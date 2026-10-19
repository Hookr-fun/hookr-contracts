// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Hookr leg collector, part of the HookRevenue Tokenizer
/// @notice Holds Hookr's leg of every revenue token the tokenizer creates with one and lets anyone sweep what those shares
///         earned to the live HookrTreasury's current `target()`: the streamed income through `sweep` / `sweepAll`, the
///         drops through `sweepDrops` (IHookrDropSweep). No owner: the treasury's target is read on every sweep, so the
///         treasury's own two-step target change is the only way to move where the money goes.
interface IHookrLegCollector {
    /// @notice The treasury has no code.
    error InvalidTreasury(address treasury);
    /// @notice `token` has no code, so it is no revenue token to sweep.
    error InvalidToken(address token);

    /// @notice `amount` of asset `asset` earned by this collector's shares of `token` went to `target`.
    event Swept(address indexed token, uint256 indexed asset, address indexed target, uint256 amount);

    /// @notice The HookrTreasury whose `target()` every sweep pays.
    function treasury() external view returns (address);

    /// @notice Claims this collector's income in asset `asset` of revenue token `token` to the treasury's target. Anyone.
    function sweep(address token, uint256 asset) external returns (uint256 amount);

    /// @notice `sweep` for every asset of `token`, skipping assets with nothing due.
    function sweepAll(address token) external returns (uint256[] memory amounts);
}
