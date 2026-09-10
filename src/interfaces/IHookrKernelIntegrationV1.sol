// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IHookrStackRegistryV1} from "./IHookrStackRegistryV1.sol";

/// @title Hookr Kernel Integration V1
/// @notice Typed immutable wiring exposed by reviewed routers and quoters admitted to a stack registry.
interface IHookrKernelIntegrationV1 {
    function integrationKind() external view returns (bytes32);

    function integrationFamilyId() external view returns (bytes32);

    function integrationVersion() external view returns (uint32);

    function poolManager() external view returns (IPoolManager);

    function stackRegistry() external view returns (IHookrStackRegistryV1);
}
