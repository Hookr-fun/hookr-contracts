// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrDropBox} from "hookrevenue-v2/interfaces/IHookrDropBox.sol";
import {IHookrRevenueToken} from "hookrevenue-v2/interfaces/IHookrRevenueToken.sol";
import {HookrDayUnits} from "./base/HookrDayUnits.sol";
import {HookrTimeSharesGuard} from "./base/HookrTimeSharesGuard.sol";
import {HookrDays} from "./libraries/HookrDays.sol";
import {IHookrTimeShares} from "./interfaces/IHookrTimeShares.sol";

/// @title Hookr time shares
/// @notice Lock revenue tokens for whole UTC days, or forever, and get one time share per locked revenue token for
///         every day of the lock: an ERC-6909 unit, id the day, that earns only that day's income of the locked
///         revenue tokens in every asset the token pays. The revenue tokens go back once the last day has ended; a
///         forever lock never returns. The locker issues each day's units when it likes, to anyone it names.
/// @dev This contract holds the locked revenue tokens as an ordinary holder: it earns, and it claims from the token
///      asset by asset, each claim on its own so that one asset's trouble never stops the others. What the token
///      owes it (its `claimable`, plus what was received, plus anything found here above the books) grows between
///      two settles; a settle attributes that growth to the time since the last settle point over the revenue
///      tokens locked then (HookrIncomeTimeline). Every lock and unlock settles first, so the locked amount is
///      constant inside each stretch, and a day's units are owed exactly the income the revenue tokens behind them
///      earned, read off the timeline at the day's two ends. A unit transfer of a day under way (or ended and not
///      settled across its end) settles first, so the sender keeps what its units earned up to the move. The income a
///      lock earns outside its days (from the lock to its first day, and from its last day to the unlock) belongs to
///      the locker and is claimed per lock.
///      Payouts pay the lesser of what is owed and the cash on the books, the rest stays owed, and a short asset is
///      pulled from the token first. An asset whose balance cannot be read books no surplus at a settle, counts what
///      a pull it could not measure took from the token, and never moves its mark down (that pull is found later and
///      counted once), instead of stopping it, so locks, unlocks and the other assets' claims never depend on one
///      asset's reads. No owner, no pause; `roll()`, `settle()`, `sweepDrops()`, `catchUp()`, `syncAssets()` and the
///      issue of a day's units are the only calls that are not a holder's own.
///
///      The token's other income path, its drop box, pays this contract's balance at the end of the block before the
///      drop was recorded (its snapshot). Drops never reach the timeline: they have a ledger of their own. Every
///      `lock` and `unlock` writes what all locks hold at the end of its block (an epoch), and each lock keeps the
///      epoch it joined and the epoch it left. A sweep (`sweepDrops`, `catchUp`) books a drop by its snapshot,
///      whenever it is swept and by whoever: what landed, over what the locks held at that snapshot, added per held
///      revenue token at the snapshot's epoch (a Fenwick tree per asset that grows by one node per epoch). A lock's
///      drop income is its amount times the sum over the epochs it held in, paid by `claimLock` with the rest of its
///      own income, also after it unlocked. So a drop pays exactly the locks that held at its snapshot, in proportion
///      to what they held then; a lock made after the snapshot gets none of it; and no lock, unlock, settle, roll or
///      claim ever waits for a drop. A new lock counts at once (`lockedAt` is the lock), unless a settle point was
///      already written earlier in the same second: then income found since that point waits in the carry, so the
///      lock is pending until the next point (`Activated`). The revenue token lists up to eight assets and adds them
///      after it was minted; every settle follows the list first (`syncAssets`).
contract HookrTimeShares is HookrDayUnits, HookrTimeSharesGuard {
    using SafeERC20 for IERC20;

    /// @dev Gas given to an asset's `balanceOf`: fifty times what a plain ERC-20 needs, so an asset whose read
    ///      burns gas cannot take the whole transaction down with it.
    uint256 private constant BALANCE_READ_GAS = 100_000;
    /// @dev Gas given to one drop's claim from the box by `catchUp`, and the floor of what `sweepDrops` gives; a claim
    ///      that fails is parked (it stays claimable at the box).
    uint256 private constant DROP_CLAIM_GAS = 200_000;
    /// @dev What a sweep keeps besides a claim's cap and the 63/64 rule: it takes the next drop only with
    ///      `cap * 64 / 63 + DROP_SWEEP_RESERVE` left, so a caller cannot make an honest drop's claim fail by passing
    ///      little gas.
    uint256 private constant DROP_SWEEP_RESERVE = 60_000;
    uint256 private constant DROP_SWEEP_GAS = DROP_CLAIM_GAS * 64 / 63 + DROP_SWEEP_RESERVE;
    /// @dev Gas `catchUp` keeps for a drop besides the claim's: the booking's fixed writes. It adds the two capped
    ///      balance reads around the claim for an ERC-20, and `TREE_WRITE` for every tree node the booking writes (one
    ///      at the newest epoch, up to log2(epochs) + 1 at an old one), so it stops before a drop it could not book
    ///      instead of reverting on it.
    uint256 private constant BOOK_RESERVE = 100_000;
    /// @dev Gas for one tree node a booking writes: a fresh slot, cold.
    uint256 private constant TREE_WRITE = 25_000;
    /// @inheritdoc IHookrTimeShares
    uint256 public constant MIN_LOCK_DIVISOR = 10_000;

    /// @inheritdoc IHookrTimeShares
    uint32 public constant MIN_LOCK_DAYS = 1;
    /// @inheritdoc IHookrTimeShares
    uint32 public constant MAX_LOCK_DAYS = 3650;
    /// @inheritdoc IHookrTimeShares
    uint256 public constant MAX_LOCK_AMOUNT = type(uint128).max;
    /// @inheritdoc IHookrTimeShares
    uint16 public constant MAX_TIP_BPS = 100;
    /// @inheritdoc IHookrTimeShares
    uint256 public constant MIN_TIP_GROWTH = 0.001 ether;
    /// @inheritdoc IHookrTimeShares
    uint256 public constant MAX_ISSUE_DAYS = 366;
    /// @inheritdoc IHookrTimeShares
    uint256 public constant MAX_CLAIM_DAYS = 366;

    /// @inheritdoc IHookrTimeShares
    IHookrRevenueToken public immutable token;
    /// @inheritdoc IHookrTimeShares
    uint16 public immutable tipBps;
    /// @inheritdoc IHookrTimeShares
    uint256 public immutable tipCap;
    /// @dev The drop ledger's scale: a booking adds `amount x DROP_SCALE / held` per held revenue token, and its
    ///      rounding is below `held / DROP_SCALE` units. `SCALE` (1e36, exact for decimal amounts) while the token's
    ///      supply is at most that, else 2^128: held never passes the supply, which is below 2^128, so a drop's
    ///      rounding is under one base unit whatever the supply. Every lock's drop income, its
    ///      amount times values booked at epochs where it was part of `held`, stays below the sum of bookings times
    ///      `DROP_SCALE`, under 2^256.
    uint256 private immutable DROP_SCALE;
    /// @dev The token's assets as followed so far, native ETH first; slots from `_assetCount` on are zero.
    Currency[MAX_ASSETS] private _currencies;

    /// @inheritdoc IHookrTimeShares
    uint256 public lockedTotal;
    /// @inheritdoc IHookrTimeShares
    uint256 public lockCount;
    /// @inheritdoc IHookrTimeShares
    uint256 public nextDrop;

    /// @dev The locks made in the second of an existing settle point that are not in `lockedTotal` yet: their total,
    ///      the block of the first, and the first lock id. They are contiguous, all of one second (the last point's),
    ///      and join at the next settle (any later second), before any later lock is made: that settle writes a
    ///      point at the second after theirs and lets them in there, so their stored `lockedAt` is that second from
    ///      the start.
    uint256 private _pendingAmount;
    uint256 private _pendingTick;
    uint256 private _pendingFirst;

    /// @dev What all locks hold (active plus pending) at the end of a block in which a lock or an unlock was made.
    ///      Entry `e` is epoch `e`; block numbers strictly increase. Totals fit: the token's supply is below 2^128.
    struct Held {
        uint48 blockNumber;
        uint208 total;
    }

    Held[] private _epochs;
    /// @dev Per lock: the epoch it joined (low 128 bits) and the epoch it left (high 128 bits, zero while it holds;
    ///      a leave epoch is at least 1, since the lock's own epoch comes first). It held at a snapshot exactly when
    ///      the snapshot's epoch is at or after the join epoch and before the leave epoch.
    mapping(uint256 lockId => uint256) private _lockEpochs;
    /// @dev Per asset, a Fenwick tree over epochs (node `e + 1` is epoch `e`) of drop income per held revenue token,
    ///      scaled. It grows by one node per epoch, and each new node starts as the sum of the nodes it covers.
    mapping(uint256 asset => mapping(uint256 node => uint256)) private _dropTree;
    /// @dev Per asset, the sum of every value booked: the tree's prefix over all epochs.
    uint256[MAX_ASSETS] private _dropTotal;
    /// @dev Bit `a` set once asset `a` has a value in its tree.
    uint256 private _dropAssets;
    /// @dev Per asset and snapshot node, the rounding of the bookings at that node, scaled by `DROP_SCALE` (under one
    ///      base unit): it joins the next drop booked in that asset at the same node, so it is only ever paid to the
    ///      locks that held at that snapshot, whatever order drops are swept in, and none of it
    ///      reaches the timeline. What is left at a node is under one unit, already in the books' inflow.
    mapping(uint256 asset => mapping(uint256 node => uint256)) private _dropRest;

    mapping(uint256 lockId => Lock) private _locks;
    /// @dev Per lock, a bitmap of the days whose units were issued: word `day >> 8`, bit `day & 255`.
    mapping(uint256 lockId => mapping(uint256 word => uint256)) private _issued;
    mapping(uint256 lockId => uint256[MAX_ASSETS]) private _lockPaid;
    /// @dev Per lock and asset, scaled: its part of the carry at the moment it left (see `unlock`).
    mapping(uint256 lockId => uint256[MAX_ASSETS]) private _lockExtra;
    /// @dev Per asset: units received from the token or found here (the books' inflow), units paid out, and the
    ///      inflow plus the token's claim as of the last settle.
    uint256[MAX_ASSETS] private _pulled;
    uint256[MAX_ASSETS] private _paid;
    uint256[MAX_ASSETS] private _lastCumulative;
    /// @dev Per asset: what the token's `claim` returned on pulls whose landing could not be read (the read right after
    ///      the claim failed), and drops that no lock held at the snapshot of, since the last settle that read the
    ///      asset. It has left the token's `claimable` or the box without entering the books; an unread asset's
    ///      cumulative counts it, and a settle that reads the asset finds it as surplus and zeroes it.
    uint256[MAX_ASSETS] private _unmeasured;

    /// @param token_ The revenue token to lock: it must have code, be live, have a drop box that points back at it,
    ///        keep its clock at the block number, and have native ETH as its first asset.
    /// @param tipBps_ The roll caller's tip, at most `MAX_TIP_BPS`.
    /// @param tipCap_ The most ETH one roll pays its caller.
    constructor(IHookrRevenueToken token_, uint16 tipBps_, uint256 tipCap_) {
        if (tipBps_ > MAX_TIP_BPS || address(token_).code.length == 0) revert InvalidConfig();
        token = token_;
        tipBps = tipBps_;
        tipCap = tipCap_;
        if (!token_.live() || uint256(token_.clock()) != block.number) revert InvalidConfig();
        address box = token_.dropBox();
        if (box.code.length == 0 || IHookrDropBox(box).token() != address(token_)) revert InvalidConfig();
        _syncAssets();
        if (_assetCount == 0 || !_currencies[0].isAddressZero()) revert InvalidConfig();
        nextDrop = IHookrDropBox(box).dropCount();
        DROP_SCALE = token_.shareSupply() > SCALE ? 1 << 128 : SCALE;
    }

    /// @notice Takes native ETH from the revenue token's claims, and from anyone: whatever lands here above the
    ///         books is attributed at the next settle like income of the stretch it was found in.
    receive() external payable {}

    /// @inheritdoc IHookrTimeShares
    function currencyAt(uint256 asset) external view returns (Currency) {
        _checkAsset(asset);
        return _currencies[asset];
    }

    /// @inheritdoc IHookrTimeShares
    function minLockAmount() public view returns (uint256) {
        uint256 m = token.shareSupply() / MIN_LOCK_DIVISOR;
        return m == 0 ? 1 : m;
    }

    /// @inheritdoc IHookrTimeShares
    function lockAt(uint256 lockId) external view returns (Lock memory) {
        return _lockView(lockId);
    }

    /// @inheritdoc IHookrTimeShares
    function pendingLocks() external view returns (uint256 amount, uint256 tick, uint256 firstLock) {
        return (_pendingAmount, _pendingTick, _pendingFirst);
    }

    /// @inheritdoc IHookrTimeShares
    function heldAt(uint256 blockNumber) external view returns (uint256) {
        uint256 n = _epochsTo(blockNumber);
        return n == 0 ? 0 : _epochs[n - 1].total;
    }

    /// @inheritdoc IHookrTimeShares
    function lockEpochs(uint256 lockId) external view returns (uint256 joinEpoch, uint256 leaveEpoch) {
        _stored(lockId);
        uint256 ep = _lockEpochs[lockId];
        return (uint128(ep), ep >> 128);
    }

    /// @inheritdoc IHookrTimeShares
    function sweepable(uint256 from, uint256 max) external view returns (uint256[] memory ids, uint256 next) {
        IHookrDropBox box = IHookrDropBox(token.dropBox());
        uint256 count = box.dropCount();
        next = from < count ? from : count;
        uint256 end = max < count - next ? next + max : count;
        ids = new uint256[](end - next);
        uint256 found;
        for (; next < end; ++next) {
            if (box.claimable(next, address(this)) == 0) continue;
            if (_indexOfAsset(box.dropAt(next).asset) == type(uint256).max) continue;
            ids[found++] = next;
        }
        assembly ("memory-safe") {
            mstore(ids, found)
        }
    }

    /// @inheritdoc IHookrTimeShares
    function isIssued(uint256 lockId, uint256 day) external view returns (bool) {
        _stored(lockId);
        return _issued[lockId][day >> 8] & (uint256(1) << (day & 255)) != 0;
    }

    /// @inheritdoc IHookrTimeShares
    function pulled(uint256 asset) external view returns (uint256) {
        _checkAsset(asset);
        return _pulled[asset];
    }

    /// @inheritdoc IHookrTimeShares
    function paid(uint256 asset) external view returns (uint256) {
        _checkAsset(asset);
        return _paid[asset];
    }

    /// @inheritdoc IHookrTimeShares
    function held(uint256 asset) external view returns (uint256) {
        _checkAsset(asset);
        (uint256 amount, bool ok) = _held(_currencies[asset]);
        if (!ok) revert AssetUnreadable(asset);
        return amount;
    }

    /// @inheritdoc IHookrTimeShares
    function dayIndex(uint256 day, uint256 asset) external view returns (uint256) {
        _checkAsset(asset);
        return _dayIndexesPreview(day, _nowIndex())[asset];
    }

    /// @inheritdoc IHookrTimeShares
    function claimable(address holder, uint256 day, uint256 asset) external view returns (uint256) {
        _checkAsset(asset);
        uint256[MAX_ASSETS] memory u = _dayIndexesPreview(day, _nowIndex());
        Holder storage h = _holders[holder][day][asset];
        return (h.credit + balanceOf[holder][day] * (u[asset] - h.index)) / SCALE;
    }

    /// @inheritdoc IHookrTimeShares
    function lockClaimable(uint256 lockId, uint256 asset) external view returns (uint256) {
        Lock memory l = _lockView(lockId);
        _checkAsset(asset);
        if (l.lockedAt == 0) return 0;
        return _lockOwed(lockId, l, asset, _nowIndex(), true) - _lockPaid[lockId][asset];
    }

    /// @inheritdoc IHookrTimeShares
    /// @dev Settles first, so the stretch that ends now was earned by the locks that were active before this one
    ///      (and earlier pending locks join). When that settle wrote the point at this second, the lock joins
    ///      `lockedTotal` at once. When a point already stood at this second, growth found since it waits in the
    ///      carry for the next stretch, which the lock must not share: it is pending until the next settle, which
    ///      gives that carry to the stretch up to the next second and lets the lock in from there, so its days never
    ///      move. Either way it is in the drop ledger from this block on. The transfer must land exactly; the token
    ///      refuses nothing on this path.
    function lock(uint256 amount, uint32 numberOfDays) external nonReentrant returns (uint256 lockId) {
        if (amount == 0 || amount > MAX_LOCK_AMOUNT || amount < minLockAmount()) revert InvalidAmount(amount);
        if (numberOfDays != FOREVER && (numberOfDays < MIN_LOCK_DAYS || numberOfDays > MAX_LOCK_DAYS)) {
            revert InvalidDays(numberOfDays);
        }
        bool fresh = _lastTime() < block.timestamp;
        _settle(false);
        uint256 before = token.balanceOf(address(this));
        if (!token.transferFrom(msg.sender, address(this), amount) || token.balanceOf(address(this)) != before + amount)
        {
            revert InexactTransfer();
        }
        lockId = lockCount++;
        uint64 joinedAt = uint64(block.timestamp);
        if (fresh) {
            lockedTotal += amount;
            emit Activated(lockId, amount, joinedAt);
        } else {
            if (_pendingAmount == 0) {
                _pendingTick = block.number;
                _pendingFirst = lockId;
            }
            _pendingAmount += amount;
            ++joinedAt;
        }
        _lockEpochs[lockId] = _moveHeld();
        // The day grid is below 2^32 for the next 11 million years; a lock's days fit with room.
        uint32 first = uint32(HookrDays.dayOf(block.timestamp)) + 1;
        uint32 last = numberOfDays == FOREVER ? FOREVER : first + numberOfDays - 1;
        _locks[lockId] = Lock(msg.sender, joinedAt, first, uint128(amount), last, 0);
        emit Locked(lockId, msg.sender, amount, first, last);
    }

    /// @inheritdoc IHookrTimeShares
    function issue(uint256 lockId, uint256 day, address to) external nonReentrant {
        if (msg.sender != _stored(lockId).owner) revert Unauthorized(msg.sender);
        _checkRecipient(to);
        _issue(lockId, _activeLock(lockId), day, to);
    }

    /// @inheritdoc IHookrTimeShares
    function issueRange(uint256 lockId, uint256 firstDay, uint256 lastDay, address to) external nonReentrant {
        if (msg.sender != _stored(lockId).owner) revert Unauthorized(msg.sender);
        _checkRecipient(to);
        if (lastDay < firstDay) revert InvalidDay(lastDay);
        uint256 count = lastDay - firstDay + 1;
        if (count > MAX_ISSUE_DAYS) revert TooManyDays(count);
        Lock memory l = _activeLock(lockId);
        for (uint256 day = firstDay; day <= lastDay; ++day) {
            _issue(lockId, l, day, to);
        }
    }

    /// @inheritdoc IHookrTimeShares
    /// @dev Settles first, so the tail (last day's end to now) is written at this point. Never touches the drop box:
    ///      the leave epoch written here keeps the lock in every drop whose snapshot is before this block, whenever
    ///      that drop is swept, and out of every later one.
    function unlock(uint256 lockId, address to) external nonReentrant {
        Lock storage stored = _stored(lockId);
        if (msg.sender != stored.owner) revert Unauthorized(msg.sender);
        _checkRecipient(to);
        if (stored.lastDay == FOREVER) revert NeverEnds(lockId);
        if (stored.unlockedAt != 0) revert AlreadyUnlocked(lockId);
        _settle(false);
        Lock memory l = _lockView(lockId);
        if (l.lockedAt == 0) revert LockPending(lockId);
        uint256 endsAt = HookrDays.endOf(l.lastDay);
        if (block.timestamp < endsAt) revert NotEnded(lockId, endsAt);
        stored.unlockedAt = uint64(block.timestamp);
        uint256 amount = l.amount;
        // Growth found in the second of the last point waits in the carry for the next point, which the leaver is not
        // in: its part of it is booked to the lock now.
        _lockExtra[lockId] = _takeCarryShare(amount, lockedTotal);
        lockedTotal -= amount;
        _lockEpochs[lockId] |= _moveHeld() << 128;
        uint256 before = token.balanceOf(to);
        if (!token.transfer(to, amount) || token.balanceOf(to) != before + amount) revert InexactTransfer();
        emit Unlocked(lockId, to, amount);
    }

    /// @inheritdoc IHookrTimeShares
    function settle() external nonReentrant {
        _settle(false);
    }

    /// @inheritdoc IHookrTimeShares
    function syncAssets() external nonReentrant {
        _syncAssets();
    }

    /// @inheritdoc IHookrTimeShares
    /// @dev Takes a drop only with `DROP_SWEEP_GAS + BOOK_RESERVE` plus `TREE_WRITE` per tree node its booking
    ///      writes left, so a caller cannot make an honest claim fail by passing little gas, and a drop at an old epoch
    ///      stops the walk instead of reverting it. A claim that fails anyway is parked: it stays claimable at the box
    ///      for a later `sweepDrops`. First an empty claim at the box: it reverts while the
    ///      box's lock is held (a call from inside a drop's `transferFrom` or a claim's payout), where every claim
    ///      would fail and the walk would pass every drop; the revert comes through.
    function catchUp(uint256 max) external nonReentrant returns (bool done) {
        _syncAssets();
        IHookrDropBox box = IHookrDropBox(token.dropBox());
        uint256 count = box.dropCount();
        _probeBox(box);
        uint256 i = nextDrop;
        uint256 taken;
        for (; i < count; ++i) {
            if (gasleft() < DROP_SWEEP_GAS + BOOK_RESERVE) break;
            if (box.claimable(i, address(this)) == 0) continue;
            IHookrDropBox.Drop memory d = box.dropAt(i);
            uint256 a = _indexOfAsset(d.asset);
            if (a == type(uint256).max) continue;
            if (taken == max) break;
            uint256 node = _epochsTo(d.snapshotBlock);
            uint256 reads = a == 0 ? 0 : 2 * BALANCE_READ_GAS;
            if (gasleft() < DROP_SWEEP_GAS + BOOK_RESERVE + reads + TREE_WRITE * _treeWrites(node)) break;
            ++taken;
            _takeDrop(box, i, a, node, DROP_CLAIM_GAS);
        }
        nextDrop = i;
        return i == count;
    }

    /// @inheritdoc IHookrTimeShares
    /// @dev Pulls first, so the tip is paid from cash that is here; the growth the settle measures is the same
    ///      before and after a pull (what the token owed became what was received).
    function roll() external nonReentrant returns (uint256 tip) {
        _syncAssets();
        _pullAll();
        tip = _settle(true);
        emit Rolled(msg.sender, tip);
        if (tip != 0) _send(_currencies[0], msg.sender, tip);
    }

    /// @inheritdoc IHookrTimeShares
    /// @dev Each drop is claimed on its own through a call capped at `claimGas` (at least `DROP_CLAIM_GAS`), so one
    ///      refusing drop parks instead of reverting the batch and burns at most the cap the caller chose, and its
    ///      landing is measured. A drop whose claim needs more than the default cap (an asset with a costly transfer,
    ///      another revenue token) is booked by a caller that names a cap above it. No
    ///      settle: a drop is never timeline income.
    function sweepDrops(uint256[] calldata dropIds, uint256 claimGas)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (claimGas < DROP_CLAIM_GAS) claimGas = DROP_CLAIM_GAS;
        _syncAssets();
        IHookrDropBox box = IHookrDropBox(token.dropBox());
        uint256 m = dropIds.length;
        amounts = new uint256[](m);
        for (uint256 j; j < m; ++j) {
            uint256 id = dropIds[j];
            IHookrDropBox.Drop memory d = box.dropAt(id);
            uint256 a = _indexOfAsset(d.asset);
            if (a == type(uint256).max) revert UnlistedDrop(id);
            if (box.claimable(id, address(this)) == 0) continue;
            if (gasleft() < claimGas * 64 / 63 + DROP_SWEEP_RESERVE) revert DropSweepGas();
            amounts[j] = _takeDrop(box, id, a, _epochsTo(d.snapshotBlock), claimGas);
        }
    }

    /// @notice Moves `amount` units of day `id` to `receiver` (ERC-6909).
    /// @dev Settles first when the day has started and is not final at the last point (still open, or ended after the
    ///      last point), so the sender is checkpointed at now and keeps what its units earned up to the move, and the
    ///      receiver starts from now. Guarded, since the settle reads the token and the assets.
    function transfer(address receiver, uint256 id, uint256 amount) public override nonReentrant returns (bool) {
        _settleOpenDay(id);
        return super.transfer(receiver, id, amount);
    }

    /// @notice Moves `amount` units of day `id` from `sender` to `receiver` (ERC-6909).
    /// @dev Settles first, as `transfer`.
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        public
        override
        nonReentrant
        returns (bool)
    {
        _settleOpenDay(id);
        return super.transferFrom(sender, receiver, id, amount);
    }

    /// @dev A settle when day `day` has started and its end is after the last point; nothing for a day not yet begun
    ///      (it has no income) or one that is final (its index never moves again).
    function _settleOpenDay(uint256 day) private {
        if (day <= FOREVER && HookrDays.startOf(day) < block.timestamp && HookrDays.endOf(day) > _lastTime()) {
            _settle(false);
        }
    }

    /// @inheritdoc IHookrTimeShares
    /// @dev Settles only when the day is still open at the last point; a day that has ended and been settled is
    ///      final and needs no new point.
    function claim(uint256 day, uint256 asset, address to) external nonReentrant returns (uint256 amount) {
        _syncAssets();
        _checkAsset(asset);
        _checkRecipient(to);
        if (day > FOREVER) revert InvalidDay(day);
        if (HookrDays.startOf(day) > block.timestamp) revert NothingToClaim();
        if (HookrDays.endOf(day) > _lastTime()) _settle(false);
        _checkpoint(msg.sender, day, _dayIndexes(day));
        amount = _payHolder(msg.sender, day, asset, to);
        if (amount == 0) revert NothingToClaim();
    }

    /// @inheritdoc IHookrTimeShares
    /// @dev One settle when any listed day is still open, one payout for all of them, each day's credit reduced by
    ///      its part in order; a day listed twice pays once.
    function claimMany(uint256[] calldata days_, uint256 asset, address to)
        external
        nonReentrant
        returns (uint256 amount)
    {
        uint256 m = days_.length;
        if (m > MAX_CLAIM_DAYS) revert TooManyDays(m);
        _syncAssets();
        _checkAsset(asset);
        _checkRecipient(to);
        uint64 lastT = _lastTime();
        bool open;
        for (uint256 j; j < m; ++j) {
            if (days_[j] > FOREVER) revert InvalidDay(days_[j]);
            if (HookrDays.endOf(days_[j]) > lastT) open = true;
        }
        if (open) _settle(false);
        uint256 owed;
        for (uint256 j; j < m; ++j) {
            uint256 day = days_[j];
            _checkpoint(msg.sender, day, _dayIndexes(day));
            owed += _holders[msg.sender][day][asset].credit / SCALE;
        }
        if (owed == 0) revert NothingToClaim();
        uint256 available = _available(asset, owed);
        if (available == 0) revert NothingToClaim();
        uint256 left = available;
        for (uint256 j; j < m && left != 0; ++j) {
            uint256 day = days_[j];
            Holder storage h = _holders[msg.sender][day][asset];
            uint256 credit = h.credit;
            uint256 take = credit / SCALE;
            if (take == 0) continue;
            if (take > left) take = left;
            h.credit = credit - take * SCALE;
            left -= take;
            emit IncomeClaimed(msg.sender, day, asset, to, take);
        }
        amount = available - left;
        _paid[asset] += amount;
        _send(_currencies[asset], to, amount);
    }

    /// @inheritdoc IHookrTimeShares
    function claimLock(uint256 lockId, uint256 asset, address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != _stored(lockId).owner) revert Unauthorized(msg.sender);
        _syncAssets();
        _checkAsset(asset);
        _checkRecipient(to);
        _settle(false);
        Lock memory l = _lockView(lockId);
        if (l.lockedAt == 0) revert LockPending(lockId);
        Preview memory none;
        uint256 owed = _lockOwed(lockId, l, asset, none, false) - _lockPaid[lockId][asset];
        if (owed == 0) revert NothingToClaim();
        amount = _available(asset, owed);
        if (amount == 0) revert NothingToClaim();
        _lockPaid[lockId][asset] += amount;
        _paid[asset] += amount;
        _send(_currencies[asset], to, amount);
        emit LockIncomeClaimed(lockId, asset, to, amount);
    }

    /// @dev Follows the revenue token's asset list: lists each asset it added since the last look, at most eight.
    ///      Idempotent. Native ETH is checked first in the constructor.
    function _syncAssets() private {
        uint256 have = _assetCount;
        uint256 n = token.assetCount();
        if (n > MAX_ASSETS) n = MAX_ASSETS;
        if (n <= have) return;
        for (uint256 i = have; i < n; ++i) {
            Currency c = token.assetAt(i).currency;
            _currencies[i] = c;
            emit AssetListed(i, c);
        }
        _assetCount = n;
    }

    /// @dev Asset index of a drop box asset address, or `type(uint256).max` when the token does not pay it.
    function _indexOfAsset(address asset) private view returns (uint256) {
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            if (Currency.unwrap(_currencies[i]) == asset) return i;
        }
        return type(uint256).max;
    }

    /// @dev Lock `lockId` as stored, or `UnknownLock` past the last one.
    function _stored(uint256 lockId) private view returns (Lock storage l) {
        if (lockId >= lockCount) revert UnknownLock(lockId);
        l = _locks[lockId];
    }

    /// @dev Lock `lockId` as it stands: `lockedAt` is the lock itself when it counted at once, otherwise the second
    ///      after it, where the settle that lets it in writes a point (zero while pending). That second is at or
    ///      before its first day's start, so its days are the ones it was made with.
    function _lockView(uint256 lockId) private view returns (Lock memory l) {
        l = _stored(lockId);
        if (_pendingAmount != 0 && lockId >= _pendingFirst) l.lockedAt = 0;
    }

    /// @dev The lock, activated first when a settle can do it now; `LockPending` when it is still pending.
    function _activeLock(uint256 lockId) private returns (Lock memory l) {
        if (_pendingAmount != 0 && lockId >= _pendingFirst) _settle(false);
        l = _lockView(lockId);
        if (l.lockedAt == 0) revert LockPending(lockId);
    }

    /// @dev `box.claim([id], this)` with `cap` gas and no more than three words of return data copied: whether it
    ///      succeeded and what it paid.
    function _tryClaim(IHookrDropBox box, uint256 id, uint256 cap) private returns (bool ok, uint256 got) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        bytes memory data = abi.encodeCall(IHookrDropBox.claim, (ids, address(this)));
        address target = address(box);
        assembly ("memory-safe") {
            let out := mload(0x40)
            mstore(0x40, add(out, 96))
            ok := call(cap, target, 0, add(data, 32), mload(data), out, 96)
            if ok {
                ok := iszero(lt(returndatasize(), 96))
                got := mload(add(out, 64))
            }
        }
    }

    /// @dev An empty `box.claim` from this contract, which claims nothing and pays nothing: it reverts while the box's
    ///      transient lock is held, and the revert (the box's `Reentered`) comes through.
    function _probeBox(IHookrDropBox box) private {
        bytes4 selector = IHookrDropBox.claim.selector;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, selector)
            mstore(add(p, 4), 0x40)
            mstore(add(p, 36), address())
            mstore(add(p, 68), 0)
            if iszero(call(gas(), box, 0, p, 100, 0, 0)) {
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
    }

    /// @dev Claims this contract's share of drop `id` (asset `a`, its snapshot's tree node `node`) with `cap` gas and
    ///      books it by its snapshot. The books take what landed, measured by two reads around the claim, never more
    ///      than the box says it paid (an asset that charges on the way in); what the box paid when either read fails.
    ///      A claim that fails is parked: an event, and the drop stays claimable at the box. Returns what was booked.
    function _takeDrop(IHookrDropBox box, uint256 id, uint256 a, uint256 node, uint256 cap)
        private
        returns (uint256 booked)
    {
        Currency c = _currencies[a];
        (uint256 before, bool okB) = _held(c);
        (bool ok, uint256 got) = _tryClaim(box, id, cap);
        if (!ok) {
            emit DropParked(id, a);
            return 0;
        }
        (uint256 after_, bool okA) = _held(c);
        if (okB && okA) {
            uint256 landed = after_ > before ? after_ - before : 0;
            if (landed < got) got = landed;
        }
        booked = _book(a, got, node);
        emit DropSwept(id, a, booked);
    }

    /// @dev Books `amount` of asset `a`, a drop whose snapshot is at tree node `node` (`_epochsTo` of its snapshot
    ///      block), to the locks that held at the end of that block: `amount x DROP_SCALE / held` per held revenue
    ///      token at the snapshot's epoch, the rounding kept for the next drop in the asset at the same node. It enters
    ///      the cash and the mark together, so a settle never finds it as growth. With nothing held by locks then
    ///      (only revenue tokens sent here outside a lock), no lock earned it: it is found income of the timeline,
    ///      booked like a pull that could not be measured.
    function _book(uint256 a, uint256 amount, uint256 node) private returns (uint256 booked) {
        uint256 eligible = node == 0 ? 0 : _epochs[node - 1].total;
        if (eligible == 0) {
            _unmeasured[a] += amount;
            return amount;
        }
        uint256 inflow = _pulled[a];
        uint256 room = inflow < type(uint128).max ? type(uint128).max - inflow : 0;
        booked = amount < room ? amount : room;
        if (booked == 0) return 0;
        // booked <= 2^128 - 1 - inflow and the rest is below held <= DROP_SCALE <= 2^128, so this is below 2^256; v is
        // never zero.
        uint256 scaled = booked * DROP_SCALE + _dropRest[a][node];
        uint256 v = scaled / eligible;
        _dropRest[a][node] = scaled - v * eligible;
        uint256 len = _epochs.length;
        for (uint256 k = node; k <= len; k += _low(k)) {
            _dropTree[a][k] += v;
        }
        _dropTotal[a] += v;
        _dropAssets |= 1 << a;
        _pulled[a] = inflow + booked;
        _lastCumulative[a] += booked;
    }

    /// @dev Writes what all locks hold now as this block's epoch (one epoch per block, its total the end-of-block
    ///      value) and returns it. A new epoch's tree node starts as the sum of the nodes it covers, for every asset
    ///      with a drop, so every prefix stays right while the tree grows.
    function _moveHeld() private returns (uint256 epoch) {
        uint256 total = lockedTotal + _pendingAmount;
        uint256 len = _epochs.length;
        if (len != 0 && _epochs[len - 1].blockNumber == block.number) {
            _epochs[len - 1].total = uint208(total);
            return len - 1;
        }
        _epochs.push(Held(uint48(block.number), uint208(total)));
        uint256 mask = _dropAssets;
        if (mask != 0) {
            uint256 node = len + 1;
            uint256 floor = node - _low(node);
            for (uint256 a; mask != 0; ++a) {
                if (mask & 1 != 0) {
                    uint256 sum;
                    for (uint256 k = len; k > floor; k -= _low(k)) {
                        sum += _dropTree[a][k];
                    }
                    if (sum != 0) _dropTree[a][node] = sum;
                }
                mask >>= 1;
            }
        }
        return len;
    }

    /// @dev The number of epochs at or before `blockNumber`: the Fenwick node of a snapshot at that block (zero
    ///      before the first lock).
    function _epochsTo(uint256 blockNumber) private view returns (uint256 low) {
        uint256 high = _epochs.length;
        if (high != 0 && _epochs[high - 1].blockNumber <= blockNumber) return high;
        while (low < high) {
            uint256 mid = (low + high) >> 1;
            if (_epochs[mid].blockNumber > blockNumber) high = mid;
            else low = mid + 1;
        }
    }

    /// @dev Lock `lockId`'s drop income in asset `a`, scaled by `DROP_SCALE`: `amount` times the values booked at the
    ///      epochs it held in, from its join epoch to before its leave epoch (to the newest while it holds).
    function _dropOwedScaled(uint256 lockId, uint256 amount, uint256 a) private view returns (uint256) {
        if ((_dropAssets >> a) & 1 == 0) return 0;
        uint256 ep = _lockEpochs[lockId];
        uint256 out = ep >> 128;
        uint256 high = out == 0 ? _dropTotal[a] : _prefix(a, out);
        return amount * (high - _prefix(a, uint128(ep)));
    }

    /// @dev The sum of asset `a`'s drop values over the first `k` epochs.
    function _prefix(uint256 a, uint256 k) private view returns (uint256 sum) {
        for (; k != 0; k -= _low(k)) {
            sum += _dropTree[a][k];
        }
    }

    /// @dev The lowest set bit of `k`.
    function _low(uint256 k) private pure returns (uint256) {
        unchecked {
            return k & (0 - k);
        }
    }

    /// @dev How many tree nodes a booking at node `node` writes: none for a snapshot before the first epoch.
    function _treeWrites(uint256 node) private view returns (uint256 count) {
        if (node == 0) return 0;
        uint256 len = _epochs.length;
        for (uint256 k = node; k <= len; k += _low(k)) {
            ++count;
        }
    }

    /// @dev Lets the pending locks into the total at `when`, the second after theirs.
    function _activate(uint64 when) private {
        uint256 amount = _pendingAmount;
        lockedTotal += amount;
        _pendingAmount = 0;
        emit Activated(_pendingFirst, amount, when);
    }

    /// @dev This contract's balance of `c`, and whether it could be read: native from the balance; an ERC-20 through
    ///      a bounded `balanceOf` call whose answer must be at least a word. A read that reverts, answers short or
    ///      runs out of its gas is `false`, so one asset's trouble never stops a settle or another asset's payout.
    function _held(Currency c) private view returns (uint256 amount, bool ok) {
        if (c.isAddressZero()) return (address(this).balance, true);
        address asset = Currency.unwrap(c);
        uint256 cap = BALANCE_READ_GAS;
        assembly ("memory-safe") {
            mstore(0x00, shl(224, 0x70a08231))
            mstore(0x04, address())
            ok := staticcall(cap, asset, 0x00, 0x24, 0x00, 0x20)
            ok := and(ok, iszero(lt(returndatasize(), 0x20)))
            if ok { amount := mload(0x00) }
        }
    }

    /// @dev A payout or unit recipient: anyone but zero and this contract.
    function _checkRecipient(address to) private view {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
    }

    /// @dev Lock `l`'s units of day `day` to `to`: once, within the lock's days.
    function _issue(uint256 lockId, Lock memory l, uint256 day, address to) private {
        if (day < l.firstDay || day > l.lastDay) revert DayOutOfLock(lockId, day);
        uint256 word = day >> 8;
        uint256 bit = uint256(1) << (day & 255);
        uint256 bits = _issued[lockId][word];
        if (bits & bit != 0) revert AlreadyIssued(lockId, day);
        _issued[lockId][word] = bits | bit;
        uint256 amount = l.amount;
        _mintUnits(to, day, amount);
        emit Issued(lockId, day, to, amount);
    }

    /// @dev Per asset, what grew since the last settle: the books' inflow plus what the token owes now, less the
    ///      same sum at the last settle. `surplus` is what sits here above the books (received less paid) and joins
    ///      the inflow at the settle, clamped so the inflow never passes 2^128 - 1 (the token's own ceiling for an
    ///      asset over its life); what is above that stays unbooked, and every index and credit keeps the bounds
    ///      HookrIncomeTimeline states. An asset whose balance cannot be read (`unread`) books no surplus this time,
    ///      counts `_unmeasured` (what pulls whose landing could not be read took from the token's `claimable`
    ///      without entering the books), and never moves its mark down; that pull is found as surplus once the asset
    ///      reads again, already attributed, so a stretch that ends while the asset is unread keeps its income.
    ///      A sum that fell on a read asset (an asset that charged this contract on a claim, or a balance that fell
    ///      on its own) grows by nothing and resets the mark.
    function _measure()
        private
        view
        returns (
            uint256[MAX_ASSETS] memory growth,
            uint256[MAX_ASSETS] memory cumulative,
            uint256[MAX_ASSETS] memory surplus,
            bool[MAX_ASSETS] memory unread
        )
    {
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            uint256 inflow = _pulled[i];
            uint256 cash = inflow - _paid[i];
            (uint256 heldNow, bool ok) = _held(_currencies[i]);
            if (!ok) {
                unread[i] = true;
            } else if (heldNow > cash) {
                uint256 room = inflow < type(uint128).max ? type(uint128).max - inflow : 0;
                uint256 found = heldNow - cash;
                surplus[i] = found < room ? found : room;
            }
            cumulative[i] = inflow + surplus[i] + token.claimable(address(this), i);
            uint256 last = _lastCumulative[i];
            if (unread[i]) {
                cumulative[i] += _unmeasured[i];
                if (cumulative[i] < last) cumulative[i] = last;
            }
            if (cumulative[i] > last) growth[i] = cumulative[i] - last;
        }
    }

    /// @dev The points a settle now would write, as `_settle` writes them: with pending locks, the second after the
    ///      last point takes its part of the growth and the carry over the locks before them, and the rest of the
    ///      stretch goes over all; without, one point now. A point keeps the last index when nothing is locked (the
    ///      growth waits in the carry), and nothing moves when no time has passed since the last point.
    function _nowIndex() private view returns (Preview memory p) {
        uint64 lastT = _lastTime();
        p.from = lastT;
        p.fromIndex = _lineAt(lastT);
        if (block.timestamp <= lastT) return _same(p);
        (uint256[MAX_ASSETS] memory growth,,,) = _measure();
        uint256 n = _assetCount;
        uint256 locked = lockedTotal;
        uint256[MAX_ASSETS] memory c;
        for (uint256 i; i < n; ++i) {
            c[i] = _carry[i];
        }
        if (_pendingAmount != 0) {
            p.from = lastT + 1;
            uint256 span = block.timestamp - lastT;
            for (uint256 i; i < n; ++i) {
                uint256 part = growth[i] / span;
                growth[i] -= part;
                c[i] += part * SCALE;
                if (locked != 0) {
                    p.fromIndex[i] += c[i] / locked;
                    c[i] %= locked;
                }
            }
            locked += _pendingAmount;
            if (block.timestamp == p.from) return _same(p);
        }
        for (uint256 i; i < n; ++i) {
            p.nowIndex[i] = p.fromIndex[i] + (locked == 0 ? 0 : (growth[i] * SCALE + c[i]) / locked);
        }
    }

    /// @dev `p` with its now index equal to its from index (a settle now writes at most one point and moves nothing).
    function _same(Preview memory p) private pure returns (Preview memory) {
        p.nowIndex = p.fromIndex;
        return p;
    }

    /// @dev Writes the settle point: books the surplus, moves the marks, takes the tip off the ETH growth when this
    ///      is a roll, and attributes the growth over what is locked. The tip is `tipBps` of the ETH growth, only
    ///      when that is at least `MIN_TIP_GROWTH`, at most `tipCap`, never more than the ETH on the books.
    function _settle(bool isRoll) private returns (uint256 tip) {
        _syncAssets();
        // Pending locks join at the first point after their second: this settle writes it.
        bool activate = _pendingAmount != 0 && block.timestamp > _lastTime();
        (
            uint256[MAX_ASSETS] memory growth,
            uint256[MAX_ASSETS] memory cumulative,
            uint256[MAX_ASSETS] memory surplus,
            bool[MAX_ASSETS] memory unread
        ) = _measure();
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            if (unread[i]) emit AssetUnread(i);
            if (surplus[i] != 0) _pulled[i] += surplus[i];
            if (!unread[i] && _unmeasured[i] != 0) _unmeasured[i] = 0;
            if (cumulative[i] != _lastCumulative[i]) _lastCumulative[i] = cumulative[i];
        }
        if (isRoll && tipBps != 0 && growth[0] >= MIN_TIP_GROWTH) {
            tip = growth[0] * tipBps / 10_000;
            if (tip > tipCap) tip = tipCap;
            uint256 cash = _pulled[0] - _paid[0];
            if (tip > cash) tip = cash;
            uint256 balance = address(this).balance;
            if (tip > balance) tip = balance;
            if (tip != 0) {
                growth[0] -= tip;
                _paid[0] += tip;
            }
        }
        if (activate) {
            // The pending locks were made in the second of the last point, after it; growth found since waits in the
            // carry. A point at the next second gives that carry, and that second's part of the growth found now
            // (the line is straight between points), to the locks before them; they join there and share the rest.
            uint64 next = _lastTime() + 1;
            uint256 span = block.timestamp - (next - 1);
            uint256[MAX_ASSETS] memory part;
            for (uint256 i; i < n; ++i) {
                part[i] = growth[i] / span;
                growth[i] -= part[i];
            }
            _attribute(part, lockedTotal, next);
            _activate(next);
        }
        _attribute(growth, lockedTotal, uint64(block.timestamp));
    }

    /// @dev Claims every asset the token owes this contract, each on its own: a claim that reverts leaves that
    ///      asset's credit at the token for a later roll and stops nothing else. What lands is what the books take.
    function _pullAll() private {
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            if (token.claimable(address(this), i) != 0) _pullAsset(i);
        }
    }

    /// @dev The books take what the claim made land, measured by two reads around it: nothing when the asset cannot
    ///      be read before the claim (no claim then, `AssetUnread`), and nothing when it cannot be read after it or
    ///      the balance fell (what did land is found as surplus by a later settle). When it cannot be read after,
    ///      what the claim returned is kept in `_unmeasured` until a settle reads the asset, so the books' cumulative
    ///      does not lose it while the asset stays unread.
    function _pullAsset(uint256 asset) private {
        Currency c = _currencies[asset];
        (uint256 before, bool ok) = _held(c);
        if (!ok) {
            emit AssetUnread(asset);
            return;
        }
        try token.claim(asset, address(this)) returns (uint256 claimed) {
            (uint256 after_, bool okAfter) = _held(c);
            if (!okAfter) _unmeasured[asset] += claimed;
            uint256 landed = okAfter && after_ > before ? after_ - before : 0;
            _pulled[asset] += landed;
            emit Pulled(asset, landed);
        } catch {
            emit PullFailed(asset);
        }
    }

    /// @dev What of `owed` in asset `asset` can be paid now: the cash on the books, after pulling the asset from the
    ///      token when the books are short, and never more than is held; nothing while the asset cannot be read.
    function _available(uint256 asset, uint256 owed) private returns (uint256) {
        Currency c = _currencies[asset];
        (, bool ok) = _held(c);
        if (!ok) return 0;
        uint256 cash = _pulled[asset] - _paid[asset];
        if (cash < owed && token.claimable(address(this), asset) != 0) {
            _pullAsset(asset);
            cash = _pulled[asset] - _paid[asset];
        }
        (uint256 heldNow, bool okNow) = _held(c);
        if (!okNow) return 0;
        if (cash > heldNow) cash = heldNow;
        return owed < cash ? owed : cash;
    }

    /// @dev Pays `holder`'s settled credit in asset `asset` of day `day` to `to`, the lesser of what it is owed and
    ///      what can be paid; zero, and nothing written, when nothing can be paid.
    function _payHolder(address holder, uint256 day, uint256 asset, address to) private returns (uint256 amount) {
        Holder storage h = _holders[holder][day][asset];
        uint256 credit = h.credit;
        uint256 owed = credit / SCALE;
        if (owed == 0) return 0;
        amount = _available(asset, owed);
        if (amount == 0) return 0;
        h.credit = credit - amount * SCALE;
        _paid[asset] += amount;
        _send(_currencies[asset], to, amount);
        emit IncomeClaimed(holder, day, asset, to, amount);
    }

    /// @dev Lock `l`'s own income in asset `asset`, in units: its amount times the index growth from the lock to its
    ///      first day's start, plus from its last day's end to the unlock (or to now while it is still here), plus
    ///      its part of the carry when it left, over `SCALE`; plus its drop income over `DROP_SCALE`. On the settled
    ///      line, or on the line extended to now by `p` when `preview`.
    function _lockOwed(uint256 lockId, Lock memory l, uint256 asset, Preview memory p, bool preview)
        private
        view
        returns (uint256)
    {
        uint256 amount = l.amount;
        uint256 lockedAt = l.lockedAt;
        uint256 firstStart = HookrDays.startOf(l.firstDay);
        uint256 scaled = amount * (_at(firstStart, p, preview)[asset] - _at(lockedAt, p, preview)[asset])
            + _lockExtra[lockId][asset];
        if (l.lastDay != FOREVER) {
            uint256 tailStart = HookrDays.endOf(l.lastDay);
            uint256 tailEnd = l.unlockedAt != 0 ? l.unlockedAt : block.timestamp;
            if (tailEnd > tailStart) {
                scaled += amount * (_at(tailEnd, p, preview)[asset] - _at(tailStart, p, preview)[asset]);
            }
        }
        return scaled / SCALE + _dropOwedScaled(lockId, amount, asset) / DROP_SCALE;
    }

    function _at(uint256 t, Preview memory p, bool preview) private view returns (uint256[MAX_ASSETS] memory) {
        return preview ? _lineAtPreview(uint64(t), p) : _lineAt(uint64(t));
    }

    /// @dev Delivers `amount` of `c` to `to`: native by call, an ERC-20 by a transfer that must take exactly
    ///      `amount` out of this contract (an asset that charges this contract on the way out is refused, so it can
    ///      never eat into what the other holders are owed).
    function _send(Currency c, address to, uint256 amount) private {
        if (c.isAddressZero()) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
            return;
        }
        IERC20 erc = IERC20(Currency.unwrap(c));
        uint256 before = erc.balanceOf(address(this));
        erc.safeTransfer(to, amount);
        if (erc.balanceOf(address(this)) != before - amount) revert InexactTransfer();
    }
}
