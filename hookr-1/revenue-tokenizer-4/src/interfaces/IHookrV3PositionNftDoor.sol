// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INonfungiblePositionManagerDoor} from "./external/INonfungiblePositionManagerDoor.sol";
import {IHookrPositionBundle} from "./IHookrPositionBundle.sol";

/// @title Hookr v3 position NFT door, part of the HookRevenue Tokenizer
/// @notice One locked bundle of Uniswap v3 position NFTs whose fees flow to a revenue token (IHookrPositionBundle).
/// @dev What differs from the v4 door: a collection is one `collect` with both maxima at their largest, paid to the
///      door (the manager pokes the pool first, so it collects everything owed), except on a pool of the revenue
///      token itself, where the token's side has a maximum of 0 and stays in the position, going back with the NFT
///      at release (the manager pays one recipient, and the token refuses a transfer to its own door; the tokenizer
///      refuses a position on such a pool, `V3PairIsRevenueToken`, so this stays only as a guard); the native
///      side arrives as the manager's WETH9, which the door unwraps on the token's pull before forwarding, so the
///      door's currencies list native ETH in its place; a v3 pool is never on our hook, so a v3 door always carries
///      Hookr's leg.
interface IHookrV3PositionNftDoor is IHookrPositionBundle {
    /// @notice A position's fees were collected into the door.
    /// @param tokenId The position collected.
    /// @param amount0 The amount of the pool's token0 collected.
    /// @param amount1 The amount of the pool's token1 collected.
    event Collected(uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    /// @notice `amount` of the wrapped native token was unwrapped to native ETH.
    /// @param amount The amount unwrapped.
    event Unwrapped(uint256 amount);
    /// @notice The wrapper refused to unwrap `amount` this time; it stays in the door.
    /// @param amount The amount that stayed wrapped.
    event UnwrapFailed(uint256 amount);

    /// @notice Gas one unwrap of the wrapped native token gets: 100,000.
    /// @return The gas cap for one unwrap.
    function UNWRAP_GAS() external view returns (uint256);
    /// @notice The Uniswap v3 NonfungiblePositionManager that minted the NFTs.
    /// @return The position manager.
    function positionManager() external view returns (INonfungiblePositionManagerDoor);
    /// @notice The wrapped native token the door unwraps (the manager's WETH9).
    /// @return The wrapped native token.
    function wrappedNative() external view returns (address);
    /// @notice The pool a listed position sits in, read once at activation.
    /// @param tokenId The listed position NFT.
    /// @return token0 The pool's first token.
    /// @return token1 The pool's second token.
    /// @return fee The pool's fee tier.
    function poolOf(uint256 tokenId) external view returns (address token0, address token1, uint24 fee);
}
