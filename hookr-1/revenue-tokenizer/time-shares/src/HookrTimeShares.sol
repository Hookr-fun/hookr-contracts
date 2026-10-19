// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrDropBox} from "fee-tokenizer/interfaces/IHookrDropBox.sol";
import {IHookrRevenueToken} from "fee-tokenizer/interfaces/IHookrRevenueToken.sol";
import {HookrDayUnits} from "./base/HookrDayUnits.sol";
import {HookrIncomeTimeline} from "./base/HookrIncomeTimeline.sol";
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
///      earned, read off the timeline at the day's two ends. The income a lock earns outside its days (from the lock
///      to its first day, and from its last day to the unlock) belongs to the locker and is claimed per lock.
///      Payouts pay the lesser of what is owed and the cash on the books, the rest stays owed, and a short asset is
///      pulled from the token first. The token's other income path, its drop box, credits this contract's locked
///      balance too; `sweepDrops` claims that share here, where the next settle books it. An asset whose balance
///      cannot be read is left out of a settle (nothing of it booked, nothing attributed) instead of stopping it,
///      so locks, unlocks and the other assets' claims never depend on one asset's reads. No owner, no pause;
///      `roll()`, `settle()`, `sweepDrops()` and the issue of a day's units are the only calls that are not a
///      holder's own.
contract HookrTimeShares is HookrDayUnits, HookrTimeSharesGuard {
    using SafeERC20 for IERC20;

    /// @dev Gas given to an asset's `balanceOf`: a hundred times what a plain ERC-20 needs, so an asset whose read
    ///      burns gas cannot take the whole transaction down with it.
    uint256 private constant BALANCE_READ_GAS = 200_000;

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
    /// @dev The token's assets, native ETH first; unused slots are zero and never read.
    Currency private immutable _currency0;
    Currency private immutable _currency1;
    Currency private immutable _currency2;
    Currency private immutable _currency3;

    /// @inheritdoc IHookrTimeShares
    uint256 public lockedTotal;
    /// @inheritdoc IHookrTimeShares
    uint256 public lockCount;

    mapping(uint256 lockId => Lock) private _locks;
    /// @dev Per lock, a bitmap of the days whose units were issued: word `day >> 8`, bit `day & 255`.
    mapping(uint256 lockId => mapping(uint256 word => uint256)) private _issued;
    mapping(uint256 lockId => uint256[MAX_ASSETS]) private _lockPaid;
    /// @dev Per asset: units received from the token or found here (the books' inflow), units paid out, and the
    ///      inflow plus the token's claim as of the last settle.
    uint256[MAX_ASSETS] private _pulled;
    uint256[MAX_ASSETS] private _paid;
    uint256[MAX_ASSETS] private _lastCumulative;

    /// @param token_ The revenue token to lock; must have code and native ETH as its first asset.
    /// @param tipBps_ The roll caller's tip, at most `MAX_TIP_BPS`.
    /// @param tipCap_ The most ETH one roll pays its caller.
    constructor(IHookrRevenueToken token_, uint16 tipBps_, uint256 tipCap_) HookrIncomeTimeline(_countAssets(token_)) {
        if (tipBps_ > MAX_TIP_BPS) revert InvalidConfig();
        token = token_;
        tipBps = tipBps_;
        tipCap = tipCap_;
        uint256 n = token_.assetCount();
        Currency c0 = token_.assetAt(0).currency;
        if (!c0.isAddressZero()) revert InvalidConfig();
        _currency0 = c0;
        _currency1 = n > 1 ? token_.assetAt(1).currency : Currency.wrap(address(0));
        _currency2 = n > 2 ? token_.assetAt(2).currency : Currency.wrap(address(0));
        _currency3 = n > 3 ? token_.assetAt(3).currency : Currency.wrap(address(0));
    }

    /// @notice Takes native ETH from the revenue token's claims, and from anyone: whatever lands here above the
    ///         books is attributed at the next settle like income of the stretch it was found in.
    receive() external payable {}

    // ------------------------------------------------------------------ views

    /// @inheritdoc IHookrTimeShares
    function currencyAt(uint256 asset) external view returns (Currency) {
        _checkAsset(asset);
        return _currency(asset);
    }

    /// @inheritdoc IHookrTimeShares
    function lockAt(uint256 lockId) external view returns (Lock memory) {
        return _lock(lockId);
    }

    /// @inheritdoc IHookrTimeShares
    function isIssued(uint256 lockId, uint256 day) external view returns (bool) {
        _lock(lockId);
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
        (uint256 amount, bool ok) = _held(_currency(asset));
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
        Lock storage l = _lock(lockId);
        _checkAsset(asset);
        uint256[MAX_ASSETS] memory nowIndex = _nowIndex();
        return _lockOwedScaled(l, asset, nowIndex, true) / SCALE - _lockPaid[lockId][asset];
    }

    // ------------------------------------------------------------------ locks

    /// @inheritdoc IHookrTimeShares
    /// @dev Settles first, so the stretch that ends now was earned by the revenue tokens locked before this one. The
    ///      transfer must land exactly; the token refuses nothing on this path.
    function lock(uint256 amount, uint32 numberOfDays) external nonReentrant returns (uint256 lockId) {
        if (amount == 0 || amount > MAX_LOCK_AMOUNT) revert InvalidAmount(amount);
        if (numberOfDays != FOREVER && (numberOfDays < MIN_LOCK_DAYS || numberOfDays > MAX_LOCK_DAYS)) {
            revert InvalidDays(numberOfDays);
        }
        _settle(false);
        uint256 before = token.balanceOf(address(this));
        if (!token.transferFrom(msg.sender, address(this), amount) || token.balanceOf(address(this)) != before + amount)
        {
            revert InexactTransfer();
        }
        lockedTotal += amount;
        // The day grid is below 2^32 for the next 11 million years; a lock's days fit with room.
        uint32 first = uint32(HookrDays.dayOf(block.timestamp)) + 1;
        uint32 last = numberOfDays == FOREVER ? FOREVER : first + numberOfDays - 1;
        lockId = lockCount++;
        _locks[lockId] = Lock(msg.sender, uint64(block.timestamp), first, uint128(amount), last, 0);
        emit Locked(lockId, msg.sender, amount, first, last);
    }

    /// @inheritdoc IHookrTimeShares
    function issue(uint256 lockId, uint256 day, address to) external {
        Lock storage l = _lock(lockId);
        if (msg.sender != l.owner) revert Unauthorized(msg.sender);
        _checkRecipient(to);
        _issue(lockId, l, day, to);
    }

    /// @inheritdoc IHookrTimeShares
    function issueRange(uint256 lockId, uint256 firstDay, uint256 lastDay, address to) external {
        Lock storage l = _lock(lockId);
        if (msg.sender != l.owner) revert Unauthorized(msg.sender);
        _checkRecipient(to);
        if (lastDay < firstDay) revert InvalidDay(lastDay);
        uint256 count = lastDay - firstDay + 1;
        if (count > MAX_ISSUE_DAYS) revert TooManyDays(count);
        for (uint256 day = firstDay; day <= lastDay; ++day) {
            _issue(lockId, l, day, to);
        }
    }

    /// @inheritdoc IHookrTimeShares
    /// @dev Settles first, so the tail (last day's end to now) is written at this point and the revenue tokens that
    ///      leave earned nothing of what comes after.
    function unlock(uint256 lockId, address to) external nonReentrant {
        Lock storage l = _lock(lockId);
        if (msg.sender != l.owner) revert Unauthorized(msg.sender);
        _checkRecipient(to);
        if (l.lastDay == FOREVER) revert NeverEnds(lockId);
        if (l.unlockedAt != 0) revert AlreadyUnlocked(lockId);
        uint256 endsAt = HookrDays.endOf(l.lastDay);
        if (block.timestamp < endsAt) revert NotEnded(lockId, endsAt);
        _settle(false);
        l.unlockedAt = uint64(block.timestamp);
        uint256 amount = l.amount;
        lockedTotal -= amount;
        uint256 before = token.balanceOf(to);
        if (!token.transfer(to, amount) || token.balanceOf(to) != before + amount) revert InexactTransfer();
        emit Unlocked(lockId, to, amount);
    }

    // ------------------------------------------------------------------ settle and roll

    /// @inheritdoc IHookrTimeShares
    function settle() external nonReentrant {
        _settle(false);
    }

    /// @inheritdoc IHookrTimeShares
    /// @dev Pulls first, so the tip is paid from cash that is here; the growth the settle measures is the same
    ///      before and after a pull (what the token owed became what was received).
    function roll() external nonReentrant returns (uint256 tip) {
        _pullAll();
        tip = _settle(true);
        emit Rolled(msg.sender, tip);
        if (tip != 0) _send(_currency0, msg.sender, tip);
    }

    /// @inheritdoc IHookrTimeShares
    /// @dev The box pays its caller, so the claim lands here; the settle right after books it as the surplus of the
    ///      stretch since the last point. A drop cannot be attributed to the day of its snapshot: final days and
    ///      holder checkpoints never move.
    function sweepDrops(uint256[] calldata dropIds) external nonReentrant returns (uint256[] memory amounts) {
        IHookrDropBox box = IHookrDropBox(token.dropBox());
        uint256 m = dropIds.length;
        uint256[] memory assets = new uint256[](m);
        for (uint256 j; j < m; ++j) {
            assets[j] = _assetOf(box.dropAt(dropIds[j]).asset, dropIds[j]);
        }
        amounts = box.claim(dropIds, address(this));
        for (uint256 j; j < m; ++j) {
            emit DropSwept(dropIds[j], assets[j], amounts[j]);
        }
        _settle(false);
    }

    // ------------------------------------------------------------------ claims

    /// @inheritdoc IHookrTimeShares
    /// @dev Settles only when the day is still open at the last point; a day that has ended and been settled is
    ///      final and needs no new point.
    function claim(uint256 day, uint256 asset, address to) external nonReentrant returns (uint256 amount) {
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
        _send(_currency(asset), to, amount);
    }

    /// @inheritdoc IHookrTimeShares
    function claimLock(uint256 lockId, uint256 asset, address to) external nonReentrant returns (uint256 amount) {
        Lock storage l = _lock(lockId);
        if (msg.sender != l.owner) revert Unauthorized(msg.sender);
        _checkAsset(asset);
        _checkRecipient(to);
        _settle(false);
        uint256[MAX_ASSETS] memory none;
        uint256 owed = _lockOwedScaled(l, asset, none, false) / SCALE - _lockPaid[lockId][asset];
        if (owed == 0) revert NothingToClaim();
        amount = _available(asset, owed);
        if (amount == 0) revert NothingToClaim();
        _lockPaid[lockId][asset] += amount;
        _paid[asset] += amount;
        _send(_currency(asset), to, amount);
        emit LockIncomeClaimed(lockId, asset, to, amount);
    }

    // ------------------------------------------------------------------ internals

    /// @dev The token's asset count, for the base constructor; a token without code is refused.
    function _countAssets(IHookrRevenueToken token_) private view returns (uint256) {
        if (address(token_).code.length == 0) revert InvalidConfig();
        return token_.assetCount();
    }

    function _currency(uint256 asset) private view returns (Currency) {
        if (asset == 0) return _currency0;
        if (asset == 1) return _currency1;
        if (asset == 2) return _currency2;
        return _currency3;
    }

    /// @dev Asset `asset`'s index for a drop box asset address, or `UnlistedDrop` when the token does not pay it.
    function _assetOf(address asset, uint256 dropId) private view returns (uint256) {
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            if (Currency.unwrap(_currency(i)) == asset) return i;
        }
        revert UnlistedDrop(dropId);
    }

    /// @dev This contract's balance of `c`, and whether it could be read: native from the balance; an ERC-20 through
    ///      a bounded `balanceOf` call whose answer must be at least a word. A read that reverts, answers short or
    ///      runs out of its gas is `false`, so one asset's trouble never stops a settle or another asset's payout.
    function _held(Currency c) private view returns (uint256 amount, bool ok) {
        if (c.isAddressZero()) return (address(this).balance, true);
        (bool success, bytes memory data) =
            Currency.unwrap(c).staticcall{gas: BALANCE_READ_GAS}(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!success || data.length < 32) return (0, false);
        return (abi.decode(data, (uint256)), true);
    }

    /// @dev Lock `lockId`, or `UnknownLock` past the last one.
    function _lock(uint256 lockId) private view returns (Lock storage l) {
        if (lockId >= lockCount) revert UnknownLock(lockId);
        l = _locks[lockId];
    }

    /// @dev A payout or unit recipient: anyone but zero and this contract.
    function _checkRecipient(address to) private view {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
    }

    /// @dev Lock `l`'s units of day `day` to `to`: once, within the lock's days.
    function _issue(uint256 lockId, Lock storage l, uint256 day, address to) private {
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
    ///      HookrIncomeTimeline states. An asset whose balance cannot be read (`unread`) books no surplus this time.
    ///      A sum that fell (an asset that charged this contract on a claim, or a balance that fell on its own)
    ///      grows by nothing and resets the mark.
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
            (uint256 heldNow, bool ok) = _held(_currency(i));
            if (!ok) {
                unread[i] = true;
            } else if (heldNow > cash) {
                uint256 room = inflow < type(uint128).max ? type(uint128).max - inflow : 0;
                uint256 found = heldNow - cash;
                surplus[i] = found < room ? found : room;
            }
            cumulative[i] = inflow + surplus[i] + token.claimable(address(this), i);
            uint256 last = _lastCumulative[i];
            if (cumulative[i] > last) growth[i] = cumulative[i] - last;
        }
    }

    /// @dev Every asset's index a settle now would write: the last point plus the unsettled growth over what is
    ///      locked; the last point as it is when nothing is locked or no time has passed since it (the growth
    ///      would wait in the carry).
    function _nowIndex() private view returns (uint256[MAX_ASSETS] memory g) {
        uint64 lastT = _lastTime();
        g = _lineAt(lastT);
        uint256 locked = lockedTotal;
        if (locked == 0 || block.timestamp <= lastT) return g;
        (uint256[MAX_ASSETS] memory growth,,,) = _measure();
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            g[i] += (growth[i] * SCALE + _carry[i]) / locked;
        }
    }

    /// @dev Writes the settle point: books the surplus, moves the marks, takes the tip off the ETH growth when this
    ///      is a roll, and attributes the growth over what is locked. The tip is `tipBps` of the ETH growth, only
    ///      when that is at least `MIN_TIP_GROWTH`, at most `tipCap`, never more than the ETH on the books.
    function _settle(bool isRoll) private returns (uint256 tip) {
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
        _attribute(growth, lockedTotal);
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
    ///      the balance fell (what did land is found as surplus by a later settle).
    function _pullAsset(uint256 asset) private {
        Currency c = _currency(asset);
        (uint256 before, bool ok) = _held(c);
        if (!ok) {
            emit AssetUnread(asset);
            return;
        }
        try token.claim(asset, address(this)) returns (uint256) {
            (uint256 after_, bool okAfter) = _held(c);
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
        Currency c = _currency(asset);
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
        _send(_currency(asset), to, amount);
        emit IncomeClaimed(holder, day, asset, to, amount);
    }

    /// @dev Lock `l`'s own income in asset `asset`, scaled: its amount times the index growth from the lock to its
    ///      first day's start, plus from its last day's end to the unlock (or to now while it is still here). On
    ///      the settled line, or on the line extended to now by `nowIndex` when `preview`.
    function _lockOwedScaled(Lock storage l, uint256 asset, uint256[MAX_ASSETS] memory nowIndex, bool preview)
        private
        view
        returns (uint256 scaled)
    {
        uint256 amount = l.amount;
        uint256 lockedAt = l.lockedAt;
        uint256 firstStart = HookrDays.startOf(l.firstDay);
        scaled = amount * (_at(firstStart, nowIndex, preview)[asset] - _at(lockedAt, nowIndex, preview)[asset]);
        if (l.lastDay == FOREVER) return scaled;
        uint256 tailStart = HookrDays.endOf(l.lastDay);
        uint256 tailEnd = l.unlockedAt != 0 ? l.unlockedAt : block.timestamp;
        if (tailEnd > tailStart) {
            scaled += amount * (_at(tailEnd, nowIndex, preview)[asset] - _at(tailStart, nowIndex, preview)[asset]);
        }
    }

    function _at(uint256 t, uint256[MAX_ASSETS] memory nowIndex, bool preview)
        private
        view
        returns (uint256[MAX_ASSETS] memory)
    {
        return preview ? _lineAtPreview(uint64(t), nowIndex) : _lineAt(uint64(t));
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
