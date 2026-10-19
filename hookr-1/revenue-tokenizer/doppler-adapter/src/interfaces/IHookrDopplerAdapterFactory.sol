// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title Hookr Doppler adapter factory, part of the HookRevenue Tokenizer
/// @notice Makes Doppler adapters at predictable addresses, before the revenue token exists, for the launches of one
///         launchpad. The app labels an adapter this deployed factory made as verified; any other
///         IHookrRevenueSource, and any adapter of another factory, is unverified.
/// @dev Three checks before an adapter is made: the caller (or the adapter's own predicted address) holds a share
///      of the launch now; the launch's integrator in the Airlock is the factory's `integrator`; and a collection of
///      the pool fits in `COLLECT_CHECK_GAS` (measured inside a call that is always undone, so the check books no
///      fees and fees earned before the bind still reach the adapter's first pull). The caller becomes the
///      adapter's `origin`. The address depends on the origin, the revenue token and the launch token, so each
///      holder makes an adapter of its own. No owner. Two pins: the Doppler hook initializer and the integrator.
interface IHookrDopplerAdapterFactory {
    /// @notice An adapter was made for `launchToken`'s fee share, paying `revenueToken`, by `origin`.
    event AdapterCreated(
        address indexed adapter, address indexed revenueToken, address indexed launchToken, address origin
    );

    /// @notice A pin has no code or is zero.
    error InvalidConfig();
    /// @notice Neither `caller` nor its predicted adapter holds a share of `launchToken`'s fees.
    error NotBeneficiary(address caller, address launchToken);
    /// @notice The launch was made under `integrator`, not this factory's.
    error LaunchpadNotAllowed(address integrator);
    /// @notice A collection of the launch's pool did not fit in `COLLECT_CHECK_GAS` (too many curve positions), so
    ///         the adapter could never collect it.
    error CollectTooHeavy();
    /// @notice `checkCollect`'s answer when the collection fit; it always reverts, so nothing it did is kept.
    error CollectFits();

    /// @notice Gas a collection of the pool must fit in at `create`: 1,000,000, the adapter's `COLLECT_GAS` less
    ///         500,000 kept for Doppler's two payouts.
    function COLLECT_CHECK_GAS() external view returns (uint256);
    /// @notice The Doppler hook initializer every adapter collects from.
    function initializer() external view returns (address);
    /// @notice The only integrator whose launches get an adapter (Long's, for the Long factory).
    function integrator() external view returns (address);
    /// @notice True for every adapter this factory made.
    function isAdapter(address adapter) external view returns (bool);
    /// @notice Makes the adapter for the caller's share of `launchToken`, paying `revenueToken`. The caller holds
    ///         the share, or already moved it to `predict(caller, revenueToken, launchToken)`.
    function create(address revenueToken, address launchToken) external returns (address adapter);
    /// @notice Runs one `collectFees(pool)` with `COLLECT_CHECK_GAS` and always reverts: `CollectFits` when the
    ///         collection went through, the collection's own failure otherwise. Anyone may call; nothing is kept.
    function checkCollect(PoolId pool) external;
    /// @notice The address `create(revenueToken, launchToken)` gives when `origin` calls it.
    function predict(address origin, address revenueToken, address launchToken) external view returns (address);
}
