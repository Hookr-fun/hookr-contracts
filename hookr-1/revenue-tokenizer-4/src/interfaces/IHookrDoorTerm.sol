// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Hookr door term, part of the HookRevenue Tokenizer
/// @notice The term of a door that holds a fee right until a date: the account the right goes back to, the unlock
///         timestamp (or forever), and the one way to change it, `extendTerm`, which moves the date only later.
interface IHookrDoorTerm {
    /// @notice The account the right goes back to cannot be zero or the door.
    error InvalidReturnTo(address returnTo);
    /// @notice The unlock time is not in the future (and not FOREVER).
    error UnlockNotInFuture(uint64 unlockAt, uint256 now_);
    /// @notice Only the account the right goes back to may extend the term; `caller` is not it.
    error OnlyReturnTo(address caller);
    /// @notice The unlock time has not passed.
    error StillLocked(uint64 unlockAt, uint256 now_);
    /// @notice The right is locked forever; it never goes back.
    error LockedForever();
    /// @notice The right already went back.
    error AlreadyReleased();

    /// @notice The unlock value that means the right never goes back: type(uint64).max.
    /// @return The FOREVER sentinel.
    function FOREVER() external view returns (uint64);
    /// @notice The account the right goes back to at release, and the only one that may extend the term.
    /// @return The account the right goes back to.
    function returnTo() external view returns (address);
    /// @notice The unlock timestamp; FOREVER means never.
    /// @return The unlock timestamp.
    function unlockAt() external view returns (uint64);
    /// @notice Moves the unlock time to `newUnlock`, which must be later than the current one (FOREVER for good).
    ///         Only `returnTo`, only while the right is still here. Emits `IHookrRevenueDoor.TermExtended`.
    /// @param newUnlock The new unlock timestamp, or FOREVER.
    function extendTerm(uint64 newUnlock) external;
}
