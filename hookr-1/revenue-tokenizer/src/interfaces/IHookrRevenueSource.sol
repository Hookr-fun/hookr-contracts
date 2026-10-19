// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Hookr revenue source, part of the HookRevenue Tokenizer
/// @notice What any contract answers to be a source of a revenue token: a door of kind `SOURCE` that the token's
///         sync pulls. A source only pushes what it collected into the revenue token (and drops into the token's
///         drop box what the token does not list as an asset); the token never pays a source and never calls it
///         with more than the gas stipend it declared. The Pons adapter implements it; any other platform plugs
///         in later with a new adapter and no change to the token or the tokenizer.
/// @dev Fixed at mint like every other door: the tokenizer checks `revenueToken()` names the token being minted,
///      `bound()` is true, every currency of `assets()` is one of the token's assets and `pullGas()` is within the
///      tokenizer's bounds. The sync calls `pull()` as a raw call with that stipend and copies no return data, so a
///      source that reverts, runs out of gas or answers with garbage fails only itself (`DoorPulled(i, false)`).
///      A source counts as outside our hook: a token with any source takes the Hookr leg (5% of the shares). A
///      source whose `ends()` is `REVOCABLE` with a date is refused at mint (`SourceRevocationPending`): the
///      revocation must lapse or be cancelled first. `pull()` must never revert on an empty collection and must do
///      nothing while the revenue token has no code (the adapter exists before the token, pointing at its predicted
///      address); it should pay only a token that sealed it as a door, as the Pons adapter does, so the right never
///      feeds a token that took no leg for it. Anything the token does not list goes in through the token's drop
///      box (`approve` the box, then `IHookrDropBox.drop`); a pull must never call the token's `dropStray`, which
///      runs under the lock the sync holds while it pulls.
interface IHookrRevenueSource {
    /// @notice When a stream ends, as the app shows it.
    /// @param FOREVER Nothing can move the stream away from the token.
    /// @param AT_BLOCK The stream ends at parent block `at` (a locked family).
    /// @param AT_TIME The stream ends at timestamp `at` (a position-NFT door).
    /// @param REVOCABLE Someone else can move the stream away at any time; `at` is the earliest moment a pending
    ///        revocation takes effect, or zero when none is pending.
    /// @param ENDED The stream no longer pays the token (released, or revoked).
    enum EndKind {
        FOREVER,
        AT_BLOCK,
        AT_TIME,
        REVOCABLE,
        ENDED
    }

    /// @notice `amount` of `currency` reached the revenue token.
    event Forwarded(Currency indexed currency, uint256 amount);
    /// @notice The revenue token could not take `amount` of `currency` this time; it stays in the source for a
    ///         later pull.
    event ForwardFailed(Currency indexed currency, uint256 amount);
    /// @notice `amount` of `asset`, which the token does not list, was dropped into the token's drop box as drop
    ///         `dropId`.
    event StrayDropped(address indexed asset, uint256 amount, uint256 dropId);
    /// @notice The drop box refused `amount` of `asset` this time (no earning supply yet, or the box's own
    ///         refusals); it stays in the source for a later pull.
    event StrayDropFailed(address indexed asset, uint256 amount);

    /// @notice The revenue token has no code yet: the source does nothing until the token exists.
    error NotLive();

    /// @notice The revenue token every pull pays. Fixed at construction, so the source can exist before the token
    ///         at the token's predicted address.
    function revenueToken() external view returns (address);
    /// @notice Every currency a pull may deliver to the token (address zero is native ETH). The tokenizer requires
    ///         each to be one of the token's assets; anything else the source collects is dropped into the token's
    ///         drop box instead.
    function assets() external view returns (Currency[] memory);
    /// @notice The kind of stream, as a constant id (`keccak256("pons.v2")`, ...).
    function sourceKind() external view returns (bytes32);
    /// @notice The kind of stream, in words, for the app.
    function label() external view returns (string memory);
    /// @notice Whether the outside right currently points at this source (the Pons creator fee recipient).
    ///         Required true at mint; false afterwards means the stream was revoked.
    function bound() external view returns (bool);
    /// @notice When the stream ends, and the pending revocation if there is one.
    function ends() external view returns (EndKind kind, uint64 at);
    /// @notice The gas stipend the token's sync calls `pull` with; between the tokenizer's `MIN_SOURCE_GAS` and
    ///         `MAX_SOURCE_GAS`.
    function pullGas() external view returns (uint32);
    /// @notice Collects everything the right has for this source and pushes it to the revenue token: native ETH
    ///         into the token's empty `receive`, the token's ERC-20 assets by `transfer`, each on its own attempt
    ///         with a gas cap; anything the token does not list goes into the token's drop box as a drop (`approve`
    ///         the box, then `IHookrDropBox.drop`; never the token's `dropStray`, which is locked during a sync).
    ///         Anyone may call; the token's sync does. Never pays anyone but the token and its box, and only a
    ///         token that sealed this source as a door.
    function pull() external;
}
