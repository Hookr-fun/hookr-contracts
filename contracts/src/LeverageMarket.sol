// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ILeverage, ILeverageHook} from "./interfaces/ILeverage.sol";
import {LeverageBookLib} from "./libraries/LeverageBookLib.sol";
import {LeverageMath} from "./libraries/LeverageMath.sol";
import {V4PoolMath} from "./libraries/V4PoolMath.sol";

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title LeverageMarket
/// @notice One market: the v4 liquidity, the credit ledger, and the LP share that claims both.
///
///         This is the contract the design's "one pool, one liquidity base" sentence actually
///         means. It owns the pool's liquidity, it lends out of that same liquidity, and it
///         issues a share of the whole balance sheet rather than a bare pool position — so an
///         LP's claim and an LP's exposure are the same object.
///
///         It is a different address from the hook on purpose: it calls `poolManager.swap`,
///         so the hook sees its opens and liquidations as ordinary swaps and observes them.
contract LeverageMarket is IUnlockCallback {
    using StateLibrary for IPoolManager;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @dev The range the factory seeds. NAV values the position over exactly this range, so
    ///      the two cannot drift apart.
    int24 internal constant FULL_LOWER = -887220;
    int24 internal constant FULL_UPPER = 887220;

    /// @dev How far execution may fall below the pre-trade spot before an unwind is refused.
    uint256 public constant MAX_UNWIND_SLIPPAGE_BPS = 500;

    enum Action {
        Open,
        Close,
        Liquidate,
        Seed,
        Unwind
    }

    IPoolManager public immutable poolManager;
    ILeverageHook public immutable hook;
    IERC20Like public immutable token;
    PoolKey public key;
    PoolId public immutable poolId;
    ILeverage.MarketConfig public config;

    // ---- credit ledger
    uint256 public borrowIndex = WAD;
    uint256 public lastAccrual;
    uint256 public totalScaledDebt;
    uint256 public badDebt;
    uint256 public reserveQuote;

    /// @notice Outstanding pull payments — money the market holds but does not own.
    uint256 public totalClaimable;
    mapping(address => ILeverage.Position) public positions;

    // ---- LP share (minimal ERC-20)
    string public constant name = "Hookr Leverage Market Share";
    string public constant symbol = "hLMS";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed lp, uint256 quoteIn, uint256 sharesOut);
    event Redeem(address indexed lp, uint256 sharesIn, uint256 quoteOut, uint256 feeBps);
    event Opened(address indexed trader, uint256 equity, uint256 borrowed, uint256 collateral);
    event Closed(address indexed trader, uint256 proceeds, uint256 repaid, uint256 toTrader);
    event Liquidated(address indexed trader, address indexed keeper, uint256 seized, uint256 repaid, uint256 shortfall);
    event BadDebt(uint256 amount);
    event CollateralAdded(address indexed trader, uint256 quoteIn, uint256 collateralOut);
    event Repaid(address indexed trader, uint256 amount);
    event Claimed(address indexed who, uint256 amount);
    event ReserveDrawn(uint256 amount);

    error NotPoolManager();
    error NotFactory();
    error NotHook();
    error NotSelf();
    error NoPosition();
    error Healthy();
    error Unhealthy();
    error OverCapacity();
    error NothingToDo();
    error SlippageTooHigh();
    error InsufficientLiquidity();
    error PositionExists();
    error Overflow();
    /// @dev Distinct from `InsufficientLiquidity` on purpose: this fires only when idle cash
    ///      was genuinely insufficient AND the market's own position declined to sell into a
    ///      pool it currently distrusts — a transient, retryable state, not the plain "there
    ///      is no cash at all" case `InsufficientLiquidity` already covers. A caller or
    ///      frontend can catch this specifically and know to wait rather than treat it as a
    ///      generic failure.
    error PriceProtected();

    address public immutable factory;
    bool private seeded;

    /// @dev Per-BLOCK liquidation budget. `_seizeCap` used to re-read the pool's live token
    ///      side and `_execSell` used to re-snapshot spot on every call, so a keeper doing
    ///      several liquidate() calls in one block — restoring the pool between them, or simply
    ///      benefiting from the token side the earlier sells had already inflated — got a fresh
    ///      cap and a fresh floor each time. Measured: three calls in one block seized 296% of
    ///      the single-call cap, at a 1085 bps shortfall against the block-opening mark.
    ///
    ///      All four fields are set ONCE, on the first liquidation sell touched in a block, and
    ///      never updated again until `block.number` moves — including when the price or the
    ///      pool's token side would make a later call's own numbers look better. Re-anchoring
    ///      at a "better" number mid-block is exactly what let the attack renew its budget.
    uint64 private liqAnchorBlock;
    uint256 private liqAnchorPriceWad;
    uint256 private liqAnchorTokenSide;
    uint256 private liqBlockTokensSold;

    /// @notice Pull-payment balances. Liquidation credits here rather than transferring.
    mapping(address => uint256) public claimable;

    constructor(IPoolManager manager, ILeverageHook hook_, PoolKey memory key_, ILeverage.MarketConfig memory cfg) {
        // Validated here because nothing downstream can survive a bad one. kinkWad of zero
        // makes the rate curve revert, and accrue() is on every path — the market would be
        // bricked from its first borrow with no way back. A liquidation bonus above 100%
        // underflows the payout and makes liquidate() revert forever, which is worse than
        // no liquidation at all: the positions that need closing are exactly the ones stuck.
        if (cfg.kinkWad == 0 || cfg.kinkWad >= WAD) revert ILeverage.BadConfig();
        if (cfg.liqThresholdBps == 0 || cfg.liqThresholdBps > BPS) revert ILeverage.BadConfig();
        if (cfg.ltvBps == 0 || cfg.ltvBps >= cfg.liqThresholdBps) revert ILeverage.BadConfig();
        // A bonus is a slice of the recovery, so it has to leave a recovery behind.
        if (cfg.liqBonusBps > 2_000) revert ILeverage.BadConfig();
        if (cfg.reserveFactorBps > BPS) revert ILeverage.BadConfig();
        if (cfg.maxUtilisationWad == 0 || cfg.maxUtilisationWad > WAD) revert ILeverage.BadConfig();
        poolManager = manager;
        hook = hook_;
        key = key_;
        poolId = key_.toId();
        token = IERC20Like(Currency.unwrap(key_.currency1));
        config = cfg;
        factory = msg.sender;
        lastAccrual = block.timestamp;
    }

    receive() external payable {}

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ------------------------------------------------------------------ interest

    /// @notice Rolls the borrow index forward and books the reserve's cut of the interest.
    function accrue() public {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0) return;
        lastAccrual = block.timestamp;
        if (totalScaledDebt == 0) return;

        uint256 debtBefore = totalDebt();
        uint256 rate = borrowRateWad();
        borrowIndex = LeverageMath.accrueIndex(borrowIndex, rate, dt);
        uint256 interest = totalDebt() - debtBefore;
        if (interest > 0) {
            reserveQuote += interest * config.reserveFactorBps / BPS;
        }

        // The reserve is CASH cover. It was booked on index growth — paper interest — with
        // nothing tying it to money the book can actually produce, so it grew without bound on
        // a stressed market: measured at 407.76 ETH against total quote-side assets of 52.70
        // ETH after six yearly accruals at 92.86% utilisation. `navQuote` then floors at zero
        // (`assets > reserveQuote ? assets - reserveQuote : 0`) and every redemption reverts
        // InsufficientLiquidity, with LP funds frozen and no path back.
        //
        // A reserve larger than the cash behind it is not cover, it is a number. Clamping it to
        // the balance keeps it honest and cannot itself freeze anything: the clamp only ever
        // reduces a liability, and `_bookShortfall` still draws on whatever remains.
        //
        // This under-books on a market whose value sits in the pool position rather than in
        // cash. That is the conservative direction — it understates a liability the LPs owe
        // themselves, rather than overstating one they cannot pay.
        // Capped at HALF the cash, not all of it. Clamping to the full balance still let the
        // reserve swallow every wei the market held: NAV stayed technically non-zero but fell
        // far enough that `quoteForShares` rounded a real LP's redemption down to nothing, which
        // is the same freeze wearing a different number. First-loss cover that consumes the
        // entire balance is not cover.
        uint256 cap = idleQuote() / 2;
        if (reserveQuote > cap) reserveQuote = cap;
    }

    function totalDebt() public view returns (uint256) {
        return FullMath.mulDiv(totalScaledDebt, borrowIndex, WAD);
    }

    function debtOf(address trader) public view returns (uint256) {
        return FullMath.mulDiv(positions[trader].scaledDebt, borrowIndex, WAD);
    }

    function utilisation() public view returns (uint256) {
        return LeverageMath.utilisationWad(totalDebt(), idleQuote());
    }

    function borrowRateWad() public view returns (uint256) {
        return LeverageMath.borrowRatePerYearWad(utilisation(), config.kinkWad, WAD / 100, WAD / 10, 3 * WAD);
    }

    /// @notice Quote asset sitting in the market, uncommitted.
    /// @notice Cash the market owns — its balance less what it has already promised away.
    /// @dev `claimable` (keeper bonuses, liquidated traders' residuals) is a liability held in
    ///      the same ETH. Reporting the raw balance booked it as LP equity in NAV and let a
    ///      redemption spend it: one LP exit drew the pot down to 3.31 ETH against 8.86 ETH of
    ///      outstanding claims, and `claim()` then reverted forever.
    function idleQuote() public view returns (uint256) {
        uint256 bal = address(this).balance;
        return bal > totalClaimable ? bal - totalClaimable : 0;
    }

    // ------------------------------------------------------------------ valuation

    /// @dev Token inventory the market owns outright — NOT borrower collateral, which belongs
    ///      to the borrower and is already represented by the receivable it secures. Counting
    ///      both is the double count the whole design exists to rule out.
    function ownedTokens() public view returns (uint256) {
        uint256 held = token.balanceOf(address(this));
        uint256 pledged = collateralHeld;
        return held > pledged ? held - pledged : 0;
    }

    uint256 public collateralHeld;

    // ---- the credit book, bucketed by liquidation price
    //
    // The mark has to be `sum_i min(debt_i, thr * price * collateral_i)`, and `positions` is a
    // mapping — not enumerable, and navQuote sits inside deposit, redeem and openPosition, so
    // an O(n) view is a DoS. Buckets are how you get the per-position quantity without the
    // enumeration: positions that share a liquidation price share a bucket, and a bucket's two
    // sums answer for all of its members at once.
    //
    // Bucketing on the RAW liquidation price would need rebucketing on every accrual. Bucketing
    // on the index-normalised one does not — see `_bookWrite`.
    //
    // The key format itself lives in `LeverageBookLib`, because the hook reads these same
    // buckets back as the order an incoming sell reaches positions in. One layout, one file.
    uint256 internal constant MANT = LeverageBookLib.MANT;
    uint256 internal constant TAIL = LeverageBookLib.TAIL;

    /// @dev idx => sum(scaledDebt) << 128 | sum(threshold-discounted collateral).
    mapping(uint256 => uint256) internal bookBucket;
    /// @dev octave => 16-bit mask of occupied mantissas within it. Public for the same reason
    ///      `bucketHead` is: the hook descends these two masks to find who the next sell
    ///      reaches first, and a mask it cannot read is a queue it cannot order.
    mapping(uint256 => uint256) public bookSub;
    /// @dev 256-bit mask of occupied octaves. Two levels, so the read skips empty ground
    ///      without scanning it — the same shape as a v4 tick bitmap. Public alongside
    ///      `bookSub`, so the hook can descend the book from its worst position down.
    uint256 public bookOct;

    // ---- bucket membership, so the book can be READ BACK as positions and not only as sums
    //
    // The two sums above answer "how impaired is this book" without enumerating it, which is
    // what NAV needs. `liquidateAhead` needs the opposite: the ADDRESSES filed at or above a
    // price, in the order the price will reach them. A mapping cannot be walked, so the walk
    // is stored — one intrusive doubly-linked list per bucket, threaded through the same
    // buckets the two-level bitmap already indexes.
    //
    // Doubly-linked and not singly: removal has to be O(1). A position leaves the book on
    // every close, every liquidation and every repay, and a singly-linked list would have to
    // scan its bucket to find the predecessor — an unbounded scan on a path that must not be
    // allowed to become expensive, since the whole point of the queue is that it runs inside
    // somebody else's swap.
    //
    // Membership is not a flag. `_bookWrite` unlinks exactly when `oldScaled != 0` and links
    // exactly when `newScaled != 0`, which is the same condition that maintains the sums — so
    // a position is in exactly one list whenever it is counted in exactly one bucket, and
    // there is no second source of truth to drift.
    // `bucketHead` / `bucketNext` are PUBLIC because the hook walks them. `bucketPrev` is not:
    // it exists only so removal is O(1), and nothing outside this contract has any business
    // reading a list backwards.
    mapping(uint256 => address) public bucketHead;
    mapping(address => address) public bucketNext;
    mapping(address => address) internal bucketPrev;

    /// @notice Scaled debt filed in the book. Must always equal `totalScaledDebt`.
    /// @dev Five call sites mutate `positions`, and a book that misses one drifts SILENTLY —
    ///      no revert, just a mark that is quietly wrong. This is the tripwire: both sides are
    ///      maintained aggregates, so the check is O(1) and the invariant suite asserts it
    ///      after every action.
    uint256 public bookedScaled;

    /// @notice The credit book at face, less the shortfall its collateral cannot cover.
    /// @dev This replaced an AGGREGATE formula — `min(collateralHeld * price * thr, totalDebt)`
    ///      — which compared the whole book's collateral against the whole book's debt. But
    ///      `min(SUM, SUM) != SUM of min`: collateral securing little or no debt lifted the
    ///      impairment mark on every OTHER receivable. That was directly profitable, because
    ///      `borrowForEquity` returns 0 for leverage <= 1x, so an open at 1x was a free
    ///      zero-debt collateral deposit, and `addCollateral` has no gates at all. Measured
    ///      against this build with the fix reverted, on the book in LeverageMarking.t.sol: one
    ///      15 ETH injection fabricated +4.44 ETH of NAV and netted +1.44 ETH out of the LPs who
    ///      stayed. The control that isolates the cause to the mark rather than to fees: the
    ///      identical script on an UNIMPAIRED book loses money.
    ///
    ///      Read in SHORTFALL form, `face - sum_i (debt_i - thr*price*collateral_i)^+`, because
    ///      the correction is zero for every position that is not under water. The loop
    ///      therefore visits only buckets at or above the price — on a performing book that is
    ///      no buckets at all and the mark is exactly face. That matters: this sits inside
    ///      deposit, redeem and openPosition, so the performing-book path is the hot one.
    function _recoverableDebt(uint256 price) internal view returns (uint256) {
        uint256 face = totalDebt();
        if (face == 0) return 0;
        // Compare in normalised space, since that is the space the buckets are keyed in.
        uint256 p = FullMath.mulDiv(price, WAD, borrowIndex);
        uint256 ep = LeverageBookLib.msb(p);
        if (ep > LeverageBookLib.EMAX) ep = LeverageBookLib.EMAX;
        uint256 mp = ep < MANT ? 0 : (p >> (ep - MANT)) & 15;
        uint256 om = (bookOct >> ep) << ep; // drop every octave below the price's
        uint256 sh;
        while (om != 0) {
            uint256 e = LeverageBookLib.msb(om);
            om ^= uint256(1) << e;
            uint256 sm = bookSub[e];
            if (e == ep) sm = (sm >> mp) << mp; // inside the price octave, only mantissas >= the price's
            while (sm != 0) {
                uint256 m = LeverageBookLib.msb(sm);
                sm ^= uint256(1) << m;
                sh += _bucketShortfall((e << MANT) | m, p);
            }
        }
        if (sh == 0) return face;
        sh = FullMath.mulDivRoundingUp(sh, borrowIndex, WAD);
        return face > sh ? face - sh : 0;
    }

    /// @dev A bucket's contribution to the shortfall. Exact everywhere except the single bucket
    ///      the price sits inside, where the members straddle their own hinges and the best that
    ///      can be done is a bound.
    function _bucketShortfall(uint256 idx, uint256 p) internal view returns (uint256) {
        uint256 w = bookBucket[idx];
        uint256 S = w >> 128;
        if (S == 0) return 0;
        uint256 K = uint128(w);
        (uint256 lo, uint256 hi) = LeverageBookLib.bounds(idx);
        // Below the price bucket every member has q < p, so every hinge term is zero. Above it
        // every member is on the same side of its hinge, so the sum of the hinges EQUALS the
        // hinge of the sums. The min-of-sums fallacy can only bite where a hinge is crossed,
        // and that is one bucket.
        if (p >= hi) return 0; // whole bucket performs      EXACT
        if (p <= lo) {
            // whole bucket under water   EXACT
            uint256 kp = FullMath.mulDiv(K, p, WAD);
            return S > kp ? S - kp : 0;
        }
        // The one straddling bucket. Two per-member bounds, each summed only after it is
        // applied per member, so neither aggregates across a hinge:
        //   (s_i - k_i*p)^+ <= k_i*(hi - p)          -> K*(hi - p),  tight at the bottom edge
        //   (s_i - k_i*p)^+ =  s_i*(1 - p/q_i)^+ <= s_i*(1 - p/hi) -> S*(1 - p/hi), tight at the top
        // Both agree with the EXACT branches at lo and hi, so the mark is CONTINUOUS in price
        // across every boundary — there is no cliff to straddle and nothing to gain by tuning a
        // position's ratio to sit on one.
        uint256 a = FullMath.mulDivRoundingUp(K, hi - p, WAD);
        uint256 b = S - FullMath.mulDiv(S, p, hi);
        return a < b ? a : b;
    }

    // `_recoverableUpper` — the old aggregate formula, retained for the deposit side — has been
    // deleted. The argument for it was that `min(SUM,SUM) >= SUM of min` makes it an upper
    // bound, so quoting it on entry stops a depositor buying a cheapened book.
    //
    // That reasoning casts the depositor as the adversary. They are the victim. The aggregate
    // is precisely the quantity an attacker can inflate by posting collateral that secures
    // nothing, so pricing entry against it left the injection primitive fully intact against
    // whoever deposited next: they bought at the inflated mark and could only ever leave at the
    // honest one. It changed who was robbed, not whether anyone was.
    //
    // The mirror risk is real but bounded and unmanipulable. The +0.294 ETH figure that
    // motivated the asymmetry was measured against a mark that discards the collateral term
    // outright; this one is a bucketed per-position mark whose worst case is 88 bps, and no
    // action by any party widens it. A bounded 88 bps that nobody controls beats an unbounded
    // one that an attacker sets. Upper bound in, lower bound out is the right instinct when the
    // only options are two wrong numbers; it is the wrong one when an honest number exists.

    /// @dev Moves a position between buckets. Nothing is stored per position: the index is
    ///      RECOMPUTED from (collateral, scaledDebt) on both the remove and the add, with the
    ///      same truncation and the same rounding, so the removal lands in exactly the bucket
    ///      the add used. `ILeverage.Position` stays one slot.
    ///
    ///      The key is index-invariant, which is the property the whole design rests on. With
    ///      `debt = scaledDebt * borrowIndex / WAD` and `k = collateral * thr / BPS`, the
    ///      liquidation price is `q * borrowIndex / WAD` where `q = scaledDebt * WAD / k` —
    ///      and `q` contains no borrowIndex. Interest moves every position's liquidation price
    ///      by the SAME factor, so accrual can never migrate a position across a bucket
    ///      boundary; only a write to that position can. `accrue()` is therefore not a call
    ///      site here and there is no staleness story to tell. The read compensates by
    ///      normalising the price the same way.
    function _bookWrite(address trader, uint256 oldColl, uint256 oldScaled, uint256 newColl, uint256 newScaled)
        internal
    {
        uint256 thr = config.liqThresholdBps;
        if (oldScaled != 0) {
            uint256 k = oldColl * thr / BPS;
            uint256 idx = k == 0 ? TAIL : LeverageBookLib.key(FullMath.mulDivRoundingUp(oldScaled, WAD, k));
            _unlink(trader, idx);
            uint256 w = bookBucket[idx];
            uint256 s = (w >> 128) - oldScaled;
            uint256 c = uint128(w) - k;
            bookBucket[idx] = (s << 128) | c;
            bookedScaled -= oldScaled;
            if (s == 0 && c == 0) {
                uint256 e = idx >> MANT;
                uint256 sm = bookSub[e] & ~(uint256(1) << (idx & 15));
                bookSub[e] = sm;
                if (sm == 0) bookOct &= ~(uint256(1) << e);
            }
        }
        if (newScaled != 0) {
            uint256 k = newColl * thr / BPS;
            // Collateral too small to register after the threshold discount is collateral that
            // recovers nothing. Filing it at the tail — zero recovery, so the shortfall is the
            // whole debt — is conservative. NOT filing it, which is the obvious reading, left
            // the debt in totalDebt() with no bucket entry at all: marked at FULL FACE with no
            // backing whatsoever, reachable by supplying dust collateral. Caught by fuzzing.
            uint256 idx = k == 0 ? TAIL : LeverageBookLib.key(FullMath.mulDivRoundingUp(newScaled, WAD, k));
            uint256 w = bookBucket[idx];
            uint256 s = (w >> 128) + newScaled;
            uint256 c = uint128(w) + k;
            if (s > type(uint128).max || c > type(uint128).max) revert Overflow();
            bookBucket[idx] = (s << 128) | c;
            bookedScaled += newScaled;
            uint256 e = idx >> MANT;
            bookSub[e] |= uint256(1) << (idx & 15);
            bookOct |= uint256(1) << e;
            _link(trader, idx);
        }
    }

    /// @dev Push to the front. Order within a bucket carries no meaning — every member of a
    ///      bucket shares a liquidation price to within one sixteenth of an octave, so there is
    ///      no fair ordering to preserve and a head insert is the cheapest one that exists.
    function _link(address trader, uint256 idx) internal {
        address head = bucketHead[idx];
        bucketNext[trader] = head;
        bucketPrev[trader] = address(0);
        if (head != address(0)) bucketPrev[head] = trader;
        bucketHead[idx] = trader;
    }

    /// @dev The mirror, and it must be the exact mirror: `idx` is RECOMPUTED by the caller from
    ///      the same (collateral, scaledDebt) the link used, so an unlink cannot address a
    ///      bucket the position was never in and orphan it in the one it was.
    function _unlink(address trader, uint256 idx) internal {
        address prev = bucketPrev[trader];
        address next = bucketNext[trader];
        if (prev == address(0)) {
            bucketHead[idx] = next;
        } else {
            bucketNext[prev] = next;
        }
        if (next != address(0)) bucketPrev[next] = prev;
        bucketNext[trader] = address(0);
        bucketPrev[trader] = address(0);
    }

    /// @notice The position's ACTUAL reserves, split at the live price.
    /// @dev For anything that has to touch real balances — how much liquidity there is to
    ///      remove, how deep a liquidation could sell — because a split taken at the average
    ///      describes a pool that does not exist right now.
    function positionReserves() public view returns (uint256 quoteSide, uint256 tokenSide) {
        uint128 liq = poolManager.getLiquidity(poolId);
        if (liq == 0) return (0, 0);
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        (quoteSide, tokenSide) = V4PoolMath.getAmountsForLiquidity(
            sqrtP, V4PoolMath.getSqrtPriceAtTick(FULL_LOWER), V4PoolMath.getSqrtPriceAtTick(FULL_UPPER), liq
        );
    }

    /// @notice What the market's own v4 position is worth, split at the average.
    /// @dev Without this, NAV counted only the idle balance and the receivable — omitting the
    ///      largest asset the market has, so every share price it quoted was against a market
    ///      that looked empty. Use `positionReserves()` for anything that touches real
    ///      balances; this one is for marking, where the average is the point.
    function positionValue() public view returns (uint256 quoteSide, uint256 tokenSide) {
        uint128 liq = poolManager.getLiquidity(poolId);
        if (liq == 0) return (0, 0);
        // Split at the AVERAGE, never at spot. Splitting at slot0 let a same-block push
        // inflate the mark on both legs at once — the value of an AMM position at a fixed
        // price is convex, so a move in either direction raises it — and neither deposit nor
        // redeem looked at the deviation. An attacker pushed, deposited or redeemed against
        // the inflated sheet, and unwound in the same transaction.
        uint160 sqrtP = _twapSqrtPrice();
        (quoteSide, tokenSide) = V4PoolMath.getAmountsForLiquidity(
            sqrtP, V4PoolMath.getSqrtPriceAtTick(FULL_LOWER), V4PoolMath.getSqrtPriceAtTick(FULL_UPPER), liq
        );
    }

    /// @dev The average price as a sqrtPriceX96, for valuing the position. Falls back to spot
    ///      only when the ring cannot cover its window, and callers that move value refuse to
    ///      act in that state.
    function _twapSqrtPrice() internal view returns (uint160) {
        ILeverage.PriceView memory p = hook.priceView(poolId);
        uint256 price = p.twapWad == 0 ? p.spotWad : p.twapWad;
        if (price == 0) return 0;
        // price is quote-per-token (WAD); sqrtPriceX96 is sqrt(token/quote) << 96.
        uint256 ratio = FullMath.mulDiv(WAD, 1 << 96, price);
        return uint160(_sqrt(ratio << 96));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice NAV with the token leg marked at `high` or `low`.
    /// @dev Deposits mark UP and redemptions mark DOWN. Marking both sides at the same
    ///      conservative bound is a one-way ratchet: on a rally the lagging average understates
    ///      the market, deposits mint too many shares, and an in-kind redemption captures the
    ///      gap immediately instead of waiting for convergence. Two-sided quoting makes the
    ///      spread a cost to whoever crosses it rather than a gift.
    function navQuote(bool markUp) public view returns (uint256) {
        ILeverage.PriceView memory p = hook.priceView(poolId);
        uint256 price =
            markUp ? (p.spotWad > p.twapWad ? p.spotWad : p.twapWad) : (p.spotWad < p.twapWad ? p.spotWad : p.twapWad);
        (uint256 poolQuote, uint256 poolTokens) = positionValue();
        uint256 inventory = FullMath.mulDiv(ownedTokens() + poolTokens, price, WAD);
        // Bad debt is NOT subtracted here. When a shortfall is realised the receivable is
        // already removed from totalDebt and the cash never arrived, so NAV has taken the
        // loss once. Subtracting the running total again charged every LP for it twice, and
        // the second charge never went away because badDebt only grows.
        // The receivable is carried at the LOWER of face and what its collateral could
        // realistically repay. Carrying it at face meant an underwater position still counted
        // in full, so whoever redeemed first got par on a book everyone knew was impaired and
        // the loss fell entirely on whoever was slower.
        // Asymmetric, for the same reason the token leg is: the generous bound on the way in,
        // the honest one on the way out. `navQuote(true) >= navQuote(false)` still holds by
        // construction — an upper bound at the high price dominates a lower bound at the low.
        uint256 assets = LeverageMath.marketEquity(idleQuote() + poolQuote, inventory, _recoverableDebt(price), 0);
        // The reserve is a liability of the market to itself, subtracted exactly once.
        return assets > reserveQuote ? assets - reserveQuote : 0;
    }

    function sharePriceWad() external view returns (uint256) {
        if (totalSupply == 0) return WAD;
        return FullMath.mulDiv(navQuote(false), WAD, totalSupply);
    }

    // ------------------------------------------------------------------ capacity

    /// @notice The ceiling, as the most conservative of its terms.
    function creditCapacity() public view returns (uint256) {
        ILeverage.PriceView memory p = hook.priceView(poolId);
        (uint256 poolQuote,) = positionReserves();
        // The receivable enters the ceiling at what it could recover, not at face. At face an
        // impaired book inflated its own lending ceiling: the debt that could not be collected
        // still counted as headroom to lend more against.
        uint256 liquidityTerm =
            idleQuote() + poolQuote + _recoverableDebt(p.spotWad < p.twapWad ? p.spotWad : p.twapWad);
        // What a liquidation could actually sell INTO, in the quote asset — the ETH side of
        // the market's own position, halved, because clearing the whole quote side would move
        // the price to the end of the range. Raw liquidity L is not an ETH amount and putting
        // it in this minimum was a category error, not a conservative estimate.
        uint256 depthTerm = poolQuote / 2;
        uint256 bondTerm = type(uint256).max; // bond registry lands with the factory
        uint256 capacity =
            LeverageMath.creditCapacity(liquidityTerm, depthTerm, bondTerm, uint256(config.protocolCapWei));
        // Conditions tighten the terms rather than standing as separate caps.
        if (p.deviated || p.stale) capacity = LeverageMath.haircut(capacity, BPS);
        return capacity;
    }

    function availableCredit() public view returns (uint256) {
        return LeverageMath.availableCredit(creditCapacity(), totalDebt());
    }

    /// @dev Capacity and utilisation as they were before `incoming` wei arrived in this call.
    function _availableCreditExcluding(uint256 incoming) internal view returns (uint256) {
        uint256 cap = creditCapacity();
        uint256 adjusted = cap > incoming ? cap - incoming : 0;
        return LeverageMath.availableCredit(adjusted, totalDebt());
    }

    function _utilisationExcluding(uint256 incoming) internal view returns (uint256) {
        uint256 idle = idleQuote();
        return LeverageMath.utilisationWad(totalDebt(), idle > incoming ? idle - incoming : 0);
    }

    /// @notice Health as the borrower should read it: collateral marked at the lower of spot
    ///         and the average, so it never flatters the position.
    function healthFactorOf(address trader) public view returns (uint256) {
        ILeverage.Position memory pos = positions[trader];
        if (pos.scaledDebt == 0) return type(uint256).max;
        ILeverage.PriceView memory p = hook.priceView(poolId);
        uint256 low = p.spotWad < p.twapWad ? p.spotWad : p.twapWad;
        return _healthAt(low, pos.collateral, debtOf(trader));
    }

    /// @notice Health as a LIQUIDATOR must prove it, marked at the time-weighted average.
    /// @dev Deliberately not the lower of the two. Marking the trigger at spot lets a keeper
    ///      shove the price inside one block, liquidate a position the average still considers
    ///      healthy, take the bonus and unwind the push — the collateral pays for the attack.
    ///      An average cannot be moved that cheaply: it has to be held for real time, which is
    ///      the cost this is buying. The unwind floor still bounds execution against pre-trade
    ///      spot, so a manipulated price cannot make the sale itself look acceptable either.
    function liquidationHealthOf(address trader) public view returns (uint256) {
        ILeverage.Position memory pos = positions[trader];
        if (pos.scaledDebt == 0) return type(uint256).max;
        ILeverage.PriceView memory p = hook.priceView(poolId);
        return _healthAt(p.twapWad, pos.collateral, debtOf(trader));
    }

    /// @dev Health measured against the ORIGINATION ratio rather than the liquidation one, so
    ///      a new position has to sit inside ltvBps and therefore opens with real room.
    function _openHealthWad(address trader) internal view returns (uint256) {
        ILeverage.Position memory pos = positions[trader];
        if (pos.scaledDebt == 0) return type(uint256).max;
        ILeverage.PriceView memory p = hook.priceView(poolId);
        uint256 low = p.spotWad < p.twapWad ? p.spotWad : p.twapWad;
        uint256 value = FullMath.mulDiv(uint256(pos.collateral), low, WAD);
        return LeverageMath.healthFactorWad(value, debtOf(trader), config.ltvBps);
    }

    function _healthAt(uint256 price, uint256 collateral, uint256 debt) internal view returns (uint256) {
        uint256 value = FullMath.mulDiv(collateral, price, WAD);
        return LeverageMath.healthFactorWad(value, debt, config.liqThresholdBps);
    }

    // ------------------------------------------------------------------ LP side

    function deposit() external payable returns (uint256 shares) {
        if (msg.value == 0) revert NothingToDo();
        accrue();
        // Value may not enter or leave against a mark the market does not trust. Only
        // openPosition checked this before, so the two paths that actually move LP value were
        // the two that did not look.
        if (hook.isProtected(poolId)) revert ILeverage.Protected();
        // Mark UP for issuance: see navQuote.
        uint256 nav = navQuote(true);

        // Never mint against a book marked at nothing. `sharesForDeposit` divides by
        // `(equity + 1)`, so at NAV zero the divisor is one wei and a deposit mints an
        // essentially unbounded share count: measured, 1 ETH minted 1.013e21 shares against an
        // honest LP's 13. Liquidating the stuck position then released the reserve, NAV
        // returned to 102.7 ETH, and the honest LP's redemption paid 1 WEI instead of 1.318 ETH
        // while the newcomer's shares were worth 103.7 ETH.
        //
        // Gated on `totalSupply > 0` so a genuinely empty market can still be opened. This
        // closes the window however NAV reached zero, not only via the reserve.
        if (totalSupply > 0 && nav == 0) revert NothingToDo();
        // The deposit is already in `address(this).balance`, so remove it from the base.
        uint256 base = nav > msg.value ? nav - msg.value : 0;
        shares = LeverageMath.sharesForDeposit(msg.value, totalSupply, base);
        if (shares == 0) revert NothingToDo();
        totalSupply += shares;
        balanceOf[msg.sender] += shares;
        emit Transfer(address(0), msg.sender, shares);
        emit Deposit(msg.sender, msg.value, shares);
    }

    /// @notice Redeems shares for quote, capped by what the market can pay without taking the
    ///         liquidity outstanding loans stand on.
    /// @dev Pro-rata and permissionless rather than a queue. A free, cancellable FIFO ticket
    ///      is a perpetual option on the whole liquid tier: holding one costs nothing and
    ///      forgoes no upside, so the dominant strategy is to enqueue everything on day one
    ///      and own all future instant liquidity for a gas fee. Serving pro-rata removes
    ///      priority as an ownable asset.
    function redeem(uint256 shares) external returns (uint256 paid) {
        if (shares == 0 || balanceOf[msg.sender] < shares) revert NothingToDo();
        accrue();
        // Deliberately NOT gated on the protected state. Refusing exits while the market
        // distrusts its price would lock every LP in exactly when they most want out, and a
        // quiet market goes stale on its own. The mark is safe without the gate: the position
        // is valued at the average, so a same-block push cannot move it.
        // Mark DOWN for redemption.
        uint256 gross = LeverageMath.quoteForShares(shares, totalSupply, navQuote(false));

        // The fee is charged on the WORSE of the utilisation before and after the exit.
        //
        // Charging it on the state beforehand was gameable in one transaction: deposit to push
        // idle up, watch utilisation fall under the kink, redeem at zero fee, and the market is
        // left exactly where it started minus the fee it should have collected. Measuring the
        // state the withdrawal leaves behind prices the liquidity it actually consumed.
        // If cash is short, pull the shortfall out of the market's own position first. Without
        // this the position was counted in NAV and unreachable in redemption, which is the
        // worst of both: an LP's shares were marked against it, burned pro-rata against it,
        // and could never be paid from it. Value stranded in the contract with the shares that
        // would have claimed it already burned.
        uint256 want = LeverageMath.quoteForShares(shares, totalSupply, navQuote(false));
        bool declinedForPrice;
        if (want > idleQuote()) {
            declinedForPrice = _unwindForRedemption(want - idleQuote());
        }

        uint256 idle = idleQuote();
        uint256 debtNow = totalDebt();
        uint256 uBefore = LeverageMath.utilisationWad(debtNow, idle);
        uint256 payable_ = LeverageMath.serviceableWithdrawal(gross, idle, 0);
        uint256 uAfter = LeverageMath.utilisationWad(debtNow, idle > payable_ ? idle - payable_ : 0);
        uint256 feeBps = LeverageMath.exitFeeBps(uAfter > uBefore ? uAfter : uBefore, config.kinkWad, 500);

        // The reserve is NOT withheld from the cash here. It is already a liability in
        // navQuote, so an entitlement computed from NAV is net of it — withholding it a second
        // time from the payable amount charged for it twice, and worse, accrued interest is an
        // index movement rather than cash, so once the reserve exceeded the market's actual
        // balance every redemption reverted forever with nothing to fix it.
        //
        // Two distinct reasons collapse into the same "nothing payable" state, and a caller
        // deserves to tell them apart. `InsufficientLiquidity` is the ordinary case — idle is
        // empty and there was nothing (or nothing more) to unwind. `PriceProtected` is
        // specifically "the unwind was available and declined because the pool looks pushed" —
        // transient, and worth a caller retrying rather than treating as a hard failure.
        if (payable_ == 0) {
            if (declinedForPrice) revert PriceProtected();
            revert InsufficientLiquidity();
        }

        // Burn the shares the ENTITLEMENT corresponds to, and pay it net of the fee. Burning
        // only the shares matching the cash paid would hand the fee straight back, leaving
        // the remaining LPs uncompensated for the liquidity the exit consumed.
        // Rounded UP, like every other conversion here. Rounding down left the redeemer
        // holding share dust against cash the market had already handed over — the one place
        // in the LP path where the remainder went to the individual rather than the market.
        uint256 burned = gross == 0 ? 0 : FullMath.mulDivRoundingUp(shares, payable_, gross);
        if (burned > shares) burned = shares;
        if (burned == 0) revert NothingToDo();
        paid = payable_ - (payable_ * feeBps / BPS);

        balanceOf[msg.sender] -= burned;
        totalSupply -= burned;
        emit Transfer(msg.sender, address(0), burned);

        (bool ok,) = msg.sender.call{value: paid}("");
        if (!ok) revert NothingToDo();
        emit Redeem(msg.sender, burned, paid, feeBps);
    }

    // ------------------------------------------------------------------ ERC-20

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    // ------------------------------------------------------------------ trader side

    /// @notice Opens a leveraged long. The trader posts equity; the market finances the rest
    ///         out of its own liquidity and books what is owed back to it.
    function openPosition(uint256 leverageWad, uint256 minCollateralOut) external payable {
        if (msg.value == 0) revert NothingToDo();
        accrue();
        if (hook.isProtected(poolId)) revert ILeverage.Protected();

        // One position per address, and opening a second is refused rather than merged.
        //
        // `positions` is keyed by address and the open path adds into it, so a second open
        // silently re-priced the first: a cautious 1.2x position went from health 4.28 to
        // 2.33 when the same trader later opened a small 3x, moving a liquidation price they
        // had already chosen and were not being asked about.
        //
        // Refusing is the safe half of the fix. The complete one is a position per token —
        // collateral and debt travelling together as one transferable object, the way an
        // isolated-market position actually behaves — which is a larger change than belongs
        // in the same commit as the bug report. `addCollateral` already covers the case
        // someone actually wants: more size on the position they have.
        if (positions[msg.sender].collateral != 0) revert PositionExists();

        // The depth floor. Checked against the pool's REAL quote side, live, on every open —
        // a mark could be pushed, and a one-time unlock could be crossed and then withdrawn
        // behind.
        if (config.minPoolQuoteWei > 0) {
            (uint256 depth,) = positionReserves();
            if (depth < config.minPoolQuoteWei) revert InsufficientLiquidity();
        }

        uint256 borrow = LeverageMath.borrowForEquity(msg.value, leverageWad);
        // `borrowForEquity` returns 0 for leverage <= 1x, which made this a free zero-debt
        // collateral deposit wearing a leveraged position's clothes — one entry point for the
        // measured +1.44 ETH mark exploit. The book now prices such a position at exactly
        // nothing, so the exploit is dead either way; refusing it is belt and braces. A
        // zero-leverage leveraged position is not a product feature, and `addCollateral`
        // already covers the case someone actually wants.
        if (borrow == 0) revert NothingToDo();

        // Lend only cash the market owns. `creditCapacity()` is a statement about pool depth
        // and risk limits, not about the balance — so with the escrow reserved out of
        // idleQuote() a borrower could still be handed ETH that belongs to a keeper or a
        // liquidated trader, and `claim()` would revert for good.
        //
        // `msg.value` must be excluded, exactly as the two capacity checks below exclude it:
        // openPosition is payable, so the equity is ALREADY in address(this).balance by the time
        // idleQuote() reads it. Comparing `borrow` against the raw idleQuote() counted the
        // borrower's own equity as lendable cash and let a borrow of up to `msg.value` more than
        // the market's free balance settle out of the `claimable` escrow — breaking
        // `balance >= totalClaimable` and DoS-ing `claim()`, the precise outcome this guard's
        // comment promises to prevent. Bound `borrow` against the balance the market held BEFORE
        // this call: `borrow <= idleQuote() - msg.value`, written to avoid the underflow when the
        // escrow exceeds the free balance.
        if (borrow + msg.value > idleQuote()) revert InsufficientLiquidity();
        // Capacity must be measured WITHOUT the equity that just arrived. openPosition is
        // payable, so msg.value is already in address(this).balance by the time idleQuote()
        // reads it — counting it would let a trader borrow against their own deposit.
        if (borrow > _availableCreditExcluding(msg.value)) revert OverCapacity();
        if (_utilisationExcluding(msg.value) > config.maxUtilisationWad) revert OverCapacity();

        bytes memory res =
            poolManager.unlock(abi.encode(Action.Open, msg.sender, msg.value + borrow, borrow, minCollateralOut));
        uint256 received = abi.decode(res, (uint256));

        ILeverage.Position storage pos = positions[msg.sender];
        pos.collateral = _toU128(uint256(pos.collateral) + received);
        collateralHeld += received;
        uint256 scaled = FullMath.mulDiv(borrow, WAD, borrowIndex);
        pos.scaledDebt = _toU128(uint256(pos.scaledDebt) + scaled);
        totalScaledDebt += scaled;
        // Open against the ORIGINATION limit, not the liquidation threshold. Gating on health
        // alone let a position open at the very edge of liquidation — ltvBps was a stored,
        // validated, ABI-exposed field with no runtime effect, and the struct comment
        // promising "a position opens with room" described an invariant nothing implemented.
        if (_openHealthWad(msg.sender) <= WAD) revert Unhealthy();
        // The old book state is provably (0, 0): PositionExists refuses unless collateral is
        // zero, and `_clear` deletes the whole struct, so zero collateral implies zero debt.
        _bookWrite(msg.sender, 0, 0, pos.collateral, pos.scaledDebt);
        emit Opened(msg.sender, msg.value, borrow, received);
    }

    /// @notice Closes a position: sells the collateral back through the same pool, repays the
    ///         market, and hands whatever is left to the trader.
    function closePosition(uint256 minQuoteOut) external {
        ILeverage.Position memory pos = positions[msg.sender];
        if (pos.collateral == 0) revert NoPosition();
        accrue();

        uint256 owed = debtOf(msg.sender);
        bytes memory res =
            poolManager.unlock(abi.encode(Action.Close, msg.sender, uint256(pos.collateral), owed, minQuoteOut));
        uint256 proceeds = abi.decode(res, (uint256));

        _clear(msg.sender, pos);

        uint256 repaid = proceeds < owed ? proceeds : owed;
        uint256 toTrader = proceeds - repaid;
        if (repaid < owed) {
            _bookShortfall(owed - repaid);
        }
        if (toTrader > 0) {
            (bool ok,) = msg.sender.call{value: toTrader}("");
            if (!ok) revert NothingToDo();
        }
        emit Closed(msg.sender, proceeds, repaid, toTrader);
    }

    /// @notice Closes an unhealthy position for it, paying the keeper a bounded incentive.
    /// @dev Permitted while the market is protected: a market that stopped liquidating
    ///      because it doubted its price would be choosing to accumulate exactly the
    ///      positions it can least afford.
    function liquidate(address trader, uint256 minQuoteOut) external {
        _liquidateOne(trader, minQuoteOut, 0, false);
    }

    /// @dev The one liquidation body, reached two ways.
    ///
    ///      Written as a single function rather than two similar ones on purpose, and not only
    ///      for the bytecode: the two paths differ in exactly three places — where the lock
    ///      comes from, whether a keeper is owed a bonus, and whether an incoming trade has to
    ///      corroborate the trigger — and every OTHER decision a liquidation makes has to stay
    ///      identical between them. Two copies would have been two places for the seize cap,
    ///      the average-marked trigger, the floor and the shortfall waterfall to drift.
    ///
    /// @param projectedPriceWad Zero for an ordinary keeper liquidation, which asks nothing of
    ///        the future. Non-zero from the queue, where the seizure must ALSO be one the
    ///        incoming trade itself triggers.
    /// @param inLock True when a lock is already open and the sale must run inside it, which
    ///        is also exactly when there is no keeper to pay — see `_settle`.
    function _liquidateOne(address trader, uint256 minQuoteOut, uint256 projectedPriceWad, bool inLock)
        internal
        returns (uint256 seize)
    {
        ILeverage.Position memory pos = positions[trader];
        if (pos.collateral == 0) revert NoPosition();
        accrue();
        if (liquidationHealthOf(trader) > WAD) revert Healthy();

        uint256 owed = debtOf(trader);
        // The queue's extra condition, and only the queue's: this trade has to be what puts
        // the position under. Without it a single sell would drain the whole eligible queue
        // into the pool however small it was — which is a keeper's job, done on a keeper's
        // gas, not a passing trader's.
        if (projectedPriceWad != 0 && _healthAt(projectedPriceWad, pos.collateral, owed) > WAD) revert Healthy();

        // Seize only what the pool can absorb inside the unwind floor. Selling the whole
        // position in one swap is what made the floor unsatisfiable: on a constant-product
        // curve a 5% slippage bound caps the sellable amount near a twentieth of the reserve,
        // so the largest positions reverted at the trigger and stayed open until they had
        // already destroyed the collateral that would have covered them. A partial seize
        // closes what it can now; the rest stays liquidatable and is taken on the next call.
        seize = _seizeCap(uint256(pos.collateral));
        if (seize == 0) revert InsufficientLiquidity();

        uint256 proceeds;
        if (inLock) {
            proceeds = this.sellInLock(seize, minQuoteOut, true);
        } else {
            proceeds = abi.decode(
                poolManager.unlock(abi.encode(Action.Liquidate, trader, seize, owed, minQuoteOut)), (uint256)
            );
        }
        _settle(trader, pos, seize, owed, proceeds, inLock ? address(0) : msg.sender);
    }

    /// @dev Everything a liquidation does AFTER the sale has landed, shared by the two ways a
    ///      sale can land: `liquidate`, which opens its own unlock, and `liquidateAhead`, which
    ///      is already inside somebody else's. Factored rather than duplicated because this is
    ///      the half that decides who is owed what — a second copy is a second place for the
    ///      partial-seize book sync, the pull-payment escrow and the shortfall waterfall to
    ///      drift apart, and the drift would be silent.
    /// @param keeper Who earns the liquidation bonus, or `address(0)` for "nobody" — see
    ///        `liquidateAhead` for why the queue path pays no keeper.
    function _settle(
        address trader,
        ILeverage.Position memory pos,
        uint256 seize,
        uint256 owed,
        uint256 proceeds,
        address keeper
    ) internal {
        bool isPartial = seize < uint256(pos.collateral);
        if (isPartial) {
            // Reduce the position by what was actually taken and leave it open.
            positions[trader].collateral = _toU128(uint256(pos.collateral) - seize);
            collateralHeld -= seize;
        } else {
            _clear(trader, pos);
        }

        // No keeper, no bonus. The bonus buys a stranger's gas and inventory risk for work
        // nobody was obliged to do; the queue path is done by the pool itself, on the incoming
        // trader's gas, so there is no such work to buy. Paying it to the triggering swapper
        // instead would have made a cascade something worth CAUSING, which is the opposite of
        // what this is for. What the bonus would have been simply stays in the recovery, which
        // means it reaches the debt first and the liquidated trader's residual second.
        uint256 bonus = keeper == address(0) ? 0 : proceeds * config.liqBonusBps / BPS;
        uint256 net = proceeds - bonus;
        uint256 repaid = net < owed ? net : owed;
        uint256 residual = net - repaid;
        uint256 shortfall;
        if (isPartial) {
            // Retire only the debt this slice repaid; the position keeps the remainder and
            // remains liquidatable until it is healthy or gone.
            uint256 scaledRepaid = FullMath.mulDiv(repaid, WAD, borrowIndex);
            uint256 held = positions[trader].scaledDebt;
            if (scaledRepaid > held) scaledRepaid = held;
            positions[trader].scaledDebt = _toU128(held - scaledRepaid);
            totalScaledDebt -= scaledRepaid;
            // Synced ONCE, and only now that both legs have landed. Syncing after the seize
            // alone would file the position in a bucket it never actually occupies — reduced
            // collateral against undiminished debt — and the removal would then be computed
            // from a state that never existed. `pos` is the pre-seize copy taken on entry.
            _bookWrite(trader, pos.collateral, pos.scaledDebt, positions[trader].collateral, held - scaledRepaid);
            // `residual` stays as computed. A slice that recovers more than the whole debt
            // leaves an excess, and that excess is the trader's — zeroing it here handed
            // their money to the market while leaving them an open position with no debt.
        } else if (repaid < owed) {
            shortfall = owed - repaid;
            _bookShortfall(shortfall);
        }
        // Credited, not pushed. A borrower whose receive() reverts could otherwise block
        // their own liquidation for the whole over-collateralised band — the position stays
        // open precisely while it is still recoverable, and only becomes closable once it has
        // already booked bad debt. A liquidation must never depend on the liquidated party
        // being willing to accept money.
        if (bonus > 0) {
            claimable[keeper] += bonus;
            totalClaimable += bonus;
        }
        if (residual > 0) {
            claimable[trader] += residual;
            totalClaimable += residual;
        }
        emit Liquidated(trader, keeper, pos.collateral, repaid, shortfall);
    }

    /// @notice Liquidates ONE position into the pool AHEAD of the swap that is about to
    ///         execute against it. Called by the hook, from `beforeSwap`.
    ///
    /// @dev The ordering rule, stated plainly: a forced sale that the incoming trade itself
    ///      triggers goes through the pool FIRST, and the incoming trade fills against what is
    ///      left. A seller who moves the price past somebody's liquidation price is not
    ///      entitled to the price that existed before the liquidation they caused — that
    ///      liquidation is ahead of them in the queue, and its impact is part of their fill.
    ///      It is an ORDERING change and not a pricing one: the curve, the LP fee and the swap
    ///      the trader signed are all untouched.
    ///
    ///      Runs inside the incoming swapper's `unlock`, never its own, which is the whole
    ///      reason this is a separate entrypoint rather than another `Action`: `unlock` cannot
    ///      nest, and by the time `beforeSwap` reaches here one is already open. Everything
    ///      after the sale is `_settle`, shared verbatim with `liquidate`.
    ///
    ///      WHAT AUTHORISES A SEIZURE IS UNCHANGED, and this is the load-bearing sentence in
    ///      the file. A position is taken only if it is unhealthy AT THE TIME-WEIGHTED
    ///      AVERAGE — the same proof `liquidate` demands, for the same reason: spot can be
    ///      shoved inside one block and restored, so a spot-triggered liquidation is a
    ///      liquidation an attacker can manufacture. `projectedPriceWad` only ever NARROWS
    ///      that set; it adds the second condition that this particular trade is what crosses
    ///      the position's liquidation price. So a trade can change WHEN an
    ///      already-liquidatable position is taken and WHERE IN THE QUEUE it lands, and it
    ///      cannot make a position liquidatable that the average calls healthy. Widening this
    ///      to trigger on the projected price alone would reintroduce the stop-hunt the
    ///      average was chosen to close (see `liquidationHealthOf`), and no amount of
    ///      queue-ordering pays for that.
    ///
    ///      Execution is bounded by machinery that already exists rather than by new limits.
    ///      `_seizeCap`'s per-BLOCK token budget caps what every liquidation in a block may
    ///      sell COMBINED — keeper-driven and queue-driven alike — and `_execSell`'s
    ///      block-anchored floor bounds each sale against the spot the block opened at. Both
    ///      are anchored before the incoming trade rather than after it, so the queue prices
    ///      off the pre-trade market and not off the hole that trade is about to dig.
    ///
    ///      REVERTS FREELY, and the hook swallows it. Every refusal here — healthy at the
    ///      average, not crossed by this trade, budget spent, floor breached — must leave the
    ///      incoming swap to execute exactly as it would have. A queue that can brick a pool's
    ///      trading costs more than it can ever return, so the failure mode is "no
    ///      liquidation", never "no trade".
    function liquidateAhead(address trader, uint256 projectedPriceWad) external returns (uint256 tokensSold) {
        if (msg.sender != address(hook)) revert NotHook();
        if (projectedPriceWad == 0) revert NothingToDo();
        // minOut zero: the floor inside `_execSell` is the real bound here, and it is measured
        // against the block's anchored spot rather than against a number this call chose.
        return _liquidateOne(trader, 0, projectedPriceWad, true);
    }

    /// @notice Adds collateral to an open position, in the quote asset.
    /// @dev Stays open while the market is protected: every action that reduces risk does.
    ///      Without this a position drifting toward liquidation could only be closed, which
    ///      is the worst moment to force someone to realise a loss.
    function addCollateral(uint256 minCollateralOut) external payable {
        if (msg.value == 0) revert NothingToDo();
        ILeverage.Position storage pos = positions[msg.sender];
        if (pos.collateral == 0) revert NoPosition();
        accrue();

        bytes memory res =
            poolManager.unlock(abi.encode(Action.Open, msg.sender, msg.value, uint256(0), minCollateralOut));
        uint256 received = abi.decode(res, (uint256));
        uint256 wasColl = pos.collateral;
        pos.collateral = _toU128(wasColl + received);
        collateralHeld += received;
        _bookWrite(msg.sender, wasColl, pos.scaledDebt, pos.collateral, pos.scaledDebt);
        emit CollateralAdded(msg.sender, msg.value, received);
    }

    /// @notice Repays quote-asset debt, in part or in full.
    function repay() external payable {
        if (msg.value == 0) revert NothingToDo();
        ILeverage.Position storage pos = positions[msg.sender];
        if (pos.scaledDebt == 0) revert NoPosition();
        accrue();

        uint256 owed = debtOf(msg.sender);
        uint256 applied = msg.value < owed ? msg.value : owed;
        uint256 scaled = FullMath.mulDiv(applied, WAD, borrowIndex);
        if (scaled > pos.scaledDebt) scaled = pos.scaledDebt;
        uint256 wasScaled = pos.scaledDebt;
        pos.scaledDebt = uint128(wasScaled - scaled);
        totalScaledDebt -= scaled;
        _bookWrite(msg.sender, pos.collateral, wasScaled, pos.collateral, pos.scaledDebt);

        uint256 refund = msg.value - applied;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert NothingToDo();
        }
        emit Repaid(msg.sender, applied);
    }

    /// @dev Downcast that reverts rather than truncating. A silent wrap here would delete a
    ///      trader's collateral or their debt, depending on which side wrapped.
    function _toU128(uint256 v) internal pure returns (uint128) {
        if (v > type(uint128).max) revert Overflow();
        return uint128(v);
    }

    /// @dev A shortfall is absorbed by the reserve first, and only what the reserve cannot
    ///      cover becomes bad debt against the LPs.
    ///
    ///      This is what the reserve was collected for. Without a release path it only ever
    ///      grew — a monotonic liability that depressed NAV forever, so LPs paid for losses
    ///      through the reserve AND through bad debt, and the cover they had funded never
    ///      actually covered anything.
    function _bookShortfall(uint256 amount) internal {
        if (amount == 0) return;
        uint256 fromReserve = amount < reserveQuote ? amount : reserveQuote;
        if (fromReserve > 0) {
            reserveQuote -= fromReserve;
            emit ReserveDrawn(fromReserve);
        }
        uint256 remaining = amount - fromReserve;
        if (remaining > 0) {
            badDebt += remaining;
            emit BadDebt(remaining);
        }
    }

    /// @notice Withdraws a pull-payment balance.
    function claim() external returns (uint256 amount) {
        amount = claimable[msg.sender];
        if (amount == 0) revert NothingToDo();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert NothingToDo();
        emit Claimed(msg.sender, amount);
    }

    /// @notice Removes enough of the market's own liquidity to cover `quoteNeeded`.
    /// @dev Proportional and bounded: it takes a slice of the position, never the whole of
    ///      it, so one exit cannot dismantle the market the remaining LPs are standing on.
    /// @return declinedForPrice True when the ONLY reason nothing was unwound is that the pool
    ///         currently looks pushed — as opposed to there being no position, or nothing left
    ///         requested, which are unrelated and already ordinary.
    function _unwindForRedemption(uint256 quoteNeeded) internal returns (bool declinedForPrice) {
        uint128 liq = poolManager.getLiquidity(poolId);
        if (liq == 0) return false;
        (uint256 poolQuote,) = positionReserves();
        if (poolQuote == 0) return false;

        // Refuse to sell the position's token leg into a pool that was just pushed down. Uses
        // the SHORT window (see LeverageHook.RECENT_WINDOW_SEC) rather than the 900s one the
        // rest of the market trusts — a reference an attacker cannot set in-transaction, but
        // one that also stops disagreeing with an honest decline within its own duration,
        // rather than for up to 900 seconds. See LeverageHook.isRecentlyDislocated for the
        // full mechanism and its own stated limit.
        if (hook.isRecentlyDislocated(poolId)) return true;

        // Fraction of the position needed, capped at a quarter so a single redemption cannot
        // strip the book.
        uint256 num = quoteNeeded > poolQuote ? poolQuote : quoteNeeded;
        uint256 take = FullMath.mulDiv(uint256(liq), num, poolQuote);
        uint256 cap = uint256(liq) / 4;
        if (take > cap) take = cap;
        if (take == 0) return false;

        poolManager.unlock(abi.encode(Action.Unwind, address(0), take, uint256(0), uint256(0)));
        return false;
    }

    /// @dev The most collateral one unwind may take: a fraction of the pool's token side, so
    ///      the sale stays inside the slippage the floor allows. Sized under the constant
    ///      product bound rather than at it, because the floor also has to absorb the LP fee
    ///      and whatever the price does mid-unwind.
    function _seizeCap(uint256 collateral) internal view returns (uint256) {
        (, uint256 tokenSide) = positionReserves();
        // No token side means nothing to sell into: seizing the whole position would put the
        // unwind straight back into the floor it cannot clear. Take nothing and let the
        // position wait for depth rather than reverting the caller.
        if (tokenSide == 0) return 0;

        // Inside the current liquidation block, the budget is the ANCHORED token side — fixed
        // at the first touch this block — not the live one. The live side grows with every
        // seize (a seize sells INTO the pool), so basing the cap on it let the ceiling creep
        // upward call after call in the same block, on top of the re-anchoring bug above.
        uint256 baseline = (liqAnchorBlock == block.number) ? liqAnchorTokenSide : tokenSide;
        uint256 cap = baseline / 25;
        uint256 usedThisBlock = (liqAnchorBlock == block.number) ? liqBlockTokensSold : 0;
        if (usedThisBlock >= cap) return 0;
        cap -= usedThisBlock;

        return collateral < cap ? collateral : cap;
    }

    /// @dev Serves closePosition and full liquidation alike, so the book leaves by the same door.
    function _clear(address trader, ILeverage.Position memory pos) internal {
        collateralHeld -= pos.collateral;
        totalScaledDebt -= pos.scaledDebt;
        delete positions[trader];
        _bookWrite(trader, pos.collateral, pos.scaledDebt, 0, 0);
    }

    // ------------------------------------------------------------------ pool execution

    /// @notice Called by the factory once, to place the market's founding liquidity.
    /// @dev Any token the seed did not consume goes straight back to the factory rather than
    ///      sitting here as "inventory". A market cannot honestly mark a large loose position
    ///      at spot when selling it is the thing that would move spot — that is the same
    ///      headline-versus-executable error the credit ceiling exists to avoid.
    /// @dev `seeded` used to be assigned and never read, leaving the factory able to call this
    ///      twice. The second call sweeps `token.balanceOf(address(this))` — which by then
    ///      includes every borrower's collateral — and then the whole ETH balance. Only
    ///      unrelated accidents held it shut.
    function seedLiquidity(int256 liquidityDelta, int24 lower, int24 upper) external payable returns (uint256 dust) {
        if (msg.sender != factory) revert NotFactory();
        if (seeded) revert NotFactory();
        poolManager.unlock(
            abi.encode(Action.Seed, address(0), uint256(liquidityDelta), uint256(int256(lower)), uint256(int256(upper)))
        );
        seeded = true;
        dust = token.balanceOf(address(this));
        if (dust > 0) token.transfer(factory, dust);
        // Same for quote the seed did not consume: it was the creator's, and leaving it here
        // silently converts it into LP value nobody minted a share against.
        uint256 quoteDust = address(this).balance;
        if (quoteDust > 0) {
            (bool ok,) = factory.call{value: quoteDust}("");
            if (!ok) revert NothingToDo();
        }
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, address who, uint256 a, uint256 b, uint256 c) =
            abi.decode(data, (Action, address, uint256, uint256, uint256));

        if (action == Action.Open) return abi.encode(_execBuy(a, c));
        if (action == Action.Close || action == Action.Liquidate) {
            return abi.encode(this.sellInLock(a, c, action == Action.Liquidate));
        }
        if (action == Action.Seed) {
            _execSeed(int256(a), int24(int256(b)), int24(int256(c)));
            return "";
        }
        if (action == Action.Unwind) {
            _execUnwind(a);
            return "";
        }
        who; // silence unused in the Seed branch
        b;
        return "";
    }

    /// @notice The market's sale of its own tokens into its own pool. Self-call only.
    ///
    /// @dev External, and called as `this.sellInLock(...)` from inside this contract, for a
    ///      reason that is about bytecode rather than about design. Two paths need this sale —
    ///      the unlock callback, and the liquidation queue that runs inside somebody else's
    ///      unlock — and `_execSell` is the largest body in the file. As a two-site internal
    ///      function the optimiser inlined it into both, which measured 1,074 bytes and put
    ///      `LeverageMarketDeployLib` 672 bytes past EIP-170; the deploy library carries this
    ///      contract's whole initcode, so the market's size limit is really the library's. One
    ///      external entry point is one body.
    ///
    ///      The cost is a self-CALL to a warm address on paths already spending tens of
    ///      thousands of gas, and it changes nothing about custody: `msg.sender` to the pool
    ///      manager is still this contract either way, so the deltas, the sync and the settle
    ///      all land exactly where they did.
    function sellInLock(uint256 tokensIn, uint256 minOut, bool enforceFloor) external returns (uint256) {
        if (msg.sender != address(this)) revert NotSelf();
        return _execSell(tokensIn, minOut, enforceFloor);
    }

    /// @dev Spends `quoteIn` of ETH through the pool and takes the token output to this
    ///      contract. The position is written from what actually arrived, never from a quote.
    function _execBuy(uint256 quoteIn, uint256 minOut) internal returns (uint256 received) {
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(quoteIn), sqrtPriceLimitX96: 4295128739 + 1}),
            ""
        );
        uint256 spent = uint256(int256(-delta.amount0()));
        received = uint256(int256(delta.amount1()));
        if (received < minOut) revert SlippageTooHigh();

        // Reset the transient synced-currency slot before paying in native. `sync` is
        // permissionless and nothing in v4 clears it, so a stray sync(token) in the same
        // transaction would send this down the ERC-20 branch and revert NonzeroNativeValue.
        poolManager.sync(key.currency0);
        poolManager.settle{value: spent}();
        poolManager.take(key.currency1, address(this), received);
    }

    /// @dev Sells `tokensIn` back through the same pool.
    ///
    ///      The floor is measured against a PRE-TRADE SPOT snapshot taken inside this unlock,
    ///      not against a lagging average. An earlier design keyed it to the short TWAP, which
    ///      is unsatisfiable during a decline at any size: the seize amount cancels from both
    ///      sides of the inequality, so shrinking the trade does not help. Bounding execution
    ///      against the price the swap started at is what "the liquidator did not dump the
    ///      book" actually means.
    function _execSell(uint256 tokensIn, uint256 minOut, bool enforceFloor) internal returns (uint256 proceeds) {
        uint256 preSpot;
        if (enforceFloor) {
            // Anchor ONCE per block, on the first liquidation sell touched. A fresh snapshot on
            // every call let a keeper restore the pool between seizes and have each call's
            // floor re-anchor against a price that was, by then, already recovered — measured
            // at 296% of the single-call cap across three calls in one block. The anchor is
            // never moved again until `block.number` changes, even if a later call's own
            // numbers would look more favourable.
            if (liqAnchorBlock != block.number) {
                liqAnchorBlock = uint64(block.number);
                (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
                liqAnchorPriceWad = _priceWad(sqrtP);
                (, liqAnchorTokenSide) = positionReserves();
                liqBlockTokensSold = 0;
            }
            preSpot = liqAnchorPriceWad;
        }

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokensIn),
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970342 - 1
            }),
            ""
        );
        uint256 sold = uint256(int256(-delta.amount1()));
        proceeds = uint256(int256(delta.amount0()));
        if (proceeds < minOut) revert SlippageTooHigh();

        if (enforceFloor) {
            uint256 floor = FullMath.mulDiv(sold, preSpot, WAD);
            floor = floor * (BPS - MAX_UNWIND_SLIPPAGE_BPS) / BPS;
            if (proceeds < floor) revert SlippageTooHigh();
            // Booked against the FIXED per-block budget `_seizeCap` reads, so the total sold
            // across every liquidation this block — not just this call — stays inside the
            // ceiling the anchor was taken for.
            liqBlockTokensSold += sold;
        }

        poolManager.sync(key.currency1);
        token.transfer(address(poolManager), sold);
        poolManager.settle();
        poolManager.take(key.currency0, address(this), proceeds);
    }

    function _execSeed(int256 liquidityDelta, int24 lower, int24 upper) internal {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
            ""
        );
        if (delta.amount0() < 0) {
            poolManager.sync(key.currency0);
            poolManager.settle{value: uint256(int256(-delta.amount0()))}();
        }
        if (delta.amount1() < 0) {
            uint256 owed = uint256(int256(-delta.amount1()));
            poolManager.sync(key.currency1);
            token.transfer(address(poolManager), owed);
            poolManager.settle();
        }
    }

    /// @dev Burns `liquidity` from the market's position and takes both sides to the market.
    ///      The token side stays as inventory the redemption path does not spend, so a
    ///      withdrawal never quietly sells a borrower's collateral out from under them.
    function _execUnwind(uint256 liquidity) internal {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: FULL_LOWER, tickUpper: FULL_UPPER, liquidityDelta: -int256(liquidity), salt: bytes32(0)
            }),
            ""
        );
        if (delta.amount1() > 0) {
            // Sell the token leg back for quote inside the same unlock. Taking it as inventory
            // stranded it: redemption pays in the quote asset only, so every unwind converted
            // LP value into tokens no path could ever pay out.
            uint256 tokensOut = uint256(int256(delta.amount1()));
            poolManager.take(key.currency1, address(this), tokensOut);
            BalanceDelta sold = poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(tokensOut),
                    sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970342 - 1
                }),
                ""
            );
            uint256 spentTokens = uint256(int256(-sold.amount1()));
            poolManager.sync(key.currency1);
            token.transfer(address(poolManager), spentTokens);
            poolManager.settle();
            uint256 gained = uint256(int256(sold.amount0()));

            // NO PROCEEDS FLOOR HERE, deliberately. One was added and then removed, because
            // measurement showed it could not do the job it was added for and charged real
            // money for the attempt.
            //
            // It could not detect the sandwich. The snapshot and the swap happen inside a
            // single `unlock` with no external call between them, so the "pre-trade spot" it
            // compared against was already the price the sandwicher had pushed. It never saw
            // the manipulation; it only ever bounded the SIZE of the trade, and the only way
            // it stopped the attack was by reverting the victim's redemption too.
            //
            // And bounding size was expensive. Removing fraction f of a full-range position
            // and selling that leg back into the (1-f) left behind executes about f below the
            // spot the removal started from, so a 500 bps floor is really a cap of f <= 4.7%
            // (closed form 1 - 0.95/0.997 = 471 bps; measured boundaries 472/475, 475/480 and
            // 463/478 bps in three independent harnesses). `_unwindForRedemption` is allowed
            // `liq/4`, five times that, so ordinary exits reverted: one measured LP recovered
            // 105.262 of 125.982 ETH only by slicing across 18 settling redemptions and 47
            // refusals. `_seizeCap`'s tokenSide/25 sits just under the same bound, which is
            // why liquidation cleared the floor and redemption did not — the two paths were
            // sized against different caps.
            //
            // The sandwich WAS real — measured at +33.63 ETH to the attacker and -45.2 ETH to
            // the redeeming LP — and the exploitable version is CLOSED upstream of this sell:
            // `_unwindForRedemption` declines (returns, does not execute) when
            // `hook.isRecentlyDislocated(poolId)` reads spot more than 150 bps below the 90s
            // short-window mean, a mean the attacker cannot move inside one transaction. See
            // finding 2 in contracts/AUDIT.md and the gate at the top of `_unwindForRedemption`.
            // This block only runs once that gate has let the unwind proceed, so the proceeds do
            // not settle against a same-transaction push of MORE than 150 bps below the mean; a
            // push within that one-sided band still executes, and that bounded residual (an
            // ~1.5%-of-unwound-leg skim, socialised through NAV) is the deliberate cost of not
            // refusing honest exits. A bare deviation gate was not enough — a quiet push under the
            // 500 bps band still paid — which is why the fix is the tight 90s window, not a wider
            // band.
            poolManager.take(key.currency0, address(this), gained);
        }
        if (delta.amount0() > 0) poolManager.take(key.currency0, address(this), uint256(int256(delta.amount0())));
    }

    function _priceWad(uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        uint256 p = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        if (p == 0) return 0;
        return FullMath.mulDiv(WAD, 1 << 96, p);
    }
}
