// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrReleased
/// @notice The release identity every Hookr contract exposes.
interface IHookrReleased {
    /// @notice Returns the release this contract belongs to.
    /// @return The release id, the same on every contract of one release.
    function releaseId() external pure returns (uint256);
}
