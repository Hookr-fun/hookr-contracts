// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {HookrGoverned} from "../vendor/hookr-1/base/HookrGoverned.sol";
import {HookrPriceLog} from "../../price-log/src/HookrPriceLog.sol";
import {IHookrBuybackRouter} from "./interfaces/IHookrBuybackRouter.sol";
import {IHookrBuybackClaims} from "./interfaces/IHookrBuybackClaims.sol";

/// @title Hookr Buyback Burn
/// @notice Spends whatever settlement currency it holds (the treasury splitter's buyback leg) to buy HOOKR through
///         the pinned router, against a bounded slippage measured off the pool's shared, oracle-less price log, and
///         burns what it buys. No staking, no yield, never a hold-and-claim: HOOKR bought here is gone the same
///         transaction, sent to the dead address.
/// @dev Fails closed. HOOKR has no independent price oracle on chain 4663, so the only reference this contract
///      trusts is the time-weighted mean of its pinned pool's log in `HookrPriceLog` (labs/hooks/price-log), pinned
///      at construction on the PoolManager the buyback names. The log keeps permissionless records of the pool's
///      price, at most one per interval, each clamped to a step from the last and refused inside an unlock, and a
///      record weighs nothing in a window that ends when it is written. The pool is bound together with the id of
///      its log there, and only when the log records that pool and serves the window with at least
///      `MIN_RECORDS_PER_WINDOW` intervals in it. Both means are read with `meanFresh`: every record that weighs in
///      them must have stood at most `MAX_STAND_INTERVALS` intervals, so while the log is recorded every interval one
///      record carries at most that share of the window, and a reference nobody kept recording is refused rather than
///      read stale. `buyback` records the price itself first when a record is due (that record weighs nothing in
///      either mean), and reverts `NoHealthyReference` when the log does not serve both means (a pool not yet
///      launched, a log not yet seeded or not kept recorded, a thin record still weighing), rather than swap blind.
///      There is no secondary "deepest pool" fallback.
///      The bind needs no pool: the buyback can be deployed before its reference pool launches and stays inert until
///      the log covers the window.
///      The reference is the log's records, so whoever writes every record for a reference window sets the
///      reference: one clamped step per interval, and a record needs no price held, only a pump, the record and the
///      dump in one transaction. The floor follows it. What a moved reference can buy is bounded by the spend limit,
///      not by the floor: `buyback` spends at most `spendCap` over any `spendPeriod` seconds, so it buys one cap a
///      period at most, never the whole balance in one transaction, and `pause` stops it at once.
contract HookrBuybackBurn is HookrGoverned {
    using PoolIdLibrary for PoolKey;

    /// @notice Where burned HOOKR goes. No key exists for this address; nothing can ever move it again.
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    uint16 public constant MIN_SLIPPAGE_BPS = 10; // 0.1%
    uint16 public constant MAX_SLIPPAGE_BPS = 1_000; // 10%
    uint16 public constant DEFAULT_SLIPPAGE_BPS = 300; // 3%
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The fewest log intervals a reference window spans.
    uint32 public constant MIN_RECORDS_PER_WINDOW = 4;
    /// @notice The longest any record weighing in either mean may have stood, in log intervals: with the log recorded
    ///         every interval, one record then carries at most 2 / 4 of the shortest window, 2 / 6 of the default.
    uint32 public constant MAX_STAND_INTERVALS = 2;
    uint32 public constant DEFAULT_WINDOW = 1_800;
    /// @notice The short window read beside `referenceWindow`. The floor is set off whichever of the two means values
    ///         the buyback's spend higher, so a move the long mean still lags (a sell-off minutes ago) raises the floor
    ///         instead of becoming room for whoever triggers the buyback. Both means end now, and a record weighs
    ///         nothing in a window that ends when it is written, so no price set in the current second, by a swap
    ///         earlier in the same transaction or any other, enters either mean.
    uint32 public constant SPOT_WINDOW = 60;

    /// @notice Bounds of `spendPeriod`, the seconds over which the spend allowance refills to `spendCap`. The default is
    ///         one reference window: each cap is then priced against a window its previous spend has fully entered.
    uint32 public constant MIN_SPEND_PERIOD = 60;
    uint32 public constant MAX_SPEND_PERIOD = 7 days;
    uint32 public constant DEFAULT_SPEND_PERIOD = DEFAULT_WINDOW;
    /// @notice The largest `spendCap`: the largest exact input the router's signed amount takes. The cap itself is in
    ///         the spend currency's raw units, so it has no default here; the constructor takes it.
    uint128 public constant MAX_SPEND_CAP = uint128(type(int128).max);

    bytes32 public constant SET_ROUTER = keccak256("SET_ROUTER");
    bytes32 public constant SET_POOL = keccak256("SET_POOL");
    bytes32 public constant SET_SLIPPAGE = keccak256("SET_SLIPPAGE");
    bytes32 public constant SET_WINDOW = keccak256("SET_WINDOW");
    bytes32 public constant SET_SPEND_LIMIT = keccak256("SET_SPEND_LIMIT");
    bytes32 public constant UNPAUSE = keccak256("UNPAUSE");

    /// @notice The HOOKR token this contract burns. Immutable: a buyback contract that could be repointed at a
    ///         different token is not one anyone should trust.
    address public immutable hookr;
    /// @notice The shared price log the reference is read from, on the PoolManager the pinned pool trades on.
    ///         Immutable: a re-pin chooses a pool and its log id, never another log contract.
    HookrPriceLog public immutable priceLog;

    /// @notice Pinned router and its code hash at pin time; a later code change at the same address refuses swaps
    ///         until re-pinned through the timelock (the same guard as the zap relay's curated router).
    address public router;
    bytes32 public routerCodeHash;

    /// @notice The pool bought against and the id of its log in `priceLog`, whose history of the pool is the
    ///         reference. The two are checked and set together, at construction and on each re-pin. Only one pool is
    ///         wired.
    PoolKey public pool;
    bytes32 public logId;
    /// @notice `logId`'s record interval, set with it.
    uint32 public logInterval;

    uint16 public maxSlippageBps;
    uint32 public referenceWindow;
    /// @notice While set, `buyback` refuses. The owner sets it at once; clearing it waits the full timelock.
    bool public paused;

    /// @notice The most `buyback` spends at once and over any `spendPeriod` seconds: it draws on an allowance that
    ///         refills at `spendCap` per `spendPeriod`, up to `spendCap` (`spendable`). Sized to the reference pool's
    ///         depth, so one cap moves the pool inside the slippage bound. Raising it waits the full timelock;
    ///         lowering it is immediate (`tightenSpendLimit`).
    uint128 public spendCap;
    uint32 public spendPeriod;
    /// @dev The allowance left at `budgetUpdatedAt`, the time of the last buyback or limit change.
    uint128 private budget;
    uint40 private budgetUpdatedAt;

    /// @dev Reentrancy lock, transient per EIP-1153.
    bytes32 private constant ENTERED = keccak256("hookr.buyback-burn.entered");

    error InvalidSlippage(uint16 bps);
    error RouterCodeChanged(address router, bytes32 expected, bytes32 actual);
    error PoolDoesNotHoldHookr(PoolId id);
    error LogNotForPool(bytes32 logId, PoolId id);
    error InvalidWindow(uint32 window);
    error NoHealthyReference(PoolId id, uint32 window);
    error ManagerUnlocked();
    error RouterManagerMismatch(address router);
    error NothingToBuyWith(address currency);
    error Slippage(uint256 minOut, uint256 got);
    error TransferFailed(address currency, address to, uint256 amount);
    error Reentrancy();
    error Paused();
    error NotAPoolCurrency(address currency);
    error NotTighter(uint16 current, uint16 next);
    error InvalidSpendLimit(uint128 cap, uint32 period);
    error NotTighterSpendLimit(uint128 cap, uint32 period);
    error SpendLimitExceeded(uint256 amountIn, uint256 spendable);

    event RouterSet(address indexed previous, address indexed next, bytes32 codeHash);
    event PoolSet(PoolId indexed previous, PoolId indexed next, bytes32 logId);
    event SlippageSet(uint16 previous, uint16 next);
    event WindowSet(uint32 previous, uint32 next);
    event SpendLimitSet(uint128 previousCap, uint32 previousPeriod, uint128 cap, uint32 period);
    event BoughtAndBurned(
        PoolId indexed id,
        address indexed spent,
        uint256 amountIn,
        uint256 hookrOut,
        int24 referenceTick,
        address caller
    );
    event Collected(address indexed from, address indexed currency, uint256 received, uint256 burned, address caller);
    event PausedSet(bool paused);

    /// @param priceLog_ The shared price log, on the PoolManager `pool_` trades on.
    /// @param logId_ The id of `pool_`'s log in `priceLog_`, opened there before this deploys; the pool itself need not
    ///        exist yet.
    /// @param spendCap_ The starting `spendCap`, in the spend currency's raw units, sized to the reference pool's depth;
    ///        the allowance starts full and refills over `DEFAULT_SPEND_PERIOD`.
    constructor(
        address owner_,
        address hookr_,
        address router_,
        HookrPriceLog priceLog_,
        PoolKey memory pool_,
        bytes32 logId_,
        uint128 spendCap_
    ) HookrGoverned(owner_, 30 minutes) {
        if (hookr_ == address(0)) revert InvalidAddress(hookr_);
        if (address(priceLog_).code.length == 0) revert InvalidAddress(address(priceLog_));
        priceLog = priceLog_;
        _checkSpendLimit(spendCap_, DEFAULT_SPEND_PERIOD);
        hookr = hookr_;
        maxSlippageBps = DEFAULT_SLIPPAGE_BPS;
        referenceWindow = DEFAULT_WINDOW;
        spendCap = spendCap_;
        spendPeriod = DEFAULT_SPEND_PERIOD;
        budget = spendCap_;
        budgetUpdatedAt = uint40(block.timestamp);
        _setRouter(router_);
        _setPool(pool_, logId_);
        emit SlippageSet(0, DEFAULT_SLIPPAGE_BPS);
        emit WindowSet(0, DEFAULT_WINDOW);
        emit SpendLimitSet(0, 0, spendCap_, DEFAULT_SPEND_PERIOD);
    }

    modifier nonReentrant() {
        bytes32 slot = ENTERED;
        uint256 entered;
        assembly ("memory-safe") {
            entered := tload(slot)
        }
        if (entered != 0) revert Reentrancy();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    receive() external payable {}

    /// @notice Buys HOOKR with `amountIn` of the pinned pool's other currency (native ETH pulled from this
    ///         contract's own balance when that currency is native) and burns the output. Permissionless: anyone
    ///         may trigger a buyback once funds have accumulated here (from the treasury splitter or elsewhere).
    /// @dev Records the pool's price into the log first when a record is due (never inside an unlock:
    ///      `ManagerUnlocked`), then reverts rather than swap when the log does not serve a mean over `referenceWindow`
    ///      and `SPOT_WINDOW` (`NoHealthyReference`). The record it writes weighs nothing in either mean. Spends at most
    ///      `spendable()` (`SpendLimitExceeded`): the floor bounds the price against the reference, and the limit
    ///      bounds how much buys at a reference someone has held. The router's pinned code hash is re-checked on every
    ///      call.
    function buyback(uint256 amountIn) external nonReentrant returns (uint256 hookrOut) {
        if (paused) revert Paused();
        PoolKey memory key = pool;
        PoolId id = key.toId();
        address spend = _otherCurrency(key);
        if (amountIn == 0 || amountIn > _balanceOf(spend)) revert NothingToBuyWith(spend);
        uint256 available = spendable();
        if (amountIn > available) revert SpendLimitExceeded(amountIn, available);
        budget = uint128(available - amountIn);
        budgetUpdatedAt = uint40(block.timestamp);

        address r = router;
        if (r == address(0) || r.codehash != routerCodeHash) {
            revert RouterCodeChanged(r, routerCodeHash, r == address(0) ? bytes32(0) : r.codehash);
        }

        int24 meanTick;
        int24 spotTick;
        {
            HookrPriceLog log_ = priceLog;
            bytes32 lid = logId;
            if (TransientStateLibrary.isUnlocked(log_.manager())) revert ManagerUnlocked();
            // A log not seeded yet (the pool not launched or never recorded) serves nothing; seeding is anyone's call
            // on the log itself.
            if (log_.count(lid) == 0) revert NoHealthyReference(id, referenceWindow);
            log_.record(lid);
            uint32 maxStand = logInterval * MAX_STAND_INTERVALS;
            bool ok;
            (ok, meanTick) = log_.meanFresh(lid, referenceWindow, maxStand);
            if (!ok) revert NoHealthyReference(id, referenceWindow);
            bool spotOk;
            (spotOk, spotTick) = log_.meanFresh(lid, SPOT_WINDOW, maxStand);
            if (!spotOk) revert NoHealthyReference(id, SPOT_WINDOW);
        }

        // The floor follows whichever mean prices HOOKR cheaper for the buyback, so a live move the long mean still
        // lags cannot be taken by the caller in the same transaction.
        uint256 expectedOut = _expectedOut(key, spend, amountIn, meanTick);
        uint256 spotOut = _expectedOut(key, spend, amountIn, spotTick);
        if (spotOut > expectedOut) (expectedOut, meanTick) = (spotOut, spotTick);
        uint256 minOut = expectedOut - (expectedOut * maxSlippageBps) / BPS_DENOMINATOR;
        // A floor above what a single swap can return is unreachable; refuse rather than truncate it.
        if (minOut > type(uint128).max) revert Slippage(minOut, 0);

        bool zeroForOne = spend == Currency.unwrap(key.currency0);
        uint256 valueToSend = spend == address(0) ? amountIn : 0;
        if (spend != address(0)) IERC20(spend).approve(r, amountIn);

        // The real PoolManager rejects sqrtPriceLimitX96 == 0 (PriceLimitOutOfBounds: it must sit strictly inside
        // TickMath's bounds and on the correct side of the current price). Slippage is already bounded by
        // `amountBound` (minOut) above, computed from the oracle's mean tick, so the price limit itself is set to
        // the widest edge TickMath allows in the trade's direction and does no independent bounding.
        IHookrBuybackRouter.Swap memory params = IHookrBuybackRouter.Swap({
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: -int128(int256(amountIn)),
            amountBound: uint128(minOut),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            recipient: address(this),
            deadline: block.timestamp
        });
        (, uint256 got) = IHookrBuybackRouter(r).swap{value: valueToSend}(params, address(0), new uint256[](0));
        if (got < minOut) revert Slippage(minOut, got);
        hookrOut = got;

        bool burned = IERC20(hookr).transfer(BURN_SINK, hookrOut);
        if (!burned) revert TransferFailed(hookr, BURN_SINK, hookrOut);
        emit BoughtAndBurned(id, spend, amountIn, hookrOut, meanTick, msg.sender);
    }

    /// @notice Collects a claim a Rules module holds for this contract (such as a royalty a pool's creator directs
    ///         here) and keeps it working: the spend currency stays here for the next `buyback`, HOOKR is burned at
    ///         once. Permissionless, like `buyback`.
    /// @dev `from` is any Rules module; the call can only send this contract funds, and the lock stops re-entry.
    function collect(address from, address currency) external nonReentrant returns (uint256 received) {
        address spend = _otherCurrency(pool);
        if (currency != spend && currency != hookr) revert NotAPoolCurrency(currency);
        uint256 before = _balanceOf(currency);
        IHookrBuybackClaims(from).claimTo(Currency.wrap(currency), address(this));
        received = _balanceOf(currency) - before;
        uint256 burned;
        if (currency == hookr) {
            burned = _balanceOf(hookr);
            bool ok = IERC20(hookr).transfer(BURN_SINK, burned);
            if (!ok) revert TransferFailed(hookr, BURN_SINK, burned);
        }
        emit Collected(from, currency, received, burned, msg.sender);
    }

    /// @notice Stops `buyback` at once. Restrictive, so immediate; it voids any queued `UNPAUSE`, and clearing it
    ///         waits the full timelock (the `HookrGoverned` brake pattern).
    function pause() external onlyOwner {
        paused = true;
        _invalidateQueued(UNPAUSE);
        emit PausedSet(true);
    }

    /// @notice What `buyback` may spend now: the allowance left after the last buyback or limit change, refilled at
    ///         `spendCap` per `spendPeriod` since, up to `spendCap`.
    function spendable() public view returns (uint256 amount) {
        uint256 cap = spendCap;
        amount = budget + ((block.timestamp - budgetUpdatedAt) * cap) / spendPeriod;
        if (amount > cap) amount = cap;
    }

    /// @notice Lowers `spendCap`, raises `spendPeriod`, or both, at once. Restrictive, so immediate; it voids every
    ///         queued `SET_SPEND_LIMIT`, so a loosening queued before the brake has to be queued again and wait a full
    ///         delay.
    function tightenSpendLimit(uint128 cap, uint32 period) external onlyOwner {
        if (cap > spendCap || period < spendPeriod || (cap == spendCap && period == spendPeriod)) {
            revert NotTighterSpendLimit(cap, period);
        }
        _checkSpendLimit(cap, period);
        _invalidateQueued(SET_SPEND_LIMIT);
        _setSpendLimit(cap, period);
    }

    /// @notice Executes a queued `SET_SPEND_LIMIT`.
    function executeSpendLimit(uint128 cap, uint32 period) external onlyOwner {
        _consume(SET_SPEND_LIMIT, abi.encode(cap, period));
        _setSpendLimit(cap, period);
    }

    /// @notice Executes a queued `UNPAUSE` (queued with empty arguments).
    function executeUnpause() external onlyOwner {
        _consume(UNPAUSE, "");
        paused = false;
        emit PausedSet(false);
    }

    /// @notice Lowers `maxSlippageBps` at once. Restrictive, so immediate; it voids every queued `SET_SLIPPAGE`, so a
    ///         loosening queued before the brake has to be queued again and wait a full delay.
    function tightenSlippage(uint16 next) external onlyOwner {
        if (next < MIN_SLIPPAGE_BPS) revert InvalidSlippage(next);
        if (next >= maxSlippageBps) revert NotTighter(maxSlippageBps, next);
        _invalidateQueued(SET_SLIPPAGE);
        emit SlippageSet(maxSlippageBps, next);
        maxSlippageBps = next;
    }

    function executeRouter(address next) external onlyOwner {
        _consume(SET_ROUTER, abi.encode(next));
        _setRouter(next);
    }

    function executePool(PoolKey calldata next, bytes32 logId_) external onlyOwner {
        _consume(SET_POOL, abi.encode(next, logId_));
        _setPool(next, logId_);
    }

    function executeSlippage(uint16 next) external onlyOwner {
        _consume(SET_SLIPPAGE, abi.encode(next));
        emit SlippageSet(maxSlippageBps, next);
        maxSlippageBps = next;
    }

    /// @dev Checks the window again against the pool pinned now, which a re-pin since the queue may have changed.
    function executeWindow(uint32 next) external onlyOwner {
        _consume(SET_WINDOW, abi.encode(next));
        _checkWindow(logId, next);
        emit WindowSet(referenceWindow, next);
        referenceWindow = next;
    }

    function _checkQueue(bytes32 kind, bytes calldata arguments) internal view override {
        if (kind == SET_ROUTER) {
            address next = abi.decode(arguments, (address));
            _checkRouter(next);
            return;
        }
        if (kind == SET_POOL) {
            (PoolKey memory next, bytes32 logId_) = abi.decode(arguments, (PoolKey, bytes32));
            _checkPool(next, logId_, referenceWindow);
            return;
        }
        if (kind == SET_SLIPPAGE) {
            uint16 next = abi.decode(arguments, (uint16));
            if (next < MIN_SLIPPAGE_BPS || next > MAX_SLIPPAGE_BPS) revert InvalidSlippage(next);
            return;
        }
        if (kind == SET_WINDOW) {
            uint32 next = abi.decode(arguments, (uint32));
            _checkWindow(logId, next);
            return;
        }
        if (kind == SET_SPEND_LIMIT) {
            (uint128 cap, uint32 period) = abi.decode(arguments, (uint128, uint32));
            _checkSpendLimit(cap, period);
            return;
        }
        if (kind == UNPAUSE) {
            _requireCanonical(kind, arguments, "");
            return;
        }
        super._checkQueue(kind, arguments);
    }

    /// @dev Settles the allowance at the limit in force, keeps at most the new cap of it, then sets the new limit: a
    ///      raised cap refills from what was left, never at once.
    function _setSpendLimit(uint128 cap, uint32 period) private {
        uint256 left = spendable();
        budget = uint128(left < cap ? left : cap);
        budgetUpdatedAt = uint40(block.timestamp);
        emit SpendLimitSet(spendCap, spendPeriod, cap, period);
        spendCap = cap;
        spendPeriod = period;
    }

    function _checkSpendLimit(uint128 cap, uint32 period) private pure {
        if (cap == 0 || cap > MAX_SPEND_CAP || period < MIN_SPEND_PERIOD || period > MAX_SPEND_PERIOD) {
            revert InvalidSpendLimit(cap, period);
        }
    }

    function _setRouter(address next) private {
        _checkRouter(next);
        bytes32 codeHash = next.codehash;
        emit RouterSet(router, next, codeHash);
        router = next;
        routerCodeHash = codeHash;
    }

    /// @dev A router with code that swaps on the PoolManager the log reads, so the reference and the swap are one pool.
    function _checkRouter(address next) private view {
        if (next == address(0) || next.code.length == 0) revert InvalidAddress(next);
        if (address(IHookrBuybackRouter(next).poolManager()) != address(priceLog.manager())) {
            revert RouterManagerMismatch(next);
        }
    }

    function _setPool(PoolKey memory next, bytes32 logId_) private {
        _checkPool(next, logId_, referenceWindow);
        PoolId previous = pool.toId();
        pool = next;
        logId = logId_;
        logInterval = priceLog.params(logId_).interval;
        emit PoolSet(previous, next.toId(), logId_);
    }

    /// @dev The bind checks for buying against `next` with log `logId_` over `window` seconds: the pool holds HOOKR, the
    ///      log records that pool (on `priceLog`'s PoolManager), and the log serves the window (`_checkWindow`). The pool
    ///      need not exist yet.
    function _checkPool(PoolKey memory next, bytes32 logId_, uint32 window) private view {
        PoolId id = next.toId();
        bool holdsHookr = Currency.unwrap(next.currency0) == hookr || Currency.unwrap(next.currency1) == hookr;
        if (!holdsHookr) revert PoolDoesNotHoldHookr(id);
        if (!priceLog.isOpen(logId_) || PoolId.unwrap(priceLog.poolOf(logId_)) != PoolId.unwrap(id)) {
            revert LogNotForPool(logId_, id);
        }
        _checkWindow(logId_, window);
    }

    /// @dev A reference window spans at least `MIN_RECORDS_PER_WINDOW` of the log's intervals and is servable by it (at
    ///      most its `MAX_WINDOW_INTERVALS`).
    function _checkWindow(bytes32 logId_, uint32 window) private view {
        uint256 interval = priceLog.params(logId_).interval;
        if (uint256(window) < interval * MIN_RECORDS_PER_WINDOW || !priceLog.servable(logId_, window)) {
            revert InvalidWindow(window);
        }
    }

    /// @dev The pool's currency that is not HOOKR: what the caller spends.
    function _otherCurrency(PoolKey memory key) private view returns (address) {
        address c0 = Currency.unwrap(key.currency0);
        return c0 == hookr ? Currency.unwrap(key.currency1) : c0;
    }

    /// @dev Amount of HOOKR the oracle's mean tick implies `amountIn` of `spend` is worth, in raw (undecimalised)
    ///      units, the same convention the pool's own reserve ratio uses. Full precision off the square root price
    ///      with one rounding (the v3 periphery's quote-at-tick method), never through a fixed-point price, so a raw
    ///      price far below or above one stays exact.
    function _expectedOut(PoolKey memory key, address spend, uint256 amountIn, int24 meanTick)
        private
        pure
        returns (uint256)
    {
        uint256 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(meanTick);
        bool spendIsCurrency0 = spend == Currency.unwrap(key.currency0);
        if (sqrtPriceX96 <= type(uint128).max) {
            // price = sqrtPriceX96^2 / 2^192 currency1 per currency0; the square fits in 256 bits here.
            uint256 ratioX192 = sqrtPriceX96 * sqrtPriceX96;
            return spendIsCurrency0
                ? FullMath.mulDiv(ratioX192, amountIn, 1 << 192)
                : FullMath.mulDiv(1 << 192, amountIn, ratioX192);
        }
        uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        return spendIsCurrency0
            ? FullMath.mulDiv(ratioX128, amountIn, 1 << 128)
            : FullMath.mulDiv(1 << 128, amountIn, ratioX128);
    }

    function _balanceOf(address currency) private view returns (uint256) {
        if (currency == address(0)) return address(this).balance;
        return IERC20(currency).balanceOf(address(this));
    }
}
