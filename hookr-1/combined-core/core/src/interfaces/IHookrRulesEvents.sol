// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHookrRulesEvents
/// @notice The events and errors HookrRules and its arb recapture module HookrRecapture share: the module raises them
///         at the Rules' address, so both inherit this one declaration.
interface IHookrRulesEvents {
    /// @notice The caller may not do this.
    error Unauthorized();
    /// @notice The pool's configuration is invalid.
    error InvalidConfig();
    /// @notice The pool is not bound.
    error UnknownPool();
    /// @notice The settlement is inconsistent with the swap or does not back the Rules' liabilities.
    error InvalidSettlement();

    /// @notice Emitted by HookrRules for a swap's settlement and by HookrRecapture for an executor leg's advisory take
    ///         (`settleLeg`).
    /// @param id The pool.
    /// @param quote The pool's quote currency.
    /// @param protocol The protocol's share.
    /// @param royalty The royalty credited.
    /// @param refund The refund credited to the payer.
    /// @param advisoryRecipient The advisory's recipient.
    /// @param advisoryFee The fee credited to the advisory's recipient.
    event FeesAllocated(
        PoolId indexed id,
        Currency indexed quote,
        uint256 protocol,
        uint256 royalty,
        uint256 refund,
        address advisoryRecipient,
        uint256 advisoryFee
    );
}
