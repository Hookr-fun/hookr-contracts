// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRevenueToken} from "hookrevenue-v2/interfaces/IHookrRevenueToken.sol";

/// @title Hookr time shares
/// @notice One contract per revenue token. Holders lock revenue tokens for a number of whole UTC days, or forever,
///         and get, for every day of the lock, one time share per locked revenue token: an ERC-6909 unit (id = the
///         day) that earns only that day's income of the locked revenue tokens, in every asset the token pays.
///         The locked revenue tokens go back to the locker once the last day has ended; a forever lock never
///         returns. The locker issues each day's units when it likes, to itself or to anyone it names, so a single
///         day of future income can be sold or handed out without selling the revenue tokens.
/// @dev The contract holds the locked revenue tokens and is an ordinary holder of them: it earns, and a
///      permissionless `roll()` claims what the token owes it, asset by asset, and attributes it to the days it
///      covers by time. Every lock, unlock, claim and transfer of a day under way settles the same way, so a balance
///      change never shifts income between days or holders. What a day's units are owed is read from a timeline of settle points; a late roll spreads the
///      income it finds over the days since the last point, pro rata to time, and never moves income across a point
///      that was already written. The token's drop box credits the locked balance too; `sweepDrops` and `catchUp`
///      claim that share here and book each drop, by its snapshot block, to the locks that held then (paid with
///      `claimLock`), whenever it is swept. No owner, no pause, and nothing leaves but by a claim. The tip of a roll
///      is `tipBps` of the ETH the roll attributes, capped at `tipCap`.
interface IHookrTimeShares is IERC6909Claims {
    /// @notice One lock of revenue tokens.
    /// @param owner The locker: issues the days' units, claims the lock's own income, unlocks.
    /// @param lockedAt When the lock began to share in the timeline's income: the lock itself, or, for a lock made in
    ///        the second of an existing settle point, the second after it, where the next settle writes a point (zero
    ///        until that settle).
    /// @param firstDay The first whole day the lock earns for: the day after the lock was made; it never moves.
    /// @param amount Revenue tokens locked; one unit per revenue token for every day of the lock.
    /// @param lastDay The last day the lock earns for, included; `FOREVER` for a lock that never returns.
    /// @param unlockedAt When the revenue tokens went back, zero while they are here.
    struct Lock {
        address owner;
        uint64 lockedAt;
        uint32 firstDay;
        uint128 amount;
        uint32 lastDay;
        uint64 unlockedAt;
    }

    // ------------------------------------------------------------------ errors

