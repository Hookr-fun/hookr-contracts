// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
/// @notice The runtime codehash of every HookrToken the release launches: keccak256 of the release build's
///         HookrToken runtime (`type(HookrToken).runtimeCode` in the release HookrRules), which both live 4663
///         HookrRules embed (read 2026-10-15). This package's own HookrToken build hashes differently
///         (0xfd6b…7a7c), so the value is not regenerated from it; test/bench-combined/TokenCodeHash.t.sol in the L0
///         package checks it against the release source.
library HookrTokenCodeHash { bytes32 internal constant HASH = 0x2ac0989170f11b4f7bc16e90018f8b1db30b3149b2fc3aceee712135617f33d0; }
