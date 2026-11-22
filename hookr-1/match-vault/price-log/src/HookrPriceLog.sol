// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title HookrPriceLog
/// @notice A shared, oracle-less price log for Uniswap v4 pools on one PoolManager, with no owner and no admin key.
///         Anyone may open a log for a pool, anyone may record into it, and any contract may read its time-weighted
///         means. A Hook Block that needs a price it can act on reads a log instead of the spot price of the current
///         transaction, so several blocks on one pool share one record stream.
/// @dev    A log is a pool plus its frozen parameters; its id is the hash of both, so nobody can open a log under
///         someone else's id with other parameters, and opening the same pool with the same parameters twice finds the
///         same log. Nothing about a log can change after it is opened.
///         - `record(id)` writes the pool's spot tick at most once per `interval`. Each record is clamped to
///           `maxMoveTicks` from the previous one and is refused while the PoolManager is unlocked, so a free
///           in-unlock pump cannot be recorded and a paid pump moves one record by a bounded step.
///         - The first record has nothing to clamp against: it is refused inside an unlock and under `minLiquidity`,
///           and clamped to `seedTick` (the pool's opening price) within `maxMoveTicks` when the log has one.
///         - A record taken while the pool's in-range liquidity is under `minLiquidity` is marked thin; a mean that
///           weighs a thin record fails closed.
///         - Means are time-weighted over the step function of the records, and a record weighs nothing in a window
///           that ends when it is written: a pumped record counts only for the time it stands, until the next record
///           replaces it, at least one interval later.
///         - `meanFresh` also fails closed when any record weighing in the window stood longer than `maxStand`
///           seconds, so a reader can refuse a mean that one old or pumped record dominates because nobody recorded
///           after it.
///         Ticks are the pool's own (the price of currency0 in currency1); a reader whose subject is currency1 negates
///         them. The ring holds 64 records, and a reader's window may span at most `MAX_WINDOW_INTERVALS` intervals,
///         so a servable window always fits the ring.
contract HookrPriceLog {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @notice The parameters a log is opened with. Bounds are in `open`.
    struct Params {
        /// @notice The least time between two records.
        uint32 interval;
        /// @notice The most one record may move from the previous one.
        uint24 maxMoveTicks;
        /// @notice In-range liquidity under which a record is thin and the first record is refused.
        uint128 minLiquidity;
        /// @notice Whether the first record is clamped to `seedTick`. Without one, it is the spot when written.
        bool hasSeedTick;
        /// @notice The pool tick the first record is clamped to, within `maxMoveTicks`. Zero when `hasSeedTick` is false.
        int24 seedTick;
    }

    /// @notice One record. `tick` is the pool's tick, clamped against the previous record; `liquidity` is the pool's
    ///         in-range liquidity when recorded.
    struct Record {
        uint32 time;
        int24 tick;
        uint128 liquidity;
        bool thin;
    }

    /// @dev The header shares one slot (32 + 24 + 128 + 8 + 24 + 8 + 8 = 232 bits) so a read loads it once.
    struct Log {
        PoolId poolId;
        uint32 interval;
        uint24 maxMoveTicks;
        uint128 minLiquidity;
        bool hasSeedTick;
        int24 seedTick;
        uint8 head;
        uint8 count;
        Record[64] ring;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Constants: fixed, not knobs
    // ---------------------------------------------------------------------------------------------------------------

    uint256 public constant CAPACITY = 64;
    /// @notice The longest window a reader may ask to be served, in intervals: well inside the ring, so a log recorded
    ///         at its fastest pace still reaches back over it.
    uint32 public constant MAX_WINDOW_INTERVALS = 48;

    uint32 public constant MIN_INTERVAL = 60;
    uint32 public constant MAX_INTERVAL = 3600;
    uint24 public constant MIN_MOVE_TICKS = 10;
    uint24 public constant MAX_MOVE_TICKS = 5000;

    // ---------------------------------------------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------------------------------------------

    IPoolManager public immutable manager;

    mapping(bytes32 id => Log) internal logs;

    event Opened(bytes32 indexed id, PoolId indexed poolId, Params params);
    event Recorded(bytes32 indexed id, uint32 time, int24 spotTick, int24 recordedTick, uint128 liquidity, bool thin);

    error InvalidParams(bytes32 what);
    error UnknownLog(bytes32 id);
    error ManagerUnlocked();
    error PoolNotInitialized();
    error ThinStart();
    error InvalidWindow(uint32 window);
    error OutOfRange(uint256 back);

    constructor(IPoolManager manager_) {
        if (address(manager_).code.length == 0) revert InvalidParams("manager");
        manager = manager_;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Permissionless calls
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Opens the log of `poolId` with `p`, or finds it when it is already open. The pool need not exist yet:
    ///         a log opened before its pool is initialized takes its first record once the pool trades.
    function open(PoolId poolId, Params calldata p) external returns (bytes32 id) {
        _check(p);
        id = logId(poolId, p);
        Log storage l = logs[id];
        if (l.interval != 0) return id;
        l.poolId = poolId;
        l.interval = p.interval;
        l.maxMoveTicks = p.maxMoveTicks;
        l.minLiquidity = p.minLiquidity;
        l.hasSeedTick = p.hasSeedTick;
        l.seedTick = p.seedTick;
        emit Opened(id, poolId, p);
    }

    /// @notice Records the pool's price if `interval` has passed since the last record, or writes the first record.
    ///         Returns whether a record was written. Reverts while the PoolManager is unlocked when a record is due,
    ///         and on a first record of a pool not yet initialized or under `minLiquidity`.
    function record(bytes32 id) external returns (bool) {
        Log storage l = _log(id);
        uint8 n = l.count;
        if (n == 0) {
            _seed(id, l);
            return true;
        }
        uint8 head = l.head;
        Record memory last = l.ring[head];
        if (block.timestamp < uint256(last.time) + l.interval) return false;
        // Inside an unlock a pump is free until the unlock settles; refuse to record there.
        if (manager.isUnlocked()) revert ManagerUnlocked();

        (int24 spot, uint128 liquidity) = _observe(l.poolId);
        int24 recorded = _clamp(spot, last.tick, l.maxMoveTicks);
        bool thin = liquidity < l.minLiquidity;
        uint8 next = uint8((uint256(head) + 1) % CAPACITY);
        uint32 now32 = uint32(block.timestamp);
        l.ring[next] = Record(now32, recorded, liquidity, thin);
        l.head = next;
        if (n < CAPACITY) l.count = n + 1;
        emit Recorded(id, now32, spot, recorded, liquidity, thin);
        return true;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The id of the log of `poolId` with `p`. Only valid parameters can be opened.
    function logId(PoolId poolId, Params calldata p) public pure returns (bytes32) {
        return keccak256(abi.encode(poolId, p.interval, p.maxMoveTicks, p.minLiquidity, p.hasSeedTick, p.seedTick));
    }

    /// @notice Whether log `id` is open.
    function isOpen(bytes32 id) external view returns (bool) {
        return logs[id].interval != 0;
    }

    /// @notice The pool log `id` records.
    function poolOf(bytes32 id) external view returns (PoolId) {
        return _log(id).poolId;
    }

    /// @notice The frozen parameters of log `id`.
    function params(bytes32 id) external view returns (Params memory p) {
        Log storage l = _log(id);
        p = Params(l.interval, l.maxMoveTicks, l.minLiquidity, l.hasSeedTick, l.seedTick);
    }

    /// @notice How many records log `id` holds (at most CAPACITY).
    function count(bytes32 id) external view returns (uint256) {
        return logs[id].count;
    }

    /// @notice The newest record of log `id`. Reverts when it holds none.
    function latest(bytes32 id) external view returns (Record memory) {
        Log storage l = _log(id);
        if (l.count == 0) revert OutOfRange(0);
        return l.ring[l.head];
    }

    /// @notice The record `back` steps before the newest (0 = newest).
    function recordAt(bytes32 id, uint256 back) external view returns (Record memory) {
        Log storage l = _log(id);
        if (back >= l.count) revert OutOfRange(back);
        return l.ring[(uint256(l.head) + CAPACITY - back) % CAPACITY];
    }

    /// @notice Up to `n` of the newest records, newest first.
    function recent(bytes32 id, uint256 n) external view returns (Record[] memory out) {
        Log storage l = _log(id);
        uint256 c = l.count;
        if (n > c) n = c;
        out = new Record[](n);
        uint256 head = l.head;
        for (uint256 i; i < n; ++i) {
            out[i] = l.ring[(head + CAPACITY - i) % CAPACITY];
        }
    }

    /// @notice Whether a reader may ask log `id` for a `window`-second mean: at least one second and at most
    ///         `MAX_WINDOW_INTERVALS` intervals. A servable window can still fail closed (too little history, a thin
    ///         record); one that is not servable may not fit the ring.
    function servable(bytes32 id, uint32 window) public view returns (bool) {
        return window != 0 && uint256(window) <= uint256(_log(id).interval) * MAX_WINDOW_INTERVALS;
    }

    /// @notice The time-weighted mean pool tick over the `window` seconds ending now, and whether it is usable.
    function mean(bytes32 id, uint32 window) external view returns (bool ok, int24 tick) {
        return _mean(_log(id), window, block.timestamp, type(uint256).max);
    }

    /// @notice `mean`, failing closed when a record that weighs in the window stood (from its time until the next
    ///         record, or until now) longer than `maxStand` seconds.
    function meanFresh(bytes32 id, uint32 window, uint32 maxStand) external view returns (bool ok, int24 tick) {
        return _mean(_log(id), window, block.timestamp, maxStand);
    }

    /// @notice The time-weighted mean pool tick over the `window` seconds ending at `end` (not after now).
    function meanUntil(bytes32 id, uint32 window, uint32 end) external view returns (bool ok, int24 tick) {
        if (end > block.timestamp) return (false, 0);
        return _mean(_log(id), window, end, type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    function _seed(bytes32 id, Log storage l) internal {
        if (manager.isUnlocked()) revert ManagerUnlocked();
        (int24 spot, uint128 liquidity) = _observe(l.poolId);
        if (liquidity < l.minLiquidity) revert ThinStart();
        int24 tick = l.hasSeedTick ? _clamp(spot, l.seedTick, l.maxMoveTicks) : spot;
        uint32 now32 = uint32(block.timestamp);
        l.ring[0] = Record(now32, tick, liquidity, false);
        l.head = 0;
        l.count = 1;
        emit Recorded(id, now32, spot, tick, liquidity, false);
    }

    /// @dev The time-weighted mean of the records' step function over [end - window, end]. A record written at or after
    ///      `end` weighs nothing. Fails closed when the ring does not reach back to the window's start, a record that
    ///      carries weight in it is thin, or such a record stood longer than `maxStand` (until the next record or `end`).
    function _mean(Log storage l, uint32 window, uint256 end, uint256 maxStand)
        internal
        view
        returns (bool ok, int24 tick)
    {
        uint256 c = l.count;
        if (c == 0 || window == 0 || end < window) return (false, 0);
        if (uint256(window) > uint256(l.interval) * MAX_WINDOW_INTERVALS) return (false, 0);
        uint256 from = end - window;
        uint256 segEnd = end;
        uint256 head = l.head;
        int256 acc;
        for (uint256 i; i < c; ++i) {
            Record memory cp = l.ring[(head + CAPACITY - i) % CAPACITY];
            uint256 segStart = cp.time > from ? cp.time : from;
            if (segEnd > segStart) {
                if (cp.thin || segEnd - cp.time > maxStand) return (false, 0);
                acc += int256(cp.tick) * int256(segEnd - segStart);
            }
            if (cp.time <= from) return (true, int24(acc / int256(uint256(window))));
            if (cp.time < segEnd) segEnd = cp.time;
        }
        return (false, 0);
    }

    function _observe(PoolId poolId) internal view returns (int24 tick, uint128 liquidity) {
        uint160 sqrtPriceX96;
        (sqrtPriceX96, tick,,) = manager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        liquidity = manager.getLiquidity(poolId);
    }

    function _clamp(int24 spot, int24 anchor, uint24 maxMove) internal pure returns (int24) {
        int256 lo = int256(anchor) - int256(uint256(maxMove));
        int256 hi = int256(anchor) + int256(uint256(maxMove));
        int256 t = spot < lo ? lo : (spot > hi ? hi : int256(spot));
        if (t < TickMath.MIN_TICK) return TickMath.MIN_TICK;
        if (t > TickMath.MAX_TICK) return TickMath.MAX_TICK;
        return int24(t);
    }

    function _log(bytes32 id) internal view returns (Log storage l) {
        l = logs[id];
        if (l.interval == 0) revert UnknownLog(id);
    }

    function _check(Params calldata p) internal pure {
        if (p.interval < MIN_INTERVAL || p.interval > MAX_INTERVAL) revert InvalidParams("interval");
        if (p.maxMoveTicks < MIN_MOVE_TICKS || p.maxMoveTicks > MAX_MOVE_TICKS) revert InvalidParams("maxMoveTicks");
        if (p.minLiquidity == 0) revert InvalidParams("minLiquidity");
        if (p.hasSeedTick) {
            if (p.seedTick <= TickMath.MIN_TICK || p.seedTick >= TickMath.MAX_TICK) revert InvalidParams("seedTick");
        } else if (p.seedTick != 0) {
            revert InvalidParams("seedTick");
        }
    }
}