    /// @notice A construction argument is out of bounds: a token without code or with no assets, a tip above
    ///         `MAX_TIP_BPS`, a token whose first asset is not native ETH, that is not live, whose drop box does not
    ///         point back at it, or whose clock is not the block number.
    error InvalidConfig();
    /// @notice A zero lock amount, one above `MAX_LOCK_AMOUNT`, or a redemption of zero.
    error InvalidAmount(uint256 amount);
    /// @notice A lock length that is neither `MIN_LOCK_DAYS` to `MAX_LOCK_DAYS` nor `FOREVER`.
    error InvalidDays(uint32 numberOfDays);
    /// @notice A day past `FOREVER`, or a range whose first day is after its last.
    error InvalidDay(uint256 day);
    /// @notice `to` cannot take units or a payout: the zero address or this contract.
    error InvalidRecipient(address to);
    /// @notice The caller is not the lock's owner.
    error Unauthorized(address caller);
    /// @notice `lockId` is past the last lock.
    error UnknownLock(uint256 lockId);
    /// @notice `asset` is past the token's last asset.
    error UnknownAsset(uint256 asset);
    /// @notice `k` is past the last settle point.
    error UnknownPoint(uint256 k);
    /// @notice `day` is not one of the lock's days.
    error DayOutOfLock(uint256 lockId, uint256 day);
    /// @notice The lock's units for `day` were issued already.
    error AlreadyIssued(uint256 lockId, uint256 day);
    /// @notice A range of more than `MAX_ISSUE_DAYS` days, or more claim days than `MAX_CLAIM_DAYS`.
    error TooManyDays(uint256 count);
    /// @notice The lock's last day has not ended; it ends at `endsAt`.
    error NotEnded(uint256 lockId, uint256 endsAt);
    /// @notice The lock is forever: its revenue tokens never return.
    error NeverEnds(uint256 lockId);
    /// @notice The lock's revenue tokens went back already.
    error AlreadyUnlocked(uint256 lockId);
    /// @notice The claim would pay nothing.
    error NothingToClaim();
    /// @notice A revenue-token or asset transfer moved other than the amount asked.
    error InexactTransfer();
    /// @notice A native payout was refused by its recipient.
    error NativeTransferFailed();
    /// @notice Asset `asset`'s balance of this contract could not be read (its `balanceOf` reverted or answered
    ///         nothing). Settles, locks, unlocks and the other assets' claims go on without it; claims of it wait.
    error AssetUnreadable(uint256 asset);
    /// @notice Lock `lockId` is pending: made in the second of an existing settle point, it joins the lock total at
    ///         the second after its own, written by the next settle (any settle in a later second).
    error LockPending(uint256 lockId);
    /// @notice `sweepDrops` was left too little gas for a full claim of the next drop at its cap; send more gas.
    error DropSweepGas();
    /// @notice Drop `dropId` is in an asset the revenue token does not pay, so the time shares could not attribute
    ///         it; the locked revenue tokens' share of it stays in the drop box.
    error UnlistedDrop(uint256 dropId);

    // ------------------------------------------------------------------ events

    /// @notice `owner` locked `amount` revenue tokens for days `firstDay` to `lastDay` (`FOREVER` for ever).
    event Locked(uint256 indexed lockId, address indexed owner, uint256 amount, uint32 firstDay, uint32 lastDay);
    /// @notice Lock `lockId`'s `amount` revenue tokens went back to `to`.
    event Unlocked(uint256 indexed lockId, address indexed to, uint256 amount);
    /// @notice Lock `lockId`'s `amount` units of day `day` were minted to `to`.
    event Issued(uint256 indexed lockId, uint256 indexed day, address indexed to, uint256 amount);
    /// @notice A settle point was written at `timestamp` with `locked` revenue tokens locked.
    event Settled(uint64 timestamp, uint256 locked);
    /// @notice `amount` of asset `asset` was attributed to the time since the previous point; the per-token index
    ///         is `index` now.
    event IncomeAttributed(uint256 indexed asset, uint256 amount, uint256 index);
    /// @notice `amount` of asset `asset` was claimed from the revenue token.
    event Pulled(uint256 indexed asset, uint256 amount);
    /// @notice The claim of asset `asset` from the revenue token reverted; its credit stays there for a later roll.
    event PullFailed(uint256 indexed asset);
    /// @notice Asset `asset`'s balance could not be read at a settle or a pull: nothing of it was booked or pulled
    ///         this time; what is held above the books waits for a read that works.
    event AssetUnread(uint256 indexed asset);
    /// @notice The locked revenue tokens' share of drop `dropId` was claimed from the revenue token's drop box into
    ///         this contract and `amount` of asset `asset` booked to the locks that held at its snapshot.
    event DropSwept(uint256 indexed dropId, uint256 indexed asset, uint256 amount);
    /// @notice The revenue token listed asset `asset`, `currency`; this contract follows it.
    event AssetListed(uint256 indexed asset, Currency currency);
    /// @notice A drop's payout failed (its asset reverted, ran out of gas or answered too much), so the sweep went
    ///         on without it. It stays claimable at the box; any later sweep books it by its snapshot.
    event DropParked(uint256 indexed dropId, uint256 indexed asset);
    /// @notice The locks from id `firstLock` on, `amount` revenue tokens in all, joined the lock total at
    ///         `activatedAt`: a lock that counts at once, or the pending locks of one second at the second after it.
    event Activated(uint256 indexed firstLock, uint256 amount, uint64 activatedAt);
    /// @notice `by` rolled and was paid `tip` ETH.
    event Rolled(address indexed by, uint256 tip);
    /// @notice `holder` was paid `amount` of asset `asset` for its units of day `day`, at `to`.
    event IncomeClaimed(address indexed holder, uint256 indexed day, uint256 indexed asset, address to, uint256 amount);
    /// @notice Lock `lockId`'s owner was paid `amount` of asset `asset` of the lock's own income, at `to`.
    event LockIncomeClaimed(uint256 indexed lockId, uint256 indexed asset, address indexed to, uint256 amount);

