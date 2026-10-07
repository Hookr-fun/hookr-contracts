// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Hookr revenue source
/// @notice The two calls a split needs from a claims ledger. `HookrRules` (phase one) satisfies it unchanged, and so
///         does `HookrRevenueSplit` itself, so a split can be a payee of another split.
/// @dev `claim` must pay the caller's own claim to the caller.
interface IHookrRevenueSource {
    /// @notice The beneficiary's backed claim in raw currency units.
    function claimable(Currency currency, address beneficiary) external view returns (uint256);

    /// @notice Pays the caller's claim to the caller and returns the amount paid.
    function claim(Currency currency) external returns (uint256);
}
