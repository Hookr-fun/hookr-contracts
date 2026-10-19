// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRevenueToken} from "tokenizer/interfaces/IHookrRevenueToken.sol";
import {IHookrCompoundShares} from "../interfaces/IHookrCompoundShares.sol";

/// @title Hookr compound shares
/// @notice The compounder's shares (solmate's ERC-20, with EIP-2612 permit, 18 decimals like the revenue token) and
///         the ledger of its side assets: every asset the vault receives that is not the pool's quote, split over the
///         earning shares by an index as it is recognized, settled on every transfer, paid with `claimSide`. The side
///         assets are the revenue token's assets other than the quote (fixed at construction) plus any asset the
///         token's creator lists (`listSide`), up to `MAX_SIDES` in all. The reentrancy guard every cash-moving
///         function of the compounder holds lives here too.
/// @dev Recognition is by balance delta (`_recognizeSides`), as the token does in its sync, and only while shares
///      earn; what arrives while none do waits for the first that does. Rounding carries over to the next
///      recognition, so nothing is lost to it. Both sides of every transfer, mint and burn are settled at their old
///      balances before the balances move, and the compounder claims and recognizes first (`_syncSides`), so a
///      holder keeps what streamed while it held. A side asset's balance is read with a bounded staticcall that keeps
///      the first word of the answer only, so an asset that reverts, runs out of gas or answers with a huge payload is
///      skipped or cheap and stops nothing; a side asset that cannot be paid stops only its own `claimSide`. What a
///      drop brings in (`_streamSide`) is held back and released linearly over `dropStream` seconds, so it is
///      recognized, by whoever holds shares as it releases, the way the revenue token recognizes its own income; shares
///      held by the PoolManager or at `DEAD` never earn, because neither can claim.
abstract contract HookrCompoundShares is ERC20, IHookrCompoundShares {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    /// @inheritdoc IHookrCompoundShares
    uint256 public constant SCALE = 1e36;
    /// @inheritdoc IHookrCompoundShares
    uint256 public constant MAX_SIDES = 8;
    /// @inheritdoc IHookrCompoundShares
    uint256 public constant SIDE_READ_GAS = 30_000;
    /// @inheritdoc IHookrCompoundShares
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev One account's standing in one side asset: the index it was last settled at and its scaled credit.
    struct Credit {
        uint256 index;
        uint256 creditScaled;
    }

    /// @inheritdoc IHookrCompoundShares
    uint256 public immutable fixedSideCount;
    /// @inheritdoc IHookrCompoundShares
    uint256 public immutable dropStream;
    /// @dev The PoolManager: shares it holds (a pool of the shares) can never claim, so they earn nothing.
    address private immutable _sink;
    Side[] internal _sides;
    /// @dev The side's position plus one, zero for an asset that is no side.
    mapping(Currency currency => uint256 position) private _sidePosition;
    mapping(address account => mapping(uint256 side => Credit)) internal _credits;
    bool private transient _entered;

    modifier nonReentrant() {
        if (_entered) revert Reentrant();
        _entered = true;
        _;
        _entered = false;
    }

    /// @param name_ ERC-20 name of the shares.
    /// @param symbol_ ERC-20 symbol of the shares.
    /// @param token The revenue token, whose assets other than `quote` are the fixed side assets.
    /// @param quote The pool's quote currency.
    /// @param sink_ The PoolManager, whose shares earn nothing.
    constructor(string memory name_, string memory symbol_, IHookrRevenueToken token, Currency quote, address sink_)
        ERC20(name_, symbol_, 18)
    {
        _sink = sink_;
        uint256 streamSeconds = token.streamSeconds();
        dropStream = streamSeconds == 0 ? 7 days : streamSeconds;
        uint256 n = token.assetCount();
        for (uint256 i; i < n; ++i) {
            Currency c = token.assetAt(i).currency;
            if (c == quote) continue;
            _addSide(c);
        }
        fixedSideCount = _sides.length;
    }

    // ------------------------------------------------------------------ reads

    /// @inheritdoc IHookrCompoundShares
    function sideCount() external view returns (uint256) {
        return _sides.length;
    }

    /// @inheritdoc IHookrCompoundShares
    function sideAt(uint256 side) external view returns (Side memory) {
        if (side >= _sides.length) revert UnknownSide(side);
        return _sides[side];
    }

    /// @inheritdoc IHookrCompoundShares
    function sideOf(Currency currency) public view returns (bool listed, uint256 side) {
        uint256 position = _sidePosition[currency];
        if (position == 0) return (false, 0);
        return (true, position - 1);
    }

    /// @inheritdoc IHookrCompoundShares
    function earningSupply() public view returns (uint256) {
        return totalSupply - balanceOf[DEAD] - balanceOf[_sink];
    }

    /// @inheritdoc IHookrCompoundShares
    function sideClaimable(address account, uint256 side) public view returns (uint256) {
        if (side >= _sides.length) revert UnknownSide(side);
        Credit storage c = _credits[account][side];
        uint256 earning = _earns(account) ? balanceOf[account] : 0;
        return (c.creditScaled + earning * (_sides[side].index - c.index)) / SCALE;
    }

    // ------------------------------------------------------------------ claims

    /// @inheritdoc IHookrCompoundShares
    function claimSide(uint256 side, address to) external nonReentrant returns (uint256 amount) {
        if (side >= _sides.length) revert UnknownSide(side);
        _checkRecipient(to);
        Side storage s = _sides[side];
        _settleSide(msg.sender, side, s.index);
        Credit storage c = _credits[msg.sender][side];
        uint256 owed = c.creditScaled / SCALE;
        uint256 held = _held(s.currency);
        amount = owed < held ? owed : held;
        if (amount == 0) revert NothingToClaim();
        // amount <= owed = creditScaled / SCALE, so amount x SCALE <= creditScaled.
        unchecked {
            c.creditScaled -= amount * SCALE;
        }
        s.paid += uint128(amount);
        _send(s.currency, to, amount);
        emit SideClaimed(msg.sender, side, to, amount);
    }

    // ------------------------------------------------------------------ transfers

    /// @notice ERC-20 transfer; the side assets are claimed and recognized first, and both sides settled.
    /// @dev The compounder itself cannot receive shares: nothing could ever move them again.
    function transfer(address to, uint256 amount) public override returns (bool) {
        _checkRecipient(to);
        _syncSides();
        _settleBoth(msg.sender, to);
        return super.transfer(to, amount);
    }

    /// @notice ERC-20 transferFrom; the side assets are claimed and recognized first, and both sides settled.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _checkRecipient(to);
        _syncSides();
        _settleBoth(from, to);
        return super.transferFrom(from, to, amount);
    }

    // ------------------------------------------------------------------ ledger

    /// @dev Claims the side assets the revenue token owes and recognizes what the vault holds, before shares move.
    ///      The compounder fills it in.
    function _syncSides() internal virtual;

    /// @dev Lists `currency` as a side asset, unless it is listed. Reverts `TooManySides` at the cap.
    function _addSide(Currency currency) internal returns (uint256 side) {
        uint256 position = _sidePosition[currency];
        if (position != 0) return position - 1;
        side = _sides.length;
        if (side == MAX_SIDES) revert TooManySides(side + 1);
        _sides.push();
        _sides[side].currency = currency;
        _sidePosition[currency] = side + 1;
        emit SideAdded(side, currency);
    }

    /// @dev Recognizes what arrived of every side asset since the last time: the balance above `recognized - paid`,
    ///      split over the earning shares into the index. Nothing is recognized while no share earns. Returns whether
    ///      any amount was.
    function _recognizeSides() internal returns (bool any) {
        uint256 n = _sides.length;
        if (n == 0) return false;
        uint256 supply = earningSupply();
        if (supply == 0) return false;
        for (uint256 i; i < n; ++i) {
            Side storage s = _sides[i];
            uint256 accounted = s.recognized - s.paid + _unreleased(s.dropped, s.droppedAt);
            uint256 held = _held(s.currency);
            if (held <= accounted) continue;
            uint256 amount = held - accounted;
            uint256 room = type(uint128).max - s.recognized;
            if (amount > room) amount = room;
            if (amount == 0) continue;
            // amount < 2^128 and SCALE < 2^120, so the scaled amount fits.
            uint256 scaled = amount * SCALE + s.carry;
            s.index += scaled / supply;
            s.carry = scaled % supply;
            s.recognized += uint128(amount);
            any = true;
            emit SideRecognized(i, amount, s.index);
        }
    }

    /// @dev Settles `from` and `to` (the zero address for a mint or a burn) in every side asset.
    function _settleBoth(address from, address to) internal {
        uint256 n = _sides.length;
        for (uint256 i; i < n; ++i) {
            uint256 index = _sides[i].index;
            if (from != address(0)) _settleSide(from, i, index);
            if (to != address(0)) _settleSide(to, i, index);
        }
    }

    /// @dev Brings `account`'s credit in side `side` up to `index`, at its current balance.
    function _settleSide(address account, uint256 side, uint256 index) internal {
        Credit storage c = _credits[account][side];
        uint256 last = c.index;
        if (index == last) return;
        uint256 balance = _earns(account) ? balanceOf[account] : 0;
        if (balance != 0) c.creditScaled += balance * (index - last);
        c.index = index;
    }

    /// @dev A mint settles the receiver first, so new shares earn only from now.
    function _mint(address to, uint256 amount) internal override {
        _settleBoth(address(0), to);
        super._mint(to, amount);
    }

    /// @dev A burn settles the holder first, so the credit of the burnt shares stays with the holder.
    function _burn(address from, uint256 amount) internal override {
        _settleBoth(from, address(0));
        super._burn(from, amount);
    }

    /// @dev The vault's balance of `currency`, read with `SIDE_READ_GAS`; zero when the asset does not answer. Only the
    ///      first word of the answer is copied, whatever the asset returns.
    function _held(Currency currency) internal view returns (uint256 held) {
        if (currency.isAddressZero()) return address(this).balance;
        address asset = Currency.unwrap(currency);
        bytes memory callData = abi.encodeCall(IERC20.balanceOf, (address(this)));
        uint256 stipend = SIDE_READ_GAS;
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(stipend, asset, add(callData, 32), mload(callData), 0, 0x20)
            held := mload(0)
            if lt(returndatasize(), 0x20) { ok := 0 }
        }
        if (!ok) return 0;
    }

    /// @dev Whether `account` earns side assets: neither `DEAD` nor the PoolManager does.
    function _earns(address account) internal view returns (bool) {
        return account != DEAD && account != _sink;
    }

    /// @dev What of `total` (set at `since`) is still held back: it releases linearly over `dropStream` seconds.
    function _unreleased(uint256 total, uint256 since) internal view returns (uint256) {
        uint256 end = since + dropStream;
        return block.timestamp >= end ? 0 : total * (end - block.timestamp) / dropStream;
    }

    /// @dev Holds back `amount` more of side asset `side`, which a drop just brought in, to release over `dropStream`
    ///      seconds from now together with whatever of the earlier ones is still held back.
    function _streamSide(uint256 side, uint256 amount) internal {
        Side storage s = _sides[side];
        uint256 total = _unreleased(s.dropped, s.droppedAt) + amount;
        s.dropped = total > type(uint128).max ? type(uint128).max : uint128(total);
        s.droppedAt = uint40(block.timestamp);
    }

    /// @dev Pays `amount` of `currency` to `to`; a native send that fails reverts.
    function _send(Currency currency, address to, uint256 amount) internal {
        if (currency.isAddressZero()) {
            currency.transfer(to, amount);
        } else {
            IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        }
    }

    /// @dev Neither the zero address nor the compounder itself can receive.
    function _checkRecipient(address to) internal view {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
    }
}
