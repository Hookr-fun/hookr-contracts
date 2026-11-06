// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRevenueDoor} from "./IHookrRevenueDoor.sol";
import {IHookrForwardEvents} from "./IHookrForwardEvents.sol";

/// @title Hookr revenue source, part of the HookRevenue Tokenizer
/// @notice What any contract answers to be a source of a revenue token: a door of kind `SOURCE` that the token's
///         sync pulls (IHookrRevenueDoor: `revenueToken`, `ends` and `pull`), plus what the tokenizer and the app read
///         to admit and show it. A source only pushes what it collected into the revenue token, and hands the token's
///         drop box what the token does not list; the token never pays a source and never calls it with more
///         than the gas stipend it declared. The Pons and Doppler adapters implement it; any other platform plugs in
///         with a new adapter and no change to the token or the tokenizer.
/// @dev The tokenizer adds a source at mint or later: it checks `revenueToken()` names the token, `bound()` is true
///      and `pullGas()` is within its bounds, and fixes Hookr's leg on it. The sync calls `pull()` as a raw call with
///      that stipend and copies no return data, so a source that reverts, runs out of gas or answers with garbage
///      fails only itself. A first-party source takes `pull` from its revenue token alone (`OnlyRevenueToken`) and
///      pays only a token that has it as a door (`isDoor`), so the leg is never skipped; an outside source is outside
///      code, and what it pushes outside a sync reaches holders without the leg, as any push does. A source whose
///      `ends()` is `REVOCABLE` with a date is refused (the revocation must lapse or be cancelled first). `pull()`
///      must never revert on an empty collection; anything the token does not list goes in through the token's drop
///      box (`transfer` to the box, then `IHookrDropBox.dropStray`), less Hookr's leg (`legOf` the source), which is
///      paid to the token's `legCollector` after that delivery. A release period strictly under an hour (3,600 s, zero
///      included) records one immediate previous-block snapshot drop; an hour or more uses timed slices. Collection
///      timing remains caller-controlled. Delivery is
///      never through the token's `dropStray`, which runs under the lock the sync holds while it pulls. The sum of
///      every capped step must stay below `pullGas()`, or a step that burns its cap reverts the whole pull every
///      time.
interface IHookrRevenueSource is IHookrRevenueDoor, IHookrForwardEvents {
    /// @notice The revenue token has no code yet: the source does nothing until the token exists.
    error NotLive();

    /// @notice Every currency a pull may deliver to the token (address zero is native ETH). The tokenizer lists
    ///         those it can when the call that adds the source sets `StreamParams.listAssets`, while there is room;
    ///         anything the token does not list reaches holders through the drop box's stray path.
    /// @return The currencies a pull may deliver.
    function assets() external view returns (Currency[] memory);
    /// @notice The kind of stream, as a constant id (`keccak256("pons.v2")`, ...).
    /// @return The stream kind id.
    function sourceKind() external view returns (bytes32);
    /// @notice The kind of stream, in words, for the app.
    /// @return The stream kind label.
    function label() external view returns (string memory);
    /// @notice Whether the outside right currently points at this source. Required true when the source is added;
    ///         false afterwards means the stream was revoked.
    /// @return Whether the outside right points at this source.
    function bound() external view returns (bool);
    /// @notice The gas stipend the token's sync calls `pull` with; within the tokenizer's bounds.
    /// @return The pull stipend in gas.
    function pullGas() external view returns (uint32);
    /// @notice What a pull would deliver to the revenue token now, best effort: each currency (address zero is
    ///         native ETH) with its amount, before Hookr's leg. A currency the token does not list is left out.
    /// @dev Optional: the tokenizer never calls it, and a source may not implement it. The state view calls it with a
    ///      gas cap and checks the answer is two canonically encoded arrays of the same length; a source that reverts,
    ///      runs out of gas or answers in another shape reads as unread, never as zeros.
    /// @return currencies The currencies a pull would deliver.
    /// @return amounts The amount of each, before Hookr's leg.
    function pendingIncome() external view returns (Currency[] memory currencies, uint256[] memory amounts);
}
