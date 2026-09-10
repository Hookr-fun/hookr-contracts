// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HookrModuleTypesV1} from "../libraries/HookrModuleTypesV1.sol";

/// @title Hookr Stack Registry V1
/// @notice Read boundary consumed by a SWAP_DELTA_V1 kernel after a coordinator freezes a stack.
interface IHookrStackRegistryV1 {
    function stack(PoolId poolId) external view returns (HookrModuleTypesV1.StackCore memory core);

    function moduleAt(PoolId poolId, uint256 index)
        external
        view
        returns (HookrModuleTypesV1.ModuleSnapshot memory module, bytes memory config);

    /// @notice Marks a prepared stack initialized. Callable only by its exact frozen kernel.
    function markInitialized(PoolId poolId) external;
}
