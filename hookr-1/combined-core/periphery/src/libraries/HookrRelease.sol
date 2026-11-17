// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HookrRelease
/// @notice One release identity shared by every contract in the set. Contracts carry role names only.
/// @dev A new release bumps this value for the whole set, including contracts whose code did not change.
library HookrRelease {
    uint256 internal constant ID = 1;
}
