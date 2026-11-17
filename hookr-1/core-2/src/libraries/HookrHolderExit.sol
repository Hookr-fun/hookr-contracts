// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookrRulesStorage as S} from "./HookrRulesStorage.sol";
import {HookrSinks} from "./HookrSinks.sol";
import {HookrCurves} from "./HookrCurves.sol";
import {IHookrCoreBlockEvents} from "../interfaces/IHookrCoreBlockEvents.sol";

/// @notice W1-derived Exit Clock arithmetic over the canonical separate namespace (Holder Pot pays by the token's
///         balance-time meter: HookrCoreSettle).
/// @dev Internal-only routines: callers validate flags, identities, context, and the canonical cold word first.
library HookrHolderExit {
    using CurrencyLibrary for Currency;
    uint256 private constant SCALE = 1 << 96;
    uint256 private constant BALANCE_GAS = 50_000;
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

    /// @dev A sell of `amount` from a HookrToken's lots (`balance`, the fresh lot `fresh` with its time `since`, the rest
    ///      the aged bag), in basis points rounded up: `exact`, what it pays when it fills whole (the fresh lot first at
    ///      its age's rate, then the bag at the floor), and `quoted`, the most any partial fill of it pays, as `_exitBps`
    ///      for a record. The lots cover the sale (`lotsBefore` puts a router's collect back), so unlike a record there
    ///      is nothing beyond them to price; a sale past the balance cannot settle. An exact-output sell (`amount` zero)
    ///      pays the fresh lot's rate, the most any part of it can pay, or the floor when the lot is empty.
    function _exitLotBps(uint256 balance, uint256 fresh, uint256 since, uint256 amount, uint256 w)
        internal
        view
        returns (uint256 exact, uint256 quoted)
    {
        uint256 floor = _bits(w, 26, 7) * 10;
        uint256 young = fresh == 0 ? floor : _exitAgeBps(block.timestamp > since ? block.timestamp - since : 0, w);
        if (amount == 0) return (young, young);
        uint256 n = amount < fresh ? amount : fresh;
        exact = (n * young + (amount - n) * floor + amount - 1) / amount;
        quoted = n != 0 && young > exact ? young : exact;
    }

    /// @dev The Exit Clock rate in bps for tokens held `age` seconds: the top at zero, along the frozen curve, the floor from
    ///      the horizon on. One rate for a whole sell, so a partial fill pays it too (the melt mode, and a lot's rate).
    function _exitAgeBps(uint256 age, uint256 w) internal pure returns (uint256) {
        uint256 top = _bits(w, 19, 7) * 10;
        uint256 floor = _bits(w, 26, 7) * 10;
        uint256 horizon = _bits(w, 33, 6) * (_bits(w, 39, 1) == 0 ? 1 hours : 1 days);
        if (age >= horizon) return floor;
        return HookrCurves.rate(top, floor, horizon, age, uint8(_bits(w, 40, 2)));
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
