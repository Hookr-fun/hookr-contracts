// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrForward} from "../libraries/HookrForward.sol";
import {IHookrDropBox} from "../interfaces/IHookrDropBox.sol";
import {IHookrDropHost} from "../interfaces/IHookrDropHost.sol";
import {IHookrForwarding} from "../interfaces/IHookrForwarding.sol";
import {IHookrRevenueDoor} from "../interfaces/IHookrRevenueDoor.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";

/// @title Hookr forwarding, part of the HookRevenue Tokenizer
/// @notice The part every first-party door shares: its revenue token, the pull gate, the reentrancy lock, and the
///         capped forward of each currency to the token, into the token's drop box or to 0xdead
///         (IHookrForwarding).
/// @dev The token's asset list is read when a forward runs (`isAsset`), never cached: the token lists more assets
///      after mint, and a currency listed later is forwarded to the token from then on. Native ETH is always the
///      token's asset 0. The token's drop box, its leg collector and this door's leg (`legOf`) are read when a
///      currency the token does not list is delivered, so a door can exist before its token.
///
///      Hookr's leg on a currency the token lists is the token's to measure (its sync reads the balance around this
///      door's pull). On a currency the token does not list the sync sees nothing, so the door takes the leg itself
///      as it delivers: `legOf(this)` basis points to the token's leg collector, the rest into the box. A leg
///      payment that fails stays in the door and goes on with its next delivery, so it ends with the holders. The
///      leg is never taken twice: a listed currency goes to the token whole, an unlisted one never reaches the
///      token. Known limit (kept, not re-budgeted): the leg transfer gets `LEG_GAS` (100,000). When the unlisted
///      currency is a revenue token of another tokenizer or release whose `earns` does not leave our collector out
///      and which lists two or more assets with released income, the transfer must settle the collector in every
///      one of them, needs more than that and fails, so the leg stays here and the next pulls pass it to the
///      holders: Hookr's leg on that currency is not collected (measured at 2, 4 and 8 assets; one asset is paid).
///      Raising `LEG_GAS` to the token's 900,000 would shift every door's `FORWARD_ITEM_GAS` and stipend.
///
///      An unlisted currency is transferred to the box and recognized by `IHookrDropBox.dropStray`: one immediate
///      previous-block snapshot drop for a release period under an hour (zero included), or the box's timed slices
///      for a longer one.
///      The caller can choose collection timing; the prior-block cutoff excludes new same-block holders. The box
///      has its own lock, so delivery works inside the token's sync.
abstract contract HookrForwarding is IHookrRevenueDoor, IHookrForwarding {
    /// @inheritdoc IHookrForwarding
    address public constant DEAD = address(0xdead);
    /// @inheritdoc IHookrForwarding
    uint256 public constant FORWARD_GAS = 1_500_000;
    /// @inheritdoc IHookrForwarding
    uint256 public constant SEND_GAS = 50_000;
    /// @inheritdoc IHookrForwarding
    uint256 public constant BALANCE_GAS = 50_000;
    /// @inheritdoc IHookrForwarding
    uint256 public constant DROP_GAS = 400_000;
    /// @inheritdoc IHookrForwarding
    uint256 public constant LEG_GAS = 100_000;
    /// @inheritdoc IHookrForwarding
    /// @dev The costlier branch, an unlisted currency: five reads (the door's balance, the listing, the drop box, the
    ///      leg, the leg collector), the transfer into the box, the box's `dropStray` and the leg payment, each given
    ///      64/63 of its cap so the cap is really available (2,285,715 together), and the door's own work around
    ///      them.
    uint256 public constant FORWARD_ITEM_GAS = 2_340_000;
    /// @dev The largest stipend a revenue token gives one door (IHookrRevenueToken.MAX_DOOR_GAS); a door's own
    ///      `pullGas` answer is clipped to it.
    uint256 internal constant MAX_STIPEND = 12_000_000;

    /// @inheritdoc IHookrRevenueDoor
    address public immutable revenueToken;
    bool private transient _busy;

    modifier nonReentrant() {
        if (_busy) revert Reentered();
        _busy = true;
        _;
        _busy = false;
    }

    /// @dev `pull` takes calls from the revenue token alone, so Hookr's leg is measured on every pull.
    modifier onlyRevenueToken() {
        if (msg.sender != revenueToken) revert OnlyRevenueToken(msg.sender);
        _;
    }

    /// @param revenueToken_ The revenue token every pull pays; nonzero. It may not exist yet.
    constructor(address revenueToken_) {
        if (revenueToken_ == address(0)) revert RevenueTokenZero();
        revenueToken = revenueToken_;
    }

    /// @inheritdoc IHookrForwarding
    function dropStray(address asset) external nonReentrant returns (uint256 amount) {
        if (asset == address(0) || _isOwnAsset(asset)) revert OwnAsset(asset);
        bool read;
        (read, amount) = HookrForward.balanceOf(asset, address(this), BALANCE_GAS);
        if (!read || amount == 0) revert NothingToForward(asset);
        if (asset == revenueToken) {
            if (!HookrForward.transfer(asset, DEAD, amount, FORWARD_GAS)) revert ForwardRefused(asset);
            emit Retired(amount);
        } else if (!_stream(asset, amount)) {
            revert ForwardRefused(asset);
        }
    }

    /// @dev Whether `asset` is one of the currencies this door's own pull forwards; `dropStray` refuses those.
    function _isOwnAsset(address asset) internal view virtual returns (bool);

    /// @dev Forwards the door's whole balance of `asset` (address zero is native ETH). A balance that cannot be read
    ///      is reported (`ForwardFailed` with zero) and skipped. Never reverts.
    function _forwardHeld(address asset) internal {
        uint256 amount;
        if (asset == address(0)) {
            amount = address(this).balance;
        } else {
            bool read;
            (read, amount) = HookrForward.balanceOf(asset, address(this), BALANCE_GAS);
            if (!read) {
                emit ForwardFailed(Currency.wrap(asset), 0);
                return;
            }
        }
        if (amount != 0) _forward(asset, amount);
    }

    /// @dev One forward of `amount` of `asset`: native ETH to the token with `SEND_GAS`; the revenue token to 0xdead;
    ///      an ERC-20 the token lists now to the token; anything else, less Hookr's leg, into the token's drop box
    ///      (`_stream`). Never reverts.
    function _forward(address asset, uint256 amount) internal {
        Currency currency = Currency.wrap(asset);
        if (asset == address(0)) {
            if (HookrForward.send(revenueToken, amount, SEND_GAS)) emit Forwarded(currency, amount);
            else emit ForwardFailed(currency, amount);
            return;
        }
        if (asset == revenueToken) {
            if (HookrForward.transfer(asset, DEAD, amount, FORWARD_GAS)) emit Retired(amount);
            else emit ForwardFailed(currency, amount);
            return;
        }
        (bool read, uint256 listed) =
            HookrForward.read(revenueToken, abi.encodeCall(IHookrRevenueToken.isAsset, (currency)), BALANCE_GAS);
        if (!read) {
            emit ForwardFailed(currency, amount);
        } else if (listed == 0) {
            _stream(asset, amount);
        } else if (HookrForward.transfer(asset, revenueToken, amount, FORWARD_GAS)) {
            emit Forwarded(currency, amount);
        } else {
            emit ForwardFailed(currency, amount);
        }
    }

    /// @dev A source's `pendingIncome` from the first `n` of `list` (address zero is native ETH) and what each is
    ///      owed outside the door: the owed amount plus what the door holds, for native ETH and every ERC-20 the
    ///      token lists now; an ERC-20 the token does not list, or whose listing cannot be read, is left out. A
    ///      balance that cannot be read counts as zero.
    function _income(address[3] memory list, uint256[3] memory owed, uint256 n)
        internal
        view
        returns (Currency[] memory currencies, uint256[] memory amounts)
    {
        currencies = new Currency[](n);
        amounts = new uint256[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            address asset = list[i];
            uint256 held;
            if (asset == address(0)) {
                held = address(this).balance;
            } else {
                (bool read, uint256 listed) = HookrForward.read(
                    revenueToken, abi.encodeCall(IHookrRevenueToken.isAsset, (Currency.wrap(asset))), BALANCE_GAS
                );
                if (!read || listed == 0) continue;
                (, held) = HookrForward.balanceOf(asset, address(this), BALANCE_GAS);
            }
            currencies[k] = Currency.wrap(asset);
            amounts[k++] = owed[i] + held;
        }
        assembly ("memory-safe") {
            mstore(currencies, k)
            mstore(amounts, k)
        }
    }

    /// @dev Delivers `amount` of `asset`, a currency the token does not list: all of it less Hookr's leg (`_leg`) by
    ///      `transfer` into the token's drop box and the box's `dropStray` with `DROP_GAS`, which records it as one
    ///      immediate drop at a release period under an hour and adds it to the asset's stray stream otherwise; then
    ///      the leg to the token's leg collector by `transfer` with `LEG_GAS`. No box yet,
    ///      or a transfer into it the asset refuses, leaves everything here for a later pull (`StrayStreamFailed`)
    ///      and takes no leg. A `dropStray` the box refuses leaves the amount in the box, where the next `dropStray`
    ///      of the asset by anyone recognizes it. A leg payment that fails leaves the leg here, and the next pull
    ///      delivers it like anything else. Never reverts.
    function _stream(address asset, uint256 amount) internal returns (bool ok) {
        (bool found, uint256 word) =
            HookrForward.read(revenueToken, abi.encodeCall(IHookrDropHost.dropBox, ()), BALANCE_GAS);
        address box = address(uint160(word));
        if (!found || box.code.length == 0) {
            emit StrayStreamFailed(asset, amount);
            return false;
        }
        uint256 leg = _leg(amount);
        uint256 rest = amount - leg;
        if (!HookrForward.transfer(asset, box, rest, FORWARD_GAS)) {
            emit StrayStreamFailed(asset, rest);
            return false;
        }
        try IHookrDropBox(box).dropStray{gas: DROP_GAS}(asset) returns (uint256) {} catch {}
        // The transfer into the box, not its recognition: a refused `dropStray` leaves `rest` in the box for the next.
        emit StrayStreamed(asset, rest);
        if (leg == 0) return true;
        (found, word) =
            HookrForward.read(revenueToken, abi.encodeCall(IHookrRevenueToken.legCollector, ()), BALANCE_GAS);
        address collector = address(uint160(word));
        if (found && collector != address(0) && HookrForward.transfer(asset, collector, leg, LEG_GAS)) {
            emit LegPaid(asset, leg);
        }
        return true;
    }

    /// @dev Hookr's leg of `amount`: `legOf(this)` basis points on the token, the floor of `amount x bps / 10,000`
    ///      without an overflow; zero when the read fails or answers more than 10,000.
    function _leg(uint256 amount) private view returns (uint256) {
        (bool read, uint256 bps) =
            HookrForward.read(revenueToken, abi.encodeCall(IHookrRevenueToken.legOf, (address(this))), BALANCE_GAS);
        if (!read || bps > 10_000) return 0;
        return amount / 10_000 * bps + amount % 10_000 * bps / 10_000;
    }
}
