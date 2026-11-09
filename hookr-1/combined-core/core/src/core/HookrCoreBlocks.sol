// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
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

    IPoolManager public immutable poolManager;
    address private immutable SELF = address(this);

    error Unauthorized();
    error InvalidCoreContext();
    error UnsupportedOut();
    error ClockUnavailable();

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
            S.Pot storage pot = S.holderPot().pots[id];
            pot.start = uint32(block.timestamp);
            pot.openEpoch = 1;
        }
        if (hot & STORM != 0) S.storm().storms[id].settings = uint32(uint256(cold) >> 63) & ((1 << 22) - 1);
        if (hot & SG != 0) S.sandwich().windows[id] = uint256((cold >> 114) & 511) << 224;
        emit CoreBlocksBound(id, uint256(hot) | uint256(cold) << 32);
        // Pool identity, payee, enabled outflow targets and native/dynamic caps are checked by C2 before Bound is stored.
        pc;
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
        if (!x.isBuy && hot & EXIT != 0) {
            exitRate = ((uint256(q.cold) >> 19) & 127) * 10;
            if (x.exactInput && x.authenticated && HookrWallets.isWallet(x.payer)) {
                (, exitRate) = HE._exitBps(S.exitClock().exits[x.id][x.payer], uint256(-x.amountSpecified), q.cold);
            }
            uint256 fee = exitRate * 100;
            if ((q.cold >> 42) & 7 == 0) {
                if (fee > room) fee = room;
                uint256 moved = fee * share / BPS;
                q.lp += fee - moved; q.take += moved; q.hookr += moved;
            } else {
                exitTake = fee; q.take += fee;
                // A partial-fill rebate can erase the quoted top. Only the frozen floor is guaranteed.
                q.hookr += ((uint256(q.cold) >> 26) & 127) * 1_000 * share / BPS;
            }
        }
        if (hot & SG != 0 && q.context & S.CTX_GUARD == 0) {
            sgTake = _sandwich(x.id, x.zeroForOne, isStatic);
            q.take += sgTake; q.hookr += sgTake * share / BPS;
        }
        if (!isStatic) {
            bytes32 slot = S.chargeSlot(x.id, 1);
            bytes32 nothing = S.nothingToSettleSlot(x.id, 1);
            uint256 word = cut | exitTake << 24 | stormTake << 48 | sgTake << 72 | exitRate << 96;
            // Holder epoch rolling applies to every swap, including unauthenticated/launch buys with no carve.
            bool records = hot & HOLDER != 0 || q.context & S.CTX_LAUNCH_BUY == 0 && x.authenticated
                && (!x.isBuy || x.beneficiary == x.payer && HookrWallets.isWallet(x.payer))
                && hot & EXIT != 0;
            assembly ("memory-safe") { tstore(slot, word) tstore(nothing, and(iszero(records), iszero(and(word, sub(shl(96, 1), 1))))) }
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
        S.HolderPotState storage holders = S.holderPot();
        S.Pot storage pot = holders.pots[x.id];
        uint256 epoch;
        if (hot & HOLDER != 0) { epoch = HE._relEpoch(pot, tail.cold); HE._roll(holders, x.id, pot, tail.cold, epoch); }
        protocol = tail.protocol;
        uint16 share = s.pools[x.id].config.protocolShareBps;
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
                if (gross != 0 && x.exactInput && x.authenticated && HookrWallets.isWallet(x.payer)) {
                    uint256 charged = uint16(word >> 96);
                    (uint256 exact,) = HE._exitBps(S.exitClock().exits[x.id][x.payer], z.actualSubject, tail.cold);
                    if (exact < charged) {
                        uint256 rebate = gross - gross * exact / charged;
                        // Preserve the actual combined fee floor across both integer carvings.
                        uint256 repriced = FullMath.mulDiv(z.quoteBasis, uint256(tail.finalTake) - pips + exact * 100, 1_000_000);
                        uint256 maximum = z.rulesFee > repriced ? z.rulesFee - repriced : 0;
                        if (rebate > maximum) rebate = maximum;
                        gross -= rebate;
                        if (rebate != 0) {
                            HookrSinks.allocateClaim(s, x.quote, x.payer, rebate);
                            protocol -= rebate;
                            emit ExitRebated(x.id, x.payer, rebate);
                        }
                    }
                }
            } else if (i == 2) out = uint8((S.storm().storms[x.id].settings >> 19) & 7);
            else out = uint8((S.sandwich().windows[x.id] >> 230) & 7);
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
        if (tracked && hot & HOLDER != 0) {
            HE.Account memory a = HE.Account(x.payer, x.quote, x.subject, epoch);
            if (x.isBuy) HE._holderBuy(holders, s, x.id, pot, tail.cold, a, z.actualSubject - z.subjectBurn);
            else HE._holderSell(holders, s, x.id, pot, tail.cold, a, z.actualSubject);
        }
        if (tracked && hot & EXIT != 0) {
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
        S.HolderPotState storage st = S.holderPot();
        S.Pot storage p = st.pots[id];
        uint256 epoch;
        if (hot & HOLDER != 0) { epoch = HE._relEpoch(p, cold); HE._roll(st, id, p, cold, epoch); }
        uint256 credited;
        if (wallet != address(0)) {
            if (hot & HOLDER != 0) {
                S.Holder memory h;
                (h, credited) = HE._look(st, s, id, p, cold, HE.Account(wallet, quote, subject, epoch), 0, msg.sender);
                st.holders[id][wallet] = h;
            }
            if (hot & EXIT != 0) {
                (bool ok, uint256 balance) = _balanceOf(subject, wallet);
                S.Exit storage e = S.exitClock().exits[id][wallet];
                uint256 total = uint256(e.matured) + e.maturing;
                if (ok && total > balance) {
                    uint256 gone = total - balance;
                    uint256 matured = e.matured;
                    uint256 fromMatured = gone < matured ? gone : matured;
                    e.matured = uint104(matured - fromMatured);
                    e.maturing -= uint104(gone - fromMatured);
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

    function _sandwich(PoolId id, bool zeroForOne, bool isStatic) private returns (uint256) {
        uint256 word = S.sandwich().windows[id];
        uint256 settings = (word >> 224) & 511;
        uint256 window = _blockClock() / ((settings & 3) + 1);
        (uint160 current,,,) = poolManager.getSlot0(id);
        if (window != uint64(word) || uint160(word >> 64) == 0) {
            if (window > type(uint64).max) revert ClockUnavailable();
            if (!isStatic) S.sandwich().windows[id] = window | uint256(current) << 64 | settings << 224;
            return 0;
        }
        return HookrSandwichMath.charge(current, uint160(word >> 64), zeroForOne, uint8((settings >> 2) & 15));
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
