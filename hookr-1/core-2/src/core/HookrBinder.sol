// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRecaptureBind} from "../interfaces/IHookrRecaptureBind.sol";
import {IHookrBlock} from "../interfaces/IHookrBlock.sol";
import {HookrRulesStorage as S} from "../libraries/HookrRulesStorage.sol";
import {HookrBlockBound as B} from "../libraries/HookrBlockBound.sol";
import {HookrRulesChecks as Checks} from "../libraries/HookrRulesChecks.sol";
import {HookrCoreState} from "../libraries/HookrCoreState.sol";
import {HookrTime} from "../libraries/HookrTime.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

/// @title HookrBinder
/// @notice The combined core's `bind`, moved out of the core so the core fits EIP-170 on every chain (Monad fold,
///         2026-10-15). The core's `bind` forwards its exact calldata here by DELEGATECALL and appends an 18-word
///         capsule of its immutables; this code runs in the core's storage, transient storage and event address, with
///         the core's caller as `msg.sender`, so the root, the Hook Block binds, the stored pool and `RulesBound` are what
///         the core wrote before the move, byte for byte. Bind runs once per pool and never on a swap: the move costs a
///         launch one cold account and one forward, and costs a swap nothing.
/// @dev The capsule, appended after the canonical bind calldata, is: word 0 the core's `bindMasks`, word 1 its
///      `guardOnlyBits`, words 2-17 the 16-word Checks wiring (HookrRulesChecks: core, root, PoolManager, protocol
///      recipient, Recapture, Claims, this binder, ViewSwap, four blocks, registry, Hookr token codehash, part scope,
///      control). HookrRulesChecks' `terms` and `validate` are internal here: the bind checks that were a linked
///      library of the core are compiled into this binder, and read the wiring straight from the capsule in calldata,
///      so word 6 (the checks' own identity, which they forbid as a payee) is this binder. The core pins this
///      contract's address and runtime codehash, so the core's admitted codehash fixes every byte that can bind a pool
///      in its storage. Only the core can supply a capsule its own storage trusts: called directly, this contract
///      refuses.
contract HookrBinder {
    using PoolIdLibrary for PoolKey;

    address private immutable SELF = address(this);

    /// @dev 2 control words and the 16-word wiring.
    uint256 private constant CAPSULE = 18 * 32;
    bytes4 private constant BLOCK_CALL = bytes4(keccak256("blockCall(uint256,bytes)"));
    /// @dev The canonical bind head: PoolKey (5 words), PoolConfig (14 words), the data offset; then the data length.
    uint256 private constant DATA_START = 4 + 20 * 32 + 32;
    bytes32 private constant LAUNCH_BUY = 0x45f20a8ddebc10086fcb192c29e55fce3baa64c4837bca2674009b5cd15e558b;
    uint8 private constant DYNAMIC_FEE_KNOBBED = 2;

    bytes32 private constant POOL_WIDTHS = hex"a0a01818a0a0a0a0a0a018181810202008010000000000000000000000000000";
    // C1 RulesConfig first packed word: guard40, three24, seven16, hot32. Exact release layout.
    bytes32 private constant CONFIG_WIDTHS = hex"2818181810101010101010200000000000000000000000000000000000000000";

    error Unauthorized();
    error AlreadyBound();
    error InvalidConfig();
    error InvalidSettlement();
    error ReentrantClaim();
    error PoolManagerUnlocked();
    error InvalidHookBlock();
    event RulesBound(PoolId indexed id, address indexed root, bytes32 configHash, bytes config);

    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external returns (bytes32 hash)
    {
        // Only by DELEGATECALL from a core, with the bind head canonical and the data clear of the capsule, which the
        // core appends after the whole calldata (outer extras the release's decoder ignored stay ignored).
        uint256 dataOffset;
        assembly ("memory-safe") { dataOffset := data.offset }
        if (address(this) == SELF || dataOffset != DATA_START
            || DATA_START + ((data.length + 31) & ~uint256(31)) + CAPSULE > msg.data.length) revert Unauthorized();
        PoolId id = key.toId();
        address root = address(uint160(_wire(1)));
        if (msg.sender != root || !IHookrRegistry(address(uint160(_wire(12)))).isRoot(msg.sender)
            || address(key.hooks) != msg.sender
            || PoolId.unwrap(IHookrRoot(msg.sender).bindingPool()) != PoolId.unwrap(id)) revert Unauthorized();
        S.State storage s = S.rules();
        if (s.pools[id].bound) revert AlreadyBound();
        bool quoteIs0 = pc.quote == key.currency0;
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG || key.tickSpacing <= 0 || key.tickSpacing > TickMath.MAX_TICK_SPACING
            || !(quoteIs0 ? pc.subject == key.currency1 : pc.subject == key.currency0 && pc.quote == key.currency1)) revert InvalidConfig();
        uint256 keyOffset;
        assembly ("memory-safe") { keyOffset := key }
        _cleanHead(keyOffset);
        uint256[16] calldata w;
        assembly ("memory-safe") { w := sub(calldatasize(), 512) }
        uint256[4] memory pool = _poolCapsule(pc);
        (uint256 metadata, HookrTypes.RulesConfig memory c, HookrTypes.RulesKnobs memory k,
            HookrTypes.RecaptureConfig memory rc) = Checks.termsParsed(w, pool, data, id);
        uint8 flags=uint8(metadata>>48);
        bool lane=metadata & (uint256(1)<<58)!=0;
        bool funded=metadata & (uint256(1)<<59)!=0;
        uint256 context = S.context(S.Hook.Bind, (c.guardEndBlock > HookrTime.parentBlock() ? S.CTX_GUARD : 0)
            | (lane ? S.CTX_LANE : 0) | (funded ? S.CTX_FUNDED : 0));
        uint256 bound;
        uint32 hot = c.potEveryNBuys & 0x3fffffff;
        if (hot != 0) {
            bytes memory input = _frame(IHookrBlock.blockBind.selector, keyOffset, 608, 128);
            _tail4(input, context, c.potMinBuyQuote, c.potEveryNBuys, c.protocolShareBps);
            uint256 masks = _word(0);
            for (uint256 slot; slot < 4; ++slot) if (hot & uint32(masks >> (slot * 32)) != 0) {
                address hookBlock = address(uint160(_wire(8 + slot)));
                if (hookBlock == address(0)) revert InvalidConfig();
                // Cold bit 123 (Exit Clock's per-holder records) is read by the core blocks in slot 1 only. Slot 0, the
                // limit blocks of the 10-26 release, decodes the whole settings at bind and predates the bit, so it is
                // handed the settings without it.
                _coldTail(input, slot == 0 ? uint256(c.potMinBuyQuote) & ~(uint256(1) << 123) : c.potMinBuyQuote);
                uint256[4] memory answer = _call(hookBlock, input, 32);
                bound = _combineBound(bound,answer[0]);
            }
        }
        if (lane) {
            bytes memory input = _frame(IHookrRecaptureBind.bindRecapture.selector, keyOffset, 608, 384);
            assembly ("memory-safe") { mcopy(add(input, 644), rc, 256) }
            _tail4(input, c.potBps, uint32((metadata>>60)&131071), funded ? 1 : 0, uint160(root));
            uint256[4] memory answer = _call(address(uint160(_wire(4))), input, 32);
            if (answer[0] > 1 || (answer[0] != 0) != (rc.period != 0)) revert InvalidSettlement();
            if (answer[0] != 0) flags |= S.TERMS_CROWN;
        }
        Checks.validateParsed(w, pool, c, lane, metadata|uint256(flags)<<48, bound);
        _storeBound(id, pc.baseLpFeePips, int16(key.tickSpacing), quoteIs0, flags, pc.liquidityOwner, c);
        uint16 integratorBps=uint16(metadata>>16);
        uint16 minimum=uint16(metadata>>32);
        if(integratorBps!=0||minimum!=0){
            bytes32 slot=HookrCoreState.integrationSlot(id);
            uint256 word=uint160(c.integrator)|uint256(integratorBps)<<160|uint256(minimum)<<176;
            assembly("memory-safe"){sstore(slot,word)}
        }
        if(k.minDynamicFeeLiquidity!=0){
            bytes32 slot=HookrCoreState.dynamicFeeSlot(id);
            uint256 word=uint256(k.minDynamicFeeLiquidity)|(metadata & (uint256(1)<<57)!=0?uint256(DYNAMIC_FEE_KNOBBED)<<248:0);
            assembly("memory-safe"){sstore(slot,word)}
        }
        if(metadata & (uint256(1)<<56)!=0){
            bytes32 slot=HookrCoreState.knobsSlot(id);
            uint256 word=uint256(k.windowSeconds)|uint256(k.resetSeconds)<<16|uint256(k.carryBps)<<32
                |uint256(k.moveTicks)<<48|uint256(k.snipeCurve)<<72;
            assembly("memory-safe"){sstore(slot,word)}
        }
        // R4-3: every guarded pool arms its launch buy (the Snipe exemption and the launch-second refusal read it);
        // a buy cap and the guard-only blocks imply a guard (Checks).
        if (c.guardEndBlock != 0) {
            assembly ("memory-safe") { tstore(LAUNCH_BUY, id) }
        }
        // R4-1: the effective Rules data, what the pool froze: the parsed words (config, knobs, recapture are one
        // contiguous canonical encoding in memory, HookrRulesChecks._data) with a defaulted recapture part and without
        // the NO_RECAPTURE bit. Equal to `data` byte for byte whenever neither applies. RulesBound's configHash is the
        // hash of the effective data it carries; the bind hash a root receives stays keccak256(data), which every root
        // compares with the data it sent (HookrLane.initializePool: `rulesHash != keccak256(rulesData)` refuses).
        // The answer is RulesBound's data, which the core logs (it holds the event's address) and follows with the
        // bind hash, keccak256(data), for the root: `configHash`, offset 64, length, the effective bytes (a multiple
        // of 32).
        {
            uint256 length = lane ? 960 : data.length;
            assembly ("memory-safe") {
                let p := mload(0x40)
                mcopy(add(p, 96), c, length)
                mstore(p, keccak256(add(p, 96), length)) mstore(add(p, 32), 64) mstore(add(p, 64), length)
                return(p, add(96, length))
            }
        }
    }

    /// @notice The core's `blockCall(uint256 slot, bytes payload)`: a block's out-of-swap entry (a Holder Pot poke,
    ///         say), moved here from the core's fallback with its refusals unchanged (G1a, 2026-10-15). Refused while
    ///         a claim runs or the PoolManager is unlocked; the slot must hold a wired Hook Block; the payload goes to that
    ///         block's `blockOut` as one canonical frame, and its answer must be one canonical bytes envelope.
    fallback() external {
        if (address(this) == SELF || msg.sig != BLOCK_CALL) revert Unauthorized();
        bool claiming;
        bytes32 claimingSlot = S.CLAIMING_SLOT;
        assembly ("memory-safe") { claiming := tload(claimingSlot) }
        if (claiming) revert ReentrantClaim();
        if (TransientStateLibrary.isUnlocked(IPoolManager(address(uint160(_wire(2)))))) revert PoolManagerUnlocked();
        (uint256 slot, bytes memory input) = _outFrame();
        address hookBlock = slot < 4 ? address(uint160(_wire(8 + slot))) : address(0);
        if (hookBlock == address(0)) revert InvalidHookBlock();
        (bool ok, bytes memory answer) = hookBlock.delegatecall(input);
        if (!ok) assembly ("memory-safe") { revert(add(answer,32), mload(answer)) }
        _canonicalBytes(answer);
        // blockOut and blockCall return exactly the same canonical bytes envelope.
        assembly ("memory-safe") { return(add(answer,32), mload(answer)) }
    }

    /// @dev Decode the same outer(uint256,bytes) region as Solidity would from the caller's calldata (the capsule
    /// excluded), including bounded noncanonical offsets, then construct one canonical blockOut(bytes) frame. Actual
    /// bytes are copied once; padding is zeroed.
    function _outFrame() private pure returns(uint256 slot,bytes memory input){
        bytes4 selector=IHookrBlock.blockOut.selector;
        uint256 context=S.context(S.Hook.Out,0);
        assembly("memory-safe"){
            let size:=sub(calldatasize(),CAPSULE)
            if lt(size,68){revert(0,0)}
            slot:=calldataload(4)
            let offset:=calldataload(36)
            if gt(offset,sub(size,36)){revert(0,0)}
            let length:=calldataload(add(offset,4))
            let start:=add(offset,36)
            if gt(length,sub(size,start)){revert(0,0)}
            let padded:=and(add(length,31),not(31))
            input:=mload(0x40)
            mstore(0x40,add(input,add(padded,192)))
            mstore(input,add(padded,132))
            mstore(add(input,32),selector)
            mstore(add(input,36),32)
            mstore(add(input,68),length)
            if padded{mstore(add(add(input,100),sub(padded,32)),0)}
            calldatacopy(add(input,100),start,length)
            mstore(add(add(input,100),padded),context)
            mstore(add(add(input,132),padded),0)
        }
    }

    function _canonicalBytes(bytes memory answer) private pure {
        if(answer.length<64) revert InvalidSettlement();
        uint256 offset; uint256 size;
        assembly ("memory-safe") {offset:=mload(add(answer,32)) size:=mload(add(answer,64))}
        if(offset!=32 || size>answer.length-64) revert InvalidSettlement();
        uint256 padded=(size+31)&~uint256(31);
        if(answer.length!=padded+64) revert InvalidSettlement();
        uint256 padding=padded-size;
        if(padding!=0){uint256 word;
            assembly ("memory-safe"){word:=mload(add(answer,add(96,size)))}
            if(word>>((32-padding)*8)!=0) revert InvalidSettlement();
        }
    }

    /// @dev Capsule word `i` (0 bindMasks, 1 guardOnlyBits, 2-17 the wiring).
    function _word(uint256 i) private pure returns (uint256 value) {
        assembly ("memory-safe") { value := calldataload(add(sub(calldatasize(), CAPSULE), mul(i, 32))) }
    }
    function _wire(uint256 i) private pure returns (uint256) { return _word(2 + i); }

    function _call(address hookBlock, bytes memory input, uint256 length) private returns (uint256[4] memory words) {
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            ok := delegatecall(gas(), hookBlock, add(input, 32), mload(input), words, length)
            size := returndatasize()
            if iszero(ok) {
                let free := mload(0x40)
                returndatacopy(free, 0, size)
                revert(free, size)
            }
        }
        if (size != length) revert InvalidSettlement();
    }

    function _poolCapsule(HookrTypes.PoolConfig calldata pc) private pure returns (uint256[4] memory a) {
        a[0]=uint160(Currency.unwrap(pc.subject)); a[1]=uint160(pc.advisory) | uint256(pc.advisoryPhases) << 160;
        a[2]=uint160(pc.liquidityOwner);
        a[3]=uint256(pc.baseLpFeePips) | uint256(pc.caps.maxLpFeePips) << 24
            | uint256(pc.caps.maxQuoteTakePips) << 48 | uint256(pc.caps.maxSubjectTakeBps) << 72;
    }

    /// @dev Restore every flat PoolKey and PoolConfig field's canonical width before copying its bytes; a uint256
    /// width is represented by 0, and the key tick is signed 24.
    function _cleanHead(uint256 source) private pure {
        // In assembly, as the core's swap-context check (G1a gas rows): same checks, same order, same errors.
        // POOL_WIDTHS at fixed shifts, unrolled (G1a gas pass), in the same order of refusals: words 0-2, the
        // signed tick (word 3), words 4-17; word 18 (policy) is a full word.
        bytes4 tickRefusal = InvalidConfig.selector;
        bytes4 widthRefusal = InvalidSettlement.selector;
        assembly ("memory-safe") {
            if or(or(shr(160,calldataload(add(source,0))),shr(160,calldataload(add(source,32)))),shr(24,calldataload(add(source,64)))) {
                mstore(0, widthRefusal)
                revert(0, 4)
            }
            let tick := calldataload(add(source, 96))
            if iszero(eq(tick, signextend(2, tick))) {
                mstore(0, tickRefusal)
                revert(0, 4)
            }
            if or(or(or(or(shr(160,calldataload(add(add(source,128),0))),shr(160,calldataload(add(add(source,128),32)))),or(shr(160,calldataload(add(add(source,128),64))),shr(160,calldataload(add(add(source,128),96))))),or(or(shr(160,calldataload(add(add(source,128),128))),shr(160,calldataload(add(add(source,128),160)))),or(shr(24,calldataload(add(add(source,128),192))),shr(24,calldataload(add(add(source,128),224)))))),or(or(or(shr(24,calldataload(add(add(source,128),256))),shr(16,calldataload(add(add(source,128),288)))),or(shr(32,calldataload(add(add(source,128),320))),shr(32,calldataload(add(add(source,128),352))))),or(shr(8,calldataload(add(add(source,128),384))),shr(1,calldataload(add(add(source,128),416)))))) {
                mstore(0, widthRefusal)
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
    function _coldTail(bytes memory input,uint256 cold) private pure {
        assembly ("memory-safe") { mstore(sub(add(input,mload(input)),64),cold) }
    }

    function _tail4(bytes memory input,uint256 a,uint256 b,uint256 c,uint256 d) private pure {
        assembly ("memory-safe") {
            let end:=add(input,mload(input))
            mstore(sub(end,96),a) mstore(sub(end,64),b) mstore(sub(end,32),c) mstore(end,d)
        }
    }

    function _storeBound(PoolId id,uint24 base,int16 spacing,bool quoteIs0,uint8 terms,address owner,
        HookrTypes.RulesConfig memory c) private
    {
        bytes32 slot=HookrCoreState.poolSlot(id);
        uint256 header=uint256(base)|uint256(uint16(spacing))<<24|uint256(1)<<40
            |uint256(quoteIs0?1:0)<<48|uint256(terms)<<56|uint256(uint160(owner))<<64|uint256(uint32(block.timestamp))<<224;
        // The twelve fields at their C1 shifts (CONFIG_WIDTHS: guard 40, three 24, seven 16, hot 32), unrolled
        // (G1a gas pass); every field is within its width (Checks' data parse).
        assembly ("memory-safe") {
            let packed:=or(or(or(mload(c),shl(40,mload(add(c,32)))),or(shl(64,mload(add(c,64))),shl(88,mload(add(c,96))))),
                or(or(shl(112,mload(add(c,128))),shl(128,mload(add(c,160)))),or(shl(144,mload(add(c,192))),shl(160,mload(add(c,224))))))
            packed:=or(packed,or(or(shl(176,mload(add(c,256))),shl(192,mload(add(c,288)))),or(shl(208,mload(add(c,320))),shl(224,mload(add(c,352))))))
            sstore(slot,header)
            sstore(add(slot,1),packed)
            sstore(add(slot,2),or(mload(add(c,384)),shl(128,mload(add(c,416)))))
            sstore(add(slot,3),mload(add(c,448)))
            sstore(add(slot,4),mload(add(c,480)))
        }
    }

    /// @dev Same C1 Bound union and six independent checked uint24 sums, without three memory structs.
    function _combineBound(uint256 a,uint256 b) internal pure returns(uint256 combined){
        if(a>>160!=0||b>>160!=0||uint8(a>>144)>31||uint8(a>>152)>31||uint8(b>>144)>31||uint8(b>>152)>31)
            revert B.InvalidBound();
        unchecked{
            for(uint256 shift;shift<144;shift+=24){
                uint256 sum=((a>>shift)&0xffffff)+((b>>shift)&0xffffff);
                if(sum>0xffffff)revert B.InvalidBound();
                combined|=sum<<shift;
            }
            combined|=(a|b)&(uint256(0xffff)<<144);
        }
    }
}
