// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title IRegistryPoolManager
/// @dev HookrRegistry exposes its PoolManager; the phase-one interface does not declare it.
interface IRegistryPoolManager {
    function poolManager() external view returns (IPoolManager);
}
