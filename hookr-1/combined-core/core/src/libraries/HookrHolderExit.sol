// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookrRulesStorage as S} from "./HookrRulesStorage.sol";
import {HookrSinks} from "./HookrSinks.sol";
import {HookrCurves} from "./HookrCurves.sol";
import {IHookrCoreBlockEvents} from "../interfaces/IHookrCoreBlockEvents.sol";

/// @notice W1-derived Holder Pot and Exit Clock arithmetic over the canonical separate namespaces.
/// @dev Internal-only routines: callers validate flags, identities, context, and the canonical cold word first.
library HookrHolderExit {
    using CurrencyLibrary for Currency;
    uint256 private constant SCALE = 1 << 96;
    uint256 private constant BALANCE_GAS = 50_000;
    struct Account { address wallet; Currency quote; Currency subject; uint256 epoch; }
    function _roll(S.HolderPotState storage st, PoolId id, S.Pot storage p, uint256 w, uint256 t) internal {
        uint256 m = p.openEpoch;
        if (m >= t) return;
        uint256 open = p.open;
        uint256 cap = _bits(w, 46, 6);
        if (open != 0) {
            _mergeTo(st, id, p, m, cap);
            uint256 weight = _weight(st, id, p, w, m);
            uint256 count = p.count;
            uint256 r = weight == 0 ? 0 : FullMath.mulDiv(open, SCALE, weight);
            uint256 a = st.sumA[id][count];
            uint256 b = st.sumB[id][count];
            // A payout that would not fit (never for real pots) carries like an epoch nobody earned in.
            if (r != 0 && r <= (type(uint256).max - b) / m && r <= type(uint256).max - a) {
                ++count;
                st.sumA[id][count] = a + r;
                st.sumB[id][count] = b + m * r;
                uint256 shift = (count & 7) * 32;
                mapping(uint256 => uint256) storage epochs = st.cpEpochs[id];
                epochs[count >> 3] = epochs[count >> 3] & ~(uint256(type(uint32).max) << shift) | m << shift;
                p.count = uint32(count);
                p.reserve += open;
                p.open = 0;
                emit IHookrCoreBlockEvents.HolderPotClosed(id, m, open, weight, count);
            } else {
                emit IHookrCoreBlockEvents.HolderPotCarried(id, m, open);
            }
        }
        _mergeTo(st, id, p, t, cap);
        p.openEpoch = uint32(t);
    }

    /// @dev Merges every entry at or below `m - cap` (past the age cap at the close of epoch `m` and every later one).
    function _mergeTo(S.HolderPotState storage st, PoolId id, S.Pot storage p, uint256 m, uint256 cap) private {
        if (m <= cap) return;
        uint256 upTo = m - cap;
        uint256 merged = p.merged;
        if (upTo <= merged) return;
        p.old += _merge(st, id, merged + 1, upTo);
        p.merged = uint32(upTo);
    }

    /// @dev Total holder weight at the close of epoch `m`: the merged positions at the age cap, plus every live bucket
    ///      at its age. The live buckets are at most cap epochs, from merged + 1 to m.
    function _weight(S.HolderPotState storage st, PoolId id, S.Pot storage p, uint256 w, uint256 m)
        private
        view
        returns (uint256 weight)
    {
        weight = p.old * _wt(_bits(w, 46, 6), w);
        uint256 lo = uint256(p.merged) + 1;
        if (lo > m) return weight;
        mapping(uint256 => uint256) storage buckets = st.buckets[id];
        for (uint256 page = lo >> 8; page <= m >> 8; ++page) {
            uint256 bits = st.pages[id][page] & _mask(page, lo, m);
            while (bits != 0) {
                uint256 e = (page << 8) | _lowestBit(bits);
                bits &= bits - 1;
                weight += buckets[e] * _wt(m - e, w);
            }
        }
    }

    /// @dev Empties the live buckets from `from` to `to` into the merged sum and returns what they held.
    function _merge(S.HolderPotState storage st, PoolId id, uint256 from, uint256 to) private returns (uint256 moved) {
        mapping(uint256 => uint256) storage buckets = st.buckets[id];
        mapping(uint256 => uint256) storage pages = st.pages[id];
        for (uint256 page = from >> 8; page <= to >> 8; ++page) {
            uint256 word = pages[page];
            if (word == 0) continue;
            uint256 mask = _mask(page, from, to);
            uint256 bits = word & mask;
            if (bits == 0) continue;
            pages[page] = word & ~mask;
            while (bits != 0) {
                uint256 e = (page << 8) | _lowestBit(bits);
                bits &= bits - 1;
                moved += buckets[e];
                buckets[e] = 0;
            }
        }
    }

    /// @dev A holder's earnings over checkpoints settled + 1 to `count`: position x the sum of weight(age) x R. Within a
    ///      weekly band the weight is (100 + boost x band) x (epoch - entry), linear in the epoch, so each band costs two
    ///      prefix-sum differences; past the age cap it is flat.
    function _earned(S.HolderPotState storage st, PoolId id, S.Holder memory h, uint256 w, uint256 count) internal
        view
        returns (uint256)
    {
        if (h.position == 0 || h.settled >= count) return 0;
        uint256 cap = _bits(w, 46, 6);
        uint256 perWeek = _bits(w, 45, 1) == 0 ? 7 : 14;
        uint256 boost = (_bits(w, 52, 5) * 5);
        uint256 e = h.entry;
        uint256 end = count + 1;
        mapping(uint256 => uint256) storage sumA = st.sumA[id];
        mapping(uint256 => uint256) storage sumB = st.sumB[id];
        // Checkpoints of the epoch the holder entered in pay it nothing (age 0).
        uint256 c = _firstFrom(st, id, uint256(h.settled) + 1, end, e + 1);
        uint256 total;
        while (c < end) {
            uint256 age = _cpEpoch(st, id, c) - e;
            uint256 aPrev = sumA[c - 1];
            if (age >= cap) {
                total += _wt(cap, w) * (sumA[count] - aPrev);
                break;
            }
            uint256 band = age / perWeek;
            uint256 bandEnd = (band + 1) * perWeek;
            if (bandEnd > cap) bandEnd = cap;
            uint256 next = _firstFrom(st, id, c, end, e + bandEnd);
            total += (100 + boost * band) * ((sumB[next - 1] - sumB[c - 1]) - e * (sumA[next - 1] - aPrev));
            c = next;
        }
        return FullMath.mulDiv(h.position, total, SCALE);
    }

    function _holderBuy(
        S.HolderPotState storage st,
        S.State storage s,
        PoolId id,
        S.Pot storage p,
        uint256 w,
        Account memory a,
        uint256 bought
    ) internal {
        if (bought == 0) return;
        (S.Holder memory h,) = _look(st, s, id, p, w, a, 0, address(0));
        uint256 position = h.position;
        uint256 next = position + bought;
        if (next > type(uint128).max) next = type(uint128).max;
        uint256 entry = a.epoch;
        if (position != 0) {
            _bucketSub(st, id, p, h.entry, position);
            // Age is clamped at the cap before the new tokens average in, so old holdings cannot lend new ones age.
            uint256 from = h.entry;
            uint256 cap = _bits(w, 46, 6);
            if (from + cap < a.epoch) from = a.epoch - cap;
            entry = (position * from + (next - position) * a.epoch + next - 1) / next;
        }
        h.position = uint128(next);
        h.entry = uint32(entry);
        _bucketAdd(st, id, p, entry, next);
        st.held[a.subject][a.wallet] += next - position;
        st.holders[id][a.wallet] = h;
        emit IHookrCoreBlockEvents.HolderMoved(id, a.wallet, next, entry);
    }

    function _holderSell(
        S.HolderPotState storage st,
        S.State storage s,
        PoolId id,
        S.Pot storage p,
        uint256 w,
        Account memory a,
        uint256 sold
    ) internal {
        if (st.holders[id][a.wallet].position == 0) return;
        // A router may take the sold tokens before the look, so the look counts them as still held.
        (S.Holder memory h,) = _look(st, s, id, p, w, a, sold, address(0));
        uint256 position = h.position;
        if (position != 0) {
            uint256 left = sold < position ? position - sold : 0;
            _bucketSub(st, id, p, h.entry, position);
            // White Collar's rule by default: a sell loses the privilege, so what is left starts again at age 0.
            if (_bits(w, 57, 1) == 0) h.entry = uint32(a.epoch);
            h.position = uint128(left);
            if (left != 0) _bucketAdd(st, id, p, h.entry, left);
            st.held[a.subject][a.wallet] -= position - left;
            emit IHookrCoreBlockEvents.HolderMoved(id, a.wallet, left, h.entry);
        }
        st.holders[id][a.wallet] = h;
    }

    /// @dev A look at `a.wallet`: what it earned so far is credited to its claims, unless it holds less of the subject
    ///      (plus `extra`, tokens a router may already have taken) than its positions across the subject's pools, in
    ///      which case those earnings go back to the open pot, less `poker`'s bounty (none for the wallet itself or a
    ///      swap's own look), and this pool's position is cut by the shortfall and restarts at age 0. A subject whose
    ///      balance cannot be read is taken at its word. Returns the holder, settled to every checkpoint so far, and what
    ///      was credited; the caller stores the holder.
    function _look(
        S.HolderPotState storage st,
        S.State storage s,
        PoolId id,
        S.Pot storage p,
        uint256 w,
        Account memory a,
        uint256 extra,
        address poker
    ) internal returns (S.Holder memory h, uint256 credited) {
        h = st.holders[id][a.wallet];
        uint256 count = p.count;
        uint256 earned = _take(p, _earned(st, id, h, w, count));
        h.settled = uint32(count);
        if (h.position != 0) {
            (bool ok, uint256 balance) = _balanceOf(a.subject, a.wallet);
            uint256 total = st.held[a.subject][a.wallet];
            // Compare the deficit without adding an untrusted token balance to the router's extra.
            if (ok && balance < total && extra < total - balance) {
                uint256 bounty = poker == address(0) || poker == a.wallet ? 0 : earned * _bits(w, 58, 5) / 100;
                if (bounty != 0) HookrSinks.allocateClaim(s, a.quote, poker, bounty);
                // Existing reserve money is already a liability. A clamped return goes to the launch position,
                // with no second liability write; it can never silently become the new rule-fee residual.
                (, uint256 excess) = HookrSinks.allocateHolderPot(st, id, earned - bounty);
                if (excess != 0) {
                    HookrSinks.allocateAccrual(s, id, a.quote, excess);
                    emit IHookrCoreBlockEvents.PoolAccrued(id, a.quote, excess);
                }
                uint256 cut = total - balance - extra;
                if (cut > h.position) cut = h.position;
                _bucketSub(st, id, p, h.entry, h.position);
                uint256 left = h.position - cut;
                st.held[a.subject][a.wallet] = total - cut;
                h.position = uint128(left);
                h.entry = uint32(a.epoch);
                if (left != 0) _bucketAdd(st, id, p, a.epoch, left);
                emit IHookrCoreBlockEvents.HolderForfeited(id, a.wallet, poker, earned, bounty);
                emit IHookrCoreBlockEvents.HolderMoved(id, a.wallet, left, a.epoch);
                return (h, 0);
            }
        }
        if (earned != 0) {
            HookrSinks.allocateClaim(s, a.quote, a.wallet, earned);
            credited = earned;
            emit IHookrCoreBlockEvents.HolderCredited(id, a.wallet, earned);
        }
    }

    /// @dev Takes `amount` out of the paid-out reserve, at most what it holds.
    function _take(S.Pot storage p, uint256 amount) private returns (uint256) {
        uint256 reserve = p.reserve;
        if (amount > reserve) amount = reserve;
        p.reserve = reserve - amount;
        return amount;
    }

    function _bucketAdd(S.HolderPotState storage st, PoolId id, S.Pot storage p, uint256 e, uint256 amount) private {
        if (e <= p.merged) {
            p.old += amount;
            return;
        }
        st.buckets[id][e] += amount;
        st.pages[id][e >> 8] |= uint256(1) << (e & 255);
    }

    function _bucketSub(S.HolderPotState storage st, PoolId id, S.Pot storage p, uint256 e, uint256 amount) private {
        if (amount == 0) return;
        if (e <= p.merged) {
            p.old -= amount;
            return;
        }
        uint256 left = st.buckets[id][e] - amount;
        st.buckets[id][e] = left;
        if (left == 0) st.pages[id][e >> 8] &= ~(uint256(1) << (e & 255));
    }

    /// @dev Smallest checkpoint in [lo, end) whose epoch is at least `epoch`, or `end` if none.
    function _firstFrom(S.HolderPotState storage st, PoolId id, uint256 lo, uint256 end, uint256 epoch)
        private
        view
        returns (uint256)
    {
        uint256 hi = end;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (_cpEpoch(st, id, mid) >= epoch) hi = mid;
            else lo = mid + 1;
        }
        return lo;
    }

    function _cpEpoch(S.HolderPotState storage st, PoolId id, uint256 c) private view returns (uint256) {
        return uint32(st.cpEpochs[id][c >> 3] >> ((c & 7) * 32));
    }

    /// @dev A holder's weight at age `a` epochs: a x (100 + boost x full weeks in a), with a at most the age cap.
    function _wt(uint256 a, uint256 w) private pure returns (uint256) {
        uint256 cap = _bits(w, 46, 6);
        if (a > cap) a = cap;
        uint256 perWeek = _bits(w, 45, 1) == 0 ? 7 : 14;
        return a * (100 + (_bits(w, 52, 5) * 5) * (a / perWeek));
    }

    function _epochLength(uint256 w) private pure returns (uint256) {
        return _bits(w, 45, 1) == 0 ? 1 days : 12 hours;
    }

    /// @dev The current epoch, 1 for the epoch that starts at the bind. The bind time is kept mod 2^32, so the age is
    ///      exact for 136 years.
    function _relEpoch(S.Pot storage p, uint256 w) internal view returns (uint256) {
        uint256 elapsed;
        unchecked {
            elapsed = uint32(uint32(block.timestamp) - p.start);
        }
        return elapsed / _epochLength(w) + 1;
    }

    /// @dev The block.timestamp epoch `rel` starts at (mod 2^32, like the bind time it counts from).
    function _epochStart(S.Pot storage p, uint256 rel, uint256 w) internal view returns (uint256) {
        return uint256(p.start) + (rel - 1) * _epochLength(w);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Exit Clock
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev An exact-input sell of `amount`, in basis points rounded up: `exact`, what it pays when it fills whole (the
    ///      newest tokens leave first at their age's rate, then the tokens past the horizon at the floor, then anything
    ///      beyond the record at the top), and `quoted`, the most any partial fill of it pays, which is what the sell is
    ///      quoted at: a fill is always a first part of the sale, and the first part's average is highest either in the
    ///      young tokens or for the whole sale.
    function _exitBps(S.Exit memory e, uint256 amount, uint256 w) internal view returns (uint256 exact, uint256 quoted) {
        uint256 top = (_bits(w, 19, 7) * 10);
        if (amount == 0) return (top, top);
        uint256 floor = (_bits(w, 26, 7) * 10);
        uint256 horizon = (_bits(w, 33, 6) * (_bits(w, 39, 1) == 0 ? 1 hours : 1 days));
        uint256 matured = e.matured;
        uint256 maturing = e.maturing;
        uint256 young;
        uint256 age = block.timestamp > e.entry ? block.timestamp - e.entry : 0;
        if (age >= horizon) {
            matured += maturing;
            maturing = 0;
        } else {
            young = HookrCurves.rate(top, floor, horizon, age, uint8(_bits(w, 40, 2)));
        }
        uint256 n = amount < maturing ? amount : maturing;
        uint256 rest = amount - n;
        uint256 m = rest < matured ? rest : matured;
        rest -= m;
        exact = (n * young + m * floor + rest * top + amount - 1) / amount;
        quoted = n != 0 && young > exact ? young : exact;
    }

    /// @dev Exact one-word C1 layout: matured104/maturing104/entry40, with the upper8 bits preserved. A buy restarts
    ///      the maturing tokens' entry at now: one entry cannot keep a fresh lot apart from an older maturing bag, and
    ///      an averaged entry lent the bag's age to the newest tokens, which leave first (attack round 1, B-5). So the
    ///      bag still maturing at a buy matures with the lot; what had matured by then stays matured.
    function _exitBuy(S.Exit storage e, uint256 bought, uint256 w) internal {
        if (bought == 0) return;
        uint256 word;
        assembly ("memory-safe") { word := sload(e.slot) }
        uint256 matured = uint104(word);
        uint256 maturing = uint104(word >> 104);
        if (maturing != 0 && block.timestamp >= uint256(uint40(word >> 208)) + (_bits(w, 33, 6) * (_bits(w, 39, 1) == 0 ? 1 hours : 1 days))) {
            matured += maturing;
            if (matured > type(uint104).max) matured = type(uint104).max;
            maturing = 0;
        }
        uint256 next = maturing + bought;
        if (next > type(uint104).max) next = type(uint104).max;
        word = (word & ~uint256(type(uint248).max)) | matured | next << 104 | uint256(uint40(block.timestamp)) << 208;
        assembly ("memory-safe") { sstore(e.slot, word) }
    }

    function _exitSell(S.Exit storage e, uint256 sold, uint256 w) internal {
        uint256 word;
        assembly ("memory-safe") { word := sload(e.slot) }
        uint256 matured = uint104(word);
        uint256 maturing = uint104(word >> 104);
        if (maturing != 0 && block.timestamp >= uint256(uint40(word >> 208)) + (_bits(w, 33, 6) * (_bits(w, 39, 1) == 0 ? 1 hours : 1 days))) {
            matured += maturing;
            maturing = 0;
        }
        uint256 fromMaturing = sold < maturing ? sold : maturing;
        maturing -= fromMaturing;
        sold -= fromMaturing;
        matured -= sold < matured ? sold : matured;
        if (matured > type(uint104).max) matured = type(uint104).max;
        word = (word & ~uint256(type(uint208).max)) | matured | maturing << 104;
        assembly ("memory-safe") { sstore(e.slot, word) }
    }

    function _balanceOf(Currency token, address owner) private view returns (bool ok, uint256 amount) {
        if (token.isAddressZero()) return (true, owner.balance);
        address t = Currency.unwrap(token);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x70a08231))
            mstore(add(ptr, 4), owner)
            // The call first: Yul evaluates arguments right to left, so returndatasize() must come after it.
            let success := staticcall(BALANCE_GAS, t, ptr, 36, ptr, 32)
            ok := and(success, iszero(lt(returndatasize(), 32)))
            amount := mload(ptr)
        }
    }

    function _bits(uint256 w, uint256 offset, uint256 length) private pure returns (uint256) {
        return (w >> offset) & ((uint256(1) << length) - 1);
    }

    /// @dev The bits of bitmap page `page` for epochs `lo` to `hi`.
    function _mask(uint256 page, uint256 lo, uint256 hi) private pure returns (uint256 mask) {
        uint256 start = page << 8;
        mask = type(uint256).max;
        if (lo > start) mask &= type(uint256).max << (lo - start);
        if (hi < start + 255) mask &= type(uint256).max >> (start + 255 - hi);
    }

    /// @dev Index of the lowest set bit of a nonzero `x`.
    function _lowestBit(uint256 x) private pure returns (uint256 r) {
        x &= ~x + 1;
        if (x >= 1 << 128) {
            x >>= 128;
            r += 128;
        }
        if (x >= 1 << 64) {
            x >>= 64;
            r += 64;
        }
        if (x >= 1 << 32) {
            x >>= 32;
            r += 32;
        }
        if (x >= 1 << 16) {
            x >>= 16;
            r += 16;
        }
        if (x >= 1 << 8) {
            x >>= 8;
            r += 8;
        }
        if (x >= 1 << 4) {
            x >>= 4;
            r += 4;
        }
        if (x >= 1 << 2) {
            x >>= 2;
            r += 2;
        }
        if (x >= 1 << 1) r += 1;
    }

}
