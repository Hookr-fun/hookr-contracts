// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {HookrIncomeLedger} from "./HookrIncomeLedger.sol";
import {IHookrDropBox} from "../interfaces/IHookrDropBox.sol";
import {IHookrRevenueDoor} from "../interfaces/IHookrRevenueDoor.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";
import {IHookrRulesDoor} from "../interfaces/IHookrRulesDoor.sol";
import {HookrIncomeRecovery} from "../libraries/HookrIncomeRecovery.sol";
import {IHookrIncomeRecovery} from "../interfaces/IHookrIncomeRecovery.sol";

/// @title Hookr income sync, part of the HookRevenue Tokenizer
/// @notice The pulling half of a revenue token: the append-only door list, the permissionless syncs that pull the
///         doors in pages and recognize what arrived, Hookr's leg of what a legged door delivers, the caller's tip,
///         the Fee Bridge slice, bonus deposits, and `dropStray`, which hands anything else sent to the token to the
///         drop box. `receive()` stays empty: recognition happens in a sync, never on arrival.
/// @dev Doors are pulled one by one, each call with its own gas stipend, after a gas check that reverts the whole sync
///      when the caller left less than the door's stipend plus `SYNC_RESERVE_GAS` (a starved sync must fail, not
///      quietly skip doors). Nothing bounds the number of doors: `sync` pulls them all, `syncRange` a page, `syncSome`
///      a chosen set, and every one of them settles the same way, so a caller pages through a long list and routes
///      around a door that turns hostile. Recognition is by balance, so a page recognizes everything that arrived,
///      from any door or push, and no stream depends on being in the same page as another.
///      A RULES door is pulled by the token itself (`claim(currency)` pays only the caller's claim); every other kind
///      forwards what it pulls here through `pull()`. For a door with a leg, every listed asset's balance is read
///      before and after its pull and `legBps` of each rise is sent to `legCollector` at once. After the pulls the
///      tip and the bridge slice are taken from the ETH the pulled doors delivered net of the legs (the native delta
///      across the loop), and each listed asset's balance above `received - paid` is recognized once.
///
///      Whatever reaches the token is split: native ETH and the listed assets by the next sync, as surplus, claimable
///      at once at a zero release period (the default) and spread over a positive one; any other ERC-20 by
///      `dropStray`, which moves it to the drop box: one immediate drop at a release period under an hour (zero
///      included), the box's stray stream in slices at an hour or more.
///
///      No income is recognized while the PoolManager is unlocked: `sync`, `syncRange`, `syncSome` and `depositBonus`
///      revert `PoolManagerUnlocked` inside an unlock (`_requireLocked`). Inside one, anyone can take every share the
///      PoolManager holds for free, and whoever holds earning shares at recognition owns that income. Doors still
///      open their own unlocks while they are pulled (Rules claims, position collections): the check runs once, at
///      the entry, before any door. Transfers, claims and `dropStray` stay open inside an unlock, so swaps and
///      liquidity changes of this token work as before; they move shares but recognize nothing.
///
///      Every door call, balance read and leg payment is gas-capped. A door call is a raw call that copies no return
///      data: a door that reverts, runs out of its stipend or answers with garbage fails only itself
///      (`DoorPulled(i, false)`). A balance read of a listed ERC-20 is a staticcall with `BALANCE_GAS` that must
///      answer one word: one that reverts, burns its gas or answers otherwise skips that asset alone (no leg measured,
///      `AssetReadFailed` at recognition), never the others. A leg payment is a call with `LEG_GAS`; one that fails
///      leaves the amount to the holders. The rest run on the gas left: the tip to the caller and the bridge slice
///      (HookrSettlement.send, which reverts the sync when either refuses), `depositBonus`'s reads and `transferFrom`,
///      and `dropStray`'s read, transfer and box call.
abstract contract HookrIncomeSync is HookrIncomeLedger {
    using SafeERC20 for IERC20;

    /// @inheritdoc IHookrRevenueToken
    uint16 public constant MAX_TIP_BPS = 100;
    /// @inheritdoc IHookrRevenueToken
    uint256 public constant MIN_TIP_PULL = 0.001 ether;
    /// @inheritdoc IHookrRevenueToken
    uint16 public constant MAX_BRIDGE_BPS = 2_000;
    /// @inheritdoc IHookrRevenueToken
    uint16 public constant MAX_LEG_BPS = 500;
    /// @inheritdoc IHookrRevenueToken
    uint32 public constant MIN_DOOR_GAS = 100_000;
    /// @inheritdoc IHookrRevenueToken
    uint32 public constant MAX_DOOR_GAS = 12_000_000;
    /// @inheritdoc IHookrRevenueToken
    /// @dev Covers the worst a door's tail can cost with eight listed assets: a legged door's seven ERC-20 balance
    ///      reads and eight leg payments each using its whole `LEG_GAS`, then the recognition of all eight with seven
    ///      reads burning theirs, the tip, the bridge slice and the events. A sync of a legged door that uses its whole
    ///      600,000 stipend, then eight legs that each use all but a few thousand of `LEG_GAS`, uses 7,932,856 in all
    ///      (`HookrIncomeSync.legs`); the rest is margin. Unused gas returns to the caller.
    uint256 public constant SYNC_RESERVE_GAS = 8_000_000;
    /// @inheritdoc IHookrRevenueToken
    uint256 public constant BALANCE_GAS = 50_000;
    /// @inheritdoc IHookrRevenueToken
    /// @dev Sized for the dearest listed asset the tokenizer can create, a revenue token of eight assets, sent into the
    ///      leg collector (which every such token leaves out of `earns`), with that token's first release in all eight
    ///      assets and the sender settled for the first time: 903,221 measured cold as a transaction of its own, the
    ///      21,000 base cost included (`test/gas/HookrRevenueToken.caps`, `--isolate`); the call's own frame needs
    ///      882,221 of the 900,000, a margin of 17,779. Native ETH into the collector needs a fraction of it.
    uint256 public constant LEG_GAS = 900_000;
    /// @dev A balance read that failed.
    uint256 private constant UNREAD = type(uint256).max;

    /// @inheritdoc IHookrRevenueToken
    uint16 public immutable tipBps;
    /// @inheritdoc IHookrRevenueToken
    address public immutable legCollector;
    /// @inheritdoc IHookrRevenueToken
    /// @dev Shares a slot with `bridgeBps` and `live`: a sync reads the three in one load.
    address public bridge;
    /// @inheritdoc IHookrRevenueToken
    uint16 public bridgeBps;
    /// @inheritdoc IHookrRevenueToken
    bool public live;

    Door[] internal _doors;
    /// @dev A door's index plus one; zero for an address that is not a door.
    mapping(address target => uint256) internal _doorSlot;
    /// @inheritdoc IHookrRevenueToken
    mapping(address door => uint16) public legOf;

    /// @param tipBps_ The sync caller's tip, at most `MAX_TIP_BPS`.
    /// @param legCollector_ Where Hookr's leg goes; nonzero.
    constructor(uint16 tipBps_, address legCollector_) {
        if (tipBps_ > MAX_TIP_BPS || legCollector_ == address(0)) revert InvalidConfig();
        tipBps = tipBps_;
        legCollector = legCollector_;
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
    function isDoor(address target) external view returns (bool) {
        return _doorSlot[target] != 0;
    }

    /// @inheritdoc IHookrRevenueToken
    function doorIndexOf(address target) external view returns (uint256) {
        uint256 slot = _doorSlot[target];
        if (slot == 0) revert InvalidTarget(target);
        return slot - 1;
    }

    /// @inheritdoc IHookrRevenueToken
    function doorAt(uint256 door) external view returns (Door memory) {
        if (door >= _doors.length) revert InvalidDoor(door);
        return _doors[door];
    }

    /// @inheritdoc IHookrRevenueToken
    function doors(uint256 start, uint256 count) external view returns (Door[] memory page) {
        (uint256 from, uint256 to) = _clip(start, count);
        page = new Door[](to - from);
        for (uint256 i = from; i < to; ++i) {
            page[i - from] = _doors[i];
        }
    }

    // ------------------------------------------------------------------ syncs

    /// @inheritdoc IHookrRevenueToken
    function sync() external nonReentrant returns (uint256 tip) {
        uint256 ethBefore = _beginSync();
        uint256 n = _doors.length;
        for (uint256 i; i < n; ++i) {
            _pullDoor(i);
        }
        return _settle(ethBefore);
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev A `start` at or past the last door pulls nothing and still recognizes the pushes.
    function syncRange(uint256 start, uint256 count) external nonReentrant returns (uint256 tip) {
        uint256 ethBefore = _beginSync();
        (uint256 from, uint256 to) = _clip(start, count);
        for (uint256 i = from; i < to; ++i) {
            _pullDoor(i);
        }
        return _settle(ethBefore);
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev A repeated index pulls that door again, which is harmless.
    function syncSome(uint256[] calldata doorIds) external nonReentrant returns (uint256 tip) {
        uint256 ethBefore = _beginSync();
        uint256 n = _doors.length;
        for (uint256 k; k < doorIds.length; ++k) {
            uint256 i = doorIds[k];
            if (i >= n) revert InvalidDoor(i);
            _pullDoor(i);
        }
        return _settle(ethBefore);
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev Native: asset 0 only, `msg.value == amount`. ERC-20: no value; the whole `amount` must land (a token that
    ///      takes a cut is refused with `InexactTransfer`). Recognized at once under `SOURCE_BONUS`; the balance and
    ///      `received` move together, so the next sync sees no surplus from it and tips nothing. An index past the
    ///      last asset reverts `UnknownAsset`.
    function depositBonus(uint256 asset, uint256 amount) external payable nonReentrant {
        _requireLocked();
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
    /// @dev Refuses native ETH, this token and every listed asset with `InvalidAsset`; otherwise moves the whole
    ///      balance to the drop box and has it recognize what it holds of the asset beyond its books through
    ///      IHookrDropBox.dropStray. A release period under an hour (zero included) records an immediate previous-block snapshot drop; an
    ///      hour or more joins the timed stray stream. Nothing new is `NothingReceived`. `StrayDropped.amount` is what
    ///      left this token. Needs no `live`: allocation still requires the box's eligible snapshot supply.
    function dropStray(address asset) external nonReentrant {
        Currency c = Currency.wrap(asset);
        if (asset == address(0) || asset == address(this) || _position[c] != 0) revert InvalidAsset(c);
        IERC20 stray = IERC20(asset);
        uint256 amount = stray.balanceOf(address(this));
        address box = dropBox;
        if (amount != 0) stray.safeTransfer(box, amount);
        IHookrDropBox(box).dropStray(asset);
        emit StrayDropped(asset, amount);
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev HookrIncomeRecovery.collectIncome by a raw delegatecall (no return data read; a revert is bubbled): when
    ///      `revenueToken` lists this token as an asset, this token's own share of it is claimed to 0xdead (it could
    ///      never pay holders in their own token), then `claimAll(this token)` with the gas left, by a call that
    ///      copies no return data; a claim that reverts (nothing due, or not a revenue token at all) brings nothing.
    ///      The lock is held throughout, so `revenueToken` cannot enter a sync or a claim while it pays.
    function collectIncome(address revenueToken) external nonReentrant {
        if (revenueToken == address(this)) revert InvalidAsset(Currency.wrap(revenueToken));
        address recovery = address(HookrIncomeRecovery);
        bytes4 selector = HookrIncomeRecovery.collectIncome.selector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 4), revenueToken)
            if iszero(delegatecall(gas(), recovery, ptr, 0x24, 0, 0)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }

    /// @inheritdoc IHookrIncomeRecovery
    function collectDrops(address revenueToken, uint256[] calldata dropIds)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        return HookrIncomeRecovery.collectDrops(revenueToken, address(this), dropIds);
    }

    // ------------------------------------------------------------------ tokenizer-time setters

    /// @dev Appends `d`: a target with code that is not yet a door, not this token, its drop box, the PoolManager or
    ///      0xdead (the token adds its tokenizer to the list), a stipend in [`MIN_DOOR_GAS`, `MAX_DOOR_GAS`], a leg at
    ///      most `MAX_LEG_BPS` and none on a RULES door. `InvalidTarget` otherwise.
    function _addDoor(Door calldata d) internal returns (uint256 id) {
        address target = d.target;
        if (
            target.code.length == 0 || _doorSlot[target] != 0 || target == address(this) || target == dropBox
                || target == poolManager || target == DEAD || d.gas < MIN_DOOR_GAS || d.gas > MAX_DOOR_GAS
                || d.legBps > MAX_LEG_BPS || (d.kind == DoorKind.RULES && d.legBps != 0)
        ) revert InvalidTarget(target);
        id = _doors.length;
        _doors.push(d);
        _doorSlot[target] = id + 1;
        if (d.legBps != 0) legOf[target] = d.legBps;
        emit DoorAdded(id, d.kind, target, d.gas, d.legBps);
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

    /// @inheritdoc HookrIncomeLedger
    function _isDoor(address account) internal view override returns (bool) {
        return _doorSlot[account] != 0;
    }

    // ------------------------------------------------------------------ internals

    /// @dev The unlock and live checks and the native balance every sync measures its pulled ETH from.
    function _beginSync() private view returns (uint256 ethBefore) {
        _requireLocked();
        if (!live) revert NotLive();
        return address(this).balance;
    }

    /// @dev Refuses recognition while the PoolManager is unlocked (`PoolManagerUnlocked`), read with one
    ///      `exttload(IS_UNLOCKED_SLOT)` (v4-core Lock: `keccak256("Unlocked") - 1`). Only a PoolManager that answers
    ///      one nonzero word refuses; a call that fails or answers otherwise reads as locked. The tokenizer passes the
    ///      v4 PoolManager, whose `exttload` is a plain transient read that always answers, so that branch is a
    ///      stand-in's (unit tests) only; and a caller cannot starve the read into failing, because the 1/64 of gas
    ///      the EVM keeps back from a call that ran out could not pay for the recognition after it.
    function _requireLocked() private view {
        address manager = poolManager;
        assembly ("memory-safe") {
            mstore(0x00, 0xf135baaa)
            mstore(0x20, 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23)
            let ok := staticcall(gas(), manager, 0x1c, 0x24, 0x00, 0x20)
            if mul(mul(ok, eq(returndatasize(), 0x20)), mload(0x00)) {
                mstore(0x00, 0x0e1475a4)
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Doors `start` to `start + count - 1`, clipped to the list: `[from, to)`.
    function _clip(uint256 start, uint256 count) private view returns (uint256 from, uint256 to) {
        uint256 n = _doors.length;
        if (start >= n) return (n, n);
        to = count < n - start ? start + count : n;
        from = start;
    }

    /// @dev The second half of a sync, after the pulls: the tip and the bridge slice on the native delta since
    ///      `ethBefore` (net of the native legs, which left inside the loop), then one recognition per listed asset,
    ///      then `Synced`. A recognition is clamped to what the ledger can still count (`MAX_RECEIVED` in total); the
    ///      rest stays as surplus for a later sync. A sync that pulls nothing is allowed and only emits.
    function _settle(uint256 ethBefore) private returns (uint256 tip) {
        uint256 ethNow = address(this).balance;
        uint256 pulledEth = ethNow > ethBefore ? ethNow - ethBefore : 0;
        if (pulledEth >= MIN_TIP_PULL) tip = pulledEth * tipBps / 10_000;
        uint256 bridged;
        address bridge_ = bridge;
        if (bridge_ != address(0)) bridged = (pulledEth - tip) * bridgeBps / 10_000;
        if (tip != 0) HookrSettlement.send(Currency.wrap(address(0)), msg.sender, tip);
        if (bridged != 0) HookrSettlement.send(Currency.wrap(address(0)), bridge_, bridged);
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            Asset storage a = _assets[i];
            uint256 held = _balanceOf(a.currency);
            if (held == UNREAD) {
                emit AssetReadFailed(i);
                continue;
            }
            uint256 received = a.received;
            uint256 accounted = received - a.paid;
            if (held <= accounted) continue;
            uint256 amount = held - accounted;
            uint256 room = MAX_RECEIVED - received;
            if (amount > room) amount = room;
            if (amount != 0) _recognize(i, amount, SOURCE_SYNC);
        }
        emit Synced(msg.sender, pulledEth, tip, bridged);
    }

    /// @dev Pulls door `i` and emits `DoorPulled`. RULES: for each listed asset, read `claimable(currency, this)` and,
    ///      when nonzero, call `claim(currency)`. Every other kind: call `pull()`, with every listed asset's balance
    ///      read around it when the door has a leg. Before every call to the door the caller must have its stipend
    ///      plus `SYNC_RESERVE_GAS` left, or the sync reverts `SyncStarved`: with that much left the EVM hands the door
    ///      its whole stipend (the 63/64 rule never trims it), so a door that fails did so on its own, and the reserve
    ///      carries the leg and whatever follows the door.
    function _pullDoor(uint256 i) private {
        Door memory d = _doors[i];
        uint256 needed = uint256(d.gas) + SYNC_RESERVE_GAS;
        bool ok = true;
        if (d.kind == DoorKind.RULES) {
            uint256 n = _assetCount;
            for (uint256 a; a < n; ++a) {
                Currency c = _assets[a].currency;
                if (gasleft() < needed) revert SyncStarved(i, needed);
                (bool readOk, uint256 owed) =
                    _readWord(d.target, d.gas, abi.encodeCall(IHookrRulesDoor.claimable, (c, address(this))));
                if (!readOk) {
                    ok = false;
                    continue;
                }
                if (owed == 0) continue;
                if (gasleft() < needed) revert SyncStarved(i, needed);
                if (!_call(d.target, d.gas, abi.encodeCall(IHookrRulesDoor.claim, (c)))) ok = false;
            }
        } else if (d.legBps == 0) {
            if (gasleft() < needed) revert SyncStarved(i, needed);
            ok = _call(d.target, d.gas, abi.encodeCall(IHookrRevenueDoor.pull, ()));
        } else {
            ok = _pullWithLeg(i, d, needed);
        }
        emit DoorPulled(i, ok);
    }

    /// @dev Pulls a legged door: every listed asset's balance before, the pull, every balance after, and `legBps` of
    ///      each rise sent to `legCollector` (`LegPaid`). An asset whose balance could not be read on either side pays
    ///      no leg this time; a payment that fails leaves the amount to the holders. The leg is
    ///      `delta / 10,000 x legBps + (delta % 10,000) x legBps / 10,000`, the floor of `delta x legBps / 10,000`
    ///      without an overflow for any answer a balance read can give.
    function _pullWithLeg(uint256 i, Door memory d, uint256 needed) private returns (bool ok) {
        if (gasleft() < needed) revert SyncStarved(i, needed);
        uint256 n = _assetCount;
        uint256[] memory before = new uint256[](n);
        for (uint256 a; a < n; ++a) {
            before[a] = _balanceOf(_assets[a].currency);
        }
        if (gasleft() < needed) revert SyncStarved(i, needed);
        ok = _call(d.target, d.gas, abi.encodeCall(IHookrRevenueDoor.pull, ()));
        uint256 legBps = d.legBps;
        for (uint256 a; a < n; ++a) {
            uint256 was = before[a];
            if (was == UNREAD) continue;
            Currency c = _assets[a].currency;
            uint256 held = _balanceOf(c);
            if (held == UNREAD || held <= was) continue;
            uint256 delta = held - was;
            uint256 leg = delta / 10_000 * legBps + delta % 10_000 * legBps / 10_000;
            if (leg != 0 && _payLeg(c, leg)) emit LegPaid(i, a, leg);
        }
    }

    /// @dev This token's balance of `c`: native ETH directly, an ERC-20 by a `BALANCE_GAS` staticcall that must answer
    ///      one word below `UNREAD`; `UNREAD` when it does not.
    function _balanceOf(Currency c) private view returns (uint256) {
        if (c.isAddressZero()) return address(this).balance;
        (bool ok, uint256 word) =
            _readWord(Currency.unwrap(c), BALANCE_GAS, abi.encodeCall(IERC20.balanceOf, (address(this))));
        return ok ? word : UNREAD;
    }

    /// @dev Sends `amount` of `c` to `legCollector` with `LEG_GAS`: ETH by a plain call, an ERC-20 by `transfer`,
    ///      which must succeed and answer nothing or `true`. Never reverts.
    function _payLeg(Currency c, uint256 amount) private returns (bool ok) {
        address collector = legCollector;
        if (c.isAddressZero()) {
            assembly ("memory-safe") {
                ok := call(LEG_GAS, collector, amount, 0, 0, 0, 0)
            }
            return ok;
        }
        bytes memory data = abi.encodeCall(IERC20.transfer, (collector, amount));
        address erc20 = Currency.unwrap(c);
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := call(LEG_GAS, erc20, 0, add(data, 0x20), mload(data), 0, 0x20)
            ok := and(ok, or(iszero(returndatasize()), and(gt(returndatasize(), 0x1f), eq(mload(0), 1))))
        }
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
