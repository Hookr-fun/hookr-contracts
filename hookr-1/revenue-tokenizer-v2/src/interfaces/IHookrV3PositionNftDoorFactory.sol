// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INonfungiblePositionManagerDoor} from "./external/INonfungiblePositionManagerDoor.sol";

/// @title Hookr v3 position NFT door factory, part of the HookRevenue Tokenizer
/// @notice Creates v3 position-NFT doors for one tokenizer: the v4 door factory (IHookrPositionNftDoorFactory) for
///         the v3 NonfungiblePositionManager. The wrapped native token every door unwraps is read from the manager
///         once.
interface IHookrV3PositionNftDoorFactory {
    /// @notice A door was created and activated.
    event DoorCreated(
        address indexed door,
        address indexed returnTo,
        address indexed revenueToken,
        uint64 unlockAt,
        uint256[] tokenIds,
        bytes32 salt
    );

    /// @notice The position manager or the tokenizer address is zero.
    error InvalidConfig();
    /// @notice Only the pinned tokenizer creates doors.
    error OnlyTokenizer();

    /// @notice Creates a door holding `depositor`'s `tokenIds`, paying `revenueToken` until `unlockAt` (or forever);
    ///         every NFT goes back to `depositor` at release. Only the pinned tokenizer.
    function createFor(
        address depositor,
        address revenueToken,
        uint256[] calldata tokenIds,
        uint64 unlockAt,
        bytes32 salt
    ) external returns (address door);

    /// @notice The Uniswap v3 NonfungiblePositionManager that minted the NFTs.
    function positionManager() external view returns (INonfungiblePositionManagerDoor);
    /// @notice The wrapped native token every door unwraps: the manager's WETH9.
    function wrappedNative() external view returns (address);
    /// @notice The tokenizer this factory serves alone.
    function tokenizer() external view returns (address);
    /// @notice True for every door this factory created.
    function isDoor(address door) external view returns (bool);
    /// @notice The address `createFor` gives for these arguments.
    function predict(
        address depositor,
        address revenueToken,
        uint256[] calldata tokenIds,
        uint64 unlockAt,
        bytes32 salt
    ) external view returns (address);
}
