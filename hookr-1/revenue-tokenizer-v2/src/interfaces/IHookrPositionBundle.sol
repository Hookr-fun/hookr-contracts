// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrRevenueDoor} from "./IHookrRevenueDoor.sol";
import {IHookrForwarding} from "./IHookrForwarding.sol";
import {IHookrDoorTerm} from "./IHookrDoorTerm.sol";

/// @title Hookr position bundle, part of the HookRevenue Tokenizer
/// @notice What the v4 and v3 position-NFT doors share: a bundle of position NFTs from one account, locked until a
///         date or forever, whose fees the revenue token pulls a page of positions at a time.
/// @dev A door is created by its factory in one transaction: deploy, receive every listed NFT from the position
///      manager (all from `returnTo`), then `activate`. From then on the NFT list and the revenue token are fixed,
///      there is no owner, no pause and no sweep of listed principal; only `returnTo` may move the unlock time, and
///      only later. The revenue token pulls: a page of positions from a cursor, each collection capped, as many as
///      the stipend carries while keeping forwarding gas back, then the door's currencies in turn. Anyone may collect
///      chosen positions into the door (`pullSome`); once the unlock time has passed anyone may `release`: each NFT
///      gets a final strict collection into the door and goes back to `returnTo`; what was collected reaches the
///      token on its next pull, which a released door still answers.
interface IHookrPositionBundle is IHookrRevenueDoor, IHookrForwarding, IHookrDoorTerm {
    // ------------------------------------------------------------------ events

    /// @notice The door has every listed NFT and is live.
    event Activated(address indexed revenueToken, uint64 unlockAt, uint256[] tokenIds, address[] assets);
    /// @notice A position's fee collection reverted (or ran past the per-collection gas cap); the other positions were
    ///         still collected. `reason` is the revert data cut to its first 132 bytes (empty when there was none), so
    ///         a long reason may not decode.
    event CollectFailed(uint256 indexed tokenId, bytes reason);
    /// @notice A position NFT went back to `returnTo`.
    event Released(uint256 indexed tokenId, address indexed returnTo);
    /// @notice A position's final collection failed during `release`, so this NFT stayed in the door; `release` can be
    ///         called again for it. The matching `CollectFailed` carries the reason.
    event ReleaseHeld(uint256 indexed tokenId);
    /// @notice An NFT that is not the door's principal (never listed, or listed and already released) went to `to`.
    event UnlistedReturned(uint256 indexed tokenId, address indexed to);

    // ------------------------------------------------------------------ errors

    /// @notice The NFT list is empty.
    error NoPositions();
    /// @notice The NFT list is longer than MAX_POSITIONS.
    error TooManyPositions(uint256 count, uint256 max);
    /// @notice A token id appears twice in the list.
    error DuplicateToken(uint256 tokenId);
    /// @notice Only the factory may call this.
    error OnlyFactory();
    /// @notice Only the position manager may hand NFTs to the door.
    error OnlyPositionManager();
    /// @notice The door only accepts NFTs while it is being created, and only from `returnTo`.
    error NotAccepting();
    /// @notice The NFT is not on the door's list.
    error NotListed(uint256 tokenId);
    /// @notice The NFT is on the door's list, so it is principal and only `release` moves it.
    error Listed(uint256 tokenId);
    /// @notice The NFT was already received.
    error AlreadyReceived(uint256 tokenId);
    /// @notice The door never received this listed NFT, so it cannot activate.
    error NotReceived(uint256 tokenId);
    /// @notice The door does not own this NFT.
    error NotOwned(uint256 tokenId);
    /// @notice A listed position has no liquidity at activation, so it could never earn.
    error NoLiquidity(uint256 tokenId);
    /// @notice The door is already active.
    error AlreadyActive();
    /// @notice The door is not active yet.
    error NotActive();
    /// @notice Too little gas is left to give the next position's collection its full cap.
    error InsufficientGas(uint256 tokenId, uint256 gasLeft, uint256 needed);
    /// @notice `release` moved no NFT because every remaining position's final collection failed; `tokenId` and
    ///         `reason` (cut to its first 132 bytes) are the first failure's.
    error NoneReleased(uint256 tokenId, bytes reason);

