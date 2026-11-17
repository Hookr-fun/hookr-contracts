// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IHookrRootEvents
/// @notice The events and errors a Hookr root and its lane module share. HookrLane opens pools and runs the root's
///         module calls at the root's address by DELEGATECALL, so HookrRoot and HookrLane inherit this one declaration.
///         IHookrRoot does not, so a contract that implements IHookrRoot inherits no declarations.
interface IHookrRootEvents {
    /// @notice The caller may not do this.
    error Unauthorized();
    /// @notice The pool is not one this root initialized, or is not in the state the call needs.
    error InvalidPool();
    /// @notice The pool is already initialized.
    error AlreadyInitialized();
    /// @notice The pool's configuration, modules or data are invalid.
    error InvalidConfig();
    /// @notice `module` is not an admission of the kind it was bound as, or no longer runs its pinned code or schema.
    error InvalidModule(address module);

    /// @notice A module call the root or its lane requires failed without a reason: it ran out of gas, reverted without
    ///         data, returned the wrong length or (an advisory's swap answer to the root) a value out of range.
    error ModuleCallFailed(address module, bytes4 callSelector);

    /// @notice A module call the root or its lane requires reverted with data. `reason` is that data, cut to its first
    ///         132 bytes (a selector and four words): the module's own error, carried inside this one so it never reads
    ///         as the root's or the lane's.
    error ModuleCallReverted(address module, bytes4 callSelector, bytes reason);
    /// @notice `module` returned a result the root refuses.
    error InvalidModuleResult(address module);
    /// @notice The callback re-entered the root while a swap, a binding or an arb recapture frame was active.
    error ReentrantCallback();
    /// @notice A swap carries hook data the root does not accept.
    error InvalidHookData();
    /// @notice `quote` is not a quote the registry admits for new pools.
    error UnqualifiedQuote(address quote);

    /// @notice A pool opened on the root.
    /// @param id The pool.
    /// @param launcher The launcher that initialized it.
    /// @param policyHash The commitment to the pool key, configuration and module data.
    /// @param rules The pool's Rules.
    /// @param advisory The pool's advisory, or zero.
    event PoolOpened(
        PoolId indexed id, address indexed launcher, bytes32 indexed policyHash, address rules, address advisory
    );
}
