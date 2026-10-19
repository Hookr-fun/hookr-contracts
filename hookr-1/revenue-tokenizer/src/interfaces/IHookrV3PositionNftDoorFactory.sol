// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INonfungiblePositionManagerDoor} from "./external/INonfungiblePositionManagerDoor.sol";

/// @title Hookr v3 position NFT door factory, part of the HookRevenue Tokenizer
/// @notice Creates v3 position-NFT doors: deploys one at a CREATE2 address bound to the depositor, moves the
///         depositor's listed position NFTs into it and activates it, all in one transaction. The v4 door factory
///         (IHookrPositionNftDoorFactory) for the v3 NonfungiblePositionManager.
/// @dev The depositor must have approved the factory for each NFT (`approve` or `setApprovalForAll` on the
///      manager, or a permit the tokenizer applies first). Two ways in: `create`, where the caller is the
///      depositor, on a factory with no tokenizer; and `createFor`, which only the pinned tokenizer may call,
///      naming the creator whose NFTs move. A factory pinned to a tokenizer serves `createFor` alone
///      (`OnlyTokenizer`). The tokenizer deploys its factory in its own constructor through
///      HookrV3DoorFactoryDeployer, so the factory's creation code stays out of the tokenizer's. The wrapped
///      native token every door unwraps is read from the manager once.
interface IHookrV3PositionNftDoorFactory {
    /// @notice A door was created and activated.
    event DoorCreated(
        address indexed door,
        address indexed creator,
        address indexed revenueToken,
        uint64 unlockAt,
        uint256[] tokenIds,
        bytes32 salt
    );

    /// @notice The position manager address is zero.
    error PositionManagerZero();
    /// @notice Only the pinned tokenizer may create a door on a depositor's behalf; on a factory pinned to a
    ///         tokenizer, only the tokenizer creates doors at all.
    error OnlyTokenizer();

    /// @notice Creates a door holding the caller's `tokenIds`, paying `revenueToken` until `unlockAt` (or forever).
    ///         Only on a factory with no tokenizer.
    function create(address revenueToken, uint256[] calldata tokenIds, uint64 unlockAt, bytes32 salt)
        external
        returns (address door);
    /// @notice The tokenizer's way in: creates a door holding `depositor`'s `tokenIds`, so each NFT is recorded as
    ///         the depositor's and goes back to the depositor at release. Only the pinned tokenizer.
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
    /// @notice The tokenizer that may call `createFor`; zero when this factory serves `create` alone.
    function tokenizer() external view returns (address);
    /// @notice True for every door this factory created.
    function isDoor(address door) external view returns (bool);
    /// @notice How many doors this factory created for `revenueToken`.
    function doorCount(address revenueToken) external view returns (uint256);
    /// @notice The `i`-th door created for `revenueToken`, in creation order.
    function doorAt(address revenueToken, uint256 i) external view returns (address);
    /// @notice Every door this factory created for `revenueToken`, in creation order.
    function doorsOf(address revenueToken) external view returns (address[] memory);
    /// @notice The address `create` (or `createFor` on their behalf) gives `creator` for these arguments and `salt`.
    function predict(address creator, address revenueToken, uint256[] calldata tokenIds, uint64 unlockAt, bytes32 salt)
        external
        view
        returns (address);
}
