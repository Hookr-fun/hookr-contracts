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
import {IHookrRulesConfig} from "hookr/interfaces/IHookrRulesConfig.sol";
import {IHookrProtocolClaims} from "hookr/interfaces/IHookrProtocolClaims.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {HookrTaxQueue} from "./HookrTaxQueue.sol";
import {HookrTaxQueueTypes} from "./types/HookrTaxQueueTypes.sol";
import {IHookrStraySweep} from "./interfaces/IHookrStraySweep.sol";
import {HookrAsset} from "./libraries/HookrAsset.sol";
import {IHookrFeeRouteRegistry} from "./interfaces/IHookrFeeRouteRegistry.sol";
import {IHookrFeeSwapExecutor} from "./interfaces/IHookrFeeSwapExecutor.sol";
import {HookrCloneArgs} from "./libraries/HookrCloneArgs.sol";
import {HookrSessionTiers} from "hookr/libraries/HookrSessionTiers.sol";

/// @title HookrDirectionalTax
/// @notice Hookr 1 advisory module, exclusive group DIRECTIONAL_QUOTE_TAX: independent buy and sell taxes, each at
///         most 10%, taken in the quote currency and credited to a per-direction claim queue that converts later.
/// @dev Enters Hookr 1 as an ADVISORY admission on a root (caps: LP fee = the session
///      surcharge ceiling, zero when no pool may carry session tiers; quote take 100,000 pips; subject take 0; strict,
///      not fail-open) and pools opt in through `HookrLauncher.launchAdvised`.
///
///      Per swap the module is read-only (the root STATICCALLs it) and returns one `Advice`:
///      - buys, exact input or exact output, at the before phase: `quoteTakePips = buyTaxPips`, recipient the buy
///        queue. The root reserves the take on the specified quote for exact-input buys and charges it on the
///        unspecified quote for exact-output buys, as pips of the gross buyer spend.
///      - exact-input sells, at the after phase: `quoteTakePips = sellTaxPips`, recipient the sell queue, charged as
///        pips of the quote leaving the pool.
///      - exact-output sells, at the before phase: `quoteTakePips = sellTaxPips`, recipient the sell queue. The root
///        reserves ceil(Q * rate / (PIPS - rate)) extra quote on the specified output, so the seller still nets Q
///        and the tax is the same pips of the gross quote leaving the pool as on an exact-input sell.
///      The root credits the take to the queue as a HookrRules claim inside the swap. The queue is never called
///      during a swap, so no conversion route, authorizer, signer or recipient can fail a trade.
///
///      Optional tax decay: a pool may also append a `Schedule`. A decaying direction starts at `startPips` at the
///      bind block and falls to the leg's `taxPips` over `blocks` blocks of `block.number` (the clock HookrRules'
///      Anti-Snipe guard counts), along a quadratic or a linear curve. Bounds, caps and queues use the start, the
///      direction's largest tax. A direction may decay to zero.
///
///      Creator knobs, all frozen at bind and bounded here (`MIN_*`/`MAX_*`, with `DEFAULT_*` suggestions for launch
///      forms): each direction's tax, route, recipients and stale-recovery wait; the optional decay; the optional
///      session tiers.
///
///      Optional session tiers (off-market fees): a pool may append `HookrSessionTiers.Tiers` to its config. Its
///      before-phase advice then also carries an LP-fee surcharge that follows the US equity session, read from the
///      shared calendar `calendar` (a HookrSessionAdvisory fixed at construction) and clamped to the admission's LP
///      cap, which the root reserves out of the Rules' LP room at bind. A failed or malformed calendar read charges
///      the pool's highest tier and never reverts the swap. Pools without tiers pay nothing extra beyond one branch.
///
///      `bind` runs once per pool under the root's CALL and is the only state change. It admits only a registered
///      root binding its own pool, checks that the pool's frozen caps leave room for the tax on top of the worst-case
///      Rules take, the pool's Hookr minimum included (so the tax can never trip the root's aggregate cap), reads the
///      pool's frozen Rules protocol share and recipient, and deploys the two queues as ERC-1167 clones whose code
///      carries their frozen terms. A pool with arb recapture on binds like any other: the root asks this module about
///      every executor leg on it, in each phase it is bound for, and the leg pays the same tax into the same queue as
///      an outside swap of that shape.
contract HookrDirectionalTax is HookrReleased, IHookrAdvisory, IHookrStraySweep {
    using PoolIdLibrary for PoolKey;

    /// @notice Smallest per-direction tax, in pips (1e6 = 100%). Zero disables a direction unless it decays.
    uint24 public constant MIN_TAX_PIPS = 0;
    /// @notice Per-direction ceiling: 100,000 pips = 10%.
    uint24 public constant MAX_TAX_PIPS = 100_000;
    /// @notice Suggested per-direction tax for launch forms: 30,000 pips = 3%. `bind` does not use it.
    uint24 public constant DEFAULT_TAX_PIPS = 30_000;
    /// @notice Shortest tax decay, in blocks. Zero blocks means no decay.
    uint32 public constant MIN_DECAY_BLOCKS = 1;
    /// @notice Longest tax decay, in blocks: the same 100,000-block horizon as HookrRules' Anti-Snipe guard.
    uint32 public constant MAX_DECAY_BLOCKS = 100_000;
    /// @notice Suggested decay length for launch forms: 300 blocks of `block.number`, about an hour where that clock
    ///         is a 12-second parent chain. `bind` does not use it.
    uint32 public constant DEFAULT_DECAY_BLOCKS = 300;
    /// @notice Suggested decay start for launch forms: the ceiling. The start must be above the leg's tax.
    uint24 public constant DEFAULT_DECAY_START_PIPS = MAX_TAX_PIPS;
    /// @notice Decay curve: `end + (start - end) * (blocks - elapsed)^2 / blocks^2`, front-loaded. The default.
    uint8 public constant CURVE_QUADRATIC = 0;
    /// @notice Decay curve: `end + (start - end) * (blocks - elapsed) / blocks`.
    uint8 public constant CURVE_LINEAR = 1;
    /// @notice Suggested decay curve for launch forms.
    uint8 public constant DEFAULT_DECAY_CURVE = CURVE_QUADRATIC;
    /// @notice Shortest wait a routed leg may set before an unconverted creator share can be recovered as quote.
    uint32 public constant MIN_STALE_RECOVERY_DELAY = 1 days;
    /// @notice Longest such wait.
    uint32 public constant MAX_STALE_RECOVERY_DELAY = 90 days;
    /// @notice Suggested wait for launch forms. `bind` does not use it; a routed leg states its own.
    uint32 public constant DEFAULT_STALE_RECOVERY_DELAY = 30 days;
    /// @notice Protocol share ceiling, the same 50% HookrRules enforces.
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 5_000;
    uint256 private constant BPS = 10_000;
    /// @notice The exclusive group of this module for a registry that tracks groups. Phase one enforces exclusivity
    ///         structurally: a pool carries at most one advisory.
    bytes32 public constant EXCLUSIVE_GROUP = keccak256("DIRECTIONAL_QUOTE_TAX");
    /// @notice The only Rules schema whose fee ceilings this module knows how to bound: the keccak256 of RulesConfig's
    ///         type string, HookrRules.configSchemaHash() for the 16-word layout (`integrator` last).
    bytes32 public constant RULES_SCHEMA = keccak256(
        "RulesConfig(uint40 guardEndBlock,uint24 maxFeePips,uint24 snipeTaxPips,uint24 snipeFloorPips,uint16 snipeDecaySeconds,uint16 dynamicFeeSens,uint16 burnBps,uint16 lpBps,uint16 potBps,uint16 royaltyBps,uint16 protocolShareBps,uint32 potEveryNBuys,uint128 maxBuyQuoteAmount,uint128 potMinBuyQuote,address royaltyTo,address integrator)"
    );
    bytes32 private constant SCHEMA_HASH = keccak256(
        "HookrDirectionalTax.Config(Leg buy,Leg sell)Leg(uint24 taxPips,bytes32 routeId,address assetRecipient,address recoveryRecipient,uint32 staleRecoveryDelay);optional HookrSessionTiers.Tiers(uint24 regularPips,uint24 preMarketPips,uint24 afterHoursPips,uint24 overnightPips,uint24 closedPips,uint16 openRampSeconds,uint16 closeRampSeconds,uint8 flags);optional HookrDirectionalTax.Schedule(Decay buy,Decay sell)Decay(uint24 startPips,uint32 blocks,uint8 curve)"
    );
    uint256 private constant CONFIG_BYTES = 320;
    uint256 private constant TIERED_CONFIG_BYTES = CONFIG_BYTES + HookrSessionTiers.ENCODED_SIZE;
    uint256 private constant SCHEDULE_BYTES = 192;
    uint256 private constant DECAYING_CONFIG_BYTES = CONFIG_BYTES + SCHEDULE_BYTES;
    uint256 private constant TIERED_DECAYING_CONFIG_BYTES = TIERED_CONFIG_BYTES + SCHEDULE_BYTES;
    /// @dev keccak256(abi.encode(uint256(keccak256("hookr.directional-tax")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SLOT = 0x7dadc15f283a75d24c70b5db89b6d4ae2e90625de723ce1d273d30252cc46c00;

    /// @notice The registry whose roots may bind this module.
    IHookrRegistry public immutable registry;
    /// @notice The route registry conversion legs must name an active route in, and the only caller of `sweepStray`.
    IHookrFeeRouteRegistry public immutable routeRegistry;
    /// @notice The queue implementation every clone delegates to.
    address public immutable queueImplementation;
    /// @notice Floor on the pool's Rules protocol share, which is also the tax's protocol share. Fixed at deployment
    ///         and therefore pinned by the admission code hash.
    uint16 public immutable minProtocolShareBps;
    /// @notice The shared session calendar (a HookrSessionAdvisory) session tiers read, or zero when this deployment
    ///         offers no session tiers.
    address public immutable calendar;

    /// @notice One direction of a pool's tax.
    /// @param taxPips Tax in pips (1e6 = 100%), at most `MAX_TAX_PIPS`; with a decay, the tax it ends at. A direction
    ///        with no tax and no decay is disabled, and every other field must then be zero.
    /// @param routeId Conversion route for the creator share, or zero to pay it out as quote to `assetRecipient`.
    /// @param assetRecipient Receives the creator share, converted or as quote. Required when `taxPips` is set.
    /// @param recoveryRecipient Receives the creator share as quote if the route is retired, or if the booked share
    ///        waits `staleRecoveryDelay` with no successful conversion. Required with a route, zero without one.
    /// @param staleRecoveryDelay Seconds a booked creator share may wait with no successful conversion before anyone
    ///        can pay it as quote to `recoveryRecipient`; each conversion restarts the wait. With a route it is
    ///        `MIN_STALE_RECOVERY_DELAY` to `MAX_STALE_RECOVERY_DELAY` (launch forms suggest
    ///        `DEFAULT_STALE_RECOVERY_DELAY`); without one it must be zero.
    struct Leg {
        uint24 taxPips;
        bytes32 routeId;
        address assetRecipient;
        address recoveryRecipient;
        uint32 staleRecoveryDelay;
    }

    /// @notice The advisory bytes a pool binds, canonical ABI encoding only:
    ///         - `abi.encode(Config)`, 320 bytes;
    ///         - `abi.encode(Config, Schedule)`, 512 bytes, with a tax decay;
    ///         - `abi.encode(Config, HookrSessionTiers.Tiers)`, 576 bytes, with session tiers;
    ///         - `abi.encode(Config, HookrSessionTiers.Tiers, Schedule)`, 768 bytes, with both.
    ///         All-zero tiers equal no tiers. A schedule, when present, must decay at least one direction.
    struct Config {
        Leg buy;
        Leg sell;
    }

    /// @notice One direction's optional tax decay. All zero means no decay.
    /// @param startPips Tax at the bind block, above the leg's `taxPips` and at most `MAX_TAX_PIPS`.
    /// @param blocks Blocks from the bind block until the tax reaches the leg's `taxPips`, 1 to `MAX_DECAY_BLOCKS`.
    /// @param curve `CURVE_QUADRATIC` or `CURVE_LINEAR`; zero when `blocks` is zero.
    struct Decay {
        uint24 startPips;
        uint32 blocks;
        uint8 curve;
    }

    /// @notice A pool's optional tax decay, one per direction.
    struct Schedule {
        Decay buy;
        Decay sell;
    }

    /// @notice A decaying pool's frozen schedule as the swap path reads it, packed into one storage slot.
    /// @param startBlock The bind block, where every decay starts.
    struct DecayTerms {
        uint24 buyStartPips;
        uint32 buyBlocks;
        uint8 buyCurve;
        uint24 sellStartPips;
        uint32 sellBlocks;
        uint8 sellCurve;
        uint40 startBlock;
    }

    /// @notice A bound pool's terms as the swap path reads them.
    /// @param buyTaxPips The buy tax, or with a buy decay the tax the decay ends at; `taxAt` gives the current one.
    /// @param tiered Whether the pool carries session tiers, stored separately in `sessionTiers`.
    /// @param decaying Whether the pool carries a tax decay, stored separately in `decayTerms`.
    /// @param sellTaxPips The sell tax, or with a sell decay the tax the decay ends at.
    struct Terms {
        address buyQueue;
        uint24 buyTaxPips;
        bool bound;
        bool tiered;
        bool decaying;
        address sellQueue;
        uint24 sellTaxPips;
    }

    /// @notice A tiered pool's frozen session surcharge. Two storage slots: the tiers, then the limit.
    /// @param tiers The pool's tiers, each at most `limit`.
    /// @param limit The admission's LP-fee cap at bind, the ceiling on every surcharge this pool is advised.
    struct Session {
        HookrSessionTiers.Tiers tiers;
        uint24 limit;
    }

    /// @custom:storage-location erc7201:hookr.directional-tax
    struct State {
        mapping(address root => mapping(PoolId => Terms)) terms;
        mapping(address queue => bool) queues;
        mapping(address root => mapping(PoolId => Session)) sessions;
        mapping(address root => mapping(PoolId => DecayTerms)) decays;
    }

    error Unauthorized();
    error AlreadyBound(address root, PoolId id);
    error UnknownPool(address root, PoolId id);
    error InvalidConfig(uint8 reason);
    error InvalidPoolConfig(uint8 reason);
    error CapsTooLow(bool isBuy, uint256 required, uint256 cap);
    error ProtocolShareOutOfRange(uint16 shareBps);
    error RouteUnavailable(bytes32 routeId);
    error InvalidWiring();
    error SessionTiersUnavailable();

    /// @notice Emitted once per pool when its tax terms and queues are frozen.
    event DirectionalTaxBound(
        address indexed root,
        PoolId indexed id,
        uint24 buyTaxPips,
        address buyQueue,
        uint24 sellTaxPips,
        address sellQueue,
        uint16 protocolShareBps,
        address protocolRecipient
    );

    /// @notice Emitted once per decaying pool when its schedule is frozen.
    event TaxDecayBound(address indexed root, PoolId indexed id, Schedule schedule, uint40 startBlock);

    /// @notice Emitted once per tiered pool when its session tiers are frozen.
    event SessionTiersBound(address indexed root, PoolId indexed id, HookrSessionTiers.Tiers tiers, uint24 limit);

    /// @param registry_ The Hookr registry whose registered roots may bind.
    /// @param executor_ The signed-plan executor queues convert through; its route registry is read here.
    /// @param minProtocolShareBps_ Floor on the pool's Rules protocol share, at most 50%.
    /// @param calendar_ The shared session calendar (a HookrSessionAdvisory) for session tiers, or zero to refuse
    ///        tiered pools.
    constructor(
        IHookrRegistry registry_,
        IHookrFeeSwapExecutor executor_,
        uint16 minProtocolShareBps_,
        address calendar_
    ) {
        if (
            address(registry_).code.length == 0 || address(executor_).code.length == 0
                || minProtocolShareBps_ > MAX_PROTOCOL_SHARE_BPS
                || (calendar_ != address(0) && calendar_.code.length == 0)
        ) revert InvalidWiring();
        calendar = calendar_;
        registry = registry_;
        routeRegistry = executor_.routeRegistry();
        if (address(routeRegistry).code.length == 0) revert InvalidWiring();
        minProtocolShareBps = minProtocolShareBps_;
        queueImplementation = address(new HookrTaxQueue(executor_));
    }

    /// @inheritdoc IHookrAdvisory
    function configSchemaHash() external pure returns (bytes32) {
        return SCHEMA_HASH;
    }

    /// @notice Returns the frozen terms of `root`'s pool `id`. Unbound pools return zero fields.
    function terms(address root, PoolId id) external view returns (Terms memory) {
        return _state().terms[root][id];
    }

    /// @notice Returns the frozen session tiers of `root`'s pool `id`. Untiered and unbound pools return zero fields.
    function sessionTiers(address root, PoolId id) external view returns (Session memory) {
        return _state().sessions[root][id];
    }

    /// @notice Returns the session surcharge `root`'s pool `id` would be advised at `timestamp`, or zero for an
    ///         untiered or unbound pool.
    function sessionSurchargeAt(address root, PoolId id, uint256 timestamp) external view returns (uint24) {
        State storage s = _state();
        if (!s.terms[root][id].tiered) return 0;
        return _sessionSurcharge(s.sessions[root][id], timestamp);
    }

    /// @notice Returns the frozen tax decay of `root`'s pool `id`. Pools without a decay return zero fields.
    function decayTerms(address root, PoolId id) external view returns (DecayTerms memory) {
        return _state().decays[root][id];
    }

    /// @notice Returns the tax, in pips, `root`'s pool `id` charges in one direction at `blockNumber`, or zero for an
    ///         unbound pool. Blocks before the bind block read as the bind block.
    function taxAt(address root, PoolId id, bool isBuy, uint256 blockNumber) external view returns (uint24) {
        State storage s = _state();
        Terms memory t = s.terms[root][id];
        uint24 endPips = isBuy ? t.buyTaxPips : t.sellTaxPips;
        if (!t.decaying) return endPips;
        return _decayed(s.decays[root][id], isBuy, endPips, blockNumber);
    }

    /// @inheritdoc IHookrStraySweep
    /// @dev The module never holds tax: the root credits it to the queues as Rules claims. Every balance here is a
    ///      stray, and sweeping it touches no pool state.
    function sweepStray(address asset, uint256 amount, address to) external {
        if (msg.sender != address(routeRegistry)) revert StraySweepUnauthorized(msg.sender);
        uint256 held = HookrAsset.balanceOf(asset, address(this));
        if (amount == 0 || to == address(0) || amount > held) revert InvalidStraySweep(asset, amount, held);
        HookrAsset.send(asset, to, amount);
        emit StraySwept(asset, to, amount);
    }

    /// @notice Returns whether `queue` is a queue this module deployed at a pool binding.
    function isQueue(address queue) external view returns (bool) {
        return _state().queues[queue];
    }

    /// @notice Predicts a queue's address from its terms; usable before the pool exists.
    function predictQueue(HookrTaxQueueTypes.Terms memory queueTerms) public view returns (address) {
        return HookrCloneArgs.predict(queueImplementation, abi.encode(queueTerms), _salt(queueTerms), address(this));
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Only a registered root binding its own pool during `initializePool` may call. Reverting here reverts the
    ///      pool's creation, never a swap.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32 configHash)
    {
        PoolId id = key.toId();
        if (
            !registry.isRoot(msg.sender) || address(key.hooks) != msg.sender
                || PoolId.unwrap(IHookrRoot(msg.sender).bindingPool()) != PoolId.unwrap(id)
        ) revert Unauthorized();
        State storage s = _state();
        if (s.terms[msg.sender][id].bound) revert AlreadyBound(msg.sender, id);
        (Config memory c, HookrSessionTiers.Tiers memory tiers, Schedule memory schedule) = _decode(data);
        (uint24 buyPeak, uint24 sellPeak) = (_peak(c.buy, schedule.buy), _peak(c.sell, schedule.sell));
        uint24 lpCap = _checkPool(pc, buyPeak, sellPeak);
        (uint16 share, address protocolRecipient) = _checkRules(id, pc, buyPeak, sellPeak);
        Terms memory t;
        t.bound = true;
        if (schedule.buy.blocks != 0 || schedule.sell.blocks != 0) {
            t.decaying = true;
            s.decays[msg.sender][id] = DecayTerms({
                buyStartPips: schedule.buy.startPips,
                buyBlocks: schedule.buy.blocks,
                buyCurve: schedule.buy.curve,
                sellStartPips: schedule.sell.startPips,
                sellBlocks: schedule.sell.blocks,
                sellCurve: schedule.sell.curve,
                startBlock: uint40(block.number)
            });
            emit TaxDecayBound(msg.sender, id, schedule, uint40(block.number));
        }
        if (!HookrSessionTiers.isEmpty(tiers)) {
            if (calendar == address(0)) revert SessionTiersUnavailable();
            HookrSessionTiers.check(tiers, lpCap);
            t.tiered = true;
            s.sessions[msg.sender][id] = Session(tiers, lpCap);
            emit SessionTiersBound(msg.sender, id, tiers, lpCap);
        }
        t.buyTaxPips = c.buy.taxPips;
        t.sellTaxPips = c.sell.taxPips;
        if (buyPeak != 0) t.buyQueue = _deploy(s, id, pc, true, c.buy, share, protocolRecipient);
        if (sellPeak != 0) t.sellQueue = _deploy(s, id, pc, false, c.sell, share, protocolRecipient);
        s.terms[msg.sender][id] = t;
        emit DirectionalTaxBound(
            msg.sender, id, t.buyTaxPips, t.buyQueue, t.sellTaxPips, t.sellQueue, share, protocolRecipient
        );
        return keccak256(data);
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev The tax never gates liquidity.
    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev A tiered pool also gets its session surcharge; the calendar read cannot revert the swap. A decaying
    ///      pool reads its schedule's one storage slot; other pools pay one branch.
    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory advice) {
        Terms memory t = _bound(x.id);
        // Buys, and exact-output sells (the root reserves the take on the specified quote out). Exact-input sells
        // take at the after phase.
        if (x.isBuy || !x.exactInput) {
            uint24 pips = _pipsNow(t, x.id, x.isBuy);
            if (pips != 0) {
                advice.quoteTakePips = pips;
                advice.recipient = x.isBuy ? t.buyQueue : t.sellQueue;
            }
        }
        if (t.tiered) {
            advice.lpFeeSurchargePips = _sessionSurcharge(_state().sessions[msg.sender][x.id], block.timestamp);
        }
    }

    /// @inheritdoc IHookrAdvisory
    function afterSwap(HookrTypes.SwapContext calldata x, int128, int128)
        external
        view
        returns (HookrTypes.Advice memory advice)
    {
        Terms memory t = _bound(x.id);
        if (!x.isBuy && x.exactInput) {
            uint24 pips = _pipsNow(t, x.id, false);
            if (pips != 0) {
                advice.quoteTakePips = pips;
                advice.recipient = t.sellQueue;
            }
        }
    }

    /// @notice Upper bounds of the admitted HookrRules quote take, in pips, for buys and for exact-input sells, on a
    ///         pool whose frozen Hookr minimum is `minFeePips` (`IHookrRecaptureRules.minimumFee`, zero for none).
    /// @dev Mirrors `HookrRules._quote` and `_validate` for schema `RULES_SCHEMA`: a buy takes the LP-reward
    ///      protocol share, royalty and burn slice plus the protocol share of the dynamic fee and Snipe, whose sum is
    ///      clipped to the LP-fee room; an exact-input sell takes the protocol share of the dynamic fee only. Rounding
    ///      is bounded from above; the LP Rewards and Auto Burn shares are in pips, rounded up, as the Rules take them.
    ///      The Hookr minimum replaces a smaller rule share (the royalty is not Hookr's): a buy takes at most
    ///      royalty + max(rule share, minimum) and a sell max(dynamic fee share, minimum), so each ceiling is the larger
    ///      of the rule-fee ceiling and its minimum take, the same `max` the Rules' own cap bound uses.
    function rulesQuoteCeilings(HookrTypes.RulesConfig memory c, uint256 base, uint256 minFeePips)
        public
        pure
        returns (uint256 buyMax, uint256 sellMax)
    {
        uint256 share = c.protocolShareBps;
        // LP Rewards and Auto Burn as `HookrRules._buyParts` takes them: the protocol's share of each slice in pips,
        // rounded up, then the royalty on what LP Rewards keep.
        uint256 lpSlice = (uint256(c.lpBps) * share + 99) / 100;
        uint256 lpNet = uint256(c.lpBps) * 100 - lpSlice;
        uint256 royaltyPips = lpNet * c.royaltyBps / BPS;
        uint256 burnSlice = (uint256(c.burnBps) * share + 99) / 100;
        uint256 lpReward = lpNet - royaltyPips;
        uint256 take = lpSlice + royaltyPips + burnSlice;
        uint256 span = c.maxFeePips > base ? c.maxFeePips - base : 0;
        uint256 room = base + lpReward >= 600_000 ? 0 : 600_000 - base - lpReward;
        uint256 variable = span + c.snipeTaxPips;
        if (variable > room) variable = room;
        buyMax = take + variable * share / BPS;
        sellMax = span * share / BPS;
        if (royaltyPips + minFeePips > buyMax) buyMax = royaltyPips + minFeePips;
        if (minFeePips > sellMax) sellMax = minFeePips;
    }

    /// @dev Session surcharge at `timestamp`: the package's `valueAt` on the shared calendar (the tier value, or the
    ///      highest tier when the read fails or is malformed), clamped to the pool's frozen limit.
    function _sessionSurcharge(Session storage stored, uint256 timestamp) private view returns (uint24) {
        Session memory p = stored;
        uint256 pips = HookrSessionTiers.valueAt(p.tiers, calendar, timestamp);
        return uint24(pips < p.limit ? pips : p.limit);
    }

    /// @dev Pool-shape checks: this module, strict, exactly the phases the legs need. Each direction is bounded by
    ///      its peak, the start of its decay or its flat tax. Returns the admission's LP-fee cap, the ceiling for
    ///      session tiers.
    function _checkPool(HookrTypes.PoolConfig calldata pc, uint24 buyPeak, uint24 sellPeak)
        private
        view
        returns (uint24)
    {
        if (pc.advisory != address(this)) revert InvalidPoolConfig(1);
        if (pc.advisoryFailOpen) revert InvalidPoolConfig(2);
        // Buys and exact-output sells take at the before phase; exact-input sells take at the after phase.
        uint8 phases = HookrTypes.BEFORE_SWAP | (sellPeak != 0 ? HookrTypes.AFTER_SWAP : 0);
        if (pc.advisoryPhases != phases) revert InvalidPoolConfig(3);
        IHookrRegistry.Admission memory a = registry.admission(msg.sender, address(this));
        uint256 maxTax = buyPeak > sellPeak ? buyPeak : sellPeak;
        if (a.caps.maxQuoteTakePips < maxTax) {
            revert CapsTooLow(buyPeak >= sellPeak, maxTax, a.caps.maxQuoteTakePips);
        }
        return a.caps.maxLpFeePips;
    }

    /// @dev Reads the pool's frozen Rules terms, its Hookr minimum included, checks the aggregate quote cap
    ///      leaves room for the tax in each taxed direction and returns the protocol share and recipient the queues
    ///      freeze. Every exact-output sell's Rules take (max of the clipped dynamic-fee span times the share and the
    ///      minimum) is within the exact-input sell ceiling, so one bound covers both sell shapes.
    function _checkRules(PoolId id, HookrTypes.PoolConfig calldata pc, uint24 buyPeak, uint24 sellPeak)
        private
        view
        returns (uint16 share, address protocolRecipient)
    {
        if (IHookrRules(pc.rules).configSchemaHash() != RULES_SCHEMA) revert InvalidPoolConfig(4);
        HookrTypes.RulesConfig memory rc = IHookrRulesConfig(pc.rules).config(id);
        (uint256 buyMax, uint256 sellMax) =
            rulesQuoteCeilings(rc, pc.baseLpFeePips, IHookrRecaptureRules(pc.rules).minimumFee(id));
        uint256 cap = pc.caps.maxQuoteTakePips;
        if (buyPeak != 0 && buyMax + buyPeak > cap) revert CapsTooLow(true, buyMax + buyPeak, cap);
        if (sellPeak != 0 && sellMax + sellPeak > cap) revert CapsTooLow(false, sellMax + sellPeak, cap);
        share = rc.protocolShareBps;
        if (share < minProtocolShareBps || share > MAX_PROTOCOL_SHARE_BPS) revert ProtocolShareOutOfRange(share);
        protocolRecipient = IHookrProtocolClaims(pc.rules).protocolRecipient();
        if (protocolRecipient == address(0)) revert InvalidPoolConfig(5);
    }

    function _deploy(
        State storage s,
        PoolId id,
        HookrTypes.PoolConfig calldata pc,
        bool isBuy,
        Leg memory leg,
        uint16 share,
        address protocolRecipient
    ) private returns (address queue) {
        if (
            leg.routeId != bytes32(0)
                && !routeRegistry.isActive(leg.routeId, Currency.unwrap(pc.quote), _tokenOut(leg.routeId))
        ) {
            revert RouteUnavailable(leg.routeId);
        }
        HookrTaxQueueTypes.Terms memory qt = HookrTaxQueueTypes.Terms({
            root: msg.sender,
            rules: pc.rules,
            poolId: id,
            quote: pc.quote,
            isBuy: isBuy,
            protocolRecipient: protocolRecipient,
            protocolShareBps: share,
            routeId: leg.routeId,
            assetRecipient: leg.assetRecipient,
            recoveryRecipient: leg.recoveryRecipient,
            staleRecoveryDelay: leg.staleRecoveryDelay
        });
        queue = HookrCloneArgs.deploy(queueImplementation, abi.encode(qt), _salt(qt));
        s.queues[queue] = true;
    }

    function _tokenOut(bytes32 routeId) private view returns (address) {
        return routeRegistry.route(routeId).tokenOut;
    }

    function _salt(HookrTaxQueueTypes.Terms memory qt) private pure returns (bytes32) {
        return keccak256(abi.encode(qt.root, qt.poolId, qt.isBuy));
    }

    /// @dev Canonical decode: exact length, exact re-encoding, and per-leg shape rules. Tiers whose pips are all zero
    ///      must be all zero; a schedule must decay at least one direction.
    function _decode(bytes calldata data)
        private
        pure
        returns (Config memory c, HookrSessionTiers.Tiers memory tiers, Schedule memory schedule)
    {
        uint256 length = data.length;
        bool tiered = length == TIERED_CONFIG_BYTES || length == TIERED_DECAYING_CONFIG_BYTES;
        bool decaying = length == DECAYING_CONFIG_BYTES || length == TIERED_DECAYING_CONFIG_BYTES;
        bytes memory canonical;
        if (length == CONFIG_BYTES) {
            c = abi.decode(data, (Config));
            canonical = abi.encode(c);
        } else if (length == DECAYING_CONFIG_BYTES) {
            (c, schedule) = abi.decode(data, (Config, Schedule));
            canonical = abi.encode(c, schedule);
        } else if (length == TIERED_CONFIG_BYTES) {
            (c, tiers) = abi.decode(data, (Config, HookrSessionTiers.Tiers));
            canonical = abi.encode(c, tiers);
        } else if (length == TIERED_DECAYING_CONFIG_BYTES) {
            (c, tiers, schedule) = abi.decode(data, (Config, HookrSessionTiers.Tiers, Schedule));
            canonical = abi.encode(c, tiers, schedule);
        } else {
            revert InvalidConfig(1);
        }
        if (keccak256(data) != keccak256(canonical)) revert InvalidConfig(1);
        if (
            tiered && HookrSessionTiers.isEmpty(tiers)
                && (tiers.openRampSeconds != 0 || tiers.closeRampSeconds != 0 || tiers.flags != 0)
        ) revert InvalidConfig(7);
        _checkLeg(c.buy, schedule.buy);
        _checkLeg(c.sell, schedule.sell);
        if (decaying && schedule.buy.blocks == 0 && schedule.sell.blocks == 0) revert InvalidConfig(8);
        if (_peak(c.buy, schedule.buy) == 0 && _peak(c.sell, schedule.sell) == 0) revert InvalidConfig(2);
    }

    /// @dev A direction's decay rules first, then its leg rules against its peak tax. A disabled direction is all
    ///      zero (reason 3). A live one has a tax of at most `MAX_TAX_PIPS` (4) and an asset recipient (5). A routed
    ///      leg has a recovery recipient (6) and a stale-recovery wait within bounds (13); a direct leg has neither.
    function _checkLeg(Leg memory leg, Decay memory decay) private pure {
        _checkDecay(leg.taxPips, decay);
        if (_peak(leg, decay) == 0) {
            if (
                leg.routeId != bytes32(0) || leg.assetRecipient != address(0) || leg.recoveryRecipient != address(0)
                    || leg.staleRecoveryDelay != 0
            ) {
                revert InvalidConfig(3);
            }
            return;
        }
        if (leg.taxPips > MAX_TAX_PIPS) revert InvalidConfig(4);
        if (leg.assetRecipient == address(0)) revert InvalidConfig(5);
        if ((leg.routeId == bytes32(0)) != (leg.recoveryRecipient == address(0))) revert InvalidConfig(6);
        if (leg.routeId == bytes32(0)
                ? leg.staleRecoveryDelay != 0
                : leg.staleRecoveryDelay < MIN_STALE_RECOVERY_DELAY || leg.staleRecoveryDelay > MAX_STALE_RECOVERY_DELAY)
        {
            revert InvalidConfig(13);
        }
    }

    /// @dev No decay is all zero (reason 9). A decay runs 1 to `MAX_DECAY_BLOCKS` blocks (10), starts above the tax
    ///      it ends at and at most `MAX_TAX_PIPS` (11), on a known curve (12).
    function _checkDecay(uint24 endPips, Decay memory decay) private pure {
        if (decay.blocks == 0) {
            if (decay.startPips != 0 || decay.curve != 0) revert InvalidConfig(9);
            return;
        }
        if (decay.blocks > MAX_DECAY_BLOCKS) revert InvalidConfig(10);
        if (decay.startPips <= endPips || decay.startPips > MAX_TAX_PIPS) revert InvalidConfig(11);
        if (decay.curve > CURVE_LINEAR) revert InvalidConfig(12);
    }

    /// @dev A direction's largest tax: the start of its decay, or its flat tax.
    function _peak(Leg memory leg, Decay memory decay) private pure returns (uint24) {
        return decay.blocks != 0 ? decay.startPips : leg.taxPips;
    }

    /// @dev The calling root's tax in one direction at this block.
    function _pipsNow(Terms memory t, PoolId id, bool isBuy) private view returns (uint24) {
        uint24 endPips = isBuy ? t.buyTaxPips : t.sellTaxPips;
        if (!t.decaying) return endPips;
        return _decayed(_state().decays[msg.sender][id], isBuy, endPips, block.number);
    }

    /// @dev One direction's tax at `blockNumber` on a decaying pool. A direction without a decay, and every block from
    ///      `startBlock + blocks` on, pays `endPips`. Never above the start, never below the end, never rising.
    function _decayed(DecayTerms storage stored, bool isBuy, uint24 endPips, uint256 blockNumber)
        private
        view
        returns (uint24)
    {
        DecayTerms memory d = stored;
        (uint256 start, uint256 blocks, uint8 curve) =
            isBuy ? (d.buyStartPips, d.buyBlocks, d.buyCurve) : (d.sellStartPips, d.sellBlocks, d.sellCurve);
        uint256 elapsed = blockNumber > d.startBlock ? blockNumber - d.startBlock : 0;
        if (elapsed >= blocks) return endPips;
        uint256 left = blocks - elapsed;
        uint256 span = start - endPips;
        uint256 pips = curve == CURVE_LINEAR ? span * left / blocks : span * left * left / (blocks * blocks);
        return uint24(endPips + pips);
    }

    function _bound(PoolId id) private view returns (Terms memory t) {
        t = _state().terms[msg.sender][id];
        if (!t.bound) revert UnknownPool(msg.sender, id);
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") {
            s.slot := SLOT
        }
    }
}
