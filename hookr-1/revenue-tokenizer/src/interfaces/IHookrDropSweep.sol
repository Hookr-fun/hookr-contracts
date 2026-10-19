// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Hookr drop sweep, part of the HookRevenue Tokenizer
/// @notice What a contract that holds revenue-token shares for someone else (Hookr's leg collector) adds so the drops
///         those shares earn reach that someone. A drop is paid to whoever calls the box, so a holder with no code
///         path to `claim` earns a share of every drop that nobody can ever take (the box has no sweep). This mixin
///         is that code path: anyone may call it, it pays the drops to the contract's fixed target, nothing else.
interface IHookrDropSweep {
    /// @notice `token` has no code, so it cannot be a drop host.
    error NoDropBox(address token);

    /// @notice This contract's share of drop `dropId` into `token` (`amount` of the drop's asset) went to `target`.
    event DropSwept(address indexed token, uint256 indexed dropId, address indexed target, uint256 amount);

    /// @notice Claims this contract's share of each listed drop into revenue token `token` to the target. Anyone, any
    ///         time. Reverts as the box does: unknown id, already swept, or nothing due.
    function sweepDrops(address token, uint256[] calldata dropIds) external returns (uint256[] memory amounts);
}
