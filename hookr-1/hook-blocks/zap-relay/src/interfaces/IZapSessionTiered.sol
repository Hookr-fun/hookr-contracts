// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrSessionTiers} from "hookr/libraries/HookrSessionTiers.sol";

/// @title Session-tiered zap relay advisory
/// @notice Optional off-market LP-fee tiers a pool of either zap-relay advisory can bind. The session is read from a
///         shared calendar (a HookrSessionAdvisory) fixed at construction. Empty tiers mean no surcharge.
interface IZapSessionTiered {
    /// @notice A pool bound non-empty session tiers; `limit` is the advisory's admitted LP-fee cap at bind.
    event SessionTiersBound(address indexed binder, PoolId indexed id, HookrSessionTiers.Tiers tiers, uint24 limit);

    /// @notice The shared calendar every tiered pool reads (`sessionAt(uint256)`).
    function calendar() external view returns (address);

    /// @notice The frozen session tiers a binder (the root) stored for a pool, and the cap they are clamped to.
    function sessionTiers(address binder, PoolId id)
        external
        view
        returns (bool tiered, uint24 limit, HookrSessionTiers.Tiers memory tiers);
}
