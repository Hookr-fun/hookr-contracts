// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title HookrTypes
/// @notice Shared constants and structs of the Hookr core: pool config, swap context, advice, settlement, receipts.
library HookrTypes {
    uint8 internal constant BEFORE_SWAP = 1;
    uint8 internal constant AFTER_SWAP = 2;
    /// @notice keccak256 of RulesConfig's type string, the 16-word layout (`integrator` last): what HookrRules
    ///         answers from configSchemaHash() and what both advisories require of a pool's Rules.
    bytes32 internal constant RULES_CONFIG_SCHEMA = keccak256(
        "RulesConfig(uint40 guardEndBlock,uint24 maxFeePips,uint24 snipeTaxPips,uint24 snipeFloorPips,uint16 snipeDecaySeconds,uint16 dynamicFeeSens,uint16 burnBps,uint16 lpBps,uint16 potBps,uint16 royaltyBps,uint16 protocolShareBps,uint32 potEveryNBuys,uint128 maxBuyQuoteAmount,uint128 potMinBuyQuote,address royaltyTo,address integrator)"
    );
    /// @notice RulesKnobs bounds and defaults, which HookrRules enforces at bind. A dynamic fee pool's tempo:
    ///         windowSeconds from MIN_WINDOW_SECONDS to MAX_WINDOW_SECONDS; resetSeconds a multiple of
    ///         RESET_STEP_SECONDS from the larger of twice the window and MIN_RESET_SECONDS to MAX_RESET_SECONDS;
    ///         carryBps a multiple of CARRY_STEP_BPS up to MAX_CARRY_BPS; moveTicks from MIN_MOVE_TICKS to
    ///         MAX_MOVE_TICKS. The DEFAULT_ values are the tempo HookrLauncher's launch, launchAdvised and launchWithBuy
    ///         bind and HookrRules.dynamicFeeParameters() returns.
    uint16 internal constant MIN_WINDOW_SECONDS = 12;
    uint16 internal constant MAX_WINDOW_SECONDS = 300;
    uint16 internal constant DEFAULT_WINDOW_SECONDS = 30;
    uint16 internal constant MIN_RESET_SECONDS = 30;
    uint16 internal constant MAX_RESET_SECONDS = 1_800;
    uint16 internal constant RESET_STEP_SECONDS = 15;
    uint16 internal constant DEFAULT_RESET_SECONDS = 120;
    uint16 internal constant MAX_CARRY_BPS = 9_500;
    uint16 internal constant CARRY_STEP_BPS = 125;
    uint16 internal constant DEFAULT_CARRY_BPS = 7_500;
    uint24 internal constant MIN_MOVE_TICKS = 50;
    uint24 internal constant MAX_MOVE_TICKS = 2_000;
    uint24 internal constant DEFAULT_MOVE_TICKS = 200;
    /// @notice RulesKnobs.snipeCurve: the shape a decaying Snipe tax falls along, from snipeTaxPips at launch to
    ///         snipeFloorPips at snipeDecaySeconds (HookrRules: each curve's maths and rounding). SNIPE_CURVE_LINEAR, a
    ///         straight line, is the default; SNIPE_CURVE_FRONT_LOADED halves what is left to fall every eighth of the
    ///         decay (an exponential fall); SNIPE_CURVE_STEP holds the tax in eight equal steps, an eighth of the way
    ///         down at the start of each later eighth of the decay.
    uint8 internal constant SNIPE_CURVE_LINEAR = 0;
    uint8 internal constant SNIPE_CURVE_FRONT_LOADED = 1;
    uint8 internal constant SNIPE_CURVE_STEP = 2;
    /// @notice The longest snipeDecaySeconds a pool binds with is the larger of MAX_SNIPE_DECAY_SECONDS and its guard's
    ///         length at bind, (guardEndBlock - block.number) x PARENT_BLOCK_SECONDS, at most 65,535 (uint16): any guard
    ///         may decay over up to an hour, and a longer guard over up to its whole length.
    uint16 internal constant MAX_SNIPE_DECAY_SECONDS = 3_600;
    uint256 internal constant PARENT_BLOCK_SECONDS = 12;

    /// @notice Immutable aggregate fee ceilings. Pips use 1e6; basis points use 1e4.
    /// @dev For a RULES admission, maxLpFeePips bounds the TOTAL native LP fee (base + Rules surcharge).
    ///      For an ADVISORY admission it bounds the advisory surcharge.
    struct Caps {
        uint24 maxLpFeePips;
        uint24 maxQuoteTakePips;
        uint16 maxSubjectTakeBps;
    }

    /// @notice Pool identity, trusted modules and immutable execution limits.
    /// @dev Native quote currency is address zero. Subject and quote are independent of address sorting.
    struct PoolConfig {
        Currency subject;
        Currency quote;
        address rules;
        address advisory;
        address liquidityOwner;
        uint24 baseLpFeePips;
        Caps caps;
        uint32 rulesGasLimit;
        uint32 advisoryGasLimit;
        uint8 advisoryPhases;
        bool advisoryFailOpen;
        bytes32 policyId;
    }

    /// @notice Parameters for Anti-Snipe, Hookr dynamic fees, Auto Burn, LP Rewards and the King of the Pool pot.
    /// @dev Amounts use raw quote units. guardEndBlock and the guard's buy cap use the chain's block.number, which is
    ///      the parent (L1) height on Arbitrum-style chains; a window's wall-clock length is per chain. The dynamic
    ///      fee's reference windows use block.timestamp. maxFeePips is the LP fee a dynamic fee pool charges at its
    ///      full span and dynamicFeeSens (1 to 10) sets how far a swap must move the price to reach it; both equal
    ///      the base fee and zero on a pool without dynamic fees. The Anti-Snipe tax also counts in block.timestamp:
    ///      it decays in seconds from the pool's launch, from snipeTaxPips to snipeFloorPips (below snipeTaxPips)
    ///      over snipeDecaySeconds (at most an hour, or the guard's length if that is longer: MAX_SNIPE_DECAY_SECONDS),
    ///      along the pool's RulesKnobs.snipeCurve (linear by default), and is charged only while the guard lasts.
    ///      While it decays, the per-parent-block buy cap is maxBuyQuoteAmount scaled by snipeTaxPips over the
    ///      current tax. A zero snipeDecaySeconds charges snipeTaxPips flat for the whole guard under a fixed cap of
    ///      maxBuyQuoteAmount.
    ///      potEveryNBuys and potMinBuyQuote are reserved and must be zero; potBps is a recapture pool's King of the
    ///      Pool pot share (see RecaptureConfig) and zero on every other pool. protocolShareBps is Hookr's share of
    ///      the Snipe, dynamic fee, LP Rewards and Auto Burn, from the effective floor at bind (the larger of the
    ///      Rules' immutable floor and the treasury's governed floor) to 5,000. `integrator` names the pool's
    ///      integrator, zero for none: it must be on the treasury's integrator list at bind, and the pool then pays it
    ///      the rate the list gives it at bind of every Hookr share of those four rules, frozen with the pool.
    struct RulesConfig {
        uint40 guardEndBlock;
        uint24 maxFeePips;
        uint24 snipeTaxPips;
        uint24 snipeFloorPips;
        uint16 snipeDecaySeconds;
        uint16 dynamicFeeSens;
        uint16 burnBps;
        uint16 lpBps;
        uint16 potBps;
        uint16 royaltyBps;
        uint16 protocolShareBps;
        uint32 potEveryNBuys;
        uint128 maxBuyQuoteAmount;
        uint128 potMinBuyQuote;
        address royaltyTo;
        address integrator;
    }

    /// @notice A pool's Rules knobs beyond RulesConfig, frozen at bind as the second part of its Rules data: present
    ///         on a dynamic fee pool, a recapture pool and a pool with a knob off its default, absent on any other
    ///         (HookrRules.bind).
    /// @dev minDynamicFeeLiquidity is a dynamic fee pool's minimum dynamic fee liquidity (1 to 2^96 - 1): a swap
    ///      carries the pool's anchor to its end price only when its quote covers this liquidity between the anchor
    ///      and that price. windowSeconds, resetSeconds, carryBps and moveTicks are its tempo, in bounds (the
    ///      constants above): without an anchor move the reference steps toward the anchor once per window, keeping
    ///      carryBps of its distance, and joins it after the reset; while the anchor keeps moving it still steps once
    ///      per reset; a move counts when it carries the anchor at least moveTicks from where the last counted move
    ///      left it. All five are zero on a pool without dynamic fees. snipeCurve is a decaying Snipe's shape
    ///      (SNIPE_CURVE_*), and only a pool whose Snipe decays (RulesConfig.snipeDecaySeconds nonzero) may take
    ///      another than SNIPE_CURVE_LINEAR.
    struct RulesKnobs {
        uint96 minDynamicFeeLiquidity;
        uint16 windowSeconds;
        uint16 resetSeconds;
        uint16 carryBps;
        uint24 moveTicks;
        uint8 snipeCurve;
    }

    /// @notice A recapture pool's creator knobs, frozen at bind as the third part of its Rules data. The pool freezes
    ///         the root's lane executor at initialization and each of its swaps runs an arb recapture before and after
    ///         it (HookrLane). Of each arb recapture's push the protocol takes first 25% of the profit the push reports
    ///         at the pool's frozen partner share (RECAPTURE_PROTOCOL_BPS, the same on every pool, whatever its
    ///         protocolShareBps, and never split with an integrator); traderBps + lpBps + RulesConfig.potBps (10,000 in
    ///         all) split the rest. traderBps (at most 5,000) goes to the trader named on the after-phase, lpBps to the
    ///         pool's LP accrual (the launch position). A nonzero RulesConfig.potBps (at most 5,000) turns King of the
    ///         Pool on with period (1 hour to 30 days), maxPrizeBps (1 to prizeBound: half of what Hookr keeps of LP
    ///         Rewards and Auto Burn after the pool's integrator rate, in basis points of a buy), potReleaseBps (2,500
    ///         to 10,000) and minBuyQuote (nonzero, raw quote units); off, they are zero. releaseBlocks
    ///         (MIN_RELEASE_BLOCKS to MAX_RELEASE_BLOCKS, in L2 blocks: ArbSys.arbBlockNumber() via HookrClock, about
    ///         10 a second) is the period over which a pending LP share is released to in-range liquidity: each flush
    ///         donates pending x min(L2 blocks since its release block, releaseBlocks) / releaseBlocks, rounded up, the
    ///         blocks capped at 10 a second of block.timestamp plus one second's worth, so liquidity in range for one
    ///         L2 block boundary takes at most 1/releaseBlocks of it plus one raw unit. Bounds and defaults:
    ///         HookrRules' MIN_, MAX_ and DEFAULT_ getters and recaptureDefaults().
    struct RecaptureConfig {
        bool on;
        uint16 traderBps;
        uint16 lpBps;
        uint32 period;
        uint16 maxPrizeBps;
        uint16 potReleaseBps;
        uint128 minBuyQuote;
        uint32 releaseBlocks;
    }

    /// @notice Root-authenticated identity and requested swap shape passed to pool modules.
    struct SwapContext {
        PoolId id;
        address sender;
        address payer;
        address beneficiary;
        Currency subject;
        Currency quote;
        bool authenticated;
        bool isBuy;
        bool exactInput;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        uint24 baseLpFeePips;
    }

    /// @notice Native rule charges before execution. The LP surcharge excludes the frozen base fee.
    /// @dev lpFeeSurchargePips is dynamic fee LP part + Snipe LP part + LP Rewards (buys), pips of the pool input.
    ///      quoteTakePips is pips of the gross buyer spend (all buys) or of actualQuote (sells). An exact-output
    ///      sell reserves its quote take on top of the requested output, so the seller still receives it.
    ///      subjectBurnBps is nonzero for exact-input and exact-output buys, zero for sells.
    struct FeeQuote {
        uint24 lpFeeSurchargePips;
        uint24 quoteTakePips;
        uint16 subjectBurnBps;
    }

    /// @notice Outcome of the swap the root runs on the PoolManager, and reverts, before Rules price a dynamic fee.
    /// @dev The simulated swap trades the specified amount net of every charge Rules and the advisory quote without
    ///      the dynamic fee, at their LP fee without it. sqrtPriceAfterX96 is the last price with liquidity it reached and
    ///      tickAfter the pool's tick there: a swap that runs out of liquidity is priced to the edge of that liquidity,
    ///      not to its price limit.
    struct SwapSimulation {
        uint160 sqrtPriceBeforeX96;
        int24 tickBefore;
        uint160 sqrtPriceAfterX96;
        int24 tickAfter;
    }

    /// @notice Advisory charges and recipient. A zero quote take requires no recipient.
    struct Advice {
        uint24 lpFeeSurchargePips;
        uint24 quoteTakePips;
        address recipient;
        bool reject;
    }

    /// @notice Actual executed amounts and liabilities that the root reconciles after the swap.
    /// @dev quoteBasis is the gross buyer spend (actualQuote + totalFee) for every buy and actualQuote for sells.
    ///      refund is nonzero only for authenticated exact-input partial fills. subjectBurn is
    ///      actualSubject * burnBps / BPS for exact-input buys and the pre-reserved subject for exact-output buys.
    struct Settlement {
        uint256 actualQuote;
        uint256 actualSubject;
        uint256 quoteBasis;
        uint256 rulesFee;
        uint256 advisoryFee;
        uint256 refund;
        uint256 subjectBurn;
        address advisoryRecipient;
    }

    /// @notice Opt-in transient receipt consumed immediately by the pinned router/quoter.
    /// @dev Input includes a reserved partial-fill fee; quoteRefund is separately backed in Rules.
    struct ExecutionReceipt {
        PoolId id;
        bytes32 policyHash;
        address payer;
        address beneficiary;
        Currency inputCurrency;
        Currency outputCurrency;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 actualQuote;
        uint256 quoteFee;
        uint256 quoteRefund;
        uint256 subjectBurn;
        uint24 lpFeePips;
    }
}
