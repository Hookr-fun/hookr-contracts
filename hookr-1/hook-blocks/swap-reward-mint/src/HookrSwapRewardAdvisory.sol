// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {IHookrRules} from "hookr/interfaces/IHookrRules.sol";
import {IHookrRecaptureRules} from "hookr/interfaces/IHookrRecaptureRules.sol";
import {IHookrLaneRules} from "hookr/interfaces/IHookrLaneRules.sol";
import {IHookrLanes} from "hookr/interfaces/IHookrLanes.sol";
import {HookrSessionTiers} from "hookr/libraries/HookrSessionTiers.sol";
import {IHookrRulesView} from "./interfaces/IHookrRulesView.sol";
import {IHookrSwapRewardMinter} from "./interfaces/IHookrSwapRewardMinter.sol";
import {IHookrSwapRewardMinterAttestor} from "./interfaces/IHookrSwapRewardMinterAttestor.sol";

/// @title Hookr swap reward advisory
/// @notice The Swap Reward Mint add-on as a Hookr 1 ADVISORY: on each swap it asks for a fixed reward slice of
///         the quote leg (at most 5%) and names the programme's reward account as the recipient. HookrRules credits
///         the slice as a quote claim to that account; the off-pool minter later turns it into reward tokens.
/// @dev One deployment serves every pool of every registered root that admits it. Per pool it stores one word at
///      bind (one more with session tiers, one more with a recapture lane) and nothing on the swap path. Swap
///      callbacks are `view` (the root STATICCALLs them) and never revert for a bound pool except when they receive
///      too little gas to read the programme or the calendar, which would otherwise let a trader switch the slice off
///      or pick the calendar's failure tier.
///      Bind refuses a pool advisory gas limit below MIN_ADVISORY_GAS_LIMIT, so that happens only when the swap
///      transaction itself was sent with too little gas. A failed or malformed programme read means "charge
///      nothing"; a failed or malformed calendar read charges the pool's highest tier.
///      The slice lands where the root allows a take and where the quote amount is known:
///        exact-input buy  - before phase, buy slice in pips of the specified quote input;
///        exact-output buy - after phase, buy slice in pips of the gross quote spend, from the completed deltas;
///        exact-input sell - after phase, sell slice in pips of the quote output, from the completed deltas;
///        exact-output sell - FIXED mode only: before phase, sell slice in pips of the requested quote output (the
///                            root reserves it on top, so the trader still nets the request). A partly filled
///                            exact-output sell on a FIXED pool then reverts ExactOutputShortfall, as on any pool
///                            with a quote take there. In TRADER mode it is exempt: the slice buys the trader a
///                            reward, so skipping it dodges no fee.
///      The creator sets the buy and sell slices separately; a side set to zero is never charged and never read.
///      Each swap's slice is clipped so it never exceeds the programme's room (per-swap cap and lifetime cap).
///      A TRADER programme credits the slice to the swap's trader: the payer the root authenticated, and only when
///      that payer is also the swap's beneficiary. A swap that pays its output to another address has no trader and
///      pays no TRADER slice, so no payer pays for a reward it does not receive (a Limit Orders fill without its
///      GATE is paid by the book and received by the order's recipient). A FIXED programme credits its fixed
///      recipient on every charged swap, whoever pays.
///      A pool may also freeze optional session tiers (HookrSessionTiers) at bind: an LP-fee surcharge that follows
///      the US equity session, read from the shared calendar fixed at construction and returned in the before phase
///      on every swap. A pool bound without tiers pays for one extra branch and nothing else.
///      Arb recapture legs: a pool whose Rules froze recapture (Hookr 1 launches pre-fill it on) freezes the root's
///      lane executor, and the root asks this advisory about each of that executor's legs as an unauthenticated swap
///      of the executor, charging the surcharge as LP fee and the take through IHookrLaneRules.settleLeg. Bind
///      records the same executor, and every unauthenticated swap whose sender is it is asked nothing: no slice (a
///      FIXED programme would otherwise pay the fixed recipient for arbitrage, spend the programme's room on it and
///      revert a partly filled exact-output sell leg with ExactOutputShortfall) and no session surcharge (the root
///      charges legs no dynamic fee either). The same executor's direct swap outside a frame is exempt too; the
///      executor is trusted. Any other swap, unauthenticated or not, is charged as before.
contract HookrSwapRewardAdvisory is IHookrAdvisory {
    using PoolIdLibrary for PoolKey;

    /// @notice Pips denominator.
    uint256 public constant PIPS = 1_000_000;
    /// @notice The reward slice ceiling, 5% of the quote leg.
    uint24 public constant MAX_REWARD_TAKE_PIPS = 50_000;
    /// @notice Gas stipend of the programme read on the swap path.
    uint256 public constant MINTER_VIEW_GAS = 100_000;
    /// @notice The smallest pool advisory gas limit `bind` accepts. The swap path needs the programme read's stipend,
    ///         its 63/64 margin and the call reserve (111,587) plus calldata and cold-storage overhead; the three
    ///         charged quadrants first succeed at about 113k warm and 115k cold, plus one storage read for an
    ///         unauthenticated swap on a recapture lane pool (its sender against the recorded lane executor). Below
    ///         that every charged swap reverts. The registry admits any gas limit from 25,000 and the root pins the pool's limit to the
    ///         admission's, so the advisory refuses the launch rather than bind an immutable pool that cannot trade.
    uint32 public constant MIN_ADVISORY_GAS_LIMIT = 150_000;
    /// @notice The smallest pool advisory gas limit `bind` accepts for a pool with session tiers. The before phase then
    ///         also makes the calendar read (HookrSessionTiers.READ_GAS stipend and its margin) ahead of the programme
    ///         read, so a hostile or failing calendar that burns its whole stipend still leaves the programme read its
    ///         stipend and the swap trades.
    uint32 public constant MIN_SESSION_GAS_LIMIT = 200_000;
    /// @notice Both swap phases; the programme needs the after phase for exact-output buys and exact-input sells.
    uint8 public constant PHASES = 3;
    uint256 private constant BPS = 10_000;
    uint256 private constant CALL_RESERVE = 10_000;
    uint256 private constant NATIVE_CEILING = 600_000;
    /// @dev The stipend of the Rules' recapture mode read at bind, the root's own for the same read (HookrLane._freeze).
    uint256 private constant RECAPTURE_READ_GAS = 50_000;
    /// @dev HookrRules.configSchemaHash(): the keccak256 of RulesConfig's type string, the same id as
    ///      HookrFeeAdvisory.RULES_SCHEMA.
    bytes32 private constant HOOKR_RULES_SCHEMA = keccak256(
        "RulesConfig(uint40 guardEndBlock,uint24 maxFeePips,uint24 snipeTaxPips,uint24 snipeFloorPips,uint16 snipeDecaySeconds,uint16 dynamicFeeSens,uint16 burnBps,uint16 lpBps,uint16 potBps,uint16 royaltyBps,uint16 protocolShareBps,uint32 potEveryNBuys,uint128 maxBuyQuoteAmount,uint128 potMinBuyQuote,address royaltyTo,address integrator)"
    );

    /// @notice One pool's frozen programme, packed in one slot.
    /// @param minter The attested programme.
    /// @param buyTakePips The frozen reward slice on buys; zero when buys are not charged.
    /// @param sellTakePips The frozen reward slice on sells; zero when sells are not charged.
    /// @param grossUpPips The rules' worst-case quote take plus the buy slice: an upper bound on the total rate the
    ///        root grosses an exact-output buy up by. Never above the pool's aggregate cap (bind refuses otherwise).
    ///        The rules' ceiling alone is grossUpPips - buyTakePips.
    /// @param sessioned Whether the pool froze non-empty session tiers.
    /// @param exactOutputSells Whether exact-output sells pay the sell slice: a FIXED programme with a sell slice.
    /// @param hasLane Whether the pool froze a recapture lane executor (`laneExecutor`), whose unauthenticated swaps
    ///        are asked nothing.
    struct Binding {
        address minter;
        uint24 buyTakePips;
        uint24 sellTakePips;
        uint24 grossUpPips;
        bool sessioned;
        bool exactOutputSells;
        bool hasLane;
    }

    /// @notice One pool's frozen session tiers and LP-surcharge limits, packed in one slot.
    /// @dev The tier fields mirror HookrSessionTiers.Tiers.
    /// @param limit Largest session surcharge once the rules' launch guard has ended: the admission's LP cap, less
    ///        whatever the rules' largest native LP fee leaves of the pool cap.
    /// @param guardLimit Largest session surcharge while the launch guard is active (the rules' Snipe tax included).
    /// @param guardEnd The rules' guard end, on the rules' block.number clock.
    struct Session {
        uint24 regularPips;
        uint24 preMarketPips;
        uint24 afterHoursPips;
        uint24 overnightPips;
        uint24 closedPips;
        uint16 openRampSeconds;
        uint16 closeRampSeconds;
        uint8 flags;
        uint24 limit;
        uint24 guardLimit;
        uint40 guardEnd;
    }

    /// @notice The admission registry whose roots may bind this advisory.
    IHookrRegistry public immutable registry;
    /// @notice The only factory whose minters this advisory accepts.
    address public immutable factory;
    /// @notice The shared session calendar (a HookrSessionAdvisory, read through `sessionAt`). Zero disables tiers.
    address public immutable calendar;
    mapping(PoolId => Binding) private _bindings;
    mapping(PoolId => Session) private _sessions;
    mapping(PoolId => address) private _laneExecutors;

    error Unauthorized();
    error AlreadyBound(PoolId id);
    error InvalidConfig();
    error UnknownMinter(address minter);
    error MinterMismatch(address minter, uint256 check);
    error TakeAboveAdmission(uint24 take, uint24 admitted);
    error AggregateCapTooLow(uint256 rulesCeiling, uint24 take, uint24 poolCap);
    error RewardTargetNotReady(address minter);
    error InsufficientGas();
    error GasLimitTooLow(uint32 limit, uint32 minimum);
    error SessionCalendarUnset();
    error ProgrammeEnded(address minter);

    /// @notice A pool froze a reward programme.
    event RewardProgrammeBound(
        PoolId indexed id,
        address indexed root,
        address indexed minter,
        uint24 buyTakePips,
        uint24 sellTakePips,
        uint256 rulesQuoteCeilingPips,
        uint24 poolQuoteCapPips,
        uint24 grossUpPips
    );

    /// @notice A pool froze a recapture lane executor; its unauthenticated swaps (the arb recapture legs) pay no slice
    ///         and no session surcharge.
    event LaneExecutorExempt(PoolId indexed id, address indexed executor);

    /// @notice A pool froze session tiers with its LP-surcharge limits.
    event SessionTiersBound(PoolId indexed id, HookrSessionTiers.Tiers tiers, uint24 limit, uint24 guardLimit);

    /// @param registry_ The admission registry.
    /// @param factory_ The minter factory.
    /// @param calendar_ The shared session calendar, or zero for an advisory whose pools cannot bind session tiers.
    constructor(IHookrRegistry registry_, address factory_, address calendar_) {
        if (
            address(registry_).code.length == 0 || factory_.code.length == 0
                || (calendar_ != address(0) && calendar_.code.length == 0)
        ) revert InvalidConfig();
        registry = registry_;
        factory = factory_;
        calendar = calendar_;
    }

    /// @inheritdoc IHookrAdvisory
    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("hookr.advisory.swap-reward-mint.config");
    }

    /// @notice Returns the frozen programme of a pool; a zero minter means unbound.
    function binding(PoolId id) external view returns (Binding memory) {
        return _bindings[id];
    }

    /// @notice Returns the recapture lane executor a pool froze at bind, whose unauthenticated swaps are asked nothing;
    ///         zero for a pool without recapture.
    function laneExecutor(PoolId id) external view returns (address) {
        return _laneExecutors[id];
    }

    /// @notice Returns the frozen session tiers and limits of a pool; all zero when it has none.
    function session(PoolId id) external view returns (Session memory) {
        return _sessions[id];
    }

    /// @notice Returns the session surcharge a pool would receive at `timestamp` on the current block.
    function sessionSurchargeAt(PoolId id, uint256 timestamp) external view returns (uint24) {
        return _bindings[id].sessioned ? _sessionSurcharge(id, timestamp) : 0;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev `data` is abi.encode(minter), or abi.encode(minter, HookrSessionTiers.Tiers) for a pool with session tiers
    ///      (empty tiers bind as no tiers). Refuses the pool (the whole launch reverts) unless: the caller is the
    ///      registered root initializing this key; the minter is attested by the factory and declared for this
    ///      advisory, pool, rules and quote, and is not a sidecar; each side's slice is at most 5%, at least one side
    ///      charges, and the larger slice is inside this advisory's admission cap; both phases are enabled and the
    ///      advisory is strict; the pool's advisory gas limit is at least MIN_ADVISORY_GAS_LIMIT, so no swap sent with
    ///      enough gas can revert for want of the programme read's stipend; the rules' worst-case quote take plus the
    ///      larger slice fits the pool's aggregate cap, so no swap can ever revert AggregateCapExceeded because of
    ///      it; the programme's protocol recipient is the rules' protocol recipient; the reward asset accepts the
    ///      minter today; and the programme's window, if it has one, is still open. Non-empty tiers also need a
    ///      calendar, tiers that pass HookrSessionTiers.check against the admission's LP cap and a pool gas limit of
    ///      at least MIN_SESSION_GAS_LIMIT. The exact-output buy gross-up bound is stored on the buy slice; an
    ///      exact-output sell (FIXED mode) uses the same rules ceiling plus the sell slice. A pool whose Rules froze
    ///      recapture records the root's lane executor, read as the root froze it moments before in the same call
    ///      (the Rules' `recaptureMode` with the root's stipend, then the registry's `activeLaneOf(root)`).
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata config, bytes calldata data)
        external
        returns (bytes32 configHash)
    {
        PoolId id = key.toId();
        if (
            msg.sender != address(key.hooks) || !registry.isRoot(msg.sender)
                || PoolId.unwrap(IHookrRoot(msg.sender).bindingPool()) != PoolId.unwrap(id)
        ) revert Unauthorized();
        if (_bindings[id].minter != address(0)) revert AlreadyBound(id);
        address minter;
        HookrSessionTiers.Tiers memory tiers;
        if (data.length == 32) {
            minter = abi.decode(data, (address));
        } else if (data.length == 32 + HookrSessionTiers.ENCODED_SIZE) {
            (minter, tiers) = abi.decode(data, (address, HookrSessionTiers.Tiers));
        } else {
            revert InvalidConfig();
        }
        if (!IHookrSwapRewardMinterAttestor(factory).isMinter(minter)) revert UnknownMinter(minter);
        IHookrSwapRewardMinter m = IHookrSwapRewardMinter(minter);
        if (m.advisory() != address(this)) revert MinterMismatch(minter, 1);
        if (PoolId.unwrap(m.poolId()) != PoolId.unwrap(id)) revert MinterMismatch(minter, 2);
        if (m.rules() != config.rules) revert MinterMismatch(minter, 3);
        if (Currency.unwrap(m.quote()) != Currency.unwrap(config.quote)) revert MinterMismatch(minter, 4);
        if (m.mode() == IHookrSwapRewardMinter.Mode.SIDECAR) revert MinterMismatch(minter, 5);
        if (m.protocolRecipient() != IHookrRulesView(config.rules).protocolRecipient()) {
            revert MinterMismatch(minter, 6);
        }
        uint24 buyTake = m.buyTakePips();
        uint24 sellTake = m.sellTakePips();
        uint24 take = buyTake > sellTake ? buyTake : sellTake;
        if (take == 0 || take > MAX_REWARD_TAKE_PIPS || config.advisoryPhases != PHASES || config.advisoryFailOpen) {
            revert InvalidConfig();
        }
        HookrTypes.Caps memory own = registry.admission(msg.sender, address(this)).caps;
        if (take > own.maxQuoteTakePips) revert TakeAboveAdmission(take, own.maxQuoteTakePips);
        uint256 ceiling = rulesQuoteCeiling(msg.sender, id, config);
        if (ceiling + take > config.caps.maxQuoteTakePips) {
            revert AggregateCapTooLow(ceiling, take, config.caps.maxQuoteTakePips);
        }
        // The root pins config.advisoryGasLimit to the admission's gasLimit, so this also refuses a low admission.
        if (config.advisoryGasLimit < MIN_ADVISORY_GAS_LIMIT) {
            revert GasLimitTooLow(config.advisoryGasLimit, MIN_ADVISORY_GAS_LIMIT);
        }
        if (!m.rewardReady()) revert RewardTargetNotReady(minter);
        uint40 endsAt = m.endsAt();
        if (endsAt != 0 && endsAt <= block.timestamp) revert ProgrammeEnded(minter);
        HookrSessionTiers.check(tiers, own.maxLpFeePips);
        bool sessioned = !HookrSessionTiers.isEmpty(tiers);
        if (sessioned) _bindSession(id, config, tiers, own.maxLpFeePips);
        uint24 grossUp = uint24(ceiling + buyTake);
        bool exactOutputSells = sellTake != 0 && m.mode() == IHookrSwapRewardMinter.Mode.FIXED;
        address executor = _frozenLaneExecutor(msg.sender, id, config.rules);
        if (executor != address(0)) {
            _laneExecutors[id] = executor;
            emit LaneExecutorExempt(id, executor);
        }
        _bindings[id] = Binding(minter, buyTake, sellTake, grossUp, sessioned, exactOutputSells, executor != address(0));
        emit RewardProgrammeBound(
            id, msg.sender, minter, buyTake, sellTake, ceiling, config.caps.maxQuoteTakePips, grossUp
        );
        return keccak256(data);
    }

    /// @dev The lane executor the root froze for the pool (HookrLane._freeze, run just before this bind): zero unless
    ///      the Rules answer a nonzero recapture mode in one 32-byte word within the root's stipend, then the
    ///      registry's open lane of the root, which the root read and checked in the same call. Too little gas to give
    ///      the mode read its full stipend reverts, so the read cannot miss a lane the root froze.
    function _frozenLaneExecutor(address root, PoolId id, address rules) private view returns (address executor) {
        if (gasleft() < RECAPTURE_READ_GAS + RECAPTURE_READ_GAS / 63 + CALL_RESERVE) revert InsufficientGas();
        bytes memory input = abi.encodeCall(IHookrLaneRules.recaptureMode, (id));
        bool ok;
        uint256 mode;
        assembly ("memory-safe") {
            let out := mload(0x40)
            ok := staticcall(RECAPTURE_READ_GAS, rules, add(input, 32), mload(input), out, 32)
            ok := and(ok, eq(returndatasize(), 32))
            mode := mload(out)
        }
        if (!ok || mode == 0) return address(0);
        (executor,,,) = IHookrLanes(address(registry)).activeLaneOf(root);
    }

    /// @dev Whether the swap is the pool's frozen lane executor's own unauthenticated swap (an arb recapture leg).
    ///      A pool without a lane, or an authenticated swap, reads no extra storage.
    function _isLaneExecutor(Binding memory b, HookrTypes.SwapContext calldata x) private view returns (bool) {
        return b.hasLane && !x.authenticated && x.sender == _laneExecutors[x.id];
    }

    /// @dev The swap's trader for a TRADER programme: the payer when it is also the beneficiary, zero otherwise. The
    ///      minter answers no room for a zero trader in TRADER mode and ignores the trader in FIXED mode.
    function _trader(HookrTypes.SwapContext calldata x) private pure returns (address) {
        return x.payer == x.beneficiary ? x.payer : address(0);
    }

    /// @dev Freezes the tiers with their limits: the admission's LP cap, and no more than what the pool cap leaves
    ///      after the rules' largest native LP fee after and during the launch guard, so the surcharge alone can
    ///      never push a swap over the pool's LP cap.
    function _bindSession(
        PoolId id,
        HookrTypes.PoolConfig calldata config,
        HookrSessionTiers.Tiers memory t,
        uint256 cap
    ) private {
        if (calendar == address(0)) revert SessionCalendarUnset();
        if (config.advisoryGasLimit < MIN_SESSION_GAS_LIMIT) {
            revert GasLimitTooLow(config.advisoryGasLimit, MIN_SESSION_GAS_LIMIT);
        }
        uint256 poolCap = config.caps.maxLpFeePips;
        (uint256 after_, uint256 guard, uint256 guardEnd) = rulesLpCeiling(msg.sender, id, config);
        uint24 limit = uint24(_min(cap, poolCap > after_ ? poolCap - after_ : 0));
        uint24 guardLimit = uint24(_min(cap, poolCap > guard ? poolCap - guard : 0));
        _sessions[id] = Session(
            t.regularPips,
            t.preMarketPips,
            t.afterHoursPips,
            t.overnightPips,
            t.closedPips,
            t.openRampSeconds,
            t.closeRampSeconds,
            t.flags,
            limit,
            guardLimit,
            uint40(guardEnd)
        );
        emit SessionTiersBound(id, t, limit, guardLimit);
    }

    /// @notice An upper bound on the native LP fee (base plus rules surcharge) the pool's rules can set after and
    ///         during the launch guard, and the guard end.
    /// @dev For HookrRules (schema HOOKR_RULES_SCHEMA) it is base + LP Rewards (as HookrRules quotes them, see
    ///      `_buyParts`) + the full dynamic-fee span, plus the Snipe tax during the guard, each at most 600,000 and at
    ///      most the pool and rules-admission caps. For any other rules schema it is min(pool cap, rules admission cap)
    ///      with no guard.
    function rulesLpCeiling(address root, PoolId id, HookrTypes.PoolConfig calldata config)
        public
        view
        returns (uint256 after_, uint256 guard, uint256 guardEnd)
    {
        uint256 ceiling = _min(registry.admission(root, config.rules).caps.maxLpFeePips, config.caps.maxLpFeePips);
        after_ = ceiling;
        guard = ceiling;
        if (IHookrRules(config.rules).configSchemaHash() != HOOKR_RULES_SCHEMA) return (after_, guard, 0);
        HookrTypes.RulesConfig memory c = IHookrRulesView(config.rules).config(id);
        uint256 base = config.baseLpFeePips;
        (uint256 lpReward,,) = _buyParts(c);
        uint256 span = c.maxFeePips > base ? uint256(c.maxFeePips) - base : 0;
        after_ = _min(ceiling, _min(NATIVE_CEILING, base + lpReward + span));
        guard = _min(ceiling, _min(NATIVE_CEILING, base + lpReward + span + c.snipeTaxPips));
        guardEnd = c.guardEndBlock;
    }

    /// @notice An upper bound on the quote-take pips the pool's rules can ever ask for on any swap.
    /// @dev For HookrRules (schema HOOKR_RULES_SCHEMA) it is the larger of two bounds. The first is the buy take
    ///      (LP-Reward protocol share, royalty and burn slice, exactly as HookrRules quotes them, see `_buyParts`) plus
    ///      the protocol share of the full dynamic-fee span and Snipe tax; the dynamic fee never exceeds its span,
    ///      Snipe never exceeds snipeTaxPips and the Rules round each of those two shares down separately. The second
    ///      is the royalty plus the Hookr minimum the pool froze at bind (`minimumFee`, zero for a pool without one):
    ///      the Rules take royalty + max(Hookr's rule share, minimum) on a buy and max(dynamic-fee share, minimum) on a
    ///      sell, so HookrRules cannot quote more on any swap. It is HookrRules' own bind bound
    ///      (`max(rule-fee bound, royalty + minimum)`) with the dynamic fee and Snipe left unclipped. For any other rules
    ///      schema it falls back to the rules' admitted and pool caps.
    function rulesQuoteCeiling(address root, PoolId id, HookrTypes.PoolConfig calldata config)
        public
        view
        returns (uint256 ceiling)
    {
        if (IHookrRules(config.rules).configSchemaHash() == HOOKR_RULES_SCHEMA) {
            HookrTypes.RulesConfig memory c = IHookrRulesView(config.rules).config(id);
            (, uint256 buyTake, uint256 royaltyPips) = _buyParts(c);
            uint256 span = c.maxFeePips > config.baseLpFeePips ? uint256(c.maxFeePips) - config.baseLpFeePips : 0;
            ceiling = buyTake + (span + c.snipeTaxPips) * c.protocolShareBps / BPS;
            uint256 minimum = royaltyPips + IHookrRecaptureRules(config.rules).minimumFee(id);
            if (minimum > ceiling) ceiling = minimum;
        } else {
            uint24 admitted = registry.admission(root, config.rules).caps.maxQuoteTakePips;
            ceiling = admitted < config.caps.maxQuoteTakePips ? admitted : config.caps.maxQuoteTakePips;
        }
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev The slice never gates liquidity.
    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Charges exact-input buys, on the specified quote input, at the buy slice; the root caps the fee at the
    ///      requested input. On a FIXED pool it also charges exact-output sells, on the requested quote output, at
    ///      the sell slice. The root reserves ceil(Q x rate / (PIPS - rate)) on top of the request Q for the total
    ///      rate (the rules' take plus this slice, at most the rules' ceiling plus the sell slice) and credits this
    ///      advisory the reserve less the rules' floor share, which is below Q x slice / (PIPS - rate) + 2. So the
    ///      slice is clipped against room - 2 over (PIPS - ceiling - sell slice) and stays at most room - 1. A pool
    ///      with session tiers also gets its session surcharge on every swap but the lane executor's.
    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory advice) {
        Binding memory b = _bindings[x.id];
        if (b.minter == address(0) || _isLaneExecutor(b, x)) return advice;
        if (b.sessioned) advice.lpFeeSurchargePips = _sessionSurcharge(x.id, block.timestamp);
        uint24 pips;
        address recipient;
        uint256 room;
        if (x.isBuy) {
            if (!x.exactInput || x.amountSpecified >= 0 || b.buyTakePips == 0) return advice;
            (recipient, room) = _room(b.minter, _trader(x), x.authenticated);
            pips = _pips(b.buyTakePips, room, uint256(-x.amountSpecified), PIPS);
        } else {
            if (x.exactInput || x.amountSpecified <= 0 || !b.exactOutputSells) return advice;
            (recipient, room) = _room(b.minter, _trader(x), x.authenticated);
            uint256 grossUp = uint256(b.grossUpPips) - b.buyTakePips + b.sellTakePips;
            pips = _pips(b.sellTakePips, room == 0 ? 0 : room - 1, uint256(x.amountSpecified), PIPS - grossUp);
        }
        if (pips != 0) {
            advice.quoteTakePips = pips;
            advice.recipient = recipient;
        }
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Charges exact-output buys (buy slice) and exact-input sells (sell slice) from the completed pool deltas.
    ///      For a buy the root grosses the fee up over (PIPS - total rate). The total rate is the rules' take (at most
    ///      the bind-time ceiling) plus the buy slice, so the clip divides by (PIPS - grossUpPips) and the slice stays
    ///      inside the room whatever the rules charged. The lane executor's unauthenticated swaps pay nothing.
    function afterSwap(HookrTypes.SwapContext calldata x, int128 amount0, int128 amount1)
        external
        view
        returns (HookrTypes.Advice memory advice)
    {
        Binding memory b = _bindings[x.id];
        if (b.minter == address(0) || x.isBuy == x.exactInput || _isLaneExecutor(b, x)) return advice;
        uint24 take = x.isBuy ? b.buyTakePips : b.sellTakePips;
        if (take == 0) return advice;
        int128 quoteDelta = x.zeroForOne == x.isBuy ? amount0 : amount1;
        uint256 amount = quoteDelta < 0 ? uint256(-int256(quoteDelta)) : uint256(int256(quoteDelta));
        if (amount == 0) return advice;
        (address recipient, uint256 room) = _room(b.minter, _trader(x), x.authenticated);
        uint24 pips = _pips(take, room, amount, x.isBuy ? PIPS - b.grossUpPips : PIPS);
        if (pips != 0) {
            advice.quoteTakePips = pips;
            advice.recipient = recipient;
        }
    }

    /// @dev The session surcharge at `timestamp`, clamped to the pool's limit on the current block. Too little gas to
    ///      give the calendar read its full stipend reverts, so a trader cannot starve the read to pick the failure
    ///      value; a calendar that fails, reverts or returns garbage charges the pool's highest tier.
    function _sessionSurcharge(PoolId id, uint256 timestamp) private view returns (uint24) {
        Session memory s = _sessions[id];
        uint256 stipend = HookrSessionTiers.READ_GAS;
        if (gasleft() < stipend + stipend / 63 + CALL_RESERVE) revert InsufficientGas();
        HookrSessionTiers.Tiers memory t = HookrSessionTiers.Tiers(
            s.regularPips,
            s.preMarketPips,
            s.afterHoursPips,
            s.overnightPips,
            s.closedPips,
            s.openRampSeconds,
            s.closeRampSeconds,
            s.flags
        );
        uint256 value = HookrSessionTiers.valueAt(t, calendar, timestamp);
        uint256 limit = block.number < s.guardEnd ? s.guardLimit : s.limit;
        return uint24(value < limit ? value : limit);
    }

    /// @dev The LP Rewards pips and the quote take pips of a buy, exactly as HookrRules._buyParts quotes them: the
    ///      protocol's share of the LP Rewards and burn slices in pips of the gross buyer spend, each rounded up
    ///      (ceil(bps x shareBps / 100)), then the royalty on the LP Rewards left, rounded down. Taking the share in
    ///      whole basis points rounded down instead (the Rules' rounding before the pips share) under-reads the take by
    ///      up to 99 pips per slice whenever shareBps is not a whole percent, and an exact-output buy's slice, clipped
    ///      against that lower gross-up, then pays more than the programme's room.
    function _buyParts(HookrTypes.RulesConfig memory c)
        private
        pure
        returns (uint256 lpReward, uint256 take, uint256 royaltyPips)
    {
        uint256 share = c.protocolShareBps;
        uint256 lpSlice = (uint256(c.lpBps) * share + 99) / 100;
        uint256 lpNet = uint256(c.lpBps) * 100 - lpSlice;
        royaltyPips = lpNet * c.royaltyBps / BPS;
        lpReward = lpNet - royaltyPips;
        take = lpSlice + royaltyPips + (uint256(c.burnBps) * share + 99) / 100;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev The Rules credit strictly less than amount * pips / denominator + 1 to the advisory, so choosing
    ///      pips <= (room - 1) * denominator / amount keeps every slice at most room - 1.
    function _pips(uint24 take, uint256 room, uint256 amount, uint256 denominator) private pure returns (uint24) {
        if (room < 2) return 0;
        uint256 limit = (room - 1) * denominator / amount;
        return limit < take ? uint24(limit) : take;
    }

    /// @dev Reads the programme with a fixed stipend. Too little gas to give the full stipend reverts, so a trader
    ///      cannot starve the read to skip the slice; any failure of the programme itself reads as zero room.
    function _room(address minter, address trader, bool authenticated)
        private
        view
        returns (address recipient, uint256 room)
    {
        uint256 stipend = MINTER_VIEW_GAS;
        if (gasleft() < stipend + stipend / 63 + CALL_RESERVE) revert InsufficientGas();
        bytes memory input = abi.encodeCall(IHookrSwapRewardMinter.quoteRoom, (trader, authenticated));
        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            let out := mload(0x40)
            ok := staticcall(stipend, minter, add(input, 32), mload(input), out, 64)
            ok := and(ok, eq(returndatasize(), 64))
            word := mload(out)
            room := mload(add(out, 32))
        }
        if (!ok || word == 0 || word > type(uint160).max) return (address(0), 0);
        recipient = address(uint160(word));
        if (room > type(uint128).max) room = type(uint128).max;
    }
}
