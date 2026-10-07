// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Hookr revenue types
/// @notice Shared constants and structs of the Revenue Router: one frozen split of a fee stream into at most
///         eight payees, each with a role label and a basis-point weight, summing to exactly 10,000.
library HookrRevenueTypes {
    /// @notice Basis-point denominator; the weights of one split sum to exactly this.
    uint16 internal constant BPS = 10_000;
    /// @notice Fewest payees one split may name.
    uint8 internal constant MIN_RECIPIENTS = 1;
    /// @notice Most payees one split may name. Bounds the O(n^2) allocation loop of every deposit.
    uint8 internal constant MAX_RECIPIENTS = 8;
    /// @notice Payee count launch tooling proposes: the creator alone, before the creator adds anyone.
    uint8 internal constant DEFAULT_RECIPIENTS = 1;
    /// @notice Smallest weight one payee may hold.
    uint16 internal constant MIN_RECIPIENT_BPS = 1;
    /// @notice Largest weight one payee may hold (a single payee takes everything).
    uint16 internal constant MAX_RECIPIENT_BPS = BPS;
    /// @notice Weight launch tooling proposes for the creator's own payee in the default single-payee list.
    uint16 internal constant DEFAULT_RECIPIENT_BPS = BPS;

    /// @notice Role labels. They are public accounting labels, not permissions: a role never grants access.
    /// @dev STRATEGY is the only role with a behavioural difference: its account is pull-only, so a third party
    ///      can never push value into a strategy contract at a moment of the third party's choosing.
    enum Role {
        CREATOR,
        PROTOCOL,
        BUILDER,
        REFERRER,
        STRATEGY
    }

    /// @notice One payee: the account credited, its weight in basis points and its role label.
    /// @dev One (account, role) pair may appear once. One account may hold several roles; its claim is the sum.
    struct Recipient {
        address account;
        uint16 bps;
        Role role;
    }
}
