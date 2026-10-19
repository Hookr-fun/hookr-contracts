// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTimeSharesGuard} from "./base/HookrTimeSharesGuard.sol";
import {HookrDays} from "./libraries/HookrDays.sol";
import {IHookrTimeShares} from "./interfaces/IHookrTimeShares.sol";
import {IHookrTimeShareWrapper} from "./interfaces/IHookrTimeShareWrapper.sol";

/// @title Hookr time share wrapper
/// @notice The ERC-20 form of one day's time shares: one wrapped token is one unit of the day plus a pro-rata share
///         of the cash the wrapper's units have earned. Wrap before the day starts, trade any time, unwrap any time
///         for the units and the cash.
/// @dev Units are held one for one: the wrapped supply equals the units taken in through `deposit`. Income reaches
///      the wrapper as the time shares' claims (`collect`, run before every redemption), and a redemption pays each
///      asset's cash held times the redeemed share, rounded down, so recognized income always follows redeemed
///      units. Because the cash is split by the supply at the redemption, a redemption while the time shares still
///      owe an asset would hand the redeemer's part of it to the later redeemers; `redeem` refuses that
///      (`StillOwed`) and `redeemShort` does it on purpose. The name, symbol and decimals come from the revenue
///      token, so one creation code serves every day and the wrapper's address follows from the time shares and
///      the day (HookrTimeShareWrapperFactory).
contract HookrTimeShareWrapper is ERC20, HookrTimeSharesGuard, IHookrTimeShareWrapper {
    using SafeERC20 for IERC20;

    /// @dev Gas given to an asset's `balanceOf`, as in the time shares.
    uint256 private constant BALANCE_READ_GAS = 200_000;

    /// @inheritdoc IHookrTimeShareWrapper
    IHookrTimeShares public immutable shares;
    /// @inheritdoc IHookrTimeShareWrapper
    uint256 public immutable day;
    uint256 private immutable _assetCount;
    uint8 private immutable _decimals;
    Currency private immutable _currency0;
    Currency private immutable _currency1;
    Currency private immutable _currency2;
    Currency private immutable _currency3;

    /// @param shares_ The time shares whose units of `day_` this wraps.
    /// @param day_ The day.
    constructor(IHookrTimeShares shares_, uint256 day_) ERC20("", "") {
        if (address(shares_).code.length == 0 || day_ > shares_.FOREVER()) revert InvalidConfig();
        shares = shares_;
        day = day_;
        uint256 n = shares_.assetCount();
        _assetCount = n;
        _decimals = IERC20Metadata(address(shares_.token())).decimals();
        _currency0 = shares_.currencyAt(0);
        _currency1 = n > 1 ? shares_.currencyAt(1) : Currency.wrap(address(0));
        _currency2 = n > 2 ? shares_.currencyAt(2) : Currency.wrap(address(0));
        _currency3 = n > 3 ? shares_.currencyAt(3) : Currency.wrap(address(0));
    }

    /// @notice Accepts native income from the time shares only.
    receive() external payable {
        if (msg.sender != address(shares)) revert NativeNotAccepted();
    }

    // ------------------------------------------------------------------ metadata

    /// @inheritdoc IERC20Metadata
    function name() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return string.concat(IERC20Metadata(address(shares.token())).name(), " day ", Strings.toString(day));
    }

    /// @inheritdoc IERC20Metadata
    function symbol() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return string.concat("ts", IERC20Metadata(address(shares.token())).symbol(), "-", Strings.toString(day));
    }

    /// @inheritdoc IERC20Metadata
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return _decimals;
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc IHookrTimeShareWrapper
    function assetCount() external view returns (uint256) {
        return _assetCount;
    }

    /// @inheritdoc IHookrTimeShareWrapper
    function basket(uint256 asset) public view returns (uint256) {
        (uint256 amount, bool ok) = _held(_currency(asset));
        if (!ok) revert AssetUnreadable(asset);
        return amount + shares.claimable(address(this), day, asset);
    }

    /// @inheritdoc IHookrTimeShareWrapper
    function previewRedeem(uint256 amount) external view returns (uint256[] memory cash) {
        uint256 n = _assetCount;
        uint256 supply = totalSupply();
        cash = new uint256[](n);
        if (supply == 0) return cash;
        for (uint256 i; i < n; ++i) {
            cash[i] = basket(i) * amount / supply;
        }
    }

    // ------------------------------------------------------------------ actions

    /// @inheritdoc IHookrTimeShareWrapper
    function deposit(uint256 amount, address to) external nonReentrant {
        if (amount == 0) revert InvalidAmount(amount);
        _checkRecipient(to);
        if (block.timestamp >= HookrDays.startOf(day)) revert DayStarted(day);
        uint256 before = shares.balanceOf(address(this), day);
        if (
            !shares.transferFrom(msg.sender, address(this), day, amount)
                || shares.balanceOf(address(this), day) != before + amount
        ) revert InexactTransfer();
        _mint(to, amount);
        emit Deposited(msg.sender, to, amount);
    }

    /// @inheritdoc IHookrTimeShareWrapper
    function redeem(uint256 amount, address to) external nonReentrant returns (uint256[] memory cash) {
        return _redeem(amount, to, false);
    }

    /// @inheritdoc IHookrTimeShareWrapper
    function redeemShort(uint256 amount, address to) external nonReentrant returns (uint256[] memory cash) {
        return _redeem(amount, to, true);
    }

    /// @inheritdoc IHookrTimeShareWrapper
    function collect() external nonReentrant {
        _collect(false);
    }

    // ------------------------------------------------------------------ internals

    function _currency(uint256 asset) private view returns (Currency) {
        if (asset == 0) return _currency0;
        if (asset == 1) return _currency1;
        if (asset == 2) return _currency2;
        return _currency3;
    }

    /// @dev This wrapper's balance of `c`, and whether it could be read, the time shares' way: native from the
    ///      balance, an ERC-20 through a bounded `balanceOf` whose answer must be at least a word.
    function _held(Currency c) private view returns (uint256 amount, bool ok) {
        if (c.isAddressZero()) return (address(this).balance, true);
        (bool success, bytes memory data) =
            Currency.unwrap(c).staticcall{gas: BALANCE_READ_GAS}(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!success || data.length < 32) return (0, false);
        return (abi.decode(data, (uint256)), true);
    }

    function _checkRecipient(address to) private view {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
    }

    /// @dev Collects first, so every asset the units earned up to now is in the basket; then the share of each
    ///      asset's cash is fixed, the wrapped tokens burn, the units move, the cash moves. Unless `acceptShort`, an asset
    ///      still owed after the collection or unreadable is `StillOwed`; with it, such an asset pays its held share
    ///      (zero when unreadable) and the rest stays here.
    function _redeem(uint256 amount, address to, bool acceptShort) private returns (uint256[] memory cash) {
        if (amount == 0) revert InvalidAmount(amount);
        _checkRecipient(to);
        uint256 supply = totalSupply();
        _collect(!acceptShort);
        uint256 n = _assetCount;
        cash = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (uint256 heldNow, bool ok) = _held(_currency(i));
            if (!ok) {
                if (!acceptShort) revert StillOwed(i);
                continue;
            }
            cash[i] = heldNow * amount / supply;
        }
        _burn(msg.sender, amount);
        uint256 before = shares.balanceOf(to, day);
        if (!shares.transfer(to, day, amount) || shares.balanceOf(to, day) != before + amount) {
            revert InexactTransfer();
        }
        for (uint256 i; i < n; ++i) {
            if (cash[i] != 0) _send(_currency(i), to, cash[i]);
        }
        emit Redeemed(msg.sender, to, amount, cash);
    }

    /// @dev Claims every asset the time shares owe the wrapper, each on its own; a claim that reverts leaves that
    ///      asset owed for a later collection and stops nothing else. When `strict`, an asset still owed after its
    ///      claim (the claim reverted, or paid less than owed) is `StillOwed`.
    function _collect(bool strict) private {
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            if (shares.claimable(address(this), day, i) == 0) continue;
            try shares.claim(day, i, address(this)) returns (uint256 got) {
                emit Collected(i, got);
            } catch {}
            if (strict && shares.claimable(address(this), day, i) != 0) revert StillOwed(i);
        }
    }

    /// @dev Delivers `amount` of `c` to `to`: native by call, an ERC-20 by a transfer that must take exactly
    ///      `amount` out of this wrapper.
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

    /// @dev Wrapped tokens sent to the wrapper itself could never be redeemed.
    function _update(address from, address to, uint256 value) internal override {
        if (to == address(this)) revert InvalidRecipient(to);
        super._update(from, to, value);
    }
}
