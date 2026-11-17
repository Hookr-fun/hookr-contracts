// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHookrProtocolClaims
/// @notice The claims surface consumed by the Hookr treasury.
interface IHookrProtocolClaims {
    /// @notice Return the recipient of protocol-owned fee allocations.
    /// @return The recipient of protocol-owned allocations.
    function protocolRecipient() external view returns (address);

    /// @notice Return the PoolManager that backs the source's claims.
    /// @return The PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice Return the account's unpaid claim in the given currency.
    /// @param currency The currency.
    /// @param account The account.
    /// @return The account's unpaid claim in the currency.
    function claimable(Currency currency, address account) external view returns (uint256);

    /// @notice Pay the caller's claim to a destination and report the amount paid.
    /// @param currency The currency.
    /// @param to The destination.
    /// @return The amount paid.
    function claimTo(Currency currency, address to) external returns (uint256);
}
