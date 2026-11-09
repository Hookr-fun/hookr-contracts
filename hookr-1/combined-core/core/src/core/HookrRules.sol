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
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRules} from "../interfaces/IHookrRules.sol";
import {IHookrRulesConfig} from "../interfaces/IHookrRulesConfig.sol";
import {IHookrFeeOnlyRules} from "../interfaces/IHookrFeeOnlyRules.sol";
import {IHookrDynamicFeeRules} from "../interfaces/IHookrDynamicFeeRules.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrDynamicFee} from "../libraries/HookrDynamicFee.sol";
import {HookrReleased} from "../base/HookrReleased.sol";


import {IHookrTreasury} from "../interfaces/IHookrTreasury.sol";
import {IHookrProtocolClaims} from "../interfaces/IHookrProtocolClaims.sol";
import {IHookrProtocolClaimsTransfer} from "../interfaces/IHookrProtocolClaimsTransfer.sol";
import {HookrTokenCodeHash} from "../libraries/HookrTokenCodeHash.sol";
import {IHookrRulesEvents} from "../interfaces/IHookrRulesEvents.sol";
import {IHookrRecaptureEvents} from "../interfaces/IHookrRecaptureEvents.sol";
import {IHookrRulesState} from "../interfaces/IHookrRulesState.sol";

import {IHookrRulesCore} from "../interfaces/IHookrRulesCore.sol";
import {IHookrLaneRules} from "../interfaces/IHookrLaneRules.sol";
import {IHookrRecaptureBind} from "../interfaces/IHookrRecaptureBind.sol";
import {IHookrBlock} from "../interfaces/IHookrBlock.sol";
import {HookrRulesStorage as S} from "../libraries/HookrRulesStorage.sol";
import {HookrBlockBound as B} from "../libraries/HookrBlockBound.sol";
import {HookrBlockCall as C} from "../libraries/HookrBlockCall.sol";
import {HookrBlockKeys} from "../libraries/HookrBlockKeys.sol";
import {HookrTime} from "../libraries/HookrTime.sol";
import {HookrViewSwap} from "../libraries/HookrViewSwap.sol";
import {HookrCoreState} from "../libraries/HookrCoreState.sol";
import {HookrWallets} from "../libraries/HookrWallets.sol";
import {HookrBlockKey} from "./HookrBlockKey.sol";

