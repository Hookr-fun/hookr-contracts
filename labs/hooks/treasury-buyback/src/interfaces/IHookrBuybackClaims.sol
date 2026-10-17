// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHookrBuybackClaims
/// @notice The slice of a Hookr Rules module this contract needs: paying out a claim credited to it.
interface IHookrBuybackClaims {
    function claimTo(Currency currency, address to) external returns (uint256);
}
