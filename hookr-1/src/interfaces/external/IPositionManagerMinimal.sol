// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IPositionManagerMinimal
/// @notice The Uniswap v4 PositionManager surface HookrLpBoost uses (0x58daec3116aae6D93017bAAea7749052E8a04fA7 on
///         Robinhood Chain 4663).
/// @dev A position is an ERC-721 whose liquidity the PoolManager holds for the PositionManager under salt
///      bytes32(tokenId). `info` packs, from the low bit: the subscriber flag (8 bits), tickLower (24), tickUpper (24)
///      and the upper 200 bits of the pool id. `transferFrom` and `safeTransferFrom` revert while the PoolManager is
///      unlocked and unsubscribe a subscribed position.
interface IPositionManagerMinimal {
    /// @notice Returns the PoolManager that holds every position's liquidity.
    /// @return The PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns the owner of a position NFT; reverts for a token that does not exist.
    /// @param tokenId The position.
    /// @return The owner.
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice Returns a position's pool and its packed position info.
    /// @param tokenId The position.
    /// @return poolKey The pool the position belongs to (all zero for a token that never existed).
    /// @return info The packed subscriber flag, ticks and truncated pool id.
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory poolKey, uint256 info);

    /// @notice Returns a position's liquidity, read from the PoolManager.
    /// @param tokenId The position.
    /// @return liquidity The position's liquidity.
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);

    /// @notice Moves a position NFT; the caller must be its owner or approved for it.
    /// @param from The current owner.
    /// @param to The new owner.
    /// @param tokenId The position.
    function transferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Moves a position NFT and, when `to` holds code, requires its `onERC721Received` to accept it.
    /// @param from The current owner.
    /// @param to The new owner.
    /// @param tokenId The position.
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Runs encoded position actions (`abi.encode(bytes actions, bytes[] params)`) inside one PoolManager
    ///         unlock.
    /// @param unlockData The encoded actions and their parameters.
    /// @param deadline The last timestamp at which the call may run.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}
