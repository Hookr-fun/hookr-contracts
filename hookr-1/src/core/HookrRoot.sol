// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrRules} from "../interfaces/IHookrRules.sol";
import {IHookrDynamicFeeRules} from "../interfaces/IHookrDynamicFeeRules.sol";
import {IHookrRootRoute} from "../interfaces/IHookrRootRoute.sol";
import {IHookrAdvisory} from "../interfaces/IHookrAdvisory.sol";
import {HookrRootStorage} from "../libraries/HookrRootStorage.sol";
import {HookrLane} from "./HookrLane.sol";
import {IHookrLaneRoot} from "../interfaces/IHookrLaneRoot.sol";
import {IHookrLaneRules} from "../interfaces/IHookrLaneRules.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrRootEvents} from "../interfaces/IHookrRootEvents.sol";
import {IHookrLaneEvents} from "../interfaces/IHookrLaneEvents.sol";
import {IHookrRootState} from "../interfaces/IHookrRootState.sol";

/// @title HookrRoot
/// @notice Immutable root. A pool opts into the recapture lane at launch through its Rules; every other pool runs the
///         swap path without it. No forwarding or universal reward callback.
/// @dev Principal locks are counted in this chain's block.number, the parent (L1) height on Arbitrum-style chains.
///      On a pool with Hookr dynamic fees each swap first runs, and reverts, the same swap on the PoolManager through
///      the root's fallback, so Rules price the dynamic fee on where it ends. Initialization and the lane run in the
///      HookrLane module this root deploys in its constructor and reaches only by DELEGATECALL (see HookrLane): a lane
///      pool freezes the registry's lane executor at initialization, and each of its swaps reads the executor's live
///      switch once, requires the lane's gas floor, and runs an arb recapture before the swap is quoted and after it
///      settles.
contract HookrRoot is
    HookrReleased,
    IHookrRoot,
    IHookrRootRoute,
    IHooks,
    IHookrRootEvents,
    IHookrLaneEvents,
    IHookrRootState
{
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for IPoolManager;

    /// @inheritdoc IHookrRootState
    uint160 public constant PERMISSION_FLAGS = 0x2acc;
    /// @inheritdoc IHookrRootState
    address public constant DEAD = address(0xdead);
    uint256 private constant PIPS = 1_000_000;
    uint256 private constant FRAME_AUTHENTICATED = 1 << 160;
    uint256 private constant FRAME_RECEIPT = 1 << 161;
    uint256 private constant FRAME_FEE_ONLY = 1 << 162;
    /// @dev Fallback input length of a simulation: `abi.encode(PoolKey, SwapParams, uint24)`.
    uint256 private constant SIMULATION_INPUT = 288;
    /// @dev Fallback input length of a dynamic fee quote: the PoolKey and SwapParams, the SwapContext and the amount.
    uint256 private constant QUOTE_INPUT = 704;
    bytes32 private constant ACTIVE = HookrRootStorage.ACTIVE;
    bytes32 private constant FRAME = keccak256("hookr.root.transient.frame");
    bytes32 private constant BINDING = HookrRootStorage.BINDING;
    uint256 private constant FRAME_LANE = 1 << 163;
    uint256 private constant FRAME_NESTED = 1 << 164;
    /// @dev Fallback input length of a lane frame: `abi.encode(PoolKey, address trader)`.
    uint256 private constant LANE_INPUT = 192;
    /// @dev An advised executor leg: the advisory's path alone, no rule, its take credited through
    ///      IHookrLaneRules.settleLeg.
    uint256 private constant FRAME_LEG = 1 << 165;
    /// @dev HookrLane.updateLegDynamicFee: an executor leg on a dynamic fee pool carries the pool's dynamic fee state.
    bytes4 private constant CARRY_LEG = HookrLane.updateLegDynamicFee.selector;
    /// @dev `_refuseMev` asks the lane executor's MEV view, `checkV3PoolsMev(address,address,address,bool)`, with at
    ///      most MEV_CHECK_GAS, the live WTH root's figure.
    bytes4 private constant MEV_CHECK = 0x9e97c424;
    uint256 private constant MEV_CHECK_GAS = 200_000;
    bytes32 private constant RECEIPT = keccak256("hookr.root.transient.receipt");
    bytes32 private constant RECEIPT_OWNER = keccak256("hookr.root.transient.receipt.owner");
    /// @inheritdoc IHookrRoot
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrRoot
    IHookrRegistry public immutable registry;
    /// @inheritdoc IHookrRoot
    address public immutable router;
    /// @inheritdoc IHookrRoot
    address public immutable quoter;
    /// @inheritdoc IHookrRoot
    address public immutable curatedRouter;
    /// @inheritdoc IHookrRootState
    bytes32 public immutable routerCodeHash;
    /// @inheritdoc IHookrRootState
    bytes32 public immutable quoterCodeHash;
    /// @inheritdoc IHookrRootState
    bytes32 public immutable curatedRouterCodeHash;
    /// @dev HookrLane: the cold-path module (initializePool and the recapture lane) this root deployed and reaches only
    ///      by DELEGATECALL, and its runtime codehash. Both are fixed in this root's runtime code, so the registry's pin
    ///      of this root's codehash also pins the module's code (checked at registration through `laneModule()`).
    address private immutable lane;
    bytes32 private immutable laneCodeHash;

    /// @dev The pool record is HookrRootStorage.Record (shared with HookrLane): HookrRoot's record with `dynamicFee`
    ///      widened to `mode` (dynamic fee, lane, King of the Pool ledger) and the frozen lane appended.
    struct Frame {
        HookrTypes.SwapContext context;
        HookrTypes.FeeQuote rules;
        HookrTypes.Advice advice;
        uint256 reserved;
        uint24 lpFee;
        bool receiptRequested;
    }

    constructor(IPoolManager _manager, IHookrRegistry _registry, address _router, address _quoter, address _curated) {
        if (
            address(_manager).code.length == 0 || address(_registry).code.length == 0 || _router.code.length == 0
                || _quoter.code.length == 0 || (_curated != address(0) && _curated.code.length == 0)
                || (uint160(address(this)) & 0x3fff) != PERMISSION_FLAGS
        ) revert InvalidWiring();
        if (_curated != address(0)) {
            (bool ok, bytes memory out) = _curated.staticcall(abi.encodeWithSignature("poolManager()"));
            if (!ok || out.length != 32 || abi.decode(out, (uint256)) != uint256(uint160(address(_manager)))) {
                revert InvalidWiring();
            }
        }
        poolManager = _manager;
        registry = _registry;
        router = _router;
        quoter = _quoter;
        curatedRouter = _curated;
        routerCodeHash = _router.codehash;
        quoterCodeHash = _quoter.codehash;
        curatedRouterCodeHash = _curated.codehash;
        address module = address(new HookrLane(_manager, _registry));
        lane = module;
        laneCodeHash = module.codehash;
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    /// @inheritdoc IHookrRoot
    /// @notice Returns the immutable configuration of an initialized Hookr pool.
    function poolConfig(PoolId id) external view returns (HookrTypes.PoolConfig memory pc) {
        HookrRootStorage.Record storage r = _record(id);
        pc.subject = r.subject;
        pc.quote = r.quote;
        pc.rules = r.rules;
        pc.advisory = r.advisory;
        pc.liquidityOwner = r.liquidityOwner;
        pc.baseLpFeePips = r.baseLpFeePips;
        pc.caps = HookrTypes.Caps(r.capLp, r.capQuote, r.capSubject);
        pc.rulesGasLimit = r.rulesGasLimit;
        pc.advisoryGasLimit = r.advisoryGasLimit;
        pc.advisoryPhases = r.advisoryPhases;
        pc.advisoryFailOpen = r.advisoryFailOpen;
        pc.policyId = r.policyId;
    }

    /// @inheritdoc IHookrRootRoute
    function poolRoute(PoolId id) external view returns (Currency quote, address advisory) {
        HookrRootStorage.Record storage r = _record(id);
        return (r.quote, r.advisory);
    }

    /// @notice IHookrLaneRoot.quoteLeg: what a recapture leg of `params` on `key` sent by the caller would pay the
    ///         pool's advisory, asked as the leg asks it (the caller as sender, payer and beneficiary, unauthenticated).
    ///         Writes nothing; answers under staticcall or eth_call. Reverts `NotALeg` for a pool the caller's swap
    ///         would not be a leg on, and where the leg would be refused. The after phase is asked on the state before
    ///         the swap (`afterPreSwap`).
    function quoteLeg(PoolKey calldata key, SwapParams calldata params, int128 amount0, int128 amount1)
        external
        returns (
            uint24 lpFeePips,
            uint24 takePips,
            address recipient,
            bool fullPath,
            bool afterSkipped,
            bool afterPreSwap
        )
    {
        PoolId id = key.toId();
        HookrRootStorage.Record storage r = _record(id);
        // A leg is the frozen executor's swap on its lane pool and, inside a frame (HookrLane._enter), only on the
        // frame's pool or a lane sibling of the frame's family. A swap anywhere else is an ordinary one that pays the
        // pool's Rules too, which this does not price.
        uint256 frame = HookrRootStorage.tget(HookrRootStorage.LANE_FRAME);
        bytes32 family = r.laneFamily;
        if (
            r.mode & HookrRootStorage.MODE_LANE == 0 || r.laneExecutor != msg.sender
                || (frame != 0
                    && (msg.sender != address(uint160(HookrRootStorage.tget(HookrRootStorage.LANE_EXECUTOR)))
                        || (frame != uint256(PoolId.unwrap(id))
                            && (family == bytes32(0)
                                || family != bytes32(HookrRootStorage.tget(HookrRootStorage.LANE_FAMILY))))))
        ) revert NotALeg();
        HookrTypes.SwapContext memory x = _context(key, params, msg.sender, id, r);
        fullPath = x.isBuy && block.number < r.lockedUntil;
        lpFeePips = r.baseLpFeePips;
        uint256 phases = r.advisoryPhases;
        if (phases & HookrTypes.BEFORE_SWAP != 0) {
            HookrTypes.Advice memory a = _advice(r, x, 0, 0, false, r.capLp - lpFeePips);
            lpFeePips += a.lpFeeSurchargePips;
            takePips = a.quoteTakePips;
            recipient = a.recipient;
            if (lpFeePips > r.capLp || takePips > r.capQuote) revert AggregateCapExceeded();
            if (a.reject) revert SwapRejected();
        }
        if (phases & HookrTypes.AFTER_SWAP != 0) {
            // The after phase answers on the pool's own swap delta; without one it is not asked, and the flag says so.
            // With one it is asked on the state before the swap, which only an advisory pricing on the amounts alone
            // answers as the leg is answered; the root cannot see what an advisory reads, and the flag says so.
            if (amount0 == 0 && amount1 == 0) {
                afterSkipped = true;
            } else {
                afterPreSwap = true;
                HookrTypes.Advice memory b = _advice(r, x, amount0, amount1, true, 0);
                if (
                    b.lpFeeSurchargePips != 0 || b.reject
                        || (b.quoteTakePips != 0
                            && (x.isBuy == x.exactInput || (takePips != 0 && b.recipient != recipient)))
                ) revert InvalidModuleResult(r.advisory);
                if (b.quoteTakePips != 0) recipient = b.recipient;
                takePips += b.quoteTakePips;
            }
        }
        if (takePips > r.advisoryCapQuote || takePips > r.capQuote) revert AggregateCapExceeded();
    }

    /// @inheritdoc IHookrRootRoute
    function feeOnlyFrom(PoolId id) external view returns (uint256) {
        return _record(id).feeOnlyFrom;
    }

    /// @inheritdoc IHookrRoot
    /// @notice Returns the commitment to the pool key, configuration and module data.
    function policyHash(PoolId id) external view returns (bytes32) {
        return _record(id).policy;
    }

    /// @inheritdoc IHookrRoot
    /// @notice Returns whether this root initialized the pool.
    function knownPool(PoolId id) external view returns (bool) {
        return _state().pools[id].initialized;
    }

    /// @inheritdoc IHookrRoot
    /// @notice Returns the pool being bound during initialization. Zero outside binding.
    function bindingPool() external view returns (PoolId) {
        return PoolId.wrap(bytes32(HookrRootStorage.tget(BINDING)));
    }

    /// @inheritdoc IHookrRoot
    /// @notice Binds admitted modules and initializes one pool. Only an admitted launcher can call.
    /// @dev Runs in HookrLane by DELEGATECALL (see HookrLane.initializePool): the subject must hold its own code, not
    ///      an EIP-7702 delegation designator, and the registry must qualify the quote (`isQuote`); Rules bind against
    ///      min(pool, Rules admission) caps less the advisory's admitted maximum; the Rules removal lock is read once
    ///      and bounded to HookrLane's MAX_LOCK_BLOCKS; a pool whose Rules froze recapture freezes the registry lane.
    function initializePool(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata, bytes calldata, uint160)
        external
        returns (PoolId)
    {
        _forward();
    }

    /// @inheritdoc IHooks
    /// @notice Accepts only initialization started by this root.
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyManager
        returns (bytes4)
    {
        if (sender != address(this) || HookrRootStorage.tget(BINDING) != uint256(PoolId.unwrap(key.toId()))) {
            revert Unauthorized();
        }
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @notice Checks the pool modules before liquidity is added. A fail-open advisory is fee-only and is not consulted.
    ///         On a lane pool HookrLane first donates a due recapture LP share, before the new liquidity lands.
    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyManager
        returns (bytes4)
    {
        if (HookrRootStorage.tget(ACTIVE) != 0 || HookrRootStorage.tget(BINDING) != 0) revert ReentrantCallback();
        PoolId id = key.toId();
        HookrRootStorage.Record storage r = _record(id);
        if (r.mode & HookrRootStorage.MODE_LANE != 0) _lane(0);
        _required(r.rules, abi.encodeCall(IHookrRules.beforeAddLiquidity, (id, sender)), r.rulesGasLimit, 0, true);
        if (r.advisory != address(0) && !r.advisoryFailOpen) {
            bool allowed = abi.decode(
                _required(
                    r.advisory,
                    abi.encodeCall(IHookrAdvisory.beforeAddLiquidity, (id, sender)),
                    r.advisoryGasLimit,
                    32,
                    true
                ),
                (bool)
            );
            if (!allowed) revert SwapRejected();
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @inheritdoc IHooks
    /// @notice Refuses principal removal while the Rules guard makes one LP exclusive. Fee collection is always allowed.
    ///         On a lane pool HookrLane first donates the released part of a pending recapture LP share, before the
    ///         removal lands.
    /// @dev The lock was read from Rules at initialization and bounded there; no module is called on removal.
    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        external
        onlyManager
        returns (bytes4)
    {
        if (HookrRootStorage.tget(ACTIVE) != 0 || HookrRootStorage.tget(BINDING) != 0) revert ReentrantCallback();
        if (params.liquidityDelta == 0) return IHooks.beforeRemoveLiquidity.selector;
        PoolId id = key.toId();
        HookrRootStorage.Record storage r = _record(id);
        uint256 until = r.lockedUntil;
        if (block.number < until) revert LiquidityLocked(id, until);
        if (r.laneLiquidity) _lane(0);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @inheritdoc IHooks
    /// @notice Authenticates the route, quotes bounded fees and reserves specified-side charges.
    /// @dev Exact-input buys reserve the quote take on the specified input. Exact-output buys with a burn reserve
    ///      ceil(S * b / (BPS - b)) extra subject on the specified output, so the caller still nets S. Exact-output
    ///      sells reserve ceil(Q * t / (PIPS - t)) extra quote for the quote take t, so the caller still nets Q.
    ///      From `feeOnlyFrom` the Rules module is not called and nothing is reserved. The pool's stored LP fee (the
    ///      base fee set at initialization) applies, overridden only by a nonzero advisory surcharge. On a dynamic fee
    ///      pool the advisory is consulted first, the swap is simulated net of the charges Rules and the advisory
    ///      quote without the dynamic fee, and Rules quote the dynamic fee on the simulated outcome. A recapture executor
    ///      leg (HookrLane._enter) on a pool with an advisory takes this path as an unauthenticated swap of the
    ///      executor with no Rules quote, no lane op and no dynamic fee: it pays the advisory's surcharge as LP fee and
    ///      its take in the pool's quote, credited through IHookrLaneRules.settleLeg; a leg on a pool without one pays
    ///      the base LP fee and returns before it. Either leg on a dynamic fee pool is charged no dynamic fee, and its
    ///      afterSwap has HookrLane carry the pool's dynamic fee state as an ordinary swap would (`_carryLeg`).
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 active = HookrRootStorage.tget(ACTIVE);
        uint256 leg;
        if (active != 0 || HookrRootStorage.tget(BINDING) != 0) {
            // Only an open arb recapture's executor swaps inside another swap (HookrLane._enter): a leg returns its
            // base LP fee, with bit 24 set when the pool has an advisory. An unadvised leg pays that fee alone; an
            // advised one goes on here, asked and charged by the advisory as an unauthenticated swap, and runs no rule.
            leg = _lane(HookrRootStorage.OP_ENTER | (active << 8));
            if (leg != 0 && leg >> 24 == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), uint24(leg));
        }
        uint256 requested = _magnitude(params.amountSpecified);
        if (requested == 0 || requested > uint256(uint128(type(int128).max))) revert AmountOutOfRange();
        PoolId id = key.toId();
        HookrRootStorage.Record storage r = _record(id);
        HookrRootStorage.tput(ACTIVE, active + 1);
        HookrRootStorage.tput(RECEIPT_OWNER, 0);
        Frame memory f;
        f.context = _context(key, params, sender, id, r);
        f.receiptRequested = _identity(f.context, data);
        uint256 feeOnly = r.feeOnlyFrom;
        if (feeOnly != 0 && block.number >= feeOnly) {
            uint24 overrideFee;
            f.lpFee = r.baseLpFeePips;
            if (r.advisoryPhases & HookrTypes.BEFORE_SWAP != 0) {
                uint256 cap = r.capLp;
                f.advice = _advice(r, f.context, 0, 0, false, cap - f.lpFee);
                uint256 advised = uint256(f.lpFee) + f.advice.lpFeeSurchargePips;
                if (advised > cap) revert AggregateCapExceeded();
                if (f.advice.reject) revert SwapRejected();
                if (f.advice.lpFeeSurchargePips != 0) {
                    f.lpFee = uint24(advised);
                    overrideFee = f.lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
                }
            }
            _writeFrame(f, active == 0 ? FRAME_FEE_ONLY : FRAME_FEE_ONLY | FRAME_NESTED);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), overrideFee);
        }
        // An advised leg runs no lane op, no ledger mark, no dynamic fee simulation and no Rules quote.
        uint256 mode = leg == 0 ? r.mode : 0;
        // Frame flags: FRAME_NESTED for the executor's swap inside an arb recapture that takes the full path or is an
        // advised leg (FRAME_LEG too), FRAME_LANE for an outer swap on a lane pool whose switch was on, whose afterSwap
        // runs the after-phase arb recapture.
        uint256 flags = active == 0 ? 0 : (leg == 0 ? FRAME_NESTED : FRAME_NESTED | FRAME_LEG);
        if (mode & HookrRootStorage.MODE_LANE != 0) {
            // A lane pool is never fee-only. The before-phase arb recapture runs before Rules quote, so the quote and a
            // dynamic fee simulation see the pool after the arb recapture. It returns the live gas cap the after-phase
            // reuses.
            uint256 op = (active == 0 ? HookrRootStorage.OP_RUN : 0)
                | (mode & HookrRootStorage.MODE_LEDGER != 0 ? HookrRootStorage.OP_MARK : 0);
            // The payer above bit 8 keys the multi-lane gas check to one payer's route (HookrLane._laneGas).
            if (op != 0 && _lane(op | uint256(uint160(f.context.payer)) << 8) != 0) {
                flags = FRAME_LANE;
                _refuseMev(key, r, sender, params.zeroForOne);
            }
        }
        bool dynamicFee = mode & HookrRootStorage.MODE_DYNAMIC_FEE != 0;
        if (dynamicFee) {
            _dynamicFeeQuote(key, params, f, requested);
        } else if (leg == 0) {
            f.rules = abi.decode(
                _required(r.rules, abi.encodeCall(IHookrRules.beforeSwap, (f.context)), r.rulesGasLimit, 96, false),
                (HookrTypes.FeeQuote)
            );
        }
        // The Rules admission cap bounds the total native LP fee, as bind already enforces.
        uint256 nativeFee = uint256(r.baseLpFeePips) + f.rules.lpFeeSurchargePips;
        if (
            nativeFee > r.rulesCapLp || f.rules.quoteTakePips > r.rulesCapQuote
                || f.rules.subjectBurnBps > r.rulesCapSubject
        ) revert InvalidModuleResult(r.rules);
        if (nativeFee > r.capLp) revert AggregateCapExceeded();
        if (!dynamicFee && r.advisoryPhases & HookrTypes.BEFORE_SWAP != 0) {
            f.advice = _advice(r, f.context, 0, 0, false, r.capLp - nativeFee);
        }
        uint256 fee = nativeFee + f.advice.lpFeeSurchargePips;
        uint256 rate = uint256(f.rules.quoteTakePips) + f.advice.quoteTakePips;
        if (fee > r.capLp || rate > r.capQuote || f.rules.subjectBurnBps > r.capSubject) {
            revert AggregateCapExceeded();
        }
        if (f.advice.reject) revert SwapRejected();
        if (!f.context.isBuy) {
            if (f.rules.subjectBurnBps != 0) revert InvalidModuleResult(r.rules);
            if (!f.context.exactInput && rate != 0) {
                f.reserved = (requested * rate + (PIPS - rate) - 1) / (PIPS - rate);
                if (requested + f.reserved > uint256(uint128(type(int128).max))) revert AmountOutOfRange();
            }
        } else if (f.context.exactInput) {
            f.reserved = requested * rate / PIPS;
        } else if (f.rules.subjectBurnBps != 0) {
            uint256 b = f.rules.subjectBurnBps;
            f.reserved = (requested * b + (10_000 - b) - 1) / (10_000 - b);
            if (requested + f.reserved > uint256(uint128(type(int128).max))) revert AmountOutOfRange();
        }
        f.lpFee = uint24(fee);
        _writeFrame(f, flags);
        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(int128(uint128(f.reserved)), 0),
            f.lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @inheritdoc IHooks
    /// @notice Reconciles actual fills, backs claims and applies permitted burns. Nothing is donated or held.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyManager returns (bytes4, int128) {
        uint256 active = HookrRootStorage.tget(ACTIVE);
        if (active == 0) revert ReentrantCallback();
        if (active >= HookrRootStorage.LEG) {
            // An executor leg on a pool without an advisory: no rule, no charge beyond the base LP fee. On a dynamic fee
            // pool it carries the pool's dynamic fee state (`_carryLeg`).
            // ACTIVE was 1 when the leg entered (HookrLane._enter): back to 1, the leg's LEG and LEG_DYNAMIC cleared.
            HookrRootStorage.tput(ACTIVE, active & (HookrRootStorage.LEG - 1));
            if (active >= HookrRootStorage.LEG_DYNAMIC) _carryLeg(0);
            return (IHooks.afterSwap.selector, 0);
        }
        PoolId id = key.toId();
        (Frame memory f, uint256 flags) = _readFrame(id, sender, params);
        HookrRootStorage.Record storage r = _record(id);
        bool quoteIs0 = r.quoteIsCurrency0;
        Currency quote = quoteIs0 ? key.currency0 : key.currency1;
        f.context.subject = quoteIs0 ? key.currency1 : key.currency0;
        f.context.quote = quote;
        f.context.baseLpFeePips = r.baseLpFeePips;
        f.context.isBuy = params.zeroForOne == quoteIs0;
        (int128 quoteDelta, int128 subjectDelta) =
            quoteIs0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (
            (f.context.isBuy && (quoteDelta > 0 || subjectDelta < 0))
                || (!f.context.isBuy && (quoteDelta < 0 || subjectDelta > 0))
        ) revert InvalidPool();
        HookrTypes.Settlement memory z;
        z.actualQuote = _magnitude(quoteDelta);
        z.actualSubject = _magnitude(subjectDelta);
        if (flags & FRAME_FEE_ONLY != 0) {
            if (r.advisoryPhases & HookrTypes.AFTER_SWAP != 0) {
                // The advisory is admitted without a quote take, so an after-phase take already reverted.
                HookrTypes.Advice memory late = _advice(r, f.context, delta.amount0(), delta.amount1(), true, 0);
                if (late.lpFeeSurchargePips != 0 || late.reject) revert InvalidModuleResult(r.advisory);
            }
            if (f.receiptRequested) _receipt(r, f, z, 0);
            HookrRootStorage.tput(ACTIVE, flags & FRAME_NESTED == 0 ? 0 : 1);
            return (IHooks.afterSwap.selector, 0);
        }
        HookrTypes.Advice memory afterAdvice;
        if (r.advisoryPhases & HookrTypes.AFTER_SWAP != 0) {
            afterAdvice = _advice(r, f.context, delta.amount0(), delta.amount1(), true, 0);
            if (
                afterAdvice.lpFeeSurchargePips != 0 || afterAdvice.reject
                    || (afterAdvice.quoteTakePips != 0 && f.context.isBuy == f.context.exactInput)
            ) {
                revert InvalidModuleResult(r.advisory);
            }
            if (
                afterAdvice.quoteTakePips != 0 && f.advice.quoteTakePips != 0
                    && afterAdvice.recipient != f.advice.recipient
            ) revert InvalidModuleResult(r.advisory);
        }
        uint256 advisoryRate = uint256(f.advice.quoteTakePips) + afterAdvice.quoteTakePips;
        uint256 rate = uint256(f.rules.quoteTakePips) + advisoryRate;
        if (advisoryRate > r.advisoryCapQuote || rate > r.capQuote) {
            revert AggregateCapExceeded();
        }
        z.advisoryRecipient = afterAdvice.quoteTakePips != 0 ? afterAdvice.recipient : f.advice.recipient;
        uint256 totalFee;
        if (f.context.isBuy) {
            z.quoteBasis = z.actualQuote * PIPS / (PIPS - rate);
            if (f.context.exactInput) {
                uint256 requested = uint256(-f.context.amountSpecified);
                if (z.actualQuote > requested - f.reserved) revert InvalidPool();
                if (z.quoteBasis > requested) z.quoteBasis = requested;
                totalFee = z.quoteBasis - z.actualQuote;
                if (totalFee > f.reserved) revert InvalidPool();
                z.refund = f.reserved - totalFee;
                z.subjectBurn = z.actualSubject * f.rules.subjectBurnBps / 10_000;
            } else {
                totalFee = z.quoteBasis - z.actualQuote;
                z.subjectBurn = f.reserved;
                uint256 required = uint256(f.context.amountSpecified) + f.reserved;
                if (f.reserved != 0 && z.actualSubject != required) {
                    revert ExactOutputShortfall(z.actualSubject, required);
                }
            }
        } else if (f.context.exactInput) {
            z.quoteBasis = z.actualQuote;
            totalFee = z.quoteBasis * rate / PIPS;
        } else {
            z.quoteBasis = z.actualQuote;
            totalFee = f.reserved;
            uint256 required = uint256(f.context.amountSpecified) + f.reserved;
            if (f.reserved != 0 && z.actualQuote != required) revert ExactOutputShortfall(z.actualQuote, required);
        }
        if (f.context.isBuy || f.context.exactInput) {
            z.rulesFee = z.quoteBasis * f.rules.quoteTakePips / PIPS;
        } else if (rate != 0) {
            // The reserved take splits by rate, so a Rules-only take leaves no advisory remainder.
            z.rulesFee = totalFee * f.rules.quoteTakePips / rate;
        }
        z.advisoryFee = totalFee - z.rulesFee;
        if (!f.context.authenticated && z.refund != 0) revert UnauthenticatedRefund(id, z.refund);
        uint256 quoteTaken = totalFee + z.refund;
        uint256 credited;
        if (flags & FRAME_LEG == 0) {
            credited = abi.decode(
                _required(r.rules, abi.encodeCall(IHookrRules.settleSwap, (f.context, z)), r.rulesGasLimit, 32, false),
                (uint256)
            );
        } else {
            // An advised leg: the advisory's take alone (no Rules take; a refund already reverted), credited to its
            // recipient. On a dynamic fee pool it carries the pool's dynamic fee state (`_carryLeg`).
            if (quoteTaken != 0) {
                credited = abi.decode(
                    _required(
                        r.rules,
                        abi.encodeCall(IHookrLaneRules.settleLeg, (id, z.advisoryRecipient, quoteTaken)),
                        r.rulesGasLimit,
                        32,
                        false
                    ),
                    (uint256)
                );
            }
            if (r.mode & HookrRootStorage.MODE_DYNAMIC_FEE != 0) _carryLeg(f.lpFee);
        }
        if (credited != quoteTaken) revert InvalidModuleResult(r.rules);
        if (quoteTaken != 0) poolManager.mint(r.rules, quote.toId(), quoteTaken);
        if (z.subjectBurn != 0) {
            Currency subject = f.context.subject;
            if (poolManager.getSyncedCurrency() == subject) revert UnsupportedBurnSync();
            uint256 managerBefore = subject.balanceOf(address(poolManager));
            uint256 deadBefore = subject.balanceOf(DEAD);
            poolManager.take(subject, DEAD, z.subjectBurn);
            uint256 managerAfter = subject.balanceOf(address(poolManager));
            uint256 deadAfter = subject.balanceOf(DEAD);
            if (
                managerAfter > managerBefore || managerBefore - managerAfter != z.subjectBurn || deadAfter < deadBefore
                    || deadAfter - deadBefore != z.subjectBurn
            ) revert UnsupportedTokenTransfer();
        }
        if (flags & FRAME_LANE != 0) {
            _lane(uint256(uint160(f.context.authenticated ? f.context.payer : address(0))) << 8);
        }
        if (f.receiptRequested) _receipt(r, f, z, totalFee);
        emit HookFee(id, quote, totalFee, z.refund, z.subjectBurn);
        HookrRootStorage.tput(ACTIVE, flags & FRAME_NESTED == 0 ? 0 : 1);
        // Exact-output sells took their quote fee on the specified side in beforeSwap.
        uint256 unspecified =
            f.context.exactInput ? (f.context.isBuy ? z.subjectBurn : totalFee) : (f.context.isBuy ? totalFee : 0);
        if (unspecified > uint256(uint128(type(int128).max))) revert AmountOutOfRange();
        return (IHooks.afterSwap.selector, int128(uint128(unspecified)));
    }

    /// @notice Called with no data, returns 1: this root simulates the swaps of pools with Hookr dynamic fees. Every
    ///         other use is the root's own, from `beforeSwap`.
    /// @dev With `abi.encode(PoolKey, SwapParams, uint24)`, runs that swap on the PoolManager at that LP fee and reverts
    ///      `SwapSimulated` with its outcome: the PoolManager does not call a hook for a swap the hook starts, and the
    ///      revert rolls back every state change. A swap that runs out of liquidity ends at its price limit; a 1-wei
    ///      swap back crosses the empty range for free and stops at the last price with liquidity. With the dynamic
    ///      fee quote input, quotes the swap and returns the Rules quote and the advice. With the lane frame input,
    ///      runs HookrLane's frame. From any other caller, `laneModule()` answers from this root's code and every
    ///      other call is HookrLane's lane surface (`settleRecapture`, `laneOf`, `sameTxLiquidityOnPath`). A
    ///      fallback rather than functions, so the dispatcher and the code of every other call stay as they were.
    fallback(bytes calldata input) external returns (bytes memory) {
        if (msg.sender != address(this)) {
            if (input.length == 0) return abi.encode(uint256(1));
            // IHookrLaneRoot.laneModule, from this root's own code.
            if (input.length == 4 && bytes4(input) == IHookrLaneRoot.laneModule.selector) {
                return abi.encode(lane, laneCodeHash);
            }
            // HookrLane's settleRecapture (the executor's push), laneOf and sameTxLiquidityOnPath.
            _forward();
        }
        if (HookrRootStorage.tget(ACTIVE) == 0) revert Unauthorized();
        if (input.length == QUOTE_INPUT) return _quoteDynamicFee(input);
        if (input.length != SIMULATION_INPUT) {
            // The lane frame (HookrLane's fallback).
            if (input.length == LANE_INPUT) _forward();
            revert InvalidHookData();
        }
        PoolKey memory key;
        SwapParams memory params;
        uint24 lpFeePips;
        // The root wrote the input in `_simulate`: every field is a clean word, in struct order.
        assembly ("memory-safe") {
            calldatacopy(key, 0, 160)
            calldatacopy(params, 160, 96)
            lpFeePips := calldataload(256)
        }
        PoolId id = key.toId();
        (uint160 sqrtBefore, int24 tickBefore,, uint24 storedFee) = StateLibrary.getSlot0(poolManager, id);
        if (lpFeePips != storedFee) poolManager.updateDynamicLPFee(key, lpFeePips);
        uint160 sqrtAfter;
        int24 tickAfter;
        while (true) {
            poolManager.swap(key, params, "");
            (sqrtAfter, tickAfter,,) = StateLibrary.getSlot0(poolManager, id);
            // The swap back has sqrtBefore as its limit; the swap itself cannot (the PoolManager refuses it).
            if (
                sqrtAfter != params.sqrtPriceLimitX96 || sqrtAfter == sqrtBefore
                    || StateLibrary.getLiquidity(poolManager, id) != 0
            ) break;
            params.zeroForOne = !params.zeroForOne;
            params.amountSpecified = -1;
            params.sqrtPriceLimitX96 = sqrtBefore;
        }
        revert SwapSimulated(sqrtBefore, tickBefore, sqrtAfter, tickAfter);
    }

    /// @inheritdoc IHookrRoot
    /// @notice Consumes the current swap receipt once. Only the pinned router or quoter can call.
    function takeReceipt(PoolId id) external returns (HookrTypes.ExecutionReceipt memory result) {
        if (msg.sender != router && msg.sender != quoter) revert Unauthorized();
        if (HookrRootStorage.tget(ACTIVE) != 0 || HookrRootStorage.tget(RECEIPT_OWNER) != uint256(uint160(msg.sender)))
        {
            revert NoReceipt();
        }
        if (HookrRootStorage.tget(RECEIPT) != uint256(PoolId.unwrap(id))) revert NoReceipt();
        uint256 base = uint256(RECEIPT);
        uint256 w = HookrRootStorage.tget(bytes32(base + 2));
        result.id = id;
        result.policyHash = bytes32(HookrRootStorage.tget(bytes32(base + 1)));
        result.payer = address(uint160(w));
        result.lpFeePips = uint24(w >> 160);
        result.beneficiary = address(uint160(HookrRootStorage.tget(bytes32(base + 3))));
        result.inputCurrency = Currency.wrap(address(uint160(HookrRootStorage.tget(bytes32(base + 4)))));
        result.outputCurrency = Currency.wrap(address(uint160(HookrRootStorage.tget(bytes32(base + 5)))));
        w = HookrRootStorage.tget(bytes32(base + 6));
        (result.inputAmount, result.outputAmount) = (uint128(w), w >> 128);
        w = HookrRootStorage.tget(bytes32(base + 7));
        (result.actualQuote, result.quoteFee) = (uint128(w), w >> 128);
        w = HookrRootStorage.tget(bytes32(base + 8));
        (result.quoteRefund, result.subjectBurn) = (uint128(w), w >> 128);
        HookrRootStorage.tput(RECEIPT_OWNER, 0);
    }

    /// @dev Nine transient words: id, policy hash, payer with the LP fee above bit 160, beneficiary, input and output
    ///      currencies, then inputAmount, actualQuote and quoteRefund in the low 128 bits of three words whose high
    ///      128 bits hold outputAmount, quoteFee and subjectBurn. Every amount is bounded by the PoolManager's int128
    ///      deltas; a wider one reverts rather than truncates.
    function _receipt(HookrRootStorage.Record storage r, Frame memory f, HookrTypes.Settlement memory z, uint256 fee)
        private
    {
        uint256 input = f.context.isBuy ? z.actualQuote : z.actualSubject;
        uint256 output = f.context.isBuy ? z.actualSubject : z.actualQuote;
        if (f.context.isBuy) {
            input += f.context.exactInput ? f.reserved : fee;
            output -= z.subjectBurn;
        } else {
            output -= fee;
        }
        if ((input | output | z.actualQuote | fee | z.refund | z.subjectBurn) > type(uint128).max) {
            revert AmountOutOfRange();
        }
        (Currency inputCurrency, Currency outputCurrency) =
            f.context.isBuy ? (f.context.quote, f.context.subject) : (f.context.subject, f.context.quote);
        uint256 base = uint256(RECEIPT);
        HookrRootStorage.tput(RECEIPT, uint256(PoolId.unwrap(f.context.id)));
        HookrRootStorage.tput(bytes32(base + 1), uint256(r.policy));
        HookrRootStorage.tput(bytes32(base + 2), uint256(uint160(f.context.payer)) | (uint256(f.lpFee) << 160));
        HookrRootStorage.tput(bytes32(base + 3), uint256(uint160(f.context.beneficiary)));
        HookrRootStorage.tput(bytes32(base + 4), uint256(uint160(Currency.unwrap(inputCurrency))));
        HookrRootStorage.tput(bytes32(base + 5), uint256(uint160(Currency.unwrap(outputCurrency))));
        HookrRootStorage.tput(bytes32(base + 6), input | (output << 128));
        HookrRootStorage.tput(bytes32(base + 7), z.actualQuote | (fee << 128));
        HookrRootStorage.tput(bytes32(base + 8), z.refund | (z.subjectBurn << 128));
        HookrRootStorage.tput(RECEIPT_OWNER, uint256(uint160(f.context.sender)));
    }

    /// @dev The authenticated identity is the immediate caller: the pinned Router's or Quoter's msg.sender as encoded
    ///      in hook data, or the locker the curated router reports through msgSender(). Relayers and aggregators that
    ///      call either router are the payer and receive refunds and attribution. A curated router whose msgSender()
    ///      fails or returns an invalid word reverts the swap; it is never downgraded to an unauthenticated swap.
    function _identity(HookrTypes.SwapContext memory x, bytes calldata data) private returns (bool wantsReceipt) {
        if (x.sender == router || x.sender == quoter) {
            bytes32 expected = x.sender == router ? routerCodeHash : quoterCodeHash;
            if (x.sender.codehash != expected || data.length != 128) revert InvalidHookData();
            PoolId supplied;
            (x.payer, x.beneficiary, supplied, wantsReceipt) = abi.decode(data, (address, address, PoolId, bool));
            if (x.payer == address(0) || x.beneficiary == address(0) || PoolId.unwrap(supplied) != PoolId.unwrap(x.id)) revert InvalidHookData();
            x.authenticated = true;
        } else {
            if (data.length != 0) revert InvalidHookData();
            if (x.sender == curatedRouter && curatedRouter != address(0)) {
                if (x.sender.codehash != curatedRouterCodeHash) revert InvalidHookData();
                (bool ok, bytes memory result,) =
                    HookrRootStorage.bounded(x.sender, abi.encodeWithSignature("msgSender()"), 30_000, 32, true);
                uint256 word = ok ? abi.decode(result, (uint256)) : 0;
                if (word == 0 || word > type(uint160).max) revert InvalidHookData();
                x.payer = address(uint160(word));
                x.beneficiary = x.payer;
                x.authenticated = true;
            }
        }
    }

    /// @dev An unauthenticated swap's context: `sender` as payer and beneficiary.
    function _context(
        PoolKey calldata key,
        SwapParams calldata params,
        address sender,
        PoolId id,
        HookrRootStorage.Record storage r
    ) private view returns (HookrTypes.SwapContext memory) {
        bool quoteIs0 = r.quoteIsCurrency0;
        return HookrTypes.SwapContext({
            id: id,
            sender: sender,
            payer: sender,
            beneficiary: sender,
            subject: quoteIs0 ? key.currency1 : key.currency0,
            quote: quoteIs0 ? key.currency0 : key.currency1,
            authenticated: false,
            isBuy: params.zeroForOne == quoteIs0,
            exactInput: params.amountSpecified < 0,
            zeroForOne: params.zeroForOne,
            amountSpecified: params.amountSpecified,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            baseLpFeePips: r.baseLpFeePips
        });
    }

    function _advice(
        HookrRootStorage.Record storage r,
        HookrTypes.SwapContext memory x,
        int128 amount0,
        int128 amount1,
        bool afterPhase,
        uint256 fallbackRoom
    ) private returns (HookrTypes.Advice memory advice) {
        bytes memory input = afterPhase
            ? abi.encodeCall(IHookrAdvisory.afterSwap, (x, amount0, amount1))
            : abi.encodeCall(IHookrAdvisory.beforeSwap, (x));
        (bool ok, bytes memory output, bool reverted) =
            HookrRootStorage.bounded(r.advisory, input, r.advisoryGasLimit, 128, true);
        if (ok) {
            uint256 lp;
            uint256 take;
            uint256 recipient;
            uint256 reject;
            assembly ("memory-safe") {
                lp := mload(add(output, 32))
                take := mload(add(output, 64))
                recipient := mload(add(output, 96))
                reject := mload(add(output, 128))
            }
            ok = lp <= type(uint24).max && take <= type(uint24).max && recipient <= type(uint160).max && reject <= 1;
        }
        if (!ok) {
            if (!r.advisoryFailOpen) HookrRootStorage.revertModuleCall(r.advisory, input, reverted);
            if (!afterPhase) {
                uint256 ceiling = r.advisoryCapLp;
                advice.lpFeeSurchargePips = uint24(ceiling < fallbackRoom ? ceiling : fallbackRoom);
            }
            return advice;
        }
        advice = abi.decode(output, (HookrTypes.Advice));
        if (
            advice.lpFeeSurchargePips > r.advisoryCapLp || advice.quoteTakePips > r.advisoryCapQuote
                || (advice.quoteTakePips != 0 && advice.recipient == address(0))
                || (r.advisoryFailOpen && (advice.reject || advice.quoteTakePips != 0))
        ) revert InvalidModuleResult(r.advisory);
    }

    /// @dev Quotes a dynamic fee pool in a call to the root's own fallback and writes the Rules quote and the advice
    ///      into the frame. The input is the swap's PoolKey and SwapParams as the PoolManager passed them, the context
    ///      and the requested amount.
    function _dynamicFeeQuote(PoolKey calldata key, SwapParams calldata, Frame memory f, uint256 requested) private {
        bytes memory context = abi.encodeCall(IHookrRules.beforeSwap, (f.context));
        bytes memory payload = new bytes(QUOTE_INPUT);
        assembly ("memory-safe") {
            // The SwapParams follow the PoolKey in the hook's calldata.
            calldatacopy(add(payload, 32), key, 256)
            mcopy(add(payload, 288), add(context, 36), 416)
            mstore(add(payload, 704), requested)
        }
        (bool ok, bytes memory out) = address(this).call(payload);
        if (!ok || out.length != 224) {
            assembly ("memory-safe") {
                revert(add(out, 32), mload(out))
            }
        }
        HookrTypes.FeeQuote memory q = f.rules;
        HookrTypes.Advice memory a = f.advice;
        assembly ("memory-safe") {
            mcopy(q, add(out, 32), 96)
            mcopy(a, add(out, 128), 128)
        }
    }

    /// @dev The charges without the dynamic fee, the advisory, then the swap simulated net of both at their LP fee,
    ///      and the Rules quote priced on its outcome. Returns seven words: the quote, range-checked, and the advice.
    function _quoteDynamicFee(bytes calldata input) private returns (bytes memory) {
        PoolKey memory key;
        SwapParams memory params;
        HookrTypes.SwapContext memory x;
        uint256 requested;
        // The root wrote the input in `_dynamicFeeQuote`: every field is a clean word, in struct order.
        assembly ("memory-safe") {
            calldatacopy(key, input.offset, 160)
            calldatacopy(params, add(input.offset, 160), 96)
            calldatacopy(x, add(input.offset, 256), 416)
            requested := calldataload(add(input.offset, 672))
        }
        HookrRootStorage.Record storage r = _record(x.id);
        (uint256 preLp, uint256 preTake, uint256 preBurn) = abi.decode(
            _required(r.rules, abi.encodeCall(IHookrDynamicFeeRules.simulationQuote, (x)), r.rulesGasLimit, 96, true),
            (uint256, uint256, uint256)
        );
        uint256 fee = uint256(r.baseLpFeePips) + preLp;
        if (fee > r.capLp) revert AggregateCapExceeded();
        HookrTypes.Advice memory advice;
        if (r.advisoryPhases & HookrTypes.BEFORE_SWAP != 0) {
            advice = _advice(r, x, 0, 0, false, r.capLp - fee);
            fee += advice.lpFeeSurchargePips;
        }
        uint256 reserved = _reserve(x, requested, preTake + advice.quoteTakePips, preBurn);
        params.amountSpecified = x.exactInput ? -int256(requested - reserved) : int256(requested + reserved);
        HookrTypes.SwapSimulation memory m = _simulate(key, params, fee);
        (uint256 lp, uint256 take, uint256 burn) = abi.decode(
            _required(
                r.rules, abi.encodeCall(IHookrDynamicFeeRules.quoteSimulatedSwap, (x, m)), r.rulesGasLimit, 96, false
            ),
            (uint256, uint256, uint256)
        );
        if (lp > type(uint24).max || take > type(uint24).max || burn > type(uint16).max) {
            revert InvalidModuleResult(r.rules);
        }
        return abi.encode(lp, take, burn, advice);
    }

    /// @dev Runs the simulation in a frame that always reverts and decodes its outcome. Any other revert, including one
    ///      the real swap would also hit and running out of gas, is re-thrown.
    function _simulate(PoolKey memory key, SwapParams memory params, uint256 lpFee)
        private
        returns (HookrTypes.SwapSimulation memory m)
    {
        (bool ok, bytes memory out) = address(this).call(abi.encode(key, params, uint24(lpFee)));
        if (ok || out.length != 132 || bytes4(out) != SwapSimulated.selector) {
            assembly ("memory-safe") {
                revert(add(out, 32), mload(out))
            }
        }
        assembly ("memory-safe") {
            mstore(m, mload(add(out, 36)))
            mstore(add(m, 32), signextend(2, mload(add(out, 68))))
            mstore(add(m, 64), mload(add(out, 100)))
            mstore(add(m, 96), signextend(2, mload(add(out, 132))))
        }
    }

    /// @dev Specified-side reservation for quote take `rate` and burn `burnBps`, as described on `beforeSwap`.
    function _reserve(HookrTypes.SwapContext memory x, uint256 requested, uint256 rate, uint256 burnBps)
        private
        pure
        returns (uint256 reserved)
    {
        if (!x.isBuy) {
            if (!x.exactInput && rate != 0) reserved = (requested * rate + (PIPS - rate) - 1) / (PIPS - rate);
        } else if (x.exactInput) {
            reserved = requested * rate / PIPS;
        } else if (burnBps != 0) {
            reserved = (requested * burnBps + (10_000 - burnBps) - 1) / (10_000 - burnBps);
        }
        if (!x.exactInput && requested + reserved > uint256(uint128(type(int128).max))) revert AmountOutOfRange();
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

    /// @dev Asks the pool's frozen lane executor whether this swap is closing an arbitrage inside a v3 pool's callback
    ///      (`checkV3PoolsMev(subject, quote, sender, zeroForOne)`, `sender` the caller of PoolManager.swap and
    ///      `zeroForOne` the swap's own direction on this pool in its key's order, true for currency0 in and currency1
    ///      out), by staticcall with at most MEV_CHECK_GAS, and refuses the swap on a clean single true word
    ///      (MevCallbackRefused). Only on an outer swap whose before-phase lane call ran, after it: the lane was
    ///      switched on and the executor's code was the frozen one, so a braked or changed executor is never asked. A
    ///      revert, a missing function (a view of another signature included), a short or long return or any other
    ///      word lets the swap go on, so an executor that stops answering cannot stop a pool. The gas it spends is part
    ///      of the swap's own work between the lane calls (HookrLane.LANE_BODY).
    function _refuseMev(PoolKey calldata key, HookrRootStorage.Record storage r, address sender, bool zeroForOne)
        private
        view
    {
        Currency quote = r.quote;
        Currency subject = key.currency0 == quote ? key.currency1 : key.currency0;
        bytes memory input = abi.encodeWithSelector(MEV_CHECK, subject, quote, sender, zeroForOne);
        address executor = r.laneExecutor;
        bool ok;
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(MEV_CHECK_GAS, executor, add(input, 32), mload(input), 0, 32)
            size := returndatasize()
            word := mload(0)
        }
        if (ok && size == 32 && word == 1) revert MevCallbackRefused(Currency.unwrap(subject), Currency.unwrap(quote));
    }

    /// @dev DELEGATECALLs HookrLane with this call's calldata and `op` appended; bubbles a revert; returns the first
    ///      returned word, zero when none.
    function _lane(uint256 op) private returns (uint256 word) {
        address target = lane;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            mstore(add(ptr, calldatasize()), op)
            let ok := delegatecall(gas(), target, ptr, add(calldatasize(), 32), 0, 32)
            if iszero(ok) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            if gt(returndatasize(), 31) { word := mload(0) }
        }
    }

    /// @dev An executor leg on a dynamic fee pool, from afterSwap: DELEGATECALLs HookrLane.updateLegDynamicFee with this
    ///      afterSwap's calldata under that selector and the leg's LP fee `lpFee` appended (zero: the pool's base fee).
    ///      The carry charges nothing and never fails the leg: its failure is ignored and leaves the state as it was.
    function _carryLeg(uint256 lpFee) private {
        address target = lane;
        bytes4 selector = CARRY_LEG;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            mstore(ptr, or(and(selector, shl(224, 0xffffffff)), and(mload(ptr), shr(32, not(0)))))
            mstore(add(ptr, calldatasize()), lpFee)
            pop(delegatecall(gas(), target, ptr, add(calldatasize(), 32), 0, 0))
        }
    }

    /// @dev DELEGATECALLs HookrLane with this call's calldata unchanged and returns or reverts with its returndata.
    function _forward() private {
        address target = lane;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := delegatecall(gas(), target, ptr, calldatasize(), 0, 0)
            returndatacopy(ptr, 0, returndatasize())
            if iszero(ok) { revert(ptr, returndatasize()) }
            return(ptr, returndatasize())
        }
    }

    function _record(PoolId id) private view returns (HookrRootStorage.Record storage r) {
        r = _state().pools[id];
        if (!r.initialized) revert InvalidPool();
    }

    function _magnitude(int256 value) private pure returns (uint256) {
        if (value == type(int256).min) revert AmountOutOfRange();
        return value < 0 ? uint256(-value) : uint256(value);
    }

    function _state() private pure returns (HookrRootStorage.State storage s) {
        return HookrRootStorage.state();
    }

    function _binding(PoolId id, address sender, bool zeroForOne, int256 amountSpecified, uint160 limit)
        private
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encode(id, sender, zeroForOne, amountSpecified, limit)));
    }

    /// @dev Word 0 binds the swap shape; word 1 payer, flags, LP fee and burn; word 2 beneficiary and quote takes;
    ///      words 3-4 advisory recipient and reserve, written and read only off the fee-only path.
    function _writeFrame(Frame memory f, uint256 flags) private {
        HookrTypes.SwapContext memory x = f.context;
        uint256 base = uint256(FRAME);
        HookrRootStorage.tput(FRAME, _binding(x.id, x.sender, x.zeroForOne, x.amountSpecified, x.sqrtPriceLimitX96));
        HookrRootStorage.tput(
            bytes32(base + 1),
            uint256(uint160(x.payer)) | (x.authenticated ? FRAME_AUTHENTICATED : 0)
                | (f.receiptRequested ? FRAME_RECEIPT : 0) | flags | (uint256(f.lpFee) << 168)
                | (uint256(f.rules.subjectBurnBps) << 192)
        );
        HookrRootStorage.tput(
            bytes32(base + 2),
            uint256(uint160(x.beneficiary)) | (uint256(f.rules.quoteTakePips) << 160)
                | (uint256(f.advice.quoteTakePips) << 184)
        );
        if (flags & FRAME_FEE_ONLY == 0) {
            HookrRootStorage.tput(bytes32(base + 3), uint256(uint160(f.advice.recipient)));
            HookrRootStorage.tput(bytes32(base + 4), f.reserved);
        }
    }

    /// @dev Reverts unless the frame was written for exactly this pool, sender and swap parameters. Subject, quote,
    ///      base fee and direction are re-derived from the pool record by the caller.
    function _readFrame(PoolId id, address sender, SwapParams calldata params)
        private
        view
        returns (Frame memory f, uint256 flags)
    {
        if (
            HookrRootStorage.tget(FRAME)
                != _binding(id, sender, params.zeroForOne, params.amountSpecified, params.sqrtPriceLimitX96)
        ) {
            revert ReentrantCallback();
        }
        uint256 base = uint256(FRAME);
        uint256 w1 = HookrRootStorage.tget(bytes32(base + 1));
        uint256 w2 = HookrRootStorage.tget(bytes32(base + 2));
        f.context.id = id;
        f.context.sender = sender;
        f.context.payer = address(uint160(w1));
        f.context.beneficiary = address(uint160(w2));
        f.context.authenticated = w1 & FRAME_AUTHENTICATED != 0;
        f.context.exactInput = params.amountSpecified < 0;
        f.context.zeroForOne = params.zeroForOne;
        f.context.amountSpecified = params.amountSpecified;
        f.context.sqrtPriceLimitX96 = params.sqrtPriceLimitX96;
        f.receiptRequested = w1 & FRAME_RECEIPT != 0;
        flags = w1 & (FRAME_FEE_ONLY | FRAME_LANE | FRAME_NESTED | FRAME_LEG);
        f.lpFee = uint24(w1 >> 168);
        f.rules.subjectBurnBps = uint16(w1 >> 192);
        f.rules.quoteTakePips = uint24(w2 >> 160);
        f.advice.quoteTakePips = uint24(w2 >> 184);
        if (flags & FRAME_FEE_ONLY == 0) {
            f.advice.recipient = address(uint160(HookrRootStorage.tget(bytes32(base + 3))));
            f.reserved = HookrRootStorage.tget(bytes32(base + 4));
        }
    }

    /// @inheritdoc IHooks
    /// @notice This callback is not enabled by the Hookr root permission flags.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyManager returns (bytes4) {
        revert UnsupportedCallback();
    }

    /// @inheritdoc IHooks
    /// @notice This callback is not enabled by the Hookr root permission flags.
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyManager returns (bytes4, BalanceDelta) {
        revert UnsupportedCallback();
    }

    /// @inheritdoc IHooks
    /// @notice This callback is not enabled by the Hookr root permission flags.
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyManager returns (bytes4, BalanceDelta) {
        revert UnsupportedCallback();
    }

    /// @inheritdoc IHooks
    /// @notice This callback is not enabled by the Hookr root permission flags.
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyManager
        returns (bytes4)
    {
        revert UnsupportedCallback();
    }

    /// @inheritdoc IHooks
    /// @notice This callback is not enabled by the Hookr root permission flags.
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyManager
        returns (bytes4)
    {
        revert UnsupportedCallback();
    }
}
