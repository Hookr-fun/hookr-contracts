// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManagerDoor} from "./IPositionManagerDoor.sol";
import {IHookrPositionBundle} from "./IHookrPositionBundle.sol";

/// @title Hookr position NFT door, part of the HookRevenue Tokenizer
/// @notice One locked bundle of Uniswap v4 position NFTs whose fees flow to a revenue token (IHookrPositionBundle).
/// @dev A collection is the PositionManager's DECREASE_LIQUIDITY of 0 then TAKE_PAIR to the door; on a pool of the
///      revenue token itself, TAKE of the other currency to the door and TAKE of the token's side to 0xdead. The
///      tokenizer splits a set of positions into a door on the pinned Hookr root (no leg) and one off it (Hookr's
///      leg): `rootCount` tells them apart.
interface IHookrPositionNftDoor is IHookrPositionBundle {
    /// @notice A position's fees were collected into the door.
    event Collected(uint256 indexed tokenId);

    /// @notice The Uniswap v4 PositionManager that minted the NFTs.
    function positionManager() external view returns (IPositionManagerDoor);
    /// @notice The Hookr root `isHookrPool` compares each pool's hook with.
    function hookrRoot() external view returns (address);
    /// @notice The pool a listed position sits in, read once at activation.
    function poolKeyOf(uint256 tokenId) external view returns (PoolKey memory);
    /// @notice Whether a listed position's pool hook is the Hookr root.
    function isHookrPool(uint256 tokenId) external view returns (bool);
    /// @notice For every listed position, whether its pool hook is the Hookr root.
    function hookrPools() external view returns (bool[] memory);
    /// @notice How many listed positions sit in pools whose hook is the Hookr root: all of them for the tokenizer's
    ///         no-leg door, none for its outside door.
    function rootCount() external view returns (uint256);
    /// @notice Whether a listed position's pool hook, not being the Hookr root, runs on liquidity removals, so its
    ///         author could make this position's fee collection fail and keep this NFT in the door. Reported only.
    function hookCanBlockCollection(uint256 tokenId) external view returns (bool);
}
