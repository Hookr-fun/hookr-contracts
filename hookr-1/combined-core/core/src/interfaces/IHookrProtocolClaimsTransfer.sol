// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHookrProtocolClaimsTransfer
/// @notice The ERC-6909 exit of a claims source whose claims are backed by PoolManager ERC-6909 balances.
interface IHookrProtocolClaimsTransfer {
    /// @notice Pay the caller's whole claim to a destination as PoolManager ERC-6909 claims and report the amount.
    /// @param currency The claimed currency.
    /// @param to The destination of the ERC-6909 claims.
    /// @return The amount paid.
    function claimAsClaims(Currency currency, address to) external returns (uint256);
}
