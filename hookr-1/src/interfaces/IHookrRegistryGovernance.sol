// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrRegistryGovernance
/// @notice The registry's governance reads the launch fee's terms use: HookrRegistry's owner, guardian and timelock
///         delay.
interface IHookrRegistryGovernance {
    /// @notice The registry's owner, who proposes and applies a launch fee.
    /// @return The owner.
    function owner() external view returns (address);

    /// @notice The registry's guardian, who may clear the launch fee at once.
    /// @return The guardian, zero for none.
    function guardian() external view returns (address);

    /// @notice The registry's timelock delay, which a proposed launch fee waits before it can apply.
    /// @return The delay in seconds.
    function delay() external view returns (uint48);
}
