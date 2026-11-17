// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title Hookr revenue reentrancy guard, part of the HookRevenue Tokenizer
/// @notice Transient-storage (EIP-1153) reentrancy lock shared by the revenue token and its drop box.
/// @dev One slot per contract (transient storage is per address). Every cash-moving external function takes it,
///      so a native-ETH recipient that runs code during a payout cannot re-enter a claim, a sync or a drop.
abstract contract HookrRevenueGuard {
    /// @dev keccak256("hookr.revenue.lock")
    bytes32 private constant LOCK = 0xb2e9bbb7416e2d479469e6bc46c03786da070f9102b8b0af6e032f5ea3389121;

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
