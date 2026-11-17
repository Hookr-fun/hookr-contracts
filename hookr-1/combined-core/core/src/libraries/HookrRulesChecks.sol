// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {HookrDynamicFee} from "./HookrDynamicFee.sol";
import {HookrRulesStorage as S} from "./HookrRulesStorage.sol";
import {HookrSettings} from "./HookrSettings.sol";
import {HookrBlockBound as B} from "./HookrBlockBound.sol";
import {HookrBlockKeys} from "./HookrBlockKeys.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrTreasury} from "../interfaces/IHookrTreasury.sol";
import {IHookrRules} from "../interfaces/IHookrRules.sol";
import {HookrTime} from "./HookrTime.sol";

/// @notice Two linked view bind stages; no state write or module dispatch lives in this library.
/// @dev Core copies production inputs locally; fee/knob helper extraction retains reviewed K21 rounding.
library HookrRulesChecks {
    struct Wiring {
        address rules;
        address root;
        address manager;
        address recipient;
        address recapture;
        address claims;
        address checks;
        address simulator;
        address[4] blocks;
        IHookrRegistry registry;
        uint256 minShare;
        bool rootSimulates;
        bytes32 hookrTokenCodeHash;
        address partScope;
        uint8 allowed;
        uint32 wiredHot;
        uint128 wiredCold;
    }
    struct Terms {
        HookrTypes.RulesConfig config;
        HookrTypes.RulesKnobs knobs;
        HookrTypes.RecaptureConfig recaptureConfig;
        uint256 floor;
        uint16 integratorBps;
        uint16 minFee;
        uint8 flags;
        bool custom;
        bool tempo;
        bool lane;
        bool funded;
        uint32 prizeCap;
    }
    error InvalidConfig();
    error UnknownIntegrator(address integrator);
    error BlockNotAdmitted(uint8 index);
    uint256 private constant PIPS = 1_000_000;
    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_INTEGRATOR_BPS = 5_000;
    uint256 private constant MAX_MIN_FEE_PIPS = 10_000;
    bytes4 private constant EXCLUSIVE_GROUP_SELECTOR = 0x5ac238e9;
    uint256 private constant GROUP_READ_GAS = 10_000;
    bytes32 private constant TAX_CONVERSION_GROUP = keccak256("DIRECTIONAL_QUOTE_TAX");
    /// @dev R4-1: RulesConfig.potEveryNBuys bit 18, "no arb recapture" (`_stripOptOut`).
    uint32 internal constant NO_RECAPTURE = uint32(1) << 18;
    /// @dev Root v2's `laneSource()` (DESIGN 20.2), read with a bounded gas for an owned companion.
    /// @dev HookrRecapture.defaultLane(address,address,bool), a left-aligned literal for assembly;
    ///      `test_selectorLiterals` checks it against the module's selector.
    uint256 internal constant DEFAULT_LANE_SELECTOR = 0xe058e30e00000000000000000000000000000000000000000000000000000000;


    /// @dev 16 words: core/root/PM/protocol/Recapture/Claims/Checks/ViewSwap, four blocks,
    /// registry, token codehash, part scope, control. Control: minShare16 at0/rootSim1 at16/
    /// allowed8 at17/hot32 at25/cold128 at57; reserved185+. No identity is omitted.
    function _cleanWire(uint256[16] calldata a) private pure {
        // In assembly (G1a gas rows): words 0-14 but 13 are clean addresses, word 15 has no bit at 185 or above.
        bytes4 refusal = InvalidConfig.selector;
        assembly ("memory-safe") {
            let bad := shr(185, calldataload(add(a, 480)))
            for { let i := 0 } lt(i, 15) { i := add(i, 1) } {
                if iszero(eq(i, 13)) { bad := or(bad, shr(160, calldataload(add(a, shl(5, i))))) }
            }
            if bad {
                mstore(0, refusal)
                revert(0, 4)
            }
        }
    }

    /// @dev Four validated calldata words; avoid expanding the capsule into an unused14-word PoolConfig.
    function _cleanPool(uint256[4] memory a) private pure {
        if (a[0] >> 160 != 0 || a[1] >> 168 != 0 || a[2] >> 160 != 0 || a[3] >> 88 != 0) revert InvalidConfig();
    }

    // RulesConfig16, RulesKnobs6, RecaptureConfig8: widths in original ABI word order.
    bytes32 private constant DATA_WIDTHS = hex"2818181810101010101010208080a0a060101010180801101020101080200000";
    function _data(bytes calldata data) private pure returns
        (HookrTypes.RulesConfig memory c, HookrTypes.RulesKnobs memory k, HookrTypes.RecaptureConfig memory rc)
    {
        uint256 length=data.length;
        if (length != 512 && length != 704 && length != 960) revert InvalidConfig();
        bytes4 refusal=InvalidConfig.selector;
        // Every present word within its DATA_WIDTHS width, as before, unrolled at the fixed widths (G1a gas pass):
        // the sixteen config words, the six knobs from 704 bytes on, the eight recapture words at 960.
        assembly ("memory-safe") {
            let o := data.offset
            let bad := or(or(or(or(shr(40,calldataload(add(o,0))),shr(24,calldataload(add(o,32)))),or(shr(24,calldataload(add(o,64))),shr(24,calldataload(add(o,96))))),or(or(shr(16,calldataload(add(o,128))),shr(16,calldataload(add(o,160)))),or(shr(16,calldataload(add(o,192))),shr(16,calldataload(add(o,224)))))),or(or(or(shr(16,calldataload(add(o,256))),shr(16,calldataload(add(o,288)))),or(shr(16,calldataload(add(o,320))),shr(32,calldataload(add(o,352))))),or(or(shr(128,calldataload(add(o,384))),shr(128,calldataload(add(o,416)))),or(shr(160,calldataload(add(o,448))),shr(160,calldataload(add(o,480)))))))
            if iszero(lt(length, 704)) { bad := or(bad, or(or(or(shr(96,calldataload(add(add(o,512),0))),shr(16,calldataload(add(add(o,512),32)))),or(shr(16,calldataload(add(add(o,512),64))),shr(16,calldataload(add(add(o,512),96))))),or(shr(24,calldataload(add(add(o,512),128))),shr(8,calldataload(add(add(o,512),160)))))) }
            if eq(length, 960) { bad := or(bad, or(or(or(shr(1,calldataload(add(add(o,704),0))),shr(16,calldataload(add(add(o,704),32)))),or(shr(16,calldataload(add(add(o,704),64))),shr(32,calldataload(add(add(o,704),96))))),or(or(shr(16,calldataload(add(add(o,704),128))),shr(16,calldataload(add(add(o,704),160)))),or(shr(128,calldataload(add(add(o,704),192))),shr(32,calldataload(add(add(o,704),224))))))) }
            if bad {
                mstore(0, refusal)
                revert(0, 4)
            }
        }
        assembly ("memory-safe") {
            c:=mload(0x40) k:=add(c,512) rc:=add(k,192)
            mstore(0x40,add(rc,256))
            for {let p:=k} lt(p,add(rc,256)) {p:=add(p,32)} {mstore(p,0)}
            calldatacopy(c,data.offset,length)
        }
    }

    function terms(uint256[16] calldata w, uint256[4] memory pool, bytes calldata data, PoolId id)
        internal view returns (uint256 metadata)
    {
        _cleanWire(w); _cleanPool(pool);
        (metadata,,,) = termsParsed(w, pool, data, id);
    }

    /// @dev `terms`, also answering the Rules data it parsed and checked (every width, exact length, zeroed absent
    ///      tails), so HookrBinder binds and stores those words without a second copy. Nothing here writes them.
    ///      The wiring and pool capsule are taken as clean: HookrBinder's come from the core's immutables (written
    ///      by the core after the calldata) and from PoolConfig fields Solidity validated on access; `terms` checks
    ///      them for any other caller (G1a gas pass).
    function termsParsed(uint256[16] calldata w, uint256[4] memory pool, bytes calldata data, PoolId id)
        internal view returns (uint256 metadata, HookrTypes.RulesConfig memory c, HookrTypes.RulesKnobs memory k,
            HookrTypes.RecaptureConfig memory rc)
    {
        (c, k, rc) = _data(data);
        // R4-1 (next core 10-22): recapture on by default. Rules data with a recapture part asks for it (`on`) or opts
        // out (`on == false`; its other words are not read); RulesConfig's NO_RECAPTURE bit opts out in every form,
        // so a launcher that drops an off recapture part still reaches it; any other data takes the recapture module's
        // own `recaptureDefaults()` whenever the lane source's registry lane is open (`_defaultLane`), none when closed.
        // NO_RECAPTURE is potEveryNBuys bit 18, reserved in the v1 settings word, carried alone or in a versioned word
        // (bits 30-31 = 1) beside any blocks, and cleared before anything reads the word: the pool stores the word without
        // it, and a word left with only its version bits and no cold field is the no-block word, zero.
        bool optOut;
        bool lane;
        bytes4 refusal = InvalidConfig.selector;
        uint256 length = data.length;
        assembly ("memory-safe") {
            let hotAt := add(c, 352)
            let hot := mload(hotAt)
            optOut := and(shr(18, hot), 1)
            if optOut {
                // What is left is checked as any settings word (`checkSettings`: versioned unless zero).
                hot := xor(hot, 0x40000)
                if and(eq(hot, 0x40000000), iszero(mload(add(c, 416)))) { hot := 0 }
                mstore(hotAt, hot)
            }
            if eq(length, 960) {
                // A recapture part beside NO_RECAPTURE must be off; an off part's other words bind nothing.
                lane := mload(rc)
                if and(lane, optOut) { mstore(0, refusal) revert(0, 4) }
            }
        }
        uint32 hot=c.potEveryNBuys;uint128 cold=c.potMinBuyQuote;checkSettings(hot,cold);
        if (length != 960 && !optOut) lane = _defaultLane(w, rc);
        bool crown = lane && rc.period != 0;
        bool funded = crown && (c.potBps == 0
            || ((hot&127) != 0 && ((hot>>14)&7) == 3)
            || (((hot>>7)&127) != 0 && (((hot>>24)&7) == 0 ? ((hot>>14)&7) : ((hot>>24)&7)) == 3)
            || ((hot&(uint32(1)<<20)!=0) && ((cold>>42)&7) == 3) || ((hot&(uint32(1)<<22)!=0) && ((cold>>82)&7) == 3)
            || ((hot&(uint32(1)<<17)!=0) && ((cold>>120)&7) == 3));
        uint256 control = w[15];
        uint8 enabled = B.enabledBlocks(c.potEveryNBuys, c.potMinBuyQuote, crown);
        if (enabled & ~uint8(control >> 17) != 0 || c.potEveryNBuys & 0x3fffffff & ~uint32(control >> 25) != 0
            || c.potMinBuyQuote & ~(uint128(control >> 57) | (crown ? uint128(131071) << 97 : uint128(0))) != 0) revert InvalidConfig();
        address scope = address(uint160(w[14]));
        IHookrRegistry registry = IHookrRegistry(address(uint160(w[12])));
        if (scope != address(uint160(w[0]))) {
            address templateRoot = IHookrRules(scope).trustedRoot();
            uint256[11] memory template = _admission(address(registry),templateRoot,scope);
            if (address(uint160(template[1])) != scope || template[0] != uint256(IHookrRegistry.Kind.RULES)
                || bytes32(template[2]) != scope.codehash || !registry.isRoot(templateRoot)) revert InvalidConfig();
        }
        bytes32 initHash = enabled != 0 ? HookrBlockKeys.initCodeHash() : bytes32(0);
        // An admitted key ran HookrBlockKey's runtime when the registry admitted it (`_checkAdmission` compares the
        // codehash), and an empty contract's code never changes, so the admission's pinned hash against that runtime's
        // stands for reading the key's code (G1a gas pass: a cold account per key).
        bytes32 keyHash = enabled != 0 ? HookrBlockKeys.runtimeCodeHash() : bytes32(0);
        for (uint8 i; i < 8; ++i) if (enabled & (uint8(1) << i) != 0) {
            address key = HookrBlockKeys.keyWith(scope, i, initHash);
            uint256[11] memory a = _admission(address(registry),scope,key);
            if (address(uint160(a[1])) != key || a[0] != uint256(IHookrRegistry.Kind.RULES) || bytes32(a[2]) != keyHash
                || a[8] == 0 || a[10] != 0) revert BlockNotAdmitted(i);
        }
        // On Monad (143) every dynamic fee pool is priced by the root's own simulation, on the transaction's gas: the
        // in-core walk's budget is counted at the EIP-2929 cold prices of 4663 and 1, and Monad's cold reads (8,100 a
        // slot, 10,100 an account) would run the walks it allows past the Rules call's 2,000,000 (attack round 1,
        // CORE-2). Every root simulates (both answer 1 to an empty call), so no 143 dynamic fee pool is refused.
        bool rootSimulation = c.dynamicFeeSens != 0 && (lane || block.chainid == HookrTime.MONAD_CHAIN_ID
            || (address(uint160(pool[1])) != address(0) && uint8(pool[1] >> 160) & HookrTypes.BEFORE_SWAP != 0));
        bool rootSimulates = control & (uint256(1) << 16) != 0;
        if (rootSimulation && !rootSimulates) revert InvalidConfig();
        (bool custom, bool tempo) = _checkKnobs(rootSimulates || !rootSimulation, c, k, data.length >= 704, data.length == 960);
        (uint256 floor, uint256 integrator, uint256 minimum) = _feeTerms(w, c.integrator, lane, id);
        // R4-2 (next core 10-22): a lane pool keeps the minimum the treasury gives lane pools (`feeTerms(.., true, ..)`,
        // 0 today, D12), so a later treasury change reaches new lane pools without a new Rules.
        if (_earnsHookr(c, uint24(pool[3])) || address(uint160(pool[0])).codehash != bytes32(w[13])
            || _taxConversion(w, address(uint160(pool[1])), c.protocolShareBps)) minimum = 0;
        if (c.integrator != address(0) && _forbidden(w, c.integrator)) revert UnknownIntegrator(c.integrator);
        uint8 flags = (integrator != 0 ? S.TERMS_INTEGRATOR : 0) | (minimum != 0 ? S.TERMS_MINIMUM : 0)
            | (custom ? S.TERMS_KNOBS : 0) | (lane ? S.TERMS_LANE : 0) | (rootSimulation ? S.TERMS_ROOT_SIM : 0);
        metadata = floor | integrator << 16 | minimum << 32 | uint256(flags) << 48
            | uint256(custom ? 1 : 0) << 56 | uint256(tempo ? 1 : 0) << 57 | uint256(lane ? 1 : 0) << 58
            | uint256(funded ? 1 : 0) << 59 | uint256(uint32((cold>>97)&131071)) << 60;
    }

    /// @dev R4-1: whether the lane source's registry lane is open, filling `rc` with the recapture module's
    ///      `recaptureDefaults()` when it is. The lane source is this core's trustedRoot (w[1]) for the template
    ///      instance, and for an owned companion its part scope's (the template's) trustedRoot: a companion's own root
    ///      holds a braked copy of the lane (DESIGN 20.1, 20.2). A registry that does not answer `activeLaneOf` in four
    ///      words reads as a closed lane: the root then freezes no lane either (`HookrLane._freeze` refuses a
    ///      recapture pool without one), so no pool can bind recapture the root will not run. The defaults must be a
    ///      plain lane (period 0, no pot), or the bind refuses. A module call that reverts refuses the bind with its
    ///      reason (AL-1: an owned companion whose root does not answer `laneSource()`).
    function _defaultLane(uint256[16] calldata w, HookrTypes.RecaptureConfig memory rc) private view returns (bool open) {
        // HookrRecapture.defaultLane(registry, trustedRoot, companion), static: the recapture module's defaults while
        // the lane source's registry lane is open, all zero otherwise. A companion's part scope is not this core.
        // The wiring words are clean addresses here: HookrBinder's come from the core's immutables, and `terms`
        // checks them (`_cleanWire`) for any other caller.
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, DEFAULT_LANE_SELECTOR)
            mstore(add(p, 4), calldataload(add(w, 384)))
            mstore(add(p, 36), calldataload(add(w, 32)))
            mstore(add(p, 68), iszero(eq(calldataload(add(w, 448)), calldataload(w))))
            // The call first: Yul evaluates arguments right to left, so returndatasize() must follow it.
            let ok := staticcall(gas(), calldataload(add(w, 128)), p, 100, rc, 256)
            // A refusal is passed on (AL-1: HookrRecapture's LaneSourceUnanswered, an owned companion whose root did
            // not answer laneSource()), so a failed read never binds a pool as if its deployer had opted out. A module
            // that answers, but not in eight words, gives no default; `rc` is then not read (no lane, and the effective
            // data is the data as sent).
            if iszero(ok){let free:=mload(0x40) returndatacopy(free,0,returndatasize()) revert(free,returndatasize())}
            open := and(eq(returndatasize(), 256), mload(rc))
        }
    }

    function validate(uint256[16] calldata w, uint256[4] memory pool, bytes calldata data, uint256 metadata, uint256 blockBound)
        internal view
    {
        _cleanWire(w); _cleanPool(pool);
        (HookrTypes.RulesConfig memory c,,) = _data(data);
        // As termsParsed: the NO_RECAPTURE bit cleared (the ChecksCapsule harness's entry; not in the binder).
        if (c.potEveryNBuys & NO_RECAPTURE != 0) {
            c.potEveryNBuys &= ~NO_RECAPTURE;
            if (c.potEveryNBuys == uint32(1) << 30 && c.potMinBuyQuote == 0) c.potEveryNBuys = 0;
        }
        uint32 hot=c.potEveryNBuys;uint128 cold=c.potMinBuyQuote;checkSettings(hot,cold);
        validateParsed(w, pool, c, data.length == 960, metadata, blockBound);
    }

    /// @dev `validate` on Rules data `termsParsed` already cleaned, parsed and settings-checked from the same wiring,
    ///      pool capsule and bytes in the same bind (HookrBinder), so those three steps are not repeated.
    function validateParsed(uint256[16] calldata w, uint256[4] memory pool, HookrTypes.RulesConfig memory c, bool lane,
        uint256 metadata, uint256 blockBound) internal view
    {
        if (metadata >> 77 != 0) revert InvalidConfig();
        uint256 floor = uint16(metadata);
        uint16 integrator = uint16(metadata >> 16);
        uint16 minimum = uint16(metadata >> 32);
        uint8 flags = uint8(metadata >> 48);
        B.Bound memory b = B.unpack(blockBound);
        uint32 hot=c.potEveryNBuys;uint128 cold=c.potMinBuyQuote;
        bool crown = flags & S.TERMS_CROWN != 0;
        if (c.protocolShareBps < floor || c.protocolShareBps > 5000 || c.maxFeePips < uint24(pool[3]) || c.maxFeePips > 600000
            || uint256(uint24(pool[3])) + c.snipeTaxPips > 600000 || c.dynamicFeeSens > 10
            || uint256(c.burnBps) + c.lpBps > 1000 || c.royaltyBps > 1000
            || (c.dynamicFeeSens == 0) != (c.maxFeePips == uint24(pool[3]))
            || (c.royaltyBps != 0 && (c.royaltyTo == address(0) || c.lpBps == 0))
            || (c.snipeDecaySeconds == 0 ? c.snipeFloorPips != 0 : c.snipeFloorPips >= c.snipeTaxPips)) revert InvalidConfig();
        if (c.guardEndBlock == 0) {
            if (c.snipeTaxPips != 0 || c.maxBuyQuoteAmount != 0 || c.snipeDecaySeconds != 0 || (hot&(uint32(1)<<19)!=0) || (hot&(uint32(1)<<23)!=0)) revert InvalidConfig();
        } else {
            // On Robinhood Chain `block.number` is the parent chain's height read from the L2 header, which moves by one or
            // two about every 15 seconds, not every 12 (measured, attack round 3 R3-1): so a guard keeps three spare parent
            // blocks there (36 seconds; the parent height's lag behind its 12-second slots fell by at most 30 seconds in
            // 72 hours of history, attack round 4 R4-1). Elsewhere the parent block is a 12-second slot. Stated limit: the
            // height can also stall and then catch up in one L2 block (135 and 333 seconds in the 28 days to 10-25, Opus
            // attack round OPC-1), and a guard bound during a stall counts from the stale height, so it ends at the
            // catch-up. No spare count bounds a stall and the chain exposes no parent timestamp, so the app and the SDK
            // count the guard from the parent chain's own head while the height is stale (SDK `parentHeadAfterStall`).
            uint256 spare = block.chainid == HookrTime.ROBINHOOD_CHAIN_ID ? 4 : 1;
            uint256 parentBlock = HookrTime.parentBlock() + spare;
            // A guard of N parent blocks may end (N - 1) x 12 seconds after its launch, as the launch can fall late in
            // its parent block: so a guard is at least two parent blocks, which keeps the launch-second refusal inside
            // it (the root skips the Rules of a fee-only pool from its guard's end), and the launch windows and a long
            // decay are measured against the guard's shortest length (attack round 1, B-2 and B-3).
            if (c.guardEndBlock <= parentBlock || c.guardEndBlock > parentBlock + 100000 - spare || address(uint160(pool[2])) == address(0)) revert InvalidConfig();
            // The guard's shortest length in parent blocks, the windows' own 12-second steps.
            uint256 guardBlocks = c.guardEndBlock - parentBlock;
            if ((c.snipeDecaySeconds > HookrTypes.MAX_SNIPE_DECAY_SECONDS
                    && c.snipeDecaySeconds > guardBlocks * HookrTypes.PARENT_BLOCK_SECONDS)
                || ((cold>>85)&511) > guardBlocks || ((cold>>94)&7) > guardBlocks) revert InvalidConfig();
        }
        uint8 outflows = b.buyOutflows | b.sellOutflows;
        if ((outflows & (uint8(1) << 2) != 0 && !(hot&(uint32(1)<<21)!=0))
            || (outflows & (uint8(1) << 3) != 0 && !crown) || (!crown && (c.potBps != 0 || uint32((cold>>97)&131071) != 0))
            || ((hot&(uint32(1)<<22)!=0) && c.dynamicFeeSens != 0) || ((hot&(uint32(1)<<17)!=0) && lane)
            || ((hot&(uint32(1)<<21)!=0) && lane && ((cold>>46)&63) > 14)) revert InvalidConfig();
        bool payee = outflows & (uint8(1) << 4) != 0;
        if (payee ? c.royaltyTo == address(0) : c.royaltyBps == 0 && c.royaltyTo != address(0)) revert InvalidConfig();
        if (c.royaltyTo != address(0) && _forbidden(w, c.royaltyTo)) revert InvalidConfig();
        if (uint256(b.sellMaxLp) + b.sellMaxTake > 200000) revert InvalidConfig();
        _caps(c, pool, minimum, b);
        if (crown) {
            bool funded = outflows & (uint8(1) << 3) != 0 || c.potBps == 0;
            if (funded && (uint32((cold>>97)&131071) == 0 || uint32((cold>>97)&131071) > 1000
                || uint32((cold>>97)&131071) > irrecoverableCap(c, integrator, b))) revert InvalidConfig();
        }
    }

    /// @dev Conservative proposed policy: actual quote minima only, pot saturation allowed, reviewed crown rebate50%.
    /// Amount-level Root/carve/coin-rounding proof and per-charge D36 refinement remain explicit integration gates.
    function irrecoverableCap(HookrTypes.RulesConfig memory c, uint16 integrator, B.Bound memory b)
        internal pure returns (uint256)
    {
        uint256 protocol = _protocolPips(c.lpBps, c.protocolShareBps) + _protocolPips(c.burnBps, c.protocolShareBps);
        // Gross other minima with an LP-fee outflow need an exact per-slice/clip proof; conservatively omit for now.
        if (b.buyOutflows & 1 == 0) protocol += uint256(b.minBuyOtherCharge) * c.protocolShareBps / BPS;
        uint256 quoteMinimum = uint256(b.minBuyPotCharge) + protocol;
        return quoteMinimum * (BPS - integrator) * 5000 / (100 * BPS * BPS);
    }

    function _caps(HookrTypes.RulesConfig memory c, uint256[4] memory pool, uint16 minimum, B.Bound memory b) private pure {
        (uint256 lpReward, uint256 take, uint16 burn, uint256 royalty) = _buyParts(c);
        uint256 base = uint24(pool[3]);
        if (base + lpReward > 600000) revert InvalidConfig();
        uint256 span = uint256(c.maxFeePips) - base;
        if (!HookrDynamicFee.withinReach(span, c.dynamicFeeSens, c.protocolShareBps)) revert InvalidConfig();
        uint256 room = 600000 - base - lpReward;
        uint256 dynamicFee = span < room ? span : room;
        uint256 snipe = c.snipeTaxPips < room - dynamicFee ? c.snipeTaxPips : room - dynamicFee;
        uint256 share = dynamicFee * c.protocolShareBps / BPS + snipe * c.protocolShareBps / BPS;
        uint256 minimumShare = share;
        if (span + c.snipeTaxPips > room && c.protocolShareBps != 0) {
            share = (dynamicFee + snipe) * c.protocolShareBps / BPS;
            minimumShare = share == 0 ? 0 : share - 1;
        }
        uint256 buyLp = base + lpReward + dynamicFee + snipe - minimumShare + b.buyMaxLp;
        uint256 sellLp = uint256(c.maxFeePips) + b.sellMaxLp;
        uint256 buyTake = take + share + b.buyMaxTake;
        uint256 withMinimum = royalty + uint256(b.buyMaxTake) + minimum;
        if (withMinimum > buyTake) buyTake = withMinimum;
        uint256 sellTake = span * c.protocolShareBps / BPS + b.sellMaxTake;
        withMinimum = uint256(b.sellMaxTake) + minimum;
        if (withMinimum > sellTake) sellTake = withMinimum;
        if (buyLp > uint24(pool[3] >> 24) || sellLp > uint24(pool[3] >> 24) || buyTake > uint24(pool[3] >> 48)
            || sellTake > uint24(pool[3] >> 48) || burn > uint16(pool[3] >> 72)) revert InvalidConfig();
    }

    function _forbidden(uint256[16] calldata w, address account) private pure returns (bool) {
        // Every original infrastructure identity remains forbidden; the protocol recipient is checked
        // separately for integrators and remains a permitted explicit creator payee.
        if (account == address(0)) return false;
        bool hit;
        // Wiring words 0-11 but 3 (the protocol recipient), each as its low 160 bits, in assembly (G1a gas pass).
        assembly ("memory-safe") {
            for { let i := 0 } lt(i, 12) { i := add(i, 1) } {
                if and(iszero(eq(i, 3)), eq(account, and(calldataload(add(w, shl(5, i))), 0xffffffffffffffffffffffffffffffffffffffff))) {
                    hit := 1
                }
            }
        }
        if (hit) return true;
        // The eight brake keys of the part scope.
        return HookrBlockKeys.isKey(address(uint160(w[14])), account);
    }

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

    function _protocolPips(uint256 bps, uint256 shareBps) private pure returns (uint256) {
        return (bps * shareBps + 99) / 100;
    }

    function _earnsHookr(HookrTypes.RulesConfig memory c, uint256 base) private pure returns (bool) {
        uint256 share = c.protocolShareBps;
        if (share == 0) return false;
        if (c.lpBps != 0 || c.burnBps != 0) return true;
        uint256 span = c.maxFeePips > base ? c.maxFeePips - base : 0;
        return span * share >= BPS || uint256(c.snipeTaxPips) * share >= BPS;
    }

    function _taxConversion(uint256[16] calldata w, address advisory, uint256 share) private view returns (bool) {
        if (advisory == address(0) || share == 0) return false;
        bytes32 group;
        assembly ("memory-safe") {
            mstore(0, EXCLUSIVE_GROUP_SELECTOR)
            // The call first: Yul evaluates arguments right to left, so returndatasize() must follow it.
            let ok := staticcall(GROUP_READ_GAS, advisory, 0, 4, 0, 32)
            if and(ok, eq(returndatasize(), 32)) { group := mload(0) }
        }
        return group == TAX_CONVERSION_GROUP && _admission(address(uint160(w[12])),msg.sender,advisory)[5] != 0;
    }

    /// @dev Exact raw-carrier equivalent of the frozen C1 decode/validate; no Settings memory expansion.
    /// Bit-width tautologies (e.g. one-bit unit/epoch and five-bit WC exponent) follow from extraction.
    function checkSettings(uint32 hot,uint128 cold) internal pure {
        if(hot==0&&cold==0)return;
        if(hot>>30!=1||hot&((uint32(1)<<18)|(uint32(7)<<27))!=0||cold>>123!=0)revert HookrSettings.InvalidSettings();
        uint256 buy=hot&127;uint256 sell=(hot>>7)&127;uint256 out=(hot>>14)&7;uint256 sellOut=(hot>>24)&7;
        if(buy>100||sell>100||(buy!=0||sell!=0?out==0||out>4:out!=0)
            ||sellOut!=0&&(buy==0||sell==0||sellOut>4||sellOut==out))revert HookrSettings.InvalidSettings();
        uint256 fields=uint256(cold)&((uint256(1)<<19)-1);
        if(hot&(uint32(1)<<19)==0){if(fields!=0)revert HookrSettings.InvalidSettings();}
        else {uint256 mantissa=fields&16383;if(mantissa==0||(fields>>14!=0&&mantissa*10<16384))revert HookrSettings.InvalidSettings();}
        fields=(uint256(cold)>>19)&((uint256(1)<<26)-1);
        if(hot&(uint32(1)<<20)==0){if(fields!=0)revert HookrSettings.InvalidSettings();}else _exitSettings(fields);
        fields=(uint256(cold)>>45)&((uint256(1)<<18)-1);
        if(hot&(uint32(1)<<21)==0){if(fields!=0)revert HookrSettings.InvalidSettings();}else _holderSettings(fields);
        fields=(uint256(cold)>>63)&((uint256(1)<<22)-1);
        if(hot&(uint32(1)<<22)==0){if(fields!=0)revert HookrSettings.InvalidSettings();}else _stormSettings(fields);
        fields=(uint256(cold)>>85)&4095;
        if(hot&(uint32(1)<<23)==0){if(fields!=0)revert HookrSettings.InvalidSettings();}
        else if((fields&511)>300||(fields>>9)>5||fields==0)revert HookrSettings.InvalidSettings();
        fields=(uint256(cold)>>114)&511;
        if(hot&(uint32(1)<<17)==0){if(fields!=0)revert HookrSettings.InvalidSettings();}
        else if(((fields>>2)&15)<5||(fields>>6)==0||(fields>>6)>4)revert HookrSettings.InvalidSettings();
        uint256 cap=(uint256(cold)>>97)&131071;
        if(cap>100000||hot&(uint32(0x3fff)|(uint32(1)<<17)|(uint32(31)<<19))==0&&cap==0)revert HookrSettings.InvalidSettings();
    }
    function _exitSettings(uint256 a) private pure {
        uint256 top=a&127;uint256 floor=(a>>7)&127;uint256 horizon=(a>>14)&63;
        if(top==0||top>100||floor>=top||(((a>>20)&1)==0?(horizon==0||horizon>63):(horizon<3||horizon>30)))
            revert HookrSettings.InvalidSettings();
        if(((a>>21)&3)>2||(a>>23)>4)revert HookrSettings.InvalidSettings();
    }
    function _holderSettings(uint256 a) private pure {
        uint256 age=(a>>1)&63;uint256 bounty=(a>>13)&31;
        if(age==0||age>56||((a>>7)&31)>20||bounty==0||bounty>20)revert HookrSettings.InvalidSettings();
    }
    function _stormSettings(uint256 a) private pure {
        uint256 ceiling=a&255;
        if(ceiling==0||ceiling>200||((a>>8)&255)>ceiling||((a>>16)&7)>3||(a>>19)>4)revert HookrSettings.InvalidSettings();
    }

    // Exact Admission ABI census: enum/address/hash/hash/three caps/gas/phases/two bools.
    // Preserve Solidity's minimum return length and validate even unused narrow fields.
    function _admission(address registry,address scope,address implementation) private view returns(uint256[11] memory a){
        a=_read(registry,IHookrRegistry.admission.selector,scope,uint160(implementation),0,11);
        // The admission's widths in one test (G1a gas pass; was a loop over a width table): kind at most 2,
        // implementation 160 bits, caps 24/24/16, gasLimit 32, phaseMask 8, feeOnly and failOpen 1 bit each.
        bool dirty;
        assembly("memory-safe"){
            dirty:=or(or(or(gt(mload(a),2),shr(160,mload(add(a,32)))),or(shr(24,mload(add(a,128))),shr(24,mload(add(a,160))))),
                or(or(shr(16,mload(add(a,192))),shr(32,mload(add(a,224)))),or(shr(8,mload(add(a,256))),or(shr(1,mload(add(a,288))),shr(1,mload(add(a,320)))))))
        }
        if(dirty)revert InvalidConfig();
    }
    function _read(address target,bytes4 selector,address first,uint256 second,uint256 third,uint256 words)
        private view returns(uint256[11] memory answer)
    {
        assembly("memory-safe"){
            answer:=mload(0x40)
            let input:=add(answer,352)
            mstore(0x40,add(input,128))
            for{let p:=answer}lt(p,input){p:=add(p,32)}{mstore(p,0)}
            mstore(input,selector) mstore(add(input,4),first) mstore(add(input,36),second) mstore(add(input,68),third)
            let size:=68
            if eq(words,3){size:=100}
            let ok:=staticcall(gas(),target,input,size,answer,mul(words,32))
            if iszero(ok){let free:=mload(0x40) returndatacopy(free,0,returndatasize()) revert(free,returndatasize())}
            if lt(returndatasize(),mul(words,32)){revert(0,0)}
        }
    }

    function _feeTerms(uint256[16] calldata w, address integrator, bool lane, PoolId id)
        private
        view
        returns (uint256 floor, uint256 integratorBps, uint256 minFee)
    {
        floor = uint16(w[15]);
        address recipient = address(uint160(w[3]));
        if (recipient.code.length != 0) {
            uint256[11] memory a=_read(recipient,IHookrTreasury.feeTerms.selector,integrator,lane?1:0,uint256(PoolId.unwrap(id)),3);
            for(uint256 i;i<3;++i)if(a[i]>>16!=0)revert InvalidConfig();
            if(a[0]>floor)floor=a[0];
            if(integrator!=address(0))integratorBps=a[1];
            minFee=a[2];
        }
        if (
            integrator != address(0)
                && (integratorBps == 0
                    || integratorBps > MAX_INTEGRATOR_BPS
                    || integrator == address(uint160(w[0]))
                    || integrator == address(uint160(w[1]))
                    || integrator == recipient
                    || integrator == address(uint160(w[2]))
                    || integrator == address(uint160(w[4])))
        ) revert UnknownIntegrator(integrator);
        if (minFee > MAX_MIN_FEE_PIPS) revert InvalidConfig();
    }

    function _checkKnobs(bool rootSimulationAllowed, HookrTypes.RulesConfig memory c, HookrTypes.RulesKnobs memory k, bool knobbed, bool lane)
        private
        pure
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
                !knobbed || k.minDynamicFeeLiquidity == 0 || !rootSimulationAllowed || window < HookrTypes.MIN_WINDOW_SECONDS
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
}
