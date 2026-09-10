// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Hookr Claim Sink V1
/// @notice Typed sink for quote-currency ERC-6909 claims minted by a Hookr kernel.
interface IHookrClaimSinkV1 {
    /// @notice Whether the sink can safely accept this additional claim liability now.
    /// @dev False makes the kernel skip this module's new accrual; it must not break the base swap.
    function canCredit(uint256 amount) external view returns (bool);

    /// @notice Accounts claims already minted to this sink by its immutable kernel.
    function creditClaims(uint256 amount) external;
}
