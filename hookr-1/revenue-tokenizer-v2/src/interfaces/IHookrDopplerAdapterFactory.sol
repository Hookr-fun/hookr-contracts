// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title Hookr Doppler adapter factory, part of the HookRevenue Tokenizer
/// @notice Makes Doppler adapters at predictable addresses, before the revenue token adds them, for the launches of
///         one launch platform (Long's). The app labels an adapter this deployed factory made as verified; any other
///         IHookrRevenueSource, and any adapter of another factory, is unverified.
/// @dev Five checks before an adapter is made: neither of the pool's currencies is the revenue token; the adapter's
///      predicted address holds no share of the launch yet; the caller holds a share of the launch now; the launch's
///      integrator in the Airlock is the factory's `integrator`; and a collection of the pool fits in
///      `COLLECT_CHECK_GAS` (measured inside a call that is always undone, so the check books no fees and fees earned
///      before the bind still reach the adapter's first pull). The caller becomes the adapter's `origin`, and
///      `originShares` is its own share alone. The address depends on the origin, the revenue token and the launch
///      token, so each holder makes an adapter of its own. No owner. Two pins: the Doppler hook initializer and the
///      integrator.
///
///      The order is: `create` while holding the share, then move the share to the adapter
///      (`updateBeneficiary(poolId, adapter)`, the holder's own call). A share moved to an address before `create` put
///      an adapter there is refused (`ShareMovedBeforeCreate`) and stays at an address with no code for good, since
///      only its holder's own call moves a Doppler share. Another beneficiary of the same launch can cause that
///      refusal too: `predict` is public and Doppler's `updateBeneficiary` lets any holder move its own share to any
///      address, so it can park its share at your predicted address first (that share is then lost there for good).
///      Move your share to a fresh address and call `create` from it: the address binds the origin, so a fresh
///      origin's adapter is at a new address. Once bound, `abort` brings the share back only when it is
///      more than half of the launch (IHookrDopplerAdapter); a smaller share (Long's creator holds 47.5%) has no way
///      back, so bind and add it in one batched transaction (`updateBeneficiary`, then `tokenize` at the mint or
///      `addStreams`), where a failed add undoes the bind.
interface IHookrDopplerAdapterFactory {
    /// @notice An adapter was made for `launchToken`'s fee share, paying `revenueToken`, by `origin`.
    event AdapterCreated(
        address indexed adapter, address indexed revenueToken, address indexed launchToken, address origin
    );

    /// @notice A pin has no code or is zero.
    error InvalidConfig();
    /// @notice The launch's numeraire or launch token is the revenue token itself, which no collection could ever pay
    ///         into the adapter.
    error PairIsRevenueToken();
    /// @notice `caller` holds no share of `launchToken`'s fees.
    error NotBeneficiary(address caller, address launchToken);
    /// @notice `adapter`, the address `create` would make, already holds a share of the launch: a share moved there
    ///         before `create` (by the caller or by another holder). Make the adapter first, then move the share.
    error ShareMovedBeforeCreate(address adapter);
    /// @notice The launch was made under `integrator`, not this factory's.
    error IntegratorNotAllowed(address integrator);
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
    /// @notice Makes the adapter for the caller's share of `launchToken`, paying `revenueToken`. The caller must still
    ///         hold its share (`NotBeneficiary`) and `predict(caller, revenueToken, launchToken)` must hold none
    ///         (`ShareMovedBeforeCreate`): never move the share before this call, since a `create` that then refuses
    ///         would leave it at an address with no code for good. Move it to the returned adapter afterwards. Another
    ///         beneficiary of the launch that parks its own share at that address makes this refuse as well; then
    ///         move your share to a fresh address and call from there.
    function create(address revenueToken, address launchToken) external returns (address adapter);
    /// @notice Runs one `collectFees(pool)` with `COLLECT_CHECK_GAS` and always reverts: `CollectFits` when the
    ///         collection went through, the collection's own failure otherwise. Anyone may call; nothing is kept.
    function checkCollect(PoolId pool) external;
    /// @notice The address `create(revenueToken, launchToken)` gives when `origin` calls it. For reading only: no share
    ///         may be moved there before `create`.
    function predict(address origin, address revenueToken, address launchToken) external view returns (address);
}
