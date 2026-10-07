// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookrTypes} from "../../types/HookrTypes.sol";
import {IHookrRoot} from "../../interfaces/IHookrRoot.sol";
import {IHookrRegistry} from "../../interfaces/IHookrRegistry.sol";
import {IHookrRules} from "../../interfaces/IHookrRules.sol";
import {IHookrRulesConfig} from "../../interfaces/IHookrRulesConfig.sol";
import {IHookrFeeOnlyRules} from "../../interfaces/IHookrFeeOnlyRules.sol";
import {IHookrDynamicFeeRules} from "../../interfaces/IHookrDynamicFeeRules.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrDynamicFee} from "../../libraries/HookrDynamicFee.sol";
import {HookrReleased} from "../../base/HookrReleased.sol";
import {HookrRecapture} from "../../core/HookrRecapture.sol";
import {IHookrTreasury} from "../../interfaces/IHookrTreasury.sol";
import {IHookrProtocolClaims} from "../../interfaces/IHookrProtocolClaims.sol";
import {IHookrProtocolClaimsTransfer} from "../../interfaces/IHookrProtocolClaimsTransfer.sol";
import {HookrToken} from "../../support/HookrToken.sol";
import {IHookrRulesEvents} from "../../interfaces/IHookrRulesEvents.sol";
import {IHookrRecaptureEvents} from "../../interfaces/IHookrRecaptureEvents.sol";
import {IHookrRulesState} from "../../interfaces/IHookrRulesState.sol";
import {IHookrRoundTripBook} from "./interfaces/IHookrRoundTripBook.sol";
import {HookrRoundTripStorage} from "./HookrRoundTripStorage.sol";

