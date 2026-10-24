// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrRevenueTokenDoor} from "./HookrRevenueTokenDoor.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";
import {IHookrRevenueTokenDoorFactory} from "../interfaces/IHookrRevenueTokenDoorFactory.sol";

/// @title Hookr revenue token door factory, part of the HookRevenue Tokenizer
/// @notice Makes revenue token doors for one tokenizer. See IHookrRevenueTokenDoorFactory for the rules.
/// @dev No owner. The CREATE2 salt binds `returnTo`, so no one takes another's address.
contract HookrRevenueTokenDoorFactory is IHookrRevenueTokenDoorFactory {
    /// @inheritdoc IHookrRevenueTokenDoorFactory
    address public immutable tokenizer;
    /// @inheritdoc IHookrRevenueTokenDoorFactory
    mapping(address door => bool) public isDoor;

    /// @param tokenizer_ The tokenizer this factory serves; it deploys the factory and passes itself.
    constructor(address tokenizer_) {
        if (tokenizer_ == address(0)) revert TokenizerZero();
        tokenizer = tokenizer_;
    }

    /// @inheritdoc IHookrRevenueTokenDoorFactory
    function createFor(address returnTo, address outer, address inner, uint64 unlockAt, bytes32 salt)
        external
        returns (address door)
    {
        if (msg.sender != tokenizer) revert OnlyTokenizer();
        if (inner.code.length == 0 || IHookrRevenueToken(inner).tokenizer() != tokenizer) revert ForeignToken(inner);
        door = address(new HookrRevenueTokenDoor{salt: _salt(returnTo, salt)}(outer, inner, returnTo, unlockAt));
        isDoor[door] = true;
        emit DoorCreated(door, returnTo, outer, inner, unlockAt, salt);
    }

    /// @inheritdoc IHookrRevenueTokenDoorFactory
    function predict(address returnTo, address outer, address inner, uint64 unlockAt, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(HookrRevenueTokenDoor).creationCode, abi.encode(outer, inner, returnTo, unlockAt))
        );
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(returnTo, salt), initCodeHash)))
            )
        );
    }

    /// @dev The CREATE2 salt: the caller's salt bound to `returnTo`.
    function _salt(address returnTo, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(returnTo, salt));
    }
}
