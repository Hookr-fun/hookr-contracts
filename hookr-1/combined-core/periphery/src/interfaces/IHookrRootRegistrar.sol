// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrRootRegistrar
/// @notice What the registry and the treasury ask a root factory that registers owned roots (IHookrOwnedRoots): who
///         may open pools on one of its roots now, and which Rules module it deployed for that root.
/// @dev Day-one implementation: HookrOwnedRootFactory (through IHookrOwnedRootFactory).
interface IHookrRootRegistrar {
    /// @notice Whether `opener` may open a pool on `root` now: anyone on a public root, only the root's owner on an
    ///         owner-only one, and nobody while the root's owner has paused it.
    /// @dev The registry asks with a bounded static call from `rootOpenFor` and counts only a clean 32-byte true: a
    ///      revert, a return shorter or longer than one word, any word other than 1 or running out of gas reads as
    ///      closed.
    /// @param root The owned root.
    /// @param opener The account opening the pool: the launcher's caller.
    /// @return Whether the pool may open.
    function mayOpen(address root, address opener) external view returns (bool);

    /// @notice The Rules module the factory deployed for `root`, or zero for a root it did not deploy.
    /// @param root The owned root.
    /// @return The root's companion Rules module.
    function rulesOf(address root) external view returns (address);
}
