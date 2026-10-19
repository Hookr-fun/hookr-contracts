// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrPositionNftDoor} from "./HookrPositionNftDoor.sol";
import {IHookrPositionNftDoorFactory} from "./interfaces/IHookrPositionNftDoorFactory.sol";
import {IPositionManagerDoor} from "./interfaces/IPositionManagerDoor.sol";

/// @title Hookr position NFT door factory, part of the HookRevenue Tokenizer
/// @notice Creates position-NFT doors: deploys one at a CREATE2 address bound to the caller, moves the caller's listed
///         position NFTs into it and activates it, all in one transaction.
/// @dev The depositor must have approved this factory for each NFT (`approve` or `setApprovalForAll` on the
///      PositionManager). Two ways in: `create`, where the caller is the depositor, on a factory with no tokenizer;
///      and `createFor`, which only the pinned HookRevenue Tokenizer may call, naming the creator whose NFTs move: the
///      tokenizer calls it inside `tokenizePositions`, so every NFT is pulled from the creator and goes back to the
///      creator at release, never to the tokenizer. A factory pinned to a tokenizer serves `createFor` alone: the
///      tokenizer fixes a revenue token's Hookr leg from its positions' hooks before the door exists, so a door anyone
///      could make afterwards for the same token would bolt income that pays Hookr nothing onto a token with no leg,
///      and would be listed under the token beside the tokenizer's door (`OnlyTokenizer`). The door's address depends
///      on the depositor, the salt and the door's constructor arguments, so
///      it can be computed with `predict` before the door exists. A predicted address is never a deposit target: an
///      NFT sent there before `create` makes `create` fail (the depositor no longer owns it) and sits at a codeless
///      address; the factory is the only way NFTs enter a door.
contract HookrPositionNftDoorFactory is IHookrPositionNftDoorFactory {
    /// @inheritdoc IHookrPositionNftDoorFactory
    IPositionManagerDoor public immutable positionManager;
    /// @inheritdoc IHookrPositionNftDoorFactory
    address public immutable hookrRoot;
    /// @inheritdoc IHookrPositionNftDoorFactory
    address public immutable tokenizer;
    /// @inheritdoc IHookrPositionNftDoorFactory
    mapping(address door => bool) public isDoor;
    /// @dev Every door created for a revenue token, in creation order: one push per door, so an app lists a token's doors
    ///      without a log scan.
    mapping(address revenueToken => address[]) internal _doorsOf;

    /// @param positionManager_ The Uniswap v4 PositionManager that minted the NFTs.
    /// @param hookrRoot_ The Hookr root every door reports its pools against.
    /// @param tokenizer_ The HookRevenue Tokenizer allowed to call `createFor`, or zero. The tokenizer deploys this factory
    ///        in its own constructor and passes itself.
    constructor(IPositionManagerDoor positionManager_, address hookrRoot_, address tokenizer_) {
        if (address(positionManager_) == address(0)) revert PositionManagerZero();
        positionManager = positionManager_;
        hookrRoot = hookrRoot_;
        tokenizer = tokenizer_;
    }

    /// @inheritdoc IHookrPositionNftDoorFactory
    function create(address revenueToken, uint256[] calldata tokenIds, uint64 unlockAt, bytes32 salt)
        external
        returns (address door)
    {
        if (tokenizer != address(0)) revert OnlyTokenizer();
        return _create(msg.sender, revenueToken, tokenIds, unlockAt, salt);
    }

    /// @inheritdoc IHookrPositionNftDoorFactory
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

    /// @dev Deploys the door at the address bound to `depositor` and `salt`, moves each NFT from the depositor into it
    ///      (the PositionManager tells the door who sent each one) and activates it.
    function _create(
        address depositor,
        address revenueToken,
        uint256[] calldata tokenIds,
        uint64 unlockAt,
        bytes32 salt
    ) private returns (address door) {
        HookrPositionNftDoor d = new HookrPositionNftDoor{salt: _salt(depositor, salt)}(
            positionManager, revenueToken, unlockAt, tokenIds, hookrRoot
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

    /// @inheritdoc IHookrPositionNftDoorFactory
    function doorCount(address revenueToken) external view returns (uint256) {
        return _doorsOf[revenueToken].length;
    }

    /// @inheritdoc IHookrPositionNftDoorFactory
    function doorAt(address revenueToken, uint256 i) external view returns (address) {
        return _doorsOf[revenueToken][i];
    }

    /// @inheritdoc IHookrPositionNftDoorFactory
    function doorsOf(address revenueToken) external view returns (address[] memory) {
        return _doorsOf[revenueToken];
    }

    /// @inheritdoc IHookrPositionNftDoorFactory
    function predict(address creator, address revenueToken, uint256[] calldata tokenIds, uint64 unlockAt, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(HookrPositionNftDoor).creationCode,
                abi.encode(positionManager, revenueToken, unlockAt, tokenIds, hookrRoot)
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
