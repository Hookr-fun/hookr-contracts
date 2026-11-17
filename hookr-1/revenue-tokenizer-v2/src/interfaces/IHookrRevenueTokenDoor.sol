// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrRevenueDoor} from "./IHookrRevenueDoor.sol";
import {IHookrForwarding} from "./IHookrForwarding.sol";
import {IHookrDoorTerm} from "./IHookrDoorTerm.sol";

/// @title Hookr revenue token door, part of the HookRevenue Tokenizer
/// @notice Holds shares of an inner revenue token for an outer one, so the outer token's holders share what the
///         inner shares earn: a basket of revenue tokens. The outer token pulls it: the inner token's income in every
///         listed asset is claimed straight into the outer token, asset by asset, and the door's share of every inner
///         drop in a currency the outer token lists (native ETH always) is claimed and forwarded to it. An inner drop
///         in any other currency is left in the inner box for `claimDrop`, which forwards it into the outer token's
///         drop box on request, so drops nobody wants are not copied up a basket. Income or a drop in the outer token
///         itself, which refuses its own shares, is claimed to 0xdead, where it earns nothing; native ETH sent to the
///         door is forwarded by the next pull.
/// @dev Made by HookrRevenueTokenDoorFactory for its tokenizer alone; the tokenizer then moves the inner shares in
///      from the account adding the stream, `returnTo`. Both tokens come from the same tokenizer, and the inner token
///      refuses transfers only to its own doors, so the door can hold its shares. Hookr's leg on this door is zero.
///      From the unlock time anyone may `release`: the shares go back to `returnTo`; the inner token's ledger settles
///      the door's income at the transfer and keeps it owed to the door, so the next pull still claims it into the
///      outer token, and drops the door was in for keep being claimed from the cursor.
interface IHookrRevenueTokenDoor is IHookrRevenueDoor, IHookrForwarding, IHookrDoorTerm {
    /// @notice The inner and outer revenue tokens are the same token.
    error SameToken();

    /// @notice `amount` of the door's income in inner asset `asset` was claimed into the outer token.
    event IncomeClaimed(uint256 indexed asset, uint256 amount);
    /// @notice The inner token's claim of the door's income in asset `asset` reverted (the asset is frozen, refuses
    ///         the outer token, or the inner token holds none of it); the income stays owed to the door for a later
    ///         pull. `reason` is the claim's revert data cut to its first 132 bytes (the error's selector and four
    ///         words): longer data is cut there, so a long reason may not decode, and an empty one means the claim
    ///         returned no data.
    event IncomeClaimFailed(uint256 indexed asset, bytes reason);
    /// @notice The door's share of inner drop `dropId`, `amount` of `asset`, was claimed and forwarded (or, for the
    ///         outer token itself, claimed to 0xdead).
    event DropClaimed(uint256 indexed dropId, address indexed asset, uint256 amount);
    /// @notice The inner drop box refused the door's claim of drop `dropId`; `claimDrop` retries it.
    event DropClaimFailed(uint256 indexed dropId);
    /// @notice A pull left the door's share of drop `dropId`, in `asset`, which the outer token does not list, in the
    ///         inner box; `claimDrop` takes it on request.
    event DropLeft(uint256 indexed dropId, address indexed asset);
    /// @notice `shares` of the inner token went back to `returnTo`.
    event Released(address indexed returnTo, uint256 shares);

    /// @notice Gas one inner asset's claim gets: 1,600,000, above the costliest asset an inner token can list (a
    ///         revenue token of this tokenizer with eight assets while each of the eight has its first income
    ///         streaming, 1,175,338 cold into an outer token holding it).
    function CLAIM_GAS() external view returns (uint256);
    /// @notice The most gas one inner asset's read and claim can take, every cap included: 1,700,000. A pull starts
    ///         an asset only with this left.
    function INCOME_ITEM_GAS() external view returns (uint256);
    /// @notice Gas one inner drop box `claim` gets: 1,600,000 (a drop share of the costliest asset into the door
    ///         while each of its eight assets has its first income streaming, 1,146,341 cold).
    function DROP_CLAIM_GAS() external view returns (uint256);
    /// @notice The most inner drops one pull visits: 4. A pull starts one only with `DROP_ITEM_GAS` left.
    function DROPS_PER_PULL() external view returns (uint256);
    /// @notice The most gas one drop's claim and forward can take, every cap included: 4,050,000.
    function DROP_ITEM_GAS() external view returns (uint256);
    /// @notice The gas stipend the tokenizer gives this door: 12,000,000, the token's largest. A pull claims every
    ///         inner asset whose claim fits and the rest first on the next pull (`incomeCursor`), then up to
    ///         `DROPS_PER_PULL` drops.
    function PULL_GAS() external view returns (uint32);

    /// @notice The inner revenue token whose shares the door holds.
    function inner() external view returns (address);
    /// @notice The inner token's drop box, read once at construction.
    function innerDropBox() external view returns (address);
    /// @notice The inner shares the door holds now.
    function shares() external view returns (uint256);
    /// @notice The inner box's drop count when the door was made: the door's first drop. Drops before it are never
    ///         the door's.
    function firstDrop() external view returns (uint256);
    /// @notice The next inner drop a pull visits.
    function dropCursor() external view returns (uint256);
    /// @notice Whether the shares went back to `returnTo`.
    function released() external view returns (bool);
    /// @notice The inner asset the next pull's income starts at: the one the last pull ran out of gas at, or zero.
    function incomeCursor() external view returns (uint256);

    /// @notice From the unlock time, returns every inner share the door holds to `returnTo`. Anyone may call.
    ///         Reverts before the unlock, always on a door locked forever, and once released.
    function release() external;
    /// @notice Claims the door's share of inner drop `dropId`, any drop from `firstDrop` on, and forwards it: to the
    ///         outer token when it lists the asset, into the outer token's drop box otherwise (an immediate drop at a
    ///         release period under an hour, the stray stream at an hour or more, less Hookr's leg, which is zero on
    ///         this door);
    ///         a drop the door has no share in, or claimed already, moves nothing. Anyone may call: for a drop whose
    ///         claim a pull could not make, one a pull left because the outer token does not list its currency
    ///         (`DropLeft`), or one the cursor has not reached yet. `UnknownDrop` before `firstDrop` or past the last
    ///         drop.
    function claimDrop(uint256 dropId) external;
}
