// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "hookr-1/src/types/HookrTypes.sol";
import {IHookrAdvisory} from "hookr-1/src/interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "hookr-1/src/interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "hookr-1/src/interfaces/IHookrRoot.sol";

/// @notice The one read this advisory makes of an ERC-8470 Token Launch Observations registry.
/// @dev `observationId` is the detector's latest observation of `token` (0 when it has none). `value` is the finding
///      of `kind`/`param` inside that observation, or `type(uint256).max` when that observation does not carry it.
///      Shares are basis points of total supply, 0..10,000.
interface ILaunchObservationsReader {
    function latestFinding(uint256 chainId, address token, address detector, bytes32 kind, uint64 param)
        external
        view
        returns (uint256 observationId, uint64 observedBlock, uint64 recordedAt, uint256 value, uint8 lean);
}

/// @title TollLaunchCheckAdvisory
/// @notice A HookrRoot advisory that rejects buys of a pool's subject token while one detector's ERC-8470
///         observation of that token's launch is over the pool's limits, for the first `activeForBlocks` blocks
///         after the pool binds it. After that window it never rejects again. It never rejects a sell, never adds an
///         LP fee and never takes anything.
/// @dev Copied from TemplateAdvisory's structure: no owner, no storage other than the bindings, no upgrade path, no
///      DELEGATECALL. Bindings are keyed by the calling root. The registry and the detector are immutables, so they
///      are part of the runtime code the registry admits by code hash.
///
///      HookrRoot honours `reject` only from a fail-closed binding: `HookrRoot._advice` reverts InvalidModuleResult
///      when a fail-open advisory returns `reject`, and a fail-closed binding reverts the swap when the advisory call
///      reverts, runs out of gas or answers in the wrong shape. So this advisory is meant to be bound fail-closed, and
///      nothing on its swap path reverts: a registry call that reverts, runs out of the gas this advisory gives it or
///      answers short counts as "not observed", which rejects only when the pool set `blockUnread`. On a fail-open
///      binding it returns zero advice on every swap (it accepts the binding, but can never reject there).
contract TollLaunchCheckAdvisory is IHookrAdvisory {
    using PoolIdLibrary for PoolKey;

    /// @notice The bind data, `abi.encode(Config)`, exactly 128 bytes.
    /// @param maxFirstBlockBps Reject a buy when more than this share of supply was bought in the token's first block,
    ///        in bps. 0 turns the limit off; otherwise 1..9,999.
    /// @param maxFundingLinkedBps Reject a buy when more than this share of supply sits with wallets that share a
    ///        funding source, in bps. 0 turns the limit off; otherwise 1..9,999.
    /// @param blockUnread Whether a buy is rejected while the detector has not observed the token.
    /// @param activeForBlocks The window's length in `block.number` blocks from the bind. Not 0.
    struct Config {
        uint16 maxFirstBlockBps;
        uint16 maxFundingLinkedBps;
        bool blockUnread;
        uint32 activeForBlocks;
    }

    /// @notice One pool's frozen settings. One storage slot.
    /// @param activeUntilBlock The first block in which the check no longer applies: the bind block plus
    ///        `activeForBlocks`.
    /// @param failOpen Whether the pool bound this advisory fail-open; such a binding never rejects.
    struct Binding {
        uint64 activeUntilBlock;
        uint16 maxFirstBlockBps;
        uint16 maxFundingLinkedBps;
        bool blockUnread;
        bool failOpen;
        bool bound;
    }

    /// @notice Smallest advisory gas limit a HookrRoot pool may bind with. The root forwards the same limit to `bind`
    ///         and to every `beforeSwap`. A read that runs out of the gas it is given counts as "not observed", so
    ///         the limit must cover the most expensive buy: both registry reads scanning an observation of the
    ///         registry's maximum of 32 findings, every one of them a funding-linked share, cold. The fork test
    ///         measures that at 188,079 gas against the live registry; this leaves about a third more.
    uint32 public constant MIN_ADVISORY_GAS = 250_000;
    /// @notice Gas each registry read leaves to this advisory, so it can always return its answer.
    uint256 public constant READ_RESERVE = 5_000;

    bytes32 public constant CONFIG_SCHEMA = keccak256(
        "labs.toll-launch-check.advisory.v1:"
        "(uint16 maxFirstBlockBps,uint16 maxFundingLinkedBps,bool blockUnread,uint32 activeForBlocks)"
    );
    bytes32 public constant FIRST_BLOCK_SHARE = keccak256("erc.launch-observations.first-block-share");
    bytes32 public constant FUNDING_LINKED_SHARE = keccak256("erc.launch-observations.funding-linked-share");
    /// @dev The `param` each finding is written under by the detector this advisory pins.
    uint64 public constant FIRST_BLOCK_PARAM = 0;
    uint64 public constant FUNDING_LINKED_PARAM = 1;
    uint256 public constant NOT_READ = type(uint256).max;
    uint16 public constant MAX_BPS = 10_000;

    /// @dev Reasons `check` returns.
    bytes32 public constant NOT_OBSERVED = "not-observed";
    bytes32 public constant FIRST_BLOCK = "first-block-share";
    bytes32 public constant FUNDING_LINKED = "funding-linked-share";
    bytes32 public constant EXPIRED = "expired";
    bytes32 public constant FAIL_OPEN = "fail-open";

    ILaunchObservationsReader public immutable registry;
    address public immutable detector;

    mapping(address binder => mapping(PoolId => Binding)) private _bindings;

    /// @notice Emitted when a root binds a pool.
    event Bound(
        address indexed binder,
        PoolId indexed id,
        uint16 maxFirstBlockBps,
        uint16 maxFundingLinkedBps,
        bool blockUnread,
        uint64 activeUntilBlock,
        bool failOpen
    );

    /// @notice Thrown when the caller binds a pool it already bound.
    error AlreadyBound(address binder, PoolId id);
    /// @notice Thrown when `check` asks for a pool the binder has not bound.
    error UnknownPool(address binder, PoolId id);
    /// @notice Thrown when the bind data or the pool's advisory settings are out of range.
    error InvalidConfig();
    /// @notice Thrown when the registry or the detector is the zero address.
    error InvalidDeployment();

    constructor(ILaunchObservationsReader registry_, address detector_) {
        if (address(registry_) == address(0) || detector_ == address(0)) revert InvalidDeployment();
        registry = registry_;
        detector = detector_;
    }

    /// @inheritdoc IHookrAdvisory
    function configSchemaHash() external pure returns (bytes32) {
        return CONFIG_SCHEMA;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev The caller must be the pool's root, with this contract admitted as an ADVISORY for it, binding it before
    ///      the swap only, with at least MIN_ADVISORY_GAS. The window starts in this block.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32 configHash)
    {
        Config memory c = _decode(data);
        if (
            address(key.hooks) != msg.sender || pc.advisory != address(this)
                || pc.advisoryPhases != HookrTypes.BEFORE_SWAP || pc.advisoryGasLimit < MIN_ADVISORY_GAS
        ) revert InvalidConfig();
        IHookrRegistry.Admission memory a = IHookrRoot(msg.sender).registry().admission(msg.sender, address(this));
        if (a.kind != IHookrRegistry.Kind.ADVISORY || a.implementation != address(this)) revert InvalidConfig();
        PoolId id = key.toId();
        Binding storage b = _bindings[msg.sender][id];
        if (b.bound) revert AlreadyBound(msg.sender, id);
        // At most block.number + 2^32 - 1, far inside uint64.
        uint64 until = uint64(block.number + c.activeForBlocks);
        b.activeUntilBlock = until;
        b.maxFirstBlockBps = c.maxFirstBlockBps;
        b.maxFundingLinkedBps = c.maxFundingLinkedBps;
        b.blockUnread = c.blockUnread;
        b.failOpen = pc.advisoryFailOpen;
        b.bound = true;
        emit Bound(msg.sender, id, c.maxFirstBlockBps, c.maxFundingLinkedBps, c.blockUnread, until, pc.advisoryFailOpen);
        return keccak256(data);
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Liquidity is never restricted.
    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Zero advice for a sell, a pool the caller has not bound, a fail-open binding, and from the window's end
    ///      on, each before the registry is read. A buy inside the window gets `reject` when the check refuses it.
    ///      The surcharge, the take and the recipient are always zero. Nothing here reverts.
    function beforeSwap(HookrTypes.SwapContext calldata context)
        external
        view
        returns (HookrTypes.Advice memory advice)
    {
        if (!context.isBuy) return advice;
        Binding memory b = _bindings[msg.sender][context.id];
        if (!b.bound || b.failOpen || block.number >= b.activeUntilBlock) return advice;
        (bool allowed,,) = _check(Currency.unwrap(context.subject), b);
        advice.reject = !allowed;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Never called: a pool binds this advisory with the BEFORE_SWAP phase only.
    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory advice)
    {
        return advice;
    }

    /// @notice Returns the binding of `id` by `binder`.
    function binding(address binder, PoolId id) external view returns (Binding memory) {
        return _bindings[binder][id];
    }

    /// @notice The decision `beforeSwap` takes now for a buy of `token` on the pool `id` bound by `binder`, with the
    ///         reason and the share that decided it, for a front end or an agent that wants the reason before it
    ///         sends the swap (the root reports a rejection only as SwapRejected).
    function check(address binder, PoolId id, address token)
        external
        view
        returns (bool allowed, bytes32 reason, uint256 value)
    {
        Binding memory b = _bindings[binder][id];
        if (!b.bound) revert UnknownPool(binder, id);
        if (b.failOpen) return (true, FAIL_OPEN, 0);
        if (block.number >= b.activeUntilBlock) return (true, EXPIRED, 0);
        return _check(token, b);
    }

    /// @dev "Observed" means the detector has an observation of the token and the read answered. Inside its latest
    ///      observation a finding it does not carry (`NOT_READ`), or a second read that fails, counts neither way.
    ///      The first-block share is checked before the funding-linked share.
    function _check(address token, Binding memory b) private view returns (bool, bytes32, uint256) {
        (bool ok, uint256 observationId, uint256 firstBlock) = _read(token, FIRST_BLOCK_SHARE, FIRST_BLOCK_PARAM);
        if (!ok || observationId == 0) return (!b.blockUnread, NOT_OBSERVED, 0);
        if (b.maxFirstBlockBps != 0 && firstBlock != NOT_READ && firstBlock > b.maxFirstBlockBps) {
            return (false, FIRST_BLOCK, firstBlock);
        }
        if (b.maxFundingLinkedBps != 0) {
            uint256 linked;
            (ok,, linked) = _read(token, FUNDING_LINKED_SHARE, FUNDING_LINKED_PARAM);
            if (ok && linked != NOT_READ && linked > b.maxFundingLinkedBps) return (false, FUNDING_LINKED, linked);
        }
        return (true, bytes32(0), 0);
    }

    /// @dev One `latestFinding` read as a static call that keeps READ_RESERVE gas back and copies at most the five
    ///      words of its answer. `ok` is false when there is not more than READ_RESERVE gas left, when the call
    ///      reverts or runs out of gas, or when it answers fewer than five words. It never reverts.
    function _read(address token, bytes32 kind, uint64 param)
        private
        view
        returns (bool ok, uint256 observationId, uint256 value)
    {
        address target = address(registry);
        address pinned = detector;
        bytes4 selector = ILaunchObservationsReader.latestFinding.selector;
        uint256 reserve = READ_RESERVE;
        assembly ("memory-safe") {
            let g := gas()
            if gt(g, reserve) {
                let p := mload(0x40)
                mstore(p, selector)
                mstore(add(p, 4), chainid())
                mstore(add(p, 36), token)
                mstore(add(p, 68), pinned)
                mstore(add(p, 100), kind)
                mstore(add(p, 132), param)
                ok := staticcall(sub(g, reserve), target, p, 164, p, 160)
                ok := and(ok, iszero(lt(returndatasize(), 160)))
                if ok {
                    observationId := mload(p)
                    value := mload(add(p, 96))
                }
            }
        }
    }

    /// @dev Canonical decoding of exactly four words: the bytes must re-encode to themselves. A share is at most
    ///      10,000 bps, so a limit of 10,000 or more could never trip; a config that can never reject anything and a
    ///      window of 0 blocks are rejected too.
    function _decode(bytes calldata data) private pure returns (Config memory c) {
        if (data.length != 128) revert InvalidConfig();
        c = abi.decode(data, (Config));
        if (
            keccak256(abi.encode(c)) != keccak256(data) || c.maxFirstBlockBps >= MAX_BPS
                || c.maxFundingLinkedBps >= MAX_BPS
                || (c.maxFirstBlockBps == 0 && c.maxFundingLinkedBps == 0 && !c.blockUnread) || c.activeForBlocks == 0
        ) revert InvalidConfig();
    }
}
