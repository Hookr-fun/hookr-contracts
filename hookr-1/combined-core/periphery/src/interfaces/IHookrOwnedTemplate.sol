// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrOwnedTemplate
/// @notice The two HookrRoot and HookrRules getters HookrOwnedRootFactory reads that no other Hookr interface declares.
interface IHookrOwnedTemplate {
    /// @notice The permission flags a HookrRoot's address carries.
    /// @return The flags.
    function PERMISSION_FLAGS() external view returns (uint160);

    /// @notice The protocol-share floor a HookrRules was built with.
    /// @return The floor in basis points.
    function minProtocolShareBps() external view returns (uint16);
}
