// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPositionManagerDoor} from "./IPositionManagerDoor.sol";

/// @title Hookr position NFT door factory, part of the HookRevenue Tokenizer
/// @notice Creates position-NFT doors: deploys one at a CREATE2 address bound to the depositor, moves the depositor's
///         listed position NFTs into it and activates it, all in one transaction.
/// @dev The depositor must have approved the factory for each NFT (`approve` or `setApprovalForAll` on the
///      PositionManager, or a permit the tokenizer applies first). Two ways in: `create`, where the caller is the
///      depositor, on a factory with no tokenizer; and `createFor`, which only the pinned HookRevenue Tokenizer may
///      call, naming the creator whose NFTs move. A factory pinned to a tokenizer serves `createFor` alone
///      (`OnlyTokenizer`): the tokenizer fixes a revenue token's Hookr leg from its positions' hooks before the door
///      exists, so a door anyone could make afterwards for the same token would bolt income that pays Hookr nothing onto
///      a token with no leg. A door's address depends on the depositor, the salt and the door's constructor arguments
///      (`predict`); a predicted address is never a deposit target, the factory is the only way NFTs enter a door.
interface IHookrPositionNftDoorFactory {
    // ------------------------------------------------------------------ events

    /// @notice A door was created and activated.
    event DoorCreated(
        address indexed door,
        address indexed creator,
        address indexed revenueToken,
        uint64 unlockAt,
        uint256[] tokenIds,
        bytes32 salt
    );

    // ------------------------------------------------------------------ errors

    /// @notice The PositionManager address is zero.
    error PositionManagerZero();
    /// @notice Only the pinned tokenizer may create a door on a depositor's behalf; on a factory pinned to a tokenizer,
    ///         only the tokenizer creates doors at all.
    error OnlyTokenizer();

    // ------------------------------------------------------------------ actions

    /// @notice Creates a door holding the caller's `tokenIds`, paying `revenueToken` until `unlockAt` (or forever). Only
    ///         on a factory with no tokenizer; a factory pinned to a tokenizer reverts `OnlyTokenizer`.
    /// @param revenueToken The revenue token every collected fee goes to.
    /// @param tokenIds The caller's position NFTs; the factory must be approved for each.
    /// @param unlockAt The unlock timestamp (any future date the creator picks), or type(uint64).max for forever.
    /// @param salt The caller's salt; the same caller and salt always give the same door address for the same
    ///        arguments.
    /// @return door The new door.
    function create(address revenueToken, uint256[] calldata tokenIds, uint64 unlockAt, bytes32 salt)
        external
        returns (address door);

    /// @notice The tokenizer's way in: creates a door holding `depositor`'s `tokenIds` (the depositor approved this
    ///         factory), so each NFT is recorded as the depositor's and goes back to the depositor at release, not to
    ///         the tokenizer. Only the pinned tokenizer.
    /// @param depositor The creator whose NFTs move.
    /// @param revenueToken The revenue token every collected fee goes to.
    /// @param tokenIds The depositor's position NFTs.
    /// @param unlockAt The unlock timestamp, or type(uint64).max for forever.
    /// @param salt The salt the door's address is bound to, with the depositor.
    /// @return door The new door.
    function createFor(
        address depositor,
        address revenueToken,
        uint256[] calldata tokenIds,
        uint64 unlockAt,
        bytes32 salt
    ) external returns (address door);

    // ------------------------------------------------------------------ views

    /// @notice The Uniswap v4 PositionManager that minted the NFTs.
    function positionManager() external view returns (IPositionManagerDoor);

    /// @notice The Hookr root every door reports its pools against.
    function hookrRoot() external view returns (address);

    /// @notice The HookRevenue Tokenizer that may call `createFor`; zero when this factory serves `create` alone.
    function tokenizer() external view returns (address);

    /// @notice True for every door this factory created.
    function isDoor(address door) external view returns (bool);

    /// @notice How many doors this factory created for `revenueToken`.
    function doorCount(address revenueToken) external view returns (uint256);

    /// @notice The `i`-th door created for `revenueToken`, in creation order.
    function doorAt(address revenueToken, uint256 i) external view returns (address);

    /// @notice Every door this factory created for `revenueToken`, in creation order (on a pinned factory, the
    ///         tokenizer's alone; `IHookrRevenueTokenizer.tokenizations(token).door` is the one it sealed in).
    function doorsOf(address revenueToken) external view returns (address[] memory);

    /// @notice The address `create` (or `createFor` on their behalf) gives `creator` for these arguments and `salt`.
    function predict(address creator, address revenueToken, uint256[] calldata tokenIds, uint64 unlockAt, bytes32 salt)
        external
        view
        returns (address);
}
