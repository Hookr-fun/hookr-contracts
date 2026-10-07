// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrFeeRouteRegistry} from "./IHookrFeeRouteRegistry.sol";

/// @title Hookr stray sweep
/// @notice Returns assets sent by mistake to a directional-tax contract. Only the route registry named by the contract
///         may call, and the registry runs it only for its owner after a queued, disclosed SWEEP_STRAY has waited the
///         owner timelock. A sweep never moves accrued tax, a booked share or a Rules claim: a tax queue refuses its
///         own quote asset (unbooked quote is income at the next settle), and a queue's sweep reverts if its quote
///         balance changes.
interface IHookrStraySweep {
    /// @notice Emitted when `amount` of stray `asset` leaves for `to`.
    event StraySwept(address indexed asset, address indexed to, uint256 amount);

    /// @notice The caller is not the route registry this contract names.
    error StraySweepUnauthorized(address caller);
    /// @notice The asset is the tax asset.
    error NotStray(address asset);
    /// @notice Moving the asset moved the tax asset too (for example a second entry point of the same token).
    error SweepMovedQuote(address asset);
    /// @notice Zero amount, zero destination, or more than the contract holds.
    error InvalidStraySweep(address asset, uint256 amount, uint256 held);

    /// @notice The route registry whose owner may sweep strays here.
    function routeRegistry() external view returns (IHookrFeeRouteRegistry);

    /// @notice Sends `amount` of stray `asset` (zero is native ETH) to `to`. Route registry only.
    function sweepStray(address asset, uint256 amount, address to) external;
}
