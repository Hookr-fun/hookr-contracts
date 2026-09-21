// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {HookrSwapAccountingKernelV3} from "./HookrSwapAccountingKernelV3.sol";
import {HookrSwapKernelV5Wth} from "./HookrSwapKernelV5Wth.sol";
import {IHookrStackRegistryV1} from "./interfaces/IHookrStackRegistryV1.sol";

/// @title Hookr Modular Hook V6 WTH V5
/// @notice Root hook for pools on the always-on WTH arbitrage-recapture profile.
/// @dev Same shape and constructor as HookrModularHookV6, and it shares that root's accounting
///      implementation, registry, coordinator and hook flags. The only difference is the swap
///      kernel: HookrSwapKernelV5Wth runs the correction for every caller, lets the correction
///      plan be optional, sizes a beforeSwap correction from a quote-denominated swap instead of
///      skipping it, and refuses a swap that is closing an arbitrage leg inside a v3 callback.
///      A pool picks this profile by being opened against this root's kernel id; the standard
///      root is untouched and behaves exactly as it does today.
contract HookrModularHookV6WthV5 is HookrSwapKernelV5Wth {
    constructor(
        IPoolManager poolManager_,
        IHookrStackRegistryV1 stackRegistry_,
        address coordinator_,
        HookrSwapAccountingKernelV3 accountingKernel_
    ) HookrSwapKernelV5Wth(poolManager_, stackRegistry_, coordinator_, accountingKernel_) {}

    function contractName() external pure override returns (string memory) {
        return "HookrModularHookV6WthV5";
    }

    function contractVersion() external pure override returns (string memory) {
        return "6.0.0";
    }
}
