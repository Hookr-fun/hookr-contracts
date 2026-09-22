// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IHookrArbExecutorV3} from "./interfaces/IHookrArbExecutorV3.sol";
import {IHookrExecutionClockV1} from "./interfaces/IHookrExecutionClockV1.sol";
import {IHookrKernelIntegrationV1} from "./interfaces/IHookrKernelIntegrationV1.sol";
import {IHookrStackRegistryV1} from "./interfaces/IHookrStackRegistryV1.sol";
import {IWthArbitrageExecutorV1} from "./interfaces/IWthArbitrageExecutorV1.sol";
import {HookrArbTypesV3} from "./libraries/HookrArbTypesV3.sol";
import {HookrModuleTypesV1} from "./libraries/HookrModuleTypesV1.sol";
import {HookrWthFeePolicyV2} from "./libraries/HookrWthFeePolicyV2.sol";

/// @title Hookr WTH Executor Adapter V1
/// @notice The single boundary between a Hookr root hook and WTH's own arbitrage executor.
/// @dev The hook speaks IHookrArbExecutorV3 and the stack registry admits correction executors
///      only if they answer IHookrKernelIntegrationV1. WTH's contract does neither, so this
///      adapter answers both and forwards a narrowed call. It is the address WTH hardcodes as
///      their approved caller.
///
///      What it deliberately does not do: it holds no funds (it has no receive, no fallback and no
///      payable function), it keeps no accounting, and it never decides how much profit exists.
///      WTH's executor pays every recipient directly. `maxArbVolumeBps` and `poolMinProfitQuote`
///      are frozen per pool by the registry and are passed to this adapter, but WTH's interface
///      takes neither, so they are not enforced here: sizing and the profit floor are WTH's.
contract HookrWthExecutorAdapterV1 is IHookrArbExecutorV3, IHookrKernelIntegrationV1 {
    using PoolIdLibrary for PoolKey;

    bytes32 public constant INTEGRATION_KIND = keccak256("HOOKR_KERNEL_INTEGRATION_CORRECTION_EXECUTOR");
    bytes32 public constant INTEGRATION_FAMILY_ID = keccak256("HOOKR_SWAP_DELTA_V1");
    uint32 public constant INTEGRATION_VERSION = 1;

    /// @notice The three shares the hook names. WTH keeps the remaining 2000 bps internally.
    uint256 public constant SPLIT_TOTAL_BPS = 8_000;

    /// @dev Ceiling on the gas handed to WTH's executor, plus what this adapter keeps back so it
    ///      can always return or bubble a revert. The correction library calls this adapter with a
    ///      2.5m stipend and reserves 800k for the outer swap's own settlement; capping the inner
    ///      call below that stipend means a misbehaving executor cannot consume the reserve.
    uint256 public constant EXECUTOR_CALL_GAS_LIMIT = 2_200_000;
    uint256 public constant ADAPTER_GAS_RESERVE = 60_000;

    IPoolManager public immutable poolManager;
    IHookrStackRegistryV1 public immutable stackRegistry;
    IHookrExecutionClockV1 public immutable executionClock;

    address public owner;
    address public pendingOwner;
    /// @notice WTH's executor. Settable exactly once, by the owner, and immutable afterwards.
    address public wthExecutor;

    event OwnerProposed(address indexed nextOwner);
    event OwnerSet(address indexed owner);
    event ExecutorSet(address indexed executor);

    error ZeroAddress();
    error NotOwner();
    error NotPendingOwner();
    error ExecutorAlreadySet();
    error ExecutorNotSet();
    error NotTargetHook();
    error NotRegisteredKernel();
    error BadSplit();
    error BadExecutorReturn();
    error InsufficientGas();
    error InvalidExecutionClock();
    error ExecutorCallFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address owner_,
        IPoolManager poolManager_,
        IHookrStackRegistryV1 stackRegistry_,
        IHookrExecutionClockV1 executionClock_
    ) {
        if (
            owner_ == address(0) || address(poolManager_) == address(0) || address(poolManager_).code.length == 0
                || address(stackRegistry_) == address(0) || address(stackRegistry_).code.length == 0
                || address(executionClock_) == address(0) || address(executionClock_).code.length == 0
        ) revert ZeroAddress();
        try executionClock_.executionBlockNumber() returns (uint64) {}
        catch {
            revert InvalidExecutionClock();
        }
        owner = owner_;
        poolManager = poolManager_;
        stackRegistry = stackRegistry_;
        executionClock = executionClock_;
        emit OwnerSet(owner_);
    }

    function contractName() external pure returns (string memory) {
        return "HookrWthExecutorAdapterV1";
    }

    function contractVersion() external pure returns (string memory) {
        return "1.1.0";
    }

    // -----------------------------------------------------------------------------------------
    // Ownership
    // -----------------------------------------------------------------------------------------

    function proposeOwner(address nextOwner) external onlyOwner {
        if (nextOwner == address(0) || nextOwner == owner) revert ZeroAddress();
        pendingOwner = nextOwner;
        emit OwnerProposed(nextOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnerSet(msg.sender);
    }

    /// @notice Binds WTH's executor. One shot: the destination can never be moved afterwards.
    function setExecutorOnce(address executor_) external onlyOwner {
        if (wthExecutor != address(0)) revert ExecutorAlreadySet();
        if (executor_ == address(0) || executor_.code.length == 0) revert ZeroAddress();
        wthExecutor = executor_;
        emit ExecutorSet(executor_);
    }

    // -----------------------------------------------------------------------------------------
    // IHookrKernelIntegrationV1
    // -----------------------------------------------------------------------------------------

    function integrationKind() external pure returns (bytes32) {
        return INTEGRATION_KIND;
    }

    function integrationFamilyId() external pure returns (bytes32) {
        return INTEGRATION_FAMILY_ID;
    }

    function integrationVersion() external pure returns (uint32) {
        return INTEGRATION_VERSION;
    }

    /// @notice Read by HookrStackRegistryV1._validateLimits before a pool may name this adapter.
    function feePolicyId() external pure returns (bytes32) {
        return HookrWthFeePolicyV2.FEE_POLICY_ID;
    }

    // -----------------------------------------------------------------------------------------
    // IHookrArbExecutorV3
    // -----------------------------------------------------------------------------------------

    /// @notice Always open. Admission is WTH's to decide inside their own executor.
    function routeAdmissionOpen() external pure returns (bool) {
        return true;
    }

    /// @notice The same execution height the reviewed Hookr executor reads, from the same clock.
    function executionBlockNumber() external view returns (uint64) {
        return executionClock.executionBlockNumber();
    }

    /// @notice Forwards one correction to WTH's executor.
    /// @dev Callable only by the frozen root hook of a pool this adapter is the correction executor
    ///      for. Every failure reverts, and the calling hook's try/catch turns that into a
    ///      CorrectionAttempt event rather than a failed user swap. There is no MEV pre-check: a
    ///      revert from the executor can only skip the correction on this side, never break the
    ///      user's swap, so the extra external call would buy nothing.
    function executeArbitrage(HookrArbTypesV3.ExecutionRequest calldata request)
        external
        returns (uint256 realizedProfitQuote, bytes32 planDigest)
    {
        address executor = wthExecutor;
        if (executor == address(0)) revert ExecutorNotSet();

        HookrModuleTypesV1.StackCore memory core = _checkedCaller(request.targetKey);
        IWthArbitrageExecutorV1.ProfitSplit memory split = _checkedSplit(request, core);


        uint256 available = gasleft();
        if (available <= ADAPTER_GAS_RESERVE) revert InsufficientGas();
        uint256 forwarded = available - ADAPTER_GAS_RESERVE;
        if (forwarded > EXECUTOR_CALL_GAS_LIMIT) forwarded = EXECUTOR_CALL_GAS_LIMIT;

        (bool ok, bytes memory returned) = executor.call{gas: forwarded}(
            abi.encodeCall(
                IWthArbitrageExecutorV1.executeArbitrage, (request.targetKey, request.rebateRecipient, split)
            )
        );
        if (!ok) _bubble(returned);
        if (returned.length != 32) revert BadExecutorReturn();
        realizedProfitQuote = abi.decode(returned, (uint256));
        planDigest = keccak256(abi.encode(request.targetKey, request.rebateRecipient, split));
    }

    // -----------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------

    /// @dev The caller must be the pool's own frozen root hook, registered in this adapter's kernel
    ///      family, with this adapter named as that pool's correction executor.
    function _checkedCaller(PoolKey calldata targetKey)
        internal
        view
        returns (HookrModuleTypesV1.StackCore memory core)
    {
        if (msg.sender != address(targetKey.hooks)) revert NotTargetHook();
        core = stackRegistry.stack(targetKey.toId());
        if (
            !core.configured || !core.initialized || core.kernel != msg.sender
                || core.kernelCodeHash != msg.sender.codehash || core.kernelFamilyId != INTEGRATION_FAMILY_ID
                || core.subject == address(0) || core.subject == core.quote
                || core.limits.correctionExecutor != address(this)
                || core.correctionExecutorIntegrationId == bytes32(0)
                || core.correctionExecutorCodeHash != address(this).codehash
                || core.limits.correctionFeePolicyId != HookrWthFeePolicyV2.FEE_POLICY_ID
        ) revert NotRegisteredKernel();
    }

    /// @dev Restates WTH's own stated rules at the boundary so a malformed split never reaches
    ///      them: the three named shares sum to 8000, no trader share without a trader, and no
    ///      creator share without the pool's frozen creator.
    function _checkedSplit(HookrArbTypesV3.ExecutionRequest calldata request, HookrModuleTypesV1.StackCore memory core)
        internal
        pure
        returns (IWthArbitrageExecutorV1.ProfitSplit memory split)
    {
        HookrArbTypesV3.ProfitSplit calldata source = request.profitSplit;
        if (
            uint256(source.traderBps) + source.creatorBps + source.triggerPoolBps != SPLIT_TOTAL_BPS
                || (request.rebateRecipient == address(0) && source.traderBps != 0)
                || (source.creator == address(0) && source.creatorBps != 0)
                || source.creator != core.limits.correctionCreator
        ) revert BadSplit();
        split = IWthArbitrageExecutorV1.ProfitSplit({
            creator: source.creator,
            traderBps: source.traderBps,
            creatorBps: source.creatorBps,
            triggerPoolBps: source.triggerPoolBps
        });
    }

    function _bubble(bytes memory reason) internal pure {
        if (reason.length == 0) revert ExecutorCallFailed();
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