    // ------------------------------------------------------------------ constants

    /// @notice The most position NFTs one door can hold: 64.
    function MAX_POSITIONS() external view returns (uint256);
    /// @notice The most gas one position's fee collection may use: 1,500,000. An honest collection runs in about
    ///         131k cold; a hook or a token that burns gas can cost a pull at most this much per position.
    function COLLECT_GAS_CAP() external view returns (uint256);
    /// @notice Gas kept back for the door's own work between the floor check and the collection call: 120,000.
    function COLLECT_GAS_MARGIN() external view returns (uint256);
    /// @notice The least gas that must be left before each position's collection starts, so the call receives its
    ///         full cap: 1,643,809. A token pull ends its page here; `pullSome` and `release` revert
    ///         `InsufficientGas`.
    function COLLECT_GAS_FLOOR() external view returns (uint256);
    /// @notice The most currencies one token pull keeps forwarding gas for before it collects: 2. The pull forwards
    ///         more while the gas allows; what it could not reach it forwards in turn over the next pulls.
    function FORWARD_PAGE() external view returns (uint256);
    /// @notice Gas a token pull keeps for its own work besides the collections and the forwards: 150,000.
    function PULL_BASE_GAS() external view returns (uint256);

    // ------------------------------------------------------------------ actions

    /// @notice Collects the listed positions in `ids` (any order; an id not on the list is `NotListed`, an empty list
    ///         `NoPositions`) into the door, without forwarding: the revenue token's next pull forwards it. Anyone may
    ///         call it, so an honest position is collected on its own gas whatever the other positions' hooks do.
    function pullSome(uint256[] calldata ids) external;
    /// @notice After the unlock time: for each NFT still in the door, collects its fees into the door one last time
    ///         and, if that succeeded, returns it to `returnTo`. An NFT whose final collection failed stays
    ///         (`ReleaseHeld`) and the call can be repeated for it. Anyone may call it; reverts before the unlock time,
    ///         always on a door locked forever, with `NoneReleased` when no NFT could move, and with `AlreadyReleased`
    ///         once every NFT is out.
    function release() external;
    /// @notice `release` for the listed positions in `ids` alone, with the same checks.
    function releaseSome(uint256[] calldata ids) external;
    /// @notice Returns an NFT that sits in the door but is not principal (one never on the list, or one already
    ///         released) to `returnTo`. Anyone may call it; it never touches a listed NFT still held (`Listed`).
    function rescueUnlisted(uint256 tokenId) external;

    // ------------------------------------------------------------------ views

    /// @notice The factory that created the door; the only account that may call `activate`.
    function factory() external view returns (address);
    /// @notice The locked position NFTs, in creation order.
    function tokenIds() external view returns (uint256[] memory);
    /// @notice Every currency the door forwards: native ETH (address zero) first, always, then the listed pools'
    ///         currencies but the revenue token itself, which never reaches the door.
    function assets() external view returns (address[] memory);
    /// @notice The gas stipend the tokenizer gives this door: `PULL_BASE_GAS`, `COLLECT_GAS_FLOOR` per position and
    ///         `FORWARD_ITEM_GAS` per currency up to `FORWARD_PAGE`, clipped to 12,000,000 (the token's largest
    ///         stipend; a larger door collects its positions in turn over several pulls).
    function pullGas() external view returns (uint32);
    /// @notice True once every listed NFT is in and the door is live.
    function active() external view returns (bool);
    /// @notice True once every NFT went back to `returnTo`.
    function released() external view returns (bool);
    /// @notice True once this NFT went back to `returnTo`.
    function releasedOf(uint256 tokenId) external view returns (bool);
    /// @notice How many NFTs went back so far.
    function releasedCount() external view returns (uint256);
    /// @notice Whether `release` would pass the time check now: active, not fully released, unlock passed, not
    ///         forever.
    function canRelease() external view returns (bool);
}
