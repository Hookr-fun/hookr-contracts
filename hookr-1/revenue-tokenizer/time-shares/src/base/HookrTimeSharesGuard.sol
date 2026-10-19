// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title Hookr time shares reentrancy guard
/// @notice Transient-storage (EIP-1153) reentrancy lock, the same shape as the revenue token's: one slot per
///         contract, taken by every function that moves cash, so a native recipient that runs code during a payout
///         cannot re-enter a roll, a lock, a claim or a redemption.
abstract contract HookrTimeSharesGuard {
    /// @dev keccak256("hookr.timeshares.lock")
    bytes32 private constant LOCK = 0x721c32acc3a2cd94e5e567bb9ef22fb8895590685d528f45e15bcb4d0df13f67;

    /// @notice A guarded function was entered while another guarded call on this contract was still running.
    error Reentered();

    modifier nonReentrant() {
        bytes32 slot = LOCK;
        uint256 locked;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
        if (locked != 0) revert Reentered();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }
}
