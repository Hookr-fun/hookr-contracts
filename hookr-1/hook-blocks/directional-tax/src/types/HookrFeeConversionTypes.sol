// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Hookr fee conversion types
/// @notice Shared shapes for the asynchronous tax-conversion sidecar: the fee-route registry, its authorizer and its
///         executor.
library HookrFeeConversionTypes {
    /// @notice Lifecycle of a conversion route. Routes are never edited; they are registered once and retired once.
    enum RouteStatus {
        NONE,
        ACTIVE,
        RETIRED
    }

    /// @notice One owner-registered conversion path. Native ETH is the zero address.
    /// @dev `routeDataHash` freezes every byte the adapter will read (for the v4 adapter, the PoolKey), so a
    ///      signer can choose only the amount, the minimum output and the expiry of a conversion.
    struct Route {
        address tokenIn;
        address tokenOut;
        address adapter;
        bytes32 adapterCodeHash;
        bytes32 routeDataHash;
        RouteStatus status;
        uint40 retiredAt;
    }

    /// @notice A signed, single-use conversion instruction for one queue.
    /// @dev `maxBlock` reads the contract's `block.number` clock. On Robinhood Chain (Nitro) that is the parent
    ///      chain height, not the L2 height a fork shows, so signers must set it as a window relative to it.
    ///      `caller` is the only account that may run the plan through its strategy, or zero for anyone. The
    ///      executor signs it and the strategy enforces it, so a signer that names a keeper stops anyone else who
    ///      learns the plan (from a failed transaction's calldata, say) from running it inside a price move of
    ///      their own.
    struct ExecutionPlan {
        bytes32 routeId;
        address strategy;
        uint128 amountIn;
        uint128 minAmountOut;
        uint64 maxBlock;
        uint64 deadline;
        uint64 nonce;
        bytes32 routeDataHash;
        address caller;
    }
}
