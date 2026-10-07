// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrSessionTiers} from "hookr/libraries/HookrSessionTiers.sol";
import {ZapSessionFee} from "./libraries/ZapSessionFee.sol";

/// @title Zap relay session lens
/// @notice Stateless helper that returns a pool's off-market session surcharge from its frozen tiers, read from the
///         shared calendar fixed at construction. HookrZapAccrual deploys its own lens in its constructor, so the
///         lens address is an immutable of the accrual's admitted runtime code and its code comes from the accrual's
///         creation code.
/// @dev Keeps the session read out of HookrZapAccrual's runtime (it was split out when the accrual still embedded the
///      zap vault's creation code, which now lives in ZapVaultDeployer). Never reverts on a calendar failure:
///      ZapSessionFee charges the highest tier then.
contract ZapSessionLens {
    /// @notice The shared session calendar (a HookrSessionAdvisory).
    address public immutable calendar;

    /// @param calendar_ The shared session calendar.
    constructor(address calendar_) {
        calendar = calendar_;
    }

    /// @notice The surcharge in pips for `tiers` at the current block timestamp, never above `limit`.
    /// @param tiers A pool's frozen session tiers.
    /// @param limit The calling advisory's admitted LP-fee cap, frozen at bind.
    function surcharge(HookrSessionTiers.Tiers calldata tiers, uint256 limit) external view returns (uint24) {
        return ZapSessionFee.surcharge(tiers, calendar, limit);
    }
}
