// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
/// @notice The runtime codehash of every HookrToken that keeps its holders' lots (`lots`, `lotsBefore`): keccak256 of
///         the HookrToken runtime the release HookrTokenDeployer embeds (labs/hooks/combined-core/launcher-hold, its
///         src-only release build; that package's test/support/HookrTokenCodeHash.t.sol pins the same value). Exit Clock
///         reads `lotsBefore` only from a subject with this codehash, and the Binder gives such a token the Hookr
///         minimum as it does the first template's.
library HookrHoldTokenCodeHash { bytes32 internal constant HASH = 0x67037cbf7e52e1cda28efea71c44b8eeec886cbb4cb19c07fef45c97ac89d1a1; }
