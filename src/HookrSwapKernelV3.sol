// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookrSwapAccountingKernelV3} from "./HookrSwapAccountingKernelV3.sol";
import {IHookrStackRegistryV1} from "./interfaces/IHookrStackRegistryV1.sol";
import {HookrArbTypesV3} from "./libraries/HookrArbTypesV3.sol";
import {HookrCorrectionPayloadV2} from "./libraries/HookrCorrectionPayloadV2.sol";
import {HookrHookDataV1} from "./libraries/HookrHookDataV1.sol";
import {HookrModularCorrectionLibV2} from "./libraries/HookrModularCorrectionLibV2.sol";
import {HookrModuleTypesV1} from "./libraries/HookrModuleTypesV1.sol";

/// @title Hookr Swap Kernel V3
/// @notice Release root combining bounded stateful-module accounting with V2 phase-bound WTH correction.
/// @dev The versioned accounting implementation is executed by DELEGATECALL, preserving the V1/V2
///      mapping-at-slot-zero and callback-sentinel-at-slot-one layout. This root intercepts only
///      beforeSwap/afterSwap to retain V2's correction namespace, phases, nested-callback guard and
///      2.5m-gas fail-open dispatcher. All other selectors delegate to the pinned implementation.
contract HookrSwapKernelV3 {
    using PoolIdLibrary for PoolKey;

    uint160 public constant REQUIRED_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    bytes32 public constant KERNEL_FAMILY_ID = keccak256("HOOKR_SWAP_DELTA_V1");
    bytes32 public constant KERNEL_INSTANCE_LAYOUT_ID = keccak256("HOOKR_KERNEL_INSTANCE_LAYOUT_V1");
    bytes32 public constant STATEFUL_MODULE_MAGIC = keccak256("HOOKR_STATEFUL_SWAP_MODULE_V1");
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;
    uint24 private constant OVERRIDE_FEE_FLAG = 0x400000;
    uint160 public constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 public constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    uint8 private constant CORRECTION_SUCCEEDED = 1;
    uint8 private constant CORRECTION_FAILED = 2;

    // Exact V2 namespace: signed payloads and nested-callback expectations do not change in V3.
    bytes32 private constant CORRECTION_STATE_SLOT = keccak256("hookr.swap.kernel.v2.correction.state");
    bytes32 private constant CORRECTION_EXECUTOR_SLOT = keccak256("hookr.swap.kernel.v2.correction.executor");
    bytes32 private constant CORRECTION_POOL_SLOT = keccak256("hookr.swap.kernel.v2.correction.pool");

    IPoolManager public immutable poolManager;
    IHookrStackRegistryV1 public immutable stackRegistry;
    address public immutable coordinator;
    HookrSwapAccountingKernelV3 public immutable accountingKernel;
    bytes32 public immutable accountingKernelCodeHash;

    struct PreparedSwap {
        PoolId poolId;
        HookrModuleTypesV1.StackCore core;
        address recipient;
        bool trustedCaller;
        bytes delegatedHookData;
        bytes beforeCorrection;
        bytes afterCorrection;
    }

    event CorrectionAttemptSucceeded(
        PoolId indexed poolId, uint8 indexed phase, bytes32 indexed planDigest, uint256 realizedProfitQuote
    );
    event CorrectionAttemptFailed(PoolId indexed poolId, uint8 indexed phase, bytes32 payloadHash, bytes32 reasonHash);
    event CorrectionAttemptSkipped(PoolId indexed poolId, uint8 indexed phase, bytes32 payloadHash, bytes32 reasonHash);

    error InvalidWiring();
    error AccountingKernelCodeChanged(bytes32 expected, bytes32 actual);
    error InvalidStack();
    error ReentrantCallback();
    error DelegateCallFailed();

    constructor(
        IPoolManager poolManager_,
        IHookrStackRegistryV1 stackRegistry_,
        address coordinator_,
        HookrSwapAccountingKernelV3 accountingKernel_
    ) {
        if (
            address(poolManager_) == address(0) || address(poolManager_).code.length == 0
                || address(stackRegistry_) == address(0) || address(stackRegistry_).code.length == 0
                || coordinator_ == address(0) || coordinator_.code.length == 0
                || address(accountingKernel_) == address(0) || address(accountingKernel_).code.length == 0
                || address(accountingKernel_.poolManager()) != address(poolManager_)
                || address(accountingKernel_.stackRegistry()) != address(stackRegistry_)
                || accountingKernel_.coordinator() != coordinator_
                || accountingKernel_.KERNEL_FAMILY_ID() != KERNEL_FAMILY_ID
                || accountingKernel_.kernelInstanceLayoutId() != KERNEL_INSTANCE_LAYOUT_ID
                || accountingKernel_.REQUIRED_FLAGS() != REQUIRED_FLAGS
                || accountingKernel_.statefulModuleKernelMagic() != STATEFUL_MODULE_MAGIC
        ) revert InvalidWiring();
        poolManager = poolManager_;
        stackRegistry = stackRegistry_;
        coordinator = coordinator_;
        accountingKernel = accountingKernel_;
        accountingKernelCodeHash = address(accountingKernel_).codehash;
        // HookrSwapAccountingKernelV3 keeps `_callbackState` in slot one, exactly like V1.
        assembly ("memory-safe") {
            sstore(1, 1)
        }
    }

    function contractName() external pure virtual returns (string memory) {
        return "HookrSwapKernelV3";
    }

    function contractVersion() external pure virtual returns (string memory) {
        return "3.0.0";
    }

    /// @notice Exact storage-layout lineage required by per-market instance factories.
    function kernelInstanceLayoutId() external pure returns (bytes32) {
        return KERNEL_INSTANCE_LAYOUT_ID;
    }

    /// @notice Opt-in lifecycle marker required before a registry may freeze STATEFUL_V1 modules.
    function statefulModuleKernelMagic() external pure returns (bytes32) {
        return STATEFUL_MODULE_MAGIC;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride)
    {
        if (msg.sender != address(poolManager)) _delegateAndReturn();
        if (_tload(CORRECTION_STATE_SLOT) != 0) {
            _checkCorrectionCallback(sender, key, hookData, 1);
            _tstore(CORRECTION_STATE_SLOT, 2);
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, OVERRIDE_FEE_FLAG);
        }

        PreparedSwap memory prepared = _prepare(sender, key, hookData);
        bytes memory output = _delegate(
            abi.encodeWithSelector(IHooks.beforeSwap.selector, sender, key, params, prepared.delegatedHookData)
        );
        (selector, delta, feeOverride) = abi.decode(output, (bytes4, BeforeSwapDelta, uint24));

        uint128 triggerBaseAmount = _preSwapTriggerBase(params, key, prepared.core);
        if (triggerBaseAmount != 0 && prepared.beforeCorrection.length != 0) {
            _tryCorrection(
                prepared.poolId,
                key,
                params.zeroForOne,
                triggerBaseAmount,
                prepared.core,
                prepared.recipient,
                prepared.trustedCaller,
                HookrArbTypesV3.PHASE_BEFORE_SWAP,
                prepared.beforeCorrection
            );
        }
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4 selector, int128 hookDelta) {
        if (msg.sender != address(poolManager)) _delegateAndReturn();
        if (_tload(CORRECTION_STATE_SLOT) != 0) {
            _checkCorrectionCallback(sender, key, hookData, 2);
            _tstore(CORRECTION_STATE_SLOT, 1);
            return (IHooks.afterSwap.selector, 0);
        }

        PreparedSwap memory prepared = _prepare(sender, key, hookData);
        bytes memory output = _delegate(
            abi.encodeWithSelector(IHooks.afterSwap.selector, sender, key, params, delta, prepared.delegatedHookData)
        );
        (selector, hookDelta) = abi.decode(output, (bytes4, int128));

        uint128 triggerBaseAmount = _postSwapTriggerBase(key, delta, prepared.core);
        if (triggerBaseAmount != 0 && prepared.afterCorrection.length != 0) {
            _tryCorrection(
                prepared.poolId,
                key,
                params.zeroForOne,
                triggerBaseAmount,
                prepared.core,
                prepared.recipient,
                prepared.trustedCaller,
                HookrArbTypesV3.PHASE_AFTER_SWAP,
                prepared.afterCorrection
            );
        }
    }

    function _prepare(address sender, PoolKey calldata key, bytes calldata rawHookData)
        internal
        view
        returns (PreparedSwap memory prepared)
    {
        prepared.poolId = key.toId();
        prepared.core = _checkedCore(prepared.poolId, key);
        if (sender == prepared.core.limits.trustedRouter) {
            if (sender.codehash != prepared.core.trustedRouterCodeHash) revert InvalidStack();
            prepared.trustedCaller = true;
        } else if (sender == prepared.core.limits.trustedQuoter) {
            if (sender.codehash != prepared.core.trustedQuoterCodeHash) revert InvalidStack();
            prepared.trustedCaller = true;
        }
        if (!prepared.trustedCaller) {
            prepared.recipient = sender;
            prepared.delegatedHookData = rawHookData;
            return prepared;
        }

        HookrHookDataV1.Envelope memory routerEnvelope = HookrHookDataV1.decode(rawHookData, prepared.core.stackHash);
        prepared.recipient = routerEnvelope.recipient;
        if (routerEnvelope.moduleData.length == 0) {
            prepared.delegatedHookData = HookrHookDataV1.encode(
                routerEnvelope.payer, routerEnvelope.recipient, routerEnvelope.stackHash, bytes("")
            );
            return prepared;
        }

        HookrCorrectionPayloadV2.Envelope memory correction = HookrCorrectionPayloadV2.decode(routerEnvelope.moduleData);
        prepared.beforeCorrection = correction.beforeSwapCorrection;
        prepared.afterCorrection = correction.afterSwapCorrection;
        prepared.delegatedHookData = HookrHookDataV1.encode(
            routerEnvelope.payer,
            routerEnvelope.recipient,
            routerEnvelope.stackHash,
            HookrCorrectionPayloadV2.encodeModulePayload(correction.modulePayload)
        );
    }

    function _preSwapTriggerBase(
        SwapParams calldata params,
        PoolKey calldata key,
        HookrModuleTypesV1.StackCore memory core
    ) internal pure returns (uint128 amount) {
        if (!_isCanonicalFullFillLimit(params.zeroForOne, params.sqrtPriceLimitX96)) return 0;
        bool exactInput = params.amountSpecified < 0;
        address specifiedCurrency = exactInput
            ? (params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1))
            : (params.zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0));
        if (specifiedCurrency != core.subject) return 0;
        int256 raw = params.amountSpecified;
        if (raw == 0 || raw > int256(type(int128).max) || raw < -int256(type(int128).max)) return 0;
        uint256 magnitude = uint256(raw < 0 ? -raw : raw);
        amount = uint128(magnitude);
    }

    function _postSwapTriggerBase(PoolKey calldata key, BalanceDelta delta, HookrModuleTypesV1.StackCore memory core)
        internal
        pure
        returns (uint128 amount)
    {
        int128 raw = core.subject == Currency.unwrap(key.currency0) ? delta.amount0() : delta.amount1();
        if (raw == 0) return 0;
        uint256 magnitude = raw < 0 ? uint256(-int256(raw)) : uint256(int256(raw));
        if (magnitude > uint256(uint128(type(int128).max))) return 0;
        amount = uint128(magnitude);
    }

    function _tryCorrection(
        PoolId poolId,
        PoolKey calldata key,
        bool outerZeroForOne,
        uint128 triggerBaseAmount,
        HookrModuleTypesV1.StackCore memory core,
        address recipient,
        bool trustedCaller,
        uint8 phase,
        bytes memory correctionData
    ) internal {
        address executor = core.limits.correctionExecutor;
        if (executor == address(0) || !trustedCaller) return;
        _tstore(CORRECTION_STATE_SLOT, 1);
        _tstore(CORRECTION_EXECUTOR_SLOT, uint160(executor));
        _tstore(CORRECTION_POOL_SLOT, uint256(PoolId.unwrap(poolId)));
        try HookrModularCorrectionLibV2.dispatch(
            executor,
            key,
            outerZeroForOne,
            triggerBaseAmount,
            recipient,
            core.limits.correctionCreator,
            core.limits.correctionMaxVolumeBps,
            core.limits.correctionMinProfitQuote,
            phase,
            correctionData
        ) returns (
            HookrModularCorrectionLibV2.DispatchResult memory result
        ) {
            _clearCorrection();
            if (result.status == CORRECTION_SUCCEEDED) {
                emit CorrectionAttemptSucceeded(poolId, phase, result.planDigest, result.realizedProfitQuote);
            } else if (result.status == CORRECTION_FAILED) {
                emit CorrectionAttemptFailed(poolId, phase, keccak256(correctionData), result.reasonHash);
            } else {
                emit CorrectionAttemptSkipped(poolId, phase, keccak256(correctionData), result.reasonHash);
            }
        } catch (bytes memory reason) {
            _clearCorrection();
            emit CorrectionAttemptFailed(poolId, phase, keccak256(correctionData), keccak256(reason));
        }
    }

    function _checkCorrectionCallback(address sender, PoolKey calldata key, bytes calldata hookData, uint256 state)
        internal
        view
    {
        if (
            _tload(CORRECTION_STATE_SLOT) != state || hookData.length != 0
                || sender != address(uint160(_tload(CORRECTION_EXECUTOR_SLOT)))
                || PoolId.unwrap(key.toId()) != bytes32(_tload(CORRECTION_POOL_SLOT))
        ) revert ReentrantCallback();
        HookrModuleTypesV1.StackCore memory core = _checkedCore(key.toId(), key);
        if (sender != core.limits.correctionExecutor) revert ReentrantCallback();
    }

    function _clearCorrection() internal {
        _tstore(CORRECTION_STATE_SLOT, 0);
        _tstore(CORRECTION_EXECUTOR_SLOT, 0);
        _tstore(CORRECTION_POOL_SLOT, 0);
    }

    function _checkedCore(PoolId poolId, PoolKey calldata key)
        internal
        view
        returns (HookrModuleTypesV1.StackCore memory core)
    {
        core = stackRegistry.stack(poolId);
        if (
            !core.configured || !core.initialized || core.kernel != address(this)
                || core.kernelFamilyId != KERNEL_FAMILY_ID || core.kernelCodeHash != address(this).codehash
                || address(key.hooks) != address(this) || key.fee != DYNAMIC_FEE_FLAG || core.subject == core.quote
                || !((Currency.unwrap(key.currency0) == core.subject && Currency.unwrap(key.currency1) == core.quote)
                    || (Currency.unwrap(key.currency1) == core.subject && Currency.unwrap(key.currency0) == core.quote))
        ) revert InvalidStack();
        if (core.limits.correctionExecutor == address(0)) {
            if (
                core.correctionExecutorIntegrationId != bytes32(0) || core.correctionExecutorCodeHash != bytes32(0)
                    || core.limits.correctionCreator != address(0) || core.limits.correctionMaxVolumeBps != 0
                    || core.limits.correctionMinProfitQuote != 0 || core.limits.correctionFeePolicyId != bytes32(0)
            ) revert InvalidStack();
        } else if (
            core.correctionExecutorIntegrationId == bytes32(0) || core.correctionExecutorCodeHash == bytes32(0)
                || core.limits.correctionExecutor.codehash != core.correctionExecutorCodeHash
        ) {
            revert InvalidStack();
        }
    }

    function _isCanonicalFullFillLimit(bool zeroForOne, uint160 limit) internal pure returns (bool) {
        return zeroForOne ? limit == MIN_SQRT_PRICE_LIMIT : limit == MAX_SQRT_PRICE_LIMIT;
    }

    function _delegate(bytes memory input) internal returns (bytes memory output) {
        bytes32 actual = address(accountingKernel).codehash;
        if (actual != accountingKernelCodeHash) revert AccountingKernelCodeChanged(accountingKernelCodeHash, actual);
        (bool ok, bytes memory result) = address(accountingKernel).delegatecall(input);
        if (!ok) _bubble(result);
        return result;
    }

    fallback() external {
        _delegateAndReturn();
    }

    function _delegateAndReturn() internal {
        bytes32 actual = address(accountingKernel).codehash;
        if (actual != accountingKernelCodeHash) revert AccountingKernelCodeChanged(accountingKernelCodeHash, actual);
        address target = address(accountingKernel);
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

    function _bubble(bytes memory reason) internal pure {
        if (reason.length == 0) revert DelegateCallFailed();
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }

    function _tload(bytes32 slot) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _tstore(bytes32 slot, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}
