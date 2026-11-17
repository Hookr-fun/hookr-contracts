// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrFactoryRegistry
/// @notice The registry surface a root factory uses. HookrRegistry implements it.
interface IHookrFactoryRegistry {
    /// @notice Returns whether the account is an active root factory.
    /// @param factory The account to check.
    /// @return Whether `factory` is an active root factory.
    function isRootFactory(address factory) external view returns (bool);

    /// @notice Registers and opens a root deployed by the calling active root factory, recording its advisory.
    /// @dev The root must hold non-delegated code, be unregistered and report this registry. Refused while new
    ///      markets are paused.
    /// @param root The root the factory deployed.
    /// @param advisory The root's immutable advisory, or zero.
    function registerFactoryRoot(address root, address advisory) external;
}
