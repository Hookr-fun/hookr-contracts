// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHookrModuleV1} from "hookr/interfaces/IHookrModuleV1.sol";
import {HookrModuleTypesV1} from "hookr/libraries/HookrModuleTypesV1.sol";

/// @notice The one read this module needs from an ERC-8470 Token Launch Observations registry.
/// @dev `observationId` is the detector's latest observation of `token` (0 when it has none). `value`
///      is the finding of `kind`/`param` inside that observation, or `type(uint256).max` when that
///      observation does not carry it. Shares are basis points of total supply, 0..10,000.
interface ILaunchObservationsReader {
    enum Lean {
        None,
        Clear,
        Careful,
        Against
    }

    function latestFinding(uint256 chainId, address token, address detector, bytes32 kind, uint64 param)
        external
        view
        returns (uint256 observationId, uint64 observedBlock, uint64 recordedAt, uint256 value, Lean lean);
}

/// @title Toll Launch Check Module
/// @notice A read-only policy module that refuses buys of a pool's subject token when one detector's
///         ERC-8470 observation of that token's launch is over the limits the pool's config sets, for
///         a window of `activeForBlocks` blocks; after the window it allows every buy, for good. It
///         never refuses a sell, takes nothing and adds no fee.
/// @dev A refusal is a revert from `beforeSwap`; the accounting kernel turns a failed module call
///      into `ModuleCallFailed(moduleId, phase, keccak256(revertData))`, so the swap does not happen.
///      The registry and the detector are constructor immutables, so they are part of the runtime
///      code the catalog would pin. The thresholds are the per-pool config, validated at stack
///      creation. The module reads only the pinned detector's findings: the registry keys every
///      observation by the address that wrote it.
contract TollLaunchCheckModule is IHookrModuleV1 {
    struct Config {
        bytes32 poolId;
        address kernel;
        address subject;
        address quote;
        /// @dev Refuse a buy when more than this share of supply was bought in the token's first
        ///      block, in bps. 0 turns the limit off.
        uint16 maxFirstBlockBps;
        /// @dev Refuse a buy when more than this share of supply sits with wallets that share a
        ///      funding source, in bps. 0 turns the limit off.
        uint16 maxFundingLinkedBps;
        /// @dev What a buy does while the detector has not observed the token: true refuses it.
        bool blockUnread;
        /// @dev The first block of the check's window, in `block.number`. `validateStack` refuses a
        ///      start after the block the stack is created in.
        uint64 startBlock;
        /// @dev The window's length in blocks: the check applies while
        ///      `block.number < startBlock + activeForBlocks` and never after. 0 is invalid, so every
        ///      pool's check has an end.
        uint32 activeForBlocks;
    }

    bytes32 public constant MODULE_KEY = keccak256("LABS_TOLL_LAUNCH_CHECK");
    uint32 public constant MODULE_VERSION = 2;
    bytes32 public constant CONFIG_SCHEMA_HASH = keccak256(
        "labs.toll-launch-check.config.v2:" "(bytes32 poolId,address kernel,address subject,address quote,"
        "uint16 maxFirstBlockBps,uint16 maxFundingLinkedBps,bool blockUnread,uint64 startBlock,"
        "uint32 activeForBlocks)"
    );

    bytes32 public constant FIRST_BLOCK_SHARE = keccak256("erc.launch-observations.first-block-share");
    bytes32 public constant FUNDING_LINKED_SHARE = keccak256("erc.launch-observations.funding-linked-share");
    /// @dev The `param` each finding is written under by the detector this module pins.
    uint64 public constant FIRST_BLOCK_PARAM = 0;
    uint64 public constant FUNDING_LINKED_PARAM = 1;

    uint256 public constant NOT_READ = type(uint256).max;
    uint16 public constant MAX_BPS = 10_000;

    /// @dev Reasons carried by `LaunchCheckRefused`.
    bytes32 public constant NOT_OBSERVED = "not-observed";
    bytes32 public constant FIRST_BLOCK = "first-block-share";
    bytes32 public constant FUNDING_LINKED = "funding-linked-share";
    /// @dev Reason `check` returns, with `allowed` true, once the window has ended.
    bytes32 public constant EXPIRED = "expired";

    ILaunchObservationsReader public immutable registry;
    address public immutable detector;

    error InvalidConfig();
    error ConfigNotForThisStack();
    error InvalidDeployment();
    /// @notice A buy refused by the policy. `value` is the share in bps that tripped the limit, or 0
    ///         for `NOT_OBSERVED`.
    error LaunchCheckRefused(address token, bytes32 reason, uint256 value);

    constructor(ILaunchObservationsReader registry_, address detector_) {
        if (address(registry_) == address(0) || detector_ == address(0)) revert InvalidDeployment();
        registry = registry_;
        detector = detector_;
    }

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
    /// @dev The module asks the kernel for nothing, so every cap is zero. The stack is created in
    ///      this block, so the window may not start after it and must still be open in it: the check
    ///      ends at the latest `activeForBlocks` blocks after the stack is created.
    function validateStack(bytes32 poolId, address kernel, address subject, address quote, bytes calldata config)
        external
        view
        returns (HookrModuleTypesV1.ModuleConfigCaps memory caps)
    {
        Config memory c = _decode(config);
        if (c.poolId != poolId || c.kernel != kernel || c.subject != subject || c.quote != quote) {
            revert ConfigNotForThisStack();
        }
        if (c.startBlock > block.number || block.number >= _end(c)) revert InvalidConfig();
        caps.configHash = keccak256(config);
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
    /// @dev A sell returns before the config is decoded or the registry is read, so no config and no
    ///      registry state can make it revert here. A buy at or after the window's end returns before
    ///      the registry is read. A buy that passes returns an all-zero result.
    function beforeSwap(HookrModuleTypesV1.SwapContext calldata context, bytes calldata config)
        external
        view
        returns (HookrModuleTypesV1.ModuleResult memory result)
    {
        if (!context.isBuy) return result;
        Config memory c = _decode(config);
        (bool allowed, bytes32 reason, uint256 value) = _check(context.subject, c);
        if (!allowed) revert LaunchCheckRefused(context.subject, reason, value);
    }

    /// @inheritdoc IHookrModuleV1
    function afterSwap(HookrModuleTypesV1.AfterSwapContext calldata, bytes calldata)
        external
        pure
        returns (HookrModuleTypesV1.ModuleResult memory result)
    {
        return result;
    }

    /// @notice The decision `beforeSwap` takes for a buy of `token` under `c`, without reverting.
    function check(address token, Config calldata c)
        external
        view
        returns (bool allowed, bytes32 reason, uint256 value)
    {
        return _check(token, c);
    }

    /// @dev "Observed" means the detector has any observation of the token. Inside its latest
    ///      observation a finding the detector did not read (`NOT_READ`) counts neither way. The
    ///      first-block share is checked before the funding-linked share. From the window's end on,
    ///      every buy is allowed without a read.
    function _check(address token, Config memory c) internal view returns (bool, bytes32, uint256) {
        if (block.number >= _end(c)) return (true, EXPIRED, 0);
        (uint256 observationId,,, uint256 firstBlock,) =
            registry.latestFinding(block.chainid, token, detector, FIRST_BLOCK_SHARE, FIRST_BLOCK_PARAM);
        if (observationId == 0) return (!c.blockUnread, NOT_OBSERVED, 0);
        if (c.maxFirstBlockBps != 0 && firstBlock != NOT_READ && firstBlock > c.maxFirstBlockBps) {
            return (false, FIRST_BLOCK, firstBlock);
        }
        if (c.maxFundingLinkedBps != 0) {
            (,,, uint256 linked,) =
                registry.latestFinding(block.chainid, token, detector, FUNDING_LINKED_SHARE, FUNDING_LINKED_PARAM);
            if (linked != NOT_READ && linked > c.maxFundingLinkedBps) return (false, FUNDING_LINKED, linked);
        }
        return (true, bytes32(0), 0);
    }

    /// @dev The first block at which the check no longer applies.
    function _end(Config memory c) internal pure returns (uint256) {
        return uint256(c.startBlock) + c.activeForBlocks;
    }

    /// @dev Canonical decoding: the bytes must re-encode to themselves, and every bound that does not
    ///      depend on the block is checked here. A share is at most 10,000 bps, so a limit of 10,000
    ///      or more could never trip and is rejected, as is a config that can never refuse anything
    ///      and a window of 0 blocks or one that starts at block 0.
    function _decode(bytes calldata config) internal pure returns (Config memory c) {
        c = abi.decode(config, (Config));
        if (
            keccak256(abi.encode(c)) != keccak256(config) || c.poolId == bytes32(0) || c.kernel == address(0)
                || c.subject == address(0) || c.subject == c.quote || c.maxFirstBlockBps >= MAX_BPS
                || c.maxFundingLinkedBps >= MAX_BPS
                || (c.maxFirstBlockBps == 0 && c.maxFundingLinkedBps == 0 && !c.blockUnread) || c.startBlock == 0
                || c.activeForBlocks == 0
        ) revert InvalidConfig();
    }
}
