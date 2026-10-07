// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Permit2 allowance surface
interface IPermit2Allowance {
    /// @notice Sets `spender`'s allowance over the caller's `token`, bounded by `amount` and `expiration`.
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;

    /// @notice Returns `spender`'s allowance over `owner`'s `token`.
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}
