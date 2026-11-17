// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrPositionNftDoor} from "./HookrPositionNftDoor.sol";
import {IHookrPositionNftDoorFactory} from "../interfaces/IHookrPositionNftDoorFactory.sol";
import {IPositionManagerDoor} from "../interfaces/IPositionManagerDoor.sol";

/// @title Hookr position NFT door factory, part of the HookRevenue Tokenizer
/// @notice Creates v4 position-NFT doors for one tokenizer. See IHookrPositionNftDoorFactory for the rules.
/// @dev No owner. The CREATE2 salt binds the depositor, so no one takes another's address.
contract HookrPositionNftDoorFactory is IHookrPositionNftDoorFactory {
    /// @inheritdoc IHookrPositionNftDoorFactory
    IPositionManagerDoor public immutable positionManager;
    /// @inheritdoc IHookrPositionNftDoorFactory
    address public immutable hookrRoot;
    /// @inheritdoc IHookrPositionNftDoorFactory
    address public immutable tokenizer;
    /// @inheritdoc IHookrPositionNftDoorFactory
    mapping(address door => bool) public isDoor;

    /// @param positionManager_ The Uniswap v4 PositionManager that minted the NFTs.
    /// @param hookrRoot_ The Hookr root every door reports its pools against.
    /// @param tokenizer_ The tokenizer this factory serves; it deploys the factory and passes itself.
    constructor(IPositionManagerDoor positionManager_, address hookrRoot_, address tokenizer_) {
        if (address(positionManager_) == address(0) || tokenizer_ == address(0)) revert InvalidConfig();
        positionManager = positionManager_;
        hookrRoot = hookrRoot_;
        tokenizer = tokenizer_;
    }

    /// @inheritdoc IHookrPositionNftDoorFactory
    function createFor(
        address depositor,
        address revenueToken,
        uint256[] calldata tokenIds,
        uint64 unlockAt,
        bytes32 salt
    ) external returns (address door) {
        if (msg.sender != tokenizer) revert OnlyTokenizer();
        HookrPositionNftDoor d = new HookrPositionNftDoor{salt: _salt(depositor, salt)}(
            positionManager, revenueToken, depositor, unlockAt, tokenIds, hookrRoot
        );
        door = address(d);
        for (uint256 i; i < tokenIds.length; ++i) {
            positionManager.safeTransferFrom(depositor, door, tokenIds[i]);
        }
        d.activate();
        isDoor[door] = true;
        emit DoorCreated(door, depositor, revenueToken, unlockAt, tokenIds, salt);
    }

    /// @inheritdoc IHookrPositionNftDoorFactory
    function predict(
        address depositor,
        address revenueToken,
        uint256[] calldata tokenIds,
        uint64 unlockAt,
        bytes32 salt
    ) external view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(HookrPositionNftDoor).creationCode,
                abi.encode(positionManager, revenueToken, depositor, unlockAt, tokenIds, hookrRoot)
            )
        );
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(depositor, salt), initCodeHash)))
            )
        );
    }

    /// @dev The CREATE2 salt: the depositor's own salt bound to the depositor.
    function _salt(address depositor, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(depositor, salt));
    }
}
