// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HookrRevenueTypes} from "../interfaces/HookrRevenueTypes.sol";
import {IHookrRevenueSplit} from "../interfaces/IHookrRevenueSplit.sol";

/// @title Hookr revenue config
/// @notice Validation and commitment of one split's payee list. Shared by the split constructor and the router's
///         `predict`, so an address the router predicts can always be deployed.
library HookrRevenueConfig {
    /// @notice The commitment a split address is derived from.
    function id(bytes32 tag, HookrRevenueTypes.Recipient[] memory recipients) internal pure returns (bytes32) {
        return keccak256(abi.encode(tag, recipients));
    }

    /// @notice Refuses a list outside [MIN_RECIPIENTS, MAX_RECIPIENTS], a zero or self-referential account, a weight
    ///         outside [MIN_RECIPIENT_BPS, MAX_RECIPIENT_BPS], a repeated (account, role) pair, and weights that do not
    ///         sum to exactly 10,000 bps.
    /// @param split The split's own address: a split can never be its own payee (its share would be unclaimable).
    /// @param forbidden A further address that can never claim (the router), or zero.
    function validate(HookrRevenueTypes.Recipient[] memory recipients, address split, address forbidden) internal pure {
        uint256 count = recipients.length;
        if (count < HookrRevenueTypes.MIN_RECIPIENTS || count > HookrRevenueTypes.MAX_RECIPIENTS) {
            revert IHookrRevenueSplit.InvalidRecipients();
        }
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            HookrRevenueTypes.Recipient memory r = recipients[i];
            if (
                r.account == address(0) || r.account == split || r.account == forbidden
                    || r.bps < HookrRevenueTypes.MIN_RECIPIENT_BPS || r.bps > HookrRevenueTypes.MAX_RECIPIENT_BPS
            ) {
                revert IHookrRevenueSplit.InvalidRecipients();
            }
            for (uint256 j; j < i; ++j) {
                if (recipients[j].account == r.account && recipients[j].role == r.role) {
                    revert IHookrRevenueSplit.DuplicateRecipient(r.account, r.role);
                }
            }
            sum += r.bps;
        }
        if (sum != HookrRevenueTypes.BPS) revert IHookrRevenueSplit.InvalidRecipients();
    }
}
