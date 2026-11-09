// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";

/// @notice All persistent/transient domains and the core-written context. State is the exact release prefix.
library HookrRulesStorage {
    bytes32 internal constant RULES_SLOT = 0x762913e4bc0f59f7b08c82f07586fa48932548ab5fab99e6db0b09765b4ff900;
    bytes32 internal constant CROWN_SLOT = 0xe45082cd3f3f56debb1da3304fe7cfd6cd462e55169b53e1f0e1ebc07b911400;
    bytes32 internal constant WALLET_CAP_SLOT = 0x8190fa37ee53028d7ec387c90aac7f3e4d904039b59756b2970eed3647c26400;
    bytes32 internal constant SANDWICH_SLOT = 0xf7cff7e690a5e1b64782155bf051762276c1cd70e72eafa801c57a3688cf2b00;
    bytes32 internal constant EXIT_CLOCK_SLOT = 0xcb37ea1cf1f2293b9daf3767d90ebf61a02a2d7769f01ae1de29d1b47539ad00;
    bytes32 internal constant HOLDER_POT_SLOT = 0x87ae29139f88595cbf43b1c3319c9387bfae339aedc136243d3055616b7fa800;
    bytes32 internal constant STORM_SLOT = 0xea683f1a88ebd99d84a0bd41935e95ff61b60d2ad00eb312ae21f03c41f77a00;
    bytes32 internal constant CLAIMING_SLOT = bytes32(0);
    bytes32 internal constant PROTOCOL_PAID = keccak256("hookr.rules.transient.protocol.paid");
    bytes32 internal constant DYNAMIC_FEE_LAG = keccak256("hookr.rules.transient.dynamic.fee.lag");
    bytes32 internal constant DYNAMIC_FEE_STATE = keccak256("hookr.rules.transient.dynamic.fee.state");
    bytes32 internal constant DYNAMIC_FEE_END = keccak256("hookr.rules.transient.dynamic.fee.end");
    bytes32 internal constant LAUNCH_BUY = keccak256("hookr.rules.transient.launch.buy");
    bytes32 internal constant T_SOLD = keccak256("hookr.rules.transient.koth.sold");
    bytes32 internal constant T_PREV = keccak256("hookr.rules.transient.koth.prev");
    bytes32 internal constant T_PREV_AMOUNT = keccak256("hookr.rules.transient.koth.prevAmount");
    bytes32 internal constant T_PREV2 = keccak256("hookr.rules.transient.koth.prev2");
    bytes32 internal constant T_PREV2_AMOUNT = keccak256("hookr.rules.transient.koth.prev2Amount");
    bytes32 internal constant T_PREV3 = keccak256("hookr.rules.transient.koth.prev3");
    bytes32 internal constant T_PREV3_AMOUNT = keccak256("hookr.rules.transient.koth.prev3Amount");
    bytes32 internal constant FINAL_TAKE = keccak256("hookr.rules.transient.final.take");
    bytes32 internal constant CHARGE = keccak256("hookr.rules.transient.charge");
    bytes32 internal constant NOTHING_TO_SETTLE = keccak256("hookr.rules.transient.nothing.settle");
    uint8 internal constant TERMS_INTEGRATOR = 1;
    uint8 internal constant TERMS_MINIMUM = 2;
    uint8 internal constant TERMS_KNOBS = 4;
    uint8 internal constant TERMS_CROWN = 8;
    uint8 internal constant TERMS_LANE = 16;
    uint8 internal constant TERMS_ROOT_SIM = 32;
    /// @dev R4-3 (next core 10-22): the pool shares one Anti-Snipe buy cap with its launch family, counted in cap
    ///      fractions (FAMILY_CAP_SCALE a whole cap) at the family anchor's guard word (`familyAnchorSlot`).
    uint8 internal constant TERMS_FAMILY = 64;
    uint256 internal constant FAMILY_CAP_SCALE = 1 << 96;
    /// @dev Persistent: a family member's anchor pool id (the family's first capped member bound in its transaction).
    bytes32 internal constant FAMILY_ANCHOR = keccak256("hookr.rules.family.anchor");
    /// @dev Transient: keccak256(FAMILY_TX, liquidity owner, family) -> the family's anchor pool id in this transaction.
    bytes32 internal constant FAMILY_TX = keccak256("hookr.rules.transient.family");
    enum Hook { Bind, AddLiquidity, Quote, Settle, Out }
    uint256 internal constant CTX_STATIC = 1 << 3;
    uint256 internal constant CTX_BUY = 1 << 4;
    uint256 internal constant CTX_AUTHENTICATED = 1 << 5;
    uint256 internal constant CTX_GUARD = 1 << 6;
    uint256 internal constant CTX_LAUNCH_BUY = 1 << 7;
    uint256 internal constant CTX_LANE = 1 << 8;
    uint256 internal constant CTX_FUNDED = 1 << 9;
    error InvalidContext();

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


    struct Podium { address second; address third; uint128 secondAmount; uint128 thirdAmount; }
    struct CrownState {
        mapping(PoolId => Podium) podiums;
        mapping(PoolId => uint32) prizeCaps;
        mapping(PoolId => uint256) gates;
    }
    struct WalletCapState { mapping(Currency => mapping(uint32 => mapping(address => uint256))) bought; }
    struct SandwichState { mapping(PoolId => uint256) windows; }
    struct Exit { uint104 matured; uint104 maturing; uint40 entry; }
    struct ExitClockState { mapping(PoolId => mapping(address => Exit)) exits; }
    struct Pot { uint128 open; uint32 openEpoch; uint32 merged; uint32 count; uint32 start; uint256 reserve; uint256 old; }
    struct Holder { uint128 position; uint32 entry; uint32 settled; }
    struct HolderPotState {
        mapping(PoolId => Pot) pots;
        mapping(PoolId => mapping(address => Holder)) holders;
        mapping(PoolId => mapping(uint256 => uint256)) buckets;
        mapping(PoolId => mapping(uint256 => uint256)) pages;
        mapping(PoolId => mapping(uint256 => uint256)) sumA;
        mapping(PoolId => mapping(uint256 => uint256)) sumB;
        mapping(PoolId => mapping(uint256 => uint256)) cpEpochs;
        mapping(Currency => mapping(address => uint256)) held;
    }
    struct Storm { int24 lastTick; uint40 sampleEpoch; uint64 variance; uint24 level; bool started; uint32 settings; }
    struct StormState { mapping(PoolId => Storm) storms; }

    function rules() internal pure returns (State storage s) { bytes32 slot = RULES_SLOT; assembly ("memory-safe") { s.slot := slot } }
    function crown() internal pure returns (CrownState storage s) { bytes32 slot = CROWN_SLOT; assembly ("memory-safe") { s.slot := slot } }
    function walletCap() internal pure returns (WalletCapState storage s) { bytes32 slot = WALLET_CAP_SLOT; assembly ("memory-safe") { s.slot := slot } }
    function sandwich() internal pure returns (SandwichState storage s) { bytes32 slot = SANDWICH_SLOT; assembly ("memory-safe") { s.slot := slot } }
    function exitClock() internal pure returns (ExitClockState storage s) { bytes32 slot = EXIT_CLOCK_SLOT; assembly ("memory-safe") { s.slot := slot } }
    function holderPot() internal pure returns (HolderPotState storage s) { bytes32 slot = HOLDER_POT_SLOT; assembly ("memory-safe") { s.slot := slot } }
    function storm() internal pure returns (StormState storage s) { bytes32 slot = STORM_SLOT; assembly ("memory-safe") { s.slot := slot } }

    function context(Hook hook, uint256 flags) internal pure returns (uint256 word) {
        if (flags & ~uint256(0x3f8) != 0) revert InvalidContext();
        return uint256(hook) | flags;
    }
    function contextHook(uint256 word) internal pure returns (Hook) {
        if (word >> 10 != 0 || word & 7 > uint256(Hook.Out)) revert InvalidContext();
        return Hook(word & 7);
    }
    function poolTransient(bytes32 domain, PoolId id) internal pure returns (bytes32) { return keccak256(abi.encode(domain, id)); }
    function familyAnchorSlot(PoolId id) internal pure returns (bytes32) { return poolTransient(FAMILY_ANCHOR, id); }
    function finalTakeSlot(PoolId id) internal pure returns (bytes32) { return poolTransient(FINAL_TAKE, id); }
    function chargeSlot(PoolId id, uint8 module) internal pure returns (bytes32) { return keccak256(abi.encode(CHARGE, id, module)); }
    function nothingToSettleSlot(PoolId id, uint8 module) internal pure returns (bytes32) { return keccak256(abi.encode(NOTHING_TO_SETTLE, id, module)); }
    function protocolPaidSlot(address payer, Currency quote) internal pure returns (bytes32) { return keccak256(abi.encode(PROTOCOL_PAID, payer, quote)); }
    function crownGate(uint64 roundEnd, uint128 smallestSpend) internal pure returns (uint256) { return uint256(roundEnd) | uint256(smallestSpend) << 64; }
    function crownGateValues(uint256 word) internal pure returns (uint64 roundEnd, uint128 smallestSpend) {
        if (word >> 192 != 0) revert InvalidContext();
        return (uint64(word), uint128(word >> 64));
    }
}
