// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title ICanonicalVenueRulesClaims
/// @dev The two HookrRules claim functions the recapture pass-through uses.
interface ICanonicalVenueRulesClaims {
    function claimable(Currency currency, address beneficiary) external view returns (uint256);
    function claimAsClaims(Currency currency, address to) external returns (uint256);
}
