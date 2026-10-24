// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {EndKind} from "../types/EndKind.sol";
import {IHookrDoorTerm} from "../interfaces/IHookrDoorTerm.sol";
import {IHookrRevenueDoor} from "../interfaces/IHookrRevenueDoor.sol";

/// @title Hookr door term, part of the HookRevenue Tokenizer
/// @notice The term of a door that holds a fee right until a timestamp (IHookrDoorTerm): one `returnTo`, the account
///         that added the right, and an unlock time that only `returnTo` moves, and only later.
/// @dev The tokenizer enforces the shortest term (7 days or forever) before it creates a door; the door itself
///      refuses only a date that is not in the future.
abstract contract HookrDoorTerm is IHookrRevenueDoor, IHookrDoorTerm {
    /// @inheritdoc IHookrDoorTerm
    uint64 public constant FOREVER = type(uint64).max;

    /// @inheritdoc IHookrDoorTerm
    address public immutable returnTo;
    /// @inheritdoc IHookrDoorTerm
    uint64 public unlockAt;

    /// @param returnTo_ The account the right goes back to; not zero or the door.
    /// @param unlockAt_ The unlock timestamp, after now, or FOREVER.
    constructor(address returnTo_, uint64 unlockAt_) {
        if (returnTo_ == address(0) || returnTo_ == address(this)) revert InvalidReturnTo(returnTo_);
        if (unlockAt_ != FOREVER && unlockAt_ <= block.timestamp) revert UnlockNotInFuture(unlockAt_, block.timestamp);
        returnTo = returnTo_;
        unlockAt = unlockAt_;
    }

    /// @inheritdoc IHookrDoorTerm
    function extendTerm(uint64 newUnlock) external {
        if (msg.sender != returnTo) revert OnlyReturnTo(msg.sender);
        if (_isReleased()) revert AlreadyReleased();
        uint64 current = unlockAt;
        if (newUnlock <= current) revert TermNotExtended(newUnlock, current);
        unlockAt = newUnlock;
        emit TermExtended(newUnlock);
    }

    /// @inheritdoc IHookrRevenueDoor
    function ends() external view returns (EndKind kind, uint64 endsAt) {
        if (_isReleased()) return (EndKind.ENDED, 0);
        uint64 unlock = unlockAt;
        if (unlock == FOREVER) return (EndKind.FOREVER, 0);
        return (EndKind.AT_TIME, unlock);
    }

    /// @dev Whether the right went back for good.
    function _isReleased() internal view virtual returns (bool);

    /// @dev Reverts unless the term is over: never for a right locked forever, not before the unlock time.
    function _requireUnlocked() internal view {
        uint64 unlock = unlockAt;
        if (unlock == FOREVER) revert LockedForever();
        if (block.timestamp < unlock) revert StillLocked(unlock, block.timestamp);
    }
}
