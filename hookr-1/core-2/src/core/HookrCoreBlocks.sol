// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrBlock} from "../interfaces/IHookrBlock.sol";
import {IHookrCoreBlockEvents} from "../interfaces/IHookrCoreBlockEvents.sol";
import {HookrRulesStorage as S} from "../libraries/HookrRulesStorage.sol";
import {HookrBlockCall as Call} from "../libraries/HookrBlockCall.sol";
import {HookrChargeConfig} from "../libraries/HookrChargeConfig.sol";
import {HookrHolderExit as HE} from "../libraries/HookrHolderExit.sol";
import {HookrWallets} from "../libraries/HookrWallets.sol";
import {HookrSinks} from "../libraries/HookrSinks.sol";
import {HookrMath} from "../libraries/HookrMath.sol";
import {HookrSandwichMath} from "../libraries/HookrSandwichMath.sol";
import {HookrHoldTokenCodeHash} from "../libraries/HookrHoldTokenCodeHash.sol";
import {HookrCoreSettle} from "../libraries/HookrCoreSettle.sol";

/// @notice Root-agnostic revision-3 Swap Cut, Exit Clock, Holder Pot, Storm Fee and Sandwich Guard.
/// @dev The authenticated core supplies every tail. Swap allocations leave the single liability write to the core.
contract HookrCoreBlocks is IHookrBlock, IHookrCoreBlockEvents {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    uint32 private constant SG = 1 << 17;
    uint32 private constant EXIT = 1 << 20;
    uint32 private constant HOLDER = 1 << 21;
    uint32 private constant STORM = 1 << 22;
    uint32 private constant CUT_BUY = 127;
    uint32 private constant CUT_SELL = 127 << 7;
    uint32 private constant CUT_OUT = 7 << 14 | 7 << 24;
    uint256 private constant LP_ROOM = 600_000;
    uint256 private constant BPS = 10_000;
    uint256 private constant BALANCE_GAS = 50_000;
    uint256 private constant CLOCK_GAS = 20_000;
    bytes4 private constant POKE = bytes4(keccak256("poke((address,address,uint24,int24,address),address)"));
    /// @dev erc7201:hookr.rules.sandwich.seen, keccak256(abi.encode(uint256(keccak256("hookr.rules.sandwich.seen")) - 1))
    ///      & ~0xff: per pool, the sqrt price the guard's settle last read on a lane pool (`_sandwich`). Its own namespace,
    ///      read and written only here, so the core's shared storage library and every other Hook Block keep their bytes.
    bytes32 private constant SEEN_SLOT = 0x5ea6230c6245dcf5c2849a7a8b1ec4c8f0a72205c3337db1aa5b8c87109bed00;
    /// @dev erc7201:hookr.rules.exit.pools: per subject token, its Exit Clock pools on this core, listed at bind (a count,
    ///      then up to EXIT_POOLS_MAX pool ids). An authenticated sell and a poke read the wallet's records over them, so a
    ///      record may never stand for more tokens than the wallet holds across the token's pools (Exit Clock audit
    ///      10-31, F1 and F1b). A pool past the bound is not listed; its own record is still checked.
    bytes32 private constant EXIT_POOLS_SLOT = 0x22e5150c62c3d9e078febd96c719bfce26f280e6889c5727779b6ffbff8be400;
    uint256 private constant EXIT_POOLS_MAX = 4;
    /// @dev The charge word's flag that a sell priced Exit Clock's exact blended rate on the LP-fee path, which holds only
    ///      for the whole sale: its settle refuses a partial fill (audit 10-31, F2).
    uint256 private constant FULL_FILL = 1 << 112;
    /// @dev Cold settings bit 123: on a pool whose token keeps no hold time, Exit Clock keeps per-holder records on this
    ///      pool (the creator's pick) instead of melting from top to floor over the horizon from the pool's launch. Outside
    ///      this Hook Block's declared cold fields (HookrBlockCall's field set is fixed in HookrRules' bytes): the Binder
    ///      admits it with Exit Clock on, and the Rules hand this block the whole cold word.
    uint256 private constant EXIT_RECORDS = 1 << 123;
    /// @dev IHookrToken.lotsBefore(address,uint256), read with LOTS_GAS: the seller's balance, fresh lot and lot time as
    ///      they stood before a router's collect of this sale.
    bytes4 private constant LOTS_BEFORE = 0x54821050;
    uint256 private constant LOTS_GAS = 30_000;
    /// @dev erc7201:hookr.rules.exit.lot: per pool, transient, the lot a token-mode quote priced (fresh 108 | aged 108 |
    ///      since 40), for the settle's rebate to the exact rate of what filled. Its own namespace, as `_seenSlot`.
    bytes32 private constant LOT_SLOT = 0xbaf55abe57cfac45a5a39eb38be2cb41b4c5ff7f0ac8ee3ddf0ae2bfa3a17c00;
    uint256 private constant LOT_MASK = (uint256(1) << 108) - 1;

    IPoolManager public immutable poolManager;
    address private immutable SELF = address(this);

    error Unauthorized();
    error InvalidCoreContext();
    error UnsupportedOut();
    error ClockUnavailable();
    error ExitClockPartialFill();

    /// @dev A clean-up (`poke`) cut `cut` tokens from `wallet`'s Exit Clock record on `id`: what the wallet's records over
    ///      the token's pools stood for beyond what it holds. Anyone may call it; nothing is paid for it.
    event ExitRecordCut(PoolId indexed id, address indexed wallet, address indexed poker, uint256 cut);

    /// @dev Accepted creator credit only. Overflow left in protocol is absent. Charge: Cut0, Exit1, Storm2, Guard3.
    event CoreBlockAllocated(PoolId indexed id, address indexed payer, uint8 charge, uint8 outflow, address recipient, uint256 amount);

    constructor(IPoolManager manager) { poolManager = manager; }
    modifier delegated() { if (address(this) == SELF) revert Unauthorized(); _; }

    function blockMasks() external pure returns (uint256 hooks, uint256 cold) {
        uint256 bind = CUT_BUY | CUT_SELL | CUT_OUT | SG | EXIT | HOLDER | STORM;
        uint256 buy = CUT_BUY | SG | STORM;
        uint256 sell = CUT_SELL | SG | EXIT | STORM;
        uint256 records = EXIT | HOLDER;
        hooks = bind | buy << 64 | sell << 96 | (buy | records) << 128 | (sell | records) << 160
            | (CUT_BUY | CUT_SELL | SG | EXIT | STORM) << 224;
        cold = (((uint256(1) << 85) - 1) ^ ((uint256(1) << 19) - 1))
            | uint256(511) << 114 | records << 128;
    }

    function blockBind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc)
        external delegated returns (uint256 bound)
    {
        (uint256 context, uint128 cold, uint32 hot, uint16 share) = Call.bindTail();
        bound = HookrChargeConfig.validateAndBound(hot, cold, share, context & S.CTX_LANE != 0);
        PoolId id = key.toId();
        if (hot & HOLDER != 0) {
            // Holder Pot pays by the token's balance-time meter: only a HookrToken (by runtime codehash) carries one.
            if (Currency.unwrap(pc.subject).codehash != HookrHoldTokenCodeHash.HASH) revert HookrChargeConfig.CoreBlocksConfig();
            S.Pot storage pot = S.holderPot().pots[id];
            pot.start = uint32(block.timestamp / 1 days);
            pot.openEpoch = uint32(block.timestamp / 1 days);
        }
        if (hot & STORM != 0) S.storm().storms[id].settings = uint32(uint256(cold) >> 63) & ((1 << 22) - 1);
        if (hot & EXIT != 0 && _exitMode(pc.subject, cold) == 2) _listExitPool(pc.subject, id);
        if (hot & SG != 0) S.sandwich().windows[id] = uint256((cold >> 114) & 511) << 224;
        emit CoreBlocksBound(id, uint256(hot) | uint256(cold) << 32);
        // Pool identity, payee, enabled outflow targets and native/dynamic caps are checked by C2 before Bound is stored.
    }

    function blockAddLiquidity(PoolId, address) external view delegated { revert UnsupportedOut(); }

    function blockQuote(HookrTypes.SwapContext calldata x, HookrTypes.SwapSimulation calldata)
        external delegated returns (uint256 lp, uint256 take, uint256 burn, uint256 hookr)
    {
        Call.Quote memory q = Call.quoteTail();
        _identity(q.context, x);
        S.Bound storage b = S.rules().pools[x.id];
        uint32 hot = b.config.potEveryNBuys;
        uint16 share = b.config.protocolShareBps;
        bool isStatic = q.context & S.CTX_STATIC != 0;
        uint256 cut = (x.isBuy ? hot & CUT_BUY : (hot >> 7) & 127) * 1_000;
        uint256 exitTake;
        uint256 exitRate;
        uint256 stormTake;
        uint256 sgTake;
        if (cut != 0) { q.take += cut; q.hookr += cut * share / BPS; }
        uint256 room = LP_ROOM - x.baseLpFeePips - q.lp;
        if (hot & STORM != 0) {
            (uint256 level, uint8 out) = _storm(x.id, isStatic);
            if (out == 0) {
                if (level > room) level = room;
                room -= level;
                uint256 moved = level * share / BPS;
                q.lp += level - moved; q.take += moved; q.hookr += moved;
            } else { stormTake = level; q.take += level; q.hookr += level * share / BPS; }
        }
        uint256 fullFill;
        uint256 exitMode = hot & EXIT != 0 ? _exitMode(x.subject, q.cold) : 0;
        if (!x.isBuy && hot & EXIT != 0) {
            exitRate = ((uint256(q.cold) >> 19) & 127) * 10;
            if (exitMode == 0) {
                // Pool-wide melt: every sell pays the rate for the pool's age, from its launch.
                exitRate = HE._exitAgeBps(block.timestamp - b.launchedAt, q.cold);
            } else if (exitMode == 1) {
                // The token's lots, as they stood before a router's collect of this sale: the fresh lot at its age's rate,
                // the aged bag at the floor, one exact rate for the whole sale. An unknown router, a contract payer, an
                // empty balance or a failed read pays the top. Paid to LPs: the exact rate, and the settle refuses a
                // partial fill of a mixed bag. Paid elsewhere: the most a partial fill pays, rebated to the exact rate of
                // what filled at settle, from the lot kept for it. A direct HookrRouter sale after another send of the
                // token in the same transaction is priced on that send's tail put back: more or fresher tokens than the
                // seller holds, which can only cost the seller (attack round 10-31, A5).
                uint256 lot;
                if (x.authenticated && HookrWallets.isWallet(x.payer)) {
                    uint256 amountIn = x.exactInput ? uint256(-x.amountSpecified) : 0;
                    (bool ok, uint256 held, uint256 fresh, uint256 since) = _lotsBefore(x.subject, x.payer, amountIn);
                    if (ok && held != 0 && fresh <= held && since <= block.timestamp && held >> 108 == 0) {
                        (uint256 exact, uint256 quoted) = HE._exitLotBps(held, fresh, since, amountIn, q.cold);
                        if ((q.cold >> 42) & 7 != 0) exitRate = quoted;
                        else {
                            exitRate = exact;
                            if (exact < quoted) fullFill = FULL_FILL;
                        }
                        lot = fresh | (held - fresh) << 108 | since << 216;
                    }
                }
                if (!isStatic) {
                    bytes32 at = _lotSlot(x.id);
                    assembly ("memory-safe") { tstore(at, lot) }
                }
            } else if (x.exactInput && x.authenticated && HookrWallets.isWallet(x.payer)) {
                uint256 amountIn = uint256(-x.amountSpecified);
                (uint256 exact, uint256 quoted) = HE._exitBps(_cappedRecord(x, amountIn, isStatic), amountIn, q.cold);
                // Paid to the liquidity owner, a payee or a pot: quoted at the most a partial fill pays, then rebated to
                // the exact rate at settle. Paid to LPs, whose fee cannot be rebated: the exact rate for the whole sale,
                // and the settle refuses a partial fill (a first part of a mixed bag would leave the young tokens at the
                // blended rate).
                if ((q.cold >> 42) & 7 != 0) exitRate = quoted;
                else {
                    exitRate = exact;
                    if (exact < quoted) fullFill = FULL_FILL;
                }
            }
            uint256 fee = exitRate * 100;
            if ((q.cold >> 42) & 7 == 0) {
                if (fee > room) fee = room;
                uint256 moved = fee * share / BPS;
                q.lp += fee - moved; q.take += moved; q.hookr += moved;
            } else {
                exitTake = fee; q.take += fee;
                // Counted in full, as the cut and Storm count theirs, so a Hookr minimum does not stack on the quoted
                // rate (audit 10-31, 1.11); the settle's rebate then keeps Hookr at the minimum, never below it.
                q.hookr += fee * share / BPS;
            }
        }
        // On a lane pool the guard reads, and its settle writes, the price the Rules last saw (`_sandwich`).
        bool seen = hot & SG != 0 && q.context & (S.CTX_GUARD | S.CTX_LANE) == S.CTX_LANE;
        if (hot & SG != 0 && q.context & S.CTX_GUARD == 0) {
            sgTake = _sandwich(x.id, x.zeroForOne, isStatic, seen);
            q.take += sgTake; q.hookr += sgTake * share / BPS;
        }
        if (!isStatic) {
            bytes32 slot = S.chargeSlot(x.id, 1);
            bytes32 nothing = S.nothingToSettleSlot(x.id, 1);
            uint256 word = cut | exitTake << 24 | stormTake << 48 | sgTake << 72 | exitRate << 96 | fullFill;
            // Holder epoch rolling applies to every swap, including unauthenticated/launch buys with no carve.
            bool records = hot & HOLDER != 0 || seen || q.context & S.CTX_LAUNCH_BUY == 0 && x.authenticated
                && (!x.isBuy || x.beneficiary == x.payer && HookrWallets.isWallet(x.payer))
                && exitMode == 2;
            // A sell under the full-fill guard always settles, so the guard runs even when nothing is allocated (paid to
            // LPs): the mask keeps FULL_FILL beside the four charges.
            assembly ("memory-safe") { tstore(slot, word) tstore(nothing, and(iszero(records), iszero(and(word, or(sub(shl(96, 1), 1), FULL_FILL))))) }
        }
        return (q.lp, q.take, q.burn, q.hookr);
    }

    function blockSettle(HookrTypes.SwapContext calldata x, HookrTypes.Settlement calldata z)
        external delegated returns (uint256 protocol)
    {
        Call.Settle memory tail = Call.settleTail();
        _identity(tail.context, x);
        if (tail.context & S.CTX_STATIC != 0) revert InvalidCoreContext();
        S.State storage s = S.rules();
        uint32 hot = s.pools[x.id].config.potEveryNBuys;
        bytes32 slot = S.chargeSlot(x.id, 1);
        bytes32 nothing = S.nothingToSettleSlot(x.id, 1);
        uint256 word;
        assembly ("memory-safe") { word := tload(slot) tstore(slot, 0) tstore(nothing, 0) }
        if (word & FULL_FILL != 0 && z.actualSubject < uint256(-x.amountSpecified)) revert ExitClockPartialFill();
        if (hot & HOLDER != 0) HookrCoreSettle.holderRoll(x.id);
        if (hot & SG != 0 && tail.context & (S.CTX_GUARD | S.CTX_LANE) == S.CTX_LANE) {
            (uint160 settled,,,) = poolManager.getSlot0(x.id);
            bytes32 seenAt = _seenSlot(x.id);
            assembly ("memory-safe") { sstore(seenAt, settled) }
        }
        protocol = tail.protocol;
        uint16 share = s.pools[x.id].config.protocolShareBps;
        // The settle reads the mode itself, since a buy on an Exit Clock pool may run no quote here. Token mode (1) takes
        // the lot its quote kept, if any; per-holder records (2) write records.
        uint256 exitMode = hot & EXIT != 0 ? _exitMode(x.subject, tail.cold) : 0;
        bool exitRecords = exitMode == 2;
        uint256 lot;
        if (exitMode == 1) {
            bytes32 at = _lotSlot(x.id);
            assembly ("memory-safe") { lot := tload(at) tstore(at, 0) }
        }
        for (uint8 i; i < 4; ++i) {
            uint24 pips = uint24(word >> (uint256(i) * 24));
            if (pips == 0) continue;
            uint256 gross = HookrSinks.carve(z.rulesFee, pips, tail.finalTake);
            uint8 out;
            if (i == 0) {
                out = uint8((hot >> 14) & 7);
                if (!x.isBuy && (hot >> 24) & 7 != 0) out = uint8((hot >> 24) & 7);
            } else if (i == 1) {
                out = uint8((tail.cold >> 42) & 7);
                (gross, protocol) = HookrCoreSettle.exitRebate(x, z, tail, word, lot, exitRecords, pips, gross, protocol);
            } else if (i == 2) out = uint8((S.storm().storms[x.id].settings >> 19) & 7);
            else {
                out = uint8((S.sandwich().windows[x.id] >> 230) & 7);
                (gross, protocol) = HookrCoreSettle.sandwichReprice(poolManager, x, z, gross, protocol, share);
            }
            (, uint256 creator) = HookrSinks.split(gross, share);
            address recipient = out == 1 ? s.pools[x.id].liquidityOwner : out == 4 ? s.pools[x.id].config.royaltyTo : address(0);
            (uint256 accepted,) = HookrSinks.allocateOutflow(s, x.id, x.quote, out, recipient, creator);
            protocol -= accepted;
            if (accepted != 0) {
                if (out == 1) emit PoolAccrued(x.id, x.quote, accepted);
                emit CoreBlockAllocated(x.id, x.payer, i, out, recipient, accepted);
            }
        }
        bool tracked = tail.context & S.CTX_LAUNCH_BUY == 0 && x.authenticated
            && (!x.isBuy || x.beneficiary == x.payer && HookrWallets.isWallet(x.payer));
        // Holder Pot keeps no record of the swap: the wallet's days are paid by the token's meter at each of its looks.
        if (tracked && hot & HOLDER != 0) HookrCoreSettle.holderLook(x.id, x.payer, x.subject, x.quote, false);
        if (tracked && exitRecords) {
            S.Exit storage e = S.exitClock().exits[x.id][x.payer];
            if (x.isBuy) HE._exitBuy(e, z.actualSubject - z.subjectBurn, tail.cold);
            else if (e.matured != 0 || e.maturing != 0) HE._exitSell(e, z.actualSubject, tail.cold);
        }
    }

    /// @dev Exactly poke(PoolKey,address), transported as data; no arbitrary selector dispatch exists here.
    function blockOut(bytes calldata data) external delegated returns (bytes memory) {
        Call.outTail();
        if (data.length != 196 || bytes4(data[:4]) != POKE) revert UnsupportedOut();
        (PoolKey memory key, address wallet) = abi.decode(data[4:], (PoolKey, address));
        PoolId id = key.toId();
        S.State storage s = S.rules();
        S.Bound storage b = s.pools[id];
        uint32 hot = b.config.potEveryNBuys;
        uint128 cold = b.config.potMinBuyQuote;
        if (!b.bound || hot & (HOLDER | EXIT) == 0) revert NotCoreBlocksPool();
        Currency subject = b.quoteIsCurrency0 ? key.currency1 : key.currency0;
        Currency quote = b.quoteIsCurrency0 ? key.currency0 : key.currency1;
        if (hot & HOLDER != 0) HookrCoreSettle.holderRoll(id);
        uint256 credited;
        if (wallet != address(0)) {
            // A poke pays the wallet's unpaid days forward and back (older days collected on demand, by anyone).
            if (hot & HOLDER != 0 && HookrWallets.isWallet(wallet)) credited = HookrCoreSettle.holderLook(id, wallet, subject, quote, true);
            if (hot & EXIT != 0 && _exitMode(subject, cold) == 2) {
                // The clean-up: the wallet's records over the token's pools of this core, against what it holds. This
                // pool's record is cut by the excess, the oldest tokens first (newest first would let fresh tokens sell at
                // the floor; audit 10-31). Each pool of the token is cleaned on its own; anyone may call it, unpaid.
                (bool ok, uint256 balance) = _balanceOf(subject, wallet);
                S.Exit storage e = S.exitClock().exits[id][wallet];
                uint256 own = uint256(e.matured) + e.maturing;
                if (ok && own != 0) {
                    uint256 total = _tokenRecords(subject, id, wallet, own);
                    if (total > balance) {
                        uint256 gone = _cut(e, total - balance);
                        if (gone != 0) emit ExitRecordCut(id, wallet, msg.sender, gone);
                    }
                }
            }
        }
        return abi.encode(credited);
    }

    /// @dev Exact C1 packed layout: tick24/epoch40/variance64/level24/started8/settings32. One SLOAD.
    function _storm(PoolId id, bool isStatic) private returns (uint256 level, uint8 out) {
        S.Storm storage state = S.storm().storms[id];
        uint256 word;
        assembly ("memory-safe") { word := sload(state.slot) }
        uint256 settings = uint32(word >> 160);
        out = uint8((settings >> 19) & 7);
        uint256 t = block.timestamp / 5 minutes;
        uint256 epoch = uint40(word >> 24);
        level = uint24(word >> 128);
        if (uint8(word >> 152) != 0 && t <= epoch) return (level, out); // No tick read inside a sample epoch.
        (, int24 tick,,) = poolManager.getSlot0(id);
        uint256 floor = ((settings >> 8) & 255) * 500;
        uint256 variance;
        if (uint8(word >> 152) == 0) level = floor;
        else {
            uint256 passed = t - epoch;
            uint256 elapsed = passed * 5 minutes;
            uint256 halvings = elapsed / 60 minutes;
            variance = halvings >= 64 ? 0 : uint256(uint64(word >> 64)) >> halvings;
            variance -= variance * (elapsed % 60 minutes) / (2 * 60 minutes);
            int256 d = int256(tick) - int24(uint24(word));
            uint256 move = uint256(d * d) / passed;
            uint256 ceiling = (settings & 255) * 500;
            uint256 clip = (ceiling - floor) / 12; clip *= clip;
            variance += move > clip ? clip : move;
            uint256 target = floor + 6 * HookrMath.sqrt(variance);
            if (target > ceiling) target = ceiling;
            uint256 from = level;
            if (target > level) { level += 1_000; if (level > target) level = target; }
            else { uint256 down = 1_000 * passed; level = level > target + down ? level - down : target; }
            if (!isStatic && level != from) emit StormStepped(id, from, level, variance);
        }
        if (!isStatic) {
            word = uint256(uint24(tick)) | uint256(uint40(t)) << 24 | uint256(uint64(variance)) << 64
                | uint256(uint24(level)) << 128 | uint256(1) << 152 | settings << 160;
            assembly ("memory-safe") { sstore(state.slot, word) }
        }
    }

    /// @dev On a lane pool (`seen`) the executor's legs move the price between two swaps the Rules see, and run no Rules
    ///      themselves (HookrLane `_enter`: only the frozen executor, only inside an open frame). The guard's settle
    ///      records the price the Rules last saw, so the move from it to slot0 at the next quote in the window is
    ///      exactly the legs'. `HookrSandwichMath.carryOpening` lets that move shrink the window's outstanding move, never grow
    ///      it: no trader pays for a leg, and a back-run still pays for whatever of the reversal the legs left.
    function _sandwich(PoolId id, bool zeroForOne, bool isStatic, bool seen) private returns (uint256) {
        uint256 word = S.sandwich().windows[id];
        uint256 settings = (word >> 224) & 511;
        uint256 window = _blockClock() / ((settings & 3) + 1);
        (uint160 current,,,) = poolManager.getSlot0(id);
        uint160 opening = uint160(word >> 64);
        if (window != uint64(word) || opening == 0) {
            if (window > type(uint64).max) revert ClockUnavailable();
            if (!isStatic) S.sandwich().windows[id] = window | uint256(current) << 64 | settings << 224;
            return 0;
        }
        if (seen) {
            // The window was opened by a quote in it, whose settle wrote the last price seen: it is this window's.
            bytes32 slot = _seenSlot(id);
            uint160 last;
            assembly ("memory-safe") { last := and(sload(slot), 0xffffffffffffffffffffffffffffffffffffffff) }
            if (last != 0 && last != current) {
                uint160 carried = HookrSandwichMath.carryOpening(opening, last, current);
                if (carried != opening) {
                    opening = carried;
                    if (!isStatic) S.sandwich().windows[id] = window | uint256(opening) << 64 | settings << 224;
                }
            }
        }
        uint256 charged = HookrSandwichMath.charge(current, opening, zeroForOne, uint8((settings >> 2) & 15));
        if (!isStatic) {
            // The settle reprices from the price this swap starts at; nothing to reprice when nothing is charged.
            if (charged != 0) HookrCoreSettle.sandwichStash(poolManager, id);
            else {
                bytes32 at = HookrCoreSettle.preSlot(id);
                assembly ("memory-safe") { tstore(at, 0) tstore(add(at, 1), 0) }
            }
        }
        return charged;
    }

    /// @dev The seller's record as an exact-input sell of `amountIn` prices it: cut first by what the wallet's records
    ///      over the token's pools exceed its balance plus the amount sold (the balance may or may not still hold the sold
    ///      tokens when the quote runs; adding them back never under-credits an honest seller). Written back outside
    ///      static mode.
    function _cappedRecord(HookrTypes.SwapContext calldata x, uint256 amountIn, bool isStatic)
        private returns (S.Exit memory record)
    {
        S.Exit storage e = S.exitClock().exits[x.id][x.payer];
        record = e;
        uint256 own = uint256(record.matured) + record.maturing;
        if (own == 0) return record;
        (bool ok, uint256 held) = _balanceOf(x.subject, x.payer);
        if (!ok) return record;
        if (own <= held || own - held <= amountIn) return record;
        uint256 gone = own - held - amountIn;
        uint256 fromMatured = gone < record.matured ? gone : record.matured;
        record.matured -= uint104(fromMatured);
        record.maturing -= uint104(gone - fromMatured);
        if (!isStatic) {
            e.matured = record.matured;
            e.maturing = record.maturing;
        }
    }

    /// @dev Cuts up to `excess` from a record, matured tokens first; returns what it cut.
    function _cut(S.Exit storage e, uint256 excess) private returns (uint256 gone) {
        uint256 matured = e.matured;
        uint256 maturing = e.maturing;
        gone = excess < matured + maturing ? excess : matured + maturing;
        uint256 fromMatured = gone < matured ? gone : matured;
        e.matured = uint104(matured - fromMatured);
        e.maturing = uint104(maturing - (gone - fromMatured));
    }

    /// @dev The wallet's records over the token's listed pools, `own` (pool `id`'s) counted once whether or not listed.
    function _tokenRecords(Currency subject, PoolId id, address wallet, uint256 own) private view returns (uint256 total) {
        total = own;
        bytes32 base = _exitPoolsBase(subject);
        uint256 n;
        assembly ("memory-safe") { n := sload(base) }
        for (uint256 i; i < n; ++i) {
            bytes32 other;
            assembly ("memory-safe") { other := sload(add(base, add(i, 1))) }
            if (other == PoolId.unwrap(id)) continue;
            S.Exit storage o = S.exitClock().exits[PoolId.wrap(other)][wallet];
            total += uint256(o.matured) + o.maturing;
        }
    }

    function _listExitPool(Currency subject, PoolId id) private {
        bytes32 base = _exitPoolsBase(subject);
        uint256 n;
        assembly ("memory-safe") { n := sload(base) }
        if (n >= EXIT_POOLS_MAX) return;
        assembly ("memory-safe") { sstore(add(base, add(n, 1)), id) sstore(base, add(n, 1)) }
    }

    function _exitPoolsBase(Currency subject) private pure returns (bytes32 base) {
        assembly ("memory-safe") { mstore(0, subject) mstore(32, EXIT_POOLS_SLOT) base := keccak256(0, 64) }
    }

    /// @dev How Exit Clock prices `subject`'s sells: 1 from the token's own hold time (a HookrToken that keeps it,
    ///      by runtime codehash), else 2 per-holder records on the pool when the creator picked them (cold bit 123), else
    ///      0 the pool-wide melt from launch.
    function _exitMode(Currency subject, uint256 cold) private view returns (uint256) {
        if (Currency.unwrap(subject).codehash == HookrHoldTokenCodeHash.HASH) return 1;
        return cold & EXIT_RECORDS != 0 ? 2 : 0;
    }

    function _lotsBefore(Currency token, address owner, uint256 back)
        private view returns (bool ok, uint256 held, uint256 fresh, uint256 since)
    {
        address t = Currency.unwrap(token);
        bytes4 selector = LOTS_BEFORE;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector) mstore(add(ptr, 4), owner) mstore(add(ptr, 36), back)
            let success := staticcall(LOTS_GAS, t, ptr, 68, ptr, 96)
            ok := and(success, iszero(lt(returndatasize(), 96)))
            held := mload(ptr) fresh := mload(add(ptr, 32)) since := mload(add(ptr, 64))
        }
    }

    function _lotSlot(PoolId id) private pure returns (bytes32 slot) {
        assembly ("memory-safe") { mstore(0, id) mstore(32, LOT_SLOT) slot := keccak256(0, 64) }
    }

    function _seenSlot(PoolId id) private pure returns (bytes32 slot) {
        assembly ("memory-safe") { mstore(0, id) mstore(32, SEEN_SLOT) slot := keccak256(0, 64) }
    }

    function _blockClock() private view returns (uint256 height) {
        if (block.chainid != 4_663) return block.number;
        bool ok;
        assembly ("memory-safe") {
            mstore(0, shl(224, 0xa3b1b31d))
            ok := staticcall(CLOCK_GAS, 0x64, 0, 4, 0, 32)
            ok := and(ok, eq(returndatasize(), 32))
            height := mload(0)
        }
        if (!ok || height == 0 || height > type(uint64).max) revert ClockUnavailable();
    }
    function _balanceOf(Currency token, address owner) private view returns (bool ok, uint256 amount) {
        if (token.isAddressZero()) return (true, owner.balance);
        address t = Currency.unwrap(token);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x70a08231)) mstore(add(ptr, 4), owner)
            let success := staticcall(BALANCE_GAS, t, ptr, 36, ptr, 32)
            ok := and(success, iszero(lt(returndatasize(), 32))) amount := mload(ptr)
        }
    }
    function _identity(uint256 context, HookrTypes.SwapContext calldata x) private pure {
        uint256 flags = (x.isBuy ? S.CTX_BUY : 0) | (x.authenticated ? S.CTX_AUTHENTICATED : 0);
        if ((context ^ flags) & (S.CTX_BUY | S.CTX_AUTHENTICATED) != 0) revert InvalidCoreContext();
    }
}
