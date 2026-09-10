// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {HookrModuleTypesV1} from "./libraries/HookrModuleTypesV1.sol";
import {HookrHookDataV1} from "./libraries/HookrHookDataV1.sol";
import {IHookrModuleV1} from "./interfaces/IHookrModuleV1.sol";
import {IHookrStatefulModuleV1} from "./interfaces/IHookrStatefulModuleV1.sol";
import {IHookrClaimSinkV1} from "./interfaces/IHookrClaimSinkV1.sol";
import {IHookrStackRegistryV1} from "./interfaces/IHookrStackRegistryV1.sol";
import {HookrStatefulModuleTypesV1} from "./libraries/HookrStatefulModuleTypesV1.sol";
import {HookrStatefulSettlementLibV1} from "./libraries/HookrStatefulSettlementLibV1.sol";

/// @title Hookr Swap Accounting Kernel V3
/// @notice V1 accounting plus the lifecycle lane used by the canonical Native Mechanics module.
/// @dev READ_ONLY modules remain STATICCALLed. The catalog's one-time canonical STATEFUL_V1 module
///      is CALLed once per declared phase under its frozen gas bound and runtime codehash. The
///      kernel validates and executes returned donations, claim mints, token takes, and hook deltas.
///      The release root delegates here and owns the V2-compatible correction envelope.
contract HookrSwapAccountingKernelV3 is IHooks {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // beforeInitialize | beforeAddLiquidity | beforeSwap | afterSwap |
    // beforeSwapReturnsDelta | afterSwapReturnsDelta
    uint160 public constant REQUIRED_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    bytes32 public constant KERNEL_FAMILY_ID = keccak256("HOOKR_SWAP_DELTA_V1");
    bytes32 public constant KERNEL_INSTANCE_LAYOUT_ID = keccak256("HOOKR_KERNEL_INSTANCE_LAYOUT_V1");
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;
    uint24 private constant OVERRIDE_FEE_FLAG = 0x400000;
    uint160 public constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 public constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 public constant MAX_HOOK_DATA_LENGTH = 4096;
    bytes32 private constant SKIP_CLAIM_SINK_UNAVAILABLE = keccak256("CLAIM_SINK_UNAVAILABLE");
    bytes4 private constant STRICT_CREDIT_REQUIRED_SELECTOR = bytes4(keccak256("strictCreditRequired()"));
    uint8 private constant PHASE_LIQUIDITY = 1;
    uint8 private constant PHASE_BEFORE_SWAP = 2;
    uint8 private constant PHASE_AFTER_SWAP = 3;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    IHookrStackRegistryV1 public immutable stackRegistry;
    address public immutable coordinator;

    struct InFlightSwap {
        bytes32 contextHash;
        uint128 specifiedQuoteTake;
        uint128 quoteDonation;
        uint24 effectiveLpFeePips;
        bool quoteDonationDeferred;
    }

    struct RuntimeQuote {
        bytes32 moduleId;
        bytes32 attributionKey;
        address recipient;
        uint16 rateBps;
        uint32 gasLimit;
        bool active;
    }

    struct ResolvedHookData {
        address payer;
        address recipient;
        bool trustedCaller;
        bytes moduleData;
    }

    mapping(PoolId poolId => InFlightSwap swapState) private _inFlight;
    uint256 private _callbackState = 1;

    event MarketInitialized(PoolId indexed poolId, bytes32 indexed stackHash, address indexed subject, address quote);
    event ModuleFeeAccrued(
        PoolId indexed poolId,
        bytes32 indexed moduleId,
        bytes32 indexed attributionKey,
        address recipient,
        address quote,
        uint256 amount,
        bool isBuy,
        bool exactInput,
        bool afterSwapPhase
    );
    event ModuleFeeSkipped(
        PoolId indexed poolId,
        bytes32 indexed moduleId,
        bytes32 indexed attributionKey,
        address recipient,
        bytes32 reason
    );
    event StatefulModuleAction(
        PoolId indexed poolId,
        bytes32 indexed moduleId,
        bytes32 indexed attributionKey,
        address currency,
        address recipient,
        uint256 amount,
        bool donation,
        bool afterSwapPhase
    );
    /// @notice Standard Uniswap hook-fee event emitted exactly once for a completed charged swap.
    event HookFee(bytes32 indexed poolId, address indexed sender, uint128 feeAmount0, uint128 feeAmount1);
    error NotPoolManager();
    error NotCoordinator();
    error InvalidWiring();
    error InvalidStack();
    error StackNotInitialized();
    error StackAlreadyInitialized();
    error ModuleCodeChanged(bytes32 moduleId, bytes32 expected, bytes32 actual);
    error TrustedIntegrationCodeChanged(bytes32 integrationId, bytes32 expected, bytes32 actual);
    error ModuleCallFailed(bytes32 moduleId, uint8 phase, bytes32 reasonHash);
    error InvalidModuleResult(bytes32 moduleId);
    error AggregateCapExceeded();
    error SwapAmountOutOfRange();
    error UnsupportedSwapDirection();
    error UnsupportedSpecifiedQuoteTake();
    error PartialFillUnsupportedWithInputCuts();
    error StrictClaimSinkUnavailable(bytes32 moduleId, address recipient);
    error ClaimCreditFailed(bytes32 moduleId, address recipient, bytes32 reasonHash);
    error ReentrantCallback();
    error MissingBeforeSwap();
    error HookDataTooLarge();
    error UntrustedHookData();
    error HookNotCalled();

    constructor(IPoolManager poolManager_, IHookrStackRegistryV1 stackRegistry_, address coordinator_) {
        if (
            address(poolManager_) == address(0) || address(poolManager_).code.length == 0
                || address(stackRegistry_) == address(0) || address(stackRegistry_).code.length == 0
                || coordinator_ == address(0) || coordinator_.code.length == 0
        ) revert InvalidWiring();
        poolManager = poolManager_;
        stackRegistry = stackRegistry_;
        coordinator = coordinator_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function contractName() external pure returns (string memory) {
        return "HookrSwapAccountingKernelV3";
    }

    function contractVersion() external pure returns (string memory) {
        return "3.0.0";
    }

    /// @notice Admission/runtime marker for the bounded stateful-module lane.
    function statefulModuleKernelMagic() external pure returns (bytes32) {
        return HookrStatefulModuleTypesV1.MODULE_MAGIC;
    }

    function kernelInstanceLayoutId() external pure returns (bytes32) {
        return KERNEL_INSTANCE_LAYOUT_ID;
    }

    function inFlight(PoolId poolId) external view returns (bytes32 contextHash, uint128 specifiedQuoteTake) {
        InFlightSwap storage state = _inFlight[poolId];
        return (state.contextHash, state.specifiedQuoteTake);
    }

    /// @notice Transparent quote-tax math used by indexers, routers, and transaction review.
    /// @param poolQuote For a gross-up this is the quote the pool itself requires; otherwise it is
    ///        the gross quote leg from which the fee is deducted.
    function previewQuoteTax(uint256 poolQuote, uint16 aggregateRateBps, bool grossUp)
        external
        pure
        returns (uint256 tax, uint256 grossOrNetQuote)
    {
        tax = _quoteTax(poolQuote, aggregateRateBps, grossUp);
        grossOrNetQuote = grossUp ? poolQuote + tax : poolQuote - tax;
    }

    /// @notice Pushes the frozen base fee into the PoolManager's dynamic-fee cache.
    function syncBaseFee(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        HookrModuleTypesV1.StackCore memory core = _checkedCore(poolId, true);
        _checkKey(key, core);
        poolManager.updateDynamicLPFee(key, core.limits.baseLpFeePips);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != coordinator) revert NotCoordinator();
        PoolId poolId = key.toId();
        HookrModuleTypesV1.StackCore memory core = _checkedCore(poolId, false);
        if (core.initialized) revert StackAlreadyInitialized();
        _checkKey(key, core);
        stackRegistry.markInitialized(poolId);
        emit MarketInitialized(poolId, core.stackHash, core.subject, core.quote);
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external view onlyPoolManager returns (bytes4) {
        if (hookData.length > MAX_HOOK_DATA_LENGTH) revert HookDataTooLarge();
        PoolId poolId = key.toId();
        HookrModuleTypesV1.StackCore memory core = _checkedCore(poolId, true);
        _checkKey(key, core);
        HookrModuleTypesV1.LiquidityContext memory context = HookrModuleTypesV1.LiquidityContext({
            poolId: PoolId.unwrap(poolId),
            sender: sender,
            subject: core.subject,
            quote: core.quote,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: params.liquidityDelta,
            salt: params.salt,
            hookData: hookData
        });
        for (uint256 i; i < core.moduleCount; ++i) {
            (HookrModuleTypesV1.ModuleSnapshot memory module, bytes memory config) = stackRegistry.moduleAt(poolId, i);
            _checkModule(module);
            if ((module.phaseMask & HookrModuleTypesV1.PHASE_BEFORE_ADD_LIQUIDITY) == 0) continue;
            (bool ok, bytes memory result) = _staticcallExact(
                module.implementation,
                module.callbackGasLimit,
                abi.encodeCall(IHookrModuleV1.beforeAddLiquidity, (context, config)),
                32
            );
            if (!ok) {
                revert ModuleCallFailed(module.moduleId, PHASE_LIQUIDITY, keccak256(result));
            }
            if (!abi.decode(result, (bool))) revert InvalidModuleResult(module.moduleId);
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_callbackState != 1) revert ReentrantCallback();
        if (hookData.length > MAX_HOOK_DATA_LENGTH) revert HookDataTooLarge();
        _callbackState = 2;

        PoolId poolId = key.toId();
        HookrModuleTypesV1.StackCore memory core = _checkedCore(poolId, true);
        _checkKey(key, core);
        (bool exactInput, uint256 specifiedAmount) = _checkedSwapAmount(params.amountSpecified);
        bool isBuy = _isBuy(key, params.zeroForOne, core);
        ResolvedHookData memory resolved = _resolveHookData(sender, core, hookData);

        HookrModuleTypesV1.SwapContext memory context = HookrModuleTypesV1.SwapContext({
            poolId: PoolId.unwrap(poolId),
            sender: sender,
            payer: resolved.payer,
            recipient: resolved.recipient,
            subject: core.subject,
            quote: core.quote,
            trustedCaller: resolved.trustedCaller,
            isBuy: isBuy,
            exactInput: exactInput,
            zeroForOne: params.zeroForOne,
            amountSpecified: params.amountSpecified,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            hookData: resolved.moduleData
        });

        RuntimeQuote[] memory quotes = new RuntimeQuote[](core.moduleCount);
        HookrStatefulSettlementLibV1.BeforeAction[] memory stateful =
            new HookrStatefulSettlementLibV1.BeforeAction[](core.moduleCount);
        uint256 quoteCount;
        uint256 statefulCount;
        uint256 surchargePips;
        uint256 totalRateBps;
        uint256 statefulSpecifiedTake;
        uint256 statefulQuoteDonation;
        for (uint256 i; i < core.moduleCount; ++i) {
            (HookrModuleTypesV1.ModuleSnapshot memory module, bytes memory config) = stackRegistry.moduleAt(poolId, i);
            _checkModule(module);
            if ((module.phaseMask & HookrModuleTypesV1.PHASE_BEFORE_SWAP) == 0) continue;

            if (_isStatefulModule(module)) {
                HookrStatefulModuleTypesV1.BeforeSwapResult memory action =
                    _beforeStatefulResult(module, context, core.limits.baseLpFeePips, config);
                _validateStatefulBefore(module, action, specifiedAmount, isBuy, exactInput);
                surchargePips += action.lpFeeSurchargePips;
                uint256 rateBps = uint256(action.quoteTakeBps) + (uint256(action.quoteTakePips) + 99) / 100;
                totalRateBps += rateBps;
                if (action.quoteTakeAmount != 0) {
                    stateful[statefulCount++] = HookrStatefulSettlementLibV1.BeforeAction({
                        moduleId: module.moduleId,
                        attributionKey: action.attributionKey,
                        module: module.implementation,
                        quoteTake: action.quoteTakeAmount,
                        quoteDonation: action.quoteDonationAmount,
                        active: true
                    });
                    statefulSpecifiedTake += action.quoteTakeAmount;
                    statefulQuoteDonation += action.quoteDonationAmount;
                }
                continue;
            }

            HookrModuleTypesV1.ModuleResult memory result = _beforeResult(module, context, config);
            if (
                result.lpFeeSurchargePips > module.maxLpFeeSurchargePips
                    || result.quoteTakeBps > module.maxSpecifiedQuoteTakeBps
            ) revert InvalidModuleResult(module.moduleId);
            surchargePips += result.lpFeeSurchargePips;
            if (result.quoteTakeBps == 0) {
                if (result.claimRecipient != address(0)) revert InvalidModuleResult(module.moduleId);
                continue;
            }
            if (isBuy != exactInput) revert UnsupportedSpecifiedQuoteTake();
            if (result.claimRecipient == address(0)) revert InvalidModuleResult(module.moduleId);
            quotes[quoteCount++] = RuntimeQuote({
                moduleId: module.moduleId,
                attributionKey: result.attributionKey,
                recipient: result.claimRecipient,
                rateBps: result.quoteTakeBps,
                gasLimit: module.callbackGasLimit,
                active: true
            });
            totalRateBps += result.quoteTakeBps;
        }

        uint256 lpFeePips = uint256(core.limits.baseLpFeePips) + surchargePips;
        if (lpFeePips > core.limits.maxLpFeePips || lpFeePips > HookrModuleTypesV1.PIPS) {
            revert AggregateCapExceeded();
        }
        if (totalRateBps > core.limits.maxSpecifiedQuoteTakeBps || totalRateBps >= HookrModuleTypesV1.BPS) {
            revert AggregateCapExceeded();
        }

        bool grossUpSpecified = !isBuy && !exactInput;
        uint256 specifiedTake = _creditQuotes(
            poolId, core.quote, quotes, quoteCount, specifiedAmount, grossUpSpecified, isBuy, exactInput, false
        );
        specifiedTake += statefulSpecifiedTake;
        if (specifiedTake != 0 && !_isCanonicalFullFillLimit(params.zeroForOne, params.sqrtPriceLimitX96)) {
            revert PartialFillUnsupportedWithInputCuts();
        }
        uint256 maxSignedDelta = uint256(uint128(type(int128).max));
        if (
            specifiedTake > maxSignedDelta || (isBuy && specifiedTake > specifiedAmount)
                || (grossUpSpecified && specifiedAmount > maxSignedDelta - specifiedTake)
        ) revert AggregateCapExceeded();

        bool quoteDonationDeferred =
            HookrStatefulSettlementLibV1.executeBefore(poolManager, poolId, key, core.quote, stateful, statefulCount);

        uint128 specifiedTake128 = uint128(specifiedTake);
        _inFlight[poolId] = InFlightSwap({
            contextHash: _contextHash(sender, poolId, params, hookData),
            specifiedQuoteTake: specifiedTake128,
            quoteDonation: uint128(statefulQuoteDonation),
            effectiveLpFeePips: uint24(lpFeePips),
            quoteDonationDeferred: quoteDonationDeferred
        });

        return (
            IHooks.beforeSwap.selector,
            specifiedTake == 0
                ? BeforeSwapDeltaLibrary.ZERO_DELTA
                : toBeforeSwapDelta(int128(uint128(specifiedTake)), 0),
            uint24(lpFeePips) | OVERRIDE_FEE_FLAG
        );
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        if (_callbackState != 2) revert MissingBeforeSwap();
        PoolId poolId = key.toId();
        InFlightSwap memory flight = _inFlight[poolId];
        if (flight.contextHash == bytes32(0) || flight.contextHash != _contextHash(sender, poolId, params, hookData)) {
            revert MissingBeforeSwap();
        }
        HookrModuleTypesV1.StackCore memory core = _checkedCore(poolId, true);
        _checkKey(key, core);
        (bool exactInput, uint256 specifiedAmount) = _checkedSwapAmount(params.amountSpecified);
        bool isBuy = _isBuy(key, params.zeroForOne, core);
        uint256 rawQuote = _rawQuoteMagnitude(key, core.quote, delta);
        uint256 rawSubject = _rawCurrencyMagnitude(key, core.subject, delta);
        ResolvedHookData memory resolved = _resolveHookData(sender, core, hookData);

        if (flight.specifiedQuoteTake != 0) {
            bool exactInputBuy = isBuy && exactInput;
            bool exactOutputSell = !isBuy && !exactInput;
            uint256 expectedRawQuote = exactInputBuy
                ? specifiedAmount - flight.specifiedQuoteTake
                : specifiedAmount + flight.specifiedQuoteTake;
            if ((!exactInputBuy && !exactOutputSell) || rawQuote != expectedRawQuote) {
                revert PartialFillUnsupportedWithInputCuts();
            }
        }

        if (flight.quoteDonationDeferred) {
            HookrStatefulSettlementLibV1.settleDeferredQuoteDonation(
                poolManager, poolId, key, core.quote, flight.quoteDonation
            );
        }

        HookrModuleTypesV1.AfterSwapContext memory context = HookrModuleTypesV1.AfterSwapContext({
            poolId: PoolId.unwrap(poolId),
            sender: sender,
            payer: resolved.payer,
            recipient: resolved.recipient,
            subject: core.subject,
            quote: core.quote,
            trustedCaller: resolved.trustedCaller,
            isBuy: isBuy,
            exactInput: exactInput,
            zeroForOne: params.zeroForOne,
            amountSpecified: params.amountSpecified,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            amount0: delta.amount0(),
            amount1: delta.amount1(),
            hookData: resolved.moduleData
        });

        RuntimeQuote[] memory quotes = new RuntimeQuote[](core.moduleCount);
        HookrStatefulSettlementLibV1.AfterAction[] memory stateful =
            new HookrStatefulSettlementLibV1.AfterAction[](core.moduleCount);
        uint256 quoteCount;
        uint256 statefulCount;
        uint256 totalRateBps;
        uint256 statefulQuoteTake;
        uint256 statefulSubjectTake;
        uint256 totalSubjectTakeBps;
        for (uint256 i; i < core.moduleCount; ++i) {
            (HookrModuleTypesV1.ModuleSnapshot memory module, bytes memory config) = stackRegistry.moduleAt(poolId, i);
            _checkModule(module);
            if ((module.phaseMask & HookrModuleTypesV1.PHASE_AFTER_SWAP) == 0) continue;

            if (_isStatefulModule(module)) {
                HookrStatefulModuleTypesV1.AfterSwapResult memory action = _afterStatefulResult(
                    module, context, flight.effectiveLpFeePips, flight.specifiedQuoteTake, flight.quoteDonation, config
                );
                _validateStatefulAfter(module, action, rawQuote, rawSubject, isBuy, exactInput);
                totalRateBps += (uint256(action.quoteTakePips) + 99) / 100;
                totalSubjectTakeBps += action.subjectTakeBps;
                if (action.quoteTakeAmount != 0 || action.subjectTakeAmount != 0) {
                    stateful[statefulCount++] = HookrStatefulSettlementLibV1.AfterAction({
                        moduleId: module.moduleId,
                        quoteAttributionKey: action.quoteAttributionKey,
                        subjectAttributionKey: action.subjectAttributionKey,
                        module: module.implementation,
                        subjectRecipient: action.subjectRecipient,
                        quoteTake: action.quoteTakeAmount,
                        subjectTake: action.subjectTakeAmount,
                        active: true
                    });
                    statefulQuoteTake += action.quoteTakeAmount;
                    statefulSubjectTake += action.subjectTakeAmount;
                }
                continue;
            }

            HookrModuleTypesV1.ModuleResult memory result = _afterResult(module, context, config);
            if (result.lpFeeSurchargePips != 0 || result.quoteTakeBps > module.maxUnspecifiedQuoteTakeBps) {
                revert InvalidModuleResult(module.moduleId);
            }
            if (result.quoteTakeBps == 0) {
                if (result.claimRecipient != address(0)) revert InvalidModuleResult(module.moduleId);
                continue;
            }
            if (isBuy == exactInput) revert InvalidModuleResult(module.moduleId);
            if (result.claimRecipient == address(0)) revert InvalidModuleResult(module.moduleId);
            quotes[quoteCount++] = RuntimeQuote({
                moduleId: module.moduleId,
                attributionKey: result.attributionKey,
                recipient: result.claimRecipient,
                rateBps: result.quoteTakeBps,
                gasLimit: module.callbackGasLimit,
                active: true
            });
            totalRateBps += result.quoteTakeBps;
        }
        if (
            totalRateBps > core.limits.maxUnspecifiedQuoteTakeBps || totalRateBps >= HookrModuleTypesV1.BPS
                || totalSubjectTakeBps > HookrStatefulModuleTypesV1.MAX_SUBJECT_TAKE_BPS
                || totalSubjectTakeBps > core.limits.maxSubjectTakeBps
        ) revert AggregateCapExceeded();

        bool grossUp = isBuy && !exactInput;
        uint256 unspecifiedQuoteTake =
            _creditQuotes(poolId, core.quote, quotes, quoteCount, rawQuote, grossUp, isBuy, exactInput, true);
        unspecifiedQuoteTake += statefulQuoteTake;
        uint256 hookDelta = unspecifiedQuoteTake + statefulSubjectTake;
        if (hookDelta > uint256(uint128(type(int128).max))) revert AggregateCapExceeded();

        HookrStatefulSettlementLibV1.executeAfter(
            poolManager, poolId, core.quote, core.subject, stateful, statefulCount
        );

        uint256 totalQuoteFee = uint256(flight.specifiedQuoteTake) + unspecifiedQuoteTake;
        uint256 totalSubjectFee = statefulSubjectTake;
        if (totalQuoteFee != 0 || totalSubjectFee != 0) {
            uint128 feeAmount0;
            uint128 feeAmount1;
            if (core.quote == Currency.unwrap(key.currency0)) {
                feeAmount0 = uint128(totalQuoteFee);
                feeAmount1 = uint128(totalSubjectFee);
            } else {
                feeAmount0 = uint128(totalSubjectFee);
                feeAmount1 = uint128(totalQuoteFee);
            }
            emit HookFee(PoolId.unwrap(poolId), sender, feeAmount0, feeAmount1);
        }

        delete _inFlight[poolId];
        _callbackState = 1;
        return (IHooks.afterSwap.selector, int128(uint128(hookDelta)));
    }

    function _isStatefulModule(HookrModuleTypesV1.ModuleSnapshot memory module) internal pure returns (bool) {
        return module.executionMode == HookrModuleTypesV1.ExecutionMode.STATEFUL_V1;
    }

    function _beforeStatefulResult(
        HookrModuleTypesV1.ModuleSnapshot memory module,
        HookrModuleTypesV1.SwapContext memory context,
        uint24 baseLpFeePips,
        bytes memory config
    ) internal returns (HookrStatefulModuleTypesV1.BeforeSwapResult memory result) {
        HookrStatefulModuleTypesV1.BeforeSwapContext memory statefulContext =
            HookrStatefulModuleTypesV1.BeforeSwapContext({swapContext: context, baseLpFeePips: baseLpFeePips});
        (bool ok, bytes memory raw) = _callExact(
            module.implementation,
            module.callbackGasLimit,
            abi.encodeCall(IHookrStatefulModuleV1.beforeSwapStateful, (statefulContext, config)),
            320
        );
        if (!ok) revert ModuleCallFailed(module.moduleId, PHASE_BEFORE_SWAP, keccak256(raw));
        result = abi.decode(raw, (HookrStatefulModuleTypesV1.BeforeSwapResult));
    }

    function _afterStatefulResult(
        HookrModuleTypesV1.ModuleSnapshot memory module,
        HookrModuleTypesV1.AfterSwapContext memory context,
        uint24 effectiveLpFeePips,
        uint128 aggregateSpecifiedQuoteTake,
        uint128 aggregateQuoteDonation,
        bytes memory config
    ) internal returns (HookrStatefulModuleTypesV1.AfterSwapResult memory result) {
        HookrStatefulModuleTypesV1.AfterSwapContext memory statefulContext =
            HookrStatefulModuleTypesV1.AfterSwapContext({
                swapContext: context,
                effectiveLpFeePips: effectiveLpFeePips,
                aggregateSpecifiedQuoteTake: aggregateSpecifiedQuoteTake,
                aggregateQuoteDonation: aggregateQuoteDonation
            });
        (bool ok, bytes memory raw) = _callExact(
            module.implementation,
            module.callbackGasLimit,
            abi.encodeCall(IHookrStatefulModuleV1.afterSwapStateful, (statefulContext, config)),
            256
        );
        if (!ok) revert ModuleCallFailed(module.moduleId, PHASE_AFTER_SWAP, keccak256(raw));
        result = abi.decode(raw, (HookrStatefulModuleTypesV1.AfterSwapResult));
    }

    function _validateStatefulBefore(
        HookrModuleTypesV1.ModuleSnapshot memory module,
        HookrStatefulModuleTypesV1.BeforeSwapResult memory action,
        uint256 specifiedAmount,
        bool isBuy,
        bool exactInput
    ) internal pure {
        uint256 rateBps = uint256(action.quoteTakeBps) + (uint256(action.quoteTakePips) + 99) / 100;
        if (
            action.lpFeeSurchargePips > module.maxLpFeeSurchargePips || rateBps > module.maxSpecifiedQuoteTakeBps
                || action.quoteTakePips >= HookrModuleTypesV1.PIPS
                || uint256(action.quoteDonationWeightBps) + action.quoteEscrowWeightBps != action.quoteTakeBps
                || action.quoteRoyaltyBps > 1_000 || action.quoteDonationAmount > action.quoteTakeAmount
        ) revert InvalidModuleResult(module.moduleId);

        bool declaresQuoteAction = action.quoteTakeBps != 0 || action.quoteTakePips != 0;
        if (declaresQuoteAction && (!isBuy || !exactInput)) revert InvalidModuleResult(module.moduleId);
        if (action.quoteTakeBps == 0) {
            if (action.quoteDonationWeightBps != 0 || action.quoteEscrowWeightBps != 0 || action.quoteRoyaltyBps != 0) {
                revert InvalidModuleResult(module.moduleId);
            }
        } else if (action.quoteRoyaltyBps != 0 && action.quoteTakeBps == 0) {
            revert InvalidModuleResult(module.moduleId);
        }

        uint256 baseTake = (specifiedAmount * action.quoteTakeBps) / HookrModuleTypesV1.BPS;
        uint256 pipTake = (specifiedAmount * action.quoteTakePips) / HookrModuleTypesV1.PIPS;
        uint256 expectedTake = baseTake + pipTake;
        uint256 royalty = (baseTake * action.quoteRoyaltyBps) / HookrModuleTypesV1.BPS;
        uint256 remaining = baseTake - royalty;
        uint256 expectedDonation;
        if (action.quoteTakeBps != 0) {
            expectedDonation = (remaining * action.quoteDonationWeightBps) / uint256(action.quoteTakeBps);
            if (action.quoteEscrowWeightBps == 0) expectedDonation = remaining;
        }
        if (action.quoteTakeAmount != expectedTake || action.quoteDonationAmount != expectedDonation) {
            revert InvalidModuleResult(module.moduleId);
        }

        uint256 claimAmount = expectedTake - expectedDonation;
        if (
            (claimAmount == 0 && action.claimRecipient != address(0))
                || (claimAmount != 0 && action.claimRecipient != module.implementation)
                || (expectedTake == 0 && action.attributionKey != bytes32(0))
                || (expectedTake != 0 && action.attributionKey == bytes32(0))
        ) revert InvalidModuleResult(module.moduleId);
    }

    function _validateStatefulAfter(
        HookrModuleTypesV1.ModuleSnapshot memory module,
        HookrStatefulModuleTypesV1.AfterSwapResult memory action,
        uint256 rawQuote,
        uint256 rawSubject,
        bool isBuy,
        bool exactInput
    ) internal pure {
        uint256 quoteRateBps = (uint256(action.quoteTakePips) + 99) / 100;
        if (
            quoteRateBps > module.maxUnspecifiedQuoteTakeBps || action.quoteTakePips >= HookrModuleTypesV1.PIPS
                || action.subjectTakeBps > HookrStatefulModuleTypesV1.MAX_SUBJECT_TAKE_BPS
                || action.subjectTakeBps > module.maxSubjectTakeBps
                || (action.quoteTakeAmount != 0 && action.subjectTakeAmount != 0)
        ) revert InvalidModuleResult(module.moduleId);

        uint256 expectedQuoteTake = (rawQuote * action.quoteTakePips) / HookrModuleTypesV1.PIPS;
        uint256 expectedSubjectTake = (rawSubject * action.subjectTakeBps) / HookrModuleTypesV1.BPS;
        if (action.quoteTakeAmount != expectedQuoteTake || action.subjectTakeAmount != expectedSubjectTake) {
            revert InvalidModuleResult(module.moduleId);
        }
        if ((action.quoteTakePips != 0 || action.quoteTakeAmount != 0) && isBuy == exactInput) {
            revert InvalidModuleResult(module.moduleId);
        }
        if ((action.subjectTakeBps != 0 || action.subjectTakeAmount != 0) && (!isBuy || !exactInput)) {
            revert InvalidModuleResult(module.moduleId);
        }
        if (
            (expectedQuoteTake == 0 && action.claimRecipient != address(0))
                || (expectedQuoteTake != 0 && action.claimRecipient != module.implementation)
                || (expectedSubjectTake == 0 && action.subjectRecipient != address(0))
                || (expectedSubjectTake != 0 && action.subjectRecipient != DEAD)
                || (expectedQuoteTake == 0 && action.quoteAttributionKey != bytes32(0))
                || (expectedQuoteTake != 0 && action.quoteAttributionKey == bytes32(0))
                || (expectedSubjectTake == 0 && action.subjectAttributionKey != bytes32(0))
                || (expectedSubjectTake != 0 && action.subjectAttributionKey == bytes32(0))
        ) revert InvalidModuleResult(module.moduleId);
    }

    function _creditQuotes(
        PoolId poolId,
        address quote,
        RuntimeQuote[] memory quotes,
        uint256 count,
        uint256 grossQuote,
        bool grossUp,
        bool isBuy,
        bool exactInput,
        bool afterPhase
    ) internal returns (uint256 totalTax) {
        if (count == 0 || grossQuote == 0) return 0;
        uint256[] memory allocations = new uint256[](count);
        bool changed = true;
        for (uint256 pass; pass <= count && changed; ++pass) {
            uint256 cumulativeRate;
            uint256 previousTarget;
            for (uint256 i; i < count; ++i) {
                if (!quotes[i].active) continue;
                cumulativeRate += quotes[i].rateBps;
                uint256 target = _quoteTax(grossQuote, cumulativeRate, grossUp);
                allocations[i] = target - previousTarget;
                previousTarget = target;
            }
            totalTax = previousTarget;
            changed = _deactivateFirstUnavailableRecipient(poolId, quotes, allocations, count);
        }

        uint256 credited;
        Currency quoteCurrency = Currency.wrap(quote);
        for (uint256 i; i < count; ++i) {
            if (!quotes[i].active || allocations[i] == 0) continue;

            bool alreadyCredited;
            for (uint256 j; j < i; ++j) {
                if (quotes[j].active && allocations[j] != 0 && quotes[j].recipient == quotes[i].recipient) {
                    alreadyCredited = true;
                    break;
                }
            }
            if (alreadyCredited) continue;

            uint256 recipientAllocation;
            uint32 gasLimit = type(uint32).max;
            for (uint256 j; j < count; ++j) {
                if (!quotes[j].active || allocations[j] == 0 || quotes[j].recipient != quotes[i].recipient) continue;
                recipientAllocation += allocations[j];
                if (quotes[j].gasLimit < gasLimit) gasLimit = quotes[j].gasLimit;
            }
            credited += recipientAllocation;
            poolManager.mint(quotes[i].recipient, quoteCurrency.toId(), recipientAllocation);
            (bool ok, uint256 returnSize) = _callNoReturn(
                quotes[i].recipient, gasLimit, abi.encodeCall(IHookrClaimSinkV1.creditClaims, (recipientAllocation))
            );
            if (!ok || returnSize != 0) {
                revert ClaimCreditFailed(quotes[i].moduleId, quotes[i].recipient, keccak256(abi.encode(ok, returnSize)));
            }
            for (uint256 j; j < count; ++j) {
                uint256 amount = allocations[j];
                if (!quotes[j].active || amount == 0 || quotes[j].recipient != quotes[i].recipient) continue;
                emit ModuleFeeAccrued(
                    poolId,
                    quotes[j].moduleId,
                    quotes[j].attributionKey,
                    quotes[j].recipient,
                    quote,
                    amount,
                    isBuy,
                    exactInput,
                    afterPhase
                );
            }
        }
        if (credited != totalTax) revert AggregateCapExceeded();
    }

    /// @dev A shared sink is preflighted against its cumulative allocation. On failure every
    ///      module using that sink is skipped together, then allocations are recomputed so later
    ///      recipients are never rejected against a stale, larger amount.
    function _deactivateFirstUnavailableRecipient(
        PoolId poolId,
        RuntimeQuote[] memory quotes,
        uint256[] memory allocations,
        uint256 count
    ) internal returns (bool) {
        for (uint256 i; i < count; ++i) {
            if (!quotes[i].active || allocations[i] == 0) continue;

            bool alreadyChecked;
            for (uint256 j; j < i; ++j) {
                if (quotes[j].active && allocations[j] != 0 && quotes[j].recipient == quotes[i].recipient) {
                    alreadyChecked = true;
                    break;
                }
            }
            if (alreadyChecked) continue;

            uint256 recipientAllocation;
            uint32 gasLimit = type(uint32).max;
            for (uint256 j; j < count; ++j) {
                if (!quotes[j].active || allocations[j] == 0 || quotes[j].recipient != quotes[i].recipient) continue;
                recipientAllocation += allocations[j];
                if (quotes[j].gasLimit < gasLimit) gasLimit = quotes[j].gasLimit;
            }
            if (_canCredit(quotes[i].recipient, recipientAllocation, gasLimit)) continue;

            if (_strictCreditRequired(quotes[i].recipient, gasLimit)) {
                revert StrictClaimSinkUnavailable(quotes[i].moduleId, quotes[i].recipient);
            }

            for (uint256 j; j < count; ++j) {
                if (!quotes[j].active || quotes[j].recipient != quotes[i].recipient) continue;
                quotes[j].active = false;
                allocations[j] = 0;
                emit ModuleFeeSkipped(
                    poolId,
                    quotes[j].moduleId,
                    quotes[j].attributionKey,
                    quotes[j].recipient,
                    SKIP_CLAIM_SINK_UNAVAILABLE
                );
            }
            return true;
        }
        return false;
    }

    function _beforeResult(
        HookrModuleTypesV1.ModuleSnapshot memory module,
        HookrModuleTypesV1.SwapContext memory context,
        bytes memory config
    ) internal view returns (HookrModuleTypesV1.ModuleResult memory result) {
        (bool ok, bytes memory raw) = _staticcallExact(
            module.implementation,
            module.callbackGasLimit,
            abi.encodeCall(IHookrModuleV1.beforeSwap, (context, config)),
            128
        );
        if (!ok) {
            revert ModuleCallFailed(module.moduleId, PHASE_BEFORE_SWAP, keccak256(raw));
        }
        result = abi.decode(raw, (HookrModuleTypesV1.ModuleResult));
    }

    function _afterResult(
        HookrModuleTypesV1.ModuleSnapshot memory module,
        HookrModuleTypesV1.AfterSwapContext memory context,
        bytes memory config
    ) internal view returns (HookrModuleTypesV1.ModuleResult memory result) {
        (bool ok, bytes memory raw) = _staticcallExact(
            module.implementation,
            module.callbackGasLimit,
            abi.encodeCall(IHookrModuleV1.afterSwap, (context, config)),
            128
        );
        if (!ok) {
            revert ModuleCallFailed(module.moduleId, PHASE_AFTER_SWAP, keccak256(raw));
        }
        result = abi.decode(raw, (HookrModuleTypesV1.ModuleResult));
    }

    function _canCredit(address recipient, uint256 amount, uint32 gasLimit) internal view returns (bool) {
        bytes memory input = abi.encodeCall(IHookrClaimSinkV1.canCredit, (amount));
        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(gasLimit, recipient, add(input, 32), mload(input), 0, 32)
            if iszero(eq(returndatasize(), 32)) { ok := 0 }
            word := mload(0)
        }
        return ok && word == 1;
    }

    function _strictCreditRequired(address recipient, uint32 gasLimit) internal view returns (bool) {
        bytes memory input = abi.encodeWithSelector(STRICT_CREDIT_REQUIRED_SELECTOR);
        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(gasLimit, recipient, add(input, 32), mload(input), 0, 32)
            if iszero(eq(returndatasize(), 32)) { ok := 0 }
            word := mload(0)
        }
        return ok && word == 1;
    }

    /// @dev Copies at most the exact ABI size expected from a reviewed module. Checking
    ///      `returndatasize` after a zero-allocation fixed-buffer call prevents a module from making
    ///      the kernel copy arbitrary return data before it can reject an oversized response.
    function _staticcallExact(address target, uint256 gasLimit, bytes memory input, uint256 expectedLength)
        internal
        view
        returns (bool ok, bytes memory output)
    {
        output = new bytes(expectedLength);
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(input, 0x20), mload(input), add(output, 0x20), expectedLength)
            let returnSize := returndatasize()
            if iszero(eq(returnSize, expectedLength)) {
                ok := 0
                if lt(returnSize, expectedLength) { mstore(output, returnSize) }
            }
        }
    }

    /// @dev Stateful-module counterpart to `_staticcallExact`; the same catalog gas stipend and
    ///      exact return-size rule bound the only mutable callback granted by this kernel family.
    function _callExact(address target, uint256 gasLimit, bytes memory input, uint256 expectedLength)
        internal
        returns (bool ok, bytes memory output)
    {
        output = new bytes(expectedLength);
        assembly ("memory-safe") {
            ok := call(gasLimit, target, 0, add(input, 0x20), mload(input), add(output, 0x20), expectedLength)
            let returnSize := returndatasize()
            if iszero(eq(returnSize, expectedLength)) {
                ok := 0
                if lt(returnSize, expectedLength) { mstore(output, returnSize) }
            }
        }
    }

    /// @dev Executes a state-changing sink callback without copying dependency-controlled return or
    ///      revert data. The sink ABI requires no return payload; any payload is rejected by size.
    function _callNoReturn(address target, uint256 gasLimit, bytes memory input)
        internal
        returns (bool ok, uint256 returnSize)
    {
        assembly ("memory-safe") {
            ok := call(gasLimit, target, 0, add(input, 0x20), mload(input), 0, 0)
            returnSize := returndatasize()
        }
    }

    function _checkedCore(PoolId poolId, bool requireInitialized)
        internal
        view
        returns (HookrModuleTypesV1.StackCore memory core)
    {
        core = stackRegistry.stack(poolId);
        if (
            !core.configured || core.kernel != address(this) || core.kernelFamilyId != KERNEL_FAMILY_ID
                || core.kernelCodeHash != address(this).codehash || core.moduleCount > HookrModuleTypesV1.MAX_MODULES
                || core.trustedRouterIntegrationId == bytes32(0) || core.trustedRouterCodeHash == bytes32(0)
                || core.trustedQuoterIntegrationId == bytes32(0) || core.trustedQuoterCodeHash == bytes32(0)
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
        if (requireInitialized && !core.initialized) revert StackNotInitialized();
    }

    function _checkKey(PoolKey calldata key, HookrModuleTypesV1.StackCore memory core) internal view {
        if (
            address(key.hooks) != address(this) || key.fee != DYNAMIC_FEE_FLAG
                || (Currency.unwrap(key.currency0) != core.subject && Currency.unwrap(key.currency0) != core.quote)
                || (Currency.unwrap(key.currency1) != core.subject && Currency.unwrap(key.currency1) != core.quote)
                || core.subject == core.quote
        ) revert InvalidStack();
    }

    function _checkModule(HookrModuleTypesV1.ModuleSnapshot memory module) internal view {
        bytes32 actual = module.implementation.codehash;
        if (actual != module.implementationCodeHash) {
            revert ModuleCodeChanged(module.moduleId, module.implementationCodeHash, actual);
        }
        if ((module.requiredHookFlags & ~REQUIRED_FLAGS) != 0) revert InvalidStack();
    }

    function _isBuy(PoolKey calldata key, bool zeroForOne, HookrModuleTypesV1.StackCore memory core)
        internal
        pure
        returns (bool)
    {
        address input = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        address output = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        if (input == core.quote && output == core.subject) return true;
        if (input == core.subject && output == core.quote) return false;
        revert UnsupportedSwapDirection();
    }

    function _rawQuoteMagnitude(PoolKey calldata key, address quote, BalanceDelta delta)
        internal
        pure
        returns (uint256)
    {
        return _rawCurrencyMagnitude(key, quote, delta);
    }

    function _rawCurrencyMagnitude(PoolKey calldata key, address currency, BalanceDelta delta)
        internal
        pure
        returns (uint256)
    {
        int128 value = currency == Currency.unwrap(key.currency0) ? delta.amount0() : delta.amount1();
        // Either branch widens an int128 magnitude to int256 before the exact uint256 conversion.
        // forge-lint: disable-next-line(unsafe-typecast)
        return value < 0 ? uint256(-int256(value)) : uint256(int256(value));
    }

    function _checkedSwapAmount(int256 amountSpecified) internal pure returns (bool exactInput, uint256 amount) {
        int256 maxAmount = int256(type(int128).max);
        if (amountSpecified == 0 || amountSpecified > maxAmount || amountSpecified < -maxAmount) {
            revert SwapAmountOutOfRange();
        }
        exactInput = amountSpecified < 0;
        amount = uint256(exactInput ? -amountSpecified : amountSpecified);
    }

    function _isCanonicalFullFillLimit(bool zeroForOne, uint160 limit) internal pure returns (bool) {
        return zeroForOne ? limit == MIN_SQRT_PRICE_LIMIT : limit == MAX_SQRT_PRICE_LIMIT;
    }

    function _quoteTax(uint256 grossQuote, uint256 cumulativeRateBps, bool grossUp) internal pure returns (uint256) {
        if (cumulativeRateBps == 0) return 0;
        if (cumulativeRateBps >= HookrModuleTypesV1.BPS) revert AggregateCapExceeded();
        return grossUp
            ? FullMath.mulDivRoundingUp(grossQuote, cumulativeRateBps, HookrModuleTypesV1.BPS - cumulativeRateBps)
            : FullMath.mulDiv(grossQuote, cumulativeRateBps, HookrModuleTypesV1.BPS);
    }

    function _contextHash(address sender, PoolId poolId, SwapParams calldata params, bytes calldata hookData)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                sender,
                PoolId.unwrap(poolId),
                params.zeroForOne,
                params.amountSpecified,
                params.sqrtPriceLimitX96,
                keccak256(hookData)
            )
        );
    }

    function _resolveHookData(address sender, HookrModuleTypesV1.StackCore memory core, bytes calldata rawHookData)
        internal
        view
        returns (ResolvedHookData memory resolved)
    {
        if (sender == core.limits.trustedRouter) {
            bytes32 actualCodeHash = sender.codehash;
            if (actualCodeHash != core.trustedRouterCodeHash) {
                revert TrustedIntegrationCodeChanged(
                    core.trustedRouterIntegrationId, core.trustedRouterCodeHash, actualCodeHash
                );
            }
            resolved.trustedCaller = true;
        } else if (sender == core.limits.trustedQuoter) {
            bytes32 actualCodeHash = sender.codehash;
            if (actualCodeHash != core.trustedQuoterCodeHash) {
                revert TrustedIntegrationCodeChanged(
                    core.trustedQuoterIntegrationId, core.trustedQuoterCodeHash, actualCodeHash
                );
            }
            resolved.trustedCaller = true;
        }
        if (!resolved.trustedCaller) {
            if (rawHookData.length != 0) revert UntrustedHookData();
            resolved.payer = sender;
            resolved.recipient = sender;
            return resolved;
        }
        HookrHookDataV1.Envelope memory routerEnvelope = HookrHookDataV1.decode(rawHookData, core.stackHash);
        resolved.payer = routerEnvelope.payer;
        resolved.recipient = routerEnvelope.recipient;
        resolved.moduleData = routerEnvelope.moduleData;
    }

    // The remaining callback bits are deliberately absent from this kernel family.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotCalled();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotCalled();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotCalled();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotCalled();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotCalled();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotCalled();
    }
}
