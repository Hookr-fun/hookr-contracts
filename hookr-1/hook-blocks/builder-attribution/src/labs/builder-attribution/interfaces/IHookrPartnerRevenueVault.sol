// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Per-pool revenue vault surface the registry checks before it records an attribution
interface IHookrPartnerRevenueVault {
    /// @notice The attributed pool.
    function poolId() external view returns (bytes32);

    /// @notice The root of the attributed pool.
    function root() external view returns (address);

    /// @notice The launcher that deployed the vault.
    function launcher() external view returns (address);

    /// @notice The attributed partner, or zero.
    function partnerId() external view returns (bytes32);

    /// @notice The frozen partner share.
    function partnerShareBps() external view returns (uint16);

    /// @notice The current payee of a role.
    function beneficiary(uint8 role) external view returns (address);
}
