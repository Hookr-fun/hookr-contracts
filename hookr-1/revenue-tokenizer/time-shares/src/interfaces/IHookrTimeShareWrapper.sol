// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IHookrTimeShares} from "./IHookrTimeShares.sol";

/// @title Hookr time share wrapper
/// @notice The ERC-20 form of one day's time shares, so the day can trade in a pool. Each wrapped token is one unit
///         of the day plus a pro-rata share of the cash those units have earned: the day's income raises what a
///         wrapped token redeems for instead of being paid to whoever holds it, so a pool (an omnibus holder) can
///         list it without stranding anything. Wrap before the day starts; trade and unwrap any time.
/// @dev Deposits are refused from the day's first second on, so every wrapped token entered before any of the day's
///      income existed and all of them are equal: a redemption pays units one for one plus each asset's cash held
///      times the redeemed share, after claiming what the time shares owe the wrapper. `redeem` refuses to run
///      while the time shares still owe the wrapper an asset after that claim, or while an asset's balance cannot
///      be read, because a redemption then would leave the redeemer's part of it to whoever redeems later;
///      `redeemShort` is the same redemption with that accepted. Not a promise of anything beyond what the units
///      earn. A Hookr pool that lists a wrapper must bind with Auto Burn off: wrapped tokens paid to 0xdead can
///      never be redeemed and the units and cash behind them are lost to everyone.
interface IHookrTimeShareWrapper is IERC20Metadata {
    /// @notice A construction argument is out of bounds: time shares without code, or a day past `FOREVER`.
    error InvalidConfig();
    /// @notice A zero deposit or redemption.
    error InvalidAmount(uint256 amount);
    /// @notice `to` cannot take wrapped tokens, units or a payout: the zero address or this wrapper.
    error InvalidRecipient(address to);
    /// @notice Day `day` has started; wrapping is over.
    error DayStarted(uint256 day);
    /// @notice A unit or asset transfer moved other than the amount asked.
    error InexactTransfer();
    /// @notice ETH was sent from anything but the time shares.
    error NativeNotAccepted();
    /// @notice A native payout was refused by its recipient.
    error NativeTransferFailed();
    /// @notice The time shares still owe the wrapper asset `asset` after the collection, or its balance cannot be
    ///         read: a `redeem` now would forfeit the redeemer's part of it. `redeemShort` accepts that.
    error StillOwed(uint256 asset);
    /// @notice Asset `asset`'s balance of this wrapper could not be read.
    error AssetUnreadable(uint256 asset);

    /// @notice `payer` wrapped `amount` units of the day for `to`.
    event Deposited(address indexed payer, address indexed to, uint256 amount);
    /// @notice `owner` unwrapped `amount` wrapped tokens to `to`: `amount` units plus `cash` per asset.
    event Redeemed(address indexed owner, address indexed to, uint256 amount, uint256[] cash);
    /// @notice `amount` of asset `asset` was claimed from the time shares into the basket.
    event Collected(uint256 indexed asset, uint256 amount);

    /// @notice The time shares this wrapper holds units of.
    function shares() external view returns (IHookrTimeShares);
    /// @notice The day wrapped here.
    function day() external view returns (uint256);
    /// @notice Number of assets, the revenue token's.
    function assetCount() external view returns (uint256);
    /// @notice Cash of asset `asset` behind the wrapped tokens: what is held plus what the time shares owe; reverts
    ///         `AssetUnreadable` when the asset's `balanceOf` cannot be read.
    function basket(uint256 asset) external view returns (uint256);
    /// @notice Each asset's cash a `redeem` of `amount` would pay now, next to `amount` units: the redeemed share
    ///         of each basket. A `redeemShort` pays the share of what is held instead.
    function previewRedeem(uint256 amount) external view returns (uint256[] memory cash);

    /// @notice Wraps `amount` units of the day (approve this wrapper on the time shares first, or make it an
    ///         operator) into `amount` wrapped tokens for `to`. Refused once the day has started.
    function deposit(uint256 amount, address to) external;
    /// @notice Burns `amount` wrapped tokens for `amount` units of the day plus each asset's cash pro rata, to `to`,
    ///         after claiming what the time shares owe the wrapper. Reverts `StillOwed` when an asset is still owed
    ///         after that claim or cannot be read, so no redemption moves one holder's income to another.
    function redeem(uint256 amount, address to) external returns (uint256[] memory cash);
    /// @notice `redeem` that goes through when an asset is still owed or cannot be read: it pays the redeemed share
    ///         of what is held and nothing of what is still owed, whose redeemed part stays with the wrapper for the
    ///         holders that redeem later. For a holder that wants its units out now whatever the asset does.
    function redeemShort(uint256 amount, address to) external returns (uint256[] memory cash);
    /// @notice Claims what the time shares owe the wrapper in every asset into the basket. Anyone may call; a
    ///         redemption does it first.
    function collect() external;
}
