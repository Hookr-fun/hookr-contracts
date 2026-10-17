// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice The one call the engine makes on a Tax + Conversion queue: pay the creator share, as quote, to the queue's
///         frozen asset recipient (this engine). Permissionless on the queue itself.
interface IDrawdownBurnTaxQueue {
    function payCreator() external returns (uint256 amount);
}

/// @notice The Tax + Conversion advisory's view of a bound pool (HookrDirectionalTax.terms).
interface IDrawdownBurnTaxAdvisory {
    struct Terms {
        address buyQueue;
        uint24 buyTaxPips;
        bool bound;
        bool tiered;
        bool decaying;
        address sellQueue;
        uint24 sellTaxPips;
    }

    function terms(address root, PoolId id) external view returns (Terms memory);
}

interface IDrawdownBurnToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @title HookrDrawdownBurn
/// @notice A drawdown burn engine for one Hookr pool, with no oracle, no owner and no admin key. It spends the quote it
///         holds (normally the sell side of Tax + Conversion, paid to it by the pool's queue) on buybacks that burn the
///         pool's subject token, with a burn share set by how far the price sits under its all-time high, and keeps the
///         rest as a wall: a buy order at a fixed distance under the all-time high whose fills are burned too.
/// @dev    Every price the engine acts on comes from its own checkpoints, never from the spot price of the current
///         transaction:
///         - `checkpoint()` is permissionless and records the pool's spot tick at most once per `checkpointInterval`.
///           Each record is clamped to `maxMoveTicks` from the previous record and is refused while the PoolManager is
///           unlocked, so a free in-unlock pump cannot be recorded and a paid pump moves one record by a bounded step.
///         - Means are time-weighted over the step function of the records, and the newest record weighs nothing
///           when it is written: a pumped record only counts for the time it stands, which is at least one interval in
///           which anyone may record the true price over it.
///         - The all-time high ratchets up only when every record across at least `athWindow` seconds, and at least
///           `athMinCheckpoints` of them, sits above it, to the lowest of those records, and never by more than the
///           rise cap allows for the time since the last rise. It never goes down.
///         - A record taken while the pool's in-range liquidity is under `minLiquidity` is marked thin; a window
///           that weighs a thin record cannot raise the high, set a tier, price a buyback or close an epoch.
///         Every parameter is fixed in the constructor and bounded there. Nothing can change it afterwards.
contract HookrDrawdownBurn is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // ---------------------------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice What the high and the drawdown are measured in. PRICE: the subject's price in the quote. MARKET_CAP: the
    ///         price times the circulating supply (total supply less the dead address, the zero address and the
    ///         excluded holders), relative to the circulating supply at deployment. Every burn lowers the market cap at
    ///         a flat price, so MARKET_CAP deepens its own drawdown as it burns.
    enum Reference {
        PRICE,
        MARKET_CAP
    }

    /// @notice Where the wall share goes. RESERVE: the engine keeps it and buys the subject (and burns it) only at or
    ///         under the wall price. SINK: the engine pays it out to `wallSink` (a Floor bid vault, for one).
    enum Wall {
        RESERVE,
        SINK
    }

    /// @notice The flow epoch mode. SPEND: the burn budget is spent. ACCUMULATE: it is held.
    enum Mode {
        SPEND,
        ACCUMULATE
    }

    /// @notice Everything a creator sets at launch. Bounds are in `_validate`.
    struct Config {
        IPoolManager manager;
        PoolKey key;
        /// @notice Whether the subject (the token bought back and burned) is currency0. The other side is the quote.
        bool subjectIsCurrency0;
        /// @notice The Tax + Conversion advisory whose sell queue for this pool pays this engine, or zero. The queue is
        ///         read from the advisory on each run, so the engine can be deployed before the pool (it must be: the
        ///         queue's recipient is frozen at launch). Anyone may also fund the engine directly.
        address taxAdvisory;
        // Checkpoints
        uint32 checkpointInterval;
        uint24 maxMoveTicks;
        uint128 minLiquidity;
        // The all-time high
        uint32 athWindow;
        uint8 athMinCheckpoints;
        uint16 athRiseCapBpsPerHour;
        /// @notice The price tick the first record is clamped to, within `maxMoveTicks`: the pool's opening price for
        ///         an engine deployed before its pool. Without it, the first record is the spot when it is written.
        bool hasSeedTick;
        int24 seedTick;
        bool hasInitialAth;
        int32 initialAth;
        Reference measure;
        address[] excluded;
        // Tiers
        uint16[3] tierEdgesBps;
        uint16[5] tierBurnBps;
        uint32 refWindow;
        // Spending
        uint128 spendCap;
        uint32 refillSeconds;
        uint16 maxSlippageBps;
        // The wall
        Wall wall;
        uint16 wallOffsetBps;
        address wallSink;
        // Flow epochs
        bool epochSwitch;
        uint32 epochLength;
        /// @notice The mean window the epoch's open and close are read over.
        uint32 epochWindow;
        uint16 deadBandBps;
        uint16 netOutSinkBps;
        address netOutSink;
        // Callers and the co-author
        uint16 tipBps;
        uint128 checkpointReward;
        address coAuthor;
        uint16 coAuthorBps;
    }

    /// @notice One record. `tick` is the subject's price as a tick (higher is pricier, whichever currency it is),
    ///         clamped against the previous record; `liquidity` is the pool's in-range liquidity when recorded.
    struct Checkpoint {
        uint32 time;
        int24 tick;
        uint128 liquidity;
        bool thin;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Constants: fixed, not knobs
    // ---------------------------------------------------------------------------------------------------------------

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant CAPACITY = 64;
    uint256 internal constant BPS = 10_000;

    // Bounds
    uint32 internal constant MIN_INTERVAL = 60;
    uint32 internal constant MAX_INTERVAL = 3600;
    uint24 internal constant MIN_MOVE_TICKS = 10;
    uint24 internal constant MAX_MOVE_TICKS = 5000;
    uint32 internal constant MIN_ATH_WINDOW = 300;
    uint32 internal constant MAX_ATH_WINDOW = 86_400;
    uint8 internal constant MIN_ATH_CHECKPOINTS = 2;
    uint8 internal constant MAX_ATH_CHECKPOINTS = 48;
    uint16 internal constant MIN_RISE_CAP_BPS = 500;
    uint16 internal constant MAX_EDGE_BPS = 9500;
    uint32 internal constant MIN_REF_WINDOW = 300;
    uint32 internal constant MAX_REF_WINDOW = 86_400;
    uint32 internal constant MIN_REFILL = 12;
    uint32 internal constant MAX_REFILL = 7 days;
    uint16 internal constant MIN_SLIPPAGE_BPS = 10;
    uint16 internal constant MAX_SLIPPAGE_BPS = 1000;
    uint16 internal constant MIN_WALL_OFFSET_BPS = 1000;
    uint16 internal constant MAX_WALL_OFFSET_BPS = 9000;
    uint32 internal constant MIN_EPOCH = 1 hours;
    uint32 internal constant MAX_EPOCH = 7 days;
    uint16 internal constant MAX_DEAD_BAND_BPS = 2000;
    uint16 internal constant MAX_TIP_BPS = 50;
    uint16 internal constant MAX_CO_AUTHOR_BPS = 2000;
    uint256 internal constant MAX_EXCLUDED = 4;

    // ---------------------------------------------------------------------------------------------------------------
    // Frozen configuration
    // ---------------------------------------------------------------------------------------------------------------

    IPoolManager public immutable manager;
    PoolId public immutable poolId;
    bool public immutable subjectIsCurrency0;
    Currency public immutable subject;
    Currency public immutable quote;
    /// @notice The circulating supply when the first record was written; MARKET_CAP measures against it.
    uint256 public circulatingAtStart;

    // Tunings converted to ticks once, at deployment.
    int24 internal immutable slippageTicks;
    int24 internal immutable wallTicks;
    int24 internal immutable riseCapTicks;
    int24 internal immutable deadBandTicks;
    int24 internal immutable edgeTicks0;
    int24 internal immutable edgeTicks1;
    int24 internal immutable edgeTicks2;

    Config internal cfg;

    // ---------------------------------------------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------------------------------------------

    Checkpoint[64] internal ring;
    /// @notice The slot of the newest record.
    uint8 public head;
    /// @notice How many records the ring holds (at most CAPACITY).
    uint8 public count;

    /// @notice The all-time high, in reference ticks (price ticks, plus the supply tick under MARKET_CAP).
    int32 public ath;
    bool public athSet;
    uint32 public lastRise;

    uint32 public epoch;
    int24 public epochOpen;
    Mode public mode;

    /// @notice Quote set aside for buybacks.
    uint256 public burnBudget;
    /// @notice Quote set aside for the wall (RESERVE mode).
    uint256 public wallReserve;
    /// @notice Quote owed to the frozen recipients (co-author, wall sink, net-out sink), paid by `claim`, so a recipient
    ///         that refuses a payment cannot stop the engine.
    mapping(address => uint256) public owed;
    uint256 public totalOwed;

    uint128 internal bucketLevel;
    uint32 internal bucketTime;
    bool internal entered;

    // ---------------------------------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------------------------------

    event Started(uint32 time, int24 tick, uint128 liquidity);
    event Checkpointed(uint32 time, int24 spotTick, int24 recordedTick, uint128 liquidity, bool thin);
    event AthRaised(int32 previous, int32 ath, bool capped);
    event EpochClosed(uint32 epoch, int24 open, int24 close, Mode mode);
    event Allocated(uint256 income, uint8 tier, uint256 toBurn, uint256 toWall);
    event BoughtBack(uint256 quoteIn, uint256 subjectBurned, bool wall);
    event PaidOut(address indexed to, uint256 amount, bytes32 indexed what);
    event Owed(address indexed to, uint256 amount, bytes32 indexed what);
    event RunSkipped(bytes32 reason);

    error InvalidConfig(bytes32 what);
    error NotStarted();
    error AlreadyStarted();
    error PoolNotInitialized();
    error ManagerUnlocked();
    error NotManager();
    error Reentered();
    error ThinStart();

    modifier nonReentrant() {
        if (entered) revert Reentered();
        entered = true;
        _;
        entered = false;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------------------------

    constructor(Config memory c) {
        _validate(c);
        manager = c.manager;
        poolId = c.key.toId();
        subjectIsCurrency0 = c.subjectIsCurrency0;
        subject = c.subjectIsCurrency0 ? c.key.currency0 : c.key.currency1;
        quote = c.subjectIsCurrency0 ? c.key.currency1 : c.key.currency0;
        if (subject.isAddressZero()) revert InvalidConfig("subject native");

        slippageTicks = _ratioTicks(BPS + c.maxSlippageBps);
        wallTicks = -_ratioTicks(BPS - c.wallOffsetBps);
        riseCapTicks = c.athRiseCapBpsPerHour == 0 ? int24(0) : _ratioTicks(BPS + c.athRiseCapBpsPerHour);
        deadBandTicks = _ratioTicks(BPS + c.deadBandBps);
        edgeTicks0 = -_ratioTicks(BPS - c.tierEdgesBps[0]);
        edgeTicks1 = -_ratioTicks(BPS - c.tierEdgesBps[1]);
        edgeTicks2 = -_ratioTicks(BPS - c.tierEdgesBps[2]);

        // One record moves a mean over `epochWindow` by at most maxMoveTicks x checkpointInterval / epochWindow; that
        // must stay inside the dead band, so no single record (one paid pump or dump) can flip the epoch.
        if (
            c.epochSwitch
                && uint256(c.maxMoveTicks) * c.checkpointInterval > uint256(uint24(deadBandTicks)) * c.epochWindow
        ) revert InvalidConfig("deadBand/epochWindow");

        cfg = c;

        (uint160 sqrtPriceX96,,,) = c.manager.getSlot0(c.key.toId());
        if (sqrtPriceX96 != 0) _seed();
    }

    /// @notice Writes the first record for an engine deployed before its pool was initialized. Once.
    function start() external nonReentrant {
        if (count != 0) revert AlreadyStarted();
        _seed();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Permissionless calls
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Records the pool's price if `checkpointInterval` has passed since the last record, then rolls the epoch
    ///         and tries to raise the all-time high. Pays the caller `checkpointReward` from unallocated quote when a
    ///         record was written and the engine holds enough.
    function checkpoint() external nonReentrant returns (bool recorded) {
        recorded = _checkpoint();
        if (recorded && cfg.checkpointReward != 0) {
            uint256 reward = cfg.checkpointReward;
            if (_unallocated() >= reward) _pay(msg.sender, reward, "checkpointReward");
        }
    }

    /// @notice One step of the engine: record if due, collect the tax queue, set the new income aside by the drawdown
    ///         tier, work the wall, then spend the burn budget (unless the epoch is accumulating). Both buys share
    ///         the spend cap.
    function run() external nonReentrant {
        if (count == 0) revert NotStarted();
        _checkpoint();
        _collect();

        (bool ok, int24 refTick) = _mean(cfg.refWindow);
        if (!ok) {
            emit RunSkipped("no reference");
            return;
        }
        if (!athSet) {
            emit RunSkipped("no ath");
            return;
        }
        uint8 tier = _tier(int256(refTick) + _supplyTick());
        _allocate(tier);

        // The wall is a standing bid: when the price is through it, it fills first, as a resting order would.
        _workWall();
        if (!cfg.epochSwitch || mode == Mode.SPEND) _spendBurnBudget(refTick);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    function config() external view returns (Config memory) {
        return cfg;
    }

    /// @notice The record `back` steps before the newest (0 = newest).
    function checkpointAt(uint256 back) external view returns (Checkpoint memory) {
        require(back < count, "out of range");
        return ring[(uint256(head) + CAPACITY - back) % CAPACITY];
    }

    /// @notice The time-weighted mean price tick over `window` seconds ending now, and whether it is usable.
    function meanTick(uint32 window) external view returns (bool ok, int24 tick) {
        return _mean(window);
    }

    /// @notice The current reference (mean over `refWindow`, plus the supply tick under MARKET_CAP), its drawdown from
    ///         the all-time high in basis points, and its tier. `ok` is false when no usable reference or high exists.
    function drawdown() external view returns (bool ok, int256 refValue, uint256 drawdownBps, uint8 tier) {
        (bool meanOk, int24 refTick) = _mean(cfg.refWindow);
        if (!meanOk || !athSet) return (false, 0, 0, 0);
        refValue = int256(refTick) + _supplyTick();
        tier = _tier(refValue);
        int256 dd = int256(ath) - refValue;
        if (dd > 0) {
            uint160 s = TickMath.getSqrtPriceAtTick(_clampTick(-dd));
            // price ratio (1 - drawdown) = s^2 / 2^192
            uint256 ratioBps = FullMath.mulDiv(uint256(s) * uint256(s), BPS, 1 << 192);
            drawdownBps = ratioBps >= BPS ? 0 : BPS - ratioBps;
        }
        ok = true;
    }

    /// @notice Quote the engine may still spend now under the spend cap.
    function spendable() external view returns (uint256) {
        return _bucket();
    }

    /// @notice Quote the engine holds that is in neither the burn budget nor the wall reserve.
    function unallocated() external view returns (uint256) {
        return _unallocated();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Checkpoints, the high and epochs
    // ---------------------------------------------------------------------------------------------------------------

    function _seed() internal {
        // The first record has no previous one to clamp against: refuse it inside an unlock, refuse it thin, and clamp it
        // to the seed tick the creator set (the opening price) when there is one, so a pump around `start()` moves it by
        // at most one clamp step.
        if (manager.isUnlocked()) revert ManagerUnlocked();
        (int24 tick, uint128 liquidity) = _observe();
        if (liquidity < cfg.minLiquidity) revert ThinStart();
        if (cfg.hasSeedTick) {
            int256 lo = int256(cfg.seedTick) - int256(uint256(cfg.maxMoveTicks));
            int256 hi = int256(cfg.seedTick) + int256(uint256(cfg.maxMoveTicks));
            tick = _clampTick(tick < lo ? lo : (tick > hi ? hi : int256(tick)));
        }
        if (cfg.measure == Reference.MARKET_CAP) {
            circulatingAtStart = _circulating(cfg.excluded);
            if (circulatingAtStart == 0) revert ThinStart();
        }
        uint32 now32 = uint32(block.timestamp);
        ring[0] = Checkpoint(now32, tick, liquidity, false);
        head = 0;
        count = 1;
        lastRise = now32;
        if (cfg.hasInitialAth) {
            ath = cfg.initialAth;
            athSet = true;
        }
        epoch = uint32(block.timestamp / cfg.epochLength);
        epochOpen = tick;
        bucketLevel = cfg.spendCap;
        bucketTime = now32;
        emit Started(now32, tick, liquidity);
    }

    function _checkpoint() internal returns (bool) {
        if (count == 0) revert NotStarted();
        Checkpoint memory last = ring[head];
        if (block.timestamp < uint256(last.time) + cfg.checkpointInterval) return false;
        // Inside an unlock a pump is free until the unlock settles; refuse to record there.
        if (manager.isUnlocked()) revert ManagerUnlocked();

        (int24 spot, uint128 liquidity) = _observe();
        int256 lo = int256(last.tick) - int256(uint256(cfg.maxMoveTicks));
        int256 hi = int256(last.tick) + int256(uint256(cfg.maxMoveTicks));
        int256 clamped = spot < lo ? lo : (spot > hi ? hi : int256(spot));
        int24 recorded = _clampTick(clamped);

        // The epoch closes on the history before this record; the new record would weigh nothing in it anyway.
        _rollEpoch();

        uint32 now32 = uint32(block.timestamp);
        uint8 next = uint8((uint256(head) + 1) % CAPACITY);
        bool thin = liquidity < cfg.minLiquidity;
        ring[next] = Checkpoint(now32, recorded, liquidity, thin);
        head = next;
        if (count < CAPACITY) count++;
        emit Checkpointed(now32, spot, recorded, liquidity, thin);

        _ratchet();
        return true;
    }

    /// @dev Raises the high to the lowest record of the newest run of records that spans `athWindow`, when that run
    ///      has at least `athMinCheckpoints` records, none thin and all above the high, within the rise cap.
    function _ratchet() internal {
        int256 st = _supplyTick();
        uint32 newestTime = ring[head].time;
        int256 low = type(int256).max;
        uint256 n;
        bool spans;
        for (uint256 i; i < count; ++i) {
            Checkpoint memory cp = ring[(uint256(head) + CAPACITY - i) % CAPACITY];
            if (cp.thin) return;
            int256 v = int256(cp.tick) + st;
            if (athSet && v <= int256(ath)) return;
            if (v < low) low = v;
            ++n;
            if (newestTime - cp.time >= cfg.athWindow) {
                spans = true;
                break;
            }
        }
        if (!spans || n < cfg.athMinCheckpoints) return;

        bool capped;
        if (athSet && riseCapTicks != 0) {
            int256 maxRise = int256(riseCapTicks) * int256(block.timestamp - lastRise) / 3600;
            if (low > int256(ath) + maxRise) {
                low = int256(ath) + maxRise;
                capped = true;
            }
        }
        if (athSet && low <= int256(ath)) return;
        int32 previous = ath;
        ath = int32(low);
        athSet = true;
        lastRise = uint32(block.timestamp);
        emit AthRaised(previous, ath, capped);
    }

    /// @dev On the first record of a new epoch: compares the mean at the epoch's close with its open. Up by more than
    ///      the dead band (net quote in) accumulates; down by more (net quote out) spends; inside it keeps the mode.
    function _rollEpoch() internal {
        if (!cfg.epochSwitch) return;
        uint32 e = uint32(block.timestamp / cfg.epochLength);
        if (e == epoch) return;
        (bool ok, int24 close) = _mean(cfg.epochWindow);
        if (ok) {
            int256 delta = int256(close) - int256(epochOpen);
            if (delta > deadBandTicks) mode = Mode.ACCUMULATE;
            else if (delta < -int256(deadBandTicks)) mode = Mode.SPEND;
            emit EpochClosed(epoch, epochOpen, close, mode);
            epochOpen = close;
        }
        epoch = e;
    }

    /// @dev The time-weighted mean of the records' step function over [now - window, now]. Fails closed when the ring
    ///      does not reach back to the window's start or a record that carries weight in it is thin.
    function _mean(uint32 window) internal view returns (bool ok, int24 tick) {
        if (count == 0) return (false, 0);
        uint256 end = block.timestamp;
        if (end < window) return (false, 0);
        uint256 from = end - window;
        uint256 segEnd = end;
        int256 acc;
        for (uint256 i; i < count; ++i) {
            Checkpoint memory cp = ring[(uint256(head) + CAPACITY - i) % CAPACITY];
            uint256 segStart = cp.time > from ? cp.time : from;
            if (segEnd > segStart) {
                if (cp.thin) return (false, 0);
                acc += int256(cp.tick) * int256(segEnd - segStart);
            }
            if (cp.time <= from) {
                return (true, int24(acc / int256(uint256(window))));
            }
            segEnd = cp.time;
        }
        return (false, 0);
    }

    function _tier(int256 refValue) internal view returns (uint8) {
        int256 dd = int256(ath) - refValue;
        if (dd <= 0) return 0;
        if (dd >= edgeTicks2) return 4;
        if (dd >= edgeTicks1) return 3;
        if (dd >= edgeTicks0) return 2;
        return 1;
    }

    function _observe() internal view returns (int24 tick, uint128 liquidity) {
        (uint160 sqrtPriceX96, int24 poolTick,,) = manager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        liquidity = manager.getLiquidity(poolId);
        tick = subjectIsCurrency0 ? poolTick : -poolTick;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Money
    // ---------------------------------------------------------------------------------------------------------------

    function _collect() internal {
        if (cfg.taxAdvisory == address(0)) return;
        address queue;
        try IDrawdownBurnTaxAdvisory(cfg.taxAdvisory).terms(address(cfg.key.hooks), poolId) returns (
            IDrawdownBurnTaxAdvisory.Terms memory t
        ) {
            queue = t.sellQueue;
        } catch {}
        if (queue == address(0)) return;
        // A queue with nothing due, or that cannot pay this time, leaves its claim in place; the engine runs on what
        // it holds. The queue pays only its frozen recipient, so a queue that does not name this engine pays nothing
        // here.
        try IDrawdownBurnTaxQueue(queue).payCreator() {} catch {}
    }

    function _allocate(uint8 tier) internal {
        uint256 income = _unallocated();
        if (cfg.checkpointReward != 0) {
            // Keep enough unallocated to reward the next few records.
            uint256 keep = uint256(cfg.checkpointReward) * 4;
            income = income > keep ? income - keep : 0;
        }
        if (income == 0) return;
        uint256 toBurn = income * cfg.tierBurnBps[tier] / BPS;
        uint256 toWall = income - toBurn;
        burnBudget += toBurn;
        wallReserve += toWall;
        emit Allocated(income, tier, toBurn, toWall);
    }

    function _spendBurnBudget(int24 refTick) internal {
        uint256 amount = _min(burnBudget, _bucket());
        if (amount == 0) return;
        if (cfg.epochSwitch && cfg.netOutSinkBps != 0) {
            uint256 toSink = amount * cfg.netOutSinkBps / BPS;
            if (toSink != 0) {
                burnBudget -= toSink;
                _debitBucket(toSink);
                _owe(cfg.netOutSink, toSink, "netOutSink");
                amount -= toSink;
            }
        }
        if (amount == 0) return;
        // The most the buyback pays: the reference plus the slippage allowance, never the spot of this transaction.
        int256 limitTick = int256(refTick) + slippageTicks;
        uint256 spent = _buyAndBurn(amount, limitTick, false);
        burnBudget -= spent;
    }

    function _workWall() internal {
        uint256 reserve = wallReserve;
        if (reserve == 0) return;
        if (cfg.wall == Wall.SINK) {
            wallReserve = 0;
            _owe(cfg.wallSink, reserve, "wallSink");
            return;
        }
        // The wall price, as a price tick: the high less the wall offset, less the supply tick under MARKET_CAP.
        int256 wallTick = int256(ath) - _supplyTick() - wallTicks;
        uint256 amount = _min(reserve, _bucket());
        if (amount == 0) return;
        uint256 spent = _buyAndBurn(amount, wallTick, true);
        wallReserve -= spent;
    }

    /// @dev Buys the subject with up to `budget` quote (the tip and the co-author share come out of it), never above the
    ///      price tick `limitTick`, and sends every subject token bought to the dead address. Returns the quote used,
    ///      tip and co-author share included. Buys nothing when the pool's price is already at or above the limit.
    function _buyAndBurn(uint256 budget, int256 limitTick, bool isWall) internal returns (uint256 used) {
        uint160 limit;
        uint256 toLimit;
        {
            (uint160 sqrtNow,,,) = manager.getSlot0(poolId);
            uint128 liquidity = manager.getLiquidity(poolId);
            if (subjectIsCurrency0) {
                limit = TickMath.getSqrtPriceAtTick(_clampTick(limitTick));
                if (sqrtNow >= limit) return 0;
                toLimit = SqrtPriceMath.getAmount1Delta(sqrtNow, limit, liquidity, false);
            } else {
                limit = TickMath.getSqrtPriceAtTick(_clampTick(-limitTick));
                if (sqrtNow <= limit) return 0;
                toLimit = SqrtPriceMath.getAmount0Delta(limit, sqrtNow, liquidity, false);
            }
        }
        // No dust buys: below 1% of the spend cap the engine waits for the bucket to refill.
        if (budget < uint256(cfg.spendCap) / 100) return 0;
        uint256 feeBps = uint256(cfg.tipBps) + cfg.coAuthorBps;
        // Sized to reach at most the limit at the current tick's liquidity: a Hookr root refuses an unauthenticated
        // exact-input buy that stops at its price limit with fees to refund (UnauthenticatedRefund), so the engine
        // aims under the limit and, if the buy still stops there (less liquidity past the current range), halves it.
        uint256 swapIn = _min(budget * BPS / (BPS + feeBps), toLimit);
        uint256 paid;
        uint256 burned;
        for (uint256 attempt; attempt < 4 && swapIn != 0; ++attempt) {
            try manager.unlock(abi.encode(swapIn, limit)) returns (bytes memory result) {
                (paid, burned) = abi.decode(result, (uint256, uint256));
                break;
            } catch {
                swapIn /= 2;
            }
        }
        if (paid == 0) {
            emit RunSkipped(isWall ? bytes32("wall buy failed") : bytes32("buyback failed"));
            return 0;
        }

        uint256 tip = paid * cfg.tipBps / BPS;
        uint256 coAuthorShare = paid * cfg.coAuthorBps / BPS;
        used = paid + tip + coAuthorShare;
        _debitBucket(used);
        if (tip != 0) _pay(msg.sender, tip, "tip");
        if (coAuthorShare != 0) _owe(cfg.coAuthor, coAuthorShare, "coAuthor");
        emit BoughtBack(paid, burned, isWall);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (uint256 swapIn, uint160 limit) = abi.decode(data, (uint256, uint160));
        // Buying the subject: quote in. Subject is currency0 → quote is currency1 → oneForZero.
        bool zeroForOne = !subjectIsCurrency0;
        BalanceDelta delta = manager.swap(cfg.key, SwapParams(zeroForOne, -int256(swapIn), limit), "");
        int128 quoteDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 subjectDelta = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 paid = quoteDelta < 0 ? uint256(uint128(-quoteDelta)) : 0;
        uint256 got = subjectDelta > 0 ? uint256(uint128(subjectDelta)) : 0;
        if (paid != 0) {
            if (quote.isAddressZero()) {
                manager.settle{value: paid}();
            } else {
                manager.sync(quote);
                quote.transfer(address(manager), paid);
                manager.settle();
            }
        }
        if (got != 0) manager.take(subject, DEAD, got);
        return abi.encode(paid, got);
    }

    /// @notice Pays `to` what the engine owes it. Anyone may call it; the quote goes only to `to`.
    function claim(address to) external nonReentrant returns (uint256 amount) {
        amount = owed[to];
        if (amount == 0) return 0;
        owed[to] = 0;
        totalOwed -= amount;
        _pay(to, amount, "claim");
    }

    function _owe(address to, uint256 amount, bytes32 what) internal {
        owed[to] += amount;
        totalOwed += amount;
        emit Owed(to, amount, what);
    }

    function _pay(address to, uint256 amount, bytes32 what) internal {
        quote.transfer(to, amount);
        emit PaidOut(to, amount, what);
    }

    function _unallocated() internal view returns (uint256) {
        uint256 balance = quote.balanceOfSelf();
        uint256 held = burnBudget + wallReserve + totalOwed;
        return balance > held ? balance - held : 0;
    }

    function _bucket() internal view returns (uint256) {
        uint256 level =
            uint256(bucketLevel) + uint256(cfg.spendCap) * (block.timestamp - bucketTime) / cfg.refillSeconds;
        return _min(level, cfg.spendCap);
    }

    function _debitBucket(uint256 amount) internal {
        uint256 level = _bucket();
        bucketLevel = uint128(level > amount ? level - amount : 0);
        bucketTime = uint32(block.timestamp);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Market cap
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Zero under PRICE. Under MARKET_CAP, the tick of circulating / circulatingAtStart.
    function _supplyTick() internal view returns (int256) {
        if (cfg.measure != Reference.MARKET_CAP) return 0;
        uint256 circ = _circulating(cfg.excluded);
        if (circ == 0) return TickMath.MIN_TICK;
        return int256(_ratioTicksRaw(circ, circulatingAtStart));
    }

    function _circulating(address[] memory excluded) internal view returns (uint256 circ) {
        address token = Currency.unwrap(subject);
        circ = IDrawdownBurnToken(token).totalSupply();
        circ = _sub(circ, IDrawdownBurnToken(token).balanceOf(DEAD));
        circ = _sub(circ, IDrawdownBurnToken(token).balanceOf(address(0)));
        for (uint256 i; i < excluded.length; ++i) {
            circ = _sub(circ, IDrawdownBurnToken(token).balanceOf(excluded[i]));
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Validation and math
    // ---------------------------------------------------------------------------------------------------------------

    function _validate(Config memory c) internal pure {
        if (address(c.manager) == address(0)) revert InvalidConfig("manager");
        if (c.checkpointInterval < MIN_INTERVAL || c.checkpointInterval > MAX_INTERVAL) {
            revert InvalidConfig("checkpointInterval");
        }
        if (c.maxMoveTicks < MIN_MOVE_TICKS || c.maxMoveTicks > MAX_MOVE_TICKS) revert InvalidConfig("maxMoveTicks");
        if (c.minLiquidity == 0) revert InvalidConfig("minLiquidity");
        if (c.athWindow < MIN_ATH_WINDOW || c.athWindow > MAX_ATH_WINDOW) revert InvalidConfig("athWindow");
        // The ring must be able to hold a whole window of records at the fastest pace.
        if (uint256(c.athWindow) > uint256(c.checkpointInterval) * 48) revert InvalidConfig("athWindow/interval");
        if (c.athMinCheckpoints < MIN_ATH_CHECKPOINTS || c.athMinCheckpoints > MAX_ATH_CHECKPOINTS) {
            revert InvalidConfig("athMinCheckpoints");
        }
        if (uint256(c.athMinCheckpoints) - 1 > c.athWindow / c.checkpointInterval) {
            revert InvalidConfig("athMinCheckpoints/window");
        }
        if (c.athRiseCapBpsPerHour != 0 && (c.athRiseCapBpsPerHour < MIN_RISE_CAP_BPS || c.athRiseCapBpsPerHour > BPS))
        {
            revert InvalidConfig("athRiseCap");
        }
        if (c.hasInitialAth && (c.initialAth < -2 * TickMath.MAX_TICK || c.initialAth > 2 * TickMath.MAX_TICK)) {
            revert InvalidConfig("initialAth");
        }
        if (c.measure == Reference.PRICE && c.excluded.length != 0) revert InvalidConfig("excluded");
        if (c.hasSeedTick && (c.seedTick <= TickMath.MIN_TICK || c.seedTick >= TickMath.MAX_TICK)) {
            revert InvalidConfig("seedTick");
        }
        if (c.excluded.length > MAX_EXCLUDED) revert InvalidConfig("excluded");
        if (c.tierEdgesBps[0] == 0 || c.tierEdgesBps[0] >= c.tierEdgesBps[1] || c.tierEdgesBps[1] >= c.tierEdgesBps[2])
        {
            revert InvalidConfig("tierEdges");
        }
        if (c.tierEdgesBps[2] > MAX_EDGE_BPS) revert InvalidConfig("tierEdges");
        for (uint256 i; i < 5; ++i) {
            if (c.tierBurnBps[i] > BPS) revert InvalidConfig("tierBurn");
            if (i != 0 && c.tierBurnBps[i] < c.tierBurnBps[i - 1]) revert InvalidConfig("tierBurn");
        }
        if (c.refWindow < MIN_REF_WINDOW || c.refWindow > MAX_REF_WINDOW) revert InvalidConfig("refWindow");
        if (uint256(c.refWindow) > uint256(c.checkpointInterval) * 48) revert InvalidConfig("refWindow/interval");
        if (c.spendCap == 0) revert InvalidConfig("spendCap");
        if (c.refillSeconds < MIN_REFILL || c.refillSeconds > MAX_REFILL) revert InvalidConfig("refillSeconds");
        if (c.maxSlippageBps < MIN_SLIPPAGE_BPS || c.maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert InvalidConfig("maxSlippage");
        }
        if (c.wallOffsetBps < MIN_WALL_OFFSET_BPS || c.wallOffsetBps > MAX_WALL_OFFSET_BPS) {
            revert InvalidConfig("wallOffset");
        }
        if (c.wall == Wall.SINK && c.wallSink == address(0)) revert InvalidConfig("wallSink");
        if (c.wall == Wall.RESERVE && c.wallSink != address(0)) revert InvalidConfig("wallSink");
        if (c.epochLength < MIN_EPOCH || c.epochLength > MAX_EPOCH) revert InvalidConfig("epochLength");
        if (c.epochSwitch) {
            if (c.epochWindow < MIN_REF_WINDOW || c.epochWindow > c.epochLength) revert InvalidConfig("epochWindow");
            if (uint256(c.epochWindow) > uint256(c.checkpointInterval) * 48) revert InvalidConfig("epochWindow");
        } else if (c.epochWindow != 0) {
            revert InvalidConfig("epochWindow");
        }
        if (c.deadBandBps > MAX_DEAD_BAND_BPS) revert InvalidConfig("deadBand");
        if (c.netOutSinkBps > BPS) revert InvalidConfig("netOutSink");
        if ((c.netOutSinkBps == 0) != (c.netOutSink == address(0))) revert InvalidConfig("netOutSink");
        if (c.netOutSinkBps != 0 && !c.epochSwitch) revert InvalidConfig("netOutSink");
        if (c.tipBps > MAX_TIP_BPS) revert InvalidConfig("tip");
        if (c.checkpointReward > c.spendCap / 100) revert InvalidConfig("checkpointReward");
        if (c.coAuthorBps > MAX_CO_AUTHOR_BPS) revert InvalidConfig("coAuthor");
        if ((c.coAuthorBps == 0) != (c.coAuthor == address(0))) revert InvalidConfig("coAuthor");
    }

    /// @dev The tick of the ratio `bps / 10,000`.
    function _ratioTicks(uint256 bps) internal pure returns (int24) {
        return _ratioTicksRaw(bps, BPS);
    }

    /// @dev The tick whose price is `num / den`, clamped to the representable range.
    function _ratioTicksRaw(uint256 num, uint256 den) internal pure returns (int24) {
        uint256 ratioX192 = FullMath.mulDiv(num, 1 << 192, den);
        uint256 s = _sqrt(ratioX192);
        if (s < TickMath.MIN_SQRT_PRICE) s = TickMath.MIN_SQRT_PRICE;
        if (s >= TickMath.MAX_SQRT_PRICE) s = TickMath.MAX_SQRT_PRICE - 1;
        return TickMath.getTickAtSqrtPrice(uint160(s));
    }

    function _clampTick(int256 t) internal pure returns (int24) {
        if (t < TickMath.MIN_TICK + 1) return TickMath.MIN_TICK + 1;
        if (t > TickMath.MAX_TICK - 1) return TickMath.MAX_TICK - 1;
        return int24(t);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    receive() external payable {}
}
