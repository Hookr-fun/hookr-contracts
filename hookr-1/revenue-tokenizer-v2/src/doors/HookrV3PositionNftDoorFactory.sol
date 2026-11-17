// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrV3PositionNftDoor} from "./HookrV3PositionNftDoor.sol";
import {IHookrV3PositionNftDoorFactory} from "../interfaces/IHookrV3PositionNftDoorFactory.sol";
import {INonfungiblePositionManagerDoor} from "../interfaces/external/INonfungiblePositionManagerDoor.sol";

/// @title Hookr v3 position NFT door factory, part of the HookRevenue Tokenizer
/// @notice Creates v3 position-NFT doors for one tokenizer. See IHookrV3PositionNftDoorFactory for the rules.
/// @dev No owner. The CREATE2 salt binds the depositor, so no one takes another's address.
contract HookrV3PositionNftDoorFactory is IHookrV3PositionNftDoorFactory {
    /// @inheritdoc IHookrV3PositionNftDoorFactory
    INonfungiblePositionManagerDoor public immutable positionManager;
    /// @inheritdoc IHookrV3PositionNftDoorFactory
    address public immutable wrappedNative;
    /// @inheritdoc IHookrV3PositionNftDoorFactory
    address public immutable tokenizer;
    /// @inheritdoc IHookrV3PositionNftDoorFactory
    mapping(address door => bool) public isDoor;

    /// @param positionManager_ The Uniswap v3 NonfungiblePositionManager that minted the NFTs; its WETH9 is the
    ///        wrapper every door unwraps.
    /// @param tokenizer_ The tokenizer this factory serves; it deploys the factory and passes itself.
    constructor(INonfungiblePositionManagerDoor positionManager_, address tokenizer_) {
        if (address(positionManager_) == address(0) || tokenizer_ == address(0)) revert InvalidConfig();
        positionManager = positionManager_;
        wrappedNative = positionManager_.WETH9();
        tokenizer = tokenizer_;
    }

    /// @inheritdoc IHookrV3PositionNftDoorFactory
    function createFor(
        address depositor,
        address revenueToken,
        uint256[] calldata tokenIds,
        uint64 unlockAt,
        bytes32 salt
    ) external returns (address door) {
        if (msg.sender != tokenizer) revert OnlyTokenizer();
        HookrV3PositionNftDoor d = new HookrV3PositionNftDoor{salt: _salt(depositor, salt)}(
            positionManager, revenueToken, depositor, unlockAt, tokenIds, wrappedNative
        );
        door = address(d);
        for (uint256 i; i < tokenIds.length; ++i) {
            positionManager.safeTransferFrom(depositor, door, tokenIds[i]);
        }
        d.activate();
        isDoor[door] = true;
        emit DoorCreated(door, depositor, revenueToken, unlockAt, tokenIds, salt);
    }

    /// @inheritdoc IHookrV3PositionNftDoorFactory
    function predict(
        address depositor,
        address revenueToken,
        uint256[] calldata tokenIds,
        uint64 unlockAt,
        bytes32 salt
    ) external view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(HookrV3PositionNftDoor).creationCode,
                abi.encode(positionManager, revenueToken, depositor, unlockAt, tokenIds, wrappedNative)
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
