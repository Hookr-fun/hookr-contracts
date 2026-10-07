// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrLanes} from "hookr/interfaces/IHookrLanes.sol";
import {IHookrLaneRules} from "hookr/interfaces/IHookrLaneRules.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {HookrGoverned} from "hookr/base/HookrGoverned.sol";
import {IHookrPairAdvisory} from "hookr/interfaces/IHookrPairAdvisory.sol";
import {IHookrPairRoot} from "hookr/interfaces/IHookrPairRoot.sol";
import {HookrMarketBand} from "./HookrMarketBand.sol";
import {HookrRulesFees} from "./HookrRulesFees.sol";

/// @title Hookr market guard
/// @notice Advisory for HookrRoot pools and Hookr pair roots that keeps a pool's price inside a band around an
///         admitted external price feed. REFUSE mode is a circuit breaker: a swap that would leave the band is
///         refused, exactly, after the swap. SURCHARGE mode prices a surcharge before the swap from a simulated move
///         beyond the band. Both can guard the quote depth toward the band edge. On a recapture lane pool an arb
///         recapture leg is never surcharged and is refused, exactly, after its swap when it leaves the band, in either
///         mode. Pair roots bind SURCHARGE only: their advisory returns only a surcharge and has no after phase. See
///         HookrMarketBand for the checks.
/// @dev No quote take, no funds, no owner power over bound pools. The owner admits price feeds through the fixed
///      30-minute timelock and can retire one at once, which only stops new binds. A pool freezes its feed, the feed's
///      code hash, its scale and every knob at bind. Bindings are keyed by the calling root. A failed or stale feed
///      read reverts: a fail-closed pool refuses the swap, a fail-open pool is charged the admitted cap.
contract HookrMarketGuard is HookrGoverned, IHookrAdvisory, IHookrPairAdvisory {
    using PoolIdLibrary for PoolKey;

    /// @notice An admitted price feed.
    /// @param codeHash The feed's runtime code hash.
    /// @param decimals The feed's decimals.
    /// @param maxStaleness The largest staleness a pool may bind with for this feed, seconds.
    /// @param admitted Whether new pools may bind the feed.
    struct Feed {
        bytes32 codeHash;
        uint8 decimals;
        uint32 maxStaleness;
        bool admitted;
    }

    /// @notice A bound pool: its frozen band, the knobs it bound with and, for a recapture lane pool, the lane
    ///         executor the root froze for it. The swap path reads the executor only on a LANE band.
    struct Binding {
        HookrMarketBand.Band band;
        HookrMarketBand.Knobs knobs;
        address laneExecutor;
    }

    /// @custom:storage-location erc7201:hookr.market.guard
    struct State {
        mapping(address binder => mapping(PoolId => Binding)) bindings;
        mapping(address feed => Feed) feeds;
    }

    /// @dev cast index-erc7201 hookr.market.guard
    bytes32 private constant STATE_SLOT = 0x069f4a4a794d6e9d01049449be87b5141e043320d31cfd90e2773d0e79428200;
    /// @dev keccak256 of the bind data's type string.
    bytes32 private constant SCHEMA_HASH = keccak256(
        "MarketGuardConfig(address feed,MarketGuardKnobs knobs)MarketGuardKnobs(uint8 mode,uint8 flags,uint16 bandBps,uint16 rampBps,uint32 staleness,uint24 surchargePips,uint128 minDepth)"
    );
    /// @dev HookrRules.configSchemaHash(): keccak256 of RulesConfig's type string, the 16-word layout.
    bytes32 private constant RULES_SCHEMA = keccak256(
        "RulesConfig(uint40 guardEndBlock,uint24 maxFeePips,uint24 snipeTaxPips,uint24 snipeFloorPips,uint16 snipeDecaySeconds,uint16 dynamicFeeSens,uint16 burnBps,uint16 lpBps,uint16 potBps,uint16 royaltyBps,uint16 protocolShareBps,uint32 potEveryNBuys,uint128 maxBuyQuoteAmount,uint128 potMinBuyQuote,address royaltyTo,address integrator)"
    );
    uint256 private constant VIEW_GAS = 60_000;
    uint256 private constant RULES_CONFIG_BYTES = 16 * 32;
    /// @dev IHookrRecaptureRules.minimumFee(PoolId) selector, the Hookr minimum a pool froze at bind.
    uint32 private constant MINIMUM_FEE = 0x876e88e2;

    /// @notice The owner timelock, fixed for every Hookr 1 contract.
    uint48 public constant TIMELOCK = 30 minutes;
    /// @notice Kind for admitting a feed. Arguments: abi.encode(address feed, bytes32 codeHash, uint8 decimals,
    ///         uint32 maxStaleness).
    bytes32 public constant ADMIT_FEED = keccak256("ADMIT_FEED");
    /// @notice Smallest advisory gas limit a pool may bind with: the worst swap-path read (both walks out of steps,
    ///         cold) with margin. The root forwards the same limit to `bind`.
    uint32 public constant MIN_ADVISORY_GAS = 350_000;
    /// @notice Smallest gas limit a pair root may bind with: the worst swap-path read, cold, with the feed's full read
    ///         gas and both walks out of steps.
    uint32 public constant MIN_PAIR_GAS = 350_000;
    /// @notice Size of a pair root's bind data, abi.encode(address feed, Knobs knobs, bool quoteIs0).
    uint256 public constant PAIR_ENCODED_SIZE = 288;

    uint8 public constant REFUSE = HookrMarketBand.REFUSE;
    uint8 public constant SURCHARGE = HookrMarketBand.SURCHARGE;
    uint8 public constant INVERT = HookrMarketBand.INVERT;
    uint8 public constant MIN_MODE = HookrMarketBand.REFUSE;
    uint8 public constant MAX_MODE = HookrMarketBand.SURCHARGE;
    uint8 public constant DEFAULT_MODE = HookrMarketBand.DEFAULT_MODE;
    uint16 public constant MIN_BAND_BPS = HookrMarketBand.MIN_BAND_BPS;
    uint16 public constant MAX_BAND_BPS = HookrMarketBand.MAX_BAND_BPS;
    uint16 public constant DEFAULT_BAND_BPS = HookrMarketBand.DEFAULT_BAND_BPS;
    uint16 public constant MIN_RAMP_BPS = HookrMarketBand.MIN_RAMP_BPS;
    uint16 public constant MAX_RAMP_BPS = HookrMarketBand.MAX_RAMP_BPS;
    uint16 public constant DEFAULT_RAMP_BPS = HookrMarketBand.DEFAULT_RAMP_BPS;
    uint32 public constant MIN_STALENESS = HookrMarketBand.MIN_STALENESS;
    uint32 public constant MAX_STALENESS = HookrMarketBand.MAX_STALENESS;
    uint32 public constant DEFAULT_STALENESS = HookrMarketBand.DEFAULT_STALENESS;
    uint128 public constant MIN_MIN_DEPTH = HookrMarketBand.MIN_MIN_DEPTH;
    uint128 public constant MAX_MIN_DEPTH = HookrMarketBand.MAX_MIN_DEPTH;
    uint128 public constant DEFAULT_MIN_DEPTH = HookrMarketBand.DEFAULT_MIN_DEPTH;
    uint24 public constant MIN_SURCHARGE_PIPS = HookrMarketBand.MIN_SURCHARGE_PIPS;
    uint24 public constant MAX_SURCHARGE_PIPS = HookrMarketBand.MAX_SURCHARGE_PIPS;
    uint24 public constant DEFAULT_SURCHARGE_PIPS = HookrMarketBand.DEFAULT_SURCHARGE_PIPS;

    /// @notice The PoolManager every binding root must use.
    IPoolManager public immutable poolManager;

    event FeedAdmitted(address indexed feed, bytes32 codeHash, uint8 decimals, uint32 maxStaleness);
    event FeedRetired(address indexed feed);
    event GuardBound(
        address indexed binder, PoolId indexed id, address indexed feed, HookrMarketBand.Knobs knobs, int24 bandTicks
    );

    error AlreadyBound(address binder, PoolId id);
    error InvalidConfig(uint256 code);
    error FeedNotAdmitted(address feed);
    error FeedUnavailable(address binder, PoolId id);
    error UnknownPool(address binder, PoolId id);

    /// @param owner_ The feed admission owner.
    /// @param manager The chain's PoolManager.
    constructor(address owner_, IPoolManager manager) HookrGoverned(owner_, TIMELOCK) {
        if (address(manager).code.length == 0) revert NotAContract(address(manager));
        poolManager = manager;
    }

    /// @notice Admits `feed` for new binds; consumes a queued ADMIT_FEED with the exact arguments. A re-admission
    ///         replaces the record for new binds only.
    function admitFeed(address feed, bytes32 codeHash, uint8 decimals, uint32 maxStaleness) external onlyOwner {
        _checkFeed(feed, codeHash, decimals, maxStaleness);
        _consume(ADMIT_FEED, abi.encode(feed, codeHash, decimals, maxStaleness));
        _state().feeds[feed] = Feed(codeHash, decimals, maxStaleness, true);
        emit FeedAdmitted(feed, codeHash, decimals, maxStaleness);
    }

    /// @notice Brake: `feed` can no longer be bound, and every queued re-admission of it is void. Bound pools keep
    ///         their frozen copy.
    function retireFeed(address feed) external onlyOwner {
        _state().feeds[feed].admitted = false;
        _invalidateQueued(_feedKey(feed));
        emit FeedRetired(feed);
    }

    /// @notice The admission record of `feed`.
    function feedOf(address feed) external view returns (Feed memory) {
        return _state().feeds[feed];
    }

    /// @inheritdoc IHookrAdvisory
    function configSchemaHash() external pure returns (bytes32) {
        return SCHEMA_HASH;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev The caller must be the pool's root, on the guard's PoolManager, with this contract admitted as a fee-only
    ///      ADVISORY and bound with at least MIN_ADVISORY_GAS. The bind data is abi.encode(address feed, Knobs).
    ///      Codes: 1 data size, 2 caller or pool settings, including a fail-open recapture lane pool (a fail-open
    ///      guard that cannot answer lets an arb recapture leg through at the admitted ceiling, where refusing it
    ///      needs an answer), 3 admission, 4 PoolManager, 5 feed staleness above its admission, 6 feed code changed,
    ///      7 token decimals, 8 the feed does not answer now, 10+ knob code, 19 also for a recapture lane pool bound
    ///      without the after phase (a leg is checked exactly after its swap), 20 the band and ramp span more
    ///      tick-bitmap words than HookrMarketBand.MAX_SPAN_WORDS at the pool's tick spacing.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32 configHash)
    {
        if (data.length != HookrMarketBand.ENCODED_SIZE) revert InvalidConfig(1);
        (address feedAddress, HookrMarketBand.Knobs memory k) = abi.decode(data, (address, HookrMarketBand.Knobs));
        PoolId id = key.toId();
        Binding storage entry = _state().bindings[msg.sender][id];
        if (entry.band.bits & HookrMarketBand.BOUND != 0) revert AlreadyBound(msg.sender, id);
        if (address(key.hooks) != msg.sender || pc.advisory != address(this) || pc.advisoryGasLimit < MIN_ADVISORY_GAS)
        {
            revert InvalidConfig(2);
        }
        IHookrRegistry registry = IHookrRoot(msg.sender).registry();
        IHookrRegistry.Admission memory own = registry.admission(msg.sender, address(this));
        if (own.kind != IHookrRegistry.Kind.ADVISORY || own.implementation != address(this) || !own.feeOnly) {
            revert InvalidConfig(3);
        }
        if (address(IHookrRoot(msg.sender).poolManager()) != address(poolManager)) revert InvalidConfig(4);
        uint256 knobCode = HookrMarketBand.validate(k, pc.advisoryFailOpen, pc.advisoryPhases, own.caps.maxLpFeePips);
        if (knobCode != 0) revert InvalidConfig(10 + knobCode);

        HookrMarketBand.Band memory b =
            _band(feedAddress, k, pc.subject, pc.quote, pc.quote == key.currency0, key.tickSpacing);

        // The root froze the pool's lane just before this call: a pool whose Rules ask for recapture has one, and its
        // executor is the root's active lane executor (HookrLane._freeze reads both the same way).
        (bool read, bytes memory mode) = _view(pc.rules, abi.encodeCall(IHookrLaneRules.recaptureMode, (id)), 32);
        if (read && abi.decode(mode, (uint256)) != 0) {
            if (pc.advisoryFailOpen) revert InvalidConfig(2);
            if (pc.advisoryPhases & HookrTypes.AFTER_SWAP == 0) revert InvalidConfig(19);
            (address executor,,,) = IHookrLanes(address(registry)).activeLaneOf(msg.sender);
            b.bits |= HookrMarketBand.LANE;
            entry.laneExecutor = executor;
        }

        if (k.mode == HookrMarketBand.SURCHARGE) {
            IHookrRegistry.Admission memory rulesAdmission = registry.admission(msg.sender, pc.rules);
            uint256 cap = own.caps.maxLpFeePips;
            uint256 poolCap = pc.caps.maxLpFeePips;
            (uint256 after_, uint256 guard) = _rulesCeiling(b, pc, id, rulesAdmission.caps);
            b.limit = uint24(_min(k.surchargePips, _min(cap, poolCap - after_)));
            b.guardLimit = uint24(_min(k.surchargePips, _min(cap, poolCap - guard)));
        }
        entry.band = b;
        entry.knobs = k;
        emit GuardBound(msg.sender, id, feedAddress, k, int24(b.bandTicks));
        return keccak256(data);
    }

    /// @inheritdoc IHookrPairAdvisory
    /// @dev The caller must be a pair root on the guard's PoolManager that names this advisory, binding its own pool.
    ///      The data is abi.encode(address feed, Knobs knobs, bool quoteIs0), where quoteIs0 names the pool's quote;
    ///      the mode must be SURCHARGE and surchargePips at most `capPips`. Codes as `bind`, and 9 for REFUSE.
    function bindPair(PoolId id, uint24 capPips, uint32 gasLimit, bytes calldata data) external returns (bytes4) {
        if (data.length != PAIR_ENCODED_SIZE) revert InvalidConfig(1);
        (address feedAddress, HookrMarketBand.Knobs memory k, bool quoteIs0) =
            abi.decode(data, (address, HookrMarketBand.Knobs, bool));
        Binding storage entry = _state().bindings[msg.sender][id];
        if (entry.band.bits & HookrMarketBand.BOUND != 0) revert AlreadyBound(msg.sender, id);
        if (gasLimit < MIN_PAIR_GAS) revert InvalidConfig(2);
        IHookrPairRoot pair = IHookrPairRoot(msg.sender);
        if (address(pair.poolManager()) != address(poolManager)) revert InvalidConfig(4);
        IHookrPairRoot.Params memory p = pair.params();
        PoolKey memory pairKey = pair.poolKey();
        if (PoolId.unwrap(pairKey.toId()) != PoolId.unwrap(id) || p.advisory != address(this)) {
            revert InvalidConfig(2);
        }
        if (k.mode != HookrMarketBand.SURCHARGE) revert InvalidConfig(9);
        uint256 knobCode = HookrMarketBand.validate(k, p.advisoryFailOpen, HookrTypes.BEFORE_SWAP, capPips);
        if (knobCode != 0) revert InvalidConfig(10 + knobCode);
        (Currency subject, Currency quote) = quoteIs0 ? (p.currency1, p.currency0) : (p.currency0, p.currency1);
        HookrMarketBand.Band memory b = _band(feedAddress, k, subject, quote, quoteIs0, pairKey.tickSpacing);
        b.limit = k.surchargePips;
        b.guardLimit = k.surchargePips;
        entry.band = b;
        entry.knobs = k;
        emit GuardBound(msg.sender, id, feedAddress, k, int24(b.bandTicks));
        return IHookrPairAdvisory.bindPair.selector;
    }

    /// @inheritdoc IHookrPairAdvisory
    /// @dev Reverts for a pool the caller has not bound and when the feed read fails.
    function surchargeForSwap(
        PoolId id,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata,
        address
    ) external view returns (uint24) {
        (bool bound, bool ok,, uint256 surcharge) = _advise(
            msg.sender, id, address(0), zeroForOne, amountSpecified, sqrtPriceLimitX96
        );
        if (!bound) revert UnknownPool(msg.sender, id);
        if (!ok) revert FeedUnavailable(msg.sender, id);
        return uint24(surcharge);
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Liquidity is never restricted.
    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Zero advice for a pool the caller has not bound; the root only calls it for pools it bound. Reverts when
    ///      the feed read fails. On a recapture lane pool a swap by its lane executor is an arb recapture leg: it is
    ///      never surcharged and its depth is not walked, and it is refused here only from a price already beyond the
    ///      edge it moves toward; `afterSwap` refuses one that ends beyond that edge, so a leg cannot pay its way past
    ///      the band. The executor's own swaps outside an arb recapture are treated the same way.
    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory advice) {
        (bool bound, bool ok, bool reject, uint256 surcharge) =
            _advise(msg.sender, x.id, x.sender, x.zeroForOne, x.amountSpecified, x.sqrtPriceLimitX96);
        if (!bound) return advice;
        if (!ok) revert FeedUnavailable(msg.sender, x.id);
        advice.lpFeeSurchargePips = uint24(surcharge);
        advice.reject = reject;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev REFUSE, and an arb recapture leg in either mode: rejects when the swap left the price beyond the band edge
    ///      it moved toward. Any other SURCHARGE swap: zero advice.
    function afterSwap(HookrTypes.SwapContext calldata x, int128, int128)
        external
        view
        returns (HookrTypes.Advice memory advice)
    {
        Binding storage entry = _state().bindings[msg.sender][x.id];
        HookrMarketBand.Band memory b = entry.band;
        (bool ok, bool reject) = HookrMarketBand.afterSwap(b, poolManager, x.id, x.zeroForOne, _leg(entry, b, x.sender));
        if (!ok) revert FeedUnavailable(msg.sender, x.id);
        advice.reject = reject;
    }

    /// @notice The frozen band and knobs of the pool `id` bound by `binder`.
    function binding(address binder, PoolId id) external view returns (Binding memory) {
        return _state().bindings[binder][id];
    }

    /// @notice The pool's reference tick and band edges now; `ok` is false when the feed read fails.
    function bandOf(address binder, PoolId id) external view returns (bool ok, int24 ref, int24 lower, int24 upper) {
        HookrMarketBand.Band memory b = _state().bindings[binder][id].band;
        if (b.bits & HookrMarketBand.BOUND == 0) return (false, 0, 0, 0);
        (ok, ref) = HookrMarketBand.referenceTick(b);
        if (ok) (lower, upper) = HookrMarketBand.edges(ref, b.bandTicks);
    }

    /// @notice The before-swap advice the pool bound by `binder` would give now, without reverting.
    function preview(address binder, PoolId id, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        view
        returns (bool ok, bool reject, uint24 surchargePips)
    {
        bool bound;
        uint256 s;
        (bound, ok, reject, s) = _advise(binder, id, address(0), zeroForOne, amountSpecified, sqrtPriceLimitX96);
        surchargePips = uint24(s);
    }

    /// @dev ADMIT_FEED with canonical, valid arguments, and TRANSFER_OWNER; every other kind is refused.
    function _checkQueue(bytes32 kind, bytes calldata arguments) internal view override {
        if (kind == ADMIT_FEED) {
            (address feed, bytes32 codeHash, uint8 decimals, uint32 maxStaleness) =
                abi.decode(arguments, (address, bytes32, uint8, uint32));
            _requireCanonical(kind, arguments, abi.encode(feed, codeHash, decimals, maxStaleness));
            _checkFeed(feed, codeHash, decimals, maxStaleness);
        } else if (kind == TRANSFER_OWNER) {
            super._checkQueue(kind, arguments);
        } else {
            revert UnknownOperation(kind);
        }
    }

    /// @dev ADMIT_FEED is keyed by its feed, so retiring one feed voids only that feed's queued admissions.
    function _epochKey(bytes32 kind, bytes memory arguments) internal pure override returns (bytes32) {
        if (kind == ADMIT_FEED) {
            (address feed,,,) = abi.decode(arguments, (address, bytes32, uint8, uint32));
            return _feedKey(feed);
        }
        return kind;
    }

    function _feedKey(address feed) private pure returns (bytes32) {
        return keccak256(abi.encode(ADMIT_FEED, feed));
    }

    /// @dev The feed holds plain code with `codeHash`, reports `decimals` (at most MAX_DECIMALS), and `maxStaleness`
    ///      is within the staleness bounds.
    function _checkFeed(address feed, bytes32 codeHash, uint8 decimals, uint32 maxStaleness) private view {
        _requireDeployedCode(feed);
        if (feed.codehash != codeHash) revert InvalidConfig(6);
        if (decimals > HookrMarketBand.MAX_DECIMALS) revert InvalidConfig(7);
        if (maxStaleness < HookrMarketBand.MIN_STALENESS || maxStaleness > HookrMarketBand.MAX_STALENESS) {
            revert InvalidConfig(5);
        }
        (bool ok, bytes memory out) = _view(feed, abi.encodeWithSignature("decimals()"), 32);
        if (!ok || abi.decode(out, (uint256)) != decimals) revert InvalidConfig(7);
    }

    /// @dev Checks the feed's admission for the knobs and freezes the band; the feed must answer now, and the widest
    ///      walk over the pool's ticks must fit HookrMarketBand.MAX_SPAN_WORDS at its tick spacing.
    function _band(
        address feedAddress,
        HookrMarketBand.Knobs memory k,
        Currency subject,
        Currency quote,
        bool quoteIs0,
        int24 tickSpacing
    ) private view returns (HookrMarketBand.Band memory b) {
        Feed memory f = _state().feeds[feedAddress];
        if (!f.admitted) revert FeedNotAdmitted(feedAddress);
        if (k.staleness > f.maxStaleness) revert InvalidConfig(5);
        if (feedAddress.codehash != f.codeHash) revert InvalidConfig(6);
        b = HookrMarketBand.freeze(
            k, feedAddress, f.codeHash, f.decimals, _decimals(subject), _decimals(quote), quoteIs0
        );
        if (!HookrMarketBand.spanFits(b.bandTicks, b.rampTicks, tickSpacing)) revert InvalidConfig(20);
        b.tickSpacing = int16(tickSpacing);
        (bool ok,) = HookrMarketBand.referenceTick(b);
        if (!ok) revert InvalidConfig(8);
    }

    /// @dev Decimals of a pool currency: 18 for the native currency, else `decimals()`, at most MAX_DECIMALS.
    function _decimals(Currency c) private view returns (uint8) {
        if (c.isAddressZero()) return 18;
        (bool ok, bytes memory out) = _view(Currency.unwrap(c), abi.encodeWithSignature("decimals()"), 32);
        if (!ok) revert InvalidConfig(7);
        uint256 d = abi.decode(out, (uint256));
        if (d > HookrMarketBand.MAX_DECIMALS) revert InvalidConfig(7);
        return uint8(d);
    }

    /// @dev The largest native LP fee after and during the Rules guard (HookrRulesFees.maxLp), and into `b` the guard
    ///      end and the largest exact-output reserves the root adds to a buy (the subject burn) and to a sell (the
    ///      quote take), as HookrRules quotes them: the buy burn is `burnBps` less its protocol slice taken in pips and
    ///      rounded up (HookrRulesFees.buyParts), the sell take at most the protocol share of the dynamic fee's span
    ///      or the pool's frozen Hookr minimum, the larger (HookrRulesFees.maxSellTake; the Anti-Snipe tax is
    ///      buy-only, and the minimum's top-up is a quote take, never an LP fee or a burn). When the Rules does not
    ///      report the Hookr rules schema, `config` does not return exactly one configuration or its shares exceed the
    ///      whole, it uses the pool's caps and the Rules admission caps alone, which bound what the root accepts from
    ///      any Rules; a Rules that reports the schema but does not answer `minimumFee` bounds the sell take by the
    ///      caps alone.
    function _rulesCeiling(
        HookrMarketBand.Band memory b,
        HookrTypes.PoolConfig calldata pc,
        PoolId id,
        HookrTypes.Caps memory rulesCaps
    ) private view returns (uint256 after_, uint256 guard) {
        uint256 ceiling = _min(rulesCaps.maxLpFeePips, pc.caps.maxLpFeePips);
        after_ = ceiling;
        guard = ceiling;
        uint256 buy = _min(rulesCaps.maxSubjectTakeBps, pc.caps.maxSubjectTakeBps);
        uint256 sell = _min(rulesCaps.maxQuoteTakePips, pc.caps.maxQuoteTakePips);
        (bool ok, bytes memory out) = _view(pc.rules, abi.encodeWithSignature("configSchemaHash()"), 32);
        if (ok && abi.decode(out, (bytes32)) == RULES_SCHEMA) {
            (ok, out) = _view(pc.rules, abi.encodeWithSignature("config(bytes32)", id), RULES_CONFIG_BYTES);
        } else {
            ok = false;
        }
        if (ok) {
            // The eleven leading words, each checked against its RulesConfig type; the guard reads nothing after
            // protocolShareBps, and skips the four fields it never reads.
            HookrTypes.RulesConfig memory r;
            (r.guardEndBlock, r.maxFeePips, r.snipeTaxPips,,,, r.burnBps, r.lpBps,, r.royaltyBps, r.protocolShareBps) =
                abi.decode(
                    out, (uint40, uint24, uint24, uint256, uint256, uint256, uint16, uint16, uint256, uint16, uint16)
                );
            // A foreign Rules reporting the Hookr schema with a share above the whole is bound by the caps alone.
            if (HookrRulesFees.inRange(r)) {
                uint256 base = pc.baseLpFeePips;
                uint256 burn;
                (after_, guard, burn) = HookrRulesFees.maxLp(r, base);
                after_ = _min(ceiling, after_);
                guard = _min(ceiling, guard);
                b.guardEnd = uint32(_min(r.guardEndBlock, type(uint32).max));
                buy = _min(buy, burn);
                // The Hookr minimum the pool froze at bind: a sell pays at least it. A Rules reporting the
                // schema that does not answer `minimumFee` leaves the sell take to the caps.
                address rules = pc.rules;
                bool read;
                uint256 minimum;
                assembly ("memory-safe") {
                    mstore(0, shl(224, MINIMUM_FEE))
                    mstore(4, id)
                    // Two statements: Yul evaluates arguments right to left, so one `and` would read the size
                    // of the previous call's return data.
                    read := staticcall(VIEW_GAS, rules, 0, 36, 0, 32)
                    read := and(read, eq(returndatasize(), 32))
                    minimum := mload(0)
                }
                if (read) sell = _min(sell, HookrRulesFees.maxSellTake(r, base, minimum));
            }
        }
        b.buyReserveBps = uint16(buy);
        // Pips as bps, rounded up (HookrMarketBand.grossSpecified prices 10,000 or more at the full surcharge).
        b.sellReserveBps = uint16((sell + 99) / 100);
    }

    /// @dev The before-swap advice for the pool `id` bound by `binder`; `bound` is false for a pool it has not bound.
    ///      A swap by the LANE pool's executor (`sender`) is advised as an arb recapture leg.
    function _advise(
        address binder,
        PoolId id,
        address sender,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) private view returns (bool bound, bool ok, bool reject, uint256 surcharge) {
        Binding storage entry = _state().bindings[binder][id];
        HookrMarketBand.Band memory b = entry.band;
        if (b.bits & HookrMarketBand.BOUND == 0) return (false, false, false, 0);
        (ok, reject, surcharge) = HookrMarketBand.beforeSwap(
            b, poolManager, id, zeroForOne, amountSpecified, sqrtPriceLimitX96, _leg(entry, b, sender)
        );
        bound = true;
    }

    /// @dev Whether a swap by `sender` on the pool of `entry` is an arb recapture leg: a LANE band and its frozen
    ///      lane executor.
    function _leg(Binding storage entry, HookrMarketBand.Band memory b, address sender) private view returns (bool) {
        return b.bits & HookrMarketBand.LANE != 0 && sender == entry.laneExecutor;
    }

    /// @dev Bounded static call that must return exactly `size` bytes.
    function _view(address target, bytes memory input, uint256 size)
        private
        view
        returns (bool ok, bytes memory output)
    {
        output = new bytes(size);
        assembly ("memory-safe") {
            ok := staticcall(VIEW_GAS, target, add(input, 32), mload(input), add(output, 32), size)
            ok := and(ok, eq(returndatasize(), size))
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") {
            s.slot := STATE_SLOT
        }
    }
}
