// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHookrBalanceHistory} from "../interfaces/IHookrBalanceHistory.sol";

/// @title Hookr balance history, part of the HookRevenue Tokenizer
/// @notice Mixin for an ERC-20 that keeps per-holder and earning-supply balance checkpoints keyed by block number,
///         written in `_update`. Shares the Uniswap v4 PoolManager and 0xdead hold never earn: they get no
///         history and are left out of the earning supply.
/// @dev Why not one checkpoint per change: a drop asks for balances at one block, `clock() - 1` when it lands, and
///      nothing ever asks about other blocks. So each history keeps its two newest checkpoints in a two-slot ring
///      (the one with the higher block is current, the other is its predecessor) plus an archive of the older ones
///      that some recorded snapshot block falls on. A change in a new block writes the new checkpoint over the
///      predecessor's slot, so the old current becomes the predecessor without being copied. The predecessor is
///      first moved into the archive only if a snapshot block falls on the blocks it covered; otherwise it is simply
///      overwritten. That makes a change cost one slot write in the steady state instead of a fresh slot per
///      change, and the cost does not depend on how many drops or assets exist. A drop that lands later in the same
///      block as a change still reads the balance before that change, because the predecessor is always kept until
///      the block moves on.
///
///      The keep test is exact. The predecessor covers the blocks from its own block to the block before the
///      current checkpoint's block, so it is needed if and only if a drop landed in a block from the one after the
///      predecessor's block to the current checkpoint's block. Drops before the current checkpoint was written show
///      in the newest snapshot block recorded at that moment, stored in the slot (`seen`): a drop in that range was
///      recorded by then with a snapshot at or after the predecessor's block. The only drops in that range recorded
///      after the write are drops later in the current checkpoint's own block; `_snapshotAt[current block - 1]`
///      says whether one landed, and it is read only when some drop landed since the write (`_latestSnapshot`
///      at or after the current checkpoint's block less one). Every later snapshot is at or after
///      `clock() - 1` of a later block, past the end of what the predecessor covered, so a dropped checkpoint is
///      never asked about, now or later.
///
///      A balance above 2^128 - 1 reverts: a ring slot packs the block (48 bits), the archive count (32 bits), the
///      snapshot seen (48 bits) and the value (128 bits). The revenue token's supply is below 2^128 by its own terms.
///
///      What a transfer costs: about 20k gas over a plain ERC-20 between snapshots (one slot write per earning side,
///      plus one for the earning supply when a side is excluded). Every recorded snapshot costs each holder who
///      changes across it one fresh archive slot (about 22k) once, at the first change whose predecessor carries
///      the snapshot. So a holder active every block under one drop per block pays about 65k extra per transfer for
///      as long as that lasts; anyone can record a snapshot with a 1-wei drop. That is the floor for a history exact
///      at every snapshot block (ERC20Votes pays a fresh slot on every transfer). Bounding it (a minimum gap between
///      recorded snapshots) would change the "block before the drop" rule.
///
///      `earns` must be a pure function of constants and immutables. The earning supply is kept by increments in
///      `_update` (added when shares enter an earning account, removed when they leave one), so an account that
///      changes side after it holds breaks the sum: re-including an excluded holder makes its next outgoing transfer
///      underflow and revert, excluding a holder that already earns counts its shares twice and strands part of
///      every later drop. A token that excludes more must write `super.earns(a) && a != someImmutable`, never read
///      storage or a balance.
abstract contract HookrBalanceHistory is ERC20, IHookrBalanceHistory {
    /// @dev One of the two newest checkpoints of a history.
    /// @param key The block the value holds from; zero means the slot was never written.
    /// @param archived How many older checkpoints the archive holds, `archive[0 .. archived - 1]`, blocks strictly
    ///        increasing and all below the predecessor's. Authoritative on the current slot only.
    /// @param seen The newest snapshot block recorded when this slot was written.
    /// @param value The balance from `key` on.
    struct Slot {
        uint48 key;
        uint32 archived;
        uint48 seen;
        uint128 value;
    }

    /// @dev One archived checkpoint: `value` held from block `key` until the next checkpoint's block. The value is
    ///      at most 2^128 - 1 like a ring slot's; the field is 208 bits so the struct fills its slot and a fresh
    ///      archive write is one SSTORE with no read first (a 128-bit field measured 506 gas more per archiving
    ///      transfer).
    struct Checkpoint {
        uint48 key;
        uint208 value;
    }

    /// @dev A holder's (or the earning supply's) history: the ring and the archive.
    struct History {
        Slot a;
        Slot b;
        mapping(uint256 => Checkpoint) archive;
    }

    /// @inheritdoc IHookrBalanceHistory
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @inheritdoc IHookrBalanceHistory
    address public immutable poolManager;

    mapping(address => History) private _accounts;
    History private _earning;
    uint48 private _latestSnapshot;
    /// @dev Whether a drop landed in the block after `snapshotBlock`, i.e. `snapshotBlock` is a recorded snapshot.
    mapping(uint48 snapshotBlock => bool) private _snapshotAt;

    constructor(address poolManager_) {
        if (poolManager_ == address(0)) revert InvalidConfig();
        poolManager = poolManager_;
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc IHookrBalanceHistory
    function clock() public view virtual returns (uint48) {
        return uint48(block.number);
    }

    /// @inheritdoc IHookrBalanceHistory
    /// @dev Overrides may add exclusions only of immutables: `super.earns(account) && account != someImmutable`.
    ///      See the contract notes for why a rule that can change after balances exist breaks the earning supply.
    function earns(address account) public view virtual returns (bool) {
        return account != poolManager && account != DEAD;
    }

    /// @inheritdoc IHookrBalanceHistory
    function earningSupply() public view returns (uint256) {
        (Slot memory cur,,) = _ring(_earning);
        return cur.value;
    }

    /// @inheritdoc IHookrBalanceHistory
    function latestSnapshot() public view returns (uint48) {
        return _latestSnapshot;
    }

    /// @inheritdoc IHookrBalanceHistory
    function balanceAt(address account, uint48 blockNumber) public view returns (uint256) {
        if (!earns(account)) return 0;
        return _valueAt(_accounts[account], blockNumber);
    }

    /// @inheritdoc IHookrBalanceHistory
    function earningSupplyAt(uint48 blockNumber) public view returns (uint256) {
        return _valueAt(_earning, blockNumber);
    }

    /// @inheritdoc IHookrBalanceHistory
    function checkpointCount(address account) external view returns (uint256) {
        return _count(_accounts[account]);
    }

    /// @inheritdoc IHookrBalanceHistory
    function earningCheckpointCount() external view returns (uint256) {
        return _count(_earning);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Marks `clock() - 1` as a snapshot block the history must keep answering exactly. The token exposes
    ///      this to its drop box only. Returns that block.
    function _recordSnapshot() internal returns (uint48 snapshotBlock) {
        uint48 now_ = clock();
        if (now_ == 0) revert ClockZero();
        snapshotBlock = now_ - 1;
        if (snapshotBlock > _latestSnapshot) _latestSnapshot = snapshotBlock;
        if (!_snapshotAt[snapshotBlock]) _snapshotAt[snapshotBlock] = true;
    }

    /// @dev Moves the balances, then checkpoints each earning side and, when exactly one side earns, the earning
    ///      supply. Excluded addresses (`earns` false) and the zero address of a mint or burn write nothing.
    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);
        if (value == 0) return;
        uint48 now_ = clock();
        bool fromEarns = from != address(0) && earns(from);
        bool toEarns = to != address(0) && earns(to);
        if (fromEarns) _record(_accounts[from], now_, balanceOf(from));
        if (toEarns) _record(_accounts[to], now_, balanceOf(to));
        if (fromEarns != toEarns) {
            (Slot memory cur, Slot memory prev, bool aIsCurrent) = _ring(_earning);
            _write(_earning, cur, prev, aIsCurrent, now_, toEarns ? cur.value + value : cur.value - value);
        }
    }

    /// @dev Writes `newValue` as the balance from block `now_` on.
    function _record(History storage h, uint48 now_, uint256 newValue) private {
        (Slot memory cur, Slot memory prev, bool aIsCurrent) = _ring(h);
        _write(h, cur, prev, aIsCurrent, now_, newValue);
    }

    /// @dev Writes `newValue` as the balance from block `now_` on, given the ring as `_ring` read it. See the contract
    ///      notes for what is kept.
    function _write(
        History storage h,
        Slot memory cur,
        Slot memory prev,
        bool aIsCurrent,
        uint48 now_,
        uint256 newValue
    ) private {
        if (now_ == 0) revert ClockZero();
        if (newValue > type(uint128).max) revert BalanceTooLarge(newValue);
        // casting to 'uint128' is safe because newValue was checked against type(uint128).max above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 v = uint128(newValue);
        if (cur.key == now_) {
            // Same block: the current checkpoint already covers this block, so only its value moves.
            if (aIsCurrent) h.a.value = v;
            else h.b.value = v;
            return;
        }
        uint48 latest = _latestSnapshot;
        if (cur.key == 0) {
            // First change ever: the balance was zero before, which an empty history already says.
            h.a = Slot(now_, 0, latest, v);
            return;
        }
        uint32 n = cur.archived;
        if (prev.key != 0 && _needed(cur, prev.key, latest)) {
            // A snapshot falls on the blocks the predecessor covered: move it into the archive before its slot is
            // reused.
            h.archive[n] = Checkpoint(prev.key, prev.value);
            n++;
        }
        // The new checkpoint takes the predecessor's slot (one write); the old current is now the predecessor.
        if (aIsCurrent) h.b = Slot(now_, n, latest, v);
        else h.a = Slot(now_, n, latest, v);
    }

    /// @dev Whether a snapshot block falls on `prevKey .. cur.key - 1`: one recorded before `cur` was written
    ///      (`cur.seen` at or after `prevKey`), or a drop later in `cur`'s own block, which only exists if a drop
    ///      landed since the write at all (`latest` at or after `cur.key - 1`).
    function _needed(Slot memory cur, uint48 prevKey, uint48 latest) private view returns (bool) {
        if (cur.seen >= prevKey) return true;
        if (latest + 1 < cur.key) return false;
        return _snapshotAt[cur.key - 1];
    }

    /// @dev The current checkpoint (the ring slot with the higher block), its predecessor, and whether the current
    ///      one is slot `a`.
    function _ring(History storage h) private view returns (Slot memory cur, Slot memory prev, bool aIsCurrent) {
        Slot memory a = h.a;
        Slot memory b = h.b;
        aIsCurrent = a.key >= b.key;
        return aIsCurrent ? (a, b, true) : (b, a, false);
    }

    /// @dev The value at the end of `blockNumber`: the current checkpoint when at or after its block, the
    ///      predecessor when at or after its block, else the latest archived checkpoint at or before it (zero when
    ///      there is none).
    function _valueAt(History storage h, uint48 blockNumber) private view returns (uint256) {
        (Slot memory cur, Slot memory prev,) = _ring(h);
        if (blockNumber >= cur.key) return cur.value;
        if (blockNumber >= prev.key) return prev.value;
        uint256 low = 0;
        uint256 high = cur.archived;
        while (low < high) {
            uint256 mid = (low + high) >> 1;
            if (h.archive[mid].key > blockNumber) high = mid;
            else low = mid + 1;
        }
        return low == 0 ? 0 : h.archive[low - 1].value;
    }

    function _count(History storage h) private view returns (uint256) {
        (Slot memory cur, Slot memory prev,) = _ring(h);
        if (cur.key == 0) return 0;
        return uint256(cur.archived) + (prev.key == 0 ? 1 : 2);
    }
}
