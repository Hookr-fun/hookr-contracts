// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HookrSessionTiers} from "hookr/libraries/HookrSessionTiers.sol";

/// @title Zap relay session fee
/// @notice The off-market LP-fee surcharge both zap-relay advisories add to a pool that bound session tiers.
/// @dev The session is read from the shared calendar (a HookrSessionAdvisory) with HookrSessionTiers.valueAt, a bounded
///      static call that never reverts. A failed or malformed read (including a regular session at or past its own
///      close, which HookrSessionTiers.read refuses) charges HookrSessionTiers.highest, so starving the read can never
///      lower the fee. The result is clamped to the limit frozen at bind, the advisory's admitted LP-fee cap.
library ZapSessionFee {
    /// @notice Surcharge in pips for the current block timestamp, never above `limit`. Never reverts.
    /// @param tiers The pool's frozen tiers.
    /// @param calendar The shared calendar fixed at the advisory's construction.
    /// @param limit The advisory's admitted LP-fee cap, frozen at bind.
    function surcharge(HookrSessionTiers.Tiers memory tiers, address calendar, uint256 limit)
        internal
        view
        returns (uint24)
    {
        uint256 pips = HookrSessionTiers.valueAt(tiers, calendar, block.timestamp);
        // pips <= limit <= type(uint24).max after the clamp.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(pips < limit ? pips : limit);
    }
}
