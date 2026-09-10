// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title HookrHook
/// @notice One shared Uniswap v4 hook serving every pool graduated through the Hookr launchpad.
///         Per-pool behavior is configured once by the launchpad at graduation and is immutable
///         afterwards. Blocks compose per launch:
///
///         - ANTI-SNIPE : guard window measured in blocks; a CUMULATIVE per-pool-per-block buy
///                        buy cap; extra LP fee ("snipe tax") charged on BUYS ONLY while the guard
///                        is active. Exact-output buys are blocked during the guard so the cap
///                        cannot be bypassed, and the cap accumulates across every buy in a block
///                        so it cannot be spent repeatedly inside one transaction. Sellers are
///                        never taxed by the guard. Outside liquidity additions are blocked only
///                        for this finite window so guarded LP fees remain attributable to the
///                        launchpad's locked positions; permissionless LP resumes at its end.
///                        What those locked positions earn during the window is
///                        recorded (`guardLpEarnedWei`) and withheld from the creator's fee share
///                        by the launchpad, so the tax is not rebated to a creator who paid it.
///         - SURGE FEES : LP fee scales with trade size relative to in-range pool depth
///                        (oracle-free volatility proxy), from baseFee up to maxFee.
///         - AUTO BURN   : a cut of the actual token output of every exact-input buy is sent
///                        directly to 0xdEaD in `afterSwap`. No quote-asset vault or market buy exists,
///                        so there is no permissionless order for searchers to sandwich.
///         - LP REWARDS : a cut of every exact-input buy is donated to in-range LPs inside the
///                        very swap that accrues it. No LP vault is ever held.
///         - JACKPOT    : a cut of every exact-input buy fills a deterministic pot; every Nth
///                        qualifying buy wins it (pull-payment backed by ERC-6909 claim units
///                        in the pool quote currency).
///                        A pool can advance its
///                        counter at most once per block, so a caller cannot atomically manufacture
///                        every remaining slot. There is no permissionless pot-flush path: a funded
///                        pot remains claim-backed for the next scheduled winner.
///
///         Honesty notes (also disclosed in the UI):
///         - The jackpot is NOT random and claims no randomness. A per-pool counter increments on
///           every qualifying buy and the buy whose count is a multiple of `potEveryNBuys` wins.
///           The counter is public (`potBuyCount`), so anyone can see how close the pot is.
///         - Hook fee cuts apply to exact-input buys only. Sells and exact-output buys pay only
///           the LP fee.
///         - A pot-qualifying buy must bind a canonical nonzero output recipient in hookData.
///           Missing or malformed recipient data reverts instead of funding the pot while
///           silently suppressing its public counter.
///         - `burnBps` is an output-token burn. The legacy `burnTriggerWei` config field and
///           `buybackAndBurn` entrypoint remain ABI-readable for migration tooling, but a new
///           config must set the field to zero so no caller can mistake it for an active trigger.
contract HookrHook is IHooks, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    // ---------------------------------------------------------------- constants

    // beforeInitialize | beforeAddLiquidity | beforeSwap | afterSwap |
    // beforeSwapReturnsDelta | afterSwapReturnsDelta
    uint160 public constant REQUIRED_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    uint24 internal constant OVERRIDE_FEE_FLAG = 0x400000;
    /// @notice Tick spacing every graduated pool is created with. `_poolKeyFor` relies on this.
    int24 internal constant TICK_SPACING = 60;
    uint24 internal constant MAX_TOTAL_FEE_PIPS = 500_000; // 50% hard ceiling on LP fee incl. snipe tax
    uint160 public constant MIN_SQRT_PRICE_LIMIT = 4295128740;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PIPS = 1e6; // fee denominator, 1e6 = 100%
    /// @notice Smallest buy that may advance a deterministic pot counter. This is enforced by both
    ///         the launchpad and the hook so a blueprint cannot create one-wei schedule slots.
    uint96 public constant MIN_POT_BUY_WEI = 0.001 ether;
    /// @notice Smallest quote-asset amount a buyback execution may spend. Below this the burn is
    ///         not worth the swap it costs anyone.
    uint96 public constant MIN_BUYBACK_SPEND_WEI = 0.001 ether;
    /// @notice Execution-time slippage bound for the nested buyback swap, in bps below the price
    ///         observed when execution starts. Bounds what a competing transaction can extract by
    ///     moving the pool between trigger and fill.
    uint16 public constant MAX_BUYBACK_SLIP_BPS = 500;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    address public immutable launchpad;

    // ---------------------------------------------------------------- per-pool config

    struct PoolConfig {
        bool initialized;
        uint40 guardEndBlock; // block number at which the anti-snipe guard ends (0 = no guard)
        uint24 baseFeePips; // LP fee once calm (pips, 1e6 = 100%)
        uint24 maxFeePips; // surge ceiling; == baseFeePips disables surge
        uint24 snipeTaxPips; // extra LP fee during guard
        uint16 surgeSens; // 1-10 multiplier on trade-size/depth ratio
        uint16 burnBps; // cut of exact-input buy token output -> 0xdEaD
        uint16 lpBps; // cut -> donated to in-range LPs in the same swap
        uint16 potBps; // cut -> jackpot pot
        uint16 royaltyBps; // share of LP/pot cuts routed to the blueprint author
        uint32 potEveryNBuys; // every Nth qualifying buy wins the pot (deterministic, not random)
        uint96 maxBuyWei; // cumulative quote-asset cap per pool per block during guard (0 = uncapped)
        uint96 potMinBuyWei; // buys below this do not count toward the pot
        uint96 burnTriggerWei; // deprecated v2 field; new configs MUST set this to zero
        // ARB BUYBACK: quote-asset cut accrues claims; anyone may execute once the live price sits
        // `buybackDrawdownBps` below the pool's running cheapest-anchor, subject to caps/cooldown.
        uint16 buybackBps;
        uint16 buybackDrawdownBps;
        uint32 buybackCooldownBlocks;
        uint96 buybackMinSpendWei;
        uint96 buybackMaxSpendWei;
        address royaltyTo;
        address token; // currency1 of the pool
    }

    mapping(PoolId => PoolConfig) public poolConfig;

    // Live ledgers. There is deliberately NO physical LP, pot, royal or burn vault: LP cuts
    // are donated inside the swap; pot/royalty obligations are backed 1:1 by PoolManager claim units
    // in the pool quote currency; auto-burn takes token output directly.
    // `burnVaultWei` remains as an always-zero compatibility getter for indexers that know the v2 ABI.
    mapping(PoolId => uint256) public potWei;
    mapping(PoolId => uint256) public burnVaultWei;

    /// @notice Qualifying buys counted so far, per pool. The buy that makes this a multiple of
    ///         `potEveryNBuys` takes the pot. Public so the UI can show "N buys to go".
    mapping(PoolId => uint256) public potBuyCount;
    /// @notice Last block in which this pool advanced its qualifying-buy counter. At most one
    ///         qualifying slot may be consumed per pool per block.
    mapping(PoolId => uint40) public potLastQualifyingBlock;

    /// @notice Quote-asset accrued for the buyback reserve, 1:1 backed by PoolManager ERC-6909
    ///         claims minted from the same cut as pot/royalty obligations. Only ever spent into
    ///         this pool's own swap, with the output taken straight to 0xdEaD.
    mapping(PoolId => uint256) public buybackAccruedWei;
    /// @notice Running cheapest observed price, stored as sqrtPriceX96 (higher sqrt = cheaper
    ///         token, since price is tokens-per-quote). Ratchets up on completed swaps; a buyback
    ///     may only execute when the live sqrt is `drawdownBps` ABOVE this anchor. Reset to the
    ///     post-execution price so one drawdown cannot trigger repeatedly.
    mapping(PoolId => uint160) public buybackAnchorSqrtX96;
    /// @notice Last block in which this pool executed a buyback. Cooldown is measured from it.
    mapping(PoolId => uint40) public buybackLastExecBlock;

    /// @notice Last block in which this pool admitted a guarded buy, and the quote-asset admitted in it.
    ///         Together they make `maxBuyWei` a per-BLOCK budget rather than a per-swap one, so a
    ///         caller cannot loop capped buys inside one transaction. Public so the UI can show how
    ///         much of the current block's budget is left instead of guessing.
    mapping(PoolId => uint40) public guardBuyBlock;
    mapping(PoolId => uint96) public guardBuyWei;

    /// @notice Conservatively accounted quote-asset the launchpad-owned LPs earned while the anti-snipe
    ///         guard was active: the LP fee charged on guarded buys plus the in-swap LP donation.
    ///         Exact for one-step swaps; a multi-tick swap may omit rounding dust, never overstate.
    ///         Cumulative and never decremented.
    /// @dev Read by `HookrLaunchpad.collectPoolFees`, which withholds this much of the collected
    ///      quote-asset from the creator's share. Without it the snipe tax flows back to whoever paid it
    ///      whenever that party is also the creator. This is an accrual figure computed from the
    ///      swap inputs the hook sees, not a balance the hook holds — the quote-asset itself is fee growth
    ///      inside the PoolManager, on the launchpad's own position.
    mapping(PoolId => uint256) public guardLpEarnedWei;

    // lifetime aggregates (token-page stats)
    mapping(PoolId => uint256) public totalHookFeesWei;
    mapping(PoolId => uint256) public totalBurnedTokens;
    mapping(PoolId => uint256) public totalLpDonatedWei;
    mapping(PoolId => uint256) public totalPotPaidWei;

    // pull payments: jackpot wins + blueprint royalties
    mapping(address => uint256) public claimableWei;
    mapping(address => mapping(address => uint256)) public claimableByQuoteWei;
    mapping(PoolId => address) public poolQuoteToken;

    /// @dev Effective fee carried across the PoolManager's paired beforeSwap/afterSwap callbacks
    ///      only for guarded buys with no quote-side hook cut. Those are the one guarded shape allowed
    ///      to partially fill, so afterSwap must price the guard accrual from the actual pool input
    ///      rather than the larger amount the caller requested. PoolManager does not pass the fee
    ///      override back to afterSwap; this internal scratch slot preserves it for that callback.
    ///      There is no untrusted external call between the write and delete (the only call is a
    ///      donation on cut-bearing paths, which never uses this slot and carries no donate flags).
    ///      It is appended after every pre-existing ledger so the new release preserves their slots.
    mapping(PoolId => uint24) internal guardFeePipsInFlight;

    // ---------------------------------------------------------------- events

    event PoolConfigured(PoolId indexed poolId, address indexed token, PoolConfig cfg);
    event HookFeesAccrued(
        PoolId indexed poolId,
        uint256 burnWei,
        uint256 lpWei,
        uint256 potWeiAdded,
        uint256 royaltyWei,
        address royaltyTo
    );
    event JackpotHit(PoolId indexed poolId, address indexed winner, uint256 amountWei, uint256 buyCount);
    event BuybackBurn(PoolId indexed poolId, uint256 ethIn, uint256 tokensBurned);
    event BuybackAccrued(PoolId indexed poolId, uint256 weiAdded);
    event BuybackAnchorUpdated(PoolId indexed poolId, uint160 anchorSqrtX96);
    event AutoBurn(PoolId indexed poolId, uint256 tokensBurned);
    event LpRewardsDonated(PoolId indexed poolId, uint256 amountWei);
    event Claimed(address indexed account, uint256 amountWei);

    // ---------------------------------------------------------------- errors

    error NotPoolManager();
    error NotLaunchpad();
    error AlreadyConfigured();
    error NotConfigured();
    error BadConfig();
    error MaxBuyExceeded(uint256 attemptedWei, uint256 maxWei);
    error ExactOutputBlockedDuringGuard();
    error PartialFillUnsupportedWithInputCuts();
    error ExternalLiquidityBlockedDuringGuard();
    error BuybackDisabled();
    error BuybackCooldown();
    error BuybackNotArmed(uint256 anchorSqrtX96, uint256 currentSqrtX96, uint256 drawdownBps);
    error BuybackNoOutput();
    error InvalidPotRecipient();
    error NothingToClaim();
    error ZeroAddress();
    error EthTransferFailed();
    error HookNotCalled(); // unreachable callbacks

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address launchpad_) {
        poolManager = poolManager_;
        launchpad = launchpad_;
    }

    /// @notice Stable deployment identity for post-deploy readbacks and agent health checks.
    function contractName() external pure returns (string memory) {
        return "HookrHook";
    }

    /// @notice Candidate generation. Runtime code hash remains the release authority.
    function contractVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    // ---------------------------------------------------------------- launchpad wiring

    /// @notice Called by the launchpad immediately before pool initialization. One-shot.
    function configurePool(PoolKey calldata key, PoolConfig memory cfg) external {
        if (msg.sender != launchpad) revert NotLaunchpad();
        PoolId id = key.toId();
        if (poolConfig[id].initialized) revert AlreadyConfigured();
        if (cfg.baseFeePips > MAX_TOTAL_FEE_PIPS || cfg.maxFeePips > MAX_TOTAL_FEE_PIPS) revert BadConfig();
        if (cfg.maxFeePips < cfg.baseFeePips) revert BadConfig();
        if (uint256(cfg.baseFeePips) + cfg.snipeTaxPips > MAX_TOTAL_FEE_PIPS) revert BadConfig();
        if (uint256(cfg.burnBps) + cfg.lpBps + cfg.potBps + cfg.buybackBps > 1000) revert BadConfig(); // <=10% of buy size
        if (cfg.burnTriggerWei != 0) revert BadConfig(); // compatibility-only field, never silently ignored
        if (cfg.buybackBps == 0) {
            // Fail closed: a disabled block must not carry live-looking parameters.
            if (
                cfg.buybackMinSpendWei != 0 || cfg.buybackMaxSpendWei != 0 || cfg.buybackDrawdownBps != 0
                    || cfg.buybackCooldownBlocks != 0
            ) revert BadConfig();
        } else {
            if (cfg.buybackMinSpendWei < MIN_BUYBACK_SPEND_WEI) revert BadConfig();
            if (cfg.buybackMaxSpendWei < cfg.buybackMinSpendWei) revert BadConfig();
            if (cfg.buybackDrawdownBps < 10 || cfg.buybackDrawdownBps > 9900) revert BadConfig();
            if (cfg.buybackCooldownBlocks < 1 || cfg.buybackCooldownBlocks > 100_000) revert BadConfig();
        }
        if (cfg.royaltyBps > 1000) revert BadConfig(); // <=10% of the cuts
        if (cfg.royaltyBps > 0 && uint256(cfg.lpBps) + cfg.potBps == 0) revert BadConfig();
        if (cfg.potBps > 0) {
            if (cfg.potEveryNBuys < 2 || cfg.potEveryNBuys > 100_000) revert BadConfig();
            if (cfg.potMinBuyWei < MIN_POT_BUY_WEI) revert BadConfig();
        }
        if (cfg.surgeSens > 10) revert BadConfig();
        cfg.initialized = true;
        cfg.token = Currency.unwrap(key.currency1);
        poolQuoteToken[id] = Currency.unwrap(key.currency0);
        poolConfig[id] = cfg;
        emit PoolConfigured(id, cfg.token, cfg);
    }

    /// @notice Push the configured base fee into the pool's cached dynamic LP fee.
    ///         Called by the launchpad right after initialization; also callable by anyone later
    ///         (it only re-syncs to the same configured base fee).
    function syncBaseFee(PoolKey calldata key) external {
        PoolConfig storage cfg = poolConfig[key.toId()];
        if (!cfg.initialized) revert NotConfigured();
        poolManager.updateDynamicLPFee(key, cfg.baseFeePips);
    }

    // ---------------------------------------------------------------- IHooks: used callbacks

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        // Only the launchpad may attach this hook, only with the dynamic-fee flag, and only
        // after the pool's behavior has been configured.
        if (sender != launchpad) revert NotLaunchpad();
        if (key.fee != DYNAMIC_FEE_FLAG) revert BadConfig();
        if (!poolConfig[key.toId()].initialized) revert NotConfigured();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig storage cfg = poolConfig[id];
        if (!cfg.initialized) revert NotConfigured();

        bool exactIn = params.amountSpecified < 0;
        bool isBuy = params.zeroForOne; // quote (currency0) -> token (currency1)
        bool guardActive = cfg.guardEndBlock != 0 && block.number < cfg.guardEndBlock;
        Currency quoteCurrency = key.currency0;

        // ---- anti-snipe guard
        if (guardActive && isBuy) {
            if (!exactIn) revert ExactOutputBlockedDuringGuard();
            uint256 inputIn = uint256(-params.amountSpecified);
            if (cfg.maxBuyWei != 0) {
                // The cap is CUMULATIVE per pool per block, not per swap. A per-swap cap bounds one
                // call and nothing else: a contract can loop capped buys inside a single
                // transaction and take an arbitrary share of the float at the opening price, which
                // is exactly the behavior the guard exists to stop. Measured against an instant
                // launch, a looping creator held 49-66% of the float for the price of the first
                // tick. Accumulating per (pool, block) is the same shape `_tickJackpot` uses for
                // the pot, and for the same reason: a block is the finest granularity at which
                // "different callers" is a real distinction rather than one caller with more
                // addresses.
                uint256 spent = guardBuyBlock[id] == block.number ? guardBuyWei[id] : 0;
                uint256 total = spent + inputIn;
                // Reports the CUMULATIVE figure, so the revert says what was actually refused.
                if (total > cfg.maxBuyWei) revert MaxBuyExceeded(total, cfg.maxBuyWei);
                guardBuyBlock[id] = uint40(block.number);
                // casting to 'uint96' is safe: `total` is bounded by `cfg.maxBuyWei`, a uint96,
                // on the line above.
                // forge-lint: disable-next-line(unsafe-typecast)
                guardBuyWei[id] = uint96(total);
            }
        }

        // ---- LP fee: base, plus surge by trade size, plus snipe tax on guarded BUYS only.
        //      The guard exists to price snipers out of the opening blocks; taxing exits would
        //      trap holders, which the product has never claimed to do.
        uint256 feePips = cfg.baseFeePips;
        if (cfg.maxFeePips > cfg.baseFeePips && exactIn) {
            feePips += _surgeComponent(id, cfg, params);
        }
        if (guardActive && isBuy) {
            feePips += cfg.snipeTaxPips;
        }
        if (feePips > MAX_TOTAL_FEE_PIPS) feePips = MAX_TOTAL_FEE_PIPS;

        // ---- hook fee cuts on exact-input buys
        uint256 hookFeeWei;
        uint256 lpDonatedWei;
        if (isBuy && exactIn) {
            // Auto-burn is taken from actual token output in afterSwap. Only the input-currency LP and
            // deterministic-pot cuts are returned as a beforeSwap specified delta.
            uint256 totalCutBps = uint256(cfg.lpBps) + cfg.potBps;
            if (totalCutBps > 0) {
                // The specified-currency cut is computed before v4 knows the fill. Require the
                // canonical buy limit here, then reconcile the raw pool input in afterSwap. The
                // afterSwap check also covers exhaustion at the usable full-range POL tick, which
                // sits above v4's absolute minimum price.
                if (params.sqrtPriceLimitX96 != MIN_SQRT_PRICE_LIMIT) {
                    revert PartialFillUnsupportedWithInputCuts();
                }
                uint256 inputIn = uint256(-params.amountSpecified);
                hookFeeWei = (inputIn * totalCutBps) / BPS;
                if (hookFeeWei > 0) {
                    // Split the cut. The LP share is donated to in-range LPs right here, inside
                    // the PoolManager unlock we are already holding: it stays in the pool and
                    // never becomes a balance anyone could flush to themselves. Pot and royalty
                    // obligations remain 1:1 backed by quote-asset PoolManager ERC-6909 claims.
                    lpDonatedWei = _accrue(id, cfg, key, hookFeeWei, totalCutBps);
                    uint256 takeWei = hookFeeWei - lpDonatedWei;
                    if (takeWei > 0) {
                        // Mint a quote-asset ERC-6909 claim instead of physically pulling quote
                        // the swapper settles. This nets against the hook's positive specified
                        // delta at unlock end and removes dependence on PoolManager's pre-existing
                        // global quote balance.
                        poolManager.mint(address(this), quoteCurrency.toId(), takeWei);
                    }
                    // Both the donate debit and minted-claim credit are covered by the
                    // +hookFeeWei specified delta returned below, so the hook nets to zero.
                }
                // Jackpot: count the qualifying buy, and pay out if it is the Nth one.
                if (cfg.potBps > 0 && inputIn >= cfg.potMinBuyWei) {
                    (address recipient, bool valid) = _decodeRecipient(hookData);
                    if (!valid || recipient == address(0)) revert InvalidPotRecipient();
                    _tickJackpot(id, cfg, recipient, Currency.unwrap(quoteCurrency));
                }
            }
        }

        // ---- quarantine what the LPs earn while the guard is live.
        // The snipe tax is an LP fee. Outside additions are blocked while the guard is active, so
        // it lands in fee growth the launchpad's locked positions later collect and split with the
        // creator. When the creator IS the buyer paying it — always possible, and on the instant
        // path possible in the launch transaction — up to `creatorFeeBps` of it comes straight
        // back. Measured: a creator's net cost of a guarded buy was 20% of the tax against 100%
        // for a third party, claimable in the same block. That is not a tax, it is a rebate.
        //
        // So conservatively account launchpad-owned quote-asset fees earned while the guard is
        // live, and let `HookrLaunchpad.collectPoolFees` withhold no more than that from the creator
        // side. The figure uses v4's protocol-net LP fee arithmetic on the input that reaches the
        // swap — the specified amount less the hook's own cut — plus the in-swap LP donation. It is
        // cumulative and never decremented; the launchpad tracks how much it already withheld.
        if (guardActive && isBuy) {
            if (uint256(cfg.lpBps) + cfg.potBps == 0) {
                // A no-cut exact-input swap may stop at its caller-selected price limit. Carry the
                // effective override into afterSwap, where v4 exposes the amount it truly used.
                // Booking the request here lets a nearly-full refund create phantom guarded fees.
                guardFeePipsInFlight[id] = uint24(feePips);
            } else {
                // Quote-side input cuts already require a complete fill in afterSwap, so the pool input
                // is known here. Book its protocol-net LP fee plus the in-swap LP donation.
                uint256 swapIn = uint256(-params.amountSpecified) - hookFeeWei;
                guardLpEarnedWei[id] += _guardLpFeeWei(id, swapIn, feePips) + lpDonatedWei;
            }
        }

        return (
            IHooks.beforeSwap.selector,
            hookFeeWei == 0 ? BeforeSwapDeltaLibrary.ZERO_DELTA : toBeforeSwapDelta(int128(uint128(hookFeeWei)), 0),
            uint24(feePips) | OVERRIDE_FEE_FLAG
        );
    }

    // ---------------------------------------------------------------- fee internals

    function _surgeComponent(PoolId id, PoolConfig storage cfg, SwapParams calldata params)
        internal
        view
        returns (uint256 extraPips)
    {
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity == 0) return 0;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) return 0;

        uint256 amountIn = uint256(-params.amountSpecified);
        // Virtual reserve of the input currency at the current price (xy=k view of in-range depth).
        uint256 reserveIn = params.zeroForOne
            ? (uint256(liquidity) << 96) / sqrtPriceX96  // quote side
            : (uint256(liquidity) * sqrtPriceX96) >> 96; // output token side
        if (reserveIn == 0) return 0;

        uint256 ratio1e6 = (amountIn * uint256(cfg.surgeSens) * 1e6) / reserveIn;
        if (ratio1e6 > 1e6) ratio1e6 = 1e6;
        extraPips = (uint256(cfg.maxFeePips - cfg.baseFeePips) * ratio1e6) / 1e6;
    }

    /// @dev LP fee earned from `grossInputWei`, net of PoolManager protocol fee.
    ///      v4 takes the protocol fee first, then the configured LP fee from the remainder; treating
    ///      the LP override as a fee on the whole input can overstate the launchpad's earnings and
    ///      create phantom guard debt as soon as the external protocol-fee controller enables a
    ///      fee. The combined-fee expression and rounding directions below mirror Pool.sol.
    ///
    ///      A single swap step is exact. Across initialized-tick crossings this is deliberately a
    ///      lower bound: v4 rounds the total fee up and protocol fee down in every step, whereas we
    ///      only receive the aggregate BalanceDelta. Therefore it can under-withhold rounding dust
    ///      but can never divert later creator fees for LP income the launchpad did not earn.
    function _guardLpFeeWei(PoolId id, uint256 grossInputWei, uint256 lpFeePips) internal view returns (uint256) {
        // Pool.sol treats `swapFee == protocolFee` specially: every fee wei is protocol-owned.
        // Without this branch, ceil(gross * pips) - floor(gross * pips) can invent one LP wei.
        if (lpFeePips == 0 || grossInputWei == 0) return 0;
        (,, uint24 packedProtocolFee,) = poolManager.getSlot0(id);
        uint256 protocolFeePips = uint256(packedProtocolFee & 0x0FFF);
        uint256 swapFeePips = protocolFeePips + lpFeePips - ((protocolFeePips * lpFeePips) / PIPS);
        uint256 totalSwapFeeWei = (grossInputWei * swapFeePips + PIPS - 1) / PIPS;
        uint256 protocolFeeWei = (grossInputWei * protocolFeePips) / PIPS;
        return totalSwapFeeWei - protocolFeeWei;
    }

    /// @dev Splits the hook cut and immediately donates the LP share to in-range LPs.
    /// @return lpDonated The wei handed straight to LPs; the caller must NOT `take` this part,
    ///         it stays inside the PoolManager as pool fee growth.
    function _accrue(PoolId id, PoolConfig storage cfg, PoolKey calldata key, uint256 hookFeeWei, uint256 totalCutBps)
        internal
        returns (uint256 lpDonated)
    {
        address quoteToken = Currency.unwrap(key.currency0);
        uint256 royaltyWei;
        if (cfg.royaltyBps > 0 && cfg.royaltyTo != address(0)) {
            royaltyWei = (hookFeeWei * cfg.royaltyBps) / BPS;
            _creditClaim(cfg.royaltyTo, quoteToken, royaltyWei);
        }
        uint256 remaining = hookFeeWei - royaltyWei;
        // Split the remainder pro-rata across the enabled cuts. The buyback reserve absorbs
        // rounding dust when enabled (it is a claim-backed ledger, not a per-recipient credit);
        // otherwise the legacy dust rules apply.
        uint256 lpAdd = (remaining * cfg.lpBps) / totalCutBps;
        uint256 potAdd = (remaining * cfg.potBps) / totalCutBps;
        uint256 buybackAdd;
        if (cfg.buybackBps > 0) {
            buybackAdd = remaining - lpAdd - potAdd; // buyback absorbs rounding dust
        } else {
            potAdd = remaining - lpAdd; // pot absorbs rounding dust
            if (cfg.potBps == 0) {
                // No pot: all rounding dust belongs to the LP donation.
                lpAdd += potAdd;
                potAdd = 0;
            }
        }
        if (buybackAdd > 0) {
            buybackAccruedWei[id] += buybackAdd;
            emit BuybackAccrued(id, buybackAdd);
        }
        if (lpAdd > 0) {
            // `donate` credits in-range liquidity directly. Safe to call from inside beforeSwap:
            // we are already within PoolManager's unlock, and this hook holds no donate flags so
            // PoolManager makes no re-entrant callback here.
            if (poolManager.getLiquidity(id) != 0) {
                poolManager.donate(key, lpAdd, 0, "");
                lpDonated = lpAdd;
                totalLpDonatedWei[id] += lpAdd;
                emit LpRewardsDonated(id, lpAdd);
            } else {
                // A graduated pool always has full-range POL. Reverting here keeps the buyer's
                // funds with them instead of silently redirecting an LP-designated cut.
                revert BadConfig();
            }
        }
        if (potAdd > 0) {
            potWei[id] += potAdd;
        }
        totalHookFeesWei[id] += hookFeeWei;
        emit HookFeesAccrued(id, 0, lpAdd, potAdd, royaltyWei, cfg.royaltyTo);
    }

    /// @dev Deterministic, advertised-as-such jackpot. Every qualifying buy bumps a public
    ///      counter and the buy that lands on a multiple of `potEveryNBuys` takes the pot.
    ///      No randomness is generated or claimed. Choosing a different `recipient` cannot move
    ///      the schedule, and at most one qualifying slot may be consumed per pool per block.
    function _tickJackpot(PoolId id, PoolConfig storage cfg, address recipient, address quoteToken) internal {
        if (potLastQualifyingBlock[id] == block.number) return;
        potLastQualifyingBlock[id] = uint40(block.number);
        uint256 count = potBuyCount[id] + 1;
        potBuyCount[id] = count;
        if (count % cfg.potEveryNBuys != 0) return;
        uint256 pot = potWei[id];
        if (pot == 0) return;
        potWei[id] = 0;
        totalPotPaidWei[id] += pot;
        _creditClaim(recipient, quoteToken, pot);
        emit JackpotHit(id, recipient, pot, count);
    }

    function _creditClaim(address recipient, address quoteToken, uint256 amount) internal {
        if (recipient == address(0) || amount == 0) return;
        if (quoteToken == address(0)) {
            claimableWei[recipient] += amount;
        } else {
            claimableByQuoteWei[recipient][quoteToken] += amount;
        }
    }

    /// @dev Decode canonical `abi.encode(address)`. The caller fails closed on a qualifying pot
    ///      buy so invalid payloads cannot fund the pot while silently suppressing its counter.
    function _decodeRecipient(bytes calldata hookData) internal pure returns (address recipient, bool valid) {
        if (hookData.length != 32) return (address(0), false);
        uint256 raw;
        assembly ("memory-safe") {
            raw := calldataload(hookData.offset)
        }
        if (raw >> 160 != 0) return (address(0), false);
        return (address(uint160(raw)), true);
    }

    /// @dev Rebuild a pool's key from the per-pool ledgers. Every graduated pool shares the same
    ///      static fee flag, tick spacing, and this hook, so the id round-trips by construction.
    function _poolKeyFor(PoolId id, PoolConfig storage cfg) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(poolQuoteToken[id]),
            currency1: Currency.wrap(cfg.token),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    // ---------------------------------------------------------------- public triggers

    /// @notice Legacy v2 entrypoint. V3 candidates burn token output directly in `afterSwap`, so
    ///         there is no dedicated vault and no permissionless market order to execute.
    function buybackAndBurn(PoolKey calldata, uint256) external pure {
        revert BuybackDisabled();
    }

    // ---------------------------------------------------------------- arb buyback block

    /// @notice Live readiness of a pool's buyback: armed when the reserve can fund `minSpend`,
    ///         the cooldown has elapsed, and the live price sits at least `drawdownBps` below the
    ///         running anchor (sqrt above it — higher sqrt is a cheaper token).
    function buybackStatus(PoolId id)
        public
        view
        returns (bool ready, uint256 spendWei, uint256 currentSqrtX96, uint160 anchorSqrtX96)
    {
        PoolConfig storage cfg = poolConfig[id];
        if (!cfg.initialized || cfg.buybackBps == 0) return (false, 0, 0, 0);
        (currentSqrtX96,,,) = poolManager.getSlot0(id);
        anchorSqrtX96 = buybackAnchorSqrtX96[id];
        if (currentSqrtX96 == 0 || anchorSqrtX96 == 0) return (false, 0, currentSqrtX96, anchorSqrtX96);
        if (
            buybackLastExecBlock[id] != 0
                && block.number < uint256(buybackLastExecBlock[id]) + cfg.buybackCooldownBlocks
        ) return (false, 0, currentSqrtX96, anchorSqrtX96);
        uint256 accrued = buybackAccruedWei[id];
        if (accrued < cfg.buybackMinSpendWei) return (false, 0, currentSqrtX96, anchorSqrtX96);
        // Drawdown check in sqrt space: trigger when live sqrt is drawdownBps above the anchor.
        // Computed with a 1e18-scaled ratio so small bps values do not floor to zero.
        uint256 ratio1e18 = (uint256(currentSqrtX96) * 1e18) / uint256(anchorSqrtX96);
        uint256 threshold1e18 = 1e18 + (uint256(cfg.buybackDrawdownBps) * 1e18) / BPS;
        if (ratio1e18 < threshold1e18) return (false, 0, currentSqrtX96, anchorSqrtX96);
        spendWei = accrued > cfg.buybackMaxSpendWei ? cfg.buybackMaxSpendWei : accrued;
        return (true, spendWei, currentSqrtX96, anchorSqrtX96);
    }

    /// @notice Execute one capped buyback against THIS pool using only accrued quote-asset fees.
    ///         Permissionless and deterministic: anyone may pull the trigger, the conditions are
    ///         re-checked atomically inside the fresh unlock, the spend is bounded per execution,
    ///         and every token purchased goes straight to 0xdEaD. There is no keeper and no
    ///         standing order to sandwich — between trigger and fill the price may move at most
    ///         MAX_BUYBACK_SLIP_BPS before execution stops filling.
    /// @dev Must never be called from inside another PoolManager unlock (e.g. a swap callback):
    ///      PoolManager reverts on nested unlocks, which is exactly the guard we want.
    function executeBuyback(PoolKey calldata key) external {
        PoolConfig storage cfg = poolConfig[key.toId()];
        if (!cfg.initialized) revert NotConfigured();
        if (cfg.buybackBps == 0) revert BuybackDisabled();
        poolManager.unlock(abi.encode(uint8(2), key.toId()));
    }

    /// @notice Native quote-pool claim units backing every pot and royalty obligation.
    function nativeClaimBalance() public view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(address(0)).toId());
    }

    /// @notice Quote-currency-specific claim units backing every pot and royalty obligation.
    function claimBalance(address quoteToken) public view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(quoteToken).toId());
    }

    /// @notice Withdraw jackpot winnings / blueprint royalties.
    function claim() external {
        _claimTo(msg.sender, payable(msg.sender), address(0));
    }

    /// @notice Withdraw the caller's jackpot winnings / blueprint royalties to another address.
    ///         This lets smart-contract recipients without a payable fallback recover their claim.
    function claimTo(address payable to) external {
        if (to == address(0)) revert ZeroAddress();
        _claimTo(msg.sender, to, address(0));
    }

    /// @notice Withdraw winnings / royalties in a specific quote currency.
    function claimFor(address quoteToken) external {
        _claimTo(msg.sender, payable(msg.sender), quoteToken);
    }

    /// @notice Withdraw winnings / royalties in a specific quote currency to another address.
    function claimFor(address quoteToken, address payable to) external {
        if (to == address(0)) revert ZeroAddress();
        _claimTo(msg.sender, to, quoteToken);
    }

    function _claimTo(address account, address payable to, address quoteToken) internal {
        uint256 amount;
        if (quoteToken == address(0)) {
            amount = claimableWei[account];
            claimableWei[account] = 0;
        } else {
            amount = claimableByQuoteWei[account][quoteToken];
            claimableByQuoteWei[account][quoteToken] = 0;
        }
        if (amount == 0) revert NothingToClaim();
        bytes memory result = poolManager.unlock(abi.encode(uint8(1), to, quoteToken, amount));
        uint256 paid = abi.decode(result, (uint256));
        if (paid != amount) revert BadConfig();
        emit Claimed(account, amount);
    }

    // ---------------------------------------------------------------- unlock callback

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint8 action = abi.decode(data, (uint8));
        if (action == 1) {
            (, address payable to, address quoteToken, uint256 amountWei) =
                abi.decode(data, (uint8, address, address, uint256));
            Currency quoteCurrency = Currency.wrap(quoteToken);
            poolManager.burn(address(this), quoteCurrency.toId(), amountWei);
            try poolManager.take(quoteCurrency, to, amountWei) {}
            catch {
                revert EthTransferFailed();
            }
            return abi.encode(amountWei);
        }
        if (action == 2) {
            (, PoolId id) = abi.decode(data, (uint8, PoolId));
            PoolConfig storage cfg = poolConfig[id];
            // Re-check everything against fresh state: the external pre-check is advisory only.
            if (!cfg.initialized || cfg.buybackBps == 0) revert BuybackDisabled();
            if (
                buybackLastExecBlock[id] != 0
                    && block.number < uint256(buybackLastExecBlock[id]) + cfg.buybackCooldownBlocks
            ) revert BuybackCooldown();

            (uint160 sqrtStart,,,) = poolManager.getSlot0(id);
            uint160 anchor = buybackAnchorSqrtX96[id];
            if (sqrtStart == 0 || anchor == 0) revert BuybackNotArmed(anchor, sqrtStart, cfg.buybackDrawdownBps);
            uint256 ratio1e18 = (uint256(sqrtStart) * 1e18) / uint256(anchor);
            uint256 threshold1e18 = 1e18 + (uint256(cfg.buybackDrawdownBps) * 1e18) / BPS;
            if (ratio1e18 < threshold1e18) revert BuybackNotArmed(anchor, sqrtStart, cfg.buybackDrawdownBps);

            uint256 accrued = buybackAccruedWei[id];
            if (accrued < cfg.buybackMinSpendWei) revert BuybackDisabled();
            uint256 spend = accrued > cfg.buybackMaxSpendWei ? cfg.buybackMaxSpendWei : accrued;

            // Slippage-bounded exact-input buy on this pool. The limit stops the fill once the
            // price has moved MAX_BUYBACK_SLIP_BPS against the trigger observation; a competing
            // transaction can therefore never make this purchase chase more than that bound.
            uint160 limit = uint160((uint256(sqrtStart) * (BPS - MAX_BUYBACK_SLIP_BPS)) / BPS);
            if (limit < MIN_SQRT_PRICE_LIMIT) limit = MIN_SQRT_PRICE_LIMIT;
            BalanceDelta delta = poolManager.swap(
                _poolKeyFor(id, cfg),
                SwapParams({
                    zeroForOne: true, // quote in -> token out
                    amountSpecified: -int256(spend),
                    sqrtPriceLimitX96: limit
                }),
                ""
            );

            int128 quoteLeg = delta.amount0();
            int128 tokenLeg = delta.amount1();
            uint256 consumed = quoteLeg < 0 ? uint256(-int256(quoteLeg)) : 0;
            uint256 bought = tokenLeg > 0 ? uint256(uint128(tokenLeg)) : 0;
            if (consumed == 0 || bought == 0) revert BuybackNoOutput();

            // Settle the consumed quote from the claim-backed reserve and burn what it bought.
            poolManager.burn(address(this), Currency.wrap(poolQuoteToken[id]).toId(), consumed);
            poolManager.take(Currency.wrap(cfg.token), DEAD, bought);

            buybackAccruedWei[id] = accrued - consumed;
            buybackLastExecBlock[id] = uint40(block.number);
            // Reset the anchor to where execution actually landed so the next drawdown must be a
            // NEW discount relative to post-buyback reality.
            (uint160 sqrtEnd,,,) = poolManager.getSlot0(id);
            if (sqrtEnd != 0) {
                buybackAnchorSqrtX96[id] = sqrtEnd;
                emit BuybackAnchorUpdated(id, sqrtEnd);
            }
            totalBurnedTokens[id] += bought;
            emit BuybackBurn(id, consumed, bought);
            return abi.encode(consumed, bought);
        }
        revert HookNotCalled();
    }

    // ---------------------------------------------------------------- IHooks: unused callbacks

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotCalled();
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        PoolConfig storage cfg = poolConfig[key.toId()];
        if (!cfg.initialized) revert NotConfigured();

        // `guardLpEarnedWei` is the amount the launchpad's locked positions must withhold from
        // their creator split. While the guard is active, letting an outside LP join would send
        // part of that fee to the outside position while the ledger still records 100%, leaving a
        // phantom debt that diverts unrelated post-guard creator fees. The launchpad is allowed to
        // seed its full-range position and token bands; everyone else can add liquidity as soon as
        // the finite guard ends. Existing outside positions are impossible here because the pool
        // is configured before it is initialized and the guard never starts again.
        if (cfg.guardEndBlock != 0 && block.number < cfg.guardEndBlock && sender != launchpad) {
            revert ExternalLiquidityBlockedDuringGuard();
        }
        return IHooks.beforeAddLiquidity.selector;
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

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        // Exact-input quote -> token only. Sells and exact-output buys preserve the v2 boundary
        // and do not pay an auto-burn cut.
        if (params.amountSpecified >= 0 || !params.zeroForOne) return (IHooks.afterSwap.selector, 0);
        PoolId id = key.toId();
        PoolConfig storage cfg = poolConfig[id];
        if (!cfg.initialized) revert NotConfigured();

        // ---- buyback anchor: ratchet the running cheapest-price mark.
        // Read from storage here, which is one swap stale while the outer swap holds its state in
        // memory — a deliberate coarseness for a trigger that only ever gates a capped, burn-only
        // purchase funded by fees. Higher sqrt = cheaper token (price is tokens-per-quote). Sells
        // are exactly the moves this block exists to lean against, so the anchor tracks them too.
        {
            (uint160 sqrtNow,,,) = poolManager.getSlot0(id);
            uint160 anchor = buybackAnchorSqrtX96[id];
            if (sqrtNow != 0 && sqrtNow > anchor) {
                buybackAnchorSqrtX96[id] = sqrtNow;
                emit BuybackAnchorUpdated(id, sqrtNow);
            }
        }

        // beforeSwap can only price LP/pot cuts from the requested input. Verify that the pool
        // actually consumed every wei left after that cut. If liquidity ends at the usable lower
        // tick (or any future boundary causes a partial fill), reverting here atomically unwinds
        // the donation, minted quote claims, pot counter, and swap instead of overcharging.
        uint256 requested = uint256(-params.amountSpecified);
        int128 rawPoolInput = delta.amount0();
        uint256 actualPoolIn = rawPoolInput < 0 ? uint256(-int256(rawPoolInput)) : 0;
        uint256 quoteCutBps = uint256(cfg.lpBps) + cfg.potBps;
        if (quoteCutBps > 0) {
            uint256 expectedPoolIn = requested - ((requested * quoteCutBps) / BPS);
            if (actualPoolIn != expectedPoolIn) revert PartialFillUnsupportedWithInputCuts();
        }

        bool guardActive = cfg.guardEndBlock != 0 && block.number < cfg.guardEndBlock;
        if (guardActive) {
            // beforeSwap reserves the request against the per-block cap because actual input is not
            // known yet. Release the refunded portion now. Cut-bearing swaps are required to fill
            // completely above; adding their deterministic cut reconstructs total buyer input.
            uint256 actualBuyIn = actualPoolIn + ((requested * quoteCutBps) / BPS);
            if (cfg.maxBuyWei != 0 && actualBuyIn < requested) {
                uint256 released = requested - actualBuyIn;
                guardBuyWei[id] = uint96(uint256(guardBuyWei[id]) - released);
            }

            if (quoteCutBps == 0) {
                uint256 effectiveFeePips = guardFeePipsInFlight[id];
                delete guardFeePipsInFlight[id];
                // Actual pool input includes both the LP fee and any PoolManager protocol fee.
                guardLpEarnedWei[id] += _guardLpFeeWei(id, actualPoolIn, effectiveFeePips);
            }
        }

        int128 amountOut = delta.amount1();
        if (cfg.burnBps == 0 || amountOut <= 0) return (IHooks.afterSwap.selector, 0);

        uint256 burnAmount = (uint256(uint128(amountOut)) * cfg.burnBps) / BPS;
        if (burnAmount == 0) return (IHooks.afterSwap.selector, 0);
        poolManager.take(key.currency1, DEAD, burnAmount);
        totalBurnedTokens[id] += burnAmount;
        emit AutoBurn(id, burnAmount);
        return (IHooks.afterSwap.selector, int128(uint128(burnAmount)));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotCalled();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotCalled();
    }
}
