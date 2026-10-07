// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title Transient reentrancy guard
/// @notice One transient lock per contract, shared by every guarded entry point of that contract.
/// @dev EIP-1153 storage; the lock clears at the end of the transaction even if a frame forgets to.
abstract contract TransientReentrancyGuard {
    /// @dev keccak256("hookr.module-market.reentrancy")
    bytes32 private constant LOCK = 0xf711bb71b157a2ac0bebbfbf2388f5b2ee7bc0f3ef0ce0435d38eae06525c41c;

    error Reentered();

    modifier nonReentrant() {
        bool locked;
        assembly ("memory-safe") {
            locked := tload(LOCK)
        }
        if (locked) revert Reentered();
        assembly ("memory-safe") {
            tstore(LOCK, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(LOCK, 0)
        }
    }
}
