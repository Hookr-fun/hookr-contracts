// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Hookr reward mint target
/// @notice The reward asset a Swap Reward Mint programme mints into. Implemented by the asset itself.
/// @dev The minter never holds, prices or transfers the reward asset. It only asks the asset to mint, with a
///      frozen gas stipend, and treats anything other than the exact magic return as a failed mint.
interface IHookrRewardMintTarget {
    /// @notice Returns whether `minter` may currently call `mintReward`.
    /// @dev Read with a bounded STATICCALL on the swap path. A revert, a gas burn or a malformed return is read as
    ///      "not ready", which switches the reward slice off for that swap; it never fails the swap.
    function isRewardMinter(address minter) external view returns (bool);

    /// @notice Mints `amount` reward units to `to`. Only an authorized minter may call.
    /// @return magic Must be `IHookrRewardMintTarget.mintReward.selector`.
    function mintReward(address to, uint256 amount) external returns (bytes4 magic);
}