    // ------------------------------------------------------------------ constants

    /// @notice Fixed-point scale of every index and credit: 1e36.
    function SCALE() external view returns (uint256);
    /// @notice Most assets a revenue token lists: 8.
    function MAX_ASSETS() external view returns (uint256);
    /// @notice Shortest lock: 1 day.
    function MIN_LOCK_DAYS() external view returns (uint32);
    /// @notice Longest lock with an end: 3,650 days.
    function MAX_LOCK_DAYS() external view returns (uint32);
    /// @notice The lock length, and the last day, of a lock that never returns: 2^32 - 1.
    function FOREVER() external view returns (uint32);
    /// @notice Most revenue tokens one lock takes: 2^128 - 1, the revenue token's largest supply.
    function MAX_LOCK_AMOUNT() external view returns (uint256);
    /// @notice The revenue token's share supply over this is the smallest amount `lock` takes (one unit at least),
    ///         so each lock, and each epoch it writes, costs real tokens.
    function MIN_LOCK_DIVISOR() external view returns (uint256);
    /// @notice The smallest amount `lock` takes: `shareSupply / MIN_LOCK_DIVISOR`, one at least.
    function minLockAmount() external view returns (uint256);
    /// @notice Largest roll tip: 100 basis points (1%) of the ETH the roll attributes.
    function MAX_TIP_BPS() external view returns (uint16);
    /// @notice Least ETH a roll must attribute for its caller to be tipped at all: 0.001 ETH.
    function MIN_TIP_GROWTH() external view returns (uint256);
    /// @notice Most days one `issueRange` mints: 366.
    function MAX_ISSUE_DAYS() external view returns (uint256);
    /// @notice Most days one `claimMany` pays: 366.
    function MAX_CLAIM_DAYS() external view returns (uint256);

    // ------------------------------------------------------------------ fixed terms

    /// @notice The revenue token locked here.
    function token() external view returns (IHookrRevenueToken);
    /// @notice The roll caller's tip, in basis points of the ETH the roll attributes.
    function tipBps() external view returns (uint16);
    /// @notice The most ETH one roll pays its caller.
    function tipCap() external view returns (uint256);
    /// @notice Number of assets followed so far: the revenue token's, as of the last settle or `syncAssets`. The token
    ///         lists up to 8, also after it was minted; they only append.
    function assetCount() external view returns (uint256);
    /// @notice Asset `asset`'s currency; reverts `UnknownAsset` past the last one.
    function currencyAt(uint256 asset) external view returns (Currency);

    // ------------------------------------------------------------------ locks