/// @title HookrRulesRoundTrip
/// @notice Bounded native rules and quote-claim accounting. No engagement campaign state.
/// @dev Anti-Snipe, Hookr dynamic fees, Auto Burn and LP Rewards. potEveryNBuys and potMinBuyQuote are reserved
///      RulesConfig words that must be zero, and potBps is the King of the Pool pot share of a recapture pool (zero on
///      every other pool).
///      A recapture pool's split and King of the Pool run in the HookrRecapture module this contract deploys in its
///      constructor and reaches only by DELEGATECALL (see HookrRecapture): at bind, on a King of the Pool pool's
///      settled swaps, and for the recapture surface served from the fallback. A pool without recapture never
///      reaches it.
///      Every LP-fee component (base, dynamic fee, Snipe, LP Rewards) is pips of the pool input.
///      Every quote take is pips of the gross buyer spend (buys) or of the quote that leaves the pool (sells).
///      The dynamic fee is priced on the move the root simulates for the swap, away from the pool's reference price,
///      as the average of a capped quadratic rate over that move, and charged as LP fee. The swap's executed price
///      then moves the pool's anchor in `settleSwap`. An arb recapture executor leg is charged no dynamic fee but
///      carries the pool's dynamic fee state as an ordinary swap would (`carryLeg`). No swap fee is donated or
///      deferred; only a recapture pool's LP share of an arb recapture is, through HookrRecapture. The launch guard
///      and its buy cap are counted in this chain's block.number, the parent (L1) height on Arbitrum-style chains;
///      the dynamic fee's reference windows are counted in block.timestamp, at the pool's tempo. The Snipe tax alone
///      decays in block.timestamp seconds since the pool's launch, along the pool's curve, and the guard buy cap
///      grows as it falls; both apply only while the block-number guard lasts. The tempo and the curve are the
///      pool's Rules knobs (HookrTypes.RulesKnobs), frozen at bind; a pool bound without them has the defaults.
///      The Hookr minimum: a pool whose subject is a Hookr token (HookrToken's runtime code, the token HookrLauncher
///      creates), with no arb recapture and no rule that earns Hookr a share of its fees (LP Rewards, Auto Burn,
///      dynamic fees or the Anti-Snipe tax that can pay Hookr at least a pip of a swap at the pool's
///      protocolShareBps, see `_earnsHookr`, or a Tax + Conversion advisory, see `_taxConversion`), freezes at bind
///      the minimum the treasury gives it; every other pool freezes none. On each swap of a pool with a minimum Hookr
///      takes at least that many pips of the swap: the quote take gains max(0, minimum - Hookr's rule-fee share of the
///      swap), in the pool's quote, which is the whole minimum, since such a pool's rules earn Hookr nothing.
///      Round-trip record (the only delta from HookrRules): a pool whose advisory answers ROUND_TRIP_ADVISORY() with
///      the magic value at bind records, per trader key, the directions each completed swap traded in its block.
///      Such a pool never becomes fee-only, so every swap reaches settleSwap. The record never refuses a swap. A swap
///      of the pool's arb recapture executor is not a trader's and is never recorded: a buy leg inside the launch
///      guard takes the Rules path, and its record would make the advisory refuse the executor's later legs from the
///      same transaction origin in that block. The record's writes run in HookrRoundTripRecords, which this contract
///      creates in its constructor by CREATE2 with a zero salt from the creation code a code store holds, and reaches
///      only by DELEGATECALL, from bind and from a recording pool's settleSwap, as it reaches HookrRecapture, so that
///      its runtime stays under 24,576 bytes and its initcode under 49,152.
contract HookrRulesRoundTrip is
    HookrReleased,
    IHookrRules,
    IHookrRulesConfig,
    IHookrFeeOnlyRules,
    IHookrDynamicFeeRules,
    IHookrProtocolClaims,
    IHookrProtocolClaimsTransfer,
    IUnlockCallback,
    IHookrRulesEvents,
    IHookrRecaptureEvents,
    IHookrRulesState,
    IHookrRoundTripBook
{
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    bytes32 private constant SLOT = 0x762913e4bc0f59f7b08c82f07586fa48932548ab5fab99e6db0b09765b4ff900;
    /// @dev keccak256("hookr.rules.transient.protocol.paid")
    bytes32 private constant PROTOCOL_PAID = 0x28b2af427468a99e9f7ccc4cbfc40e94c560a5499ebe45e5c40afbe02c262a45;
    /// @dev keccak256("hookr.rules.transient.dynamic.fee.lag"): set by `quoteSimulatedSwap` for `settleSwap` of the same
    ///      swap, as ANCHOR_PENDING | lag. lag is how far, in distance from the reference, the swap started ahead of
    ///      where it was charged from.
    bytes32 private constant DYNAMIC_FEE_LAG = 0x31f61b8aa76b6c2bfb865da93f6c148fe6833d56d1dc64906de519e6ee39a174;
    /// @dev keccak256("hookr.rules.transient.dynamic.fee.end"): the simulated swap's end, the last price with liquidity
    ///      it reached, set with DYNAMIC_FEE_LAG.
    bytes32 private constant DYNAMIC_FEE_END = 0x87fa0b2ebd060534e3fcf0828d6cd4ac154b0048eb86f5aeb9d005f7daf10f5d;
    /// @dev keccak256("hookr.rules.transient.launch.buy"): the id of the pool with a buy cap bound last in this
    ///      transaction, until its launch buy clears it. The launch buy is that pool's first counted buy, sent by its
    ///      liquidity owner in the bind transaction.
    bytes32 private constant LAUNCH_BUY = 0x45f20a8ddebc10086fcb192c29e55fce3baa64c4837bca2674009b5cd15e558b;
    /// @dev Bound.terms bits: the pool froze an integrator, a Hookr minimum, and Rules knobs off their defaults.
    uint8 private constant TERMS_INTEGRATOR = 1;
    uint8 private constant TERMS_MINIMUM = 2;
    uint8 private constant TERMS_KNOBS = 4;
    /// @dev DynamicFeeState.flags bits: the state started, and the pool's tempo is in its Knobs.
    uint8 private constant DYNAMIC_FEE_STARTED = 1;
    uint8 private constant DYNAMIC_FEE_KNOBBED = 2;
    /// @dev Most a pool's Hookr minimum may be, in pips of the swap: 1%.
    uint256 private constant MAX_MIN_FEE_PIPS = 10_000;
    uint256 private constant ANCHOR_PENDING = 1 << 255;
    uint256 private constant PIPS = 1_000_000;
    uint256 private constant BPS = 10_000;
    /// @dev Low 192 bits of a guard word: the parent block's net guarded buy spend.
    uint256 private constant GUARD_MASK = (uint256(1) << 192) - 1;
    /// @dev Length of `abi.encode(RulesConfig, RulesKnobs)`: 16 config words and 6 knob words.
    uint256 private constant KNOBS_RULES_DATA = 22 * 32;
    /// @dev Length of `abi.encode(RulesConfig, RulesKnobs, RecaptureConfig)`: a recapture pool, dynamic fee or not. Its
    ///      first KNOBS_RULES_DATA bytes are `abi.encode(RulesConfig, RulesKnobs)`.
    uint256 private constant RECAPTURE_RULES_DATA = 30 * 32;
    /// @dev `recaptureModule()`, answered from this contract's own code in the fallback.
    bytes4 private constant RECAPTURE_MODULE_SELECTOR = 0x720e68f5;
    /// @dev IHookrLaneRules.carryLeg, answered from this contract's own code in the fallback, and its input length.
    bytes4 private constant CARRY_LEG_SELECTOR = 0xff341722;
    uint256 private constant CARRY_LEG_INPUT = 4 + 18 * 32;
    /// @dev `EXCLUSIVE_GROUP()`, through which Tax + Conversion's advisory declares its group, the gas a bind gives
    ///      that read, and the group: keccak256("DIRECTIONAL_QUOTE_TAX") (`_taxConversion`).
    bytes4 private constant EXCLUSIVE_GROUP_SELECTOR = 0x5ac238e9;
    uint256 private constant GROUP_READ_GAS = 10_000;
    bytes32 private constant TAX_CONVERSION_GROUP = keccak256("DIRECTIONAL_QUOTE_TAX");
    /// @inheritdoc IHookrRules
    IPoolManager public immutable override(IHookrRules, IHookrProtocolClaims) poolManager;
    /// @inheritdoc IHookrRulesState
    IHookrRegistry public immutable registry;
    /// @inheritdoc IHookrProtocolClaims
    address public immutable protocolRecipient;
    /// @inheritdoc IHookrRules
    address public immutable trustedRoot;
    /// @inheritdoc IHookrRulesState
    uint16 public immutable minProtocolShareBps;
    /// @inheritdoc IHookrRulesState
    bool public immutable rootSimulates;
    /// @dev Most share of Hookr's rule-fee share a pool's integrator may be paid: half.
    uint256 private constant MAX_INTEGRATOR_BPS = 5_000;
    /// @dev A wrapped launch age above this reads as a clock behind the launch.
    uint256 private constant MAX_LAUNCH_AGE = type(uint32).max >> 1;
    /// @dev HookrRecapture: the module this contract deployed for the recapture split and King of the Pool, and its
    ///      runtime codehash. Both are fixed in this contract's runtime, so a registry admission that pins this
    ///      contract's codehash also pins the module's code (checked at admission through `recaptureModule()`).
    address private immutable recapture;
    bytes32 private immutable recaptureCodeHash;
    /// @dev The runtime codehash of every HookrToken (it has no immutables): a pool binds the Hookr minimum only when
    ///      its subject has it (and the pool has no arb recapture and no Hookr-earning rule, see `bind`).
    bytes32 private immutable hookrTokenCodeHash;

    /// @dev Slot 0 holds everything a swap reads outside the config. Subject and quote are not stored: the pool id
    ///      commits to both, and `quoteIsCurrency0` says which is the quote. The binding root is always `trustedRoot`.
    ///      `launchedAt` is the block.timestamp of the bind, the start of the Snipe decay. `tickSpacing` fits 16 bits:
    ///      the PoolManager refuses a pool above TickMath.MAX_TICK_SPACING (type(int16).max) in the initialize that
    ///      binds it. `terms` says what the pool froze in `integrations`: an integrator (TERMS_INTEGRATOR, read by
    ///      settleSwap) and a Hookr minimum (TERMS_MINIMUM, read by every quote), so a pool with neither never reads
    ///      that slot; and whether it froze Rules knobs off their defaults (TERMS_KNOBS, read by a decaying Snipe's
    ///      guarded buys), so a pool without them never reads its Knobs.
    struct Bound {
        uint24 baseFeePips;
        int16 tickSpacing;
        bool bound;
        bool quoteIsCurrency0;
        uint8 terms;
        address liquidityOwner;
        uint32 launchedAt;
        HookrTypes.RulesConfig config;
    }

    /// @dev One word per dynamic fee pool. minLiquidity is frozen at bind. The reference is the price the dynamic fee
    ///      measures from; the anchor is the executed price swaps with real notional have carried the pool to. movedAt
    ///      is the last time a swap carried the anchor to its own end price at least the pool's moveTicks from
    ///      movedTick, and movedTick the anchor tick it left. referenceAt is the time the reference's steps are
    ///      counted to. The ticks start at the pool's first dynamic fee swap other than a launch buy. `flags`:
    ///      DYNAMIC_FEE_STARTED once the ticks start, and DYNAMIC_FEE_KNOBBED, set at bind, for a pool whose tempo is
    ///      off the defaults (its Knobs hold it), so a pool with the default tempo reads no Knobs on a swap.
    struct DynamicFeeState {
        uint96 minLiquidity;
        int24 referenceTick;
        int24 anchorTick;
        int24 movedTick;
        uint40 movedAt;
        uint40 referenceAt;
        uint8 flags;
    }

    /// @dev A pool's frozen HookrTypes.RulesKnobs other than its minimum dynamic fee liquidity (in DynamicFeeState),
    ///      stored only for a pool bound with a knob off its default (TERMS_KNOBS), so a pool with the defaults never
    ///      reads it: `_tempo`, `_moveTicks` and `_snipePips` use HookrTypes' DEFAULT_ values and the linear curve
    ///      there. Stored whole, so it is nonzero exactly when the pool has one: a dynamic fee pool's window is at
    ///      least MIN_WINDOW_SECONDS, and any other pool stores it only for a curve off the linear one.
    struct Knobs {
        uint16 windowSeconds;
        uint16 resetSeconds;
        uint16 carryBps;
        uint24 moveTicks;
        uint8 snipeCurve;
    }

    /// @dev A recapture pool's frozen HookrTypes.RecaptureConfig with its quote, written and read by HookrRecapture.
    ///      RulesConfig.potBps is the King of the Pool pot's share of each arb recapture's remainder after the protocol
    ///      share; nonzero turns it on.
    struct Recapture {
        Currency quote;
        bool on;
        uint16 traderBps;
        uint16 lpBps;
        uint32 period;
        uint16 maxPrizeBps;
        uint16 potReleaseBps;
        uint128 minBuyQuote;
        uint32 releaseBlocks;
    }

    /// @dev A King of the Pool epoch: its start, the leading buy's payer and gross quote spend, and the carried pot.
    struct Hill {
        uint64 epochStart;
        address leader;
        uint128 leaderAmount;
        uint128 pot;
    }

    /// @dev A recapture pool's LP shares in its two currencies waiting for `flushRecapture`: `due` accrued before
    ///      `freshBlock`, `fresh` in it. `fresh` is due from the block after `freshBlock`, released from that block on;
    ///      `due` is released from `releasedAt`, the block of the last flush. A flush releases each part x min(blocks
    ///      since its release block, the pool's releaseBlocks) / releaseBlocks, the blocks capped by wall time. Both
    ///      block stamps are L2 heights (ArbSys.arbBlockNumber(), HookrClock), not block.number. `freshTime` is the
    ///      block.timestamp of `freshBlock`; `dueMark` is where the due part's wall-time allowance stands, in L2 blocks
    ///      at 10 a second (10 x block.timestamp plus what a flush in that second already released).
    struct Pending {
        uint128 due0;
        uint128 due1;
        uint128 fresh0;
        uint128 fresh1;
        uint64 freshBlock;
        uint64 releasedAt;
        uint64 freshTime;
        uint64 dueMark;
    }

    /// @dev A pool's integrator and the share of every Hookr rule-fee share credited to it, in basis points, both
    ///      frozen at bind from the treasury's integrator list, and the pool's Hookr minimum in pips of a swap, frozen
    ///      at bind from the treasury's terms (zero unless the pool is a Hookr token's with no arb recapture and no
    ///      Hookr-earning rule, see `bind`).
    struct Integration {
        address integrator;
        uint16 bps;
        uint16 minFeePips;
    }

    /// @custom:storage-location erc7201:hookr.rules
    struct State {
        mapping(PoolId => Bound) pools;
        mapping(Currency => mapping(address => uint256)) claims;
        mapping(Currency => uint256) liabilities;
        /// @dev (block.number << 192) | spent: net guarded buy spend in the current parent block.
        mapping(PoolId => uint256) guard;
        mapping(PoolId => DynamicFeeState) dynamicFee;
        mapping(PoolId => Recapture) recapture;
        mapping(PoolId => Hill) hills;
        /// @dev The liquidity owner's accrual per currency (LP shares with no in-range liquidity to donate to, or in a
        ///      currency other than the pool's two), payable to the pool's liquidity owner.
        mapping(PoolId => mapping(Currency => uint256)) poolAccrued;
        /// @dev Every currency the pool's liquidity owner accrual has held, in first-accrual order.
        mapping(PoolId => Currency[]) accruedCurrencies;
        /// @dev The pool's LP shares waiting to be donated to its in-range liquidity.
        mapping(PoolId => Pending) pending;
        /// @dev The pool's frozen integrator and Hookr minimum, for a pool bound with either (`Bound.terms`).
        mapping(PoolId => Integration) integrations;
        /// @dev Every advisory fee settleSwap credited on the pool, in its quote (IHookrAdvisoryFeeCounter, served by
        ///      HookrRecapture). Written only for a nonzero fee; it only grows.
        mapping(PoolId => uint256) advisoryFees;
        /// @dev The pool's frozen Rules knobs, for a pool bound with one off its default (`Bound.terms`).
        mapping(PoolId => Knobs) knobs;
    }

    bool private transient _claiming;

    /// @dev HookrRoundTripRecords: the round-trip record's writes, reached only by DELEGATECALL (`_roundTripsCall`).
    ///      Created by CREATE2 with a zero salt from the creation code the constructor's `_recordsCode` account holds,
    ///      so the address is a function of this contract's address and the module's creation code with its root
    ///      argument: a registry admission that pins this runtime's codehash, which holds the address, pins the
    ///      module's code, whichever account supplied it.
    address private immutable roundTripRecords;

    /// @notice The pool records round trips from its bind on: its advisory asked for them (HookrRoundTripRecords).
    event RoundTripsRecorded(PoolId indexed id, address indexed advisory);

    constructor(
        IPoolManager _manager,
        IHookrRegistry _registry,
        address _protocolRecipient,
        address _trustedRoot,
        uint16 _minProtocolShareBps,
        address _recordsCode
    ) {
        if (
            address(_manager).code.length == 0 || address(_registry).code.length == 0
                || _protocolRecipient == address(0) || _trustedRoot.code.length == 0 || _minProtocolShareBps > 5_000
                || address(IHookrRoot(_trustedRoot).poolManager()) != address(_manager)
                || address(IHookrRoot(_trustedRoot).registry()) != address(_registry)
        ) revert InvalidConfig();
        poolManager = _manager;
        registry = _registry;
        protocolRecipient = _protocolRecipient;
        trustedRoot = _trustedRoot;
        minProtocolShareBps = _minProtocolShareBps;
        // A protocol recipient with code is the treasury that governs the rule-fee floor and the integrator list
        // (`_feeTerms`): one that cannot answer is refused here rather than at every bind.
        if (_protocolRecipient.code.length != 0) {
            IHookrTreasury(_protocolRecipient).feeTerms(address(0), false, PoolId.wrap(0));
        }
        hookrTokenCodeHash = keccak256(type(HookrToken).runtimeCode);
        (bool ok, bytes memory out) = _trustedRoot.staticcall("");
        rootSimulates = ok && out.length == 32 && abi.decode(out, (uint256)) == 1;
        address module = address(new HookrRecapture(_manager, _protocolRecipient, _trustedRoot));
        recapture = module;
        recaptureCodeHash = module.codehash;
        // The records module, by CREATE2 with a zero salt from the creation code `_recordsCode` holds after its first
        // byte (a STOP, so a call to that account does nothing), with `_trustedRoot` as its argument.
        uint256 size = _recordsCode.code.length;
        if (size < 2) revert InvalidConfig();
        address records;
        assembly ("memory-safe") {
            let init := mload(0x40)
            extcodecopy(_recordsCode, init, 1, sub(size, 1))
            mstore(add(init, sub(size, 1)), _trustedRoot)
            records := create2(0, init, add(size, 31), 0)
        }
        if (records == address(0)) revert InvalidConfig();
        roundTripRecords = records;
    }

    /// @inheritdoc IHookrRules
    /// @notice Returns the identifier of the supported Hookr rules configuration: the keccak256 of RulesConfig's type
    ///         string (HookrTypes.RULES_CONFIG_SCHEMA), so it names the 16-word layout (`integrator` last) and changes
    ///         with any change to it. A reader built for the 15-word layout, which had keccak256("hookr.rules.config"),
    ///         fails closed against it.
    function configSchemaHash() external pure returns (bytes32) {
        return HookrTypes.RULES_CONFIG_SCHEMA;
    }

    /// @inheritdoc IHookrRules
    /// @notice Freezes one pool configuration. Only the permanently trusted root can call.
    /// @dev `data` takes one of three canonical forms, told apart by its length; any other is refused:
    ///      `abi.encode(RulesConfig)` for a pool without dynamic fees, arb recapture or a Rules knob off its default;
    ///      `abi.encode(RulesConfig, RulesKnobs)` for every other pool without arb recapture; and
    ///      `abi.encode(RulesConfig, RulesKnobs, RecaptureConfig)` for a recapture pool, whose
    ///      HookrTypes.RecaptureConfig HookrRecapture checks and freezes. The knobs (HookrTypes.RulesKnobs) must be in
    ///      HookrTypes' bounds: on a dynamic fee pool a nonzero minDynamicFeeLiquidity and its tempo, on any other pool
    ///      all five dynamic fee fields zero; a Snipe curve other than the linear one only where the Snipe decays. A
    ///      dynamic fee pool binds only under a root that simulates swaps, and only within the dynamic fee's reach
    ///      bound (HookrDynamicFee.withinReach: its span, sensitivity and protocol share keep the simulation's lead
    ///      within 5% on the dynamic fee suite's swap shapes). potBps must be zero on a pool without arb
    ///      recapture. Knobs at their defaults are not stored; a pool with one off them stores them in one more word
    ///      (`Knobs`), which only its dynamic fee swaps and its decaying Snipe's guarded buys read.
    ///      protocolShareBps must be at least the effective floor, read here once and never on a swap: the larger of
    ///      minProtocolShareBps and the treasury's governed floor. A nonzero `integrator` must be on the treasury's
    ///      list; the pool freezes it with the rate the list gives it now. A pool whose subject is a Hookr token, with
    ///      no arb recapture and no rule that earns Hookr a share of its fees, also freezes the Hookr minimum the
    ///      treasury gives it (its integrator's override only when that integrator approved this pool's id, else the
    ///      rate for a pool without recapture), at most MAX_MIN_FEE_PIPS; every other pool freezes none. A rule
    ///      earns Hookr a share when it can pay Hookr at least a pip of a swap at the pool's protocolShareBps
    ///      (`_earnsHookr`): LP Rewards or Auto Burn at a nonzero share, dynamic fees whose span (maxFeePips less the
    ///      base fee) times the share is at least 10,000, or an Anti-Snipe tax whose snipeTaxPips times the share is.
    ///      A smaller dynamic fee or Snipe pays Hookr nothing on every swap, as any rule does at a zero share, so the
    ///      pool keeps the minimum. A royalty (a cut of LP Rewards), the launch guard and its buy cap and an
    ///      integrator carry no protocol share, so a pool with only these keeps the minimum. An advisory's charge is
    ///      its own, so a pool whose only other charge is an advisory's keeps it too, except Tax + Conversion's: its
    ///      queues pay Hookr the pool's protocolShareBps of each tax, so a pool bound with an advisory that declares
    ///      Tax + Conversion's group and is admitted with a quote take binds none at a nonzero share
    ///      (`_taxConversion`). Neither a later floor, list or minimum change reaches a bound pool.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32 hash)
    {
        PoolId id = key.toId();
        if (
            msg.sender != trustedRoot || !registry.isRoot(msg.sender) || address(key.hooks) != msg.sender
                || PoolId.unwrap(IHookrRoot(msg.sender).bindingPool()) != PoolId.unwrap(id)
        ) revert Unauthorized();
        State storage s = _state();
        if (s.pools[id].bound) revert AlreadyBound();
        bool quoteIs0 = pc.quote == key.currency0;
        if (
            key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG
                || !(quoteIs0 ? pc.subject == key.currency1 : pc.subject == key.currency0 && pc.quote == key.currency1)
        ) revert InvalidConfig();
        HookrTypes.RulesConfig memory c;
        HookrTypes.RulesKnobs memory k;
        bytes memory canonical;
        bool lane = data.length == RECAPTURE_RULES_DATA;
        bytes calldata head = lane ? data[:KNOBS_RULES_DATA] : data;
        bool knobbed = head.length == KNOBS_RULES_DATA;
        if (knobbed) {
            (c, k) = abi.decode(head, (HookrTypes.RulesConfig, HookrTypes.RulesKnobs));
            canonical = abi.encode(c, k);
        } else {
            c = abi.decode(head, (HookrTypes.RulesConfig));
            canonical = abi.encode(c);
        }
        if (keccak256(head) != keccak256(canonical)) revert InvalidConfig();
        (bool custom, bool tempo) = _checkKnobs(c, k, knobbed, lane);
        (uint256 floor, uint256 integratorBps, uint256 minFee) = _feeTerms(c.integrator, lane, id);
        // The Hookr minimum binds only where nothing else earns Hookr a share: a Hookr token's pool without arb
        // recapture whose rules can pay Hookr no pip of any swap and whose advisory, if any, is not Tax + Conversion.
        if (
            lane || _earnsHookr(c, pc.baseLpFeePips) || Currency.unwrap(pc.subject).codehash != hookrTokenCodeHash
                || _taxConversion(pc.advisory, c.protocolShareBps)
        ) {
            minFee = 0;
        }
        uint8 terms = (integratorBps != 0 ? TERMS_INTEGRATOR : 0) | (minFee != 0 ? TERMS_MINIMUM : 0);
        // Frozen before the recapture config, whose King of the Pool prize bound counts what Hookr keeps after it.
        if (terms != 0) s.integrations[id] = Integration(c.integrator, uint16(integratorBps), uint16(minFee));
        // HookrRecapture checks the recapture config and freezes it (the pot share only with it).
        if (lane) _recapture();
        else if (c.potBps != 0) revert PotUnavailable(c.potBps);
        _validate(c, pc, floor, minFee);
        // The PoolManager refuses a tick spacing above type(int16).max in the initialize that binds the pool.
        s.pools[id] = Bound(
            pc.baseLpFeePips,
            int16(key.tickSpacing),
            true,
            quoteIs0,
            custom ? terms | TERMS_KNOBS : terms,
            pc.liquidityOwner,
            uint32(block.timestamp),
            c
        );
        if (k.minDynamicFeeLiquidity != 0) {
            s.dynamicFee[id] = DynamicFeeState(k.minDynamicFeeLiquidity, 0, 0, 0, 0, 0, tempo ? DYNAMIC_FEE_KNOBBED : 0);
        }
        if (custom) s.knobs[id] = Knobs(k.windowSeconds, k.resetSeconds, k.carryBps, k.moveTicks, k.snipeCurve);
        // A buy cap implies a guard past this block (_validate), so the launch buy can only land inside it.
        if (c.maxBuyQuoteAmount != 0) {
            assembly ("memory-safe") {
                tstore(LAUNCH_BUY, id)
            }
        }
        _roundTripsCall();
        hash = keccak256(data);
        emit RulesBound(id, msg.sender, hash, data);
    }

    /// @inheritdoc IHookrRules
    /// @notice Enforces the launch guard on liquidity additions.
    function beforeAddLiquidity(PoolId id, address sender) external view {
        Bound storage b = _bound(id);
        if (block.number < b.config.guardEndBlock && sender != b.liquidityOwner) revert GuardLiquidity();
    }

    /// @inheritdoc IHookrRules
    /// @notice Returns the block.number before which principal removal is refused, or zero.
    /// @dev guardEndBlock of a bound pool; zero for an unguarded or unbound pool. One SLOAD, never reverts.
    ///      The root reads it once at initialization and bounds it by its own guard window.
    function removalLockedUntil(PoolId id) external view returns (uint256 untilBlock) {
        return _state().pools[id].config.guardEndBlock;
    }

    /// @inheritdoc IHookrFeeOnlyRules
    /// @dev Fee-only: no dynamic fee (maxFeePips equals the base fee), no LP Rewards, burn, royalty or Hookr minimum, and
    ///      the launch guard (Snipe, buy cap, exact-output refusal) has ended. Zero for an unbound pool.
    function feeOnlyFrom(PoolId id) external view returns (uint256) {
        Bound storage b = _state().pools[id];
        HookrTypes.RulesConfig storage c = b.config;
        if (
            !b.bound || c.maxFeePips != b.baseFeePips || c.lpBps != 0 || c.burnBps != 0 || c.royaltyBps != 0
                || c.potBps != 0 || b.terms & TERMS_MINIMUM != 0 || HookrRoundTripStorage.load().recording[id]
        ) return 0;
        return c.guardEndBlock == 0 ? 1 : c.guardEndBlock;
    }

    /// @inheritdoc IHookrRules
    /// @notice Quotes the native rules from the authenticated context.
    /// @dev Buys (exact input and exact output) pay LP Rewards as LP fee, protocol share, royalty and burn. Snipe's
    ///      protocol share is a quote take; Snipe is the decayed tax at this block's timestamp (see `_snipePips`). A
    ///      dynamic fee pool is quoted through `quoteSimulatedSwap` and reverts here. Not view, so a later Rules
    ///      version may keep per-swap state.
    function beforeSwap(HookrTypes.SwapContext calldata x) external returns (HookrTypes.FeeQuote memory q) {
        Bound storage b = _bound(x.id);
        _checkContext(b, x);
        HookrTypes.RulesConfig memory c = _hot(b.config);
        // _checkContext pinned x.baseLpFeePips to the bound base fee.
        if (c.maxFeePips > x.baseLpFeePips) revert SimulationRequired();
        q = _quote(x, b, c, 0);
    }

    /// @inheritdoc IHookrDynamicFeeRules
    function poolHasDynamicFee(PoolId id) external view returns (bool) {
        Bound storage b = _state().pools[id];
        return b.bound && b.config.maxFeePips > b.baseFeePips;
    }

    /// @inheritdoc IHookrDynamicFeeRules
    /// @dev The largest protocol share an exact-output sell's dynamic fee can take is the clipped span times the
    ///      share. Its real take is max(its dynamic fee share, the pool's Hookr minimum), and a dynamic fee pool binds
    ///      a minimum only where that largest share is zero (`bind`: the span times the share is below 10,000, a zero
    ///      share included), so the simulation reserves max(the largest share, the minimum), which `_quote` without a
    ///      dynamic fee already gives as the minimum: never less than the real take, and no more than the larger
    ///      bound. Every other shape is quoted without the dynamic fee, so the simulated swap reaches at least as far
    ///      as the real one: its input is not reduced by the dynamic fee's LP part or protocol share.
    function simulationQuote(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.FeeQuote memory q) {
        Bound storage b = _bound(x.id);
        _checkContext(b, x);
        HookrTypes.RulesConfig memory c = _hot(b.config);
        q = _quote(x, b, c, 0);
        if (!x.isBuy && !x.exactInput) {
            uint256 span = uint256(c.maxFeePips) - x.baseLpFeePips;
            uint256 room = 600_000 - x.baseLpFeePips;
            uint256 largest = (span > room ? room : span) * c.protocolShareBps / BPS;
            if (largest > q.quoteTakePips) q.quoteTakePips = uint24(largest);
        }
    }

    /// @inheritdoc IHookrDynamicFeeRules
    /// @dev The dynamic fee is the span times the average rate over the swap's own move away from the reference,
    ///      starting from the nearer of its start price and the anchor. Movement back toward the reference is free.
    ///      `settleSwap` then carries the anchor toward the executed price.
    function quoteSimulatedSwap(HookrTypes.SwapContext calldata x, HookrTypes.SwapSimulation calldata m)
        external
        returns (HookrTypes.FeeQuote memory q)
    {
        Bound storage b = _bound(x.id);
        _checkContext(b, x);
        HookrTypes.RulesConfig memory c = _hot(b.config);
        uint256 dynamicFee;
        if (c.maxFeePips > x.baseLpFeePips) dynamicFee = _dynamicFee(x, b, c, m);
        q = _quote(x, b, c, dynamicFee);
    }

    /// @inheritdoc IHookrRules
    /// @notice Credits actual-fill fees and refunds as Rules claims and returns the credited quote amount.
    /// @dev credited = rulesFee + advisoryFee + refund; liabilities grow by exactly that amount, and a nonzero
    ///      advisoryFee is added to the pool's advisory fee counter (IHookrAdvisoryFeeCounter).
    ///      During the guard, exact-input buys add their gross spend to the parent-block cap counter and
    ///      sells subtract their actualQuote from it (floored at zero). On a decaying Snipe the cap is
    ///      maxBuyQuoteAmount * snipeTaxPips / the current tax, so a parent block that fills it pays the same Snipe
    ///      at every point of the decay; at a zero tax the cap is the counter's own width, which no parent block's
    ///      buys reach. A swap `quoteSimulatedSwap` priced carries the pool's anchor toward its executed price. The
    ///      launch buy (a capped pool's first counted buy, sent by its liquidity owner in the transaction that bound
    ///      it: HookrLauncher's dev buy) pays and counts like any other buy, then fills its parent block's counter so
    ///      no other buy clears on the pool until the next parent block, even once the Snipe has decayed to a zero
    ///      floor; at a zero tax a sell in that parent block frees room for buys of up to its own quote, as sells
    ///      always do. The launch buy carries no anchor and leaves the dynamic fee state unstarted.
    function settleSwap(HookrTypes.SwapContext calldata x, HookrTypes.Settlement calldata z)
        external
        returns (uint256 credited)
    {
        Bound storage b = _bound(x.id);
        _checkContext(b, x);
        if (HookrRoundTripStorage.load().recording[x.id]) _roundTripsCall();
        State storage s = _state();
        HookrTypes.RulesConfig storage c = b.config;
        // _checkContext pinned x.quote to the bound quote.
        Currency quote = x.quote;
        uint256 royaltyBps;
        uint256 lpBps;
        uint256 share;
        uint256 potBps;
        {
            uint256 guardEnd = c.guardEndBlock;
            royaltyBps = c.royaltyBps;
            lpBps = c.lpBps;
            share = c.protocolShareBps;
            potBps = c.potBps;
            // _checkContext pinned x.baseLpFeePips to the bound base fee.
            if (c.maxFeePips > x.baseLpFeePips) {
                _settleDynamicFee(x.id, x.zeroForOne, b.quoteIsCurrency0, z.actualQuote);
            }
            if (block.number < guardEnd) {
                uint256 limit = c.maxBuyQuoteAmount;
                if (limit != 0) {
                    uint256 word = s.guard[x.id];
                    uint256 spent = word >> 192 == block.number ? word & GUARD_MASK : 0;
                    if (x.isBuy) {
                        spent += z.quoteBasis;
                        uint256 duration = c.snipeDecaySeconds;
                        if (duration != 0) {
                            uint256 start = c.snipeTaxPips;
                            uint256 snipe = _snipePips(x.id, b, start, duration);
                            // A zero tax lifts the cap but keeps the counter within its 192 bits.
                            limit = snipe == 0 ? GUARD_MASK : limit * start / snipe;
                        }
                        if (spent > limit) revert GuardBuyLimit(spent, limit);
                        // The launch buy closes its parent block to every other buy on the pool.
                        if (word == 0 && x.sender == b.liquidityOwner && _launchBuy(x.id, true)) spent = GUARD_MASK;
                        s.guard[x.id] = (block.number << 192) | spent;
                    } else if (spent != 0) {
                        spent = spent > z.quoteBasis ? spent - z.quoteBasis : 0;
                        s.guard[x.id] = (block.number << 192) | spent;
                    }
                }
            }
        }
        // King of the Pool (a recapture pool with a pot share): HookrRecapture closes an elapsed epoch and tracks the
        // leader.
        if (potBps != 0) _recapture();
        mapping(address => uint256) storage claims = s.claims[quote];
        uint256 protocol = z.rulesFee;
        uint256 royalty;
        if (x.isBuy && royaltyBps != 0) {
            uint256 lpNet = lpBps * 100 - _protocolPips(lpBps, share);
            royalty = z.quoteBasis * (lpNet * royaltyBps / BPS) / PIPS;
            if (royalty > protocol) royalty = protocol;
            protocol -= royalty;
        }
        if (protocol != 0 && b.terms & TERMS_INTEGRATOR != 0) {
            // The integrator's frozen rate of Hookr's share, rounded down: the odd unit stays with the protocol.
            Integration storage n = s.integrations[x.id];
            uint256 cut = protocol * n.bps / BPS;
            if (cut != 0) {
                address integrator = n.integrator;
                claims[integrator] += cut;
                protocol -= cut;
                emit IntegratorPaid(x.id, quote, integrator, cut);
            }
        }
        if (protocol != 0) {
            claims[protocolRecipient] += protocol;
            // Transient ledger read by the paymaster. Only this statement writes PROTOCOL_PAID.
            bytes32 slot = keccak256(abi.encode(PROTOCOL_PAID, x.payer, quote));
            uint256 paid;
            assembly ("memory-safe") {
                paid := tload(slot)
            }
            paid += protocol;
            assembly ("memory-safe") {
                tstore(slot, paid)
            }
        }
        if (royalty != 0) claims[c.royaltyTo] += royalty;
        if (z.advisoryFee != 0) {
            if (z.advisoryRecipient == address(0)) revert InvalidSettlement();
            claims[z.advisoryRecipient] += z.advisoryFee;
            s.advisoryFees[x.id] += z.advisoryFee;
        }
        if (z.refund != 0) {
            if (x.payer == address(0)) revert InvalidSettlement();
            claims[x.payer] += z.refund;
        }
        credited = z.rulesFee + z.advisoryFee + z.refund;
        if (credited != 0) s.liabilities[quote] += credited;
        emit FeesAllocated(x.id, quote, protocol, royalty, z.refund, z.advisoryRecipient, z.advisoryFee);
    }

    /// @inheritdoc IHookrRules
    /// @notice Protocol fee credited to protocolRecipient in this transaction by swaps whose authenticated payer is
    ///         `payer`, in `quote`: Hookr's share of the rule fees less any integrator's part.
    /// @dev Transient (EIP-1153): monotonic within a transaction, zero at transaction start. Only settleSwap writes it.
    function protocolFeePaid(address payer, Currency quote) external view returns (uint256 amount) {
        bytes32 slot = keccak256(abi.encode(PROTOCOL_PAID, payer, quote));
        assembly ("memory-safe") {
            amount := tload(slot)
        }
    }

    /// @inheritdoc IHookrRules
    function claimable(Currency currency, address beneficiary)
        external
        view
        override(IHookrRules, IHookrProtocolClaims)
        returns (uint256)
    {
        return _state().claims[currency][beneficiary];
    }

    /// @inheritdoc IHookrRulesState
    function totalLiability(Currency currency) external view returns (uint256) {
        return _state().liabilities[currency];
    }

    /// @inheritdoc IHookrRulesConfig
    /// @dev Unbound pools return zero fields.
    function config(PoolId id) external view returns (HookrTypes.RulesConfig memory) {
        return _state().pools[id].config;
    }

    /// @inheritdoc IHookrRulesState
    function integration(PoolId id) external view returns (address integrator, uint16 integratorBps) {
        Integration storage n = _state().integrations[id];
        return (n.integrator, n.bps);
    }

    /// @inheritdoc IHookrRules
    /// @notice Returns whether owned PoolManager claims cover the currency liabilities.
    function accountingInvariant(Currency currency) external view returns (bool) {
        return poolManager.balanceOf(address(this), currency.toId()) >= _state().liabilities[currency];
    }

    /// @inheritdoc IHookrRules
    /// @notice Pays the caller's claim to the caller, up to the PoolManager amount limit.
    function claim(Currency currency) external returns (uint256) {
        return _claim(currency, msg.sender);
    }

    /// @inheritdoc IHookrRules
    /// @dev Any recipient except zero, the PoolManager, this contract (which has no sweep) and `trustedRoot`, which has
    ///      no path that moves an ERC-20 balance.
    function claimTo(Currency currency, address to)
        external
        override(IHookrRules, IHookrProtocolClaims)
        returns (uint256)
    {
        return _claim(currency, to);
    }

    /// @inheritdoc IHookrProtocolClaimsTransfer
    /// @notice Pays the caller's whole claim to `to` as PoolManager ERC-6909 claims. Moves no token.
    /// @dev The exit for a quote whose transfers are paused, taxed or restricted for the recipient. The
    ///      recipient redeems the ERC-6909 balance later through any PoolManager unlock. Refuses the recipients
    ///      claimTo refuses: a balance paid to `trustedRoot` would leave it only as a protocol claim (`sweepClaims`).
    function claimAsClaims(Currency currency, address to) external returns (uint256 amount) {
        State storage s = _state();
        amount = _debit(s, currency, to);
        poolManager.transfer(to, currency.toId(), amount);
        emit Claimed(currency, msg.sender, to, amount);
    }

    /// @inheritdoc IHookrRulesState
    function dynamicFeeParameters()
        external
        pure
        returns (uint256 window, uint256 reset, uint256 carryBps, uint256 moveTicks)
    {
        return (
            HookrTypes.DEFAULT_WINDOW_SECONDS,
            HookrTypes.DEFAULT_RESET_SECONDS,
            HookrTypes.DEFAULT_CARRY_BPS,
            HookrTypes.DEFAULT_MOVE_TICKS
        );
    }

    /// @inheritdoc IHookrRulesState
    function referenceState(PoolId id)
        external
        view
        returns (
            uint256 minLiquidity,
            int24 referenceTick,
            int24 anchorTick,
            uint40 movedAt,
            uint40 referenceAt,
            int24 movedTick
        )
    {
        DynamicFeeState storage g = _state().dynamicFee[id];
        return (g.minLiquidity, g.referenceTick, g.anchorTick, g.movedAt, g.referenceAt, g.movedTick);
    }

    function _debit(State storage s, Currency currency, address to) private returns (uint256 amount) {
        if (_claiming) revert ReentrantClaim();
        if (to == address(0) || to == address(poolManager) || to == address(this) || to == trustedRoot) {
            revert InvalidConfig();
        }
        amount = s.claims[currency][msg.sender];
        if (amount == 0) revert NothingToClaim();
        s.claims[currency][msg.sender] = 0;
        s.liabilities[currency] -= amount;
    }

    function _claim(Currency currency, address to) private returns (uint256 amount) {
        State storage s = _state();
        if (_claiming) revert ReentrantClaim();
        if (to == address(0) || to == address(poolManager) || to == address(this) || to == trustedRoot) {
            revert InvalidConfig();
        }
        amount = s.claims[currency][msg.sender];
        if (amount == 0) revert NothingToClaim();
        // PoolManager amounts are signed int128. Large accumulated claims remain payable in chunks.
        if (amount > uint256(uint128(type(int128).max))) amount = uint256(uint128(type(int128).max));
        _claiming = true;
        s.claims[currency][msg.sender] -= amount;
        s.liabilities[currency] -= amount;
        poolManager.unlock(abi.encode(currency, to, amount));
        _claiming = false;
        emit Claimed(currency, msg.sender, to, amount);
    }

    /// @inheritdoc IUnlockCallback
    /// @notice Burns the reserved claims and takes their backing during an authenticated claim.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_claiming) revert Unauthorized();
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        uint256 beforeBalance = currency.isAddressZero() ? 0 : currency.balanceOf(to);
        uint256 managerBefore = currency.isAddressZero() ? 0 : currency.balanceOf(address(poolManager));
        poolManager.take(currency, to, amount);
        if (!currency.isAddressZero()) {
            uint256 afterBalance = currency.balanceOf(to);
            uint256 managerAfter = currency.balanceOf(address(poolManager));
            if (
                afterBalance < beforeBalance || afterBalance - beforeBalance != amount || managerAfter > managerBefore
                    || managerBefore - managerAfter != amount
            ) revert ClaimFailed();
        }
        return bytes("");
    }

    /// @dev LP Rewards, quote take and burn parts of a buy. lpReward is pips of pool input; take is pips of
    ///      the gross buyer spend (LP-reward protocol share + royalty + burn slice), royaltyPips the royalty's part of it.
    ///      The protocol's share of each slice is taken in pips, rounded up (`_protocolPips`); the burn left after it is
    ///      whole basis points, rounded down.
    function _buyParts(HookrTypes.RulesConfig memory c)
        private
        pure
        returns (uint256 lpReward, uint256 take, uint16 burnBps, uint256 royaltyPips)
    {
        uint256 lpSlice = _protocolPips(c.lpBps, c.protocolShareBps);
        uint256 lpNet = uint256(c.lpBps) * 100 - lpSlice;
        royaltyPips = lpNet * c.royaltyBps / BPS;
        uint256 burnSlice = _protocolPips(c.burnBps, c.protocolShareBps);
        lpReward = lpNet - royaltyPips;
        take = lpSlice + royaltyPips + burnSlice;
        burnBps = uint16((uint256(c.burnBps) * 100 - burnSlice) / 100);
    }

    /// @dev The protocol's share of a `bps` slice of a buy, in pips of the gross buyer spend, rounded up:
    ///      ceil(bps x 100 x shareBps / BPS). Exact whenever shareBps is a whole percent.
    function _protocolPips(uint256 bps, uint256 shareBps) private pure returns (uint256) {
        return (bps * shareBps + 99) / 100;
    }

    /// @dev Whether a rule of `c` can pay Hookr at least a pip of some swap at the pool's protocolShareBps, on a pool
    ///      with base fee `base`, so that the pool binds no Hookr minimum (`bind`). LP Rewards and Auto Burn do at any
    ///      nonzero share: `_protocolPips` rounds their slices up. `_quote` rounds the dynamic fee's and the Snipe's
    ///      shares down, so the dynamic fee does only when its whole span (maxFeePips less the base fee, which a swap
    ///      starting past the knee pays) times the share is at least 10,000, and the Anti-Snipe tax only when
    ///      snipeTaxPips (its largest value, at launch) times the share is. Below that each pays Hookr nothing on every
    ///      swap. Neither is clipped short of that on a pool without LP Rewards (`_validate`), and LP Rewards already
    ///      earn.
    function _earnsHookr(HookrTypes.RulesConfig memory c, uint256 base) private pure returns (bool) {
        uint256 share = c.protocolShareBps;
        if (share == 0) return false;
        if (c.lpBps != 0 || c.burnBps != 0) return true;
        uint256 span = c.maxFeePips > base ? c.maxFeePips - base : 0;
        return span * share >= BPS || uint256(c.snipeTaxPips) * share >= BPS;
    }

    /// @dev Whether `advisory` is Tax + Conversion and the pool's `share` is nonzero, so that the pool binds no Hookr
    ///      minimum (`bind`): Tax + Conversion's queues split each tax it takes at the pool's protocolShareBps, so it
    ///      earns Hookr a share of the tax. Known by the exclusive group it declares, one word from
    ///      `EXCLUSIVE_GROUP()` equal to keccak256("DIRECTIONAL_QUOTE_TAX"), read with GROUP_READ_GAS (a failed,
    ///      starved or malformed read is no), and by its admission on the binding root, which must let it take the
    ///      quote. Every other advisory's charge is its own.
    function _taxConversion(address advisory, uint256 share) private view returns (bool) {
        if (advisory == address(0) || share == 0) return false;
        bytes32 group;
        assembly ("memory-safe") {
            mstore(0, EXCLUSIVE_GROUP_SELECTOR)
            // The call first: Yul evaluates arguments right to left, so returndatasize() must follow it.
            let ok := staticcall(GROUP_READ_GAS, advisory, 0, 4, 0, 32)
            if and(ok, eq(returndatasize(), 32)) { group := mload(0) }
        }
        return group == TAX_CONVERSION_GROUP && registry.admission(msg.sender, advisory).caps.maxQuoteTakePips != 0;
    }

    /// @dev Every native rule for context `x` with `dynamicFee` pips before clipping. The dynamic fee is clipped to
    ///      the room left by base and LP Rewards, then Snipe to what remains. On a pool with a Hookr minimum the quote
    ///      take then gains the minimum less Hookr's rule-fee share of the swap (its share of LP Rewards, Auto Burn,
    ///      the dynamic fee and the Snipe; the royalty is not Hookr's) when that share is below it: the whole minimum,
    ///      since only a pool whose rules earn Hookr nothing binds one (`bind`). The LP fee surcharge never changes
    ///      with it.
    function _quote(
        HookrTypes.SwapContext calldata x,
        Bound storage b,
        HookrTypes.RulesConfig memory c,
        uint256 dynamicFee
    ) private view returns (HookrTypes.FeeQuote memory q) {
        bool guard = block.number < c.guardEndBlock;
        if (guard && x.isBuy && !x.exactInput) revert GuardExactOutput();
        // _checkContext pinned x.baseLpFeePips to the bound base fee.
        uint256 base = x.baseLpFeePips;
        uint256 lpReward;
        uint256 take;
        uint256 royaltyPips;
        if (x.isBuy) {
            (lpReward, take, q.subjectBurnBps, royaltyPips) = _buyParts(c);
        }
        uint256 room = 600_000 - base - lpReward;
        uint256 snipe;
        if (guard && x.isBuy) {
            snipe = c.snipeTaxPips;
            uint256 duration = b.config.snipeDecaySeconds;
            if (duration != 0) snipe = _snipePips(x.id, b, snipe, duration);
        }
        if (dynamicFee > room) dynamicFee = room;
        if (snipe > room - dynamicFee) snipe = room - dynamicFee;
        uint256 protocolPips = dynamicFee * c.protocolShareBps / BPS + snipe * c.protocolShareBps / BPS;
        q.lpFeeSurchargePips = uint24(lpReward + dynamicFee + snipe - protocolPips);
        take += protocolPips;
        if (b.terms & TERMS_MINIMUM != 0) {
            uint256 minimum = _state().integrations[x.id].minFeePips;
            uint256 share = take - royaltyPips;
            if (share < minimum) take += minimum - share;
        }
        q.quoteTakePips = uint24(take);
    }

    /// @dev Decaying Snipe LP-fee pips before clipping, for a nonzero `duration`: from `start` at launch to
    ///      snipeFloorPips at `duration` seconds, then the floor, along the pool's snipeCurve (`_knobbedSnipe` for a
    ///      pool with Knobs, TERMS_KNOBS; the linear curve, `_linearSnipe`, for every other). The launch age is taken
    ///      modulo 2^32 like the stored launchedAt, and a clock behind the launch reads as the launch.
    function _snipePips(PoolId id, Bound storage b, uint256 start, uint256 duration) private view returns (uint256) {
        uint256 elapsed;
        unchecked {
            elapsed = uint32(uint32(block.timestamp) - b.launchedAt);
        }
        if (elapsed > MAX_LAUNCH_AGE) elapsed = 0;
        uint256 floor = b.config.snipeFloorPips;
        if (b.terms & TERMS_KNOBS != 0) return _knobbedSnipe(id, start, floor, duration, elapsed);
        if (elapsed >= duration) return floor;
        return _linearSnipe(start, floor, duration, elapsed);
    }

    /// @dev The linear Snipe, the default curve, at `elapsed` seconds before the end of a `duration`-second decay:
    ///      floor + (start - floor) * (duration - elapsed) / duration, rounded down.
    function _linearSnipe(uint256 start, uint256 floor, uint256 duration, uint256 elapsed)
        private
        pure
        returns (uint256)
    {
        return floor + (start - floor) * (duration - elapsed) / duration;
    }

    /// @dev The Snipe of a pool with Knobs, `elapsed` seconds after launch, along its snipeCurve: the floor from
    ///      `duration` on. Before it, with d = duration, e = elapsed, x = start - floor and n = 8e / d (the eighth of
    ///      the decay e falls in, 0 to 7), every division rounded down:
    ///      SNIPE_CURVE_LINEAR, floor + x * (d - e) / d (`_linearSnipe`);
    ///      SNIPE_CURVE_FRONT_LOADED, what is left to fall halves every eighth of the decay, in a straight line
    ///      between the halvings, the last eighth falling the rest of the way: with r = 8e - n * d, h = x >> n and
    ///      l = h >> 1, or 0 in the last eighth, floor + l + (h - l) * (d - r) / d, which is floor + (x >> n) at each
    ///      eighth n * d / 8 and stays at or below the linear curve but for rounding;
    ///      SNIPE_CURVE_STEP, floor + x * (8 - n) / 8, held through each eighth: `start` through the first, an eighth
    ///      of x lower from the start of each later one, and never below the linear curve.
    ///      Each is `start` at e = 0, never rises and never leaves [floor, start].
    function _knobbedSnipe(PoolId id, uint256 start, uint256 floor, uint256 duration, uint256 elapsed)
        private
        view
        returns (uint256)
    {
        uint256 curve = _state().knobs[id].snipeCurve;
        if (elapsed >= duration) return floor;
        if (curve == HookrTypes.SNIPE_CURVE_LINEAR) return _linearSnipe(start, floor, duration, elapsed);
        uint256 n = elapsed * 8 / duration;
        if (curve == HookrTypes.SNIPE_CURVE_STEP) return floor + (start - floor) * (8 - n) / 8;
        uint256 h = (start - floor) >> n;
        uint256 l = n == 7 ? 0 : h >> 1;
        return floor + l + (h - l) * (duration - (elapsed * 8 - n * duration)) / duration;
    }

    /// @dev Dynamic fee pips before clipping, and the pool's new reference, at the pool's tempo (`_tempo`). The
    ///      reference joins the anchor once the reset passes without an anchor move. Otherwise it steps toward the
    ///      anchor, keeping carryBps of its distance, once per window without an anchor move or a step, and once per
    ///      reset without a step. Steps are counted in time, so they do not depend on how many swaps arrive. Leaves
    ///      `settleSwap` the swap's lag: how far it started ahead of where it was charged from.
    function _dynamicFee(
        HookrTypes.SwapContext calldata x,
        Bound storage b,
        HookrTypes.RulesConfig memory c,
        HookrTypes.SwapSimulation calldata m
    ) private returns (uint256 dynamicFee) {
        DynamicFeeState memory g = _state().dynamicFee[x.id];
        uint256 t = block.timestamp;
        bool launchBuy;
        if (g.flags & DYNAMIC_FEE_STARTED == 0) {
            g.referenceTick = m.tickBefore;
            g.anchorTick = m.tickBefore;
            g.movedTick = m.tickBefore;
            g.movedAt = uint40(t);
            g.referenceAt = uint40(t);
            g.flags |= DYNAMIC_FEE_STARTED;
            // The launch buy (see settleSwap) is charged from the launch price and starts nothing: the next swap is
            // measured from where the launch buy left the price, as on a pool launched there.
            launchBuy = x.isBuy && x.sender == b.liquidityOwner && _launchBuy(x.id, false);
        } else {
            uint256 window = HookrTypes.DEFAULT_WINDOW_SECONDS;
            uint256 reset = HookrTypes.DEFAULT_RESET_SECONDS;
            uint256 carryBps = HookrTypes.DEFAULT_CARRY_BPS;
            if (g.flags & DYNAMIC_FEE_KNOBBED != 0) {
                Knobs storage k = _state().knobs[x.id];
                (window, reset, carryBps) = (k.windowSeconds, k.resetSeconds, k.carryBps);
            }
            if (t >= g.movedAt + reset) {
                g.referenceTick = g.anchorTick;
                g.referenceAt = uint40(t);
            } else {
                // t < movedAt + reset, so at most (reset - 1) / window window steps are due: 3 at the defaults, 149
                // at the widest knobs. Unchecked: movedAt and referenceAt are past block timestamps, so no later than t
                // (block.timestamp never falls), every step's time is at most t, a tick distance times carryBps is
                // below 2^39, and window and reset are never zero on a dynamic fee pool (bind), so nothing here
                // overflows, underflows or divides by zero.
                unchecked {
                    uint256 last = g.movedAt > g.referenceAt ? g.movedAt : g.referenceAt;
                    uint256 steps = (t - last) / window;
                    uint256 windowAt = last + steps * window;
                    uint256 resets = (t - g.referenceAt) / reset;
                    if (resets > steps) {
                        steps = resets;
                        windowAt = g.referenceAt + resets * reset;
                    }
                    if (steps != 0) {
                        int256 d = int256(g.referenceTick) - g.anchorTick;
                        for (uint256 i; i < steps && d != 0; ++i) {
                            d = d * int256(carryBps) / int256(BPS);
                        }
                        g.referenceTick = int24(g.anchorTick + d);
                        g.referenceAt = uint40(windowAt);
                    }
                }
            }
        }
        uint256 lag;
        {
            uint160 sqrtRef = TickMath.getSqrtPriceAtTick(g.referenceTick);
            int256 from = HookrDynamicFee.distance(sqrtRef, m.sqrtPriceBeforeX96, x.zeroForOne);
            int256 end = HookrDynamicFee.distance(sqrtRef, m.sqrtPriceAfterX96, x.zeroForOne);
            int256 away = from > 0 ? from : int256(0);
            if (end > away) {
                int256 anchor =
                    HookrDynamicFee.distance(sqrtRef, TickMath.getSqrtPriceAtTick(g.anchorTick), x.zeroForOne);
                int256 start = anchor < from ? anchor : from;
                if (start < 0) start = 0;
                uint256 a = uint256(start);
                uint256 ratio = HookrDynamicFee.averageRate(a, a + uint256(end - away), c.dynamicFeeSens);
                dynamicFee = (uint256(c.maxFeePips) - x.baseLpFeePips) * ratio / HookrDynamicFee.WAD;
                // A start more than a tick ahead of the anchor was not charged for; the anchor's own rounding lag was.
                int256 ahead = int256(m.tickBefore) - g.anchorTick;
                if (ahead > 1 || ahead < -1) lag = uint256(away) - a;
            }
        }
        // The launch buy leaves the state unstarted, so the pool's next swap starts it at the post-buy price.
        if (launchBuy) return dynamicFee;
        _state().dynamicFee[x.id] = g;
        uint160 simulatedEnd = m.sqrtPriceAfterX96;
        assembly ("memory-safe") {
            tstore(DYNAMIC_FEE_LAG, or(ANCHOR_PENDING, lag))
            tstore(DYNAMIC_FEE_END, simulatedEnd)
        }
    }

    /// @dev IHookrLaneRules.carryLeg, from the fallback: a recapture executor leg on a dynamic fee pool, charged no
    ///      dynamic fee, carries the pool's dynamic fee state exactly as an ordinary swap priced on the same simulation
    ///      and settled with the same quote: `_dynamicFee` steps or joins the reference by the windows, starts an
    ///      unstarted state at the leg's start (a launch buy starts none) and leaves the lag, and `_settleDynamicFee`
    ///      moves the anchor toward the executed price (`_moveAnchor`: the pool's minimum dynamic fee liquidity, the
    ///      simulated end, the lag, the rounding toward the old anchor and the move that restarts the windows). The fee
    ///      `_dynamicFee` prices is dropped: nothing is charged or credited. Root only, as `settleSwap`. The input is
    ///      `abi.encodeCall(IHookrLaneRules.carryLeg, (context, simulation, quoteAmount))`: three static arguments of
    ///      13, 4 and 1 words, read in place.
    function _carryLeg() private {
        if (msg.data.length != CARRY_LEG_INPUT) revert InvalidSettlement();
        HookrTypes.SwapContext calldata x;
        HookrTypes.SwapSimulation calldata m;
        uint256 quoteAmount;
        assembly ("memory-safe") {
            x := 4
            m := 420
            quoteAmount := calldataload(548)
        }
        Bound storage b = _bound(x.id);
        _checkContext(b, x);
        HookrTypes.RulesConfig memory c = _hot(b.config);
        // _checkContext pinned x.baseLpFeePips to the bound base fee.
        if (c.maxFeePips > x.baseLpFeePips) {
            _dynamicFee(x, b, c, m);
            _settleDynamicFee(x.id, x.zeroForOne, b.quoteIsCurrency0, quoteAmount);
        }
    }

    /// @dev Whether an anchor move of `moved` ticks from movedTick counts: at least the pool's moveTicks either way,
    ///      its Knobs' when its DynamicFeeState `flags` say its tempo is there (DYNAMIC_FEE_KNOBBED), else the default.
    function _counts(PoolId id, uint256 flags, int256 moved) private view returns (bool) {
        int256 moveTicks = int256(uint256(HookrTypes.DEFAULT_MOVE_TICKS));
        if (flags & DYNAMIC_FEE_KNOBBED != 0) moveTicks = int256(uint256(_state().knobs[id].moveTicks));
        return moved >= moveTicks || moved <= -moveTicks;
    }

    /// @dev Whether LAUNCH_BUY holds `id`, clearing it when `take`: the pool's launch buy, once.
    function _launchBuy(PoolId id, bool take) private returns (bool found) {
        assembly ("memory-safe") {
            found := eq(tload(LAUNCH_BUY), id)
            if and(found, take) { tstore(LAUNCH_BUY, 0) }
        }
    }

    /// @dev Consumes what `quoteSimulatedSwap` left for this swap and moves the anchor.
    function _settleDynamicFee(PoolId id, bool zeroForOne, bool quoteIs0, uint256 quoteAmount) private {
        uint256 lag;
        uint160 simulatedEnd;
        assembly ("memory-safe") {
            lag := tload(DYNAMIC_FEE_LAG)
            simulatedEnd := tload(DYNAMIC_FEE_END)
            tstore(DYNAMIC_FEE_LAG, 0)
        }
        if (lag != 0) _moveAnchor(id, zeroForOne, quoteIs0, quoteAmount, lag ^ ANCHOR_PENDING, simulatedEnd);
    }

    /// @dev Carries the anchor toward the executed price by the distance `quoteAmount` pays at the pool's minimum
    ///      dynamic fee liquidity, and never past the distance the swap was charged to reach: no further than the
    ///      simulated end, the last price with liquidity (a swap that ends at its price limit in an empty range crossed
    ///      that range for free), and, for a swap that started `lag` ahead of where it was charged from, only as far as
    ///      its own move. A move that ends at least `moveTicks` (the pool's) from movedTick, at the swap's own end,
    ///      restarts the windows.
    function _moveAnchor(
        PoolId id,
        bool zeroForOne,
        bool quoteIs0,
        uint256 quoteAmount,
        uint256 lag,
        uint160 simulatedEnd
    ) private {
        DynamicFeeState memory g = _state().dynamicFee[id];
        (uint160 sqrtEnd, int24 tickEnd,,) = poolManager.getSlot0(id);
        uint160 sqrtAnchor = TickMath.getSqrtPriceAtTick(g.anchorTick);
        uint160 target = (zeroForOne ? simulatedEnd > sqrtEnd : simulatedEnd < sqrtEnd) ? simulatedEnd : sqrtEnd;
        if (lag != 0) {
            uint160 sqrtRef = TickMath.getSqrtPriceAtTick(g.referenceTick);
            int256 end = HookrDynamicFee.distance(sqrtRef, target, zeroForOne);
            target = HookrDynamicFee.priceAt(sqrtRef, end > int256(lag) ? uint256(end) - lag : 0, zeroForOne);
        }
        (uint160 next, bool reached) =
            HookrDynamicFee.advance(sqrtAnchor, target, g.minLiquidity, quoteAmount, quoteIs0);
        if (next == sqrtAnchor) return;
        // The anchor's new tick is rounded toward its old price, so a move of less than one tick never shifts it.
        int24 tick = reached && target == sqrtEnd ? tickEnd : TickMath.getTickAtSqrtPrice(next);
        if (next < sqrtAnchor && TickMath.getSqrtPriceAtTick(tick) < next) ++tick;
        if (tick == g.anchorTick) return;
        g.anchorTick = tick;
        int256 moved = int256(tick) - g.movedTick;
        if (reached && _counts(id, g.flags, moved)) {
            g.movedAt = uint40(block.timestamp);
            g.movedTick = tick;
        }
        _state().dynamicFee[id] = g;
    }

    /// @dev The effective protocolShareBps floor for a bind, the larger of minProtocolShareBps and the treasury's
    ///      governed floor, `integrator`'s rate on the treasury's list (zero for no integrator) and the treasury's Hookr
    ///      minimum for pool `id` (`lane`: with arb recapture, a rate `bind` never keeps; `integrator`'s override only
    ///      if it approved `id`). A protocol recipient without code has no governed floor, no list and no minimum, so
    ///      it admits no integrator. An integrator off the list, a rate above MAX_INTEGRATOR_BPS or a minimum above
    ///      MAX_MIN_FEE_PIPS is refused, and so is an integrator that could never claim what settleSwap credits it,
    ///      whatever the list says: these Rules, their trusted root, their protocol recipient, the PoolManager and
    ///      their HookrRecapture module.
    function _feeTerms(address integrator, bool lane, PoolId id)
        private
        view
        returns (uint256 floor, uint256 integratorBps, uint256 minFee)
    {
        floor = minProtocolShareBps;
        address recipient = protocolRecipient;
        if (recipient.code.length != 0) {
            (uint16 governed, uint16 rate, uint16 minimum) = IHookrTreasury(recipient).feeTerms(integrator, lane, id);
            if (governed > floor) floor = governed;
            if (integrator != address(0)) integratorBps = rate;
            minFee = minimum;
        }
        if (
            integrator != address(0)
                && (integratorBps == 0
                    || integratorBps > MAX_INTEGRATOR_BPS
                    || integrator == address(this)
                    || integrator == trustedRoot
                    || integrator == recipient
                    || integrator == address(poolManager)
                    || integrator == recapture)
        ) revert UnknownIntegrator(integrator);
        if (minFee > MAX_MIN_FEE_PIPS) revert InvalidConfig();
    }

    /// @dev Refuses Rules knobs out of HookrTypes' bounds or at odds with the config, and Rules data longer than the
    ///      pool needs: a pool without dynamic fees, arb recapture or a knob off its default binds its config alone.
    ///      Returns whether a knob is off its default, which the pool then stores (`Knobs`, TERMS_KNOBS), and whether
    ///      one of them is the dynamic fee tempo (DYNAMIC_FEE_KNOBBED). `knobbed`: the data carries RulesKnobs;
    ///      `lane`: and a RecaptureConfig.
    function _checkKnobs(HookrTypes.RulesConfig memory c, HookrTypes.RulesKnobs memory k, bool knobbed, bool lane)
        private
        view
        returns (bool custom, bool tempo)
    {
        if (c.dynamicFeeSens == 0) {
            if (
                k.minDynamicFeeLiquidity != 0 || k.windowSeconds != 0 || k.resetSeconds != 0 || k.carryBps != 0
                    || k.moveTicks != 0
            ) revert InvalidConfig();
        } else {
            uint256 window = k.windowSeconds;
            uint256 reset = k.resetSeconds;
            if (
                !knobbed || k.minDynamicFeeLiquidity == 0 || !rootSimulates || window < HookrTypes.MIN_WINDOW_SECONDS
                    || window > HookrTypes.MAX_WINDOW_SECONDS || reset < 2 * window
                    || reset < HookrTypes.MIN_RESET_SECONDS || reset > HookrTypes.MAX_RESET_SECONDS
                    || reset % HookrTypes.RESET_STEP_SECONDS != 0 || k.carryBps > HookrTypes.MAX_CARRY_BPS
                    || k.carryBps % HookrTypes.CARRY_STEP_BPS != 0 || k.moveTicks < HookrTypes.MIN_MOVE_TICKS
                    || k.moveTicks > HookrTypes.MAX_MOVE_TICKS
            ) revert InvalidConfig();
            tempo = window != HookrTypes.DEFAULT_WINDOW_SECONDS || reset != HookrTypes.DEFAULT_RESET_SECONDS
                || k.carryBps != HookrTypes.DEFAULT_CARRY_BPS || k.moveTicks != HookrTypes.DEFAULT_MOVE_TICKS;
            custom = tempo;
        }
        if (k.snipeCurve > HookrTypes.SNIPE_CURVE_STEP || (k.snipeCurve != 0 && c.snipeDecaySeconds == 0)) {
            revert InvalidConfig();
        }
        if (k.snipeCurve != 0) custom = true;
        if (knobbed && !lane && !custom && c.dynamicFeeSens == 0) revert InvalidConfig();
    }

    /// @dev Refuses a configuration that is out of range, past the dynamic fee's reach bound, uses the disabled pot,
    ///      or would later brick valid swaps at its frozen caps. pc.caps are min(pool, admission) less the advisory's admitted
    ///      maximum; maxLpFeePips is the total LP fee. `floor` is the effective protocolShareBps floor (`_feeTerms`),
    ///      `minFee` the pool's Hookr minimum. The royalty recipient is never these Rules, their trusted root, the
    ///      PoolManager or their HookrRecapture module, which `_feeTerms` refuses as an integrator for the same reason:
    ///      none can ever claim what settleSwap credits it.
    function _validate(
        HookrTypes.RulesConfig memory c,
        HookrTypes.PoolConfig calldata pc,
        uint256 floor,
        uint256 minFee
    ) private view {
        if (c.protocolShareBps < floor) revert InvalidConfig();
        if (
            c.maxFeePips < pc.baseLpFeePips || c.maxFeePips > 600_000
                || uint256(pc.baseLpFeePips) + c.snipeTaxPips > 600_000 || c.dynamicFeeSens > 10
                || uint256(c.burnBps) + c.lpBps > 1_000 || c.royaltyBps > 1_000 || c.protocolShareBps > 5_000
                || (c.dynamicFeeSens == 0) != (c.maxFeePips == pc.baseLpFeePips)
                || (c.royaltyBps == 0) != (c.royaltyTo == address(0)) || c.potEveryNBuys != 0 || c.potMinBuyQuote != 0
                || (c.royaltyBps != 0 && c.lpBps == 0) || c.royaltyTo == address(this) || c.royaltyTo == trustedRoot
                || c.royaltyTo == address(poolManager) || c.royaltyTo == recapture
                || (c.snipeDecaySeconds > HookrTypes.MAX_SNIPE_DECAY_SECONDS
                    && (c.guardEndBlock <= block.number
                        || c.snipeDecaySeconds > (c.guardEndBlock - block.number) * HookrTypes.PARENT_BLOCK_SECONDS))
                || (c.snipeDecaySeconds == 0 ? c.snipeFloorPips != 0 : c.snipeFloorPips >= c.snipeTaxPips)
        ) revert InvalidConfig();
        if (c.guardEndBlock == 0) {
            if (c.snipeTaxPips != 0 || c.maxBuyQuoteAmount != 0 || c.snipeDecaySeconds != 0) revert InvalidConfig();
        } else if (
            c.guardEndBlock <= block.number || c.guardEndBlock > block.number + 100_000
                || pc.liquidityOwner == address(0)
        ) {
            revert InvalidConfig();
        }
        (uint256 lpReward, uint256 take, uint16 burnBps, uint256 royaltyPips) = _buyParts(c);
        uint256 base = pc.baseLpFeePips;
        if (base + lpReward > 600_000) revert InvalidConfig();
        uint256 share = c.protocolShareBps;
        uint256 span = uint256(c.maxFeePips) - base;
        // The dynamic fee's reach bound; dynamicFeeSens is at most 10 here, below the bound's scale.
        if (!HookrDynamicFee.withinReach(span, c.dynamicFeeSens, share)) revert InvalidConfig();
        // Buys: the dynamic fee is clipped to the room left by base and LP Rewards, then Snipe to what remains.
        uint256 room = 600_000 - base - lpReward;
        uint256 dynamicFee = span > room ? room : span;
        uint256 snipe = c.snipeTaxPips;
        if (snipe > room - dynamicFee) snipe = room - dynamicFee;
        uint256 slice = dynamicFee * share / BPS + snipe * share / BPS;
        uint256 maximumLp = base + lpReward + dynamicFee + snipe - slice;
        if (span + c.snipeTaxPips > room && share != 0) {
            // A clipped dynamic fee and Snipe move between two separately rounded shares. Bound both
            // possible one-pip rounding outcomes across every input size, not only the endpoint.
            slice = (dynamicFee + snipe) * share / BPS;
            uint256 minimumSlice = slice == 0 ? 0 : slice - 1;
            maximumLp = base + lpReward + dynamicFee + snipe - minimumSlice;
        }
        // Caps always cover maxFeePips, the ceiling of a sell's total LP fee.
        if (maximumLp < c.maxFeePips) maximumLp = c.maxFeePips;
        uint256 maximumQuote = slice + take;
        // Sells pay the unclipped dynamic fee slice and no buy take.
        if (span * share / BPS > maximumQuote) maximumQuote = span * share / BPS;
        // A pool with a Hookr minimum has no rule share of Hookr's (bind): a buy takes at most royalty + minimum, a
        // sell the minimum.
        if (royaltyPips + minFee > maximumQuote) maximumQuote = royaltyPips + minFee;
        if (
            maximumLp > pc.caps.maxLpFeePips || maximumQuote > pc.caps.maxQuoteTakePips
                || burnBps > pc.caps.maxSubjectTakeBps
        ) revert InvalidConfig();
    }

    /// @notice The recapture surface, served by HookrRecapture through DELEGATECALL so no selector joins the dispatcher
    ///         ahead of the swap calls of every pool: IHookrLaneRules (`recaptureMode`, `settleRecapture`), the rest
    ///         of IHookrRecaptureRules, IHookrAdvisoryFeeCounter (`advisoryFeeCredited`) and IHookrRulesKnobs
    ///         (`dynamicFeeParameters(PoolId)`, `rulesKnobs`, `dynamicFeeReachBound`). `recaptureModule()`
    ///         answers from this contract's own code, and so does IHookrLaneRules.carryLeg (`_carryLeg`), which prices
    ///         the dynamic fee state.
    fallback() external {
        address module = recapture;
        bytes32 moduleHash = recaptureCodeHash;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            let selector := shr(224, calldataload(0))
            if and(eq(calldatasize(), 4), eq(selector, shr(224, RECAPTURE_MODULE_SELECTOR))) {
                mstore(ptr, module)
                mstore(add(ptr, 32), moduleHash)
                return(ptr, 64)
            }
            // IHookrLaneRules.carryLeg falls through to `_carryLeg`, the Rules' own code; every other call is the
            // module's.
            if iszero(eq(selector, shr(224, CARRY_LEG_SELECTOR))) {
                calldatacopy(ptr, 0, calldatasize())
                let ok := delegatecall(gas(), module, ptr, calldatasize(), 0, 0)
                returndatacopy(ptr, 0, returndatasize())
                if iszero(ok) { revert(ptr, returndatasize()) }
                return(ptr, returndatasize())
            }
        }
        _carryLeg();
    }

    /// @dev DELEGATECALLs HookrRecapture with this call's calldata (bind or settleSwap, whose selectors it shares) and
    ///      bubbles a revert.
    function _recapture() private {
        address module = recapture;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            if iszero(delegatecall(gas(), module, ptr, calldatasize(), 0, 0)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }

    function _bound(PoolId id) private view returns (Bound storage b) {
        b = _state().pools[id];
        if (!b.bound) revert UnknownPool();
        if (msg.sender != trustedRoot) revert Unauthorized();
    }

    /// @dev The first config slot only; beforeSwap never reads maxBuyQuoteAmount, potMinBuyQuote or royaltyTo, and
    ///      reads snipeFloorPips and snipeDecaySeconds from storage on guarded buys alone.
    function _hot(HookrTypes.RulesConfig storage cs) private view returns (HookrTypes.RulesConfig memory c) {
        c.guardEndBlock = cs.guardEndBlock;
        c.maxFeePips = cs.maxFeePips;
        c.snipeTaxPips = cs.snipeTaxPips;
        c.dynamicFeeSens = cs.dynamicFeeSens;
        c.burnBps = cs.burnBps;
        c.lpBps = cs.lpBps;
        c.potBps = cs.potBps;
        c.royaltyBps = cs.royaltyBps;
        c.protocolShareBps = cs.protocolShareBps;
        c.potEveryNBuys = cs.potEveryNBuys;
    }

    /// @dev Rebuilds the pool key from the context's currencies in the bound order, so a subject or quote other than
    ///      the bound pool's does not hash to `x.id`.
    function _checkContext(Bound storage b, HookrTypes.SwapContext calldata x) private view {
        (Currency currency0, Currency currency1) = b.quoteIsCurrency0 ? (x.quote, x.subject) : (x.subject, x.quote);
        PoolKey memory key =
            PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, b.tickSpacing, IHooks(trustedRoot));
        if (
            PoolId.unwrap(key.toId()) != PoolId.unwrap(x.id) || x.baseLpFeePips != b.baseFeePips
                || x.payer == address(0) || x.beneficiary == address(0)
        ) revert InvalidSettlement();
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") { s.slot := SLOT }
    }

    /// @inheritdoc IHookrRoundTripBook
    function recordsRoundTrips(PoolId id) external view returns (bool) {
        return HookrRoundTripStorage.load().recording[id];
    }

    /// @inheritdoc IHookrRoundTripBook
    function roundTripWord(PoolId id, bytes32 trader) external view returns (uint256) {
        return HookrRoundTripStorage.load().words[id][trader];
    }

    /// @dev DELEGATECALLs HookrRoundTripRecords with this call's calldata (bind, or a recording pool's settleSwap,
    ///      whose selectors it shares) and bubbles a revert.
    function _roundTripsCall() private {
        address module = roundTripRecords;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            if iszero(delegatecall(gas(), module, ptr, calldatasize(), 0, 0)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }
}
