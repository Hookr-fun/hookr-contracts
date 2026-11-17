// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";

/// @title IHookrDynamicFeeRules
/// @notice Optional Rules extension for pools that charge Hookr dynamic fees. A root that simulates swaps (HookrRoot:
///         its fallback returns 1 when called with no data) reads `poolHasDynamicFee` once at binding; for those pools it
///         simulates each swap and quotes it through `quoteSimulatedSwap` instead of `IHookrRules.beforeSwap`.
interface IHookrDynamicFeeRules {
    /// @notice Returns whether swaps in the pool pay a dynamic fee.
    /// @param id The pool.
    /// @return True when swaps in the pool pay a dynamic fee.
    function poolHasDynamicFee(PoolId id) external view returns (bool);

    /// @notice Quotes the charges the root applies to the simulated swap: every native rule except the dynamic fee.
    /// @dev An exact-output sell also carries the largest protocol share its dynamic fee can take, so the simulated
    ///      output is at least the pool's real output.
    /// @param context The swap's authenticated context.
    /// @return The charges the root applies to the simulated swap, without the dynamic fee.
    function simulationQuote(HookrTypes.SwapContext calldata context) external view returns (HookrTypes.FeeQuote memory);

    /// @notice Quotes the native rules with the dynamic fee priced on the simulated swap, and records the pool's
    ///         dynamic fee state. The same swap's `IHookrRules.settleSwap` completes that record from the executed
    ///         price.
    /// @param context The swap's authenticated context.
    /// @param simulation The swap's simulated start and end prices.
    /// @return The charges the Rules quote, with the dynamic fee priced on the simulated swap.
    function quoteSimulatedSwap(HookrTypes.SwapContext calldata context, HookrTypes.SwapSimulation calldata simulation)
        external
        returns (HookrTypes.FeeQuote memory);
}