/// @title HookrRules
/// @notice Root-authenticated native fees, revision3 block dispatch and residual protocol accounting.
/// @dev RulesConfig.potEveryNBuys is the canonical hot carrier and potMinBuyQuote the cold carrier.
/// The linked Checks library performs bind-only admission; blocks add monotone quote words and carve
/// by one final Rules-take denominator. Recapture and Claims receive trustedRoot as the last calldata word.
/// Local dynamic simulation keeps raw/last-liquid/fee outcomes separate and uses the fee outcome for parity.
/// The quoted reference is transient until actual-fill settle commits reference and anchor together.
/// Protocol rule fees remain residual; every explicit claim/accrual/pot amount remains a liability.
/// Source-stage integration, exact templates, size and production-root proofs are tracked in CORE_STAGE.md.
contract HookrRules is HookrReleased, IHookrRulesCore, IHookrRulesConfig, IHookrFeeOnlyRules, IHookrDynamicFeeRules, IHookrRulesEvents, IHookrRecaptureEvents
{
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    bytes32 private constant SLOT = 0x762913e4bc0f59f7b08c82f07586fa48932548ab5fab99e6db0b09765b4ff900;
    /// @dev `poolFamily(bytes32)` (HookrLauncher), and the gas its read gets at bind (R4-3, `_joinFamily`).
    bytes4 private constant POOL_FAMILY = bytes4(keccak256("poolFamily(bytes32)"));
    uint256 private constant FAMILY_READ_GAS = 10_000;
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
    /// @dev S.Bound.terms bits: the pool froze an integrator, a Hookr minimum, Rules knobs off their defaults, and King of
    ///      the Pool.
    uint8 private constant TERMS_INTEGRATOR = 1;
    uint8 private constant TERMS_MINIMUM = 2;
    uint8 private constant TERMS_KNOBS = 4;
    uint8 private constant TERMS_CROWN = 8;
    /// @dev S.DynamicFeeState.flags bits: the state started, and the pool's tempo is in its S.Knobs.
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
    bytes4 private constant BLOCK_CALL_SELECTOR = bytes4(keccak256("blockCall(uint256,bytes)"));
    uint256 private constant CARRY_LEG_INPUT = 4 + 18 * 32;
    /// @dev `EXCLUSIVE_GROUP()`, through which Tax + Conversion's advisory declares its group, the gas a bind gives
    ///      that read, and the group: keccak256("DIRECTIONAL_QUOTE_TAX") (`_taxConversion`).
    bytes4 private constant EXCLUSIVE_GROUP_SELECTOR = 0x5ac238e9;
    uint256 private constant GROUP_READ_GAS = 10_000;
    bytes32 private constant TAX_CONVERSION_GROUP = keccak256("DIRECTIONAL_QUOTE_TAX");
    IPoolManager public immutable override poolManager;
    IHookrRegistry public immutable registry;
    address public immutable protocolRecipient;
    address public immutable trustedRoot;
    uint16 public immutable minProtocolShareBps;
    bool private immutable rootSimulates;
    /// @dev Most share of Hookr's rule-fee share a pool's integrator may be paid: half.
    uint256 private constant MAX_INTEGRATOR_BPS = 5_000;
    /// @dev A wrapped launch age above this reads as a clock behind the launch (`_snipePips`, inside the guard only).
    uint256 private constant MAX_LAUNCH_AGE = type(uint32).max >> 1;
    /// @dev R4-3: seconds after a guarded pool's launch in which only its launch buy clears (N13: 2).
    uint256 private constant LAUNCH_REFUSAL_SECONDS = 2;
    /// @dev HookrRecapture: the module passed to the constructor for the recapture split and King of the Pool (checked
    ///      against HookrRecaptureTemplate there), and its runtime codehash. Both are fixed in this contract's runtime,
    ///      so a registry admission that pins this contract's codehash also pins the module's code (checked at
    ///      admission through `recaptureModule()`).
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
    ///      that slot; whether it froze Rules knobs off their defaults (TERMS_KNOBS, read by a decaying Snipe's
    ///      guarded buys), so a pool without them never reads its S.Knobs; and whether it runs King of the Pool
    ///      (TERMS_CROWN, read by settleSwap), so no other pool reaches HookrRecapture on a swap.

    struct Wire {
        IPoolManager manager;
        IHookrRegistry registry;
        address recipient;
        address root;
        uint16 minShare;
        address recapture;
        bytes32 recaptureHash;
        address claims;
        bytes32 claimsHash;
        address[4] blocks;
        bytes32[4] blockHashes;
        address binder;
        bytes32 binderHash;
        bytes32 simulatorHash;
        uint8 allowed;
        address partScope;
    }
    address private immutable claimsModule;
    bytes32 private immutable claimsCodeHash;
    /// @dev HookrBinder: `bind` runs there by DELEGATECALL (it links HookrRulesChecks), pinned by code here.
    address private immutable binder;
    address private immutable block0;
    address private immutable block1;
    address private immutable block2;
    address private immutable block3;
    bytes32 private immutable block0Hash;
    bytes32 private immutable block1Hash;
    bytes32 private immutable block2Hash;
    bytes32 private immutable block3Hash;
    uint256 private immutable bindMasks;
    uint256 private immutable addMasks;
    uint256 private immutable buyQuoteMasks;
    uint256 private immutable sellQuoteMasks;
    uint256 private immutable buySettleMasks;
    uint256 private immutable sellSettleMasks;
    uint256 private immutable coldReadMasks;
    uint32 private immutable guardOnlyBits;
    uint32 private immutable chargingBits;
    uint32 private immutable wiredHot;
    uint128 private immutable wiredCold;
    uint8 private immutable allowedBlocks;
    address private immutable partScope;
    error InvalidBlockModule();
    error PoolManagerUnlocked();
    // Quiet omission stays off until CC72's exact core-bound event/D36 replay is green.
    bool private constant QUIET_PROTOCOL_EVENTS = false;

    constructor(Wire memory w) {
        HookrTime.checkChain();
        if (address(w.manager).code.length == 0 || address(w.registry).code.length == 0 || w.recipient == address(0)
            || w.recipient == address(w.manager) || w.root.code.length == 0 || w.minShare > 5000
            || address(IHookrRoot(w.root).poolManager()) != address(w.manager)
            || address(IHookrRoot(w.root).registry()) != address(w.registry)) revert InvalidConfig();
        _pin(w.recapture, w.recaptureHash);
        _pin(w.claims, w.claimsHash);
        _pin(w.binder, w.binderHash);
        _pin(address(HookrViewSwap), w.simulatorHash);
        if (_getter(w.recapture, IHookrRules.poolManager.selector) != uint160(address(w.manager))
            || _getter(w.recapture, bytes4(keccak256("protocolRecipient()"))) != uint160(w.recipient)
            || _getter(w.claims, IHookrRules.poolManager.selector) != uint160(address(w.manager))
            || _getter(w.claims, bytes4(keccak256("protocolRecipient()"))) != uint160(w.recipient)) revert InvalidConfig();
        uint256[6] memory masks;
        uint256 reads;
        uint32 guardBits;
        uint32 chargeBits;
        uint32 hot;
        uint128 cold;
        uint32 allowedHot = B.expandAllowed(w.allowed);
        for (uint256 slot; slot < 4; ++slot) {
            address module = w.blocks[slot];
            if (module == address(0)) { if (w.blockHashes[slot] != 0) revert InvalidBlockModule(); continue; }
            _pin(module, w.blockHashes[slot]);
            // Slot1 is the PM-bound CoreBlocks module; Limits(slot0) has no manager immutable.
            if(slot==1&&_getter(module,IHookrRules.poolManager.selector)!=uint160(address(w.manager)))revert InvalidConfig();
            (uint256 hooks, uint256 coldWord) = IHookrBlock(module).blockMasks();
            C.validateMasks(hooks, coldWord);
            for (uint8 lane; lane < 6; ++lane) {
                uint32 mask = C.lane(hooks, lane) & allowedHot;
                masks[lane] |= uint256(mask) << (slot * 32);
                hot |= mask;
            }
            guardBits |= C.lane(hooks, C.MASK_GUARD_ONLY) & allowedHot;
            chargeBits |= C.lane(hooks, C.MASK_CHARGING) & allowedHot;
            reads |= uint256(C.coldReaders(coldWord) & allowedHot) << (slot * 32);
            cold |= C.coldFields(coldWord);
        }
        poolManager = w.manager;
        registry = w.registry;
        protocolRecipient = w.recipient;
        trustedRoot = w.root;
        minProtocolShareBps = w.minShare;
        recapture = w.recapture;
        recaptureCodeHash = w.recaptureHash;
        claimsModule = w.claims;
        claimsCodeHash = w.claimsHash;
        binder = w.binder;
        (block0, block1, block2, block3) = (w.blocks[0], w.blocks[1], w.blocks[2], w.blocks[3]);
        (block0Hash, block1Hash, block2Hash, block3Hash) = (w.blockHashes[0], w.blockHashes[1], w.blockHashes[2], w.blockHashes[3]);
        bindMasks=masks[0]; addMasks=masks[1]; buyQuoteMasks=masks[2]; sellQuoteMasks=masks[3]; buySettleMasks=masks[4]; sellSettleMasks=masks[5];
        coldReadMasks=reads; guardOnlyBits=guardBits; chargingBits=chargeBits; wiredHot=hot; wiredCold=cold;
        allowedBlocks = w.allowed;
        address scope = w.partScope == address(0) ? address(this) : w.partScope;
        partScope = scope;
        if (scope == address(this)) for (uint8 i; i < 8; ++i) new HookrBlockKey{salt: HookrBlockKeys.salt(i)}();
        if (w.recipient.code.length != 0) IHookrTreasury(w.recipient).feeTerms(address(0), false, PoolId.wrap(0));
        (bool ok, bytes memory answer) = w.root.staticcall("");
        rootSimulates = ok && answer.length == 32 && abi.decode(answer, (uint256)) == 1;
        hookrTokenCodeHash = HookrTokenCodeHash.HASH;
    }

    function _pin(address target, bytes32 hash) private view {
        if (target.code.length == 0 || HookrWallets.isDesignator(target) || target.codehash != hash) revert InvalidBlockModule();
    }
    function _getter(address target, bytes4 selector) private view returns (uint256 value) {
        (bool ok, bytes memory answer) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || answer.length != 32) revert InvalidConfig();
        return abi.decode(answer, (uint256));
    }
    function _wiring() private view returns (uint256[16] memory a) {
        a[0]=uint160(address(this)); a[1]=uint160(trustedRoot); a[2]=uint160(address(poolManager)); a[3]=uint160(protocolRecipient);
        a[4]=uint160(recapture); a[5]=uint160(claimsModule); a[6]=uint160(binder); a[7]=uint160(address(HookrViewSwap));
        a[8]=uint160(block0); a[9]=uint160(block1); a[10]=uint160(block2); a[11]=uint160(block3);
        a[12]=uint160(address(registry)); a[13]=uint256(hookrTokenCodeHash); a[14]=uint160(partScope);
        a[15]=uint256(minProtocolShareBps) | uint256(rootSimulates ? 1 : 0) << 16 | uint256(allowedBlocks) << 17
            | uint256(wiredHot) << 25 | uint256(wiredCold) << 57;
    }

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
    ///      A nonzero `period` turns King of the Pool on; RulesConfig.potBps, zero allowed, is then the pot's share of
    ///      each arb recapture's remainder after the protocol share.
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

    /// @dev A King of the Pool epoch (a round): its start, a multiple of the pool's period, the leading buy's payer and
    ///      gross quote spend, and the carried pot.
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
    ///      block stamps are HookrClock ticks: L2 heights on 4663, timestamp x 10 elsewhere, never block.number. `freshTime` is the
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
        /// @dev (HookrTime.parentBlock() << 192) | spent: net guarded buy spend in the current parent block.
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

    /// @param _manager The PoolManager the Rules hold their claims on.
    /// @param _registry The registry whose treasury and admissions the Rules read.
    /// @param _protocolRecipient Receives Hookr's share of every rule fee: the treasury.
    /// @param _trustedRoot The one root whose pools the Rules bind.
    /// @param _minProtocolShareBps The immutable floor of every pool's protocolShareBps, at most 5,000.
    /// @param _module The HookrRecapture module the Rules reach by DELEGATECALL, deployed on its own for the same
    ///        PoolManager, protocol recipient and root: its code must be HookrRecaptureTemplate's build with those
    ///        wires (`_genuineModule`), and the Rules pin its address and runtime codehash.


    /// @notice Returns the identifier of the supported Hookr rules configuration: the keccak256 of RulesConfig's type
    ///         string (HookrTypes.RULES_CONFIG_SCHEMA), so it names the 16-word layout (`integrator` last) and changes
    ///         with any change to it. A reader built for the 15-word layout, which had keccak256("hookr.rules.config"),
    ///         fails closed against it.
    function configSchemaHash() external pure returns (bytes32) {
        return HookrTypes.RULES_CONFIG_SCHEMA;
    }

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
    ///      within 5% on the dynamic fee suite's swap shapes). potBps, the pot cut (potEveryNBuys) and the prize cap
    ///      (potMinBuyQuote) must be zero on a pool without arb recapture (`PotUnavailable`); on a recapture pool
    ///      HookrRecapture checks them, and a pool it reports as King of the Pool freezes TERMS_CROWN. The frozen caps
    ///      must cover the pot cut (`_validate`). S.Knobs at their defaults are not stored; a pool with one off them
    ///      stores them in one more word (`S.Knobs`), which only its dynamic fee swaps and its decaying Snipe's guarded
    ///      buys read.
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


    /// @notice Enforces the launch guard on liquidity additions.


    /// @notice Returns the parent block (HookrTime.parentBlock) before which principal removal is refused, or zero.
    /// @dev guardEndBlock of a bound pool; zero for an unguarded or unbound pool. One SLOAD, never reverts.
    ///      The root reads it once at initialization and bounds it by its own guard window.
    function removalLockedUntil(PoolId id) external view returns (uint256 untilBlock) {
        return _state().pools[id].config.guardEndBlock;
    }

    /// @dev Low38 bits hold the guard's end (or1). Plain answers keep the established both-side hint;
    /// bit38/39 means buy/sell Rules work only. Legacy Root takes the full path for these distant tags,
    /// while Root v2 skips just the inactive side. Dynamic state and global minimum/crown work return0.
    function feeOnlyFrom(PoolId id) external view returns (uint256) {
        S.Bound storage b = _state().pools[id];
        HookrTypes.RulesConfig storage c = b.config;
        if (!b.bound || c.maxFeePips != b.baseFeePips || b.terms & (TERMS_MINIMUM | TERMS_CROWN | S.TERMS_ROOT_SIM) != 0) return 0;
        uint256 start=c.guardEndBlock==0?1:c.guardEndBlock;
        // A uint40 plain guard must never be mistaken for bits38/39 at a synthetic high parent height.
        if(start>>38!=0)return 0;
        uint32 hot=_settingsHot(c.potEveryNBuys)&~guardOnlyBits;
        bool buy=c.lpBps!=0||c.burnBps!=0||c.royaltyBps!=0||_sideNeeded(buyQuoteMasks|buySettleMasks,hot);
        bool sell=_sideNeeded(sellQuoteMasks|sellSettleMasks,hot);
        if(buy&&sell)return 0;
        return start|(buy?uint256(1)<<38:sell?uint256(1)<<39:0);
    }

    function _sideNeeded(uint256 masks,uint32 hot) private pure returns(bool){
        return (uint32(masks)|uint32(masks>>32)|uint32(masks>>64)|uint32(masks>>96))&hot!=0;
    }

    /// @notice Quotes the native rules from the authenticated context.
    /// @dev Buys (exact input and exact output) pay LP Rewards as LP fee, protocol share, royalty and burn. Snipe's
    ///      protocol share is a quote take; Snipe is the decayed tax at this block's timestamp (see `_snipePips`). A
    ///      dynamic fee pool is quoted through `quoteSimulatedSwap` and reverts here. Not view, so a later Rules
    ///      version may keep per-swap state.


    function poolHasDynamicFee(PoolId id) external view returns (bool) {
        S.Bound storage b = _state().pools[id];
        return b.bound && b.terms & S.TERMS_ROOT_SIM != 0;
    }

    /// @dev The largest protocol share an exact-output sell's dynamic fee can take is the clipped span times the
    ///      share. Its real take is max(its dynamic fee share, the pool's Hookr minimum) plus the pool's sell cut, and a
    ///      dynamic fee pool binds a minimum only where that largest share is zero (`bind`: the span times the share is
    ///      below 10,000, a zero share included), so the simulation reserves max(the largest share plus the sell cut,
    ///      the minimum plus the sell cut), the second of which `_quote` without a dynamic fee already gives: never
    ///      less than the real take, and no more than the larger bound. A pool binds a minimum only without arb
    ///      recapture and a cut only with King of the Pool, so at most one of the two is nonzero. Every other shape is
    ///      quoted without the dynamic fee, so the simulated swap reaches at least as far as the real one: its input
    ///      is not reduced by the dynamic fee's LP part or protocol share.


    /// @dev The dynamic fee is the span times the average rate over the swap's own move away from the reference,
    ///      starting from the nearer of its start price and the anchor. Movement back toward the reference is free.
    ///      `settleSwap` then carries the anchor toward the executed price.


    /// @notice Credits actual-fill fees and refunds as Rules claims and returns the credited quote amount.
    /// @dev credited = rulesFee + advisoryFee + refund; liabilities grow by exactly that amount, and a nonzero
    ///      advisoryFee is added to the pool's advisory fee counter (IHookrAdvisoryFeeCounter). On a King of the Pool
    ///      pool HookrRecapture first closes an elapsed epoch, tracks the podium and books the pot cut into the open
    ///      epoch's pot, out of rulesFee; the royalty, the integrator's cut and Hookr's share are then carved from the
    ///      rest, so FeesAllocated's `protocol` and `protocolFeePaid` never count the pot's part.
    ///      During the guard, exact-input buys add their gross spend to the parent-block cap counter and
    ///      sells subtract their actualQuote from it (floored at zero); a launch family's members share one counter
    ///      (R4-3), which their sells never lower (attack round 1, CORE-1). On a decaying Snipe the cap is
    ///      maxBuyQuoteAmount * snipeTaxPips / the current tax, so a parent block that fills it pays the same Snipe
    ///      at every point of the decay; at a zero tax the cap is the counter's own width, which no parent block's
    ///      buys reach. A swap `quoteSimulatedSwap` priced carries the pool's anchor toward its executed price. The
    ///      launch buy (a capped pool's first counted buy, sent by its liquidity owner in the transaction that bound
    ///      it: HookrLauncher's dev buy) pays and counts like any other buy, then fills its parent block's counter so
    ///      no other buy clears on the pool until the next parent block, even once the Snipe has decayed to a zero
    ///      floor; at a zero tax a sell in that parent block frees room for buys of up to its own quote, as sells
    ///      always do. The launch buy carries no anchor and leaves the dynamic fee state unstarted.


    /// @notice Protocol fee credited to protocolRecipient in this transaction by swaps whose authenticated payer is
    ///         `payer`, in `quote`: Hookr's share of the rule fees less any integrator's part.
    /// @dev Transient (EIP-1153): monotonic within a transaction, zero at transaction start. Only settleSwap writes it.
    function protocolFeePaid(address payer, Currency quote) external view returns (uint256 amount) {
        bytes32 slot = keccak256(abi.encode(PROTOCOL_PAID, payer, quote));
        assembly ("memory-safe") {
            amount := tload(slot)
        }
    }





    /// @dev Unbound pools return zero fields.
    function config(PoolId id) external view returns (HookrTypes.RulesConfig memory) {
        return _state().pools[id].config;
    }



    /// @notice Returns whether owned PoolManager claims cover the currency liabilities.


    /// @notice Pays the caller's claim to the caller, up to the PoolManager amount limit.


    /// @dev Any recipient except zero, the PoolManager, this contract (which has no sweep) and `trustedRoot`, which has
    ///      no path that moves an ERC-20 balance.


    /// @notice Pays the caller's whole claim to `to` as PoolManager ERC-6909 claims. Moves no token.
    /// @dev The exit for a quote whose transfers are paused, taxed or restricted for the recipient. The
    ///      recipient redeems the ERC-6909 balance later through any PoolManager unlock. Refuses the recipients
    ///      claimTo refuses: a balance paid to `trustedRoot` would leave it only as a protocol claim (`sweepClaims`).










    /// @notice Burns the reserved claims and takes their backing during an authenticated claim.


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
    ///      with it. Last, the quote take gains the pool's pot cut for the swap's side (RulesConfig.potEveryNBuys: the
    ///      buy cut in its low 16 bits, the sell cut in its high 16, in basis points), nonzero only on a King of the
    ///      Pool pool, which never binds a minimum. `guard` is whether the swap is inside the guard window; the caller
    ///      reads the clock once for this and its block test. The caller's `q` is zeroed and filled here.
    function _quote(
        HookrTypes.SwapContext calldata x,
        S.Bound storage b,
        HookrTypes.RulesConfig memory c,
        uint256 dynamicFee,
        HookrTypes.FeeQuote memory q,
        bool guard
    ) private view returns (uint256 hookr) {
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
        // R4-3 Anti-Snipe Step B (next core 10-22), on a pool bound with a guard: the launch buy pays no Snipe (it
        // keeps the cap and the closed parent block, `_settleGuard`), and every other buy is refused for
        // LAUNCH_REFUSAL_SECONDS of block.timestamp from the launch, whether or not the guard window is still open
        // (on 143 a guard may end a second after its launch: parent blocks are block.timestamp / 12).
        if (x.isBuy && c.guardEndBlock != 0 && _snipes(x, b, guard)) {
            snipe = c.snipeTaxPips;
            uint256 duration = b.config.snipeDecaySeconds;
            if (duration != 0) snipe = _snipePips(x.id, b, snipe, duration);
        }
        if (dynamicFee > room) dynamicFee = room;
        if (snipe > room - dynamicFee) snipe = room - dynamicFee;
        uint256 protocolPips = dynamicFee * c.protocolShareBps / BPS + snipe * c.protocolShareBps / BPS;
        q.lpFeeSurchargePips = uint24(lpReward + dynamicFee + snipe - protocolPips);
        take += protocolPips;

        q.quoteTakePips = uint24(take);
        hookr = take - royaltyPips;
    }

    /// @dev Whether this buy on a guarded pool pays the Snipe: inside the guard window and not the launch buy (its
    ///      liquidity owner's, while the bind transaction's LAUNCH_BUY holds the pool). Refuses any other buy within
    ///      LAUNCH_REFUSAL_SECONDS of the launch. Block timestamps never fall, so the launch age, taken modulo 2^32
    ///      like the stored launchedAt, is never read as a clock behind the launch here: such a reading could only be
    ///      the wrap, and it refused every buy from 2^31 seconds after the launch (Opus attack round, OA-1). The age
    ///      wraps again 2^32 seconds (136 years) after the launch, where the refusal would hold for two seconds. Slot 0
    ///      of the Bound once (owner at bits 64-223, launchedAt at 224-255, warm from `_checkContext`); past the
    ///      refusal and the guard it returns without the transient read.
    function _snipes(HookrTypes.SwapContext calldata x, S.Bound storage b, bool guard) private view returns (bool) {
        uint256 head;
        assembly ("memory-safe") { head := sload(b.slot) }
        uint256 elapsed;
        unchecked { elapsed = uint32(uint32(block.timestamp) - uint32(head >> 224)); }
        bool early = elapsed < LAUNCH_REFUSAL_SECONDS;
        if (!early && !guard) return false;
        bool launch;
        assembly ("memory-safe") {
            launch := and(eq(tload(LAUNCH_BUY), calldataload(x)),
                eq(calldataload(add(x, 32)), and(shr(64, head), 0xffffffffffffffffffffffffffffffffffffffff)))
        }
        if (early && !launch) revert LaunchSecond(uint256(uint32(head >> 224)) + LAUNCH_REFUSAL_SECONDS);
        return guard && !launch;
    }

    /// @dev Decaying Snipe LP-fee pips before clipping, for a nonzero `duration`: from `start` at launch to
    ///      snipeFloorPips at `duration` seconds, then the floor, along the pool's snipeCurve (`_knobbedSnipe` for a
    ///      pool with S.Knobs, TERMS_KNOBS; the linear curve, `_linearSnipe`, for every other). The launch age is taken
    ///      modulo 2^32 like the stored launchedAt, and a clock behind the launch reads as the launch.
    function _snipePips(PoolId id, S.Bound storage b, uint256 start, uint256 duration) private view returns (uint256) {
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

    /// @dev The Snipe of a pool with S.Knobs, `elapsed` seconds after launch, along its snipeCurve: the floor from
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
        S.Bound storage b,
        HookrTypes.RulesConfig memory c,
        HookrTypes.SwapSimulation memory m
    ) private returns (uint256 dynamicFee) {
        S.DynamicFeeState memory g = _unpackDynamic()(_dynamicWord(x.id));
        uint256 lag;
        bool journal;
        (dynamicFee, lag, journal) = _priceDynamic(x, b, c, m, g);
        // The launch buy leaves the state unstarted, so the pool's next swap starts it at the post-buy price.
        if (!journal) return dynamicFee;
        // The reference and anchor share a single persistent word. Journal the quoted reference, then
        // commit once at actual-fill settle; each transient handoff is isolated by pool id.
        // One hash per pool for the three journal words: the lag at the pool's DYNAMIC_FEE_LAG slot, the state and the
        // simulated end in the two transient slots after it (G1a gas pass; the other transient slots are hashes too).
        bytes32 lagSlot = _poolSlot(S.DYNAMIC_FEE_LAG, x.id);
        _put(lagSlot, ANCHOR_PENDING | lag);
        _put(bytes32(uint256(lagSlot) + 1), _packDynamic(g));
        _put(bytes32(uint256(lagSlot) + 2), m.sqrtPriceAfterX96);
    }

    function _dynamicWord(PoolId id) private view returns (uint256 dynamicWord) {
        bytes32 dynamicSlot=HookrCoreState.dynamicFeeSlot(id);
        assembly("memory-safe"){dynamicWord:=sload(dynamicSlot)}
    }

    /// @dev `_dynamicFee`'s pricing on the pool's stored state `g`, which it steps in place: the fee,
    ///      the lag, and whether they are journaled (false only for the launch buy, which starts nothing).
    function _priceDynamic(
        HookrTypes.SwapContext calldata x,
        S.Bound storage b,
        HookrTypes.RulesConfig memory c,
        HookrTypes.SwapSimulation memory m,
        S.DynamicFeeState memory g
    ) private returns (uint256 dynamicFee, uint256 lag, bool journal) {
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
                S.Knobs storage k = _state().knobs[x.id];
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
        journal = !launchBuy;
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
        S.Bound storage b = _bound(x.id);
        _checkContext(b, x);
        HookrTypes.RulesConfig memory c = _hot()(b.config);
        // _checkContext pinned x.baseLpFeePips to the bound base fee.
        if (c.maxFeePips > x.baseLpFeePips) {
            S.DynamicFeeState memory g = _unpackDynamic()(_dynamicWord(x.id));
            (, uint256 lag, bool journal) = _priceDynamic(x, b, c, m, g);
            if (!journal) {
                // The launch buy journals nothing: settle whatever this pool has pending, as before.
                _settleDynamicFee(x.id, x.zeroForOne, b.quoteIsCurrency0, quoteAmount);
            } else {
                // `_dynamicFee` then `_settleDynamicFee` without the journal round trip between them (G1a gas pass):
                // the same state, lag and simulated end straight to `_moveAnchor`, and the lag cleared as the
                // round trip leaves it.
                _put(_poolSlot(S.DYNAMIC_FEE_LAG, x.id), 0);
                _storeDynamic(x.id, _moveAnchor(x.id, x.zeroForOne, b.quoteIsCurrency0, quoteAmount, lag,
                    m.sqrtPriceAfterX96, g));
            }
        }
    }

    /// @dev Whether an anchor move of `moved` ticks from movedTick counts: at least the pool's moveTicks either way,
    ///      its S.Knobs' when its S.DynamicFeeState `flags` say its tempo is there (DYNAMIC_FEE_KNOBBED), else the default.
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
        bytes32 lagSlot = _poolSlot(S.DYNAMIC_FEE_LAG, id);
        uint256 lag = _get(lagSlot);
        if (lag == 0) return;
        // The state and the simulated end follow the lag (`_dynamicFee`).
        S.DynamicFeeState memory g = _unpackDynamic()(_get(bytes32(uint256(lagSlot) + 1)));
        uint160 simulatedEnd = uint160(_get(bytes32(uint256(lagSlot) + 2)));
        // Only the lag gates the journal: every quote that sets it rewrites the state and end with it, and they are
        // read only while it is set, so clearing it alone retires all three (G1a gas pass).
        _put(lagSlot, 0);
        g = _moveAnchor(id, zeroForOne, quoteIs0, quoteAmount, lag ^ ANCHOR_PENDING, simulatedEnd, g);
        _storeDynamic(id, g);
    }

    function _packDynamic(S.DynamicFeeState memory g) private pure returns (uint256 word) {
        assembly ("memory-safe") {
            word:=or(and(mload(g),0xffffffffffffffffffffffff),shl(96,and(mload(add(g,32)),0xffffff)))
            word:=or(word,shl(120,and(mload(add(g,64)),0xffffff)))
            word:=or(word,shl(144,and(mload(add(g,96)),0xffffff)))
            word:=or(word,shl(168,and(mload(add(g,128)),0xffffffffff)))
            word:=or(word,shl(208,and(mload(add(g,160)),0xffffffffff)))
            word:=or(word,shl(248,and(mload(add(g,192)),0xff)))
        }
    }
    function _unpackDynamicWords(uint256 word) private pure returns (uint256 g) {
        assembly ("memory-safe") {
            g:=mload(0x40) mstore(0x40,add(g,224))
            mstore(g,and(word,0xffffffffffffffffffffffff))
            mstore(add(g,32),signextend(2,shr(96,word)))
            mstore(add(g,64),signextend(2,shr(120,word)))
            mstore(add(g,96),signextend(2,shr(144,word)))
            mstore(add(g,128),and(shr(168,word),0xffffffffff))
            mstore(add(g,160),and(shr(208,word),0xffffffffff))
            mstore(add(g,192),shr(248,word))
        }
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
        uint160 simulatedEnd,
        S.DynamicFeeState memory g
    ) private view returns (S.DynamicFeeState memory) {
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
        if (next == sqrtAnchor) return g;
        // The anchor's new tick is rounded toward its old price, so a move of less than one tick never shifts it.
        int24 tick = reached && target == sqrtEnd ? tickEnd : TickMath.getTickAtSqrtPrice(next);
        if (next < sqrtAnchor && TickMath.getSqrtPriceAtTick(tick) < next) ++tick;
        if (tick == g.anchorTick) return g;
        g.anchorTick = tick;
        int256 moved = int256(tick) - g.movedTick;
        if (reached && _counts(id, g.flags, moved)) {
            g.movedAt = uint40(block.timestamp);
            g.movedTick = tick;
        }
        return g;
    }

    /// @dev The effective protocolShareBps floor for a bind, the larger of minProtocolShareBps and the treasury's
    ///      governed floor, `integrator`'s rate on the treasury's list (zero for no integrator) and the treasury's Hookr
    ///      minimum for pool `id` (`lane`: with arb recapture, a rate `bind` never keeps; `integrator`'s override only
    ///      if it approved `id`). A protocol recipient without code has no governed floor, no list and no minimum, so
    ///      it admits no integrator. An integrator off the list, a rate above MAX_INTEGRATOR_BPS or a minimum above
    ///      MAX_MIN_FEE_PIPS is refused, and so is an integrator that could never claim what settleSwap credits it,
    ///      whatever the list says: these Rules, their trusted root, their protocol recipient, the PoolManager and
    ///      their HookrRecapture module.


    /// @dev Refuses Rules knobs out of HookrTypes' bounds or at odds with the config, and Rules data longer than the
    ///      pool needs: a pool without dynamic fees, arb recapture or a knob off its default binds its config alone.
    ///      Returns whether a knob is off its default, which the pool then stores (`S.Knobs`, TERMS_KNOBS), and whether
    ///      one of them is the dynamic fee tempo (DYNAMIC_FEE_KNOBBED). `knobbed`: the data carries RulesKnobs;
    ///      `lane`: and a RecaptureConfig.


    /// @dev Refuses a configuration that is out of range, past the dynamic fee's reach bound, or would later brick valid
    ///      swaps at its frozen caps, the pot cut counted: a buy's quote take includes the buy cut and a sell's the
    ///      sell cut. HookrRecapture checked the cut and the prize cap on a recapture pool, and `bind` refused both on
    ///      any other. pc.caps are min(pool, admission) less the advisory's admitted maximum; maxLpFeePips is the total
    ///      LP fee. `floor` is the effective protocolShareBps floor (`_feeTerms`), `minFee` the pool's Hookr minimum.
    ///      The royalty recipient is never these Rules, their trusted root, the
    ///      PoolManager or their HookrRecapture module, which `_feeTerms` refuses as an integrator for the same reason:
    ///      none can ever claim what settleSwap credits it.


    /// @notice The recapture surface, served by HookrRecapture through DELEGATECALL so no selector joins the dispatcher
    ///         ahead of the swap calls of every pool: IHookrLaneRules (`recaptureMode`, `settleRecapture`), the rest
    ///         of IHookrRecaptureRules, IHookrAdvisoryFeeCounter (`advisoryFeeCredited`) and IHookrRulesKnobs
    ///         (`dynamicFeeParameters(PoolId)`, `rulesKnobs`, `dynamicFeeReachBound`). `recaptureModule()`
    ///         answers from this contract's own code, and so does IHookrLaneRules.carryLeg (`_carryLeg`), which prices
    ///         the dynamic fee state.


    /// @dev DELEGATECALLs HookrRecapture with this call's calldata (bind or settleSwap, whose selectors it shares),
    ///      bubbles a revert and returns the module's one return word: bind's King of the Pool flag, settleSwap's pot
    ///      cut. Return data of any other length reverts (with no data), so a module that answers nothing can never
    ///      bind a King of the Pool pool as an ordinary one.


    /// @dev Whether `module`'s code is the HookrRecapture build HookrRecaptureTemplate names, wired to `manager`,
    ///      `recipient`, `root` and its own address: each of its immutable references (HookrRecaptureTemplate.REFS)
    ///      holds the wire it must, and its runtime up to the metadata trailer, with those references zeroed, hashes
    ///      to HookrRecaptureTemplate.HASH. So the module is pinned by its code, not by getters it answers itself, and
    ///      by one hash for every deployment. Constructor only. The trailer (the metadata hash of the module's sources)
    ///      is left out; no code reads it or jumps into it.


    function _bound(PoolId id) private view returns (S.Bound storage b) {
        b = _state().pools[id];
        if (!b.bound) revert UnknownPool();
        if (msg.sender != trustedRoot) revert Unauthorized();
    }

    /// @dev `_hotWords` and `_unpackDynamicWords` typed as returning the struct they build. A memory-struct return
    ///      variable is allocated and zeroed on entry (16 words for RulesConfig, 7 for DynamicFeeState), which their
    ///      assembly then replaces; the function-pointer cast skips that dead allocation (G1a gas pass), as
    ///      `_viewQuoteAll`'s cast skips a mutability check.
    function _hot() private pure
        returns (function(HookrTypes.RulesConfig storage) internal view returns (HookrTypes.RulesConfig memory) f)
    {
        function(HookrTypes.RulesConfig storage) internal view returns (uint256) raw = _hotWords;
        assembly ("memory-safe") { f := raw }
    }
    function _unpackDynamic() private pure
        returns (function(uint256) internal pure returns (S.DynamicFeeState memory) f)
    {
        function(uint256) internal pure returns (uint256) raw = _unpackDynamicWords;
        assembly ("memory-safe") { f := raw }
    }

    /// @dev The first config slot only; beforeSwap never reads maxBuyQuoteAmount, potMinBuyQuote or royaltyTo, and
    ///      reads snipeFloorPips and snipeDecaySeconds from storage on guarded buys alone.
    /// @dev The config's first packed word into the first twelve RulesConfig fields, unrolled with the C1 widths
    ///      (the C1 layout HookrBinder's CONFIG_WIDTHS packs: guard 40, three 24, seven 16, hot 32) at their fixed shifts; the cold fields read zero, as
    ///      the swap path never reads them from this copy. One loop over the width table cost about 1,300 gas more
    ///      on every Rules call (G1a gas pass).
    function _hotWords(HookrTypes.RulesConfig storage cs) private view returns (uint256 c) {
        assembly ("memory-safe") {
            c:=mload(0x40) mstore(0x40,add(c,512))
            let word:=sload(cs.slot)
            mstore(c,and(word,0xffffffffff))
            mstore(add(c,32),and(shr(40,word),0xffffff))
            mstore(add(c,64),and(shr(64,word),0xffffff))
            mstore(add(c,96),and(shr(88,word),0xffffff))
            mstore(add(c,128),and(shr(112,word),0xffff))
            mstore(add(c,160),and(shr(128,word),0xffff))
            mstore(add(c,192),and(shr(144,word),0xffff))
            mstore(add(c,224),and(shr(160,word),0xffff))
            mstore(add(c,256),and(shr(176,word),0xffff))
            mstore(add(c,288),and(shr(192,word),0xffff))
            mstore(add(c,320),and(shr(208,word),0xffff))
            mstore(add(c,352),shr(224,word))
            mstore(add(c,384),0) mstore(add(c,416),0) mstore(add(c,448),0) mstore(add(c,480),0)
        }
    }

    /// @dev Rebuilds the pool key from the context's currencies in the bound order, so a subject or quote other than
    ///      the bound pool's does not hash to `x.id`.
    function _checkContext(S.Bound storage b, HookrTypes.SwapContext calldata x) private view {
        (Currency currency0, Currency currency1) = b.quoteIsCurrency0 ? (x.quote, x.subject) : (x.subject, x.quote);
        PoolKey memory key =
            PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, b.tickSpacing, IHooks(trustedRoot));
        if (
            PoolId.unwrap(key.toId()) != PoolId.unwrap(x.id) || x.baseLpFeePips != b.baseFeePips
                || x.payer == address(0) || x.beneficiary == address(0)
        ) revert InvalidSettlement();
    }

    function _state() private pure returns (S.State storage s) {
        assembly ("memory-safe") { s.slot := SLOT }
    }

    /// @dev Runs in HookrBinder by DELEGATECALL (`_toBinder`). Off the swap path.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external returns (bytes32 hash)
    {
        // The id first: hashing the key allocates memory, and the binder's answer sits past the free pointer.
        PoolId id = key.toId();
        uint256 size = _binderCall();
        // The binder answers RulesBound's data (the effective Rules data, R4-1); the root receives keccak256(data).
        bytes32 topic = RulesBound.selector;
        assembly ("memory-safe") {
            let free := mload(0x40)
            log3(free, size, topic, id, caller())
            calldatacopy(free, data.offset, data.length)
            hash := keccak256(free, data.length)
        }
        // R4-3: a capped pool (bound config slot 2, maxBuyQuoteAmount in its low 128 bits) joins its launch family.
        bytes32 head = HookrCoreState.poolSlot(id);
        uint256 cap;
        assembly ("memory-safe") { cap := and(sload(add(head, 2)), 0xffffffffffffffffffffffffffffffff) }
        if (cap != 0) _joinFamily(id, head, pc.liquidityOwner);
    }

    /// @dev R4-3: one Anti-Snipe buy cap per launch family. The family is the one the pool's liquidity owner reports
    ///      (`poolFamily(id)`, HookrLauncher's, read with FAMILY_READ_GAS; no answer or zero is no family), scoped to
    ///      that owner. The family's first capped member bound in this transaction is its anchor and counts at its own
    ///      guard word; each later one records the anchor and both carry TERMS_FAMILY, so a pool launched alone pays
    ///      nothing on a swap. Members bind in one transaction, before any buy but each member's launch buy (the
    ///      launch-second refusal), so the anchor's counter is empty or closed when it joins: no unit to convert.
    function _joinFamily(PoolId id, bytes32 head, address owner) private {
        bytes4 selector = POOL_FAMILY;
        bytes32 family;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, selector)
            mstore(add(p, 4), id)
            // The call first: Yul evaluates arguments right to left, so returndatasize() must follow it.
            let ok := staticcall(FAMILY_READ_GAS, owner, p, 36, p, 32)
            if and(ok, eq(returndatasize(), 32)) { family := mload(p) }
        }
        if (family == 0) return;
        bytes32 domain = S.FAMILY_TX;
        bytes32 anchorSlot = S.familyAnchorSlot(id);
        uint256 familyBit = uint256(S.TERMS_FAMILY) << 56;
        bytes32 rules = SLOT;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, domain) mstore(add(p, 32), owner) mstore(add(p, 64), family)
            let txSlot := keccak256(p, 96)
            let anchor := tload(txSlot)
            switch anchor
            case 0 { tstore(txSlot, id) }
            default {
                sstore(anchorSlot, anchor)
                // The anchor's Bound head: HookrCoreState.poolSlot, the pools mapping at offset 0 of RULES_SLOT.
                mstore(0, anchor) mstore(32, rules)
                let anchorHead := keccak256(0, 64)
                sstore(anchorHead, or(sload(anchorHead), familyBit))
                sstore(head, or(sload(head), familyBit))
            }
        }
    }



    /// @dev Forwards this call's exact calldata to HookrBinder by DELEGATECALL, then the capsule HookrBinder
    ///      documents (this core's bind masks, guard-only bits and the 16-word Checks wiring), and returns or reverts
    ///      with its answer. `bind` and the fallback's `blockCall` run there, both off the swap path.
    function _toBinder() private {
        uint256 size = _binderCall();
        assembly ("memory-safe") { return(mload(0x40), size) }
    }
    /// @dev The binder call: reverts with its revert, else leaves its answer at the free memory pointer (not moved) and
    ///      answers its size.
    function _binderCall() private returns (uint256 size) {
        uint256[16] memory w = _wiring();
        address module = binder;
        uint256 masks = bindMasks;
        uint256 guardBits = guardOnlyBits;
        assembly ("memory-safe") {
            let free := mload(0x40)
            let length := calldatasize()
            calldatacopy(free, 0, length)
            let end := add(free, length)
            mstore(end, masks)
            mstore(add(end, 32), guardBits)
            mcopy(add(end, 64), w, 512)
            let ok := delegatecall(gas(), module, free, add(length, 576), 0, 0)
            size := returndatasize()
            returndatacopy(free, 0, size)
            if iszero(ok) { revert(free, size) }
        }
    }

    /// @dev The config word's guard end (bits 0-39) and hot word (bits 224-255).
    uint256 private constant ADD_FAST_MASK = 0xffffffff0000000000000000000000000000000000000000000000ffffffffff;

    function beforeAddLiquidity(PoolId id, address sender) external view {
        // _bound inline: the add row has no other Rules work to pay the call's stack frame (G1a gas pass).
        S.Bound storage b = _state().pools[id];
        if (!b.bound) revert UnknownPool();
        if (msg.sender != trustedRoot) revert Unauthorized();
        // The config's first word once: the guard end (bits 0-39) and the hot word (bits 224-255), as _hot reads
        // them. A pool with neither returns on one test; otherwise a pool with no guard window skips the clock read
        // and one with no hot setting skips the block dispatch.
        uint256 word;
        HookrTypes.RulesConfig storage cs = b.config;
        assembly ("memory-safe") { word := sload(cs.slot) }
        if (word & ADD_FAST_MASK == 0) return;
        bool guard = word & 0xffffffffff != 0 && HookrTime.parentBlock() < (word & 0xffffffffff);
        if (guard && sender != b.liquidityOwner) revert GuardLiquidity();
        if (word >> 224 == 0) return;
        uint32 hot = _active(uint32(word >> 224), guard);
        if (hot == 0) return;
        uint128 cold = _cold(b, addMasks, hot);
        bytes memory input = _frame(IHookrBlock.blockAddLiquidity.selector, 4, 64, 64);
        uint256 context = S.context(S.Hook.AddLiquidity, S.CTX_STATIC | (guard ? S.CTX_GUARD : 0)
            | (b.terms & S.TERMS_LANE != 0 ? S.CTX_LANE : 0));
        assembly ("memory-safe") { mstore(add(input, 100), context) mstore(add(input, 132), cold) }
        for (uint8 slot; slot < 4; ++slot) if (_runs(addMasks, slot, hot)) _viewCall(_module(slot), input, 0);
    }

    function beforeSwap(HookrTypes.SwapContext calldata x) external returns (HookrTypes.FeeQuote memory q) {
        S.Bound storage b = _bound(x.id);
        _checkContext(b, x);
        HookrTypes.RulesConfig memory c = _hot()(b.config);
        HookrTypes.SwapSimulation memory m;
        uint256 dynamicFee;
        if (c.dynamicFeeSens != 0) {
            // In-core pricing (no lane, no before-swap advisory, not on 143): HookrViewSwap walks the swap within its
            // own budget and prices a longer walk at the swap's own limit (NC45). Below tick spacing 14 a 1-wei push
            // into an empty side can leave the price where the next swap's walk crosses more empty words than the
            // budget reads, so the app and the SDK bind in-core dynamic fees only at spacing 14 or more (Opus attack
            // round, OA-3); the core takes any spacing.
            if (b.terms & S.TERMS_ROOT_SIM != 0) revert SimulationRequired();
            HookrTypes.FeeQuote memory pre;
            _simulationQuote(x, b, c, pre);
            HookrViewSwap.Result memory result = HookrViewSwap.simulateQuoted(poolManager, HookrViewSwap.Input(
                x.id, b.tickSpacing, x.zeroForOne, x.amountSpecified, x.sqrtPriceLimitX96,
                uint24(uint256(x.baseLpFeePips) + pre.lpFeeSurchargePips), x.isBuy, pre.quoteTakePips, pre.subjectBurnBps));
            m = HookrTypes.SwapSimulation(result.sqrtPriceBeforeX96, result.tickBefore,
                result.feePriceAfterX96, result.feeTickAfter);
            dynamicFee = _dynamicFee(x, b, c, m);
        }
        _quoteOrBlocks(x, b, c, dynamicFee, m, q);
    }

    /// @dev `_quoteAll` for a swap a block may run on; a swap with none takes the release's quote and the D14 minimum
    ///      directly, without `_quoteAll`'s frame (G1a gas pass).
    function _quoteOrBlocks(HookrTypes.SwapContext calldata x, S.Bound storage b, HookrTypes.RulesConfig memory c,
        uint256 dynamicFee, HookrTypes.SwapSimulation memory m, HookrTypes.FeeQuote memory q) private
    {
        if (_settingsHot(c.potEveryNBuys) == 0) _finishQuote(x, b, q, _quote(x, b, c, dynamicFee, q, HookrTime.parentBlock() < c.guardEndBlock));
        else _quoteAll(x, b, c, dynamicFee, m, false, q);
    }

    function simulationQuote(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.FeeQuote memory q) {
        S.Bound storage b = _bound(x.id);
        _checkContext(b, x);
        _simulationQuote(x, b, _hot()(b.config), q);
    }
    /// @dev The quote helpers fill one zeroed FeeQuote the external entry owns, rather than each allocating and
    ///      returning its own: every extra struct cost about 155 gas of memory zeroing (G1a gas pass).
    function _simulationQuote(HookrTypes.SwapContext calldata x, S.Bound storage b, HookrTypes.RulesConfig memory c,
        HookrTypes.FeeQuote memory q) private view
    {
        uint256 rawTake;
        // The guard window once for the block test and the quote (G1a gas pass).
        bool guard = HookrTime.parentBlock() < c.guardEndBlock;
        if (_settingsHot(c.potEveryNBuys) == 0 || _active(c.potEveryNBuys, guard) == 0) {
            // No block on this swap: the release's quote and the D14 minimum, without the module dispatcher's
            // function-pointer view cast (G1a gas pass).
            uint256 hookr = _quote(x, b, c, 0, q, guard);
            rawTake = _finishQuote(x, b, q, hookr);
        } else {
            HookrTypes.SwapSimulation memory m;
            rawTake = _viewQuoteAll(x, b, c, 0, m, q);
        }
        if (!x.isBuy && !x.exactInput) {
            // Static block takes at zero dynamic LP fee dominate their clipped LP-outflow protocol takes.
            // Add the entire maximum dynamic protocol share to the pre-minimum take, then take the larger
            // of that and the minimum quote. Separate flooring at the maximum-LP endpoint can miss one pip.
            uint256 largest = rawTake
                + (uint256(c.maxFeePips) - x.baseLpFeePips) * c.protocolShareBps / BPS;
            if (largest > type(uint24).max || largest >= PIPS) revert InvalidSettlement();
            if (largest > q.quoteTakePips) q.quoteTakePips = uint24(largest);
        }
    }
    function quoteSimulatedSwap(HookrTypes.SwapContext calldata x, HookrTypes.SwapSimulation calldata simulation)
        external returns (HookrTypes.FeeQuote memory q)
    {
        S.Bound storage b = _bound(x.id);
        _checkContext(b, x);
        HookrTypes.RulesConfig memory c = _hot()(b.config);
        uint256 dynamicFee;
        if (c.dynamicFeeSens != 0) dynamicFee = _dynamicFee(x, b, c, simulation);
        _quoteOrBlocks(x, b, c, dynamicFee, simulation, q);
    }

    function _viewQuoteAll(HookrTypes.SwapContext calldata x, S.Bound storage b, HookrTypes.RulesConfig memory c,
        uint256 dynamicFee, HookrTypes.SwapSimulation memory m, HookrTypes.FeeQuote memory q) private view returns (uint256)
    {
        function(HookrTypes.SwapContext calldata, S.Bound storage, HookrTypes.RulesConfig memory,
            uint256, HookrTypes.SwapSimulation memory, bool, HookrTypes.FeeQuote memory) internal returns (uint256) f = _quoteAll;
        function(HookrTypes.SwapContext calldata, S.Bound storage, HookrTypes.RulesConfig memory,
            uint256, HookrTypes.SwapSimulation memory, bool, HookrTypes.FeeQuote memory) internal view returns (uint256) v;
        assembly ("memory-safe") { v := f }
        return v(x, b, c, dynamicFee, m, true, q);
    }
    /// @dev The quote's last steps, after any block: the per-swap Hookr minimum (D14) and the aggregate bounds.
    function _finishQuote(HookrTypes.SwapContext calldata x, S.Bound storage b, HookrTypes.FeeQuote memory q,
        uint256 hookr) private view returns (uint256 rawTake)
    {
        rawTake = q.quoteTakePips;
        if (b.terms & TERMS_MINIMUM != 0) {
            uint256 minimum = _state().integrations[x.id].minFeePips;
            if (hookr < minimum) {
                uint256 take = uint256(q.quoteTakePips) + minimum - hookr;
                if (take > type(uint24).max) revert InvalidSettlement();
                q.quoteTakePips = uint24(take);
            }
        }
        // The aggregate bounds in one branch (G1a gas pass): q's three fields are its first three words.
        uint256 base = x.baseLpFeePips;
        bool out;
        assembly ("memory-safe") {
            out := or(or(gt(add(base, mload(q)), 600000), gt(mload(add(q, 32)), 350000)), gt(mload(add(q, 64)), 1000))
        }
        if (out) revert InvalidSettlement();
    }
    function _quoteAll(HookrTypes.SwapContext calldata x, S.Bound storage b, HookrTypes.RulesConfig memory c,
        uint256 dynamicFee, HookrTypes.SwapSimulation memory m, bool staticMode, HookrTypes.FeeQuote memory q)
        private returns (uint256 rawTake)
    {
        bool guard = HookrTime.parentBlock() < c.guardEndBlock;
        uint256 hookr = _quote(x, b, c, dynamicFee, q, guard);
        uint32 hot = _settingsHot(c.potEveryNBuys) == 0 ? 0 : _active(c.potEveryNBuys, guard);
        if (hot != 0) {
            uint256 masks = x.isBuy ? buyQuoteMasks : sellQuoteMasks;
            uint128 cold = _cold(b, masks, hot);
            uint256 xOffset = _cleanContext(x);
            bytes memory input = _frame(IHookrBlock.blockQuote.selector, xOffset, 416, 320);
            assembly ("memory-safe") { mcopy(add(input, 452), m, 128) }
            uint256 context = _context(S.Hook.Quote, x, b, staticMode, false, guard);
            assembly ("memory-safe") { mstore(add(input, 580), context) mstore(add(input, 612), cold) }
            _tail4(input, q.lpFeeSurchargePips, q.quoteTakePips, q.subjectBurnBps, hookr);
            // Each running module answers the four tail words, never lower (`_answer`), and its answer becomes the
            // next module's tail.
            for (uint8 slot; slot < 4; ++slot) if (_runs(masks, slot, hot)) _answer(_module(slot), input, 4, true);
            uint256 w0;
            uint256 w1;
            uint256 w2;
            uint256 w3;
            assembly ("memory-safe") {
                let end := add(add(input, 32), mload(input))
                w0 := mload(sub(end, 128)) w1 := mload(sub(end, 96)) w2 := mload(sub(end, 64)) w3 := mload(sub(end, 32))
            }
            if (w0 > type(uint24).max || w1 > type(uint24).max || w2 > type(uint16).max || w3 > w1)
                revert InvalidSettlement();
            (q.lpFeeSurchargePips, q.quoteTakePips, q.subjectBurnBps) = (uint24(w0), uint24(w1), uint16(w2));
            hookr = w3;
        }
        rawTake = _finishQuote(x, b, q, hookr);
        // The final take is for the modules' settle tail: written only when a block runs on this swap (_settleBlocks).
        if (hot != 0 && !staticMode) _put(_poolSlot(S.FINAL_TAKE, x.id), q.quoteTakePips);
    }

    function settleSwap(HookrTypes.SwapContext calldata x, HookrTypes.Settlement calldata z)
        external returns (uint256 credited)
    {
        S.Bound storage b = _bound(x.id);
        _checkContext(b, x);
        uint256 recipientWord;
        assembly ("memory-safe") { recipientWord := calldataload(add(z,224)) }
        if (recipientWord >> 160 != 0) revert InvalidSettlement();
        bool launchBuy = x.isBuy && x.sender == b.liquidityOwner && _launchBuy(x.id, true);
        // The config's first word once for the dynamic fee, the guard and the blocks (G1a gas pass): the guard end in
        // bits 0-39, dynamicFeeSens in bits 128-143, the hot word in bits 224-255, as _hot reads them.
        uint256 word;
        {
            HookrTypes.RulesConfig storage cs = b.config;
            assembly ("memory-safe") { word := sload(cs.slot) }
        }
        if ((word >> 128) & 0xffff != 0) _settleDynamicFee(x.id, x.zeroForOne, b.quoteIsCurrency0, z.actualQuote);
        bool guard = word & 0xffffffffff != 0 && HookrTime.parentBlock() < (word & 0xffffffffff);
        if (guard) _settleGuard(x, z, b, launchBuy);
        if (b.terms & TERMS_CROWN != 0) _settleCrown(x, z);
        uint256 protocol = _settleBlocks(x, z, b, launchBuy, word >> 224 == 0 ? 0 : _active(uint32(word >> 224), guard), guard);
        credited = z.rulesFee + z.advisoryFee + z.refund;
        if (credited == 0) return 0;
        S.State storage s = _state();
        mapping(address => uint256) storage claims = s.claims[x.quote];
        uint256 royalty;
        // royaltyBps (bits 192-207), lpBps (160-175) and protocolShareBps (208-223) from the config word read above.
        uint256 royaltyBps = (word >> 192) & 0xffff;
        if (x.isBuy && royaltyBps != 0) {
            uint16 lpBps = uint16(word >> 160);
            uint256 lpNet = uint256(lpBps) * 100 - _protocolPips(lpBps, uint16(word >> 208));
            royalty = z.quoteBasis * (lpNet * royaltyBps / BPS) / PIPS;
            if (royalty > protocol) royalty = protocol;
            protocol -= royalty;
            if (royalty != 0) claims[b.config.royaltyTo] += royalty;
        }
        if (protocol != 0 && b.terms & TERMS_INTEGRATOR != 0) {
            S.Integration storage n = s.integrations[x.id];
            uint256 cut = protocol * n.bps / BPS;
            if (cut != 0) {
                claims[n.integrator] += cut;
                protocol -= cut;
                emit IntegratorPaid(x.id, x.quote, n.integrator, cut);
            }
        }
        if (protocol != 0) {
            bytes32 slot = _protocolPaidSlot(x.payer, x.quote);
            _put(slot, _get(slot) + protocol);
        }
        if (z.advisoryFee != 0) {
            if (z.advisoryRecipient == address(0)) revert InvalidSettlement();
            claims[z.advisoryRecipient] += z.advisoryFee;
            s.advisoryFees[x.id] += z.advisoryFee;
        }
        if (z.refund != 0) claims[x.payer] += z.refund;
        uint256 explicit = credited - protocol;
        if (explicit != 0) s.liabilities[x.quote] += explicit;
        // Event fallback remains on until core-bound CC72/D36 proves exact replay, including explicit Hookr claims.
        if (!QUIET_PROTOCOL_EVENTS || explicit != 0)
            emit FeesAllocated(x.id, x.quote, protocol, royalty, z.refund, z.advisoryRecipient, z.advisoryFee);
    }

    function _settleGuard(HookrTypes.SwapContext calldata x, HookrTypes.Settlement calldata z,
        S.Bound storage b, bool launchBuy) private
    {
        // Called only inside the guard window (settleSwap).
        HookrTypes.RulesConfig storage c = b.config;
        uint256 parentBlock = HookrTime.parentBlock();
        if (c.maxBuyQuoteAmount == 0) return;
        S.State storage s = _state();
        // R4-3: a launch family's members share one cap, counted in fractions of each buy's own cap at the family
        // anchor's guard word (S.TERMS_FAMILY; the anchor has no anchor entry and counts at its own id).
        bool family = b.terms & S.TERMS_FAMILY != 0;
        PoolId key = x.id;
        if (family) {
            bytes32 anchorSlot = S.familyAnchorSlot(x.id);
            bytes32 anchor;
            assembly ("memory-safe") { anchor := sload(anchorSlot) }
            if (anchor != 0) key = PoolId.wrap(anchor);
        }
        uint256 word = s.guard[key];
        uint256 spent = word >> 192 == parentBlock ? word & GUARD_MASK : 0;
        if (x.isBuy) {
            uint256 limit = _guardLimit(x.id, b, c);
            uint256 amount = z.quoteBasis;
            if (family) (amount, limit) = (amount * S.FAMILY_CAP_SCALE / limit, S.FAMILY_CAP_SCALE);
            if (family && launchBuy) {
                // The launch buy keeps its own cap and closes the family's parent block, whatever a sibling's
                // launch buy left in it.
                if (amount > limit) revert GuardBuyLimit(amount, limit);
                spent = GUARD_MASK;
            } else {
                spent += amount;
                if (spent > limit) revert GuardBuyLimit(spent, limit);
                if (word == 0 && launchBuy) spent = GUARD_MASK;
            }
            s.guard[key] = (parentBlock << 192) | spent;
        } else if (spent != 0 && !family) {
            // A sell frees room only on a lone pool, where it is counted in the same pool's quote as the buys it
            // frees. A family member's sell frees none: in fractions of its own cap it would refill a sibling's
            // larger cap, again and again in one parent block (attack round 1, CORE-1).
            uint256 amount = z.quoteBasis;
            spent = spent > amount ? spent - amount : 0;
            s.guard[key] = (parentBlock << 192) | spent;
        }
    }
    /// @dev The parent block's buy cap now: maxBuyQuoteAmount, scaled by the Snipe's start over its current value on a
    ///      decaying Snipe (the counter's width at a zero tax).
    function _guardLimit(PoolId id, S.Bound storage b, HookrTypes.RulesConfig storage c) private view returns (uint256 limit) {
        limit = c.maxBuyQuoteAmount;
        if (c.snipeDecaySeconds != 0) {
            uint256 start = c.snipeTaxPips;
            uint256 snipe = _snipePips(id, b, start, c.snipeDecaySeconds);
            limit = snipe == 0 ? GUARD_MASK : limit * start / snipe;
        }
    }
    function _settleCrown(HookrTypes.SwapContext calldata x, HookrTypes.Settlement calldata z) private {
        (uint64 end, uint128 smallest) = S.crownGateValues(S.crown().gates[x.id]);
        bool run = block.timestamp >= end || (x.isBuy && x.authenticated && z.quoteBasis >= smallest)
            || (!x.isBuy && _get(_poolSlot(S.T_PREV, x.id)) != 0);
        if (run) {
            uint256 xOffset = _cleanContext(x);
            bytes memory input=_frame(IHookrRules.settleSwap.selector,xOffset,416,288);
            address root=trustedRoot;
            assembly("memory-safe"){calldatacopy(add(input,452),z,256) mstore(add(input,708),root)}
            uint256[4] memory answer = _call(recapture,input,32);
            if (answer[0] != 0) revert InvalidSettlement();
        } else if (!x.isBuy) _put(_poolSlot(S.T_SOLD, x.id), 1);
    }
    /// @dev A pool with no block active on this swap returns at once: no module ran at its quote in this swap (the
    ///      same settings and parent block hold for the whole transaction), so no final take, charge or
    ///      nothing-to-settle mark was written for it, and none needs clearing (G1a gas pass, 2026-10-15).
    function _settleBlocks(HookrTypes.SwapContext calldata x, HookrTypes.Settlement calldata z,
        S.Bound storage b, bool launchBuy, uint32 hot, bool guard) private returns (uint256 protocol)
    {
        protocol = z.rulesFee;
        if (hot == 0) return protocol;
        bytes32 takeSlot = _poolSlot(S.FINAL_TAKE, x.id);
        uint256 finalTake = _get(takeSlot);
        if (finalTake > type(uint24).max) revert InvalidSettlement();
        _put(takeSlot, 0);
        uint256 masks = x.isBuy ? buySettleMasks : sellSettleMasks;
        uint128 cold = _cold(b, masks, hot);
        bytes memory input;
        {
            uint256 xOffset = _cleanContext(x);
            input = _frame(IHookrBlock.blockSettle.selector, xOffset, 416, 384);
            assembly ("memory-safe") { calldatacopy(add(input,452), z, 256) }
            _tail4(input, _context(S.Hook.Settle, x, b, false, launchBuy, guard), cold, finalTake, protocol);
        }
        // A slot's transient flags (nothing to settle, its charge) are written only by its module, in this swap's quote
        // or settle: only those slots are read and cleared (G1a gas pass; every slot was before).
        uint256 touched = masks | (x.isBuy ? buyQuoteMasks : sellQuoteMasks);
        for (uint8 slot; slot < 4; ++slot) {
            if (!_runs(touched, slot, hot)) continue;
            bytes32 nothing = S.nothingToSettleSlot(x.id, slot);
            bool skip = _get(nothing) != 0;
            _put(nothing, 0);
            if (!skip && _runs(masks, slot, hot)) _answer(_module(slot), input, 1, false);
            _put(S.chargeSlot(x.id, slot), 0);
        }
        // The last running module's answer, never above the protocol share it was given (`_answer`).
        assembly ("memory-safe") { protocol := mload(add(input, mload(input))) }
    }

    function claimable(Currency currency, address beneficiary) external view returns (uint256 amount) {
        S.State storage s = _state();
        amount = s.claims[currency][beneficiary];
        if (beneficiary == protocolRecipient)
            amount += HookrCoreState.residual(poolManager.balanceOf(address(this), currency.toId()), s.liabilities[currency]);
    }

    function _module(uint8 slot) private view returns (address) {
        if (slot == 0) return block0;
        if (slot == 1) return block1;
        if (slot == 2) return block2;
        if (slot == 3) return block3;
        revert InvalidBlockModule();
    }
    function _settingsHot(uint32 carrier) private pure returns (uint32) { return carrier & 0x3fffffff; }
    function _active(uint32 carrier, bool guard) private view returns (uint32 hot) {
        hot = _settingsHot(carrier);
        if (!guard) hot &= ~guardOnlyBits;
    }
    function _runs(uint256 masks, uint8 slot, uint32 hot) private pure returns (bool) {
        return hot & uint32(masks >> (uint256(slot) * 32)) != 0;
    }
    /// @dev The cold word when a slot that runs reads it: per slot, hot meets both the slot's masks and its
    ///      coldReadMasks, unrolled (G1a gas pass).
    function _cold(S.Bound storage b, uint256 masks, uint32 hot) private view returns (uint128) {
        uint256 colds = coldReadMasks;
        bool need;
        assembly ("memory-safe") {
            let m := 0xffffffff
            need := or(or(and(iszero(iszero(and(hot, and(masks, m)))), iszero(iszero(and(hot, and(colds, m))))),
                and(iszero(iszero(and(hot, and(shr(32, masks), m)))), iszero(iszero(and(hot, and(shr(32, colds), m)))))),
                or(and(iszero(iszero(and(hot, and(shr(64, masks), m)))), iszero(iszero(and(hot, and(shr(64, colds), m))))),
                and(iszero(iszero(and(hot, and(shr(96, masks), m)))), iszero(iszero(and(hot, and(shr(96, colds), m)))))))
        }
        return need ? b.config.potMinBuyQuote : 0;
    }
    function _context(S.Hook hook, HookrTypes.SwapContext calldata x, S.Bound storage b,
        bool staticMode, bool launchBuy, bool guard) private view returns (uint256)
    {
        return S.context(hook, (staticMode ? S.CTX_STATIC : 0) | (x.isBuy ? S.CTX_BUY : 0)
            | (x.authenticated ? S.CTX_AUTHENTICATED : 0) | (guard ? S.CTX_GUARD : 0)
            | (launchBuy ? S.CTX_LAUNCH_BUY : 0) | (b.terms & S.TERMS_LANE != 0 ? S.CTX_LANE : 0));
    }
    function _call(address module, bytes memory input, uint256 length) private returns (uint256[4] memory words) {
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            ok := delegatecall(gas(), module, add(input, 32), mload(input), words, length)
            size := returndatasize()
            if iszero(ok) {
                let free := mload(0x40)
                returndatacopy(free, 0, size)
                revert(free, size)
            }
        }
        if (size != length) revert InvalidSettlement();
    }
    /// @dev DELEGATECALLs `module` with `input` and checks its answer of `n` words against the last `n` words of
    ///      `input`, which it then replaces: a quote answer (`up`) may raise each word and lower none, a settle answer
    ///      may lower the protocol share and raise nothing. A revert is passed on; an answer of another length, or one
    ///      that moves a word the wrong way, is refused. The answer lands past the free memory pointer, which is not
    ///      moved: no array is allocated per call (G1a gas pass).
    function _answer(address module, bytes memory input, uint256 n, bool up) private {
        bytes4 refusal = InvalidSettlement.selector;
        assembly ("memory-safe") {
            let out := mload(0x40)
            let size := shl(5, n)
            if iszero(delegatecall(gas(), module, add(input, 32), mload(input), out, size)) {
                returndatacopy(out, 0, returndatasize())
                revert(out, returndatasize())
            }
            if iszero(eq(returndatasize(), size)) { mstore(0, refusal) revert(0, 4) }
            let tail := sub(add(add(input, 32), mload(input)), size)
            for { let i := 0 } lt(i, size) { i := add(i, 32) } {
                let a := mload(add(out, i))
                let was := mload(add(tail, i))
                if or(and(up, lt(a, was)), and(iszero(up), gt(a, was))) { mstore(0, refusal) revert(0, 4) }
                mstore(add(tail, i), a)
            }
        }
    }
    function _viewCall(address module, bytes memory input, uint256 length) private view returns (uint256[4] memory) {
        function(address,bytes memory,uint256) internal returns (uint256[4] memory) f = _call;
        function(address,bytes memory,uint256) internal view returns (uint256[4] memory) v;
        assembly ("memory-safe") { v := f }
        return v(module, input, length);
    }
    /// @dev HookrRulesStorage.poolTransient (keccak256(abi.encode(domain, id))), hashed in scratch space.
    function _poolSlot(bytes32 domain, PoolId id) private pure returns (bytes32 slot) {
        assembly ("memory-safe") { mstore(0, domain) mstore(32, id) slot := keccak256(0, 64) }
    }
    /// @dev HookrRulesStorage.protocolPaidSlot (keccak256(abi.encode(PROTOCOL_PAID, payer, quote))), hashed in
    ///      scratch memory past the free pointer.
    function _protocolPaidSlot(address payer, Currency quote) private pure returns (bytes32 slot) {
        bytes32 domain = S.PROTOCOL_PAID;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, domain) mstore(add(p, 32), payer) mstore(add(p, 64), quote)
            slot := keccak256(p, 96)
        }
    }
    function _get(bytes32 slot) private view returns (uint256 word) { assembly ("memory-safe") { word := tload(slot) } }
    function _put(bytes32 slot, uint256 word) private { assembly ("memory-safe") { tstore(slot, word) } }

    /// @dev All module forwarding appends the immutable root, preserving the original caller.
    function _forward(address module) private {
        address root = trustedRoot;
        assembly ("memory-safe") {
            let free := mload(0x40)
            calldatacopy(free, 0, calldatasize())
            mstore(add(free, calldatasize()), root)
            let ok := delegatecall(gas(), module, free, add(calldatasize(), 32), 0, 0)
            returndatacopy(free, 0, returndatasize())
            if iszero(ok) { revert(free, returndatasize()) }
            return(free, returndatasize())
        }
    }
    fallback() external {
        bytes4 selector = msg.sig;
        // Lane hot routes first; every selector is pinned in the composed ABI evidence.
        if (selector == IHookrLaneRules.recaptureMode.selector || selector == IHookrLaneRules.flushRecapture.selector
            || selector == IHookrLaneRules.settleRecapture.selector || selector == IHookrLaneRules.settleLeg.selector) _forward(recapture);
        if (selector == RECAPTURE_MODULE_SELECTOR && msg.data.length == 4) {
            address module = recapture;
            bytes32 hash = recaptureCodeHash;
            assembly ("memory-safe") { mstore(0, module) mstore(32, hash) return(0,64) }
        }
        // blockCall(uint256,bytes): a block's out-of-swap entry, run in HookrBinder (G1a, 2026-10-15).
        if (selector == BLOCK_CALL_SELECTOR) _toBinder();
        if (selector == bytes4(keccak256("claim(address)")) || selector == bytes4(keccak256("claimTo(address,address)"))
            || selector == bytes4(keccak256("claimAsClaims(address,address)")) || selector == IUnlockCallback.unlockCallback.selector)
            _forward(claimsModule);
        if (selector == bytes4(keccak256("extsload(bytes32)")) && msg.data.length == 36) {
            assembly ("memory-safe") { mstore(0, sload(calldataload(4))) return(0,32) }
        }
        if (selector == CARRY_LEG_SELECTOR) { _carryLeg(); return; }
        if (selector == IHookrRecaptureBind.bindRecapture.selector) revert Unauthorized();
        _forward(recapture);
    }

    /// @dev Public dispatcher checks minimum argument length. Restore every flat field's canonical width
    /// before copying its bytes. (The PoolKey and PoolConfig head is checked in HookrBinder, with the key tick
    /// signed24.)
    /// @dev Every SwapContext word clean before its raw frame is copied to a module (fields the core itself reads are
    ///      checked by Solidity on access, as in the release). Returns the context's calldata offset. The widths in one
    ///      test (G1a gas pass; was a loop over a width table, about 100 gas a word): word 0 the pool id and word 10
    ///      amountSpecified take any value, words 1-5 are addresses, 6-9 bools, 11 a uint160 and 12 a uint24.
    function _cleanContext(HookrTypes.SwapContext calldata x) private pure returns (uint256 xOffset) {
        bytes4 refusal = InvalidSettlement.selector;
        assembly ("memory-safe") {
            xOffset := x
            let dirty := or(or(or(shr(160, calldataload(add(x, 32))), shr(160, calldataload(add(x, 64)))),
                or(shr(160, calldataload(add(x, 96))), shr(160, calldataload(add(x, 128))))),
                or(or(shr(160, calldataload(add(x, 160))), shr(1, calldataload(add(x, 192)))),
                or(shr(1, calldataload(add(x, 224))), shr(1, calldataload(add(x, 256))))))
            dirty := or(dirty, or(or(shr(1, calldataload(add(x, 288))), shr(160, calldataload(add(x, 352)))),
                shr(24, calldataload(add(x, 384)))))
            if dirty {
                mstore(0, refusal)
                revert(0, 4)
            }
        }
    }
    function _frame(bytes4 selector, uint256 source, uint256 head, uint256 tail) private pure returns (bytes memory input) {
        input = new bytes(4 + head + tail);
        assembly ("memory-safe") {
            let start := add(input,32)
            mstore(start,selector)
            calldatacopy(add(start,4),source,head)
        }
    }
    function _tail4(bytes memory input,uint256 a,uint256 b,uint256 c,uint256 d) private pure {
        assembly ("memory-safe") {
            let end:=add(input,mload(input))
            mstore(sub(end,96),a) mstore(sub(end,64),b) mstore(sub(end,32),c) mstore(end,d)
        }
    }
    function _storeDynamic(PoolId id,S.DynamicFeeState memory g) private {
        bytes32 slot=HookrCoreState.dynamicFeeSlot(id);
        uint256 word=_packDynamic(g);
        assembly ("memory-safe") {sstore(slot,word)}
    }

}