    /// @notice Revenue tokens locked and active right now: they share in the timeline's income. Locks that are still
    ///         pending (made in the second of an existing point) are not in it; drops follow `heldAt` instead.
    function lockedTotal() external view returns (uint256);
    /// @notice The locks made in the second of an existing settle point that have not joined yet: their total, the
    ///         block of the first, and the first lock id. Zero total when none is pending.
    function pendingLocks() external view returns (uint256 amount, uint256 tick, uint256 firstLock);
    /// @notice The first drop id `catchUp` has not passed: every drop below it was swept, skipped (nothing to claim,
    ///         or an asset not listed) or parked (still claimable at the box).
    function nextDrop() external view returns (uint256);
    /// @notice What all locks held (active and pending) at the end of block `blockNumber`: the divisor of a drop
    ///         whose snapshot is that block. Zero before the first lock.
    function heldAt(uint256 blockNumber) external view returns (uint256);
    /// @notice Lock `lockId`'s epochs in the drop ledger: the one its lock wrote and the one its unlock wrote (zero
    ///         while it holds). It shares in every drop whose snapshot's epoch is in `[joinEpoch, leaveEpoch)`.
    function lockEpochs(uint256 lockId) external view returns (uint256 joinEpoch, uint256 leaveEpoch);
    /// @notice Up to `max` ids from `from` on, below the drop count, whose drop this contract can claim now: a share
    ///         in a listed asset. For a keeper to page the box; `next` is where to continue.
    function sweepable(uint256 from, uint256 max) external view returns (uint256[] memory ids, uint256 next);
    /// @notice Number of locks ever made; ids run from 0.
    function lockCount() external view returns (uint256);
    /// @notice Lock `lockId`; reverts `UnknownLock` past the last one.
    function lockAt(uint256 lockId) external view returns (Lock memory);
    /// @notice Whether lock `lockId`'s units of day `day` were issued.
    function isIssued(uint256 lockId, uint256 day) external view returns (bool);
    /// @notice Units of day `day` minted so far, across every lock.
    function unitSupply(uint256 day) external view returns (uint256);
    /// @notice The day `block.timestamp` falls in.
    function currentDay() external view returns (uint256);

    // ------------------------------------------------------------------ timeline

    /// @notice Number of settle points written; the first is the construction.
    function pointCount() external view returns (uint256);
    /// @notice Settle point `k`: its timestamp and every asset's per-token index at it.
    function pointAt(uint256 k) external view returns (uint64 timestamp, uint256[] memory indexes);
    /// @notice Income of asset `asset` attributed so far per locked revenue token, scaled, at the last point.
    function index(uint256 asset) external view returns (uint256);
    /// @notice Scaled income of asset `asset` waiting for the next attribution: the remainder of the last split, or
    ///         everything that arrived while nothing was locked.
    function carry(uint256 asset) external view returns (uint256);
    /// @notice Units of asset `asset` received from the revenue token, or found here, so far.
    function pulled(uint256 asset) external view returns (uint256);
    /// @notice Units of asset `asset` paid out so far: claims and tips.
    function paid(uint256 asset) external view returns (uint256);
    /// @notice Units of asset `asset` this contract holds; reverts `AssetUnreadable` when the asset's `balanceOf`
    ///         cannot be read.
    function held(uint256 asset) external view returns (uint256);
    /// @notice Income of asset `asset` per unit of day `day`, scaled: what a settle now would give it, so a claim
    ///         in this block matches. Zero before the day starts, final once the day has ended and been settled.
    function dayIndex(uint256 day, uint256 asset) external view returns (uint256);

    // ------------------------------------------------------------------ holders

    /// @notice Units of asset `asset` that `holder` can claim now for its units of day `day`.
    function claimable(address holder, uint256 day, uint256 asset) external view returns (uint256);
    /// @notice Units of asset `asset` lock `lockId`'s owner can claim now: the income of the lock's revenue tokens
    ///         outside its days, between the lock and its first day and between its last day and the unlock, and its
    ///         share of every drop swept so far whose snapshot it held at.
    function lockClaimable(uint256 lockId, uint256 asset) external view returns (uint256);

    // ------------------------------------------------------------------ actions

