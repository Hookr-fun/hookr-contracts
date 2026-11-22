// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IHookrPriceLog
/// @notice The part of HookrPriceLog (vendor/price-log) the match vault reads and calls.
interface IHookrPriceLog {
    /// @notice The parameters a log is opened with; frozen once opened.
    struct Params {
        uint32 interval;
        uint24 maxMoveTicks;
        uint128 minLiquidity;
        bool hasSeedTick;
        int24 seedTick;
    }

    /// @notice One record: the pool's tick, moved at most the log's step from the record before.
    struct Record {
        uint32 time;
        int24 tick;
        uint128 liquidity;
        bool thin;
    }

    /// @notice The PoolManager whose pools the log records.
    function manager() external view returns (IPoolManager);

    /// @notice Opens the log of `poolId` with `p`, or finds it when it is already open.
    function open(PoolId poolId, Params calldata p) external returns (bytes32 id);

    /// @notice Records the pool's price when a record is due; returns whether one was written.
    function record(bytes32 id) external returns (bool);

    /// @notice Whether log `id` is open.
    function isOpen(bytes32 id) external view returns (bool);

    /// @notice The pool log `id` records.
    function poolOf(bytes32 id) external view returns (PoolId);

    /// @notice The newest record of log `id`. Reverts when it holds none.
    function latest(bytes32 id) external view returns (Record memory);

    /// @notice The record `back` steps before the newest (0 = newest). Reverts past the oldest held.
    function recordAt(bytes32 id, uint256 back) external view returns (Record memory);

    /// @notice The frozen parameters of log `id`.
    function params(bytes32 id) external view returns (Params memory);

    /// @notice The time-weighted mean pool tick over `window` seconds ending now; fails closed (`ok` false) when the
    ///         log does not reach back that far, a weighing record is thin, or one stood longer than `maxStand`.
    function meanFresh(bytes32 id, uint32 window, uint32 maxStand) external view returns (bool ok, int24 tick);
}
