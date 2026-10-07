// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrSwapRewardMinterAttestor
/// @notice The attestation surface of `HookrSwapRewardMinterFactory`.
interface IHookrSwapRewardMinterAttestor {
    /// @notice Whether the factory created `minter`.
    function isMinter(address minter) external view returns (bool);
}
