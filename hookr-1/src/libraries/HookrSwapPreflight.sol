// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IHookrRouter} from "../interfaces/IHookrRouter.sol";

/// @title HookrSwapPreflight
/// @notice The field checks HookrRouter applies to a swap before any pool call. HookrQuoter applies the same checks
///         against the root's router before it simulates, so it never quotes a swap that router refuses on these
///         grounds.
library HookrSwapPreflight {
    /// @notice Whether `params` passes the router's field checks: the deadline has not passed; the recipient is not
    ///         zero, `router`, `manager` or `forwarder`; the amount is neither zero nor int128's minimum; the bound is
    ///         not zero.
    /// @param params The swap.
    /// @param router The router that executes the swap.
    /// @param manager That router's PoolManager.
    /// @param forwarder That router's forwarder, zero when it has none.
    /// @return Whether the swap passes every check.
    function passes(IHookrRouter.Swap calldata params, address router, address manager, address forwarder)
        internal
        view
        returns (bool)
    {
        return passes(
            params.recipient, params.amountSpecified, params.amountBound, params.deadline, router, manager, forwarder
        );
    }

    /// @notice The same checks on a swap given field by field, for a swap the caller builds rather than receives.
    /// @param recipient The swap's recipient.
    /// @param amountSpecified The swap's amount: negative for an exact input, positive for an exact output.
    /// @param amountBound The swap's minimum output or maximum input.
    /// @param deadline The last timestamp at which the swap may execute.
    /// @param router The router that executes the swap.
    /// @param manager That router's PoolManager.
    /// @param forwarder That router's forwarder, zero when it has none.
    /// @return Whether the swap passes every check.
    function passes(
        address recipient,
        int128 amountSpecified,
        uint128 amountBound,
        uint256 deadline,
        address router,
        address manager,
        address forwarder
    ) internal view returns (bool) {
        return block.timestamp <= deadline && recipient != address(0) && recipient != router && recipient != manager
            && recipient != forwarder && amountSpecified != 0 && amountSpecified != type(int128).min && amountBound != 0;
    }
}