    /// @notice Locks `amount` revenue tokens (approve this contract first) for `numberOfDays` whole days starting
    ///         tomorrow, or forever with `FOREVER`. The caller owns the lock. It counts at once, unless a settle point
    ///         was already written in this second: then it is pending until the next settle (any settle in a later
    ///         second), which lets it in from the second after this one; its days never move. It takes part in every
    ///         drop whose snapshot is at or after this block, and in no earlier one.
    function lock(uint256 amount, uint32 numberOfDays) external returns (uint256 lockId);
    /// @notice Mints lock `lockId`'s units of day `day`, one per locked revenue token, to `to`. Only the lock's
    ///         owner, once per day, any time. Units issued after the day started carry the day's income so far.
    function issue(uint256 lockId, uint256 day, address to) external;
    /// @notice `issue` for every day from `firstDay` to `lastDay`, included; at most `MAX_ISSUE_DAYS`.
    function issueRange(uint256 lockId, uint256 firstDay, uint256 lastDay, address to) external;
    /// @notice Returns lock `lockId`'s revenue tokens to `to` once its last day has ended. Only the lock's owner,
    ///         once; never for a forever lock.
    function unlock(uint256 lockId, address to) external;
    /// @notice Follows the revenue token's asset list: lists every asset it added since the last look. Anyone; every
    ///         settle does it first.
    function syncAssets() external;
    /// @notice Walks the drops from `nextDrop`, claims and books up to `max` of them (passing over the ones with
    ///         nothing to claim or in an asset not listed, and parking one whose payout fails), and moves `nextDrop`.
    ///         Anyone; the keeper's walker. Returns whether it reached the drop count. Each claim gets the default
    ///         200,000 gas; a parked drop stays claimable at the box, listed by `sweepable`, for `sweepDrops`.
    ///         Reverts (the drop box's `Reentered`) when called while the drop box's lock is held.
    function catchUp(uint256 max) external returns (bool done);
    /// @notice Writes a settle point now: the income the revenue token owes this contract since the last point is
    ///         attributed to the time since. Anyone may call; a seller does, so a transfer pays it for the time it
    ///         held. No pull, no tip.
    function settle() external;
    /// @notice Claims every asset from the revenue token, settles, and pays the caller `tipBps` of the ETH
    ///         attributed (at least `MIN_TIP_GROWTH`, at most `tipCap`). Anyone may call.
    function roll() external returns (uint256 tip);
    /// @notice Claims the locked revenue tokens' share of each listed drop from the revenue token's drop box into
    ///         this contract and books it to the locks that held at its snapshot block, in proportion to what they
    ///         held then, whenever it is swept. Anyone may call. Every drop must be in one of the token's assets
    ///         (`UnlistedDrop` otherwise); one with nothing to claim is passed over, one whose payout fails is parked
    ///         (`DropParked`), and the box's unknown-drop revert comes through. Returns what each drop booked.
    ///         Each claim gets `claimGas`, raised to the default 200,000 when below it (zero: the default): a drop
    ///         whose claim costs more (an asset with a costly transfer, or another revenue token, whose transfer
    ///         settles each of its assets) is booked by naming a cap above its cost, and a claim that fails anyway
    ///         costs the caller at most that cap. Reverts `DropSweepGas` unless `claimGas * 64 / 63 + 60,000` is left
    ///         before each claim.
    function sweepDrops(uint256[] calldata dropIds, uint256 claimGas) external returns (uint256[] memory amounts);
    /// @notice Pays the caller's income of asset `asset` for its units of day `day` to `to`: the lesser of what it
    ///         is owed and what is held; the rest stays owed.
    function claim(uint256 day, uint256 asset, address to) external returns (uint256 amount);
    /// @notice `claim` over `days_`, paid in one transfer; at most `MAX_CLAIM_DAYS`.
    function claimMany(uint256[] calldata days_, uint256 asset, address to) external returns (uint256 amount);
    /// @notice Pays lock `lockId`'s own income in asset `asset` to `to`. Only the lock's owner.
    function claimLock(uint256 lockId, uint256 asset, address to) external returns (uint256 amount);
}
