// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHookrFamilyRelease
/// @notice Hands one released family from HookrFamilyLock to the owner its beneficiary chose, and passes the fees the
///         family earns until then to the beneficiary.
interface IHookrFamilyRelease {
    /// @notice `caller` may not call this.
    error NotAllowed(address caller);
    /// @notice A new owner of zero or this release.
    error InvalidNewOwner(address newOwner);

    /// @notice The lock that created this release.
    /// @return The lock.
    function lock() external view returns (address);

    /// @notice The family this release hands over.
    /// @return The family.
    function familyId() external view returns (bytes32);

    /// @notice The beneficiary every fee this release receives goes to.
    /// @return The beneficiary.
    function beneficiary() external view returns (address);

    /// @notice The lock accepts the family into this release.
    function accept() external;

    /// @notice The lock, or later the beneficiary, starts or re-targets the transfer of the family to `newOwner`, the
    ///         family's fees until acceptance paid to this release as ERC-6909 claims.
    /// @param newOwner The owner the transfer names: not zero or this release.
    function transferTo(address newOwner) external;

    /// @notice Sends this release's whole PoolManager ERC-6909 balance of `currency` to the beneficiary. Anyone may
    ///         call.
    /// @param currency The currency whose ERC-6909 claims are sent.
    /// @return amount The amount sent.
    function sweep(Currency currency) external returns (uint256 amount);
}
