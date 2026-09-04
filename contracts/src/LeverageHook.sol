// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ILeverage, ILeverageHook, ILeverageQueue} from "./interfaces/ILeverage.sol";
import {LeverageBookLib} from "./libraries/LeverageBookLib.sol";
import {LeverageOracleLib} from "./libraries/LeverageOracleLib.sol";

/// @title LeverageHook
/// @notice The v4 hook for a leverage-enabled Hookr market. It holds no value and moves no
///         balance: it observes price, prices the LP fee, keeps liquidity exclusive to the
///         market, and answers "is this market safe to lend against right now".
///
///         Deliberately SEPARATE from the market that lends. `Hooks.beforeSwap` and
///         `Hooks.afterSwap` both begin `if (msg.sender == address(self)) return` — a hook
///         that swapped its own pool would silently skip its own callbacks, so the largest
///         price moves in the system (opens and liquidations) would go unobserved and the
///         oracle would be blind exactly when it matters. The market is a different address,
///         so its swaps reach this hook like anyone else's.
///
///         No `*_RETURNS_DELTA` flags. This hook takes no swap-time cut, so ordinary traders
///         get an unmodified v4 pool and the whole class of partial-fill reconciliation bugs
///         that forces on `HookrHook` cannot arise here. Market revenue is origination fee,
///         interest, close fee and liquidation penalty — none of which touch a swap's delta.
contract LeverageHook is IHooks, ILeverageHook {
    using StateLibrary for IPoolManager;
    using LeverageOracleLib for LeverageOracleLib.Ring;

    // beforeInitialize | afterInitialize | beforeAddLiquidity | beforeRemoveLiquidity |
    // beforeSwap | afterSwap
    uint160 public constant REQUIRED_FLAGS =
        uint160((1 << 13) | (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6));

    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    uint24 internal constant FEE_OVERRIDE_FLAG = 0x400000;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    /// @dev Spot may sit this far from the average before the market stops trusting itself.
    uint256 public constant MAX_DEVIATION_BPS = 500;

    /// @dev A SECOND, much shorter window read from the SAME ring `MAX_DEVIATION_BPS` reads —
    ///      no separate accumulator, no separate storage. `_unwindForRedemption` needs a
    ///      reference the attacker cannot set in-transaction and that ALSO tracks close enough
    ///      to spot that it does not stay dislocated for long after a genuine price move.
    ///      900s failed the second half: a push that only walked spot down through headroom it
    ///      already had above the 900s average still paid, measured at +2.74 tokens with spot
    ///      30.27% above the mean. This window is short enough that an honest decline stops
    ///      disagreeing with it within its own duration, and — because the accumulator credits
    ///      every interval to the tick that actually stood over it — an attacker cannot shorten
    ///      that wait: a push read back in the SAME transaction shows the average essentially
    ///      unmoved from before the push, which is what makes the check fire at all.
    uint32 internal constant RECENT_WINDOW_SEC = 90;
    uint256 internal constant RECENT_MAX_WALK = RECENT_WINDOW_SEC / LeverageOracleLib.MIN_SPACING_SEC + 1;
    /// @dev Tighter than `MAX_DEVIATION_BPS`, deliberately: a 90s average sits close to spot in
    ///      ordinary trading, so a wide band here would let exactly the pushes it exists to
    ///      catch through. One-sided in `isRecentlyDislocated`, for the same reason the redeem
    ///      path is never gated on a rally — only a push BELOW the recent average can feed the
    ///      unwind's sale a manipulated price.
    uint256 public constant RECENT_DEVIATION_BPS = 150;
    /// @dev LP fee floor and ceiling, in pips (1e-6).
    uint24 public constant BASE_FEE_PIPS = 3000;
    uint24 public constant MAX_FEE_PIPS = 30_000;

    /// @dev v4's own upper bound on sqrtPriceX96. Duplicated rather than imported so the
    ///      projection has no dependency that could revert inside `beforeSwap`.
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    /// @dev Positions the queue may take ahead of one incoming sell.
    ///
    ///      Three, not "as many as are eligible". The gas is spent by a trader who asked for a
    ///      swap, and the per-block seize budget in the market means the rest of the queue is
    ///      not lost — it is taken by the next trade, or by an ordinary keeper, which is what
    ///      keepers are for. A queue that empties itself in one stranger's transaction is a
    ///      queue that charges one stranger for everybody's risk.
    uint256 internal constant QUEUE_MAX_POSITIONS = 3;

    /// @dev Buckets the walk may visit before giving up. It descends from the highest
    ///      liquidation price and stops at the first bucket the incoming trade does not cross,
    ///      so an ordinary book costs one or two — this is the ceiling for a book deliberately
    ///      shaped into many sparse buckets to make a passing swapper pay for the scan.
    uint256 internal constant QUEUE_MAX_BUCKETS = 12;

    /// @dev Calls to `liquidateAhead` one incoming sell may make, successes and refusals alike.
    ///
    ///      This is the bound that keeps the walk cheap, NOT `QUEUE_MAX_POSITIONS` — that one
    ///      counts only seizures. A refusal is per-position (healthy at the average, or a
    ///      position this trade does not cross) and does not condemn the members behind it,
    ///      because order within a bucket is arbitrary (see `LeverageMarket._link`), so the walk
    ///      must be free to step PAST a refusal to the co-located position the trade does reach.
    ///      Left unbounded, a book packed with refusing members in a crossed bucket would bill a
    ///      passing swapper for the whole scan; this cap is what a griefer runs into instead.
    ///      Set above `QUEUE_MAX_POSITIONS` so the seize budget, not the attempt budget, is what
    ///      normally ends a productive pass.
    uint256 internal constant QUEUE_MAX_ATTEMPTS = 8;

    /// @dev Gas that must remain before the queue is even attempted. Sized well above the
    ///      measured cost of a three-position pass so that starting it can never be the reason
    ///      the swap behind it runs out.
    uint256 internal constant QUEUE_MIN_GAS = 900_000;

    /// @dev `uint256(keccak256("hookr.leverage.queue.entered")) - 1`. Written as a literal
    ///      because inline assembly may only reference direct number constants — the derived
    ///      expression compiles everywhere EXCEPT the two lines that need it. A hand-copied
    ///      constant is one nobody can check, so `test_queueGuardSlot_isTheDerivedValue`
    ///      recomputes it and fails if this literal ever drifts from its own derivation.
    uint256 internal constant QUEUE_GUARD_SLOT = 0xb2f3d58a155e26575a8bb36171afb15191209824eb910b2d1e511daf11ccafb9;

    IPoolManager public immutable poolManager;

    /// @dev Set once, after deployment. The hook's address is mined against its own creation
    ///      code, so it cannot take the factory as a constructor argument without the factory
    ///      existing first — and the factory needs this address. One of the two links must be
    ///      late-bound; this is it, and it is one-shot.
    address public factory;

    mapping(PoolId => address) public marketOf;
    mapping(PoolId => LeverageOracleLib.Ring) internal rings;

    event PoolRegistered(PoolId indexed id, address indexed market);
    event FactorySet(address indexed factory);

    /// @notice Emitted when a swap was made to wait behind the liquidations it triggered.
    /// @dev `swapper` is the true `msg.sender` to `poolManager.swap`, so an indexer can show a
    ///      trader why their fill was worse than their quote and point at the specific trade
    ///      that did it — which is the whole reason this is an event and not a silent effect.
    event LiquidatedAhead(
        PoolId indexed id, address indexed swapper, uint256 count, uint256 tokensSold, uint256 projectedPriceWad
    );

    error NotPoolManager();
    error FactoryAlreadySet();
    error BadFee();
    error LiquidityIsExclusive();
    error BadFlags();

    address private immutable deployer;

    /// @param admin The address permitted to call `setFactory` once.
    /// @dev `admin` is explicit rather than `msg.sender` because this address must be MINED,
    ///      so the hook can only be created by CREATE2 — i.e. by a contract. Under
    ///      `forge script` that contract is the canonical deterministic deployer
    ///      0x4e59b448..., which would have become the deployer and left `setFactory`
    ///      unreachable by every address forever: `factory` stays zero, `registerPool` reverts
    ///      NotFactory, `beforeInitialize` reverts PoolNotRegistered, and `createMarket`
    ///      reverts for everyone. The product would have been dead on arrival.
    ///
    ///      Nothing caught it because every test deploys the hook FROM the test contract,
    ///      which is also the address that calls `setFactory`. The deploy script added
    ///      alongside this is the actual regression.
    ///
    ///      There is no circularity: the admin is known before the factory exists. It is part
    ///      of the creation code the salt is mined over, so it cannot be swapped after mining.
    constructor(IPoolManager manager, address admin) {
        if (admin == address(0)) revert ILeverage.BadConfig();
        poolManager = manager;
        deployer = admin;
        // The mined address is only meaningful if it carries the permissions this contract
        // claims. Nothing downstream re-checks it — the factory stores the hook as an
        // immutable and v4 short-circuits its own flag validation for a dynamic-fee pool — so
        // an unmined deployment would run with whatever bits its address happened to have.
        if (uint160(address(this)) & 0x3FFF != REQUIRED_FLAGS) revert BadFlags();
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice One-shot, and only by whoever deployed the hook.
    /// @dev Was callable by anyone. The hook's address is mined over its creation code, so the
    ///      factory link has to be late-bound — but "late-bound" was implemented as "open",
    ///      and a watcher could claim the hook between the two transactions and register pools
    ///      pointing at a market of their choosing.
    function setFactory(address factory_) external {
        if (msg.sender != deployer) revert ILeverage.NotFactory();
        if (factory_ == address(0)) revert ILeverage.BadConfig();
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = factory_;
        emit FactorySet(factory_);
    }

    /// @inheritdoc ILeverageHook
    function registerPool(PoolKey calldata key, address market) external {
        if (msg.sender != factory) revert ILeverage.NotFactory();
        PoolId id = key.toId();
        if (marketOf[id] != address(0)) revert ILeverage.AlreadyRegistered();
        if (key.fee != DYNAMIC_FEE_FLAG) revert BadFee();
        marketOf[id] = market;
        emit PoolRegistered(id, market);
    }

    // ------------------------------------------------------------------ price

    /// @inheritdoc ILeverageHook
    function priceView(PoolId id) external view returns (ILeverage.PriceView memory view_) {
        (uint160 sqrtPriceX96, int24 spotTick,,) = poolManager.getSlot0(id);
        view_.spotWad = _priceWadFromSqrt(sqrtPriceX96);

        (int24 mean, bool covered) = rings[id].meanTick(uint32(block.timestamp), spotTick);
        view_.stale = !covered;
        view_.twapWad = covered ? _priceWadFromSqrt(TickMath.getSqrtPriceAtTick(mean)) : view_.spotWad;

        if (view_.twapWad != 0) {
            uint256 hi = view_.spotWad > view_.twapWad ? view_.spotWad : view_.twapWad;
            uint256 lo = view_.spotWad > view_.twapWad ? view_.twapWad : view_.spotWad;
            view_.deviated = (hi - lo) * BPS / hi > MAX_DEVIATION_BPS;
        }
    }

    /// @inheritdoc ILeverageHook
    function isProtected(PoolId id) external view returns (bool) {
        if (marketOf[id] == address(0)) return true;
        (uint160 sqrtPriceX96, int24 spotTick,,) = poolManager.getSlot0(id);
        (int24 mean, bool covered) = rings[id].meanTick(uint32(block.timestamp), spotTick);
        if (!covered) return true;
        uint256 spot = _priceWadFromSqrt(sqrtPriceX96);
        uint256 twap = _priceWadFromSqrt(TickMath.getSqrtPriceAtTick(mean));
        if (twap == 0 || spot == 0) return true;
        uint256 hi = spot > twap ? spot : twap;
        uint256 lo = spot > twap ? twap : spot;
        return (hi - lo) * BPS / hi > MAX_DEVIATION_BPS;
    }

    /// @notice Whether spot currently sits materially BELOW the market's own recent history.
    /// @dev Reads the SAME ring `priceView`/`isProtected` read, just over `RECENT_WINDOW_SEC`
    ///      instead of the full window — see `RECENT_WINDOW_SEC` for why 900s could not do
    ///      this job. Deliberately one-sided (only "spot below") and deliberately "false" on
    ///      an uncovered window: a young ring has no recent history to disagree with, and the
    ///      long-window `isProtected` already refuses lending on it for the reason that
    ///      matters — this check exists to catch a RECENT push, not general immaturity.
    function isRecentlyDislocated(PoolId id) external view returns (bool) {
        (uint160 sqrtPriceX96, int24 spotTick,,) = poolManager.getSlot0(id);
        (int24 mean, bool covered) =
            rings[id].meanTickOver(uint32(block.timestamp), spotTick, RECENT_WINDOW_SEC, RECENT_MAX_WALK);
        if (!covered) return false;
        uint256 spot = _priceWadFromSqrt(sqrtPriceX96);
        uint256 recent = _priceWadFromSqrt(TickMath.getSqrtPriceAtTick(mean));
        if (recent == 0 || spot >= recent) return false;
        return (recent - spot) * BPS / recent > RECENT_DEVIATION_BPS;
    }

    /// @dev Native ETH is currency0 in every Hookr pool, so sqrtPrice is sqrt(token/ETH) and
    ///      the quote-per-token price is its reciprocal. Getting this backwards inverts every
    ///      liquidation, so it is derived in exactly one place.
    function _priceWadFromSqrt(uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        // priceToken1PerToken0 = (sqrtP/2^96)^2 ; we want token0 (ETH) per token1.
        uint256 p = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        if (p == 0) return 0;
        return FullMath.mulDiv(WAD, 1 << 96, p);
    }

    // ------------------------------------------------------------------ hooks

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (marketOf[key.toId()] == address(0)) revert ILeverage.PoolNotRegistered();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Seeds the ring and pushes the opening fee in the same transaction the pool is
    ///      created, so there is no window where the pool is live with a zero dynamic fee and
    ///      an empty observation history.
    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPoolManager returns (bytes4) {
        rings[key.toId()].seed(uint32(block.timestamp));
        poolManager.updateDynamicLPFee(key, BASE_FEE_PIPS);
        return IHooks.afterInitialize.selector;
    }

    /// @dev Liquidity is exclusive to the market. An outside LP would hold a bare v4 position
    ///      with no claim on the credit ledger — and would be silently senior to the market's
    ///      own accounting. Enforced on both sides rather than inferred from one.
    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != marketOf[key.toId()]) revert LiquidityIsExclusive();
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != marketOf[key.toId()]) revert LiquidityIsExclusive();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev Prices the LP fee. Surge scales with how much of in-range depth a trade consumes —
    ///      and is computed for EXACT-INPUT swaps only. `HookrHook`'s formula casts
    ///      `-amountSpecified`, which is negative on an exact-output swap; carrying the
    ///      formula without its guard would revert every exact-output trade in the pool.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();

        // The observation is written BEFORE the swap, with the price that stood before this
        // trade — never the price this trade created.
        //
        // Writing the post-swap tick let one transaction choose what the window recorded and
        // then suppress every honest print for MIN_SPACING_SEC: dump (recorded at the
        // depressed tick), buy back in the same block (rate-limited away), repeat. Spot
        // returned to the wei while the average fell 45%, which was enough to liquidate
        // positions spot called healthy. A trade cannot pick the number that outlives it.
        (, int24 preTick,,) = poolManager.getSlot0(id);
        rings[id].write(preTick, uint32(block.timestamp));

        uint24 fee = BASE_FEE_PIPS;
        address market = marketOf[id];

        // The market's own execution pays the base fee: surging its liquidations would take
        // the recovery out of the LPs the liquidation exists to protect.
        if (sender != market && params.amountSpecified < 0) {
            uint128 liquidity = poolManager.getLiquidity(id);
            if (liquidity > 0) {
                uint256 amountIn = uint256(-params.amountSpecified);
                uint256 ratioBps = FullMath.mulDiv(amountIn, BPS, uint256(liquidity));
                uint256 extra = ratioBps * BASE_FEE_PIPS / BPS;
                uint256 total = uint256(BASE_FEE_PIPS) + extra;
                fee = total > MAX_FEE_PIPS ? MAX_FEE_PIPS : uint24(total);
            }

            // The liquidation queue goes first. See `_runQueue` — and note that this sits
            // AFTER the fee is priced on purpose: the fee is a function of the incoming size
            // against in-range depth, and a swap does not change depth, so pricing it first
            // costs nothing and keeps the surge the trader is quoted independent of whatever
            // the queue does to the price.
            if (!params.zeroForOne) _runQueue(id, market, sender, uint256(-params.amountSpecified), fee);
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | FEE_OVERRIDE_FLAG);
    }

    /// @dev Liquidations that this incoming SELL is what triggers execute into the pool before
    ///      it does, so the seller fills against the price their own trade created rather than
    ///      the one it was quoted at. That difference is slippage in the ordinary sense: the
    ///      pool is not deeper or shallower than advertised, there is simply someone ahead in
    ///      the queue, and the queue is ahead because the seller's own trade put them there.
    ///
    ///      Only sells (`!zeroForOne`, token in / quote out), and only exact-input ones. A buy
    ///      lifts the price and can trigger nothing. Exact-output is excluded for the same
    ///      reason the surge formula excludes it: the projection would have to model a fill
    ///      that may not complete, and a wrong projection here is a liquidation that should not
    ///      have happened. Exact-output sells simply do not jump the queue — they take the
    ///      pool as they find it, which is the safe direction to be wrong in.
    ///
    ///      NOTHING HERE MAY REVERT THE SWAP. The call is wrapped, the gas is floored, and a
    ///      market that fails for any reason at all leaves the trade to execute exactly as it
    ///      would have without this function. A queue that can brick a pool's trading has cost
    ///      more than it can ever return.
    function _runQueue(PoolId id, address market, address sender, uint256 amountIn, uint24 feePips) internal {
        if (market == address(0) || _queueEntered()) return;
        // 1/64th of the remaining gas survives a callee's out-of-gas, and the rest of
        // beforeSwap plus the swap itself still has to run on it. Refusing to start below a
        // floor is the only way to keep a queue failure from becoming a swap failure.
        if (gasleft() < QUEUE_MIN_GAS) return;

        uint256 projected = _projectedPriceWad(id, amountIn, feePips);
        if (projected == 0) return;

        _setQueueEntered(true);
        (uint256 count, uint256 tokensSold) = _drainQueue(ILeverageQueue(market), projected);
        _setQueueEntered(false);
        if (count > 0) emit LiquidatedAhead(id, sender, count, tokensSold, projected);
    }

    /// @dev Walks the market's credit book from its WORST position downward and takes what the
    ///      incoming trade reaches, up to `QUEUE_MAX_POSITIONS`.
    ///
    ///      The book is bucketed by liquidation price and indexed by a two-level bitmap, so
    ///      "who does this trade reach first" is a descending walk of that bitmap rather than
    ///      an enumeration — the same walk the market performs to mark itself, over the same
    ///      buckets, using the same `LeverageBookLib` key format. The walk stops at the first
    ///      bucket the trade does not cross, which on a performing book is the first bucket it
    ///      looks at: three storage reads and out.
    ///
    ///      A REFUSAL SKIPS THE POSITION, NOT THE PASS — and the distinction is load-bearing.
    ///      Monotonicity holds BETWEEN buckets: they are visited in descending liquidation
    ///      price, so once a bucket wholly performs at the projected price (`hi <= p`) every
    ///      remaining bucket does too, and the walk ends. It does NOT hold WITHIN a bucket. A
    ///      bucket spans a band of liquidation prices, and order inside it is arbitrary
    ///      (`LeverageMarket._link` head-inserts and calls the order meaningless), so a
    ///      bucket-head the trade does not reach — healthy at the average, or on the safe side
    ///      of the projected price — can sit in front of a co-located position the trade DOES
    ///      reach. Returning on that head's refusal skipped the reachable one and left it for a
    ///      keeper to collect the bonus on; stepping past it takes it now, which is the whole
    ///      point of the queue. Cost is bounded by `QUEUE_MAX_ATTEMPTS`, so a book packed with
    ///      refusing members cannot turn a stranger's swap into a paid scan.
    function _drainQueue(ILeverageQueue market, uint256 projected)
        internal
        returns (uint256 count, uint256 tokensSold)
    {
        uint256 om = market.bookOct();
        if (om == 0) return (0, 0);

        // Bucket keys are normalised by the borrow index, so that accrual — which moves every
        // position's liquidation price by the same factor — never migrates anything between
        // buckets. The read has to normalise the same way to land in the same space.
        uint256 index = market.borrowIndex();
        if (index == 0) return (0, 0);
        uint256 p = FullMath.mulDiv(projected, WAD, index);

        uint256 buckets;
        uint256 attempts;
        while (om != 0) {
            uint256 e = LeverageBookLib.msb(om);
            om ^= uint256(1) << e;
            uint256 sm = market.bookSub(e);
            while (sm != 0) {
                uint256 m = LeverageBookLib.msb(sm);
                sm ^= uint256(1) << m;
                uint256 idx = (e << LeverageBookLib.MANT) | m;
                (, uint256 hi) = LeverageBookLib.bounds(idx);
                // Descending, so the first bucket that wholly performs at the projected price
                // proves every remaining bucket does too.
                if (hi <= p) return (count, tokensSold);
                if (++buckets > QUEUE_MAX_BUCKETS) return (count, tokensSold);

                address trader = market.bucketHead(idx);
                while (trader != address(0)) {
                    // Read the successor BEFORE the seizure, which unlinks this position from
                    // the very list being walked — and, when the seizure is partial, files it
                    // somewhere else.
                    address next = market.bucketNext(trader);
                    if (++attempts > QUEUE_MAX_ATTEMPTS) return (count, tokensSold);
                    try market.liquidateAhead(trader, projected) returns (uint256 sold) {
                        tokensSold += sold;
                        if (++count >= QUEUE_MAX_POSITIONS) return (count, tokensSold);
                    } catch {
                        // Per-position refusal: this position is not one the trade takes, but a
                        // co-located sibling behind it may be. Step past it — bounded above by
                        // `QUEUE_MAX_ATTEMPTS` — rather than abandoning the pass.
                    }
                    trader = next;
                }
            }
        }
    }

    /// @dev Where an exact-input sell of `amountIn` tokens would leave the price, in quote-wei
    ///      per whole token, if it executed against the pool exactly as it stands.
    ///
    ///      Exact, not an estimate, and that is a property of THIS pool rather than of the
    ///      formula: liquidity is exclusive to the market (`beforeAddLiquidity`), the market
    ///      seeds and unwinds one full-range position and nothing else, so `L` is constant
    ///      across every tick the trade could reach and the single-range step is the whole
    ///      swap. On a pool with concentrated positions this would be an upper bound on the
    ///      move rather than the move.
    ///
    ///      The LP fee comes off the input first, because v4 takes it off the input first. A
    ///      projection that spends the fee in the pool overstates the move, and overstating the
    ///      move is the direction that liquidates someone this trade did not actually reach.
    function _projectedPriceWad(PoolId id, uint256 amountIn, uint24 feePips) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        if (sqrtPriceX96 == 0 || liquidity == 0) return 0;

        uint256 net = amountIn - FullMath.mulDiv(amountIn, feePips, 1_000_000);
        // Token (currency1) in raises sqrtPrice, which LOWERS quote-per-token. Rounded down,
        // so the projected price is never lower than the trade would truly reach — again, the
        // direction that liquidates fewer positions rather than more.
        uint256 next = uint256(sqrtPriceX96) + FullMath.mulDiv(net, 1 << 96, uint256(liquidity));
        // Clamped rather than reverted: an amount this large will not fill anyway, and
        // `beforeSwap` reverting is the one outcome this path may never produce.
        if (next >= MAX_SQRT_PRICE) next = MAX_SQRT_PRICE - 1;
        return _priceWadFromSqrt(uint160(next));
    }

    /// @dev Transient, so it clears itself at the end of the transaction with no storage write
    ///      and no way to leave the hook latched shut if a call reverts between the two writes.
    ///
    ///      The market's own sales already miss this path — they arrive with
    ///      `sender == marketOf[id]` and never reach `_runQueue` — so this is not what stops
    ///      the queue recursing today. It is what stops a future caller from arranging that it
    ///      does, and it costs one TLOAD on a path that already makes an external call.
    function _queueEntered() internal view returns (bool entered) {
        assembly ("memory-safe") {
            entered := tload(QUEUE_GUARD_SLOT)
        }
    }

    function _setQueueEntered(bool entered) internal {
        assembly ("memory-safe") {
            tstore(QUEUE_GUARD_SLOT, entered)
        }
    }

    /// @dev The observation write. Every swap that moves the pool — including the market's own
    ///      opens and liquidations — lands here, which is the whole reason the hook and the
    ///      market are different addresses.
    /// @dev Kept for the permission bit, but it writes nothing: the observation belongs in
    ///      beforeSwap, where the tick is still the one this trade inherited rather than the
    ///      one it produced.
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, int128(0));
    }

    // ---------------------------------------------------------------- unused permissions

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}
