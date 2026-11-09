// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHookrRootRoute
/// @notice Narrow per-pool reads for relayers and routers. Implemented by HookrRoot; other roots may omit it, so
///         callers fall back to `IHookrRoot.poolConfig`.
interface IHookrRootRoute {
    /// @notice Returns the quote currency and the advisory (zero if none) of an initialized Hookr pool.
    /// @param id The pool.
    /// @return quote The pool's quote currency.
    /// @return advisory The pool's advisory, or zero.
    function poolRoute(PoolId id) external view returns (Currency quote, address advisory);

    /// @notice Returns the block from which swaps on an initialized pool skip the Rules module. Zero means never.
    /// @dev From that block a swap charges only the base LP fee plus any advisory LP surcharge: no quote take, burn,
    ///      refund or HookFee event.
    /// @param id The pool.
    /// @return The first block of swaps that skip the Rules, or zero for never.
    function feeOnlyFrom(PoolId id) external view returns (uint256);
}
