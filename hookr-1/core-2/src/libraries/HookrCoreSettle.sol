// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrTokenMeter} from "../interfaces/IHookrTokenMeter.sol";
import {IHookrCoreBlockEvents} from "../interfaces/IHookrCoreBlockEvents.sol";
import {HookrRulesStorage as S} from "./HookrRulesStorage.sol";
import {HookrBlockCall as Call} from "./HookrBlockCall.sol";
import {HookrHolderExit as HE} from "./HookrHolderExit.sol";
import {HookrWallets} from "./HookrWallets.sol";
import {HookrSinks} from "./HookrSinks.sol";

/// @notice HookrCoreBlocks' settle-time rebates and the Holder Pot's day accounting, as a linked library (EIP-170 keeps
///         the Hook Block under 24,576 bytes): the Exit Clock's rebate from the most a partial fill pays down to the exact
///         rate of what filled, Sandwich Guard's reprice of a sale that carries the price past the window's opening,
///         and Holder Pot's days, paid by the token's balance-time meter. All run by delegatecall from the Hook Block, in
///         its storage and transient storage, and emit from its address.
/// @dev Only the Hook Block's `blockSettle` calls here, after the Rules authenticated the settle; the library writes nothing
///      a settle does not (a claim for the trader, the pre-swap price's reset). The block's immutables are not visible
///      under delegatecall, so the PoolManager is an argument.
library HookrCoreSettle {
    /// @dev erc7201:hookr.rules.holder.potByDay: each Holder Pot pool's closed days' pots. Its own namespace, not a field
    ///      of the shared storage library: HookrRules compiles that file, and the core's metadata must stay the stores'.
    bytes32 private constant POT_DAYS_SLOT = 0xe32546b170ed7a8358d84012d430ff32171a29090936b560fea0ba9e8cfef700;

    function _potDays() private pure returns (mapping(PoolId => mapping(uint256 => uint256)) storage days_) {
        assembly ("memory-safe") { days_.slot := POT_DAYS_SLOT }
    }

    using StateLibrary for IPoolManager;

    uint256 private constant BPS = 10_000;
    uint256 private constant LOT_MASK = (uint256(1) << 108) - 1;
    /// @dev erc7201:hookr.rules.sandwich.pre: per pool, transient, the sqrt price and tick a charged swap started at
    ///      (price | tick << 160) and, in the next slot, the liquidity it started in; kept by the guard's quote for its
    ///      settle, which charges only the part of the sale up to the window's opening (audit 10-31, 1.3: an honest sale
    ///      past the opening paid the rate on all of it). Its own namespace, as the Hook Block's `_seenSlot`.
    bytes32 private constant PRE_SLOT = 0xa377ba1d82eb5d696048121d8ff95aeed81cb7373d1ebdf281156f4042d5b700;

    /// @dev The Exit Clock's settle-time rebate on a sell quoted at the most a partial fill pays (paid to the liquidity
    ///      owner, a payee or a pot): down to the exact rate of what filled, within the pool's combined fee floor and,
    ///      on a pool with a Hookr minimum, leaving Hookr the minimum. `lot` is the token-mode quote's stash (fresh 108 |
    ///      aged 108 | since 40), zero when the quote priced no lot. Returns the charge less the rebate, and the
    ///      protocol's take less it.
    function exitRebate(
        HookrTypes.SwapContext calldata x, HookrTypes.Settlement calldata z, Call.Settle calldata tail, uint256 word,
        uint256 lot, bool exitRecords, uint24 pips, uint256 gross, uint256 protocol
    ) external returns (uint256, uint256) {
        if (gross == 0 || !(exitRecords || lot != 0) || !x.exactInput || !x.authenticated || !HookrWallets.isWallet(x.payer)) {
            return (gross, protocol);
        }
        uint256 charged = uint16(word >> 96);
        uint256 exact;
        if (exitRecords) (exact,) = HE._exitBps(S.exitClock().exits[x.id][x.payer], z.actualSubject, tail.cold);
        else (exact,) = HE._exitLotBps((lot & LOT_MASK) + ((lot >> 108) & LOT_MASK), lot & LOT_MASK, lot >> 216, z.actualSubject, tail.cold);
        if (exact >= charged) return (gross, protocol);
        uint256 rebate = gross - gross * exact / charged;
        // Preserve the actual combined fee floor across both integer carvings.
        uint256 repriced = FullMath.mulDiv(z.quoteBasis, uint256(tail.finalTake) - pips + exact * 100, 1_000_000);
        uint256 maximum = z.rulesFee > repriced ? z.rulesFee - repriced : 0;
        if (rebate > maximum) rebate = maximum;
        S.State storage s = S.rules();
        // A pool with a Hookr minimum keeps Hookr at it: the rebate takes only what is left above the minimum once the
        // charges' creator parts are paid (a refused allocation only leaves more).
        if (s.pools[x.id].terms & S.TERMS_MINIMUM != 0) {
            maximum = minimumRoom(x.id, z, word, gross, protocol, tail.finalTake, s.pools[x.id].config.protocolShareBps);
            if (rebate > maximum) rebate = maximum;
        }
        if (rebate != 0) {
            HookrSinks.allocateClaim(s, x.quote, x.payer, rebate);
            emit IHookrCoreBlockEvents.ExitRebated(x.id, x.payer, rebate);
        }
        return (gross - rebate, protocol - rebate);
    }

    /// @dev The most steps the settle's walk from the swap's start to the opening takes (a step is one bitmap word
    ///      scanned or one initialized tick crossed, about 5,100 gas) before the settle keeps the whole charge instead:
    ///      a window dense with initialized ticks (dust positions on a fine tick spacing, security review 10-31, 6)
    ///      costs the honest trader the rebate, never the pool the charge, and a sandwicher gains nothing by it.
    uint256 private constant WALK_STEPS = 128;

    /// @dev The guard's quote keeps, for its settle, the sqrt price, tick and liquidity a charged swap starts at, so the
    ///      settle can walk the swap from there to the window's opening along the pool's own liquidity.
    function sandwichStash(IPoolManager poolManager, PoolId id) external {
        (uint160 current, int24 tick,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        bytes32 at = preSlot(id);
        uint256 word = uint256(current) | uint256(uint24(tick)) << 160;
        assembly ("memory-safe") { tstore(at, word) tstore(add(at, 1), liquidity) }
    }

    /// @dev Sandwich Guard's settle-time reprice: the quote charged the whole sale at the rate for the move from the price
    ///      the swap started at (`pre`, kept by `sandwichStash`) to the window's opening; a sale that carries the price
    ///      past the opening is a sandwich only up to it. The part beyond is repriced away: the charge keeps the share of
    ///      the sale that lies up to the opening, and the rest goes back to the trader as a claim, within the pool's
    ///      combined fee floor and, on a pool with a Hookr minimum, leaving Hookr the minimum. The share is exact: the
    ///      settle walks the swap from the price, tick and liquidity it started at to the opening along the pool's own
    ///      ticks (`_insideQuote`, the PoolManager's swap walk without fees), and sets that quote against the quote the
    ///      pool moved (a sell's output; a buy's input less the pool's LP fee, read from slot0 so a dynamic fee's
    ///      surcharge counts). A share read from the liquidity at the start or from the sqrt-price distance alone reads
    ///      low where the liquidity changes along the way (attack round and design review 10-31: an overshoot through
    ///      thin liquidity past a deeper window gave the reversal back). A walk of more than WALK_STEPS steps keeps the
    ///      whole charge. Only a wallet trader is rebated, as Exit Clock's rebate: an unauthenticated swap names its
    ///      router as the payer. Returns the charge less the rebate, and the protocol's take less it.
    function sandwichReprice(
        IPoolManager poolManager, HookrTypes.SwapContext calldata x, HookrTypes.Settlement calldata z, uint256 gross,
        uint256 protocol, uint16 share
    ) external returns (uint256, uint256) {
        bytes32 at = preSlot(x.id);
        uint256 word;
        uint256 liquidity;
        assembly ("memory-safe") { word := tload(at) liquidity := tload(add(at, 1)) tstore(at, 0) tstore(add(at, 1), 0) }
        uint160 pre = uint160(word);
        if (pre == 0 || gross == 0 || !x.authenticated || !HookrWallets.isWallet(x.payer)) return (gross, protocol);
        uint160 opening = uint160(S.sandwich().windows[x.id] >> 64);
        (uint160 post,,, uint24 lpFee) = poolManager.getSlot0(x.id);
        // Inside the window the whole sale is the sandwich's reversal; so is a swap that started past the opening.
        if (x.zeroForOne ? post >= opening || pre <= opening : post <= opening || pre >= opening) return (gross, protocol);
        S.State storage s = S.rules();
        (bool walked, uint256 inside) = _insideQuote(
            poolManager, x.id, s.pools[x.id].tickSpacing, x.zeroForOne, s.pools[x.id].quoteIsCurrency0,
            pre, int24(uint24(word >> 160)), uint128(liquidity), opening
        );
        uint256 moved = z.actualQuote;
        if (x.isBuy) moved -= moved * lpFee / 1_000_000;
        if (!walked || inside >= moved) return (gross, protocol);
        uint256 kept = FullMath.mulDiv(gross, inside, moved);
        if (kept >= gross) return (gross, protocol);
        uint256 rebate = gross - kept;
        // Slot 3 settles last, so no later charge's creator part is owed (word 0).
        if (s.pools[x.id].terms & S.TERMS_MINIMUM != 0) {
            uint256 room = minimumRoom(x.id, z, 0, gross, protocol, 0, share);
            if (rebate > room) rebate = room;
        }
        if (rebate == 0) return (gross, protocol);
        HookrSinks.allocateClaim(s, x.quote, x.payer, rebate);
        emit IHookrCoreBlockEvents.SandwichRepriced(x.id, x.payer, rebate);
        return (gross - rebate, protocol - rebate);
    }

    /// @dev The quote a swap trades from `price` (at `tick`, in `liquidity`) to `opening`, along the pool's initialized
    ///      ticks as the PoolManager walks them, without fees, rounded up: the part of the sale inside the window. The
    ///      pool's liquidity cannot change between the swap and its settle, so the walk at settle sees the ticks the swap
    ///      crossed. False when it would take more than WALK_STEPS steps.
    function _insideQuote(
        IPoolManager poolManager, PoolId id, int24 spacing, bool zeroForOne, bool quoteIsCurrency0, uint160 price,
        int24 tick, uint128 liquidity, uint160 opening
    ) private view returns (bool, uint256 inside) {
        for (uint256 steps; price != opening; ++steps) {
            if (steps == WALK_STEPS) return (false, 0);
            (int24 next, bool initialized) = _nextTick(poolManager, id, tick, spacing, zeroForOne);
            if (next <= TickMath.MIN_TICK) next = TickMath.MIN_TICK;
            else if (next >= TickMath.MAX_TICK) next = TickMath.MAX_TICK;
            uint160 nextPrice = TickMath.getSqrtPriceAtTick(next);
            uint160 target = zeroForOne ? (nextPrice < opening ? opening : nextPrice) : (nextPrice > opening ? opening : nextPrice);
            inside += quoteIsCurrency0
                ? SqrtPriceMath.getAmount0Delta(target, price, liquidity, true)
                : SqrtPriceMath.getAmount1Delta(price, target, liquidity, true);
            price = target;
            if (price == nextPrice && price != opening) {
                if (initialized) {
                    (, int128 net) = poolManager.getTickLiquidity(id, next);
                    if (zeroForOne) net = -net;
                    liquidity = net < 0 ? liquidity - uint128(-net) : liquidity + uint128(net);
                }
                tick = zeroForOne ? next - 1 : next;
            }
        }
        return (true, inside);
    }

    /// @dev TickBitmap.nextInitializedTickWithinOneWord over the PoolManager's bitmap, read by extsload.
    function _nextTick(IPoolManager poolManager, PoolId id, int24 tick, int24 spacing, bool lte)
        private view returns (int24 next, bool initialized)
    {
        unchecked {
            int24 compressed = TickBitmap.compress(tick, spacing);
            if (lte) {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 masked = poolManager.getTickBitmap(id, wordPos) & (type(uint256).max >> (uint256(type(uint8).max) - bitPos));
                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * spacing
                    : (compressed - int24(uint24(bitPos))) * spacing;
            } else {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(++compressed);
                uint256 masked = poolManager.getTickBitmap(id, wordPos) & ~((1 << bitPos) - 1);
                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * spacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * spacing;
            }
        }
    }

    /// @dev Holder Pot's day: UTC days, the token's meter grid.
    uint256 private constant DAY = 1 days;
    /// @dev The most closed days one look pays: on a swap, SWAP_DAYS forward from the wallet's last paid day (a swap's
    ///      settle stays small: about 6,000 gas a day); on a poke, POKE_DAYS forward and POKE_DAYS back from its first.
    uint256 private constant SWAP_DAYS = 2;
    uint256 private constant POKE_DAYS = 16;

    /// @dev Closes the pool's open day into its day pot once the day is over: the takings since the last close belong
    ///      to the day they came in (`openEpoch` is that day); a day with no takings leaves no pot.
    function holderRoll(PoolId id) external {
        S.HolderPotState storage st = S.holderPot();
        S.Pot storage p = st.pots[id];
        uint256 today = block.timestamp / DAY;
        uint256 open = p.openEpoch;
        if (open >= today) return;
        uint256 amount = p.open;
        if (amount != 0) {
            _potDays()[id][open] = amount;
            p.reserve += amount;
            p.open = 0;
            emit IHookrCoreBlockEvents.HolderPotClosed(id, open, amount, 0, 0);
        }
        p.openEpoch = uint32(today);
    }

    /// @dev A wallet's paid window and the token's cursors, packed in S.Holder: `position` = the window's first day (32)
    ///      | the wallet's entry at or before it (32) | the supply's (32) | the wallet's entry at or before the window's
    ///      last day (32); `entry` = the supply's at or before the last day; `settled` = the last day.
    struct Window { uint256 lo; uint256 hi; uint256 wLo; uint256 sLo; uint256 wHi; uint256 sHi; }

    /// @dev Pays `wallet` its share of the pool's closed days by the token's meter: for each day, the day's pot x the
    ///      wallet's balance-seconds / the wallets' supply's balance-seconds (the token's reads; a contract's read zero,
    ///      so the pool's own tokens earn nothing and the days pay out in full). The wallet's paid days are one window
    ///      [`position`, `settled`]: a look on the wallet's swap pays the newest closed days (its first look) or the days
    ///      after the window, at most SWAP_DAYS; a poke (`back`) pays up to POKE_DAYS forward and POKE_DAYS before the
    ///      window, down to the bind day, so older days are collected on demand, by anyone, with no keeper. Each read
    ///      starts from the cursor the previous read returned (the token's entry at the window's edge), so a read costs
    ///      its days, however many moves the wallet or the supply made in between (attack round 11-01, 6); a read the
    ///      token refuses skips that step. Credits are claims.
    function holderLook(PoolId id, address wallet, Currency subject, Currency quote, bool back)
        external returns (uint256 credited)
    {
        S.HolderPotState storage st = S.holderPot();
        S.Pot storage p = st.pots[id];
        S.Holder storage h = st.holders[id][wallet];
        uint256 today = block.timestamp / DAY;
        uint256 start = p.start;
        if (today == 0 || start >= today) return 0;
        uint256 yesterday = today - 1;
        Window memory w;
        {
            uint256 packed = h.position;
            w.lo = uint32(packed); w.wLo = uint32(packed >> 32); w.sLo = uint32(packed >> 64); w.wHi = uint32(packed >> 96);
            w.sHi = h.entry;
            w.hi = h.settled;
        }
        uint256 most = back ? POKE_DAYS : SWAP_DAYS;
        IHookrTokenMeter t = IHookrTokenMeter(Currency.unwrap(subject));
        if (w.hi == 0) {
            uint256 from = yesterday + 1 > start + most ? yesterday + 1 - most : start;
            (bool ok, uint256 earned, uint256[4] memory c) = _payDays(st, id, t, wallet, from, yesterday, 0, 0);
            if (!ok) return 0;
            credited = earned;
            (w.lo, w.hi, w.wLo, w.sLo, w.wHi, w.sHi) = (from, yesterday, c[0], c[1], c[2], c[3]);
        } else if (w.hi < yesterday) {
            uint256 from = w.hi + 1;
            uint256 to = yesterday - from + 1 > most ? from + most - 1 : yesterday;
            (bool ok, uint256 earned, uint256[4] memory c) = _payDays(st, id, t, wallet, from, to, w.wHi, w.sHi);
            if (!ok) return 0;
            credited = earned;
            (w.hi, w.wHi, w.sHi) = (to, c[2], c[3]);
        }
        if (back && w.lo > start) {
            uint256 to = w.lo - 1;
            uint256 from = to + 1 > start + POKE_DAYS ? to + 1 - POKE_DAYS : start;
            (bool ok, uint256 earned, uint256[4] memory c) = _payDays(st, id, t, wallet, from, to, w.wLo, w.sLo);
            if (ok) {
                credited += earned;
                (w.lo, w.wLo, w.sLo) = (from, c[0], c[1]);
            }
        }
        h.position = uint128(w.lo | w.wLo << 32 | w.sLo << 64 | w.wHi << 96);
        h.entry = uint32(w.sHi);
        h.settled = uint32(w.hi);
        if (credited != 0) {
            uint256 reserve = p.reserve;
            if (credited > reserve) credited = reserve;
            p.reserve = reserve - credited;
            HookrSinks.allocateClaim(S.rules(), quote, wallet, credited);
            emit IHookrCoreBlockEvents.HolderCredited(id, wallet, credited);
        }
    }

    /// @dev What `wallet` earned over the closed days `from` to `to` by the token's reads from the cursors `hintW` (the
    ///      wallet's) and `hintS` (the supply's); the cursors the reads return (the wallet's and the supply's at or
    ///      before `from - 1`, then at or before `to`); false when the token refuses a read, so the caller leaves those
    ///      days unpaid.
    function _payDays(
        S.HolderPotState storage st, PoolId id, IHookrTokenMeter t, address wallet, uint256 from, uint256 to,
        uint256 hintW, uint256 hintS
    ) private view returns (bool ok, uint256 earned, uint256[4] memory cursors) {
        uint256[] memory held;
        uint256[] memory supply;
        try t.balanceSecondsFrom(wallet, from, to, hintW) returns (uint256[] memory a, uint256 s0, uint256 s1) {
            held = a; cursors[0] = s0; cursors[2] = s1;
        } catch { return (false, 0, cursors); }
        try t.walletSupplySecondsFrom(from, to, hintS) returns (uint256[] memory a, uint256 s0, uint256 s1) {
            supply = a; cursors[1] = s0; cursors[3] = s1;
        } catch { return (false, 0, cursors); }
        if (held.length != to - from + 1 || supply.length != held.length) return (false, 0, cursors);
        mapping(uint256 => uint256) storage pots = _potDays()[id];
        for (uint256 i; i < held.length; ++i) {
            uint256 pot = pots[from + i];
            // A wallet's day is at most the wallets' supply's (the token's sums), so the share is at most the pot.
            if (pot != 0 && held[i] != 0 && supply[i] >= held[i]) earned += FullMath.mulDiv(pot, held[i], supply[i]);
        }
        return (true, earned, cursors);
    }

    /// @dev The most a rebate may take on a pool with a Hookr minimum, so that Hookr keeps the minimum (minFeePips of
    ///      the basis): the protocol's take so far, less the minimum, less the creator parts of the Exit Clock charge
    ///      (`gross`, slot 1) and of the later charges (slots 2 and 3), which the settle still pays out, is what Hookr
    ///      has to spare; a rebate costs Hookr only its share of it (the creator's part of the charge shrinks with the
    ///      rebate), so the rebate may be that spare divided by the share.
    function minimumRoom(
        PoolId id, HookrTypes.Settlement calldata z, uint256 word, uint256 gross, uint256 protocol, uint24 finalTake, uint16 share
    ) private view returns (uint256) {
        uint256 need = FullMath.mulDiv(z.quoteBasis, S.rules().integrations[id].minFeePips, 1_000_000);
        (, uint256 creator) = HookrSinks.split(gross, share);
        need += creator;
        for (uint256 j = 2; j < 4; ++j) {
            uint24 pips = uint24(word >> (j * 24));
            if (pips == 0) continue;
            (, creator) = HookrSinks.split(HookrSinks.carve(z.rulesFee, pips, finalTake), share);
            need += creator;
        }
        return protocol > need ? (protocol - need) * BPS / share : 0;
    }

    /// @dev The pre-swap price and tick's transient slot for a pool (the liquidity sits in the next one):
    ///      `sandwichStash` writes them, `sandwichReprice` reads and clears them, the Hook Block's guard quote clears them
    ///      when it charges nothing. Internal, so the block inlines it.
    function preSlot(PoolId id) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") { mstore(0, id) mstore(32, PRE_SLOT) slot := keccak256(0, 64) }
    }
}
