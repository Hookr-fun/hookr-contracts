// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {HookrSwapAccountingKernelV3} from "./HookrSwapAccountingKernelV3.sol";
import {HookrSwapKernelV3} from "./HookrSwapKernelV3.sol";
import {IHookrStackRegistryV1} from "./interfaces/IHookrStackRegistryV1.sol";

/// @title Hookr Modular Hook V6
/// @notice Stable Hookr root for immutable module stacks across multiple Uniswap v4 pools.
/// @dev Each PoolId retains its own frozen stack and accounting state. A new root deployment is
///      required only when the reviewed root implementation or sealed profile generation changes.
contract HookrModularHookV6 is HookrSwapKernelV3 {
    constructor(
        IPoolManager poolManager_,
        IHookrStackRegistryV1 stackRegistry_,
        address coordinator_,
        HookrSwapAccountingKernelV3 accountingKernel_
    ) HookrSwapKernelV3(poolManager_, stackRegistry_, coordinator_, accountingKernel_) {}

    function contractName() external pure override returns (string memory) {
        return "HookrModularHookV6";
    }

    function contractVersion() external pure override returns (string memory) {
        return "6.0.0";
    }
}
