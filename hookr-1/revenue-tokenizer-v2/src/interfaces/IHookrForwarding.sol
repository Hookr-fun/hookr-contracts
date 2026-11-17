// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrForwardEvents} from "./IHookrForwardEvents.sol";

/// @title Hookr forwarding, part of the HookRevenue Tokenizer
/// @notice How every first-party door moves what it holds on, each currency on its own capped attempt: native ETH
///         into the revenue token's empty `receive`; an ERC-20 the token lists now (`isAsset`, read when the forward
///         runs, since the token's list grows after mint) by `transfer` to the token, whose sync takes Hookr's leg
///         of it; any other ERC-20 by `transfer` into the token's drop box less Hookr's leg, then
///         `IHookrDropBox.dropStray`, which books it for the holders (one immediate previous-block snapshot drop at a
///         release period of zero or under an hour, the box's timed slices at a longer one), then the leg (`legOf`
///         this door) to the token's `legCollector`; the revenue token itself to 0xdead. A forward that fails leaves the currency in the door for a later pull
///         and never stops the others.
/// @dev Every read is a staticcall with `BALANCE_GAS` that must answer one word, and every transfer copies one word
///      of its answer at most (HookrForward), so a hostile currency costs a pull its caps and nothing more.
///
///      Known limit: while a door holds another revenue token B between collecting it and forwarding it,
///      the door earns B's income and B's drops, and no door has a call that claims them, so they stay owed to the
///      door for good. The windows: a position door's `pullSome` (anyone), `release` and `releaseSome`, which collect
///      into the door without forwarding; the forwarder's `release` and `flushClaims`; a pull whose forward page ran
///      out of gas; a forward that failed (`ForwardFailed`); and the door-side leg on an unlisted B that stays here
///      when its `LEG_GAS` transfer fails, which keeps about 5% of every delivery of a multi-asset B here for as long
///      as fees flow. When B lists this door's token, the door's share of B's income in that token stays credited in
///      B, so those shares earn this token's income for B's holders. Forwarding B outside the token's pull would skip
///      Hookr's leg on a listed B, which the token measures around the pull, so the doors do not.
///
///      Shares of the revenue token itself reach a door only when the door held them before it was added (the token
///      refuses transfers to its doors from then on). `dropStray` (anyone) moves them to 0xdead; a forwarder whose
///      currencies include the token (a market's, or a member pool pairing it) moves them on its next pull instead
///      and refuses them in `dropStray` as its own currency. No other door's pull touches them.
interface IHookrForwarding is IHookrForwardEvents {
    /// @notice The revenue token address is zero.
    error RevenueTokenZero();
    /// @notice The call re-entered the door.
    error Reentered();
    /// @notice `asset` is native ETH or one of the currencies the door's own pull forwards.
    error OwnAsset(address asset);
    /// @notice The door holds nothing of `asset`, or its balance cannot be read.
    error NothingToForward(address asset);
    /// @notice The drop box refused `asset`, or `asset` refused the move.
    error ForwardRefused(address asset);

    /// @notice The address the revenue token itself goes to; its shares earn nothing.
    function DEAD() external view returns (address);
    /// @notice Gas one ERC-20 `transfer` of a forward gets: 1,500,000. The costliest currency a door can hold is a
    ///         revenue token of this tokenizer listing eight assets, moved while each of the eight has its first
    ///         income streaming, so the transfer releases all eight streams and writes a first credit for both sides
    ///         in every asset: 1,066,045 measured cold. With every stream already released it takes 532,064.
    function FORWARD_GAS() external view returns (uint256);
    /// @notice Gas the native send into the revenue token's empty `receive` gets: 50,000.
    function SEND_GAS() external view returns (uint256);
    /// @notice Gas each read gets (a balance, the token's `isAsset`, the token's `dropBox`): 50,000.
    function BALANCE_GAS() external view returns (uint256);
    /// @notice Gas the drop box's `dropStray` gets: 400,000.
    function DROP_GAS() external view returns (uint256);
    /// @notice Gas Hookr's leg payment of an unlisted currency gets: 100,000. A revenue token from another tokenizer
    ///         that lists two or more assets with released income needs more for that transfer, which must settle the
    ///         collector in every asset: the payment fails, the leg stays in the door and later pulls pass it on to
    ///         the holders.
    function LEG_GAS() external view returns (uint256);
    /// @notice The most gas one currency's forward can take, every cap included: 2,340,000. A paged pull keeps this
    ///         much per currency it has still to forward, up to its page, before it collects more.
    function FORWARD_ITEM_GAS() external view returns (uint256);

    /// @notice Moves the door's whole balance of `asset`, an ERC-20 that is none of the door's own currencies, less
    ///         Hookr's leg, into the revenue token's drop box (the revenue token itself to 0xdead): an
    ///         airdrop to the door, a token sent here by mistake. Anyone may call. Native ETH and the door's own
    ///         currencies are `OwnAsset` (only the token's pull moves those); an empty or unreadable balance is
    ///         `NothingToForward`; a refusal is `ForwardRefused`. A release period of zero or under an hour records
    ///         an immediate previous-block snapshot drop; a longer one joins the box's timed stray stream.
    /// @return amount What moved.
    function dropStray(address asset) external returns (uint256 amount);
}
