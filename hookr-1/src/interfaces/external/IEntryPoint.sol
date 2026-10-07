// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEntryPoint
/// @notice Minimal ERC-4337 v0.7 EntryPoint surface used by the Hookr paymaster (stake and deposit manager).
interface IEntryPoint {
    /// @notice Adds msg.value to the deposit of `account`.
    function depositTo(address account) external payable;
    /// @notice Withdraws from the caller's deposit.
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external;
    /// @notice Adds msg.value to the caller's stake and sets its unstake delay.
    function addStake(uint32 unstakeDelaySec) external payable;
    /// @notice Starts the caller's unstake delay.
    function unlockStake() external;
    /// @notice Withdraws the caller's unlocked stake.
    function withdrawStake(address payable withdrawAddress) external;
    /// @notice The deposit of `account`.
    function balanceOf(address account) external view returns (uint256);
}
