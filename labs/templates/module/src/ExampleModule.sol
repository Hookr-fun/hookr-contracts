// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHookrModuleV1} from "hookr/interfaces/IHookrModuleV1.sol";
import {HookrModuleTypesV1} from "hookr/libraries/HookrModuleTypesV1.sol";

/// @title Example Module
/// @notice A read-only policy module in the shape the catalog admits: a surcharge on the LP fee for
///         buys, and a quote-side take on exact-input buys credited to one recipient.
/// @dev Read-only modules are called by STATICCALL and return a `ModuleResult`; the accounting
///      kernel bounds what they ask for against the pool's frozen caps and executes it. The config
///      is ABI-encoded `Config`, validated at stack creation (`validateStack`) so a mismatch is
///      found when the market opens rather than on its first swap. Copy this file, rename the
///      module key and the schema string, and change what `beforeSwap` and `afterSwap` return.
contract ExampleModule is IHookrModuleV1 {
    struct Config {
        bytes32 poolId;
        address kernel;
        address subject;
        address quote;
        /// @dev Added to the LP fee on every buy, in pips (1e6 = 100%).
        uint24 buySurchargePips;
        /// @dev Taken off the specified quote leg of an exact-input buy, in bps, credited to
        ///      `claimRecipient` as an ERC-6909 claim by the kernel.
        uint16 buyTakeBps;
        address claimRecipient;
    }

    bytes32 public constant MODULE_KEY = keccak256("LABS_EXAMPLE_MODULE");
    uint32 public constant MODULE_VERSION = 1;
    bytes32 public constant CONFIG_SCHEMA_HASH = keccak256(
        "labs.example-module.config.v1:" "(bytes32 poolId,address kernel,address subject,address quote,"
        "uint24 buySurchargePips,uint16 buyTakeBps,address claimRecipient)"
    );

    /// @dev The most this implementation will ever ask for. A registration must cover these; the
    ///      template keeps both far below the catalog's current maxima (500,000 pips and 4,000 bps).
    uint24 public constant MAX_BUY_SURCHARGE_PIPS = 50_000;
    uint16 public constant MAX_BUY_TAKE_BPS = 100;

    error InvalidConfig();
    error ConfigNotForThisStack();

    function moduleKey() external pure returns (bytes32) {
        return MODULE_KEY;
    }

    function moduleVersion() external pure returns (uint32) {
        return MODULE_VERSION;
    }

    function configSchemaHash() external pure returns (bytes32) {
        return CONFIG_SCHEMA_HASH;
    }

    /// @inheritdoc IHookrModuleV1
    function validateConfig(bytes calldata config) external pure returns (bytes32 configHash) {
        _decode(config);
        configHash = keccak256(config);
    }

    /// @inheritdoc IHookrModuleV1
    function validateStack(bytes32 poolId, address kernel, address subject, address quote, bytes calldata config)
        external
        pure
        returns (HookrModuleTypesV1.ModuleConfigCaps memory caps)
    {
        Config memory c = _decode(config);
        if (c.poolId != poolId || c.kernel != kernel || c.subject != subject || c.quote != quote) {
            revert ConfigNotForThisStack();
        }
        caps = HookrModuleTypesV1.ModuleConfigCaps({
            configHash: keccak256(config),
            maxLpFeeSurchargePips: c.buySurchargePips,
            maxSpecifiedQuoteTakeBps: c.buyTakeBps,
            maxUnspecifiedQuoteTakeBps: 0,
            maxSubjectTakeBps: 0
        });
    }

    /// @inheritdoc IHookrModuleV1
    function beforeAddLiquidity(HookrModuleTypesV1.LiquidityContext calldata, bytes calldata)
        external
        pure
        returns (bool allowed)
    {
        return true;
    }

    /// @inheritdoc IHookrModuleV1
    function beforeSwap(HookrModuleTypesV1.SwapContext calldata context, bytes calldata config)
        external
        pure
        returns (HookrModuleTypesV1.ModuleResult memory result)
    {
        Config memory c = _decode(config);
        if (!context.isBuy) return result;
        result.lpFeeSurchargePips = c.buySurchargePips;
        if (context.exactInput && c.buyTakeBps != 0) {
            result.quoteTakeBps = c.buyTakeBps;
            result.claimRecipient = c.claimRecipient;
            result.attributionKey = MODULE_KEY;
        }
    }

    /// @inheritdoc IHookrModuleV1
    function afterSwap(HookrModuleTypesV1.AfterSwapContext calldata, bytes calldata)
        external
        pure
        returns (HookrModuleTypesV1.ModuleResult memory result)
    {
        return result;
    }

    /// @dev Canonical decoding: the bytes must re-encode to themselves, so two encodings of one
    ///      config cannot hash differently, and every bound is checked here and nowhere else.
    function _decode(bytes calldata config) internal pure returns (Config memory c) {
        c = abi.decode(config, (Config));
        if (
            keccak256(abi.encode(c)) != keccak256(config) || c.poolId == bytes32(0) || c.kernel == address(0)
                || c.subject == address(0) || c.subject == c.quote || c.buySurchargePips > MAX_BUY_SURCHARGE_PIPS
                || c.buyTakeBps > MAX_BUY_TAKE_BPS || (c.buyTakeBps != 0 && c.claimRecipient == address(0))
                || (c.buyTakeBps == 0 && c.claimRecipient != address(0))
        ) revert InvalidConfig();
    }
}
