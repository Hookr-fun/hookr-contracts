// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IHookrModuleV1} from "./interfaces/IHookrModuleV1.sol";
import {IHookrStatefulModuleV1} from "./interfaces/IHookrStatefulModuleV1.sol";
import {IHookrStackRegistryV1} from "./interfaces/IHookrStackRegistryV1.sol";
import {HookrModuleTypesV1} from "./libraries/HookrModuleTypesV1.sol";
import {HookrStatefulModuleTypesV1} from "./libraries/HookrStatefulModuleTypesV1.sol";

interface IHookrStatefulKernelV1 {
    function statefulModuleKernelMagic() external pure returns (bytes32);
    function poolManager() external view returns (IPoolManager);
    function coordinator() external view returns (address);
}

interface IHookrFrozenStatefulModuleRegistryV1 {
    function frozenModuleConfigHash(PoolId poolId, address implementation) external view returns (bytes32 configHash);
}

/// @title Hookr Native Mechanics Block V2
/// @notice Stateful lifecycle module for the coupled Hookr builder mechanics on any quote currency.
/// @dev These blocks stay together because splitting them changes the proven fee rounding: one
///      hook cut is computed across LP Rewards and Nth-buy Pot, royalty is removed once, and the
///      protocol slice absorbs shared rounding dust. This adapter therefore exposes independently
///      switchable fields in one immutable per-pool config. Exact-input surge fees scale with the
///      specified input relative to in-range depth. Exact-output swaps use the configured ceiling
///      because the input is not known when beforeSwap must set the LP fee. Swap callbacks only
///      read PoolManager and update the module's ledgers; HookrSwapKernelV3 alone executes their
///      PoolManager action plans. Pull claims later burn this module's own backed ERC-6909 balance
///      outside the swap lifecycle.
/// @dev V2 differences from V1: every ledger is keyed by the pool's quote currency so native and
///      ERC-20 quoted pools coexist on one module without their claims ever crossing, and there is
///      no flat protocol fee. The protocol instead takes a bounded share `protocolShareBps` from
///      INSIDE each opted-in add-on - the surge surcharge, the guard snipe tax, the LP-reward cut,
///      the pot cut and the auto-burn - while the base LP fee stays whole with in-range LPs. A pool
///      is only executable when `protocolShareBps <= MAX_PROTOCOL_SHARE_BPS` and `protocolRecipient`
///      equals this module's immutable treasury. The module enforces the ceiling and the recipient;
///      the exact per-pool share inside that ceiling is chosen by the admitting coordinator and
///      frozen with the config. A zero share is structurally valid and simply gives the pool no
///      protocol leg. Amounts named `*Wei` are denominated in the pool's own quote unit.
///      See docs/FEE_MODEL_V2.md for the per-quadrant math table.
contract HookrNativeMechanicsBlockV2 is IHookrModuleV1, IHookrStatefulModuleV1, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @notice Protocol-revenue streams reported by `ProtocolShareAccrued`.
    /// @dev `Guard` is the snipe-tax slice and only ever accrues on an exact-input buy inside a
    ///      guard window, which keeps guard-window and post-guard revenue separable. Deferred
    ///      (afterSwap) slices are always pure surge and report as `Surcharge`.
    enum ProtocolStream {
        Surcharge,
        Guard,
        LpReward,
        Pot,
        Burn
    }

    bytes32 public constant MODULE_KEY = keccak256("HOOKR_NATIVE_MECHANICS");
    bytes32 public constant EXCLUSIVE_GROUP = keccak256("HOOKR_NATIVE_MECHANICS");
    /// @dev The schema string is V2's own. The `Config` layout is byte-identical to V1's, but two
    ///      fields changed meaning: `protocolShareBps` is a share of each add-on in basis points,
    ///      where `flywheelFeePips` was a flat rate on the quote leg in pips. A V1-era encoder
    ///      would produce a config that decodes without complaint and prices completely
    ///      differently, so the literal is bumped to make that mismatch fail closed at admission.
    ///      Nothing this release reuses depends on the V1 literal: the catalog, registry,
    ///      coordinator and `HookrNativeMechanicsCoordinatorLibV2` are all fresh deployments and
    ///      the catalog reads this hash off the module itself.
    bytes32 public constant CONFIG_SCHEMA_HASH = keccak256(
        "HookrNativeMechanicsBlockV2.Config(bytes32 poolId,address kernel,address subject,address quote,address lockedLiquidityProvider,uint40 guardEndBlock,uint24 baseFeePips,uint24 maxFeePips,uint24 snipeTaxPips,uint16 surgeSens,uint16 burnBps,uint16 lpBps,uint16 potBps,uint16 royaltyBps,uint32 potEveryNBuys,uint96 maxBuyQuoteAmount,uint96 potMinBuyWei,address royaltyTo,address protocolRecipient,uint24 protocolShareBps)"
    );
    bytes32 public constant NATIVE_CUT_ATTRIBUTION_KEY = keccak256("HOOKR_NATIVE_BUY_CUT");
    bytes32 public constant PROTOCOL_SHARE_ATTRIBUTION_KEY = keccak256("HOOKR_NATIVE_PROTOCOL_SHARE");
    bytes32 public constant AUTO_BURN_ATTRIBUTION_KEY = keccak256("HOOKR_NATIVE_AUTO_BURN");
    uint32 public constant MODULE_VERSION = 2;
    uint8 public constant PHASE_MASK = HookrModuleTypesV1.ALL_PHASES;
    uint160 public constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 public constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint24 public constant MAX_TOTAL_FEE_PIPS = 500_000;
    /// @notice Ceiling on the share any V2 pool may carve out of its own add-ons, in bps (50%).
    /// @dev The module never fixes the share itself. Admission proves the config's share equals the
    ///      coordinator's own tier resolution, and the frozen config then pins it for the pool. The
    ///      base LP fee is never touched by this share on any pool at any value.
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 5_000;
    /// @notice Native-quote pot floor. The `pure` structural validation cannot read an ERC-20
    ///         quote's decimals, so it only requires a non-zero floor there; the same one
    ///         thousandth of a whole unit is enforced for ERC-20 quotes by `validateProtocolShare`,
    ///         which every coordinator admission path must call.
    uint96 public constant MIN_POT_BUY_WEI = 0.001 ether;
    /// @notice Largest quote-token `decimals()` this module will admit a pot floor for.
    uint256 public constant MAX_QUOTE_DECIMALS = 36;
    uint256 public constant MAX_GUARD_BLOCKS = 100_000;
    uint256 private constant PIPS = 1_000_000;
    uint32 private constant TOKEN_QUERY_GAS = 50_000;
    uint256 private constant BPS = 10_000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @dev Transient-storage domain for the surcharge slice a deferred quadrant carries from
    ///      `beforeSwapStateful` to `afterSwapStateful`. Never survives the transaction.
    bytes32 private constant PENDING_PROTOCOL_PIPS_SEED =
        keccak256("hookr.native.mechanics.v2.pending.protocol.surcharge.pips");

    IPoolManager public immutable poolManager;
    IHookrStackRegistryV1 public immutable stackRegistry;
    /// @notice The only address that may receive this module's protocol share.
    address public immutable protocolRecipient;

    struct Config {
        bytes32 poolId;
        address kernel;
        address subject;
        address quote;
        address lockedLiquidityProvider;
        uint40 guardEndBlock;
        uint24 baseFeePips;
        uint24 maxFeePips;
        uint24 snipeTaxPips;
        uint16 surgeSens;
        uint16 burnBps;
        uint16 lpBps;
        uint16 potBps;
        uint16 royaltyBps;
        uint32 potEveryNBuys;
        uint96 maxBuyQuoteAmount;
        uint96 potMinBuyWei;
        address royaltyTo;
        address protocolRecipient;
        uint24 protocolShareBps;
    }

    /// @dev Per-swap working values for the exact-input buy cut leg. Grouped so the split stays one
    ///      readable block of integer arithmetic that reconciles to the last wei.
    struct BuyCut {
        uint256 gross;
        uint256 donation;
        uint256 potAdd;
        uint256 royalty;
        uint256 protocolLp;
        uint256 protocolPot;
        uint256 takeBps;
        uint256 lpNetBps;
    }

    mapping(bytes32 poolId => uint256 amount) public potWei;
    mapping(bytes32 poolId => uint256 count) public potBuyCount;
    mapping(bytes32 poolId => uint40 blockNumber) public potLastQualifyingBlock;
    mapping(bytes32 poolId => uint40 blockNumber) public guardBuyBlock;
    mapping(bytes32 poolId => uint96 amount) public guardBuyAmount;
    /// @notice Informational per-pool counter of quote-denominated LP earnings accrued while the
    ///         guard window was active. It is no longer an input to any transfer.
    mapping(bytes32 poolId => uint256 amount) public guardLpEarnedQuote;
    mapping(bytes32 poolId => uint256 amount) public totalHookFeesWei;
    mapping(bytes32 poolId => uint256 amount) public totalBurnedTokens;
    mapping(bytes32 poolId => uint256 amount) public totalLpDonatedWei;
    mapping(bytes32 poolId => uint256 amount) public totalPotPaidWei;
    /// @notice Cumulative protocol share accrued by one pool across every stream.
    mapping(bytes32 poolId => uint256 amount) public totalProtocolShareWei;
    /// @notice Cumulative protocol share accrued by one pool for one `ProtocolStream`.
    mapping(bytes32 poolId => mapping(uint8 stream => uint256 amount)) public protocolShareByStream;
    /// @notice Pull-claim ledger, keyed by the pool's quote currency then by account.
    mapping(address quote => mapping(address account => uint256 amount)) public claimable;
    /// @notice Backed ERC-6909 liability this module owes per quote currency.
    mapping(address quote => uint256 amount) public totalClaimLiability;

    event HookFeesAccrued(
        bytes32 indexed poolId,
        uint256 burnWei,
        uint256 lpWei,
        uint256 potWeiAdded,
        uint256 royaltyWei,
        address royaltyTo
    );
    event JackpotHit(bytes32 indexed poolId, address indexed winner, uint256 amountWei, uint256 buyCount);
    event AutoBurn(bytes32 indexed poolId, uint256 tokensBurned);
    event LpRewardsDonated(bytes32 indexed poolId, uint256 amountWei);
    /// @notice One protocol-share accrual, attributed to the add-on it was carved out of.
    event ProtocolShareAccrued(bytes32 indexed poolId, ProtocolStream indexed stream, uint256 amount);
    event Claimed(address indexed quote, address indexed account, address indexed to, uint256 amount);

    error InvalidConfig();
    error StatefulKernelRequired();
    error NotKernel();
    error NotPoolManager();
    error InvalidRuntimeContext();
    error MaxBuyExceeded(uint256 attemptedQuoteAmount, uint256 maxQuoteAmount);
    error ExactOutputBlockedDuringGuard();
    error PartialFillUnsupportedWithInputCuts();
    error ExternalLiquidityBlockedDuringGuard();
    error InvalidPotRecipient();
    error NothingToClaim();
    error ZeroAddress();
    error ClaimTransferFailed();
    error HookNotCalled();
    error ProtocolShareNotEnforced();

    constructor(IPoolManager poolManager_, IHookrStackRegistryV1 stackRegistry_, address protocolRecipient_) {
        if (
            address(poolManager_) == address(0) || address(poolManager_).code.length == 0
                || address(stackRegistry_) == address(0) || address(stackRegistry_).code.length == 0
                || protocolRecipient_ == address(0)
        ) revert ZeroAddress();
        poolManager = poolManager_;
        stackRegistry = stackRegistry_;
        protocolRecipient = protocolRecipient_;
    }

    function contractName() external pure returns (string memory) {
        return "HookrNativeMechanicsBlockV2";
    }

    function contractVersion() external pure returns (string memory) {
        return "2.1.0";
    }

    function moduleKey() external pure override returns (bytes32) {
        return MODULE_KEY;
    }

    function moduleVersion() external pure override returns (uint32) {
        return MODULE_VERSION;
    }

    function configSchemaHash() external pure override returns (bytes32) {
        return CONFIG_SCHEMA_HASH;
    }

    function statefulModuleMagic() external pure override returns (bytes32) {
        return HookrStatefulModuleTypesV1.MODULE_MAGIC;
    }

    /// @notice Coordinator admission read proving whether this config needs a locked founding LP.
    function requiresLockedFoundingPosition(bytes calldata config) external pure returns (bool required) {
        return _decodeAndValidate(config).guardEndBlock != 0;
    }

    function phaseMask() external pure returns (uint8) {
        return PHASE_MASK;
    }

    function exclusiveGroup() external pure returns (bytes32) {
        return EXCLUSIVE_GROUP;
    }

    /// @notice Structural validation only: it proves the share is within `MAX_PROTOCOL_SHARE_BPS`.
    ///         `IHookrModuleV1.validateConfig` is `external pure`, so it cannot read the
    ///         `protocolRecipient` immutable; admission must also call `validateProtocolShare`, and
    ///         `_authorize` re-checks the same pair on every swap.
    function validateConfig(bytes calldata config) external pure override returns (bytes32 configHash) {
        _decodeAndValidate(config);
        return keccak256(config);
    }

    /// @notice Coordinator admission read proving this config routes a within-ceiling protocol share
    ///         to this module's own treasury and, for an ERC-20 quote, a decimals-aware pot floor.
    /// @dev Reverts `InvalidConfig` for a structurally invalid config; returns false for a
    ///      structurally valid config whose protocol recipient is not this module's treasury or
    ///      whose ERC-20 pot floor is below one thousandth of one whole quote unit. The exact share
    ///      is the admitting coordinator's decision, so only the ceiling is checked here.
    function validateProtocolShare(bytes calldata config) external view returns (bool enforced) {
        Config memory cfg = _decodeAndValidate(config);
        if (cfg.protocolShareBps > MAX_PROTOCOL_SHARE_BPS || cfg.protocolRecipient != protocolRecipient) return false;
        if (cfg.quote != address(0) && cfg.potBps != 0) {
            (bool ok, uint256 quoteDecimals) = _boundedQuoteDecimals(cfg.quote);
            if (!ok || quoteDecimals < 3 || quoteDecimals > MAX_QUOTE_DECIMALS) return false;
            if (cfg.potMinBuyWei < 10 ** (quoteDecimals - 3)) return false;
        }
        return true;
    }

    function validateStack(bytes32 poolId, address kernel, address subject, address quote, bytes calldata config)
        external
        view
        override
        returns (HookrModuleTypesV1.ModuleConfigCaps memory caps)
    {
        Config memory cfg = _decodeAndValidate(config);
        if (
            cfg.poolId != poolId || cfg.kernel != kernel || cfg.subject != subject || cfg.quote != quote
                || kernel.code.length == 0
        ) revert InvalidConfig();

        IHookrStatefulKernelV1 statefulKernel = IHookrStatefulKernelV1(kernel);
        try statefulKernel.statefulModuleKernelMagic() returns (bytes32 magic) {
            if (magic != HookrStatefulModuleTypesV1.MODULE_MAGIC) revert InvalidConfig();
        } catch {
            revert InvalidConfig();
        }
        try statefulKernel.poolManager() returns (IPoolManager manager) {
            if (address(manager) != address(poolManager)) revert InvalidConfig();
        } catch {
            revert InvalidConfig();
        }
        if (cfg.guardEndBlock != 0) {
            if (
                uint256(cfg.guardEndBlock) <= block.number
                    || uint256(cfg.guardEndBlock) - block.number > MAX_GUARD_BLOCKS
            ) {
                revert InvalidConfig();
            }
            try statefulKernel.coordinator() returns (address coordinator) {
                if (coordinator != cfg.lockedLiquidityProvider) revert InvalidConfig();
            } catch {
                revert InvalidConfig();
            }
        }

        caps.configHash = keccak256(config);
        (uint256 surgeMax, uint256 snipeMax) = _surchargeCeiling(cfg);
        // The surcharge ceiling is bounded by MAX_TOTAL_FEE_PIPS.
        // forge-lint: disable-next-line(unsafe-typecast)
        caps.maxLpFeeSurchargePips = uint24(surgeMax + snipeMax);

        uint256 share = cfg.protocolShareBps;
        // One floor of the summed ceiling, never the sum of two floors: the runtime slice is
        // `floor(surge*s) + floor(snipe*s)`, which is always <= `floor((surge+snipe)*s)`, and the
        // runtime pair is itself bounded by this ceiling pair. Two separate floors here could sit
        // two pips below a runtime value and de-admit a legal swap at the kernel's rate check.
        uint256 surchargeSlicePips = ((surgeMax + snipeMax) * share) / BPS;
        // The burn slice floors at bps and only then scales to pips, deliberately: that floor is
        // the exact complement of the reduced subject burn weight, so the trader pays neither more
        // nor less than the configured burn.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 specifiedPips = surchargeSlicePips + ((uint256(cfg.burnBps) * share) / BPS) * 100;
        uint256 specifiedCap = uint256(cfg.lpBps) + cfg.potBps + (specifiedPips + 99) / 100;
        uint256 unspecifiedCap = (surchargeSlicePips + 99) / 100;
        if (specifiedCap >= BPS || unspecifiedCap >= BPS) revert InvalidConfig();
        // Both values are strictly below BPS and therefore fit uint16.
        // forge-lint: disable-next-line(unsafe-typecast)
        caps.maxSpecifiedQuoteTakeBps = uint16(specifiedCap);
        // forge-lint: disable-next-line(unsafe-typecast)
        caps.maxUnspecifiedQuoteTakeBps = uint16(unspecifiedCap);
        caps.maxSubjectTakeBps = cfg.burnBps;
    }

    function beforeAddLiquidity(HookrModuleTypesV1.LiquidityContext calldata context, bytes calldata config)
        external
        view
        override
        returns (bool allowed)
    {
        Config memory cfg = _decodeAndValidate(config);
        _authorize(cfg, context.poolId, context.subject, context.quote, keccak256(config));
        if (context.poolId != cfg.poolId || context.subject != cfg.subject || context.quote != cfg.quote) {
            revert InvalidRuntimeContext();
        }
        if (cfg.guardEndBlock != 0 && block.number < cfg.guardEndBlock && context.sender != cfg.lockedLiquidityProvider)
        {
            revert ExternalLiquidityBlockedDuringGuard();
        }
        return true;
    }

    /// @dev A V1 kernel must never silently execute this stateful adapter as a read-only module.
    function beforeSwap(HookrModuleTypesV1.SwapContext calldata, bytes calldata)
        external
        pure
        override
        returns (HookrModuleTypesV1.ModuleResult memory)
    {
        revert StatefulKernelRequired();
    }

    /// @dev A V1 kernel must never silently execute this stateful adapter as a read-only module.
    function afterSwap(HookrModuleTypesV1.AfterSwapContext calldata, bytes calldata)
        external
        pure
        override
        returns (HookrModuleTypesV1.ModuleResult memory)
    {
        revert StatefulKernelRequired();
    }

    function beforeSwapStateful(HookrStatefulModuleTypesV1.BeforeSwapContext calldata context, bytes calldata config)
        external
        override
        returns (HookrStatefulModuleTypesV1.BeforeSwapResult memory result)
    {
        Config memory cfg = _decodeAndValidate(config);
        _authorize(
            cfg, context.swapContext.poolId, context.swapContext.subject, context.swapContext.quote, keccak256(config)
        );
        _checkRuntime(cfg, context.swapContext);
        if (context.baseLpFeePips != cfg.baseFeePips) revert InvalidRuntimeContext();

        HookrModuleTypesV1.SwapContext calldata swapContext = context.swapContext;
        bool guardActive = cfg.guardEndBlock != 0 && block.number < cfg.guardEndBlock;
        uint256 requested = _specifiedAmount(swapContext.amountSpecified);

        if (guardActive && swapContext.isBuy) {
            if (!swapContext.exactInput) revert ExactOutputBlockedDuringGuard();
            if (cfg.maxBuyQuoteAmount != 0) {
                uint256 spent = guardBuyBlock[cfg.poolId] == block.number ? guardBuyAmount[cfg.poolId] : 0;
                uint256 total = spent + requested;
                if (total > cfg.maxBuyQuoteAmount) revert MaxBuyExceeded(total, cfg.maxBuyQuoteAmount);
                guardBuyBlock[cfg.poolId] = uint40(block.number);
                // `total` is bounded by the uint96 config immediately above.
                // forge-lint: disable-next-line(unsafe-typecast)
                guardBuyAmount[cfg.poolId] = uint96(total);
            }
        }

        uint256 surgeSlicePips;
        uint256 snipeSlicePips;
        {
            uint256 surgePips;
            uint256 snipePips;
            uint256 room = MAX_TOTAL_FEE_PIPS - cfg.baseFeePips;
            if (cfg.maxFeePips > cfg.baseFeePips) {
                surgePips = swapContext.exactInput
                    ? _surgeComponent(cfg, swapContext, requested)
                    : uint256(cfg.maxFeePips - cfg.baseFeePips);
                if (surgePips > room) surgePips = room;
            }
            if (guardActive && swapContext.isBuy) {
                snipePips = cfg.snipeTaxPips;
                if (snipePips > room - surgePips) snipePips = room - surgePips;
            }
            // Exact-output sells are exempt: the unspecified currency there is the subject, and the
            // protocol must never hold subject tokens. Their whole surcharge stays with LPs.
            if (swapContext.isBuy || swapContext.exactInput) {
                surgeSlicePips = (surgePips * cfg.protocolShareBps) / BPS;
                snipeSlicePips = (snipePips * cfg.protocolShareBps) / BPS;
            }
            // The surcharge total is bounded by MAX_TOTAL_FEE_PIPS and fits uint24.
            // forge-lint: disable-next-line(unsafe-typecast)
            result.lpFeeSurchargePips = uint24(surgePips - surgeSlicePips + snipePips - snipeSlicePips);
        }

        if (swapContext.isBuy != swapContext.exactInput) {
            // Exact-output buys and exact-input sells settle the slice against the unspecified
            // quote leg in afterSwap. The exact-input depth curve cannot be recomputed there once
            // the swap has moved the pool, so the rate rides transient storage for this call only.
            _storePendingProtocolPips(cfg.poolId, surgeSlicePips + snipeSlicePips);
            return result;
        }
        if (swapContext.isBuy) {
            _beforeExactInputBuy(cfg, swapContext, requested, surgeSlicePips, snipeSlicePips, result);
        }
    }

    function afterSwapStateful(HookrStatefulModuleTypesV1.AfterSwapContext calldata context, bytes calldata config)
        external
        override
        returns (HookrStatefulModuleTypesV1.AfterSwapResult memory result)
    {
        Config memory cfg = _decodeAndValidate(config);
        _authorize(
            cfg, context.swapContext.poolId, context.swapContext.subject, context.swapContext.quote, keccak256(config)
        );
        _checkRuntime(cfg, context.swapContext);

        HookrModuleTypesV1.AfterSwapContext calldata swapContext = context.swapContext;
        int128 quoteDelta = _currencyDelta(swapContext, cfg.quote);
        uint256 rawQuote = _magnitude(quoteDelta);
        if (!(swapContext.isBuy && swapContext.exactInput)) {
            // Exact-output buys and exact-input sells have quote as the unspecified currency.
            // Exact-output sells remain exempt and carry nothing.
            uint256 slicePips = _consumePendingProtocolPips(cfg.poolId);
            if (slicePips != 0 && swapContext.isBuy != swapContext.exactInput) {
                uint256 fee = (rawQuote * slicePips) / PIPS;
                if (fee != 0) {
                    claimable[cfg.quote][cfg.protocolRecipient] += fee;
                    totalClaimLiability[cfg.quote] += fee;
                    _accrueProtocolShare(cfg.poolId, ProtocolStream.Surcharge, fee);
                    // `slicePips` is at most half of MAX_TOTAL_FEE_PIPS and fits uint24.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    result.quoteTakePips = uint24(slicePips);
                    // `rawQuote` is an int128 magnitude and the slice is a fraction of it.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    result.quoteTakeAmount = uint128(fee);
                    result.claimRecipient = address(this);
                    result.quoteAttributionKey = PROTOCOL_SHARE_ATTRIBUTION_KEY;
                }
            }
            return result;
        }

        uint256 requested = _specifiedAmount(swapContext.amountSpecified);
        uint256 expectedPoolInput = requested - context.aggregateSpecifiedQuoteTake;
        if (quoteDelta >= 0 || (context.aggregateSpecifiedQuoteTake != 0 && rawQuote != expectedPoolInput)) {
            revert PartialFillUnsupportedWithInputCuts();
        }

        bool guardActive = cfg.guardEndBlock != 0 && block.number < cfg.guardEndBlock;
        if (guardActive) {
            uint256 actualBuyInput = rawQuote + context.aggregateSpecifiedQuoteTake;
            if (cfg.maxBuyQuoteAmount != 0 && actualBuyInput < requested) {
                uint256 released = requested - actualBuyInput;
                guardBuyAmount[cfg.poolId] = uint96(uint256(guardBuyAmount[cfg.poolId]) - released);
            }
            guardLpEarnedQuote[
                cfg.poolId
            ] += _guardLpFeeWei(cfg.poolId, rawQuote, context.effectiveLpFeePips, swapContext.zeroForOne)
            + context.aggregateQuoteDonation;
        }

        if (cfg.burnBps == 0) return result;
        int128 rawSubject = _currencyDelta(swapContext, cfg.subject);
        if (rawSubject <= 0) return result;
        // The protocol's slice of the burn is charged in quote on the input leg (see
        // docs/FEE_MODEL_V2.md §4); only the remainder is burned.
        uint256 burnNetBps = uint256(cfg.burnBps) - (uint256(cfg.burnBps) * cfg.protocolShareBps) / BPS;
        uint256 burnAmount = (uint256(uint128(rawSubject)) * burnNetBps) / BPS;
        if (burnAmount == 0) return result;
        totalBurnedTokens[cfg.poolId] += burnAmount;
        // `burnNetBps` is bounded by `burnBps`, itself at most 1,000.
        // forge-lint: disable-next-line(unsafe-typecast)
        result.subjectTakeBps = uint16(burnNetBps);
        // Subject output is bounded to int128.max and the net burn weight is <=10%.
        // forge-lint: disable-next-line(unsafe-typecast)
        result.subjectTakeAmount = uint128(burnAmount);
        result.subjectRecipient = DEAD;
        result.subjectAttributionKey = AUTO_BURN_ATTRIBUTION_KEY;
        emit AutoBurn(cfg.poolId, burnAmount);
    }

    /// @notice Backed ERC-6909 balance this module holds for one quote currency.
    function claimBalance(address quote) public view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(quote).toId());
    }

    /// @notice Per-quote solvency check. Every quote currency is backed independently.
    function accountingInvariant(address quote) external view returns (bool) {
        return claimBalance(quote) >= totalClaimLiability[quote];
    }

    function claim(address quote) external {
        _claimTo(quote, msg.sender, msg.sender);
    }

    function claimTo(address quote, address to) external {
        if (to == address(0)) revert ZeroAddress();
        _claimTo(quote, msg.sender, to);
    }

    function _claimTo(address quote, address account, address to) internal {
        uint256 amount = claimable[quote][account];
        if (amount == 0) revert NothingToClaim();
        claimable[quote][account] = 0;
        totalClaimLiability[quote] -= amount;
        uint256 paid = abi.decode(poolManager.unlock(abi.encode(uint8(1), quote, to, amount)), (uint256));
        if (paid != amount) revert ClaimTransferFailed();
        emit Claimed(quote, account, to, amount);
    }

    /// @dev `take` settles native and ERC-20 currencies alike, so one path serves every quote.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 action, address quote, address to, uint256 amount) = abi.decode(data, (uint8, address, address, uint256));
        if (action != 1) revert HookNotCalled();
        Currency currency = Currency.wrap(quote);
        poolManager.burn(address(this), currency.toId(), amount);
        uint256 balanceBefore = _recipientBalance(quote, to);
        try poolManager.take(currency, to, amount) {}
        catch {
            revert ClaimTransferFailed();
        }
        uint256 balanceAfter = _recipientBalance(quote, to);
        if (balanceAfter < balanceBefore) revert ClaimTransferFailed();
        // `_claimTo` compares this against the debited amount, so a fee-on-transfer or otherwise
        // under-delivering quote reverts the claim instead of silently paying out less.
        return abi.encode(balanceAfter - balanceBefore);
    }

    /// @dev Bounded balance read of the claim recipient in the pool's own quote currency.
    function _recipientBalance(address quote, address to) internal view returns (uint256 balance) {
        if (quote == address(0)) return to.balance;
        bytes memory input = abi.encodeWithSelector(bytes4(0x70a08231), to);
        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(TOKEN_QUERY_GAS, quote, add(input, 0x20), mload(input), 0, 0x20)
            if iszero(eq(returndatasize(), 0x20)) { ok := 0 }
            word := mload(0)
        }
        if (!ok) revert ClaimTransferFailed();
        return word;
    }

    /// @dev Bounded `decimals()` read used only by the ERC-20 pot floor in `validateProtocolShare`.
    function _boundedQuoteDecimals(address quote) internal view returns (bool ok, uint256 value) {
        bytes memory input = abi.encodeWithSelector(bytes4(0x313ce567));
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(TOKEN_QUERY_GAS, quote, add(input, 0x20), mload(input), 0, 0x20)
            if iszero(eq(returndatasize(), 0x20)) { ok := 0 }
            value := mload(0)
        }
    }

    /// @dev Post-cap ceilings for the two surcharge components, shared by admission and runtime.
    function _surchargeCeiling(Config memory cfg) internal pure returns (uint256 surgeMax, uint256 snipeMax) {
        uint256 room = MAX_TOTAL_FEE_PIPS - cfg.baseFeePips;
        surgeMax = uint256(cfg.maxFeePips) - cfg.baseFeePips;
        if (surgeMax > room) surgeMax = room;
        snipeMax = cfg.snipeTaxPips;
        if (snipeMax > room - surgeMax) snipeMax = room - surgeMax;
    }

    /// @dev The exact-input buy cut leg. `result` is filled in place so the split, the ledgers and
    ///      the kernel's own recomputation all read from one arithmetic path.
    ///
    ///      The kernel recomputes the LP donation as
    ///      `floor((gross - floor(gross * royaltyBps / BPS)) * donationWeight / takeBps)`
    ///      and accepts nothing else, so the donation is computed here identically. Everything else
    ///      (pot, royalty, protocol) lives inside the claim bucket the kernel mints to this module,
    ///      and is split here: pot by weight, royalty on the post-protocol remainder, protocol as
    ///      the residual. That ordering is what makes the split underflow-free for every input.
    function _beforeExactInputBuy(
        Config memory cfg,
        HookrModuleTypesV1.SwapContext calldata swapContext,
        uint256 requested,
        uint256 surgeSlicePips,
        uint256 snipeSlicePips,
        HookrStatefulModuleTypesV1.BeforeSwapResult memory result
    ) internal {
        uint256 share = cfg.protocolShareBps;
        // The Nth-buy Pot is recipient-specific. Only a pinned Hookr router or quoter can
        // authenticate the recipient carried in HookrHookDataV1. Standard v4 routers use empty
        // hookData, so their swaps retain pool-wide mechanics while the pot leg is omitted instead
        // of crediting the router contract.
        uint256 activePotBps = swapContext.trustedCaller ? cfg.potBps : 0;
        // Floor at bps, then scale to pips: `(burnBps * share) / BPS` is exactly the weight the
        // subject burn gives up in afterSwap, so the two legs are exact rate complements.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 takePips = surgeSlicePips + snipeSlicePips + ((uint256(cfg.burnBps) * share) / BPS) * 100;

        BuyCut memory cut;
        cut.takeBps = uint256(cfg.lpBps) + activePotBps;
        if (
            (cut.takeBps != 0 || takePips != 0)
                && !_isCanonicalFullFillLimit(swapContext.zeroForOne, swapContext.sqrtPriceLimitX96)
        ) revert PartialFillUnsupportedWithInputCuts();

        uint256 pipTake = (requested * takePips) / PIPS;
        if (cut.takeBps != 0) {
            cut.gross = (requested * cut.takeBps) / BPS;
            cut.lpNetBps = uint256(cfg.lpBps) - (uint256(cfg.lpBps) * share) / BPS;
            uint256 potNetBps = activePotBps - (activePotBps * share) / BPS;
            uint256 protocolBps = cut.takeBps - cut.lpNetBps - potNetBps;
            uint256 donationBase = cut.gross - (cut.gross * cfg.royaltyBps) / BPS;
            // Mirrors the kernel's `quoteEscrowWeightBps == 0` branch exactly.
            cut.donation = protocolBps + potNetBps == 0 ? donationBase : (donationBase * cut.lpNetBps) / cut.takeBps;
            cut.potAdd = potNetBps == 0 ? 0 : (donationBase * potNetBps) / cut.takeBps;
            cut.royalty = ((cut.gross - (cut.gross * protocolBps) / cut.takeBps) * cfg.royaltyBps) / BPS;
            uint256 protocolCut = cut.gross - cut.donation - cut.potAdd - cut.royalty;
            cut.protocolLp = protocolBps == 0 ? 0 : (protocolCut * ((uint256(cfg.lpBps) * share) / BPS)) / protocolBps;
            cut.protocolPot = protocolCut - cut.protocolLp;
            _accrueCut(cfg, cut);
        }

        if (activePotBps != 0 && requested >= cfg.potMinBuyWei) {
            if (swapContext.recipient == address(0)) revert InvalidPotRecipient();
            _tickJackpot(cfg, swapContext.recipient);
        }

        if (pipTake != 0) {
            uint256 surgeWei = (requested * surgeSlicePips) / PIPS;
            uint256 snipeWei = (requested * snipeSlicePips) / PIPS;
            _accrueProtocolShare(cfg.poolId, ProtocolStream.Surcharge, surgeWei);
            _accrueProtocolShare(cfg.poolId, ProtocolStream.Guard, snipeWei);
            _accrueProtocolShare(cfg.poolId, ProtocolStream.Burn, pipTake - surgeWei - snipeWei);
            claimable[cfg.quote][cfg.protocolRecipient] += pipTake;
        }

        uint256 quoteTake = cut.gross + pipTake;
        uint256 claimAmount = quoteTake - cut.donation;
        if (claimAmount != 0) totalClaimLiability[cfg.quote] += claimAmount;
        // `takeBps` is bounded to 1,000 by config validation.
        // forge-lint: disable-next-line(unsafe-typecast)
        result.quoteTakeBps = uint16(cut.takeBps);
        // `takePips` is at most 300,000 under the module's own ceilings.
        // forge-lint: disable-next-line(unsafe-typecast)
        result.quoteTakePips = uint24(takePips);
        // forge-lint: disable-next-line(unsafe-typecast)
        result.quoteDonationWeightBps = uint16(cut.lpNetBps);
        // forge-lint: disable-next-line(unsafe-typecast)
        result.quoteEscrowWeightBps = uint16(cut.takeBps - cut.lpNetBps);
        result.quoteRoyaltyBps = cut.takeBps == 0 ? 0 : cfg.royaltyBps;
        // The kernel bounds the specified amount to int128.max; all configured takes are <100%.
        // forge-lint: disable-next-line(unsafe-typecast)
        result.quoteTakeAmount = uint128(quoteTake);
        // forge-lint: disable-next-line(unsafe-typecast)
        result.quoteDonationAmount = uint128(cut.donation);
        result.claimRecipient = claimAmount == 0 ? address(0) : address(this);
        result.attributionKey = quoteTake == 0 ? bytes32(0) : NATIVE_CUT_ATTRIBUTION_KEY;
    }

    /// @dev Writes one exact-input buy cut split to the ledgers. Every wei of `cut.gross` lands in
    ///      exactly one of donation, pot, royalty and protocol.
    function _accrueCut(Config memory cfg, BuyCut memory cut) internal {
        if (cut.gross == 0) return;
        if (cut.donation != 0) {
            totalLpDonatedWei[cfg.poolId] += cut.donation;
            emit LpRewardsDonated(cfg.poolId, cut.donation);
        }
        if (cut.potAdd != 0) potWei[cfg.poolId] += cut.potAdd;
        if (cut.royalty != 0) claimable[cfg.quote][cfg.royaltyTo] += cut.royalty;
        uint256 protocolCut = cut.protocolLp + cut.protocolPot;
        if (protocolCut != 0) claimable[cfg.quote][cfg.protocolRecipient] += protocolCut;
        _accrueProtocolShare(cfg.poolId, ProtocolStream.LpReward, cut.protocolLp);
        _accrueProtocolShare(cfg.poolId, ProtocolStream.Pot, cut.protocolPot);
        totalHookFeesWei[cfg.poolId] += cut.gross;
        emit HookFeesAccrued(cfg.poolId, 0, cut.donation, cut.potAdd, cut.royalty, cfg.royaltyTo);
    }

    function _accrueProtocolShare(bytes32 poolId, ProtocolStream stream, uint256 amount) internal {
        if (amount == 0) return;
        protocolShareByStream[poolId][uint8(stream)] += amount;
        totalProtocolShareWei[poolId] += amount;
        emit ProtocolShareAccrued(poolId, stream, amount);
    }

    function _tickJackpot(Config memory cfg, address recipient) internal {
        if (potLastQualifyingBlock[cfg.poolId] == block.number) return;
        potLastQualifyingBlock[cfg.poolId] = uint40(block.number);
        uint256 count = potBuyCount[cfg.poolId] + 1;
        potBuyCount[cfg.poolId] = count;
        if (count % cfg.potEveryNBuys != 0) return;
        uint256 pot = potWei[cfg.poolId];
        if (pot == 0) return;
        potWei[cfg.poolId] = 0;
        totalPotPaidWei[cfg.poolId] += pot;
        claimable[cfg.quote][recipient] += pot;
        emit JackpotHit(cfg.poolId, recipient, pot, count);
    }

    function _surgeComponent(Config memory cfg, HookrModuleTypesV1.SwapContext calldata context, uint256 amountIn)
        internal
        view
        returns (uint256 extraPips)
    {
        uint128 liquidity = poolManager.getLiquidity(PoolId.wrap(cfg.poolId));
        if (liquidity == 0) return 0;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(PoolId.wrap(cfg.poolId));
        if (sqrtPriceX96 == 0) return 0;
        uint256 reserveIn = context.zeroForOne
            ? (uint256(liquidity) << 96) / sqrtPriceX96
            : FullMath.mulDiv(uint256(liquidity), sqrtPriceX96, uint256(1) << 96);
        if (reserveIn == 0) return 0;
        uint256 ratio1e6 = (amountIn * uint256(cfg.surgeSens) * PIPS) / reserveIn;
        if (ratio1e6 > PIPS) ratio1e6 = PIPS;
        extraPips = (uint256(cfg.maxFeePips - cfg.baseFeePips) * ratio1e6) / PIPS;
    }

    function _guardLpFeeWei(bytes32 poolId, uint256 grossInputWei, uint256 lpFeePips, bool zeroForOne)
        internal
        view
        returns (uint256)
    {
        if (lpFeePips == 0 || grossInputWei == 0) return 0;
        (,, uint24 packedProtocolFee,) = poolManager.getSlot0(PoolId.wrap(poolId));
        uint256 protocolFeePips = zeroForOne ? uint256(packedProtocolFee & 0x0FFF) : uint256(packedProtocolFee >> 12);
        uint256 swapFeePips = protocolFeePips + lpFeePips - ((protocolFeePips * lpFeePips) / PIPS);
        uint256 totalSwapFeeWei = (grossInputWei * swapFeePips + PIPS - 1) / PIPS;
        uint256 protocolFeeWei = (grossInputWei * protocolFeePips) / PIPS;
        return totalSwapFeeWei - protocolFeeWei;
    }

    /// @dev Carries the deferred surcharge slice across one swap. Transient storage is cleared on
    ///      read and never survives the transaction; only the pool's own frozen kernel can reach
    ///      either accessor because `_authorize` runs first on both callbacks.
    function _storePendingProtocolPips(bytes32 poolId, uint256 slicePips) internal {
        bytes32 slot = keccak256(abi.encode(PENDING_PROTOCOL_PIPS_SEED, poolId));
        assembly ("memory-safe") {
            tstore(slot, slicePips)
        }
    }

    function _consumePendingProtocolPips(bytes32 poolId) internal returns (uint256 slicePips) {
        bytes32 slot = keccak256(abi.encode(PENDING_PROTOCOL_PIPS_SEED, poolId));
        assembly ("memory-safe") {
            slicePips := tload(slot)
            tstore(slot, 0)
        }
    }

    /// @dev Fails closed for a pool admitted outside the protocol-share ceiling or with a foreign
    ///      recipient: the pair `validateProtocolShare` checks is re-verified on every swap and
    ///      every liquidity add. The per-pool share itself is pinned by the frozen config hash.
    function _authorize(Config memory cfg, bytes32 poolId, address subject, address quote, bytes32 configHash)
        internal
        view
    {
        if (cfg.protocolShareBps > MAX_PROTOCOL_SHARE_BPS || cfg.protocolRecipient != protocolRecipient) {
            revert ProtocolShareNotEnforced();
        }
        HookrModuleTypesV1.StackCore memory core = stackRegistry.stack(PoolId.wrap(poolId));
        if (
            !core.configured || !core.initialized || core.kernel != msg.sender || msg.sender != cfg.kernel
                || core.subject != subject || subject != cfg.subject || core.quote != quote || quote != cfg.quote
                || IHookrFrozenStatefulModuleRegistryV1(address(stackRegistry))
                        .frozenModuleConfigHash(PoolId.wrap(poolId), address(this)) != configHash
        ) revert NotKernel();
    }

    function _checkRuntime(Config memory cfg, HookrModuleTypesV1.SwapContext calldata context) internal pure {
        if (
            context.poolId != cfg.poolId || context.subject != cfg.subject || context.quote != cfg.quote
                || context.recipient == address(0)
        ) revert InvalidRuntimeContext();
    }

    function _checkRuntime(Config memory cfg, HookrModuleTypesV1.AfterSwapContext calldata context) internal pure {
        if (
            context.poolId != cfg.poolId || context.subject != cfg.subject || context.quote != cfg.quote
                || context.recipient == address(0)
        ) revert InvalidRuntimeContext();
    }

    function _currencyDelta(HookrModuleTypesV1.AfterSwapContext calldata context, address currency)
        internal
        pure
        returns (int128 raw)
    {
        address other = currency == context.subject ? context.quote : context.subject;
        if (currency != context.subject && currency != context.quote) revert InvalidRuntimeContext();
        raw = uint160(currency) < uint160(other) ? context.amount0 : context.amount1;
    }

    function _magnitude(int128 raw) internal pure returns (uint256) {
        return raw < 0 ? uint256(-int256(raw)) : uint256(int256(raw));
    }

    function _specifiedAmount(int256 amountSpecified) internal pure returns (uint256 amount) {
        if (amountSpecified == 0 || amountSpecified == type(int256).min) revert InvalidRuntimeContext();
        return amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
    }

    function _isCanonicalFullFillLimit(bool zeroForOne, uint160 limit) internal pure returns (bool) {
        return zeroForOne ? limit == MIN_SQRT_PRICE_LIMIT : limit == MAX_SQRT_PRICE_LIMIT;
    }

    function _decodeAndValidate(bytes calldata config) internal pure returns (Config memory cfg) {
        if (config.length != 640) revert InvalidConfig();
        cfg = abi.decode(config, (Config));
        if (keccak256(config) != keccak256(abi.encode(cfg))) revert InvalidConfig();
        if (
            cfg.poolId == bytes32(0) || cfg.kernel == address(0) || cfg.subject == address(0)
                || cfg.subject == cfg.quote || cfg.baseFeePips > MAX_TOTAL_FEE_PIPS || cfg.maxFeePips < cfg.baseFeePips
                || cfg.maxFeePips > MAX_TOTAL_FEE_PIPS
                || uint256(cfg.baseFeePips) + cfg.snipeTaxPips > MAX_TOTAL_FEE_PIPS || cfg.surgeSens > 10
                || uint256(cfg.burnBps) + cfg.lpBps + cfg.potBps > 1_000 || cfg.royaltyBps > 1_000
        ) revert InvalidConfig();
        if (cfg.guardEndBlock == 0) {
            if (cfg.lockedLiquidityProvider != address(0) || cfg.snipeTaxPips != 0 || cfg.maxBuyQuoteAmount != 0) {
                revert InvalidConfig();
            }
        } else if (cfg.lockedLiquidityProvider == address(0)) {
            revert InvalidConfig();
        }
        if ((cfg.surgeSens == 0) != (cfg.maxFeePips == cfg.baseFeePips)) revert InvalidConfig();
        if (cfg.royaltyBps != 0 && (cfg.royaltyTo == address(0) || uint256(cfg.lpBps) + cfg.potBps == 0)) {
            revert InvalidConfig();
        }
        if (cfg.royaltyBps == 0 && cfg.royaltyTo != address(0)) revert InvalidConfig();
        if (
            cfg.potBps != 0
                && (cfg.potEveryNBuys < 2
                    || cfg.potEveryNBuys > 100_000
                    || (cfg.quote == address(0) ? cfg.potMinBuyWei < MIN_POT_BUY_WEI : cfg.potMinBuyWei == 0))
        ) revert InvalidConfig();
        if (cfg.potBps == 0 && (cfg.potEveryNBuys != 0 || cfg.potMinBuyWei != 0)) revert InvalidConfig();
        // The protocol share is capped, not fixed: the ceiling and a non-zero recipient are
        // structural, the exact share is the coordinator's tier decision proved at admission, and
        // the recipient identity needs an immutable-aware read. A zero share has no protocol leg.
        if (cfg.protocolShareBps > MAX_PROTOCOL_SHARE_BPS || cfg.protocolRecipient == address(0)) {
            revert InvalidConfig();
        }
    }
}
