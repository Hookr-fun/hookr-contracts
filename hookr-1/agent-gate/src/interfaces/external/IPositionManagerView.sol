// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPositionManagerView
/// @notice The two reads the gate makes on Uniswap's v4 PositionManager (v4-periphery: BaseActionsRouter.msgSender,
///         ImmutableState.poolManager). The PositionManager sets a transient locker to its caller for the length of
///         `modifyLiquidities` / `modifyLiquiditiesWithoutLock` and reports it through `msgSender()`; outside a call
///         it answers zero. The same contract on Robinhood Chain 4663 (0x58daec3116aae6D93017bAAea7749052E8a04fA7) and
///         Ethereum (0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e), each pinned by code hash at construction.
interface IPositionManagerView {
    /// @notice The wallet whose `modifyLiquidities` call is running, or zero.
    function msgSender() external view returns (address);
    /// @notice The PoolManager it modifies positions on.
    function poolManager() external view returns (address);
}
