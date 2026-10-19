// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {HookrRevenueGuard} from "./HookrRevenueGuard.sol";
import {HookrBalanceHistory} from "./HookrBalanceHistory.sol";
import {HookrDropHost} from "./HookrDropHost.sol";
import {HookrERC20Permit} from "./HookrERC20Permit.sol";
import {HookrERC20Authorizations} from "./HookrERC20Authorizations.sol";
import {IHookrBalanceHistory} from "../interfaces/IHookrBalanceHistory.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";

/// @title Hookr income ledger, part of the HookRevenue Tokenizer
/// @notice The accounting half of a revenue token: a fixed-supply ERC-20 with one income index per asset, exact carry,
///         linear release of every recognized arrival over `streamSeconds`, per-holder checkpoints settled on every
///         transfer with no external call, and claims that pay the lesser of what is owed and what is held.
/// @dev One index per asset, scaled by 1e36, with the remainder of every split carried to the next; the settlement of
///      both sides in `_update`; an earning supply that leaves the excluded holders out; and a release that is set
///      by weight on every recognition, so no arrival re-spreads what was already streaming.
///
///      Accounting, per asset: `earningSupply_i x delta_i` summed over releases plus `carry` equals
///      `released x SCALE` exactly; `released == received - pendingStream`; `received - paid <= balance` while every
///      asset lands exactly. A holder's balance is constant between its checkpoints and never above the earning
///      supply any release in between was split over, so its scaled credit is at most `received x SCALE`; with
///      `received <= MAX_RECEIVED` (2^128 - 1) and `SCALE` 1e36 nothing reaches 2^256, and the sum of what every
///      holder is owed never exceeds what was released, so `paid` never exceeds `received`. Recognition adds to
///      `pendingStream` and sets the window to the amount-weighted mean of what was left of the old window and a full
///      `streamSeconds` (so an arrival next to nothing pending streams over `streamSeconds`, and a dust arrival next
///      to a large pending stream moves the window by nothing measurable); `_release` moves
///      `pendingStream x dt / (end - last)` into the index over the shares that earn now. The window never exceeds
///      `streamSeconds` and the old stream never speeds up, so a holder for `t` seconds gets at least
///      `1 - e^(-t / stream)` of what was unreleased when it bought, and a holder that buys and sells in one block
///      gets nothing.
///
///      Shares the PoolManager, 0xdead, the token's drop box or the token itself hold earn nothing and are left
///      out of `earningSupply`; when no share earns, a release waits (nothing is lost, nothing is split over zero): the
///      stream and `lastRelease` stay put until an earning holder exists, then release over the whole elapsed window.
///
///      The earning supply and the per-holder balance history are the drop host's (HookrDropHost, HookrBalanceHistory):
///      one `earns` rule, a pure function of immutables, serves the stream (every release is split over
///      `earningSupply()`) and the drops (shares by `balanceAt` the snapshot block). `_update` settles the stream for
///      both sides first, at their old balances, then lets the history move the balances and write the checkpoints.
///      Nothing in either makes an external call.
///
///      Every holder action can be signed and relayed, so a holder never needs gas: `permit` (HookrERC20Permit),
///      `transferWithAuthorization` and `receiveWithAuthorization` (HookrERC20Authorizations, which move shares
///      through the same `_update` as a transfer, so the ledger and the history see no difference), and the claims
///      here by signature, which pay only the account the holder signed for.
///
///      Storage: the assets sit in a fixed array of `MAX_ASSETS`, so reaching one is slot arithmetic with no length
///      read, and their number is an immutable. An asset's `received` and `paid` share one slot (both are below
///      2^128), as do `pendingStream`, `streamEnd` and `lastRelease`, so an idle transfer reads two slots per asset
///      and a claim reads four.
abstract contract HookrIncomeLedger is
    HookrDropHost,
    HookrERC20Permit,
    HookrERC20Authorizations,
    HookrRevenueGuard,
    IHookrRevenueToken
{
    using SafeERC20 for IERC20;

    /// @inheritdoc IHookrRevenueToken
    uint256 public constant SCALE = 1e36;
    /// @inheritdoc IHookrRevenueToken
    uint256 public constant MAX_ASSETS = 4;
    /// @inheritdoc IHookrRevenueToken
    uint256 public constant MIN_SUPPLY = 1;
    /// @inheritdoc IHookrRevenueToken
    /// @dev The carry stays below the earning supply, so `amount x SCALE + carry` fits.
    uint256 public constant MAX_SUPPLY = type(uint128).max;
    /// @inheritdoc IHookrRevenueToken
    uint256 public constant MAX_RECEIVED = type(uint128).max;
    /// @inheritdoc IHookrRevenueToken
    uint256 public constant MAX_RECOGNITION = MAX_RECEIVED;
    /// @inheritdoc IHookrRevenueToken
    uint32 public constant MIN_STREAM_SECONDS = 1 days;
    /// @inheritdoc IHookrRevenueToken
    uint32 public constant MAX_STREAM_SECONDS = 14 days;
    /// @inheritdoc IHookrRevenueToken
    uint32 public constant DEFAULT_STREAM_SECONDS = 7 days;
    /// @inheritdoc IHookrRevenueToken
    bytes32 public constant SOURCE_SYNC = keccak256("hookr.fee.source.sync");
    /// @inheritdoc IHookrRevenueToken
    bytes32 public constant SOURCE_BONUS = keccak256("hookr.fee.source.bonus");
    /// @inheritdoc IHookrRevenueToken
    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("Claim(address holder,uint256 asset,address to,bytes32 nonce,uint256 deadline)");
    /// @inheritdoc IHookrRevenueToken
    bytes32 public constant CLAIM_ALL_TYPEHASH =
        keccak256("ClaimAll(address holder,address to,bytes32 nonce,uint256 deadline)");

    /// @notice A holder's checkpoint in one asset: the index it last settled at and its unpaid credit, scaled.
    struct Holder {
        uint256 index;
        uint256 creditScaled;
    }

    /// @inheritdoc IHookrRevenueToken
    uint32 public immutable streamSeconds;
    /// @dev How many of `_assets` are set, fixed at construction.
    uint256 internal immutable _assetCount;

    /// @dev The assets, `_assets[0 .. _assetCount - 1]`; the rest of the array is never written or read.
    Asset[MAX_ASSETS] internal _assets;
    /// @dev Asset index plus one, by currency; zero for a currency that is not an asset.
    mapping(Currency currency => uint256) internal _position;
    mapping(address account => mapping(uint256 asset => Holder)) internal _holders;

    /// @param name_ ERC-20 name.
    /// @param symbol_ ERC-20 symbol.
    /// @param assets The assets, 1 to `MAX_ASSETS`, distinct, native ETH (address zero) first.
    /// @param streamSeconds_ The release period, `MIN_STREAM_SECONDS` to `MAX_STREAM_SECONDS`.
    /// @param poolManager_ The PoolManager whose shares earn nothing; must have code.
    constructor(
        string memory name_,
        string memory symbol_,
        Currency[] memory assets,
        uint32 streamSeconds_,
        address poolManager_
    ) ERC20(name_, symbol_) EIP712(name_, "1") HookrBalanceHistory(poolManager_) {
        uint256 n = assets.length;
        if (
            n == 0 || n > MAX_ASSETS || !assets[0].isAddressZero() || streamSeconds_ < MIN_STREAM_SECONDS
                || streamSeconds_ > MAX_STREAM_SECONDS || poolManager_.code.length == 0
        ) revert InvalidConfig();
        streamSeconds = streamSeconds_;
        _assetCount = n;
        for (uint256 i; i < n; ++i) {
            Currency c = assets[i];
            address token = Currency.unwrap(c);
            if (_position[c] != 0 || (token != address(0) && token.code.length == 0)) revert InvalidAsset(c);
            _assets[i].currency = c;
            _position[c] = i + 1;
        }
    }

    // ------------------------------------------------------------------ assets

    /// @inheritdoc IHookrRevenueToken
    function assetCount() external view returns (uint256) {
        return _assetCount;
    }

    /// @inheritdoc IHookrRevenueToken
    function assetAt(uint256 asset) external view returns (Asset memory) {
        return _asset(asset);
    }

    /// @inheritdoc IHookrRevenueToken
    function assetOf(Currency currency) external view returns (uint256) {
        return _assetOf(currency);
    }

    /// @inheritdoc IHookrRevenueToken
    function isAsset(Currency currency) external view returns (bool) {
        return _position[currency] != 0;
    }

    /// @inheritdoc IHookrBalanceHistory
    /// @dev The drop host's rule (not the PoolManager, 0xdead or the drop box) plus this token itself, which never
    ///      holds shares (`_update` refuses it) and so never earns. Immutables only, as the history requires.
    function earns(address account) public view override(HookrDropHost, IHookrBalanceHistory) returns (bool) {
        return super.earns(account) && account != address(this);
    }

    /// @inheritdoc IHookrRevenueToken
    function surplus(uint256 asset) external view returns (uint256) {
        return _surplus(_asset(asset));
    }

    /// @inheritdoc IHookrRevenueToken
    function releasable(uint256 asset) external view returns (uint256 amount) {
        (, amount,) = _preview(_asset(asset));
    }

    // ------------------------------------------------------------------ holders

    /// @inheritdoc IHookrRevenueToken
    /// @dev Reads the index a release now would reach (`_preview`), so a view between two releases matches what a
    ///      claim in this block would pay.
    function claimable(address account, uint256 asset) public view returns (uint256) {
        (uint256 index,,) = _preview(_asset(asset));
        Holder storage h = _holders[account][asset];
        uint256 earning = earns(account) ? balanceOf(account) : 0;
        return (h.creditScaled + earning * (index - h.index)) / SCALE;
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev Releases the asset, settles the caller, pays the lesser of what it is owed and what the token holds, keeps
    ///      the rest as scaled credit. A native payout is exact or reverts. An ERC-20 payout checks only this side:
    ///      the transfer must take `amount` out of this token, or more only by what the surplus above the books
    ///      covered before it (`InexactTransfer` otherwise, so an asset that charges this token on every transfer
    ///      never eats into what the other holders are owed); what lands at `to` is the asset's business, so a
    ///      transfer tax falls on the claimer and never locks claims. A balance that fell below the books on its own
    ///      (a rebase, a slashing, an issuer burn) is not the ledger's doing and is not this transfer's: claims of
    ///      that asset pay `min(owed, held)` against what is left, in claim order.
    function claim(uint256 asset, address to) external nonReentrant returns (uint256 amount) {
        return _claim(msg.sender, asset, to);
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev One asset whose payout fails reverts the whole call; `claim` pays the other assets one by one.
    function claimAll(address to) external nonReentrant returns (uint256[] memory amounts) {
        return _claimAll(msg.sender, to);
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev The holder's authorization is used before the payout and the whole call reverts when nothing is paid, so
    ///      a signature that paid nothing is still good once something is due.
    function claimWithSig(
        address holder,
        uint256 asset,
        address to,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant returns (uint256 amount) {
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        _useAuthorization(
            holder, nonce, keccak256(abi.encode(CLAIM_TYPEHASH, holder, asset, to, nonce, deadline)), signature
        );
        return _claim(holder, asset, to);
    }

    /// @inheritdoc IHookrRevenueToken
    function claimAllWithSig(address holder, address to, bytes32 nonce, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        _useAuthorization(
            holder, nonce, keccak256(abi.encode(CLAIM_ALL_TYPEHASH, holder, to, nonce, deadline)), signature
        );
        return _claimAll(holder, to);
    }

    /// @inheritdoc IHookrRevenueToken
    function poke() external {
        _releaseAll();
    }

    // ------------------------------------------------------------------ internals

    /// @dev Asset `asset`, or `UnknownAsset` past the last one.
    function _asset(uint256 asset) internal view returns (Asset storage a) {
        if (asset >= _assetCount) revert UnknownAsset(asset);
        a = _assets[asset];
    }

    function _assetOf(Currency currency) internal view returns (uint256) {
        uint256 position = _position[currency];
        if (position == 0) revert InvalidAsset(currency);
        return position - 1;
    }

    /// @dev What `a` holds above its books, `received - paid`: arrivals not yet recognized.
    function _surplus(Asset storage a) internal view returns (uint256) {
        uint256 held = HookrSettlement.balance(a.currency, address(this));
        uint256 accounted = a.received - a.paid;
        return held > accounted ? held - accounted : 0;
    }

    /// @dev Recognizes `amount` of asset `asset`: counts it in `received`, adds it to the stream and sets the window
    ///      by weight, after releasing what was due until now. With `remaining` still pending and `left` seconds of
    ///      its window to go, the new window is `(remaining x left + amount x streamSeconds) / (remaining + amount)`,
    ///      so the new amount carries a full `streamSeconds` and what was pending keeps what it had: a real arrival
    ///      streams over `streamSeconds`, a dust arrival moves the window by nothing measurable, and no arrival of
    ///      any size can stretch the old stream to a fresh window or speed it up (the window is at least `left` and
    ///      at most `streamSeconds`). With nothing pending, or a window that has run out, the window is
    ///      `streamSeconds`. Never splits anything itself; `_release` does, over the shares that earn at each release.
    function _recognize(uint256 asset, uint256 amount, bytes32 sourceId) internal {
        Asset storage a = _assets[asset];
        uint256 received = a.received;
        if (amount == 0 || amount > MAX_RECEIVED - received) revert InvalidAmount(amount);
        _release(a, asset);
        uint256 remaining = a.pendingStream;
        uint256 window = streamSeconds;
        if (remaining != 0 && block.timestamp < a.streamEnd) {
            uint256 left = a.streamEnd - block.timestamp;
            window = (remaining * left + amount * streamSeconds) / (remaining + amount);
        }
        // received + amount <= MAX_RECEIVED was checked above, and remaining <= received, so both fit 128 bits.
        a.received = uint128(received + amount);
        a.pendingStream = uint128(remaining + amount);
        uint64 end = uint64(block.timestamp + window);
        a.streamEnd = end;
        a.lastRelease = uint64(block.timestamp);
        emit IncomeRecognized(asset, sourceId, amount, end);
    }

    /// @dev Releases asset `asset`'s due stream into its index over the current earning supply. When nothing is due
    ///      (nothing pending, no time passed, a rounding of zero, or no share earning) nothing is written, so the
    ///      elapsed time stays in the stream and releases later: the idle path is one storage read, and every
    ///      transfer runs this for every asset.
    function _release(Asset storage a, uint256 asset) internal {
        uint256 pending = a.pendingStream;
        if (pending == 0) return;
        uint256 amount = _due(a, pending);
        if (amount == 0) return;
        uint256 supply = earningSupply();
        if (supply == 0) return;
        (uint256 index, uint256 carry) = _split(a.index, a.carry, amount, supply);
        // amount <= pending: all of it from `streamEnd` on, a share of it before.
        unchecked {
            a.pendingStream = uint128(pending - amount);
        }
        a.index = index;
        a.carry = carry;
        uint64 end = a.streamEnd;
        a.lastRelease = block.timestamp < end ? uint64(block.timestamp) : end;
        emit IncomeReleased(asset, amount, index);
    }

    /// @dev Every asset's `_release`.
    function _releaseAll() internal {
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            _release(_assets[i], i);
        }
    }

    /// @dev (new index, amount released, new carry) if `a`'s stream were released at this timestamp. A zero amount or
    ///      a zero earning supply leaves everything unchanged.
    function _preview(Asset storage a) internal view returns (uint256 index, uint256 amount, uint256 carry) {
        index = a.index;
        carry = a.carry;
        uint256 pending = a.pendingStream;
        if (pending == 0) return (index, 0, carry);
        amount = _due(a, pending);
        if (amount == 0) return (index, 0, carry);
        uint256 supply = earningSupply();
        if (supply == 0) return (index, 0, carry);
        (index, carry) = _split(index, carry, amount, supply);
    }

    /// @dev What of `pending` is due now: all of it from `streamEnd` on, else `pending x (now - last) / (end - last)`.
    function _due(Asset storage a, uint256 pending) private view returns (uint256) {
        uint256 end = a.streamEnd;
        uint256 last = a.lastRelease;
        if (block.timestamp >= end || end <= last) return pending;
        if (block.timestamp <= last) return 0;
        // last < now < end here, so neither difference underflows; pending < 2^128 and the time < 2^64 keep the
        // product under 2^192.
        unchecked {
            return pending * (block.timestamp - last) / (end - last);
        }
    }

    /// @dev `amount` split over `supply` on top of `index`, with the remainder of the last split carried in: the new
    ///      index and the new carry. `amount x SCALE + carry` fits: amount < 2^128, SCALE < 2^120, carry < supply
    ///      <= 2^128; the index stays below 2^256 by the contract notes; the new carry is a remainder.
    function _split(uint256 index, uint256 carry, uint256 amount, uint256 supply)
        private
        pure
        returns (uint256, uint256)
    {
        unchecked {
            uint256 total = amount * SCALE + carry;
            uint256 delta = total / supply;
            return (index + delta, total - delta * supply);
        }
    }

    /// @dev Settles `account`'s credit in asset `asset` at `index`, the asset's current index. A non-earning account
    ///      accrues nothing.
    function _settle(address account, uint256 asset, uint256 index) internal {
        Holder storage h = _holders[account][asset];
        uint256 last = h.index;
        if (index == last) return;
        uint256 balance = earns(account) ? balanceOf(account) : 0;
        // The index only grows and `last` is an earlier value of it; the credit stays below received x SCALE.
        if (balance != 0) {
            unchecked {
                h.creditScaled += balance * (index - last);
            }
        }
        h.index = index;
    }

    /// @dev `holder`'s claim in asset `asset`, paid to `to` or `NothingToClaim`.
    function _claim(address holder, uint256 asset, address to) private returns (uint256 amount) {
        _checkRecipient(to);
        amount = _pay(holder, _asset(asset), asset, to);
        if (amount == 0) revert NothingToClaim();
    }

    /// @dev `holder`'s claim in every asset, paid to `to`; `NothingToClaim` when no asset paid.
    function _claimAll(address holder, address to) private returns (uint256[] memory amounts) {
        _checkRecipient(to);
        uint256 n = _assetCount;
        amounts = new uint256[](n);
        bool any;
        for (uint256 i; i < n; ++i) {
            amounts[i] = _pay(holder, _assets[i], i, to);
            any = any || amounts[i] != 0;
        }
        if (!any) revert NothingToClaim();
    }

    /// @dev Pays `holder`'s claim in asset `asset` to `to`: releases, settles, pays `min(owed, held)`, keeps the rest
    ///      as scaled credit, bumps `paid`. Returns zero (and writes nothing) when nothing can be paid.
    function _pay(address holder, Asset storage a, uint256 asset, address to) private returns (uint256 amount) {
        _release(a, asset);
        _settle(holder, asset, a.index);
        Holder storage h = _holders[holder][asset];
        uint256 credit = h.creditScaled;
        uint256 owed = credit / SCALE;
        if (owed == 0) return 0;
        Currency c = a.currency;
        uint256 held = HookrSettlement.balance(c, address(this));
        amount = owed < held ? owed : held;
        if (amount == 0) return 0;
        // amount <= owed = credit / SCALE, so amount x SCALE <= credit.
        unchecked {
            h.creditScaled = credit - amount * SCALE;
        }
        uint256 accounted = a.received - a.paid;
        // paid + amount <= received (contract notes), so it fits 128 bits.
        a.paid += uint128(amount);
        if (c.isAddressZero()) {
            HookrSettlement.send(c, to, amount);
        } else {
            IERC20 token = IERC20(Currency.unwrap(c));
            token.safeTransfer(to, amount);
            uint256 left = token.balanceOf(address(this));
            uint256 spare = held > accounted ? held - accounted : 0;
            if (left > held || held - left < amount || held - left - amount > spare) revert InexactTransfer();
        }
        emit IncomeClaimed(holder, asset, to, amount);
    }

    /// @dev A payout recipient: anyone but zero, this token (whose shares would earn unclaimable income) and its drop
    ///      box (which pays out drops only, so a payout sent there would sit for good).
    function _checkRecipient(address to) private view {
        if (to == address(0) || to == address(this) || to == dropBox) revert InvalidRecipient(to);
    }

    /// @dev Releases every asset's due stream and settles both sides in every asset before balances move: the sender
    ///      keeps everything released while it held, the receiver earns only from now. Then the history moves the
    ///      balances and writes both sides' block checkpoints (HookrBalanceHistory._update), so a drop landing later
    ///      reads the balances as they stood at the end of the block before it. No external call. Shares sent to this
    ///      token would earn unclaimable income and are refused; shares may enter the PoolManager, 0xdead or the drop
    ///      box, which earn nothing.
    function _update(address from, address to, uint256 value) internal override(ERC20, HookrBalanceHistory) {
        if (to == address(this)) revert InvalidRecipient(to);
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            Asset storage a = _assets[i];
            _release(a, i);
            uint256 index = a.index;
            if (from != address(0)) _settle(from, i, index);
            if (to != address(0)) _settle(to, i, index);
        }
        super._update(from, to, value);
    }
}
