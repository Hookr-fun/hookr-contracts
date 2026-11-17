// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPositionManagerDoor} from "./IPositionManagerDoor.sol";

/// @title Hookr position NFT door factory, part of the HookRevenue Tokenizer
/// @notice Creates v4 position-NFT doors for one tokenizer: deploys one at a CREATE2 address bound to the depositor,
///         moves the depositor's listed position NFTs into it and activates it, all in one transaction.
/// @dev The depositor approves this factory for each NFT (`approve` or `setApprovalForAll` on the PositionManager, or
///      a permit the tokenizer applies first). Only the pinned tokenizer calls `createFor`: it fixes each door's Hookr
///      leg from its positions' hooks, so a door anyone else made could bolt income that pays no leg onto a token. A
///      door's address depends on the depositor, the salt and its constructor arguments (`predict`); a predicted
///      address is never a deposit target, the factory is the only way NFTs enter a door.
interface IHookrPositionNftDoorFactory {
    /// @notice A door was created and activated.
    /// @param door The new door.
    /// @param returnTo The depositor, who gets every NFT back at release.
    /// @param revenueToken The revenue token every collected fee goes to.
    /// @param unlockAt The unlock timestamp, or type(uint64).max for forever.
    /// @param tokenIds The position NFTs the door holds.
    /// @param salt The salt the address is bound to, with the depositor.
    event DoorCreated(
        address indexed door,
        address indexed returnTo,
        address indexed revenueToken,
        uint64 unlockAt,
        uint256[] tokenIds,
        bytes32 salt
    );

    /// @notice The PositionManager or the tokenizer address is zero.
    error InvalidConfig();
    /// @notice Only the pinned tokenizer creates doors.
    error OnlyTokenizer();

    /// @notice Creates a door holding `depositor`'s `tokenIds`, paying `revenueToken` until `unlockAt` (or forever);
    ///         every NFT goes back to `depositor` at release. Only the pinned tokenizer.
    /// @param depositor The account whose NFTs move, who approved this factory: the door's `returnTo`.
    /// @param revenueToken The revenue token every collected fee goes to.
    /// @param tokenIds The depositor's position NFTs, 1 to 64.
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

    /// @notice The Uniswap v4 PositionManager that minted the NFTs.
    /// @return The PositionManager.
    function positionManager() external view returns (IPositionManagerDoor);
    /// @notice The Hookr root every door reports its pools against.
    /// @return The Hookr root.
    function hookrRoot() external view returns (address);
    /// @notice The HookRevenue Tokenizer this factory serves alone.
    /// @return The tokenizer.
    function tokenizer() external view returns (address);
    /// @notice True for every door this factory created.
    /// @param door The address to check.
    /// @return Whether this factory created it.
    function isDoor(address door) external view returns (bool);
    /// @notice The address `createFor` gives for these arguments.
    /// @param depositor The account whose NFTs move.
    /// @param revenueToken The revenue token every collected fee goes to.
    /// @param tokenIds The depositor's position NFTs, 1 to 64.
    /// @param unlockAt The unlock timestamp, or type(uint64).max for forever.
    /// @param salt The salt the door's address is bound to, with the depositor.
    /// @return The predicted door address.
    function predict(
        address depositor,
        address revenueToken,
        uint256[] calldata tokenIds,
        uint64 unlockAt,
        bytes32 salt
    ) external view returns (address);
}
