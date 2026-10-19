// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title Uniswap v4 PositionManager, the subset the position-NFT door uses
/// @notice The reads, transfers, permits and the one action the door, its factory and the tokenizer call on the
///         PositionManager.
/// @dev A position is an ERC-721 whose liquidity the PoolManager holds for the PositionManager under the salt
///      bytes32(tokenId). `transferFrom` and `safeTransferFrom` revert while the PoolManager is unlocked.
interface IPositionManagerDoor {
    /// @notice The PoolManager that holds every position's liquidity.
    function poolManager() external view returns (address);

    /// @notice The owner of a position NFT; reverts for a token that does not exist.
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice A position's pool key and its packed position info (subscriber flag, ticks, truncated pool id).
    /// @dev The key is all zero for a token that never existed.
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory poolKey, uint256 info);

    /// @notice A position's liquidity, read from the PoolManager.
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);

    /// @notice Moves a position NFT; the caller must be its owner or approved for it.
    function transferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Moves a position NFT and, when `to` holds code, requires its `onERC721Received` to accept it.
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Runs encoded position actions (`abi.encode(bytes actions, bytes[] params)`) inside one PoolManager
    ///         unlock. The caller must own or be approved for every position the actions touch.
    /// @param unlockData The encoded actions and their parameters.
    /// @param deadline The last timestamp at which the call may run.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

    /// @notice Approves `spender` for position `tokenId` on its owner's signature (ERC721Permit_v4), so the owner
    ///         signs instead of sending `approve`. Anyone may relay it.
    /// @param spender The account approved for the position.
    /// @param tokenId The position.
    /// @param deadline The last timestamp at which the signature is good.
    /// @param nonce The owner's unordered nonce: the top 248 bits pick a word, the low 8 bits a bit of it.
    /// @param signature The owner's signature, `r || s || v`.
    function permit(address spender, uint256 tokenId, uint256 deadline, uint256 nonce, bytes calldata signature)
        external
        payable;

    /// @notice Sets `operator` as an operator for every position of `owner` on `owner`'s signature. Anyone may relay
    ///         it.
    function permitForAll(
        address owner,
        address operator,
        bool approved,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external payable;
}
