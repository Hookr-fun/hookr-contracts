// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title HookrTokenBounds
/// @notice The most a HookrToken's supply can be: a holder word packs the balance and the fresh lot in 108 bits each
///         beside the lot's time, so no supply above it can exist. HookrToken refuses more at creation and HookrLauncher
///         refuses it before it creates anything.
library HookrTokenBounds {
    uint256 internal constant MAX_SUPPLY = (uint256(1) << 108) - 1;
}
