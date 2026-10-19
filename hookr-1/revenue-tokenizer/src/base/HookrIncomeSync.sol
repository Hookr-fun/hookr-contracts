// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {HookrIncomeLedger} from "./HookrIncomeLedger.sol";
import {IHookrDropBox} from "../interfaces/IHookrDropBox.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";
import {IHookrRulesDoor} from "../interfaces/IHookrRulesDoor.sol";
import {IHookrFamilyForwarder} from "../interfaces/IHookrFamilyForwarder.sol";

/// @title Hookr income sync, part of the HookRevenue Tokenizer
/// @notice The pulling half of a revenue token: the fixed door list, the one permissionless `sync()` that pulls every door
///         and recognizes what arrived, the caller's tip, the Fee Bridge slice, bonus deposits, and `dropStray`, which
///         turns anything else sent to the token into a drop for the holders. `receive()` stays empty: recognition
///         happens in `sync`, never on arrival.
/// @dev Doors are pulled one by one, each call with a gas stipend and on its own, after a gas check that reverts the
///      whole sync when the caller left less than the door needs (a starved sync must fail, not quietly skip doors).
///      The seal bounds the sum of the stipends plus one reserve per door to `MAX_SYNC_GAS`, so one transaction under
///      Robinhood Chain's 32,000,000 cap always carries a whole `sync`, even when every door burns all it is given;
///      `syncSome` pulls a chosen subset of the doors with the same accounting, so holders can route around a door
///      that turns hostile after the mint and still recognize what the others delivered.
///      A RULES door is pulled by the token itself (`claim(currency)` pays only the caller's claim); FORWARDER, FEEB,
///      POSITIONS, SOURCE and POSITIONS_V3 doors forward what they pull here, all through the same `pull()`. After
///      the pulls each asset's balance above `received - paid` is recognized once. The tip is `tipBps` of the ETH the
///      doors delivered in this sync (the balance delta across the pull loop), only when that is at least
///      `MIN_TIP_PULL`, and never of a bonus or a push that was already here.
///
///      Whatever reaches the token is split: native ETH and the fixed assets by the next sync, as surplus; any other
///      ERC-20 by `dropStray`, which moves it into the drop box as a drop. The fixed assets' books never see a stray.
///
///      Every door call is a raw call that copies no return data: a door that reverts, runs out of its stipend or
///      answers with garbage fails only itself (`DoorPulled(i, false)`) and can neither stop the sync nor make it pay
///      for a large answer. A RULES door's `claimable` read is a staticcall with the same stipend and must answer one
///      word; the `claim` is only made when that word is nonzero, since the live Rules revert on an empty claim.
abstract contract HookrIncomeSync is HookrIncomeLedger {
    using SafeERC20 for IERC20;

    /// @inheritdoc IHookrRevenueToken
    uint256 public constant MAX_DOORS = 8;
    /// @inheritdoc IHookrRevenueToken
    uint16 public constant MAX_TIP_BPS = 100;
    /// @inheritdoc IHookrRevenueToken
    uint256 public constant MIN_TIP_PULL = 0.001 ether;
    /// @inheritdoc IHookrRevenueToken
    uint16 public constant MAX_BRIDGE_BPS = 2_000;
    /// @inheritdoc IHookrRevenueToken
    /// @dev A worst-case sync measured 314,362 gas all in with a last door that spent its whole 100,000 stipend, so the
    ///      tail is under 215,000; the rest is margin. Unused gas returns to the caller.
    uint256 public constant SYNC_RESERVE_GAS = 300_000;
    /// @inheritdoc IHookrRevenueToken
    /// @dev Robinhood Chain 4663 caps a transaction at 32,000,000 gas; what is left over the stipends and reserves
    ///      covers the transaction base, the calldata and the recognition tail with room.
    uint256 public constant MAX_SYNC_GAS = 28_000_000;

    /// @inheritdoc IHookrRevenueToken
    uint16 public immutable tipBps;
    /// @inheritdoc IHookrRevenueToken
    /// @dev Shares a slot with `bridgeBps` and `live`: a sync reads the three in one load.
    address public bridge;
    /// @inheritdoc IHookrRevenueToken
    uint16 public bridgeBps;
    /// @inheritdoc IHookrRevenueToken
    bool public live;

    Door[] internal _doors;

    /// @param tipBps_ The sync caller's tip, at most `MAX_TIP_BPS`.
    constructor(uint16 tipBps_) {
        if (tipBps_ > MAX_TIP_BPS) revert InvalidConfig();
        tipBps = tipBps_;
    }

    /// @notice Takes native ETH from anyone and writes nothing, so a 100,000-gas forward lands; the next sync
    ///         recognizes it as surplus, with no tip.
    receive() external payable {}

    // ------------------------------------------------------------------ doors

    /// @inheritdoc IHookrRevenueToken
    function doorCount() external view returns (uint256) {
        return _doors.length;
    }

    /// @inheritdoc IHookrRevenueToken
    function doorAt(uint256 i) external view returns (Door memory) {
        return _doors[i];
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev The tip and the bridge slice are measured on the native balance delta across the door loop alone, then
    ///      sent before recognition, so what is recognized is what stays: the pulls less the tip and the slice, plus
    ///      every push or plain send that was already here (never tipped). A recognition is clamped to what the ledger
    ///      can still count (`MAX_RECEIVED` in total); the rest stays as surplus for a later sync. A sync that pulls
    ///      nothing is allowed and only emits.
    function sync() external nonReentrant returns (uint256 tip) {
        if (!live) revert NotLive();
        uint256 ethBefore = address(this).balance;
        uint256 doors = _doors.length;
        for (uint256 i; i < doors; ++i) {
            emit DoorPulled(i, _pullDoor(i));
        }
        return _settle(ethBefore);
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev The same as `sync` over the listed doors alone: an index past the last door is `InvalidDoor`; a repeated
    ///      index pulls that door again, which is harmless. An empty list recognizes the pushes and pulls nothing.
    function syncSome(uint256[] calldata doors) external nonReentrant returns (uint256 tip) {
        if (!live) revert NotLive();
        uint256 ethBefore = address(this).balance;
        uint256 count = _doors.length;
        for (uint256 k; k < doors.length; ++k) {
            uint256 i = doors[k];
            if (i >= count) revert InvalidDoor(i);
            emit DoorPulled(i, _pullDoor(i));
        }
        return _settle(ethBefore);
    }

    /// @dev The second half of a sync, after the pulls: the tip and the bridge slice on the native delta since
    ///      `ethBefore`, then one recognition per asset, then `Synced`.
    function _settle(uint256 ethBefore) private returns (uint256 tip) {
        uint256 pulledEth = address(this).balance - ethBefore;
        if (pulledEth >= MIN_TIP_PULL) tip = pulledEth * tipBps / 10_000;
        uint256 bridged;
        address bridge_ = bridge;
        if (bridge_ != address(0)) bridged = (pulledEth - tip) * bridgeBps / 10_000;
        if (tip != 0) HookrSettlement.send(Currency.wrap(address(0)), msg.sender, tip);
        if (bridged != 0) HookrSettlement.send(Currency.wrap(address(0)), bridge_, bridged);
        uint256 assets = _assetCount;
        for (uint256 i; i < assets; ++i) {
            uint256 amount = _recognizable(_assets[i]);
            if (amount != 0) _recognize(i, amount, SOURCE_SYNC);
        }
        emit Synced(msg.sender, pulledEth, tip, bridged);
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev Native: asset 0 only, `msg.value == amount`. ERC-20: no value; the whole `amount` must land (a token that
    ///      takes a cut is refused with `InexactTransfer`). Recognized at once under `SOURCE_BONUS`; the balance and
    ///      `received` move together, so the next sync sees no surplus from it and tips nothing. An index past the
    ///      last asset reverts `UnknownAsset`.
    function depositBonus(uint256 asset, uint256 amount) external payable nonReentrant {
        if (!live) revert NotLive();
        Currency c = _asset(asset).currency;
        if (c.isAddressZero()) {
            if (msg.value != amount) revert InvalidAmount(msg.value);
        } else {
            if (msg.value != 0) revert NativeNotAccepted();
            IERC20 token = IERC20(Currency.unwrap(c));
            uint256 before = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), amount);
            if (token.balanceOf(address(this)) != before + amount) revert InexactTransfer();
        }
        _recognize(asset, amount, SOURCE_BONUS);
        emit BonusDeposited(msg.sender, asset, amount);
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev Refuses native ETH, this token and every fixed asset (`_position[currency] != 0`) with `InvalidAsset`;
    ///      otherwise moves the whole balance to the drop box by `safeTransfer` and has the box record what it holds
    ///      of the asset above what its drops still owe (IHookrDropBox.dropStray), so a stray that already sat in the
    ///      box is folded into the same drop; the box refuses when nothing is stray anywhere (`NothingReceived`) or
    ///      when no share earned at the snapshot (`NoEarningSupply`), and then nothing moves. `StrayDropped.amount`
    ///      is what left this token; the box's `Dropped` carries what it recorded (less for an asset that charges on
    ///      the way in). Needs no `live`: before the seal the box's snapshot has no earning supply and refuses.
    function dropStray(address asset) external nonReentrant returns (uint256 dropId) {
        Currency c = Currency.wrap(asset);
        if (asset == address(0) || asset == address(this) || _position[c] != 0) revert InvalidAsset(c);
        IERC20 stray = IERC20(asset);
        uint256 amount = stray.balanceOf(address(this));
        address box = dropBox;
        if (amount != 0) stray.safeTransfer(box, amount);
        dropId = IHookrDropBox(box).dropStray(asset);
        emit StrayDropped(asset, amount, dropId);
    }

    // ------------------------------------------------------------------ seal-time setters

    /// @dev Fixes the doors: 1 to `MAX_DOORS`, each target with code and no duplicate target, the stipends plus one
    ///      `SYNC_RESERVE_GAS` per door summing to at most `MAX_SYNC_GAS` (`SyncTooExpensive` otherwise).
    function _setDoors(Door[] calldata doors) internal {
        uint256 n = doors.length;
        if (n == 0 || n > MAX_DOORS) revert InvalidConfig();
        uint256 total;
        for (uint256 i; i < n; ++i) {
            Door calldata d = doors[i];
            if (d.target.code.length == 0 || d.gas == 0) revert InvalidDoor(i);
            for (uint256 j; j < i; ++j) {
                if (doors[j].target == d.target) revert InvalidDoor(i);
            }
            total += d.gas + SYNC_RESERVE_GAS;
            _doors.push(d);
        }
        if (total > MAX_SYNC_GAS) revert SyncTooExpensive(total);
    }

    /// @dev Fixes the Fee Bridge slice: a bridge with code and a share in (0, MAX_BRIDGE_BPS], or neither.
    function _setBridge(address bridge_, uint16 bps) internal {
        if (bridge_ == address(0)) {
            if (bps != 0) revert InvalidConfig();
            return;
        }
        if (bridge_.code.length == 0 || bps == 0 || bps > MAX_BRIDGE_BPS) revert InvalidConfig();
        bridge = bridge_;
        bridgeBps = bps;
    }

    // ------------------------------------------------------------------ internals

    /// @dev Pulls door `i`. RULES: for each asset, read `claimable(currency, this)` and, when nonzero, call
    ///      `claim(currency)`; every other kind (FORWARDER, FEEB, POSITIONS, SOURCE, POSITIONS_V3): call `pull()` (the
    ///      same selector on each; the answer, if any, is never read). Before every call the caller must have the door's
    ///      stipend plus `SYNC_RESERVE_GAS` left, or the sync reverts `SyncStarved`: with that much left the EVM hands
    ///      the door its whole stipend (the 63/64 rule never trims it), so a door that fails did so on its own.
    /// @return ok False when any read or call of this door failed; the sync goes on either way.
    function _pullDoor(uint256 i) private returns (bool ok) {
        Door storage d = _doors[i];
        address target = d.target;
        uint256 stipend = d.gas;
        uint256 needed = stipend + SYNC_RESERVE_GAS;
        ok = true;
        if (d.kind == DoorKind.RULES) {
            uint256 n = _assetCount;
            for (uint256 a; a < n; ++a) {
                Currency c = _assets[a].currency;
                if (gasleft() < needed) revert SyncStarved(i, needed);
                (bool readOk, uint256 owed) =
                    _readWord(target, stipend, abi.encodeCall(IHookrRulesDoor.claimable, (c, address(this))));
                if (!readOk) {
                    ok = false;
                    continue;
                }
                if (owed == 0) continue;
                if (gasleft() < needed) revert SyncStarved(i, needed);
                if (!_call(target, stipend, abi.encodeCall(IHookrRulesDoor.claim, (c)))) ok = false;
            }
        } else {
            if (gasleft() < needed) revert SyncStarved(i, needed);
            ok = _call(target, stipend, abi.encodeCall(IHookrFamilyForwarder.pull, ()));
        }
    }

    /// @dev What a sync recognizes of `a` now: its surplus, clamped to the room left under `MAX_RECEIVED` (which is
    ///      also `MAX_RECOGNITION`, so one clamp covers both bounds).
    function _recognizable(Asset storage a) private view returns (uint256 amount) {
        amount = _surplus(a);
        uint256 room = MAX_RECEIVED - a.received;
        if (amount > room) amount = room;
    }

    /// @dev A call with `stipend` gas that copies no return data, so a door cannot make the sync pay for its answer.
    function _call(address target, uint256 stipend, bytes memory data) private returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(stipend, target, 0, add(data, 0x20), mload(data), 0, 0)
        }
    }

    /// @dev A staticcall with `stipend` gas that must answer exactly one word, read from scratch space.
    function _readWord(address target, uint256 stipend, bytes memory data)
        private
        view
        returns (bool ok, uint256 word)
    {
        assembly ("memory-safe") {
            ok := staticcall(stipend, target, add(data, 0x20), mload(data), 0, 0x20)
            ok := and(ok, eq(returndatasize(), 0x20))
            word := mload(0)
        }
    }
}
