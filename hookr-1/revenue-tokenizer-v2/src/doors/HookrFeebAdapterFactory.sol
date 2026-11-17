// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrFeebAdapter} from "./HookrFeebAdapter.sol";
import {IHookrFeebAdapter} from "../interfaces/IHookrFeebAdapter.sol";
import {IHookrFeebAdapterFactory} from "../interfaces/IHookrFeebAdapterFactory.sol";
import {IBeneficiaryVault} from "../interfaces/external/IBeneficiaryVault.sol";

/// @title Hookr FEEB adapter factory, part of the HookRevenue Tokenizer
/// @notice Makes FEEB adapters for one tokenizer. See IHookrFeebAdapterFactory for the rules.
/// @dev No owner. The CREATE2 salt binds the depositor, so no one takes another's address.
contract HookrFeebAdapterFactory is IHookrFeebAdapterFactory {
    /// @inheritdoc IHookrFeebAdapterFactory
    address public immutable tokenizer;
    /// @inheritdoc IHookrFeebAdapterFactory
    address public immutable positionManager;
    /// @inheritdoc IHookrFeebAdapterFactory
    bytes32 public immutable splitterCodeHash;
    /// @inheritdoc IHookrFeebAdapterFactory
    mapping(address adapter => bool) public isAdapter;

    /// @param tokenizer_ The tokenizer this factory serves; it deploys the factory and passes itself.
    /// @param positionManager_ The Uniswap v4 PositionManager; must have code.
    /// @param splitterCodeHash_ The runtime code hash of a pools.trade fee splitter; not zero.
    constructor(address tokenizer_, address positionManager_, bytes32 splitterCodeHash_) {
        if (tokenizer_ == address(0)) revert TokenizerZero();
        if (positionManager_.code.length == 0 || splitterCodeHash_ == bytes32(0)) revert InvalidSplitterPins();
        tokenizer = tokenizer_;
        positionManager = positionManager_;
        splitterCodeHash = splitterCodeHash_;
    }

    /// @inheritdoc IHookrFeebAdapterFactory
    function createFor(
        address depositor,
        address revenueToken,
        address vault,
        uint256 tokenId,
        uint64 unlockAt,
        bytes32 salt
    ) external returns (address adapter) {
        if (msg.sender != tokenizer) revert OnlyTokenizer();
        adapter = address(
            new HookrFeebAdapter{salt: _salt(depositor, salt)}(
                revenueToken, vault, tokenId, depositor, unlockAt, positionManager, splitterCodeHash
            )
        );
        IBeneficiaryVault(vault).transferFrom(depositor, adapter, tokenId);
        address owner = IBeneficiaryVault(vault).ownerOf(tokenId);
        if (owner != adapter) revert IHookrFeebAdapter.NotBound(owner);
        isAdapter[adapter] = true;
        emit AdapterCreated(adapter, depositor, revenueToken, vault, tokenId, unlockAt, salt);
    }

    /// @inheritdoc IHookrFeebAdapterFactory
    function predict(
        address depositor,
        address revenueToken,
        address vault,
        uint256 tokenId,
        uint64 unlockAt,
        bytes32 salt
    ) external view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(HookrFeebAdapter).creationCode,
                abi.encode(revenueToken, vault, tokenId, depositor, unlockAt, positionManager, splitterCodeHash)
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
