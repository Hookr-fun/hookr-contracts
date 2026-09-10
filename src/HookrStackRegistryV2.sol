// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {HookrModuleCatalogV1} from "./HookrModuleCatalogV1.sol";
import {HookrStackRegistryV1} from "./HookrStackRegistryV1.sol";

/// @title Hookr Stack Registry V2
/// @notice Registry for immutable per-pool stacks admitted under a sealed shared-root profile.
contract HookrStackRegistryV2 is HookrStackRegistryV1 {
    constructor(address owner_, IPoolManager poolManager_, HookrModuleCatalogV1 moduleCatalog_)
        HookrStackRegistryV1(owner_, poolManager_, moduleCatalog_)
    {}

    function contractName() external pure override returns (string memory) {
        return "HookrStackRegistryV2";
    }

    function contractVersion() external pure override returns (string memory) {
        return "2.1.0";
    }

    function stableRootProfilesRequired() public pure override returns (bool) {
        return true;
    }

    /// @notice V2 serves many PoolIds from sealed shared roots and has no per-market kernel lane.
    function exceptionalKernelInstancesSupported() public pure override returns (bool) {
        return false;
    }

    function registerKernelInstanceFactory(address) external pure override {
        revert ExceptionalKernelInstancesDisabled(bytes32(0));
    }

    function retireKernelInstanceFactory(address) external pure override {
        revert ExceptionalKernelInstancesDisabled(bytes32(0));
    }

    function kernelInstanceFactory(address) external pure override returns (KernelInstanceFactorySnapshot memory) {
        revert ExceptionalKernelInstancesDisabled(bytes32(0));
    }

    function kernelInstanceFactoryFor(bytes32) external pure override returns (address) {
        return address(0);
    }

    function registerKernelInstance(address) external pure override returns (bytes32) {
        revert ExceptionalKernelInstancesDisabled(bytes32(0));
    }
}
