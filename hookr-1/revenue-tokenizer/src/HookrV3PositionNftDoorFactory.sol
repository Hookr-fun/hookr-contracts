// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrV3PositionNftDoor} from "./HookrV3PositionNftDoor.sol";
import {IHookrV3PositionNftDoorFactory} from "./interfaces/IHookrV3PositionNftDoorFactory.sol";
import {INonfungiblePositionManagerDoor} from "./interfaces/external/INonfungiblePositionManagerDoor.sol";

/// @title Hookr v3 position NFT door factory, part of the HookRevenue Tokenizer
/// @notice Creates v3 position-NFT doors: deploys one at a CREATE2 address bound to the caller, moves the caller's
///         listed position NFTs into it and activates it, all in one transaction. HookrPositionNftDoorFactory for
///         the v3 NonfungiblePositionManager.
/// @dev The depositor must have approved this factory for each NFT (`approve` or `setApprovalForAll` on the
///      manager). Two ways in: `create`, where the caller is the depositor, on a factory with no tokenizer; and
///      `createFor`, which only the pinned tokenizer may call, naming the creator whose NFTs move. A factory pinned
///      to a tokenizer serves `createFor` alone (`OnlyTokenizer`). The tokenizer deploys this factory from its own
///      constructor through HookrV3DoorFactoryDeployer. The door's address depends on the depositor, the salt and
///      the door's constructor arguments (`predict`); a predicted address is never a deposit target, the factory
///      is the only way NFTs enter a door.
contract HookrV3PositionNftDoorFactory is IHookrV3PositionNftDoorFactory {
    /// @inheritdoc IHookrV3PositionNftDoorFactory
    INonfungiblePositionManagerDoor public immutable positionManager;
    /// @inheritdoc IHookrV3PositionNftDoorFactory
    address public immutable wrappedNative;
    /// @inheritdoc IHookrV3PositionNftDoorFactory
    address public immutable tokenizer;
    /// @inheritdoc IHookrV3PositionNftDoorFactory
    mapping(address door => bool) public isDoor;
    /// @dev Every door created for a revenue token, in creation order.
    mapping(address revenueToken => address[]) internal _doorsOf;

    /// @param positionManager_ The Uniswap v3 NonfungiblePositionManager that minted the NFTs; its WETH9 is the
    ///        wrapper every door unwraps.
    /// @param tokenizer_ The tokenizer allowed to call `createFor`, or zero.
    constructor(INonfungiblePositionManagerDoor positionManager_, address tokenizer_) {
        if (address(positionManager_) == address(0)) revert PositionManagerZero();
        positionManager = positionManager_;
        wrappedNative = positionManager_.WETH9();
        tokenizer = tokenizer_;
    }

    /// @inheritdoc IHookrV3PositionNftDoorFactory
    function create(address revenueToken, uint256[] calldata tokenIds, uint64 unlockAt, bytes32 salt)
        external
        returns (address door)
    {
        if (tokenizer != address(0)) revert OnlyTokenizer();
        return _create(msg.sender, revenueToken, tokenIds, unlockAt, salt);
    }

    /// @inheritdoc IHookrV3PositionNftDoorFactory
    function createFor(
        address depositor,
        address revenueToken,
        uint256[] calldata tokenIds,
        uint64 unlockAt,
        bytes32 salt
    ) external returns (address door) {
        if (msg.sender != tokenizer || tokenizer == address(0)) revert OnlyTokenizer();
        return _create(depositor, revenueToken, tokenIds, unlockAt, salt);
    }

    /// @dev Deploys the door at the address bound to `depositor` and `salt`, moves each NFT from the depositor into
    ///      it (the manager tells the door who sent each one) and activates it.
    function _create(
        address depositor,
        address revenueToken,
        uint256[] calldata tokenIds,
        uint64 unlockAt,
        bytes32 salt
    ) private returns (address door) {
        HookrV3PositionNftDoor d = new HookrV3PositionNftDoor{salt: _salt(depositor, salt)}(
            positionManager, revenueToken, unlockAt, tokenIds, wrappedNative
        );
        door = address(d);
        for (uint256 i; i < tokenIds.length; ++i) {
            positionManager.safeTransferFrom(depositor, door, tokenIds[i]);
        }
        d.activate();
        isDoor[door] = true;
        _doorsOf[revenueToken].push(door);
        emit DoorCreated(door, depositor, revenueToken, unlockAt, tokenIds, salt);
    }

    /// @inheritdoc IHookrV3PositionNftDoorFactory
    function doorCount(address revenueToken) external view returns (uint256) {
        return _doorsOf[revenueToken].length;
    }

    /// @inheritdoc IHookrV3PositionNftDoorFactory
    function doorAt(address revenueToken, uint256 i) external view returns (address) {
        return _doorsOf[revenueToken][i];
    }

    /// @inheritdoc IHookrV3PositionNftDoorFactory
    function doorsOf(address revenueToken) external view returns (address[] memory) {
        return _doorsOf[revenueToken];
    }

    /// @inheritdoc IHookrV3PositionNftDoorFactory
    function predict(address creator, address revenueToken, uint256[] calldata tokenIds, uint64 unlockAt, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(HookrV3PositionNftDoor).creationCode,
                abi.encode(positionManager, revenueToken, unlockAt, tokenIds, wrappedNative)
            )
        );
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(creator, salt), initCodeHash)))
            )
        );
    }

    /// @dev The CREATE2 salt: the creator's own salt bound to the creator, so no one can take another's address.
    function _salt(address creator, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }
}
