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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {HookrSwapAccountingKernelV3} from "./HookrSwapAccountingKernelV3.sol";
import {IHookrStackRegistryV1} from "./interfaces/IHookrStackRegistryV1.sol";
import {HookrArbTypesV3} from "./libraries/HookrArbTypesV3.sol";
import {HookrCorrectionPayloadV2} from "./libraries/HookrCorrectionPayloadV2.sol";
import {HookrHookDataV1} from "./libraries/HookrHookDataV1.sol";
import {HookrModularCorrectionLibV3} from "./libraries/HookrModularCorrectionLibV3.sol";
import {HookrModuleTypesV1} from "./libraries/HookrModuleTypesV1.sol";

/// @notice The one view this kernel reads on a pool's frozen correction executor.
/// @dev Restated here rather than imported so the kernel depends on a single selector and nothing
///      else. `HookrWthExecutorAdapterV1` answers it with the address it forwards every correction
///      to, set once by its owner and immutable afterwards. An executor that does not answer it is
///      read as having no second address.
interface IHookrCorrectionExecutorBindingV1 {
    function wthExecutor() external view returns (address);
}

/// @title Hookr Swap Kernel V5 WTH
/// @notice Release root for the always-on WTH arbitrage-recapture profile.
/// @dev This file is a copy of HookrSwapKernelV3.sol, not a subclass. HookrSwapKernelV3 is part of
///      a deployed, verified contract and cannot be edited, and none of the members that decide
///      whether a correction runs (beforeSwap, afterSwap, _prepare, _tryCorrection) are virtual, so
///      a subclass has no way to reach that decision. Five things differ from the copied source
///      and nothing else does:
///        1. `_tryCorrection` no longer requires a trusted caller, so a swap routed through the
///           Universal Router or any aggregator reaches the executor too.
///        2. Both `beforeSwap` and `afterSwap` attempt the correction on every qualifying swap,
///           with or without a correction payload. `beforeSwap` used to require an explicit signed
///           plan; that let an arbitrageur move the reference venue first and close on this pool
///           second, leaving nothing for `afterSwap` to correct. Attempting in both phases also
///           makes the `afterSwap` attempt cheaper, because the stack reads are already warm.
///        3. `_prepare` leaves the correction recipient at zero for an unauthenticated caller
///           instead of writing the raw `sender` into it, so the rebate can never be paid to a
///           router or aggregator contract that merely relayed the swap.
///        4. It links HookrModularCorrectionLibV3, which makes the plan optional and falls back to
///           the zero-recipient split.
///        5. The correction window admits two senders instead of one: the pool's frozen correction
///           executor, and the single contract that executor forwards every correction to. See
///           `_checkCorrectionCallback` for why that is the same trust, not a wider one.
///      Everything else is byte-for-byte the copied behaviour: the DELEGATECALL to the pinned
///      accounting implementation, the V2 correction storage namespace, the nested-callback guard,
///      the gas stipend and reserve, the try/catch isolation and the three correction events.
contract HookrSwapKernelV5Wth {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 public constant REQUIRED_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    bytes32 public constant KERNEL_FAMILY_ID = keccak256("HOOKR_SWAP_DELTA_V1");
    bytes32 public constant KERNEL_INSTANCE_LAYOUT_ID = keccak256("HOOKR_KERNEL_INSTANCE_LAYOUT_V1");
    bytes32 public constant STATEFUL_MODULE_MAGIC = keccak256("HOOKR_STATEFUL_SWAP_MODULE_V1");
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;
    uint24 private constant OVERRIDE_FEE_FLAG = 0x400000;
    /// @dev Gas handed to the executor's MEV view. It is a `staticcall`, so a hostile executor
    ///      can waste this much and nothing else; the refusal below only fires on a clean `true`.
    uint256 public constant MEV_CHECK_GAS_STIPEND = 200_000;

    /// @dev The partner's MEV view, accepted under either spelling of its name.
    ///
    ///      `checkV3PoolsMev` is what the adapter called before the third root dropped it and
    ///      what the integration thread uses; `checkV3PoolsMEV` is how WTH wrote it when asking
    ///      for this root. Those hash to completely different selectors, and the kernel pins the
    ///      selector rather than importing their interface, so picking one would mean a contract
    ///      that deploys, seals and then silently never refuses anything if they ship the other.
    ///      Asking them to rename working production code to match a constant chosen here is the
    ///      wrong way round, so both are tried and the second is only paid for when the first
    ///      finds nothing.
    bytes4 private constant MEV_CHECK_SELECTOR = 0x6075521e;
    bytes4 private constant MEV_CHECK_SELECTOR_ALT = 0x85c30352;

    uint256 private constant Q96 = 1 << 96;
    uint160 public constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 public constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    uint8 private constant CORRECTION_SUCCEEDED = 1;
    uint8 private constant CORRECTION_FAILED = 2;

    // Exact V2 namespace: signed payloads and nested-callback expectations do not change in V3.
    bytes32 private constant CORRECTION_STATE_SLOT = keccak256("hookr.swap.kernel.v2.correction.state");
    bytes32 private constant CORRECTION_EXECUTOR_SLOT = keccak256("hookr.swap.kernel.v2.correction.executor");
    bytes32 private constant CORRECTION_POOL_SLOT = keccak256("hookr.swap.kernel.v2.correction.pool");
    // New to this kernel, so it gets its own key rather than crowding the V2 namespace.
    bytes32 private constant CORRECTION_BOUND_EXECUTOR_SLOT =
        keccak256("hookr.swap.kernel.v3.wth.correction.bound.executor");
    /// @dev Transaction-lifetime cache for `_boundExecutor`, keyed by the executor it answered
    ///      for. Both phases of one swap ask the same question of the same address, and the
    ///      measured read is ~2.3k each, so the second is paid for nothing. Not cleared with the
    ///      correction window: it is scoped to the transaction, and a different executor in the
    ///      same transaction misses the key and reads again.
    bytes32 private constant BOUND_EXECUTOR_CACHE_KEY_SLOT =
        keccak256("hookr.swap.kernel.v3.wth.correction.bound.cache.key");
    bytes32 private constant BOUND_EXECUTOR_CACHE_VALUE_SLOT =
        keccak256("hookr.swap.kernel.v3.wth.correction.bound.cache.value");

    /// @dev Gas handed to the one view read on the pool's correction executor. A read that costs
    ///      more than this is read as no answer, which is the same as no second address.
    uint256 private constant BOUND_EXECUTOR_READ_GAS = 30_000;

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
    /// @dev Selector kept stable so WTH can keep their view at the signature the third root used.
    error MevCallbackRefused(address subject, address quote);

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
        return "HookrSwapKernelV3Wth";
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
        _refuseMevCallback(prepared.core);
        bytes memory output = _delegate(
            abi.encodeWithSelector(IHooks.beforeSwap.selector, sender, key, params, prepared.delegatedHookData)
        );
        (selector, delta, feeOverride) = abi.decode(output, (bytes4, BeforeSwapDelta, uint24));

        // Unconditional, like afterSwap: a signed plan is optional, and the correction library
        // falls back to the zero-recipient split when none arrives. Requiring a payload here is
        // what let an arbitrageur move the reference venue first and close on this pool second,
        // because by afterSwap the gap it would have corrected is already gone.
        uint128 triggerBaseAmount = _preSwapTriggerBase(params, key, prepared.core, prepared.poolId);
        if (triggerBaseAmount != 0) {
            _tryCorrection(
                prepared.poolId,
                key,
                params.zeroForOne,
                triggerBaseAmount,
                prepared.core,
                prepared.recipient,
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
        // Always-on: an empty afterCorrection is the fallback case, not a reason to skip.
        if (triggerBaseAmount != 0) {
            _tryCorrection(
                prepared.poolId,
                key,
                params.zeroForOne,
                triggerBaseAmount,
                prepared.core,
                prepared.recipient,
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
            // The copied source put `sender` here, which was dead code: its correction never ran
            // for an untrusted caller. On this root the correction does run, and an unauthenticated
            // caller is a router or aggregator contract, not a trader, so the rebate recipient
            // stays zero and the correction library reassigns the trader's share.
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

    /// @dev The trigger size in subject units.
    ///
    ///      V3 returned 0 unless the specified amount was denominated in the subject. An
    ///      exact-input buy names quote, so buys never reached the executor: on the third root,
    ///      ten attempts, all afterSwap, none from beforeSwap. That drops the case beforeSwap
    ///      exists for, where an arbitrageur moves the reference venue first and closes here, so
    ///      the gap is gone by afterSwap.
    ///
    ///      The subject amount is genuinely unknown before the swap runs, so convert at the
    ///      pool price instead of refusing. The result is a sizing hint: the executor simulates
    ///      its own route and `correctionMaxVolumeBps` caps what it may trade.
    function _preSwapTriggerBase(
        SwapParams calldata params,
        PoolKey calldata key,
        HookrModuleTypesV1.StackCore memory core,
        PoolId poolId
    ) internal view returns (uint128 amount) {
        if (!_isCanonicalFullFillLimit(params.zeroForOne, params.sqrtPriceLimitX96)) return 0;
        int256 raw = params.amountSpecified;
        if (raw == 0 || raw > int256(type(int128).max) || raw < -int256(type(int128).max)) return 0;
        uint256 magnitude = uint256(raw < 0 ? -raw : raw);

        bool exactInput = raw < 0;
        address specifiedCurrency = exactInput
            ? (params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1))
            : (params.zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0));
        if (specifiedCurrency == core.subject) return uint128(magnitude);

        // Anything that is neither of the pool's currencies is a malformed key, not a conversion.
        address subject = core.subject;
        bool subjectIsCurrency1 = subject == Currency.unwrap(key.currency1);
        if (!subjectIsCurrency1 && subject != Currency.unwrap(key.currency0)) return 0;

        return _quoteToSubject(poolId, magnitude, subjectIsCurrency1);
    }

    /// @dev Refuse a swap that is closing an arbitrage leg inside a v3 callback.
    ///
    ///      The executor answers whether any v3 pool in its registry for this pair is currently
    ///      locked for re-entrancy. A lock means the caller is inside that pool's callback, which
    ///      in observed traffic is an arbitrage bot that moved the reference venue first and is
    ///      closing here. Refusing takes the spread away from it and leaves the gap for the
    ///      pool's own correction to take on the next swap.
    ///
    ///      This is the one place the kernel fails a user's swap on the partner's say-so, so the
    ///      conditions are narrow. It runs only where a correction executor is configured, only
    ///      outside the correction window (the executor re-enters this function to close its own
    ///      leg and must not be refused), and only on a clean `true`. A revert, a missing
    ///      function, a short return or anything but a single true word is read as no MEV and the
    ///      swap proceeds, so an executor that stops answering cannot brick the pool.
    // Not `view`: `_boundExecutor` writes its transient cache, and paying that write here means
    // the correction path does not pay the registry read again a few lines later.
    function _refuseMevCallback(HookrModuleTypesV1.StackCore memory core) internal {
        address executor = core.limits.correctionExecutor;
        if (executor == address(0)) return;
        address bound = _boundExecutor(executor);
        if (bound == address(0)) return;

        if (
            _mevViewSaysTrue(bound, MEV_CHECK_SELECTOR, core)
                || _mevViewSaysTrue(bound, MEV_CHECK_SELECTOR_ALT, core)
        ) revert MevCallbackRefused(core.subject, core.quote);
    }

    /// @dev One spelling of the MEV view, answered strictly. Anything other than a clean single
    ///      true word is false: a revert, a missing function, a short return, a dirty word.
    function _mevViewSaysTrue(address bound, bytes4 selector, HookrModuleTypesV1.StackCore memory core)
        private
        view
        returns (bool)
    {
        bytes memory input = abi.encodeWithSelector(selector, core.subject, core.quote);
        bool ok;
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(MEV_CHECK_GAS_STIPEND, bound, add(input, 0x20), mload(input), 0, 0x20)
            size := returndatasize()
            word := mload(0)
        }
        return ok && size == 32 && word == 1;
    }

    /// @dev A quote amount in subject units at the pool's spot price.
    ///
    ///      `(sqrtPriceX96 / 2**96) ** 2` is currency1 per currency0. Squaring in one step
    ///      overflows 256 bits at ordinary amounts, so each direction runs as two `mulDiv` calls,
    ///      which carry the intermediate in 512 bits. Both floor, biasing the hint low, which can
    ///      only shrink the trade the executor considers.
    ///
    ///      Returns 0 on an uninitialized pool or a size exceeding `uint128`. Both mean do not
    ///      attempt, which is what V3 answered for every quote-denominated swap.
    function _quoteToSubject(PoolId poolId, uint256 quoteAmount, bool subjectIsCurrency1)
        private
        view
        returns (uint128)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) return 0;

        uint256 converted;
        if (subjectIsCurrency1) {
            // subject = currency1, quote = currency0: multiply by price.
            converted = FullMath.mulDiv(
                FullMath.mulDiv(quoteAmount, sqrtPriceX96, Q96), sqrtPriceX96, Q96
            );
        } else {
            // subject = currency0, quote = currency1: divide by price.
            converted = FullMath.mulDiv(
                FullMath.mulDiv(quoteAmount, Q96, sqrtPriceX96), Q96, sqrtPriceX96
            );
        }
        if (converted == 0 || converted > type(uint128).max) return 0;
        return uint128(converted);
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
        uint8 phase,
        bytes memory correctionData
    ) internal {
        address executor = core.limits.correctionExecutor;
        // The copied source also returned unless the caller was the trusted router or quoter.
        // The WTH profile is defined by running for every caller, so only a pool with no executor
        // configured is exempt.
        if (executor == address(0)) return;
        _tstore(CORRECTION_STATE_SLOT, 1);
        _tstore(CORRECTION_EXECUTOR_SLOT, uint160(executor));
        _tstore(CORRECTION_BOUND_EXECUTOR_SLOT, uint160(_boundExecutor(executor)));
        _tstore(CORRECTION_POOL_SLOT, uint256(PoolId.unwrap(poolId)));
        try HookrModularCorrectionLibV3.dispatch(
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
            HookrModularCorrectionLibV3.DispatchResult memory result
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

    /// @dev The one widening in this kernel. The copied source admitted a single re-entering
    ///      sender, the pool's frozen correction executor; this admits that address and the single
    ///      contract it forwards every correction to.
    ///
    ///      The invariant: the bound executor is the same contract the pool already trusts to be
    ///      called during the correction, so admitting its swap back into the pool for the length
    ///      of that call widens nothing beyond what the seal already granted. The pool's seal names
    ///      the correction executor; that executor's whole purpose during the window is to reach
    ///      the one address it is bound to, which it cannot change; and the window still closes on
    ///      the same instruction it closes on today. A third sender is still refused, a sender on
    ///      any other pool is still refused, and outside a correction both addresses are ordinary
    ///      callers with no privilege at all.
    ///
    ///      `armed` is re-checked against the registry, not `sender`, so the pair can only ever be
    ///      the pair this pool's own frozen executor named.
    function _checkCorrectionCallback(address sender, PoolKey calldata key, bytes calldata hookData, uint256 state)
        internal
        view
    {
        address armed = address(uint160(_tload(CORRECTION_EXECUTOR_SLOT)));
        address bound = address(uint160(_tload(CORRECTION_BOUND_EXECUTOR_SLOT)));
        if (
            _tload(CORRECTION_STATE_SLOT) != state || hookData.length != 0
                || (sender != armed && (bound == address(0) || sender != bound))
                || PoolId.unwrap(key.toId()) != bytes32(_tload(CORRECTION_POOL_SLOT))
        ) revert ReentrantCallback();
        HookrModuleTypesV1.StackCore memory core = _checkedCore(key.toId(), key);
        if (armed != core.limits.correctionExecutor) revert ReentrantCallback();
    }

    /// @dev One bounded static read on the pool's frozen correction executor. A zero answer, a
    ///      revert, a short return or a dirty word all mean the same thing: no second address, and
    ///      the window then admits exactly the one sender it admits today.
    function _boundExecutor(address executor) internal returns (address bound) {
        // A hit means this transaction already asked this executor. Answering consistently within
        // one transaction is also the safer behaviour: an executor that returned two different
        // addresses across the two phases would otherwise widen the window it is meant to narrow.
        if (_tload(BOUND_EXECUTOR_CACHE_KEY_SLOT) == uint256(uint160(executor))) {
            return address(uint160(_tload(BOUND_EXECUTOR_CACHE_VALUE_SLOT)));
        }
        bound = _readBoundExecutor(executor);
        _tstore(BOUND_EXECUTOR_CACHE_KEY_SLOT, uint256(uint160(executor)));
        _tstore(BOUND_EXECUTOR_CACHE_VALUE_SLOT, uint256(uint160(bound)));
    }

    function _readBoundExecutor(address executor) internal view returns (address bound) {
        bytes memory input = abi.encodeCall(IHookrCorrectionExecutorBindingV1.wthExecutor, ());
        bool ok;
        uint256 size;
        uint256 raw;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(BOUND_EXECUTOR_READ_GAS, executor, add(input, 0x20), mload(input), 0, 0x20)
            size := returndatasize()
            raw := mload(0)
        }
        if (!ok || size != 32 || raw >> 160 != 0) return address(0);
        bound = address(uint160(raw));
    }

    function _clearCorrection() internal {
        _tstore(CORRECTION_STATE_SLOT, 0);
        _tstore(CORRECTION_EXECUTOR_SLOT, 0);
        _tstore(CORRECTION_BOUND_EXECUTOR_SLOT, 0);
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
