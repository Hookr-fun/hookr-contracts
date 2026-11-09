// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Hookr revenue tokenizer source pins
/// @notice The two adapter factories the tokenizer pins so a reader can mark first-party sources: a source made by
///         either is the Pons or Long adapter the release ships. The tokenizer itself legs every source the same.
interface IHookrRevenueTokenizerSourcePins {
    /// @notice The Pons adapter factory, or zero.
    function ponsAdapterFactory() external view returns (address);
    /// @notice The Doppler (Long) adapter factory, or zero.
    function dopplerAdapterFactory() external view returns (address);
}
