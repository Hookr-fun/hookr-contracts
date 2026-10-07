// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {CurrencyReserves} from "@uniswap/v4-core/src/libraries/CurrencyReserves.sol";
import {NonzeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonzeroDeltaCount.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrRules} from "../interfaces/IHookrRules.sol";
import {IHookrAdvisory} from "../interfaces/IHookrAdvisory.sol";
import {IHookrFeeOnlyRules} from "../interfaces/IHookrFeeOnlyRules.sol";
import {IHookrDynamicFeeRules} from "../interfaces/IHookrDynamicFeeRules.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrLanes} from "../interfaces/IHookrLanes.sol";
import {IHookrLaneRules} from "../interfaces/IHookrLaneRules.sol";
import {IHookrLaneExecutor} from "../interfaces/callback/IHookrLaneExecutor.sol";
import {HookrRootStorage} from "../libraries/HookrRootStorage.sol";
import {HookrDelegation} from "../libraries/HookrDelegation.sol";
import {IHookrRootEvents} from "../interfaces/IHookrRootEvents.sol";
import {IHookrLaneEvents} from "../interfaces/IHookrLaneEvents.sol";

/// @title HookrLane
/// @notice HookrRoot's cold paths, as a module the root deploys from its own constructor and reaches only by
///         DELEGATECALL of its own calldata (plus one trailing op word on hook callbacks), so it runs in the root's
///         context (storage, transient storage, address, events) while its code stays out of the root's runtime:
///         `initializePool`, and the recapture lane (the executor's legs, the arb recapture frames, the sink, the King
///         of the Pool liquidity ledger and the lane views). A swap on a pool without a lane never reaches it.
/// @dev The lane of a pool:
///      - Frozen at initialization when the pool's Rules report recapture: the registry's open lane of the root
///        (executor, runtime codehash, partner share) and the family the launcher reports for the pool, scoped to that
///        launcher. No arb recapture runs in the transaction that initialized the pool.
///      - On each swap the root reads the executor's live switch from the registry once. While it is off, or the
///        executor's code differs from the frozen codehash, the swap runs without the lane. While it is on, the root
///        runs an arb recapture frame before the swap is quoted and after it settles, each with exactly the switch's
///        gas cap. The before-phase requires the whole entry floor (`entryFloorOf`: its whole grant, LANE_BODY for its
///        split and the swap's own work until the after-phase, and the after-phase's floor), and each lane call its own
///        floor; below either, or with a PoolManager sync pending, the swap reverts, so no caller can make an arb
///        recapture skip. Because the before-phase may spend its whole grant whatever the state or the executor, a gas
///        limit `eth_estimateGas` finds also funds the swap when mined, as long as the swap's own work between the lane
///        calls stays within LANE_BODY. A failed frame is recorded (`CorrectionFailed`) and unwound, and the swap
///        completes.
///      - Every lane swap runs both arb recaptures, so a route through several lane pools of this root pays every one.
///        The first lane swap of a route records the gas it reached its check with; a later one requires its own
///        entry floor plus the route's earlier entry floors, less what was spent since that first check
///        (`_laneGas`). The check is therefore that the first lane swap reached the lane with the sum of the route's
///        entry floors, which no arb recapture can change, so the estimate of such a route funds the mined route as it
///        does one lane swap, as long as each earlier lane swap and the route's work up to the next one spend at most
///        their entry floors. A later lane swap never gets less than its own floor. A lane swap starts a new route
///        when it is the first swap of its PoolManager unlock (no open delta), when its payer (the authenticated
///        payer, else the swap's sender) differs from the route's, or when it reaches the check with more gas than
///        the route's last lane swap did, which within one call tree only a separately capped call gets: so
///        independent operations in one transaction (the user operations of an ERC-4337 bundle, a batcher's calls)
///        never share a check unless they have one payer and the later one's lane swap follows open deltas of its
///        own unlock with no more gas than the earlier one's (a known limit).
///      - The before-phase credits no trader: the executor gets zero as its rebate recipient and Rules get no trader.
///        The after-phase names the swap's authenticated payer, or zero, and credits it only with what its own swap
///        accounts for: its quote through the pool times its own price move (`_moveBasis`), and only when the
///        frame's legs on the pool ran against its swap. Rules pay the trader leg on min(push, basis).
///      - Inside a frame only the frozen executor swaps, before, between or after its pushes. Its legs on the pool
///        under arb recapture, and on the pool's lane siblings (same family, same frozen executor), pay that pool's
///        base LP fee, run no rule and go one direction per pool per frame; a buy leg on a pool still in its launch
///        guard instead runs the full path and pays what a trader pays (Snipe, the per-block cap and every other rule).
///        A leg on a pool with an advisory is asked and charged by it as an unauthenticated swap of the executor: both
///        phases, its surcharge as LP fee, its take in the pool's quote credited to its recipient, and its refusal. It
///        runs no rule. A leg on a pool with Hookr dynamic fees is charged no dynamic fee but carries the pool's
///        dynamic fee state (reference, anchor and windows) as an ordinary swap from the same start price to the same
///        end with the same quote would, so the next trader is priced from where the leg left the price. Its swap on
///        any other pool of the root is an ordinary swap with that pool's full rules and no lane.
///      - The frame snapshots the PoolManager's nonzero-delta count, synced currency and the root's and executor's
///        deltas in both currencies of the pool, and the root's ERC-6909 claims in every currency a push may use (the
///        pool's two and the registry's settlement set). After the executor returns it requires the deltas unchanged,
///        the root's and executor's deltas in every sibling quote it touched to be zero, and every claim balance back
///        at its snapshot once the pushes move to the Rules (so a claim minted and not pushed, a stray mint, reverts
///        the frame). The executor may push in several of the accepted currencies, each as often as it likes; each
///        currency's push is split on its own. The profit a push stands for is taken from the push itself at the
///        pool's frozen partner share (push x 10,000 / (10,000 - partnerBps)): the executor keeps its share and
///        pushes the rest; the value its call returns is not read. `partnerBps()` is never read.
///      - An LP share the Rules hold as a pending donation is released gradually and donated outside any frame:
///        before every liquidity add and removal lands and at the start of every outer swap (`_flush`), so a position
///        earns it in proportion to the L2 blocks it stayed in range (HookrRecapture).
contract HookrLane is IHookrRootEvents, IHookrLaneEvents {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    bytes32 private constant LANE_FRAME = HookrRootStorage.LANE_FRAME;
    bytes32 private constant LANE_EXECUTOR = HookrRootStorage.LANE_EXECUTOR;
    /// @dev Per frame (nonce) and currency: what the executor pushed in it so far.
    bytes32 private constant LANE_PUSHED = keccak256("hookr.root.transient.lane.pushed");
    /// @dev Per frame (nonce) and currency: the root's claim balance at the frame's open plus one, zero for a currency
    ///      the frame does not accept.
    bytes32 private constant LANE_BASE = keccak256("hookr.root.transient.lane.base");
    /// @dev Per frame (nonce): the number of currencies the frame accepts, then each of them.
    bytes32 private constant LANE_ACCEPTED = keccak256("hookr.root.transient.lane.accepted");
    bytes32 private constant LANE_DIR = keccak256("hookr.root.transient.lane.direction");
    bytes32 private constant LANE_NONCE = keccak256("hookr.root.transient.lane.nonce");
    bytes32 private constant LANE_FAMILY = HookrRootStorage.LANE_FAMILY;
    bytes32 private constant LANE_SIBLINGS = keccak256("hookr.root.transient.lane.siblings");
    bytes32 private constant LANE_CAP = keccak256("hookr.root.transient.lane.cap");
    bytes32 private constant LANE_CREATED = keccak256("hookr.root.transient.lane.created");
    /// @dev The gas the route's first lane swap on this root reached its entry check with, and the sum of the entry
    ///      floors of its lane swaps so far.
    bytes32 private constant LANE_FIRST = keccak256("hookr.root.transient.lane.first");
    bytes32 private constant LANE_SUM = keccak256("hookr.root.transient.lane.sum");
    /// @dev The gas the route's last lane swap reached its entry check with, and the route's payer.
    bytes32 private constant LANE_LAST = keccak256("hookr.root.transient.lane.last");
    bytes32 private constant LANE_PAYER = keccak256("hookr.root.transient.lane.payer");
    bytes32 private constant LEDGER = keccak256("hookr.root.transient.ledger");
    bytes32 private constant LEDGER_LIST = keccak256("hookr.root.transient.ledger.list");
    bytes32 private constant LEDGER_TICK = keccak256("hookr.root.transient.ledger.tick");
    uint256 private constant BPS = 10_000;
    /// @dev Gas the root keeps after a lane grant for what follows the frame, and gas spent between the floor check
    ///      and the self-call.
    uint256 private constant LANE_RESERVE = 150_000;
    uint256 private constant LANE_MARGIN = 5_000;
    /// @dev The swap's own work between the two lane calls that the before-phase check funds on top of both phases:
    ///      the before-phase's split, the Rules quote, a dynamic fee simulation, the advisory, the PoolManager swap,
    ///      the Rules settlement and both frames' claim snapshots (`_snapshot`, at most ten currencies each). With it,
    ///      the gas a swap needs when it reaches the lane does not depend on how much of its grant the before-phase
    ///      spends.
    uint256 private constant LANE_BODY = 600_000;
    /// @dev The most gas a pending LP donation's flush gets: a Rules call, a PoolManager donate and two claim burns.
    uint256 private constant FLUSH_GAS = 300_000;
    /// @dev Gas the frame keeps back for its own post-call checks.
    uint256 private constant FRAME_RESERVE = 60_000;
    /// @dev Gas each push currency after the first needs once the frame returns: its claims move to the Rules and the
    ///      Rules split it (`_run`). The root's reserve covers the first; a frame that pushed in k currencies returns
    ///      only with at least (k - 1) x this left of the executor's grant, and reverts otherwise, so the split of
    ///      every push is always funded and a short frame fails open instead of failing the swap.
    uint256 private constant EXTRA_PUSH_GAS = 200_000;
    uint256 private constant JIT_TOLERANCE_BPS = 10;
    uint256 private constant MAX_TRACKED_POSITIONS = 8;
    /// @dev Distinct lane siblings one frame may leg on: a family has at most eight members.
    uint256 private constant MAX_SIBLINGS = 7;
    uint256 private constant PIPS = 1_000_000;
    /// @dev Longest principal lock a Rules module can impose, in blocks after initialization.
    uint256 private constant MAX_LOCK_BLOCKS = 100_000;
    uint256 private constant OP_RUN = HookrRootStorage.OP_RUN;
    uint256 private constant OP_MARK = HookrRootStorage.OP_MARK;
    uint256 private constant OP_ENTER = HookrRootStorage.OP_ENTER;
    /// @dev `SwapSimulated(uint160,int24,uint160,int24)`, the root's simulation outcome (HookrRoot's fallback).
    bytes4 private constant SWAP_SIMULATED = 0xf630b40b;
    uint8 private constant PHASE_BEFORE = 1;
    uint8 private constant PHASE_AFTER = 2;
    IPoolManager public immutable poolManager;
    IHookrRegistry public immutable registry;
    address private immutable self;

    constructor(IPoolManager _manager, IHookrRegistry _registry) {
        poolManager = _manager;
        registry = _registry;
        self = address(this);
    }

    /// @dev Every entry runs only as the root's DELEGATECALL, never on the module's own address.
    modifier delegated() {
        if (address(this) == self) revert Unauthorized();
        _;
    }

    /// @notice The root's beforeSwap forwarded. OP_ENTER: a swap inside another swap (see `_enter`); returns the leg's
    ///         LP fee with the override flag, or zero for a swap that takes the full path. Otherwise OP_RUN (the
    ///         before-phase arb recapture of an outer swap) and/or OP_MARK (the ledger's start tick); returns the live
    ///         gas cap when the after-phase must run, else zero.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        external
        delegated
        returns (uint256 word)
    {
        uint256 op = _op();
        if (op & OP_ENTER != 0) return _enter(key, sender, params, data.length, op >> 8);
        PoolId id = key.toId();
        HookrRootStorage.Record storage r = HookrRootStorage.state().pools[id];
        if (op & OP_RUN != 0) word = _before(key, id, r, op >> 8);
        if (op & OP_MARK != 0) _markTick(id);
    }

    /// @notice The root's afterSwap forwarded when the before-phase found the lane live: the after-phase arb recapture,
    ///         the trader above bit 8, with the gas cap the before-phase read. The trader's basis is what its own swap
    ///         can account for: its quote through the pool times its own price move (see `_moveBasis`).
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        delegated
    {
        PoolId id = key.toId();
        uint256 word = HookrRootStorage.tget(LANE_CAP);
        HookrRootStorage.tput(LANE_CAP, 0);
        HookrRootStorage.Record storage r = HookrRootStorage.state().pools[id];
        address trader = address(uint160(_op() >> 8));
        uint256 basis;
        if (trader != address(0)) {
            (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(poolManager, id);
            int256 q = r.quoteIsCurrency0 ? delta.amount0() : delta.amount1();
            basis = _moveBasis(uint256(q < 0 ? -q : q), word >> 32, sqrtPrice);
        }
        _run(key, id, r, trader, PHASE_AFTER, uint32(word), basis, params.zeroForOne);
    }

    /// @notice The root's add callback forwarded on a lane pool: the released part of a pending LP share is donated
    ///         before the new liquidity lands (`_flush`), then the King of the Pool ledger records the add.
    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata p, bytes calldata)
        external
        delegated
    {
        _liquidity(sender, key, p);
    }

    /// @notice The root's removal callback forwarded on a lane pool, as the add's.
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata p,
        bytes calldata
    ) external delegated {
        _liquidity(sender, key, p);
    }

    function _liquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata p) private {
        PoolId id = key.toId();
        HookrRootStorage.Record storage r = HookrRootStorage.state().pools[id];
        _flush(key, r);
        if (r.mode & HookrRootStorage.MODE_LEDGER != 0) _ledger(id, sender, p);
    }

    function _op() private pure returns (uint256 op) {
        assembly ("memory-safe") {
            op := calldataload(sub(calldatasize(), 32))
        }
    }

    /// @dev A swap inside another swap. Only the executor of an open frame gets here, before, between or after its
    ///      pushes, and only one level deep. A leg on the pool under arb recapture or on one of its lane siblings goes
    ///      one direction per pool per frame and returns that pool's base LP fee, except a buy leg on a pool in its
    ///      launch guard, which returns zero so the root runs the full path. A leg on a pool with an advisory returns
    ///      that fee with bit 24 set: the root asks the advisory and charges what it asks, as for an unauthenticated
    ///      swap of the executor, and runs no rule. A leg on a dynamic fee pool records its start price (LEG_START),
    ///      and an unadvised one adds LEG_DYNAMIC to ACTIVE, so the root's afterSwap has `updateLegDynamicFee` carry
    ///      the pool's dynamic fee state for it (an advised one's afterSwap reads the pool's mode). A swap on any other
    ///      pool returns zero: an ordinary swap.
    function _enter(
        PoolKey calldata key,
        address sender,
        SwapParams calldata params,
        uint256 dataLength,
        uint256 active
    ) private returns (uint256) {
        bool zeroForOne = params.zeroForOne;
        uint256 frame = HookrRootStorage.tget(LANE_FRAME);
        if (
            HookrRootStorage.tget(HookrRootStorage.BINDING) != 0 || frame == 0
                || sender != address(uint160(HookrRootStorage.tget(LANE_EXECUTOR))) || active != 1
        ) revert ReentrantCallback();
        PoolId id = key.toId();
        HookrRootStorage.Record storage r = HookrRootStorage.state().pools[id];
        bool sibling = frame != uint256(PoolId.unwrap(id));
        if (sibling) {
            bytes32 family = bytes32(HookrRootStorage.tget(LANE_FAMILY));
            if (
                family == bytes32(0) || r.mode & HookrRootStorage.MODE_LANE == 0 || r.laneFamily != family
                    || r.laneExecutor != sender
            ) return 0;
        }
        if (dataLength != 0) revert InvalidHookData();
        uint256 nonce = HookrRootStorage.tget(LANE_NONCE);
        uint256 direction = zeroForOne ? 1 : 2;
        bytes32 dirSlot = _slot(LANE_DIR, id);
        uint256 seen = HookrRootStorage.tget(dirSlot);
        if (seen >> 2 != nonce) {
            // The first leg on this pool in this frame.
            HookrRootStorage.tput(dirSlot, (nonce << 2) | direction);
            if (sibling) _addSibling(r.quote);
        } else if (seen & 3 != direction) {
            revert LegDirection();
        }
        // Read beside quoteIsCurrency0, in the same slot.
        uint256 mode = r.mode;
        // During the launch guard a buy leg pays what a trader pays: Snipe, the per-block cap and every other rule. A
        // pool with arb recapture binds no Hookr minimum (HookrRules.bind), so neither a leg nor a trader pays one.
        if (zeroForOne == r.quoteIsCurrency0 && block.number < r.lockedUntil) return 0;
        if (mode & HookrRootStorage.MODE_DYNAMIC_FEE != 0) {
            // A leg on a dynamic fee pool carries the pool's dynamic fee state as an ordinary swap from the same start
            // would (`updateLegDynamicFee`, from the root's afterSwap): its start is recorded here, before the swap.
            (uint160 sqrtPrice, int24 tick,,) = StateLibrary.getSlot0(poolManager, id);
            HookrRootStorage.tput(HookrRootStorage.LEG_START, uint256(sqrtPrice) | (uint256(uint24(tick)) << 160));
            if (r.advisoryPhases != 0) return uint256(r.baseLpFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG) | (1 << 24);
            HookrRootStorage.tput(
                HookrRootStorage.ACTIVE, active + (HookrRootStorage.LEG | HookrRootStorage.LEG_DYNAMIC)
            );
            return uint256(r.baseLpFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }
        // An advised pool's leg: the root asks its advisory as for an unauthenticated swap of the executor and charges
        // what it asks (bit 24). The root sets ACTIVE for it.
        if (r.advisoryPhases != 0) return uint256(r.baseLpFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG) | (1 << 24);
        HookrRootStorage.tput(HookrRootStorage.ACTIVE, active + HookrRootStorage.LEG);
        return uint256(r.baseLpFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice An executor leg on a dynamic fee pool, after its swap: the root's afterSwap arguments under this selector
    ///         (HookrRoot's `_carryLeg`), with the leg's LP fee appended (zero: the pool's base fee). The Rules carry the
    ///         pool's dynamic fee state as for an ordinary swap simulated from the leg's start (`_enter` recorded it)
    ///         to its end and settled with the quote through the pool in the leg's swap delta
    ///         (IHookrLaneRules.carryLeg). The leg's charge does not change. The simulated end is where the leg
    ///         stopped or, for a leg that stopped at its price limit in an empty range (the case a simulation swaps
    ///         back for), the last price with liquidity: the root's own simulation of a 1-wei swap back toward the
    ///         start at the leg's LP fee, reverted. Fail-open, so a leg never fails for it: a probe or a Rules call
    ///         that fails leaves the state as it was. Only inside the PoolManager's afterSwap call to the root: the
    ///         root's fallback forwards this selector here for any other caller, and it is refused.
    function updateLegDynamicFee() external delegated {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        // The root's afterSwap calldata, read in place (it shares no decoder with afterSwap): the sender at 4, the
        // PoolKey at 36 (five words), the SwapParams at 196 (three words) and the BalanceDelta at 292; the leg's LP
        // fee is the appended last word. Every value the assembly below reads or writes is a full word.
        uint256 lpFee = _op();
        uint256 who;
        PoolId id;
        uint256 up;
        uint256 limit;
        int256 amount0;
        int256 amount1;
        assembly ("memory-safe") {
            who := and(calldataload(4), 0xffffffffffffffffffffffffffffffffffffffff)
            let p := mload(0x40)
            calldatacopy(p, 36, 160)
            id := keccak256(p, 160)
            up := iszero(calldataload(196))
            limit := and(calldataload(260), 0xffffffffffffffffffffffffffffffffffffffff)
            let delta := calldataload(292)
            amount0 := sar(128, delta)
            amount1 := signextend(15, delta)
        }
        HookrRootStorage.Record storage r = HookrRootStorage.state().pools[id];
        // The start price with the start tick above bit 160.
        uint256 start = HookrRootStorage.tget(HookrRootStorage.LEG_START);
        IPoolManager pm = poolManager;
        (uint160 sqrtPrice, int24 tick,,) = StateLibrary.getSlot0(pm, id);
        uint256 end = sqrtPrice;
        int256 endTick = tick;
        if (end == limit && end != uint160(start) && StateLibrary.getLiquidity(pm, id) == 0) {
            if (lpFee == 0) lpFee = r.baseLpFeePips;
            bool found;
            assembly ("memory-safe") {
                // abi.encode(key, SwapParams(!zeroForOne, -1, start price), uint24(lpFee)): the root's simulation input.
                let p := mload(0x40)
                calldatacopy(p, 36, 160)
                mstore(add(p, 160), up)
                mstore(add(p, 192), not(0))
                mstore(add(p, 224), and(start, 0xffffffffffffffffffffffffffffffffffffffff))
                mstore(add(p, 256), and(lpFee, 0xffffff))
                // It always reverts; only its SwapSimulated outcome carries the last price with liquidity.
                if iszero(call(gas(), address(), 0, p, 288, 0, 0)) {
                    if eq(returndatasize(), 132) {
                        returndatacopy(p, 0, 132)
                        if eq(shr(224, mload(p)), shr(224, SWAP_SIMULATED)) {
                            found := 1
                            end := mload(add(p, 68))
                            endTick := signextend(2, mload(add(p, 100)))
                        }
                    }
                }
            }
            if (!found) return;
        }
        address rules = r.rules;
        uint256 gasLimit = r.rulesGasLimit;
        uint256 baseFee = r.baseLpFeePips;
        uint256 quote0 = r.quoteIsCurrency0 ? 1 : 0;
        int256 q = quote0 == 1 ? amount0 : amount1;
        uint256 quoteAmount = uint256(q < 0 ? -q : q);
        bytes4 selector = IHookrLaneRules.carryLeg.selector;
        assembly ("memory-safe") {
            // abi.encodeCall(IHookrLaneRules.carryLeg, (context, simulation, quoteAmount)): the leg as an
            // unauthenticated swap of its sender (sender, payer and beneficiary), its start and end, and its quote.
            let p := mload(0x40)
            mstore(p, and(selector, shl(224, 0xffffffff)))
            mstore(add(p, 4), id)
            mstore(add(p, 36), who)
            mstore(add(p, 68), who)
            mstore(add(p, 100), who)
            let c0 := calldataload(36)
            let c1 := calldataload(68)
            mstore(add(p, 132), xor(c0, mul(quote0, xor(c0, c1)))) // subject: currency1 when the quote is currency0
            mstore(add(p, 164), xor(c1, mul(quote0, xor(c0, c1)))) // quote
            mstore(add(p, 196), 0) // authenticated
            mstore(add(p, 228), eq(iszero(up), quote0)) // isBuy: zeroForOne == quoteIsCurrency0
            let amountSpecified := calldataload(228)
            mstore(add(p, 260), slt(amountSpecified, 0)) // exactInput
            mstore(add(p, 292), iszero(up)) // zeroForOne
            mstore(add(p, 324), amountSpecified)
            mstore(add(p, 356), limit)
            mstore(add(p, 388), baseFee)
            mstore(add(p, 420), and(start, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(p, 452), signextend(2, shr(160, start)))
            mstore(add(p, 484), end)
            mstore(add(p, 516), endTick)
            mstore(add(p, 548), quoteAmount)
            // Fail-open: a Rules refusal leaves the state as it was, and the leg goes on.
            pop(call(gasLimit, rules, 0, p, 580, 0, 0))
        }
    }

    /// @dev Records a sibling quote the frame's end checks. The subject is a currency of the pool under arb recapture.
    function _addSibling(Currency quote) private {
        uint256 n = HookrRootStorage.tget(LANE_SIBLINGS) + 1;
        if (n > MAX_SIBLINGS) revert LegFamilyFull();
        HookrRootStorage.tput(LANE_SIBLINGS, n);
        HookrRootStorage.tput(bytes32(uint256(LANE_SIBLINGS) + n), uint256(uint160(Currency.unwrap(quote))));
    }

    /// @dev What a trader's own swap can account for in an arb recapture's push: its quote through the pool times its
    ///      own relative price move, `q × (max(p1 / p0, p0 / p1) − 1)` with p = sqrtPrice², an upper bound on the
    ///      profit of undoing the move against the price it started from. A move beyond 4× counts as 4×. Zero without a
    ///      recorded start price.
    function _moveBasis(uint256 q, uint256 sqrtBefore, uint256 sqrtAfter) private pure returns (uint256) {
        if (sqrtBefore == 0 || sqrtAfter == 0) return 0;
        (uint256 lo, uint256 hi) = sqrtBefore < sqrtAfter ? (sqrtBefore, sqrtAfter) : (sqrtAfter, sqrtBefore);
        if (hi - lo > lo) hi = 2 * lo;
        return FullMath.mulDiv(FullMath.mulDiv(q, hi - lo, lo), hi + lo, lo);
    }

    /// @dev The before-phase of an outer swap on a lane pool: reads the executor's live switch once and, while it is
    ///      on and the executor's code is the frozen one, requires the swap to carry what both lane calls and the work
    ///      between them need (`entryFloorOf`), plus what the transaction's earlier lane swaps on this root could still
    ///      spend (`_laneGas`), runs the arb recapture with no trader, and returns the gas cap for the after-phase,
    ///      which it keeps with the price the trader's swap starts from. Zero: no lane on this swap. Never in the
    ///      transaction that initialized the pool.
    function _before(PoolKey calldata key, PoolId id, HookrRootStorage.Record storage r, uint256 payer)
        private
        returns (uint256 cap)
    {
        if (HookrRootStorage.tget(_slot(LANE_CREATED, id)) != 0) return 0;
        address executor = r.laneExecutor;
        (bool on, uint32 gasCap) = IHookrLanes(address(registry)).executorLane(address(this), executor);
        if (!on || gasCap == 0) {
            _flush(key, r);
            return 0;
        }
        if (executor.codehash != r.laneCodeHash) {
            emit LaneCodeChanged(id, PHASE_BEFORE);
            _flush(key, r);
            return 0;
        }
        cap = gasCap;
        // The before-phase may spend its whole grant whatever the state or the executor, so the after-phase floor is
        // funded here, where a gas limit that passes when estimated also passes when mined. A due donation is part of
        // the swap's own work (LANE_BODY), after the check, so the check does not depend on it.
        _laneGas(entryFloorOf(cap), payer);
        _flush(key, r);
        _run(key, id, r, address(0), PHASE_BEFORE, cap, 0, false);
        (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(poolManager, id);
        HookrRootStorage.tput(LANE_CAP, cap | (uint256(sqrtPrice) << 32));
    }

    /// @dev The entry check of one lane swap whose own entry floor is `floor`, for `payer`. The first lane swap of a
    ///      route needs `floor` and records the gas it has. A later one needs `floor` plus the route's earlier floors
    ///      less what was spent since the first check, as the gas it has left shows, and never less than `floor`: it
    ///      passes whenever the first lane swap had the sum of the floors and what was spent in between stays within
    ///      the earlier floors, whatever the earlier arb recaptures spent. A lane swap starts a new route when the
    ///      PoolManager holds no open delta (the first swap of an unlock), when its payer is not the route's, or when
    ///      it reaches this check with more gas than the route's last lane swap did, which within one call tree only a
    ///      separately capped call gets.
    function _laneGas(uint256 floor, uint256 payer) private {
        uint256 available = gasleft();
        uint256 first = HookrRootStorage.tget(LANE_FIRST);
        uint256 sum;
        if (first != 0) {
            if (
                available > HookrRootStorage.tget(LANE_LAST) || HookrRootStorage.tget(LANE_PAYER) != payer
                    || uint256(poolManager.exttload(NonzeroDeltaCount.NONZERO_DELTA_COUNT_SLOT)) == 0
            ) first = 0;
            else sum = HookrRootStorage.tget(LANE_SUM);
        }
        HookrRootStorage.tput(LANE_LAST, available);
        uint256 required = floor;
        if (first == 0) {
            HookrRootStorage.tput(LANE_FIRST, available);
            HookrRootStorage.tput(LANE_PAYER, payer);
        } else if (sum + available > first) {
            required += sum + available - first;
        }
        if (available < required) revert InsufficientLaneGas(available, required);
        HookrRootStorage.tput(LANE_SUM, sum + floor);
    }

    /// @dev Asks the Rules to release and donate the pool's pending LP share (IHookrLaneRules.flushRecapture):
    ///      whenever the Rules may hold one (`laneDue`, set by a push and by a flush that left a share pending), and on
    ///      every call on a King of the Pool pool, whose pot releases can come from any swap or `settleEpoch`. The lane
    ///      reads no clock: the Rules release by Robinhood Chain's own block number, and a second flush in one of its
    ///      blocks releases nothing. Outside any frame: before every liquidity add and removal lands and at the start
    ///      of every outer swap, before its arb recapture.
    ///      Every call requires the flush's whole FLUSH_GAS, due or not, so no caller can starve it and a gas limit
    ///      estimated before a share falls due still funds the flush once it does. It fails open, so a flush the
    ///      Rules refuse leaves the share pending for a later one and never blocks the swap or the liquidity change.
    function _flush(PoolKey calldata key, HookrRootStorage.Record storage r) private {
        uint256 required = FLUSH_GAS + FLUSH_GAS / 63 + LANE_MARGIN;
        if (gasleft() < required) revert InsufficientLaneGas(gasleft(), required);
        bool stale = r.laneDue != 0;
        if (!stale && r.mode & HookrRootStorage.MODE_LEDGER == 0) return;
        (bool ok, bytes memory out,) = HookrRootStorage.bounded(
            r.rules, abi.encodeCall(IHookrLaneRules.flushRecapture, (key)), FLUSH_GAS, 32, false
        );
        if (ok && stale) {
            uint256 pending;
            assembly ("memory-safe") {
                pending := mload(add(out, 32))
            }
            r.laneDue = pending == 0 ? 0 : 1;
        }
    }

    /// @notice Runs one lane call through the root's self-called frame with exactly `grant` gas and credits what it
    ///         pushed to Rules, in the currency it pushed. Reverts below the gas floor and while a sync is pending; every
    ///         failure of the frame itself is recorded and the swap goes on. The trader's share of the push is bounded
    ///         by `basis` (quote units; the Rules use it only on a push in the pool's quote), and is zero unless the
    ///         frame's legs on the pool ran against the trader's swap (`zeroForOne`): an arb recapture the trader's own
    ///         move did not open credits it nothing.
    function _run(
        PoolKey calldata key,
        PoolId id,
        HookrRootStorage.Record storage r,
        address trader,
        uint8 phase,
        uint256 grant,
        uint256 basis,
        bool zeroForOne
    ) private {
        IPoolManager pm = poolManager;
        if (pm.exttload(CurrencyReserves.CURRENCY_SLOT) != bytes32(0)) revert SyncPending();
        // The frame's claim snapshot is part of the swap's own work, taken before the floor check, so the executor's
        // grant never pays for it and a larger settlement set never shrinks what the switch's cap leaves the executor.
        _snapshot(pm, key);
        uint256 required = floorOf(grant);
        if (gasleft() < required) revert InsufficientLaneGas(gasleft(), required);
        bytes memory input = abi.encode(key, trader);
        bytes memory out = new bytes(64);
        bool ok;
        bytes4 reason;
        assembly ("memory-safe") {
            ok := call(grant, address(), 0, add(input, 32), mload(input), add(out, 32), 64)
            switch ok
            case 1 { if iszero(eq(returndatasize(), 64)) { ok := 0 } }
            default {
                if gt(returndatasize(), 3) {
                    returndatacopy(0, 0, 4)
                    reason := and(mload(0), 0xffffffff00000000000000000000000000000000000000000000000000000000)
                }
            }
        }
        if (!ok) {
            emit CorrectionFailed(id, phase, trader, reason);
            return;
        }
        // The frame's nonce and a bit per accepted currency it pushed in (bit i: the list's i-th, from 1).
        (uint256 nonce, uint256 mask) = abi.decode(out, (uint256, uint256));
        if (mask == 0) {
            emit CorrectionSucceeded(id, phase, trader, 0, 0, Currency.wrap(address(0)));
            return;
        }
        if (basis != 0) {
            // The frame's first leg on the pool fixed its direction (HookrLane._enter): against the trader's swap.
            uint256 seen = HookrRootStorage.tget(_slot(LANE_DIR, id));
            if (seen >> 2 != nonce || seen & 3 != (zeroForOne ? 2 : 1)) basis = 0;
        }
        address rules = r.rules;
        uint256 partnerBps = r.lanePartnerBps;
        bytes32 list = _acceptedSlot(nonce);
        // The Rules may hold part of it as a pending donation, released from the next L2 block (`_flush`).
        r.laneDue = 1;
        for (uint256 i = 1; mask >> i != 0; ++i) {
            if ((mask >> i) & 1 == 0) continue;
            Currency currency = Currency.wrap(address(uint160(HookrRootStorage.tget(bytes32(uint256(list) + i)))));
            uint256 pushed = HookrRootStorage.tget(_pushedSlot(nonce, currency));
            pm.transfer(rules, currency.toId(), pushed);
            // The profit this push stands for: the executor kept its frozen partner share and pushed the rest.
            uint256 profit = FullMath.mulDiv(pushed, BPS, BPS - partnerBps);
            uint256 credited = abi.decode(
                _required(
                    rules,
                    abi.encodeCall(IHookrLaneRules.settleRecapture, (key, currency, trader, pushed, basis, profit)),
                    r.rulesGasLimit,
                    32,
                    false
                ),
                (uint256)
            );
            if (credited != pushed) revert InvalidModuleResult(rules);
            emit CorrectionSucceeded(id, phase, trader, profit, pushed, currency);
        }
    }

    /// @notice The lane frame, entered from the root's fallback on its own self-call. Snapshots the PoolManager's
    ///         nonzero-delta count, synced currency and the root's and executor's deltas in both pool currencies, reads
    ///         the root's claims in every currency the frame accepts as `_run` recorded them outside the grant
    ///         (`_snapshot`), calls the executor, and reverts (unwinding executor
    ///         and sink together) if any delta moved, if the root or the executor holds a delta in a sibling quote the
    ///         executor legged on, if any claim balance is not back at its snapshot once the pushes move on, or if the
    ///         executor pushed in k currencies and left less than (k - 1) x EXTRA_PUSH_GAS of its grant for their
    ///         splits. The value the executor returns is not read. `partnerBps()` is never read. Returns the frame's
    ///         nonce and a bit per accepted currency it pushed in.
    fallback(bytes calldata input) external delegated returns (bytes memory) {
        if (msg.sender != address(this) || input.length != 192 || HookrRootStorage.tget(HookrRootStorage.ACTIVE) == 0) {
            revert Unauthorized();
        }
        PoolKey memory key = abi.decode(input, (PoolKey));
        address trader = address(uint160(uint256(bytes32(input[160:192]))));
        IPoolManager pm = poolManager;
        PoolId id = key.toId();
        HookrRootStorage.Record storage r = HookrRootStorage.state().pools[id];
        address executor = r.laneExecutor;
        bytes32[] memory slots = new bytes32[](6);
        slots[0] = NonzeroDeltaCount.NONZERO_DELTA_COUNT_SLOT;
        slots[1] = CurrencyReserves.CURRENCY_SLOT;
        slots[2] = _deltaSlot(address(this), key.currency0);
        slots[3] = _deltaSlot(address(this), key.currency1);
        slots[4] = _deltaSlot(executor, key.currency0);
        slots[5] = _deltaSlot(executor, key.currency1);
        bytes32[] memory before = pm.exttload(slots);
        uint256 nonce = HookrRootStorage.tget(LANE_NONCE);
        bytes32 list = _acceptedSlot(nonce);
        uint256 n = HookrRootStorage.tget(list);
        // The snapshot `_run` took for this frame: at least the pool's two currencies.
        if (n == 0) revert Unauthorized();
        HookrRootStorage.tput(LANE_FRAME, uint256(PoolId.unwrap(id)));
        HookrRootStorage.tput(LANE_EXECUTOR, uint256(uint160(executor)));
        HookrRootStorage.tput(LANE_FAMILY, uint256(r.laneFamily));
        HookrRootStorage.tput(LANE_SIBLINGS, 0);
        bytes memory call_ = abi.encodeCall(IHookrLaneExecutor.executeArbitrage, (key, trader));
        uint256 available = gasleft();
        uint256 grant = available > FRAME_RESERVE ? available - FRAME_RESERVE : 0;
        bytes4 outOfGas = LaneOutOfGas.selector;
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := call(grant, executor, 0, add(call_, 32), mload(call_), 0, 32)
            size := returndatasize()
            if iszero(ok) {
                // Bubble only the first four bytes: the executor's selector; LaneOutOfGas when it reverted without one
                // after spending its whole grant; otherwise nothing.
                if lt(size, 4) {
                    if lt(gas(), add(FRAME_RESERVE, div(available, 64))) {
                        mstore(0, outOfGas)
                        revert(0, 4)
                    }
                    revert(0, 0)
                }
                revert(0, 4)
            }
        }
        HookrRootStorage.tput(LANE_FRAME, 0);
        // executeArbitrage still returns one word; its value is not read.
        if (size != 32) revert LaneBadReturn();
        bytes32[] memory after_ = pm.exttload(slots);
        if (after_[0] != before[0]) revert LaneLeftDelta(address(0));
        if (after_[1] != before[1]) revert LaneLeftSync(address(uint160(uint256(after_[1]))));
        if (after_[2] != before[2] || after_[4] != before[4]) revert LaneLeftDelta(Currency.unwrap(key.currency0));
        if (after_[3] != before[3] || after_[5] != before[5]) revert LaneLeftDelta(Currency.unwrap(key.currency1));
        _checkSiblings(pm, executor);
        // Every accepted currency's claims are back at the snapshot once its push moves to the Rules (`_run`).
        uint256 mask;
        uint256 k;
        for (uint256 i = 1; i <= n; ++i) {
            Currency c = Currency.wrap(address(uint160(HookrRootStorage.tget(bytes32(uint256(list) + i)))));
            uint256 pushed = HookrRootStorage.tget(_pushedSlot(nonce, c));
            if (pushed != 0) (mask, k) = (mask | (1 << i), k + 1);
            if (pm.balanceOf(address(this), c.toId()) != HookrRootStorage.tget(_baseSlot(nonce, c)) - 1 + pushed) {
                revert LaneStrayClaims(Currency.unwrap(c));
            }
        }
        if (k > 1 && gasleft() < (k - 1) * EXTRA_PUSH_GAS) revert LaneOutOfGas();
        return abi.encode(nonce, mask);
    }

    /// @dev The currencies a frame on `key` accepts a push in: the pool's two, then every member of the registry's
    ///      settlement set that is not one of them (at most 8, bounded by the registry).
    function _accepted(PoolKey memory key) private view returns (Currency[] memory list) {
        address[] memory set = IHookrLanes(address(registry)).settlementCurrencies();
        list = new Currency[](set.length + 2);
        (list[0], list[1]) = (key.currency0, key.currency1);
        uint256 n = 2;
        for (uint256 i; i < set.length; ++i) {
            Currency c = Currency.wrap(set[i]);
            if (!(c == key.currency0 || c == key.currency1)) list[n++] = c;
        }
        assembly ("memory-safe") {
            mstore(list, n)
        }
    }

    /// @dev Opens the next frame's nonce and records, for it, every currency the frame accepts (`_accepted`) and the
    ///      root's ERC-6909 claim balance in each (plus one, LANE_BASE). Taken in `_run` right before the self-call,
    ///      outside the grant; the frame reads it back and nothing moves a claim in between.
    function _snapshot(IPoolManager pm, PoolKey calldata key) private {
        uint256 nonce = HookrRootStorage.tget(LANE_NONCE) + 1;
        HookrRootStorage.tput(LANE_NONCE, nonce);
        Currency[] memory accepted = _accepted(key);
        bytes32 list = _acceptedSlot(nonce);
        HookrRootStorage.tput(list, accepted.length);
        for (uint256 i; i < accepted.length; ++i) {
            Currency c = accepted[i];
            HookrRootStorage.tput(bytes32(uint256(list) + i + 1), uint256(uint160(Currency.unwrap(c))));
            HookrRootStorage.tput(_baseSlot(nonce, c), pm.balanceOf(address(this), c.toId()) + 1);
        }
    }

    function _acceptedSlot(uint256 nonce) private pure returns (bytes32) {
        return keccak256(abi.encode(LANE_ACCEPTED, nonce));
    }

    function _baseSlot(uint256 nonce, Currency currency) private pure returns (bytes32) {
        return keccak256(abi.encode(LANE_BASE, nonce, currency));
    }

    function _pushedSlot(uint256 nonce, Currency currency) private pure returns (bytes32) {
        return keccak256(abi.encode(LANE_PUSHED, nonce, currency));
    }

    /// @dev Every sibling quote the executor legged on is settled: neither the root nor the executor holds a delta in
    ///      it. The subject is shared with the pool under arb recapture and checked against its snapshot.
    function _checkSiblings(IPoolManager pm, address executor) private view {
        uint256 n = HookrRootStorage.tget(LANE_SIBLINGS);
        if (n == 0) return;
        bytes32[] memory slots = new bytes32[](2 * n);
        for (uint256 i; i < n; ++i) {
            Currency quote =
                Currency.wrap(address(uint160(HookrRootStorage.tget(bytes32(uint256(LANE_SIBLINGS) + i + 1)))));
            slots[2 * i] = _deltaSlot(address(this), quote);
            slots[2 * i + 1] = _deltaSlot(executor, quote);
        }
        bytes32[] memory values = pm.exttload(slots);
        for (uint256 i; i < values.length; ++i) {
            if (values[i] != bytes32(0)) {
                revert LaneLeftDelta(address(
                        uint160(HookrRootStorage.tget(bytes32(uint256(LANE_SIBLINGS) + i / 2 + 1)))
                    ));
            }
        }
    }

    /// @notice The executor's push (IHookrLaneRoot.settleRecapture), served through the root's fallback: only the
    ///         open frame's executor, only for the pool under arb recapture, only in a currency the frame accepts (the
    ///         pool's two and the registry's settlement set at the frame's open), only when backed by claims of that
    ///         currency minted to the root since the frame opened. Pushes add up per currency, and a frame may push in
    ///         several currencies: each is split on its own once the frame returns (`_run`).
    function settleRecapture(PoolKey calldata key, Currency currency, uint256 amount) external delegated {
        uint256 nonce = HookrRootStorage.tget(LANE_NONCE);
        uint256 base = HookrRootStorage.tget(_baseSlot(nonce, currency));
        if (
            msg.sender != address(uint160(HookrRootStorage.tget(LANE_EXECUTOR)))
                || HookrRootStorage.tget(LANE_FRAME) != uint256(PoolId.unwrap(key.toId())) || amount == 0
                || amount > uint256(uint128(type(int128).max)) || base == 0
        ) revert SinkClosed();
        bytes32 slot = _pushedSlot(nonce, currency);
        uint256 pushed = HookrRootStorage.tget(slot) + amount;
        if (poolManager.balanceOf(address(this), currency.toId()) < base - 1 + pushed) revert SinkUnbacked();
        HookrRootStorage.tput(slot, pushed);
    }

    /// @notice IHookrLaneRoot.sweepClaims, served through the root's fallback: moves every ERC-6909 claim of
    ///         `currency` the root holds to the lane pool `id`'s Rules as a protocol claim. Permissionless; refused while
    ///         a swap, a binding or a frame is active, so it never reaches a push in flight.
    function sweepClaims(PoolId id, Currency currency) external delegated returns (uint256 amount) {
        if (
            HookrRootStorage.tget(HookrRootStorage.ACTIVE) != 0 || HookrRootStorage.tget(HookrRootStorage.BINDING) != 0
                || HookrRootStorage.tget(LANE_FRAME) != 0
        ) {
            revert ReentrantCallback();
        }
        HookrRootStorage.Record storage r = HookrRootStorage.state().pools[id];
        if (r.mode & HookrRootStorage.MODE_LANE == 0) revert InvalidPool();
        amount = poolManager.balanceOf(address(this), currency.toId());
        if (amount == 0) return 0;
        address rules = r.rules;
        poolManager.transfer(rules, currency.toId(), amount);
        _required(rules, abi.encodeCall(IHookrLaneRules.creditSweep, (currency, amount)), r.rulesGasLimit, 0, false);
        emit ClaimsSwept(id, currency, amount);
    }

    /// @notice IHookrLaneRoot.laneOf, served through the root's fallback.
    function laneOf(PoolId id)
        external
        view
        delegated
        returns (
            address executor,
            bytes32 codeHash,
            uint16 partnerBps,
            bytes32 family,
            bool on,
            uint32 gasCap,
            uint256 gasFloor
        )
    {
        HookrRootStorage.Record storage r = HookrRootStorage.state().pools[id];
        if (!r.initialized) revert InvalidPool();
        (executor, codeHash, partnerBps, family) = (r.laneExecutor, r.laneCodeHash, r.lanePartnerBps, r.laneFamily);
        if (executor != address(0)) {
            (on, gasCap) = IHookrLanes(address(registry)).executorLane(address(this), executor);
            if (on && gasCap != 0 && executor.codehash == codeHash) gasFloor = entryFloorOf(gasCap);
        }
    }

    /// @notice IHookrLaneRoot.sameTxLiquidityOnPath, served through the root's fallback.
    function sameTxLiquidityOnPath(PoolId id) external view delegated returns (bool) {
        return _sameTx(id, poolManager);
    }

    /// @dev Reads the Rules recapture mode and, for a recapture pool, freezes the root's open registry lane (executor,
    ///      codehash, partner share) and the family the launcher reports for the pool, scoped to that launcher, and
    ///      marks the pool as created in this transaction. A pool whose Rules ask for recapture never opens without a
    ///      lane: a closed or switched-off lane refuses it.
    function _freeze(HookrRootStorage.Record storage r, PoolId id, address rules) private returns (bytes32 laneHash) {
        (bool ok, bytes memory out,) =
            HookrRootStorage.bounded(rules, abi.encodeCall(IHookrLaneRules.recaptureMode, (id)), 50_000, 32, true);
        uint256 mode = ok ? abi.decode(out, (uint256)) : 0;
        if (mode == 0) return 0;
        (address executor, bytes32 codeHash,, uint16 partnerBps) =
            IHookrLanes(address(registry)).activeLaneOf(address(this));
        IHookrRoot root = IHookrRoot(address(this));
        if (
            mode > 2 || executor == address(0) || executor == root.router() || executor == root.quoter()
                || executor == root.curatedRouter()
        ) revert InvalidConfig();
        bytes32 family;
        (ok, out,) =
            HookrRootStorage.bounded(msg.sender, abi.encodeWithSignature("poolFamily(bytes32)", id), 50_000, 32, true);
        if (ok) family = abi.decode(out, (bytes32));
        if (family != bytes32(0)) family = keccak256(abi.encode(msg.sender, family));
        r.mode |= mode == 2 ? HookrRootStorage.MODE_LANE | HookrRootStorage.MODE_LEDGER : HookrRootStorage.MODE_LANE;
        r.laneLiquidity = true;
        (r.laneExecutor, r.lanePartnerBps, r.laneCodeHash, r.laneFamily) = (executor, partnerBps, codeHash, family);
        HookrRootStorage.tput(_slot(LANE_CREATED, id), 1);
        laneHash = keccak256(abi.encode(executor, codeHash, partnerBps, family));
        emit PoolLane(id, executor, codeHash, partnerBps, family);
    }

    /// @dev Records a liquidity change against its position for this transaction (King of the Pool pools).
    function _ledger(PoolId id, address sender, ModifyLiquidityParams calldata p) private {
        bytes32 pos = keccak256(abi.encode(LEDGER, id, sender, p.tickLower, p.tickUpper, p.salt));
        uint256 net = HookrRootStorage.tget(pos);
        if (p.liquidityDelta > 0) {
            bytes32 ticksSlot = bytes32(uint256(pos) + 1);
            if (HookrRootStorage.tget(ticksSlot) == 0) {
                HookrRootStorage.tput(
                    ticksSlot, (1 << 255) | (uint256(uint24(p.tickLower)) << 24) | uint256(uint24(p.tickUpper))
                );
                bytes32 list = _slot(LEDGER_LIST, id);
                uint256 n = HookrRootStorage.tget(list) + 1;
                HookrRootStorage.tput(list, n);
                if (n <= MAX_TRACKED_POSITIONS) HookrRootStorage.tput(bytes32(uint256(list) + n), uint256(pos));
            }
            HookrRootStorage.tput(pos, net + uint256(p.liquidityDelta));
        } else if (net != 0) {
            uint256 removed = uint256(-p.liquidityDelta);
            HookrRootStorage.tput(pos, removed >= net ? 0 : net - removed);
        }
    }

    /// @notice Records the swap's start tick on a King of the Pool pool that saw liquidity added in this transaction.
    function _markTick(PoolId id) private {
        if (HookrRootStorage.tget(_slot(LEDGER_LIST, id)) != 0) {
            (, int24 tick,,) = StateLibrary.getSlot0(poolManager, id);
            HookrRootStorage.tput(_slot(LEDGER_TICK, id), (1 << 255) | uint256(uint24(tick)));
        }
    }

    /// @notice Binds admitted modules and initializes one pool. Only an admitted launcher can call.
    /// @dev The subject must hold its own code, not an EIP-7702 delegation designator, and the registry must
    ///      qualify the quote (`isQuote`, which refuses a delegated account too). Rules bind against
    ///      min(pool, Rules admission) caps less the advisory's admitted maximum, so valid module outputs always fit
    ///      the pool caps. The Rules removal lock is read once here and bounded to MAX_LOCK_BLOCKS. A pool whose Rules
    ///      froze recapture freezes the registry lane and is never fee-only.
    function initializePool(
        PoolKey calldata key,
        HookrTypes.PoolConfig calldata pc,
        bytes calldata rulesData,
        bytes calldata advisoryData,
        uint160 sqrtPriceX96
    ) external delegated returns (PoolId id) {
        if (!registry.isLauncher(msg.sender) || !registry.rootOpen(address(this))) {
            revert Unauthorized();
        }
        if (HookrRootStorage.tget(HookrRootStorage.ACTIVE) != 0 || HookrRootStorage.tget(HookrRootStorage.BINDING) != 0)
        {
            revert ReentrantCallback();
        }
        id = key.toId();
        HookrRootStorage.Record storage r = HookrRootStorage.state().pools[id];
        if (r.initialized || r.policy != bytes32(0)) revert AlreadyInitialized();
        if (
            address(key.hooks) != address(this) || key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG
                || Currency.unwrap(pc.subject) == address(0) || Currency.unwrap(pc.subject) == Currency.unwrap(pc.quote)
                || !((pc.subject == key.currency0 && pc.quote == key.currency1)
                    || (pc.subject == key.currency1 && pc.quote == key.currency0))
                || pc.baseLpFeePips > pc.caps.maxLpFeePips || pc.caps.maxLpFeePips > 600_000
                || pc.caps.maxQuoteTakePips >= PIPS || pc.caps.maxSubjectTakeBps > 1_000
                || pc.liquidityOwner == address(0) || rulesData.length > 4096 || advisoryData.length > 4096
                || !_holdsOwnCode(Currency.unwrap(pc.subject))
        ) revert InvalidConfig();
        if (!registry.isQuote(Currency.unwrap(pc.quote))) revert UnqualifiedQuote(Currency.unwrap(pc.quote));
        IHookrRegistry.Admission memory ra = _admitted(pc.rules, IHookrRegistry.Kind.RULES);
        if (
            pc.rulesGasLimit != ra.gasLimit || address(IHookrRules(pc.rules).poolManager()) != address(poolManager)
                || IHookrRules(pc.rules).trustedRoot() != address(this)
        ) revert InvalidConfig();
        r.subject = pc.subject;
        r.baseLpFeePips = pc.baseLpFeePips;
        r.capLp = pc.caps.maxLpFeePips;
        r.capQuote = pc.caps.maxQuoteTakePips;
        r.capSubject = pc.caps.maxSubjectTakeBps;
        r.quote = pc.quote;
        r.quoteIsCurrency0 = pc.quote == key.currency0;
        r.rulesCapLp = ra.caps.maxLpFeePips;
        r.rulesCapQuote = ra.caps.maxQuoteTakePips;
        r.rulesCapSubject = ra.caps.maxSubjectTakeBps;
        r.rulesGasLimit = pc.rulesGasLimit;
        r.rules = pc.rules;
        r.advisoryPhases = pc.advisoryPhases;
        r.advisory = pc.advisory;
        r.advisoryGasLimit = pc.advisoryGasLimit;
        r.advisoryFailOpen = pc.advisoryFailOpen;
        r.liquidityOwner = pc.liquidityOwner;
        r.policyId = pc.policyId;
        HookrRootStorage.tput(HookrRootStorage.BINDING, uint256(PoolId.unwrap(id)));
        HookrTypes.PoolConfig memory rulesLimits = pc;
        if (rulesLimits.caps.maxLpFeePips > ra.caps.maxLpFeePips) rulesLimits.caps.maxLpFeePips = ra.caps.maxLpFeePips;
        if (rulesLimits.caps.maxQuoteTakePips > ra.caps.maxQuoteTakePips) {
            rulesLimits.caps.maxQuoteTakePips = ra.caps.maxQuoteTakePips;
        }
        if (rulesLimits.caps.maxSubjectTakeBps > ra.caps.maxSubjectTakeBps) {
            rulesLimits.caps.maxSubjectTakeBps = ra.caps.maxSubjectTakeBps;
        }
        IHookrRegistry.Admission memory aa;
        if (pc.advisory != address(0)) {
            aa = _admitted(pc.advisory, IHookrRegistry.Kind.ADVISORY);
            if (
                pc.advisoryGasLimit != aa.gasLimit || pc.advisoryPhases == 0 || pc.advisoryPhases & ~aa.phaseMask != 0
                    || pc.advisoryFailOpen && (!aa.failOpen || !aa.feeOnly || aa.caps.maxQuoteTakePips != 0)
                    || aa.caps.maxLpFeePips > rulesLimits.caps.maxLpFeePips
                    || aa.caps.maxQuoteTakePips > rulesLimits.caps.maxQuoteTakePips
            ) revert InvalidConfig();
            r.advisoryCapLp = aa.caps.maxLpFeePips;
            r.advisoryCapQuote = aa.caps.maxQuoteTakePips;
            // The advisory's admitted maximum is reserved before the Rules maximum is checked.
            rulesLimits.caps.maxLpFeePips -= aa.caps.maxLpFeePips;
            rulesLimits.caps.maxQuoteTakePips -= aa.caps.maxQuoteTakePips;
        } else if (
            advisoryData.length != 0 || pc.advisoryPhases != 0 || pc.advisoryFailOpen || pc.advisoryGasLimit != 0
        ) {
            revert InvalidConfig();
        }
        bytes32 rulesHash = abi.decode(
            _required(
                pc.rules, abi.encodeCall(IHookrRules.bind, (key, rulesLimits, rulesData)), pc.rulesGasLimit, 32, false
            ),
            (bytes32)
        );
        if (rulesHash != keccak256(rulesData)) revert InvalidConfig();
        {
            uint256 lock = abi.decode(
                _required(pc.rules, abi.encodeCall(IHookrRules.removalLockedUntil, (id)), pc.rulesGasLimit, 32, true),
                (uint256)
            );
            if (lock > block.number + MAX_LOCK_BLOCKS) lock = block.number + MAX_LOCK_BLOCKS;
            r.lockedUntil = uint40(lock);
        }
        bytes32 laneHash = _freeze(r, id, pc.rules);
        // A quote take is credited through Rules, so only an advisory admitted without one allows the fee-only path.
        // A lane pool never takes it.
        if (laneHash == 0 && aa.caps.maxQuoteTakePips == 0 && pc.baseLpFeePips <= ra.caps.maxLpFeePips) {
            r.feeOnlyFrom = _feeOnlyFrom(pc.rules, id);
        }
        // A pool that becomes fee-only never charges a dynamic fee.
        if (r.feeOnlyFrom == 0 && _dynamicFeeOf(pc.rules, id)) r.mode |= HookrRootStorage.MODE_DYNAMIC_FEE;
        bytes32 advisoryHash;
        if (pc.advisory != address(0)) {
            advisoryHash = abi.decode(
                _required(
                    pc.advisory,
                    abi.encodeCall(IHookrAdvisory.bind, (key, pc, advisoryData)),
                    pc.advisoryGasLimit,
                    32,
                    false
                ),
                (bytes32)
            );
            if (advisoryHash != keccak256(advisoryData)) revert InvalidConfig();
        }
        bytes32 policy = keccak256(abi.encode(block.chainid, key, pc, rulesHash, advisoryHash));
        r.policy = laneHash == 0 ? policy : keccak256(abi.encode(policy, laneHash));
        poolManager.initialize(key, sqrtPriceX96);
        r.initialized = true;
        poolManager.updateDynamicLPFee(key, pc.baseLpFeePips);
        HookrRootStorage.tput(HookrRootStorage.BINDING, 0);
        emit PoolOpened(id, msg.sender, r.policy, pc.rules, pc.advisory);
    }

    function _admitted(address implementation, IHookrRegistry.Kind kind)
        private
        returns (IHookrRegistry.Admission memory a)
    {
        a = registry.admission(address(this), implementation);
        if (
            a.implementation != implementation || implementation == address(0) || a.kind != kind
                || implementation.codehash != a.codeHash
        ) revert InvalidModule(implementation);
        bytes memory result = _required(implementation, abi.encodeWithSignature("configSchemaHash()"), 50_000, 32, true);
        if (abi.decode(result, (bytes32)) != a.schemaHash) revert InvalidModule(implementation);
    }

    /// @dev The Rules module's dynamic fee declaration, read once at binding. A failed call leaves the pool
    ///      unsimulated, where Rules that charge a dynamic fee refuse to quote.
    function _dynamicFeeOf(address rules, PoolId id) private returns (bool) {
        (bool ok, bytes memory out,) = HookrRootStorage.bounded(
            rules, abi.encodeCall(IHookrDynamicFeeRules.poolHasDynamicFee, (id)), 50_000, 32, true
        );
        return ok && abi.decode(out, (uint256)) == 1;
    }

    /// @dev The Rules module's fee-only declaration, read once at binding. A failed call or an out-of-range
    ///      block leaves the pool on the full path.
    function _feeOnlyFrom(address rules, PoolId id) private returns (uint40) {
        (bool ok, bytes memory out,) =
            HookrRootStorage.bounded(rules, abi.encodeCall(IHookrFeeOnlyRules.feeOnlyFrom, (id)), 50_000, 32, true);
        if (!ok) return 0;
        uint256 from = abi.decode(out, (uint256));
        return from > type(uint40).max ? 0 : uint40(from);
    }

    function _required(address target, bytes memory input, uint256 gasLimit, uint256 size, bool readOnly)
        private
        returns (bytes memory output)
    {
        bool ok;
        bool reverted;
        (ok, output, reverted) = HookrRootStorage.bounded(target, input, gasLimit, size, readOnly);
        if (!ok) HookrRootStorage.revertModuleCall(target, input, reverted);
    }

    /// @notice The gas a swap on a lane pool must carry at each lane call: the grant, the 1/64 the call keeps back, the
    ///         root's reserve and a margin.
    function floorOf(uint256 cap) internal pure returns (uint256) {
        return cap + cap / 63 + LANE_RESERVE + LANE_MARGIN;
    }

    /// @notice The gas a swap on a lane pool must carry when it reaches the before-phase: the most that call can spend
    ///         (its grant), LANE_BODY for its split and the swap's own work up to the after-phase, and the after-phase's
    ///         floor. It covers the before-phase's own floor. A route through several lane pools of the root carries
    ///         the sum of their entry floors to its first lane swap (`_laneGas`).
    function entryFloorOf(uint256 cap) internal pure returns (uint256) {
        return floorOf(cap) + cap + LANE_BODY;
    }

    function _sameTx(PoolId id, IPoolManager pm) private view returns (bool) {
        bytes32 list = _slot(LEDGER_LIST, id);
        uint256 n = HookrRootStorage.tget(list);
        if (n == 0) return false;
        if (n > MAX_TRACKED_POSITIONS) return true;
        (, int24 tick,,) = StateLibrary.getSlot0(pm, id);
        uint256 recorded = HookrRootStorage.tget(_slot(LEDGER_TICK, id));
        int24 start = recorded == 0 ? tick : int24(uint24(recorded));
        (int24 lo, int24 hi) = start < tick ? (start, tick) : (tick, start);
        uint256 sum;
        for (uint256 i = 1; i <= n; ++i) {
            bytes32 pos = bytes32(HookrRootStorage.tget(bytes32(uint256(list) + i)));
            uint256 net = HookrRootStorage.tget(pos);
            if (net == 0) continue;
            uint256 ticks = HookrRootStorage.tget(bytes32(uint256(pos) + 1));
            if (int24(uint24(ticks >> 24)) <= hi && int24(uint24(ticks)) > lo) sum += net;
        }
        return sum != 0 && sum * BPS > uint256(StateLibrary.getLiquidity(pm, id)) * JIT_TOLERANCE_BPS;
    }

    function _deltaSlot(address target, Currency currency) private pure returns (bytes32 key) {
        assembly ("memory-safe") {
            mstore(0, and(target, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(32, and(currency, 0xffffffffffffffffffffffffffffffffffffffff))
            key := keccak256(0, 64)
        }
    }

    function _slot(bytes32 tag, PoolId id) private pure returns (bytes32) {
        return keccak256(abi.encode(tag, id));
    }

    /// @dev Whether `account` holds code that is not an EIP-7702 delegation designator (0xef0100 || target): a
    ///      delegated account's key holder can re-point it at will. A designator is exactly 23 bytes, so only code of
    ///      that length is read: 23 bytes that start with 0xEF (HookrDelegation.isDelegated) are refused.
    function _holdsOwnCode(address account) private view returns (bool) {
        uint256 size = account.code.length;
        return size == 23 ? !HookrDelegation.isDelegated(account) : size != 0;
    }
}
