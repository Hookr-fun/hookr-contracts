// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IHookrPairAdvisory
/// @notice Optional fee advice for one Hookr pair root. The root binds its pool once, when the pool opens, and then
///         calls `surchargeForSwap` with STATICCALL under a fixed gas cap on every swap.
/// @dev The root clamps the result to its immutable advisory cap. A revert, a return that is not exactly one word,
///      or a word above uint24 counts as a failure: the root then charges the cap (fail-open) or reverts the swap.
interface IHookrPairAdvisory {
    /// @notice Binds the calling root's pool with the deployer's parameters. The root calls it once, from `open`,
    ///         before it initializes the pool; a revert or any other return aborts the deployment.
    /// @dev An advisory keeps the binding under the caller, refuses a second binding of the same pool, and refuses
    ///      parameters under which a later `surchargeForSwap` for the pool could exceed `capPips`, need more than
    ///      `gasLimit` gas or revert.
    /// @param id The caller's pool.
    /// @param capPips The caller's immutable surcharge cap.
    /// @param gasLimit The gas the caller forwards to `surchargeForSwap`.
    /// @param data The advisory's parameters for the pool, supplied by the root's deployer.
    /// @return This function's selector.
    function bindPair(PoolId id, uint24 capPips, uint32 gasLimit, bytes calldata data) external returns (bytes4);

    /// @notice Returns the LP fee surcharge in pips added to the pool's base fee for this swap.
    /// @dev Reverts for a pool the caller has not bound.
    ///      The name and argument order give this function a selector (0x00014e05) below every other external
    ///      function of both Hookr advisories, so their dispatchers match it first.
    /// @param id The pool being swapped.
    /// @param zeroForOne The swap direction.
    /// @param amountSpecified Negative for exact input, positive for exact output.
    /// @param sqrtPriceLimitX96 The swap's price limit.
    /// @param hookData The swap's hook data, unmodified.
    /// @param sender The PoolManager caller (the router), as reported by the PoolManager.
    /// @return surchargePips The LP fee surcharge in pips, which the root clamps to its advisory cap.
    function surchargeForSwap(
        PoolId id,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData,
        address sender
    ) external view returns (uint24 surchargePips);
}
