// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Common launch boundary for a hook family supported by Hookr.
/// @dev Every registered hook must use Hookr's dynamic-fee, tick-spacing-60 pool shape. The
///      hook owns decoding and validation of its immutable per-pool configuration. Validation at
///      token creation prevents a curve from carrying a config that can only fail at graduation.
interface IHookrLaunchHook {
    function REQUIRED_FLAGS() external view returns (uint160);
    function poolManager() external view returns (IPoolManager);
    function launchpad() external view returns (address);
    function validateHookConfig(bytes calldata config) external view;
    function configurePool(PoolKey calldata key, bytes calldata config) external;
    function syncBaseFee(PoolKey calldata key) external;
}
