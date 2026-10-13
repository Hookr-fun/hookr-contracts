// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPermit2
/// @notice The one function of Uniswap's Permit2 the bench calls.
interface IPermit2 {
    /// @notice Lets `spender` pull up to `amount` of `token` from the caller until `expiration`.
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}
