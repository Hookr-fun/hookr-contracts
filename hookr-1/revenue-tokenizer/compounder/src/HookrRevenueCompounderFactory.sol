// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHookrRevenueToken} from "tokenizer/interfaces/IHookrRevenueToken.sol";
import {IHookrRevenueTokenizer} from "tokenizer/interfaces/IHookrRevenueTokenizer.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {HookrRevenueCompounder} from "./HookrRevenueCompounder.sol";
import {HookrCodeStore} from "./libraries/HookrCodeStore.sol";
import {IHookrRevenueCompounderFactory} from "./interfaces/IHookrRevenueCompounderFactory.sol";

/// @title Hookr revenue compounder factory
/// @notice One compounder per revenue token (IHookrRevenueCompounderFactory). Anyone opens a token's compounder on the
///         token's own market pool with the default terms; the token's creator may instead fix another pool the token
///         is in, and the terms, provided the pool's hook cannot keep what is added to or removed from it. The
///         compounder's shares are named after the token: "Compounding <name>", "c<symbol>".
/// @dev No owner. The tokenizer and the PoolManager are pinned at deployment; the launcher is the tokenizer's. The
///      compounder's creation code is larger than one contract may be, so the factory writes it to code chunks when it
///      is deployed (HookrCodeStore) and deploys every compounder from them; nothing about a compounder depends on the
///      factory once it exists.
contract HookrRevenueCompounderFactory is IHookrRevenueCompounderFactory {
    using PoolIdLibrary for PoolKey;
    using Hooks for IHooks;

    /// @inheritdoc IHookrRevenueCompounderFactory
    int24 public constant DEFAULT_BAND_TICKS = 600;
    /// @inheritdoc IHookrRevenueCompounderFactory
    uint16 public constant DEFAULT_TIP_BPS = 50;
    /// @inheritdoc IHookrRevenueCompounderFactory
    uint128 public constant DEFAULT_TIP_CAP = 0.01 ether;

    /// @inheritdoc IHookrRevenueCompounderFactory
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrRevenueCompounderFactory
    IHookrRevenueTokenizer public immutable tokenizer;
    /// @inheritdoc IHookrRevenueCompounderFactory
    IHookrLauncher public immutable launcher;

    /// @inheritdoc IHookrRevenueCompounderFactory
    mapping(address token => address vault) public vaultOf;
    address[] private _vaults;
    address[] private _code;

    /// @param manager The PoolManager.
    /// @param tokenizer_ The tokenizer whose tokens this factory serves.
    constructor(IPoolManager manager, IHookrRevenueTokenizer tokenizer_) {
        if (address(manager).code.length == 0 || address(tokenizer_).code.length == 0) revert InvalidConfig();
        address launcher_ = tokenizer_.launcher();
        if (launcher_.code.length == 0) revert InvalidConfig();
        poolManager = manager;
        tokenizer = tokenizer_;
        launcher = IHookrLauncher(launcher_);
        _code = HookrCodeStore.write(type(HookrRevenueCompounder).creationCode);
    }

    /// @inheritdoc IHookrRevenueCompounderFactory
    function create(address token) external returns (address vault) {
        IHookrRevenueTokenizer.Tokenization memory record = tokenizer.tokenizations(token);
        if (record.creator == address(0)) revert NotTokenized(token);
        if (record.marketFamilyId == bytes32(0)) revert NoMarket(token);
        PoolKey memory key = launcher.position(record.marketFamilyId, 0).key;
        return _create(token, record.creator, key, DEFAULT_BAND_TICKS, DEFAULT_TIP_BPS, DEFAULT_TIP_CAP);
    }

    /// @inheritdoc IHookrRevenueCompounderFactory
    function createWithPool(address token, PoolKey calldata key, int24 bandTicks, uint16 tipBps, uint128 tipCap)
        external
        returns (address vault)
    {
        IHookrRevenueTokenizer.Tokenization memory record = tokenizer.tokenizations(token);
        if (record.creator == address(0)) revert NotTokenized(token);
        if (msg.sender != record.creator) revert NotCreator(msg.sender);
        // A hook that returns a delta after an add or a removal can keep part of what the vault places or takes out.
        // Only the market family's own root, which the launcher vouches for, may have that permission.
        if (
            key.hooks.hasPermission(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
                || key.hooks.hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) {
            bool root = record.marketFamilyId != bytes32(0)
                && address(launcher.position(record.marketFamilyId, 0).key.hooks) == address(key.hooks);
            if (!root) revert UnsafeHook(address(key.hooks));
        }
        return _create(token, record.creator, key, bandTicks, tipBps, tipCap);
    }

    /// @inheritdoc IHookrRevenueCompounderFactory
    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    /// @inheritdoc IHookrRevenueCompounderFactory
    function vaultAt(uint256 i) external view returns (address) {
        return _vaults[i];
    }

    /// @inheritdoc IHookrRevenueCompounderFactory
    function codeChunks() external view returns (address[] memory) {
        return _code;
    }

    /// @dev Deploys the compounder from the stored creation code with these terms; the compounder's constructor
    ///      checks the pool and the terms, and its revert reaches the caller.
    function _create(address token, address creator, PoolKey memory key, int24 bandTicks, uint16 tipBps, uint128 tipCap)
        private
        returns (address vault)
    {
        address existing = vaultOf[token];
        if (existing != address(0)) revert VaultExists(token, existing);
        IERC20Metadata meta = IERC20Metadata(token);
        bytes memory code = abi.encodePacked(
            HookrCodeStore.read(_code),
            abi.encode(
                poolManager,
                IHookrRevenueToken(token),
                key,
                bandTicks,
                tipBps,
                tipCap,
                string.concat("Compounding ", meta.name()),
                string.concat("c", meta.symbol()),
                creator
            )
        );
        assembly ("memory-safe") {
            vault := create(0, add(code, 32), mload(code))
            if iszero(vault) {
                let size := returndatasize()
                let reason := mload(0x40)
                returndatacopy(reason, 0, size)
                revert(reason, size)
            }
        }
        vaultOf[token] = vault;
        _vaults.push(vault);
        emit CompounderCreated(token, vault, key.toId(), bandTicks, tipBps, tipCap, msg.sender);
    }
}
