// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrIncomeRecovery} from "./libraries/HookrIncomeRecovery.sol";
import {IHookrIncomeRecovery} from "./interfaces/IHookrIncomeRecovery.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrDropBox} from "./interfaces/IHookrDropBox.sol";
import {IHookrDropHost} from "./interfaces/IHookrDropHost.sol";
import {IHookrRevenueToken} from "./interfaces/IHookrRevenueToken.sol";
import {HookrAuthorizations} from "./base/HookrAuthorizations.sol";
import {HookrRevenueGuard} from "./base/HookrRevenueGuard.sol";
import {HookrForward} from "./libraries/HookrForward.sol";

/// @title Hookr drop box, part of the HookRevenue Tokenizer
/// @notice Where anyone drops ETH or any ERC-20 for the holders of one revenue token; each holder claims its share of
///         each drop by its balance at the end of the block before the drop, itself, through an operator or by a
///         signature anyone relays. Whatever reaches the box without `drop` (a plain ERC-20 transfer, ETH through
///         `receive`, the revenue token's own strays) is recognized with `dropStray`: one immediate drop when the
///         release period is under an hour (zero included), otherwise slices with one snapshot each. The same applies
///         to income its shares of another revenue token earn, which `collectIncome` claims. See `IHookrDropBox` for
///         the rules.
/// @dev Claims follow checks-effects-interactions and every cash-moving function takes the transient lock, so a
///      native payout recipient that runs code cannot re-enter a claim or a drop, and a hostile ERC-20's
///      `transferFrom` cannot nest a second drop inside the balance measurement of the first. The box keeps one
///      running total per asset of what its drops still owe (`owed`): `drop` and `dropStray` add to it, each claim
///      subtracts what it paid, so a stray is the balance less the owed total and the stray stream, never a loop over
///      the drops. The stray stream is the token's release math in small: `pending` releases linearly into `ready` by
///      time, a new stray sets the window to the amount-weighted mean of what was left and a full release period, and
///      the stream advances at most `STRAY_SLICE_SECONDS` between two recorded slices; a slice turns `ready` into one
///      drop. A claim is never paid to the token's doors (`isDoor` on the token, read on every claim). The box
///      has its own EIP-712 domain ("Hookr Drop Box", version "1", its address) and its own nonces
///      (HookrAuthorizations).
contract HookrDropBox is IHookrDropBox, HookrRevenueGuard, HookrAuthorizations {
    using SafeERC20 for IERC20;

    /// @inheritdoc IHookrDropBox
    bytes32 public constant CLAIM_DROPS_TYPEHASH =
        keccak256("ClaimDrops(address holder,uint256[] dropIds,address to,bytes32 nonce,uint256 deadline)");

    /// @inheritdoc IHookrDropBox
    address public immutable token;

    Drop[] private _drops;
    /// @inheritdoc IHookrDropBox
    mapping(uint256 dropId => mapping(address holder => bool)) public claimed;
    /// @dev The drop id a record that did not happen returns.
    uint256 private constant NONE = type(uint256).max;
    /// @dev A revenue token lists at most eight assets. Every external read copies one word at most.
    uint256 private constant INCOME_ASSETS = 8;
    uint256 private constant INCOME_READ_GAS = 50_000;
    /// @dev The strict claim cap covers an eight-asset revenue token's cold first release into this box.
    uint256 private constant INCOME_CLAIM_GAS = 1_600_000;
    /// @dev The EVM's retained gas plus the balance read, stray accounting and events after one claim.
    uint256 private constant INCOME_GAS_FLOOR = INCOME_CLAIM_GAS * 64 / 63 + 300_000;
    /// @dev The shortest release period the box streams strays over; shorter ones are immediate here.
    uint256 private constant MIN_STREAM_SECONDS = 1 hours;

    /// @dev What every drop of an asset still owes its claimers: the sum of their `remaining`.
    mapping(address asset => uint256) private _owedOf;
    mapping(address asset => Stray) private _strays;

    /// @param token_ The revenue token; the box is meant to be deployed by it.
    constructor(address token_) EIP712("Hookr Drop Box", "1") {
        token = token_;
    }

    /// @notice Takes native ETH from anyone and writes nothing; `dropStray(address(0))` recognizes it for holders.
    receive() external payable {}

    // ------------------------------------------------------------------ views

    /// @inheritdoc IHookrDropBox
    function STRAY_SLICE_SECONDS() external view returns (uint256) {
        return _sliceSeconds(_streamSeconds());
    }

    /// @inheritdoc IHookrDropBox
    function strayOf(address asset) external view returns (Stray memory) {
        return _strays[asset];
    }

    /// @inheritdoc IHookrDropBox
    function dropCount() external view returns (uint256) {
        return _drops.length;
    }

    /// @inheritdoc IHookrDropBox
    function dropAt(uint256 dropId) external view returns (Drop memory) {
        if (dropId >= _drops.length) revert UnknownDrop(dropId);
        return _drops[dropId];
    }

    /// @inheritdoc IHookrDropBox
    function remaining(uint256 dropId) external view returns (uint256) {
        if (dropId >= _drops.length) revert UnknownDrop(dropId);
        Drop storage d = _drops[dropId];
        return d.amount - d.paid;
    }

    /// @inheritdoc IHookrDropBox
    function claimable(uint256 dropId, address holder) external view returns (uint256) {
        if (dropId >= _drops.length) revert UnknownDrop(dropId);
        if (claimed[dropId][holder]) return 0;
        return _owed(_drops[dropId], holder);
    }

    /// @inheritdoc IHookrDropBox
    function owed(address asset) external view returns (uint256) {
        return _owedOf[asset];
    }

    // ------------------------------------------------------------------ drops

    /// @inheritdoc IHookrDropBox
    function drop(address asset, uint256 amount) external payable nonReentrant returns (uint256 dropId) {
        if (asset == token) revert RefusedAsset(asset);
        uint256 received;
        if (asset == address(0)) {
            if (msg.value != amount) revert InexactValue(amount, msg.value);
            received = amount;
        } else {
            if (msg.value != 0) revert NativeNotAccepted();
            uint256 before = IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            received = IERC20(asset).balanceOf(address(this)) - before;
        }
        if (received == 0) revert NothingReceived();
        return _record(asset, received, msg.sender, true);
    }

    /// @inheritdoc IHookrDropBox
    /// @dev New is the box's balance of `asset` above what its drops of it still owe and what its stray stream holds.
    ///      A balance at or below that (a drop recorded too high by a lying token, a rebase down) has nothing new and
    ///      is `NothingReceived`, never an underflow. A release period under an hour (zero included) records one immediate drop against the
    ///      previous block's earning balances. Otherwise the stream releases what was due first, so the old stream
    ///      keeps its pace; the new amount carries a full release period.
    function dropStray(address asset) external nonReentrant returns (uint256 amount) {
        if (asset == token) revert RefusedAsset(asset);
        return _addStray(asset, true);
    }

    /// @inheritdoc IHookrDropBox
    /// @dev Reads at most eight assets and claims each separately into this box, with a gas cap and a fixed return
    ///      buffer for every external call. An invalid source or asset read is skipped, as is a failed claim; a
    ///      caller that leaves too little gas is refused before the attempt. What arrives is recognized as in
    ///      `dropStray` (one immediate drop under an hour's release period, the stray stream otherwise), except an
    ///      unread balance, an overflowing amount or no earning supply at the snapshot is skipped and left for a later
    ///      `dropStray`. The box's own token stays here, where it earns nothing. No caller chooses a holder or payout
    ///      recipient.
    function collectIncome(address revenueToken) external nonReentrant returns (uint256[] memory amounts) {
        uint256 n = _incomeAssets(revenueToken);
        amounts = new uint256[](n);
        if (n == 0) return amounts;
        uint256[] memory paid = new uint256[](n);
        bool any;
        for (uint256 i; i < n; ++i) {
            (paid[i], amounts[i]) = _collectIncomeAsset(revenueToken, i);
            if (paid[i] != 0) any = true;
        }
        if (!any) return new uint256[](0);
        emit IncomeCollected(revenueToken, paid, amounts);
    }

    /// @inheritdoc IHookrDropBox
    function collectIncomeAsset(address revenueToken, uint256 asset) external nonReentrant returns (uint256 amount) {
        if (asset >= _incomeAssets(revenueToken)) return 0;
        (uint256 paid, uint256 added) = _collectIncomeAsset(revenueToken, asset);
        if (paid != 0) emit IncomeAssetCollected(revenueToken, asset, paid, added);
        return added;
    }

    /// @inheritdoc IHookrDropBox
    function releaseStray(address asset) external nonReentrant returns (uint256 dropId) {
        uint256 stream = _streamSeconds();
        if (stream == 0) revert NothingReceived();
        Stray storage s = _strays[asset];
        uint256 slice = _sliceSeconds(stream);
        uint256 next = uint256(s.lastSlice) + slice;
        if (block.timestamp < next) revert SliceNotDue(next);
        return _slice(asset, s, slice, true);
    }

    /// @inheritdoc IHookrDropBox
    /// @dev `to` may be anyone but zero, the revenue token, this box and the token's doors: a drop share paid into
    ///      the token would be recognized by its next sync as streamed income for every holder, one paid into the box
    ///      would sit as everyone's stray, and one paid into a door would come back through its next pull as income
    ///      of every holder, so the claim paths never meet.
    function claim(uint256[] calldata dropIds, address to) external nonReentrant returns (uint256[] memory amounts) {
        return _claim(msg.sender, dropIds, to);
    }

    /// @inheritdoc IHookrDropBox
    /// @dev The operator list is the revenue token's (IHookrRevenueToken.isOperator), read on every call.
    function claimFrom(address holder, uint256[] calldata dropIds, address to)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (msg.sender != holder && !IHookrRevenueToken(token).isOperator(holder, msg.sender)) {
            revert Unauthorized(msg.sender);
        }
        return _claim(holder, dropIds, to);
    }

    /// @inheritdoc IHookrDropBox
    /// @dev The holder's authorization is used before the payouts; a claim of listed drops that pays nothing reverts
    ///      and leaves it unused. A signature over an empty list claims no drop: it pays nothing and uses the nonce.
    function claimWithSig(
        address holder,
        uint256[] calldata dropIds,
        address to,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant returns (uint256[] memory amounts) {
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        _useAuthorization(
            holder,
            nonce,
            keccak256(
                abi.encode(CLAIM_DROPS_TYPEHASH, holder, keccak256(abi.encodePacked(dropIds)), to, nonce, deadline)
            ),
            signature
        );
        return _claim(holder, dropIds, to);
    }

    /// @inheritdoc IHookrIncomeRecovery
    function collectDrops(address revenueToken, uint256[] calldata dropIds)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (revenueToken == token) revert RefusedAsset(revenueToken);
        (address[] memory assets, uint256[] memory paid) =
            HookrIncomeRecovery.collectBoxDrops(revenueToken, token, dropIds);
        for (uint256 i; i < paid.length; ++i) {
            if (paid[i] != 0) _addStray(assets[i], false);
        }
        return paid;
    }

    // ------------------------------------------------------------------ internals

    /// @dev Recognizes what the box holds of `asset` beyond its books (`owed` plus the stray stream): with a release
    ///      period under an hour, one immediate drop against the previous block's earning balances; otherwise added to
    ///      the asset's stray stream, releasing a slice when one is due. `strict`: nothing new is `NothingReceived`, an
    ///      amount or a stream past 2^128 - 1 units `StrayTooLarge`, no earning supply at the snapshot of an
    ///      immediate drop `NoEarningSupply`, and the balance read bubbles its own failure; otherwise each adds nothing
    ///      and returns zero. Under an hour, a soft call after a block with no earning supply records nothing, and the
    ///      amount waits for a later `dropStray`.
    function _addStray(address asset, bool strict) private returns (uint256 amount) {
        uint256 held;
        if (asset == address(0)) held = address(this).balance;
        else if (strict) held = IERC20(asset).balanceOf(address(this));
        else held = _tryBalanceOf(asset);
        Stray storage s = _strays[asset];
        uint256 owedAmount = _owedOf[asset];
        uint256 streaming = uint256(s.pending) + s.ready;
        if (held <= owedAmount || held - owedAmount <= streaming) {
            if (strict) revert NothingReceived();
            return 0;
        }
        unchecked {
            amount = held - owedAmount - streaming;
        }
        uint256 stream = _streamSeconds();
        if (stream == 0) {
            if (amount > type(uint128).max) {
                if (strict) revert StrayTooLarge(amount);
                return 0;
            }
            if (_record(asset, amount, address(this), strict) == NONE) return 0;
            emit StrayAdded(asset, amount, uint64(block.timestamp));
            return amount;
        }
        uint256 slice = _sliceSeconds(stream);
        _advance(s, slice);
        uint256 left = s.pending;
        // pending + ready never passes 2^128 - 1: this bound holds it and `_advance` only moves units between them.
        if (amount > type(uint128).max - left - s.ready) {
            if (strict) revert StrayTooLarge(amount);
            return 0;
        }
        uint256 window = stream;
        if (left != 0 && block.timestamp < s.end) {
            window = (left * (s.end - block.timestamp) + amount * stream) / (left + amount);
        }
        uint64 end = uint64(block.timestamp + window);
        s.pending = uint128(left + amount);
        s.end = end;
        s.last = uint64(block.timestamp);
        emit StrayAdded(asset, amount, end);
        if (block.timestamp >= uint256(s.lastSlice) + slice) _slice(asset, s, slice, false);
    }

    /// @dev The box's balance of `asset`, or zero when the capped read does not answer exactly one word.
    function _tryBalanceOf(address asset) private view returns (uint256) {
        (, uint256 amount) = HookrForward.balanceOf(asset, address(this), INCOME_READ_GAS);
        return amount;
    }

    /// @dev A genuine revenue token lists native ETH first and at most eight assets; unread sources have no assets.
    function _incomeAssets(address revenueToken) private view returns (uint256 count) {
        if (revenueToken == token) revert RefusedAsset(revenueToken);
        (bool ok, uint256 n) =
            HookrForward.read(revenueToken, abi.encodeCall(IHookrRevenueToken.assetCount, ()), INCOME_READ_GAS);
        if (ok && n <= INCOME_ASSETS) count = n;
    }

    /// @dev Reads the asset's fixed eight-word record, copying its currency alone, then claims this box's credit
    ///      into this box. No return data beyond the one-word claim amount is copied. Failed claims leave the
    ///      revenue token's credit untouched; an unread balance leaves the delivered currency for `dropStray`.
    function _collectIncomeAsset(address revenueToken, uint256 asset) private returns (uint256 paid, uint256 added) {
        bytes memory data = abi.encodeCall(IHookrRevenueToken.assetAt, (asset));
        bool ok;
        uint256 currency;
        assembly ("memory-safe") {
            ok := staticcall(INCOME_READ_GAS, revenueToken, add(data, 0x20), mload(data), 0, 0x20)
            ok := and(ok, eq(returndatasize(), 0x100))
            currency := mload(0)
        }
        if (!ok || currency > type(uint160).max || (asset == 0 && currency != 0)) return (0, 0);
        if (gasleft() < INCOME_GAS_FLOOR) revert IncomeCollectionStarved(asset);
        data = abi.encodeCall(IHookrRevenueToken.claim, (asset, address(this)));
        assembly ("memory-safe") {
            ok := call(INCOME_CLAIM_GAS, revenueToken, 0, add(data, 0x20), mload(data), 0, 0x20)
            ok := and(ok, eq(returndatasize(), 0x20))
            paid := mul(mload(0), ok)
        }
        if (paid != 0 && address(uint160(currency)) != token) added = _addStray(address(uint160(currency)), false);
    }

    /// @dev Records `amount` of `asset`, already in the box, as a new drop from `from`: the token's snapshot of the
    ///      block before and its earning supply then, the record, the owed total, the event. With no earning supply at
    ///      the snapshot a `strict` record reverts `NoEarningSupply` and any other returns `NONE` and records nothing.
    function _record(address asset, uint256 amount, address from, bool strict) private returns (uint256 dropId) {
        (uint48 snapshotBlock, uint256 supply) = IHookrDropHost(token).snapshot();
        if (supply == 0) {
            if (strict) revert NoEarningSupply(snapshotBlock);
            return NONE;
        }
        dropId = _drops.length;
        _drops.push(Drop(asset, snapshotBlock, amount, supply, 0));
        _owedOf[asset] += amount;
        emit Dropped(dropId, from, asset, amount, snapshotBlock, supply);
    }

    /// @dev Releases `s` up to now (at most `slice` seconds of it) and records its `ready` units as one drop from the
    ///      box. `strict`: nothing ready is `NothingReceived` and no earning supply `NoEarningSupply`; otherwise both
    ///      leave everything as it is and return `NONE`.
    function _slice(address asset, Stray storage s, uint256 slice, bool strict) private returns (uint256 dropId) {
        _advance(s, slice);
        uint256 amount = s.ready;
        if (amount == 0) {
            if (strict) revert NothingReceived();
            return NONE;
        }
        dropId = _record(asset, amount, address(this), strict);
        if (dropId == NONE) return NONE;
        s.ready = 0;
        s.lastSlice = uint64(block.timestamp);
    }

    /// @dev The token's release period as the box uses it, read from the token on every call (the box is created
    ///      inside the token's constructor, before the token can answer): zero, immediate recognition, for any period
    ///      under `MIN_STREAM_SECONDS`. A slice is never shorter than an hour, so under an hour a stream would release
    ///      each stray whole in one slice anyway and make a second stray wait up to an hour for the next.
    function _streamSeconds() private view returns (uint256) {
        uint256 stream = IHookrRevenueToken(token).streamSeconds();
        return stream < MIN_STREAM_SECONDS ? 0 : stream;
    }

    /// @dev Zero means immediate recognition, with no slice cadence; otherwise `stream / 24`, at least one hour (the
    ///      box streams only periods of an hour or more, `_streamSeconds`).
    function _sliceSeconds(uint256 stream) private pure returns (uint256) {
        if (stream == 0) return 0;
        uint256 slice = stream / 24;
        return slice > 1 hours ? slice : 1 hours;
    }

    /// @dev Moves what `s` released since `last` from `pending` into `ready`, at most one slice of the stream's time
    ///      between two recorded slices: the slice being filled starts at `lastSlice` (moved up to `last` while
    ///      nothing is ready, so an idle stream starts a fresh slice where it stands), and the stream runs at most to
    ///      its end, `step = min(now - last, lastSlice + slice - last)`, floored at zero. With `window` seconds left
    ///      from `last`, `pending x step / window` moves, or all of it once the step reaches the window. Time past the
    ///      step does not run the stream: the window that is left starts now. So no number of calls between two
    ///      slices, dust strays included, folds more than one slice of the stream into one snapshot.
    function _advance(Stray storage s, uint256 slice) private {
        uint256 pending = s.pending;
        uint256 last = s.last;
        if (pending == 0 || block.timestamp <= last) return;
        uint256 start = s.lastSlice;
        if (s.ready == 0 && last > start) {
            start = last;
            s.lastSlice = uint64(last);
        }
        uint256 room = start + slice > last ? start + slice - last : 0;
        uint256 elapsed = block.timestamp - last;
        uint256 step = elapsed < room ? elapsed : room;
        uint256 window = s.end > last ? s.end - last : 0;
        uint256 amount = step == 0 ? 0 : window <= step ? pending : pending * step / window;
        // amount <= pending, and ready + pending stays under 2^128 (dropStray's bound).
        unchecked {
            s.pending = uint128(pending - amount);
            s.ready += uint128(amount);
        }
        s.last = uint64(block.timestamp);
        s.end = uint64(window <= step ? block.timestamp : block.timestamp + window - step);
    }

    /// @dev `holder`'s share of each listed drop, paid to `to`, each once.
    function _claim(address holder, uint256[] calldata dropIds, address to) private returns (uint256[] memory amounts) {
        if (to == address(0) || to == token || to == address(this) || IHookrRevenueToken(token).isDoor(to)) {
            revert InvalidRecipient(to);
        }
        uint256 n = dropIds.length;
        uint256 count = _drops.length;
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 dropId = dropIds[i];
            if (dropId >= count) revert UnknownDrop(dropId);
            if (claimed[dropId][holder]) revert AlreadyClaimed(dropId);
            Drop storage d = _drops[dropId];
            uint256 due = _owed(d, holder);
            if (due == 0) revert NothingToClaim(dropId);
            claimed[dropId][holder] = true;
            d.paid += due;
            // due <= amount - paid, and the owed total is the sum of every drop's remaining.
            unchecked {
                _owedOf[d.asset] -= due;
            }
            amounts[i] = due;
            emit Claimed(dropId, holder, to, due);
            _pay(d.asset, to, due);
        }
    }

    /// @dev `holder`'s share of `d`: balance at the snapshot times the amount over the earning supply, rounded
    ///      down, capped at what the drop still holds.
    function _owed(Drop storage d, address holder) private view returns (uint256 due) {
        uint256 held = IHookrDropHost(token).balanceAt(holder, d.snapshotBlock);
        if (held == 0) return 0;
        due = Math.mulDiv(held, d.amount, d.earningSupply);
        uint256 left = d.amount - d.paid;
        if (due > left) due = left;
    }

    function _pay(address asset, address to, uint256 amount) private {
        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert PaymentFailed(to);
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }
}
