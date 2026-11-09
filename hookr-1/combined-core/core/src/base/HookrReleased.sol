// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {HookrRelease} from "../libraries/HookrRelease.sol";
import {IHookrReleased} from "../interfaces/IHookrReleased.sol";

/// @title HookrReleased
/// @notice Exposes the shared release identity.
abstract contract HookrReleased is IHookrReleased {
    /// @inheritdoc IHookrReleased
    function releaseId() external pure returns (uint256) {
        return HookrRelease.ID;
    }
}
