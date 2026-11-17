// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrRevenueTokenizer} from "../interfaces/IHookrRevenueTokenizer.sol";
import {IHookrRevenueDoor} from "../interfaces/IHookrRevenueDoor.sol";
import {IHookrFamilyForwarder} from "../interfaces/IHookrFamilyForwarder.sol";
import {EndKind} from "../types/EndKind.sol";
import {HookrRevenueTokenizerStorage} from "./HookrRevenueTokenizerStorage.sol";

/// @title Hookr revenue stream ends
/// @notice How a stored stream ends, read live: a Rules ledger never ends; a family as its forwarder answers for it; a
///         first-party door as its `ends()` answers; a source as its `ends()` answers within `SOURCE_VIEW_GAS`, checked
///         for shape, so a source that does not answer reads `ENDED` and never takes a view down with it.
/// @dev Internal functions only, compiled into the tokenizer and its streams library.
library HookrRevenueStreamEnds {
    /// @notice Gas each read of a source's views gets.
    uint256 internal constant SOURCE_VIEW_GAS = 200_000;
    uint64 internal constant FOREVER = type(uint64).max;

    /// @notice The record of stream `s` with its end read now.
    function record(HookrRevenueTokenizerStorage.Stream memory s)
        internal
        view
        returns (IHookrRevenueTokenizer.StreamRecord memory r)
    {
        r.kind = s.kind;
        r.door = s.door;
        r.id = s.id;
        r.legBps = s.legBps;
        r.addedAt = s.addedAt;
        r.family = s.family;
        (r.endKind, r.end) = ends(s.kind, s.door, s.family);
    }

    /// @notice How the stream of `kind` at `door` ends now; `family` is a family's index in its forwarder.
    function ends(IHookrRevenueTokenizer.StreamKind kind, address door, uint256 family)
        internal
        view
        returns (EndKind, uint64)
    {
        if (kind == IHookrRevenueTokenizer.StreamKind.RULES) return (EndKind.FOREVER, 0);
        if (kind == IHookrRevenueTokenizer.StreamKind.FAMILY || kind == IHookrRevenueTokenizer.StreamKind.MARKET) {
            IHookrFamilyForwarder.Family memory f = IHookrFamilyForwarder(door).familyAt(family);
            if (f.released) return (EndKind.ENDED, 0);
            if (f.unlockBlock == FOREVER) return (EndKind.FOREVER, 0);
            return (EndKind.AT_BLOCK, f.unlockBlock);
        }
        if (kind == IHookrRevenueTokenizer.StreamKind.SOURCE) return sourceEnds(door);
        return IHookrRevenueDoor(door).ends();
    }

    /// @notice A source's `ends()` within `SOURCE_VIEW_GAS`; `ENDED` when it does not answer two words in range.
    function sourceEnds(address source) internal view returns (EndKind, uint64) {
        (bool ok, uint256 kind, uint256 at) = read(source, abi.encodeCall(IHookrRevenueDoor.ends, ()), 2);
        if (!ok || kind > uint256(EndKind.ENDED) || at > FOREVER) return (EndKind.ENDED, 0);
        return (EndKind(kind), uint64(at));
    }

    /// @notice A staticcall of `data` on `target` with `SOURCE_VIEW_GAS` that must answer exactly `words` words (one
    ///         or two), read past the free memory pointer. A revert, a burn past the cap, no code or an answer of
    ///         another size is `ok` false with zero words.
    function read(address target, bytes memory data, uint256 words)
        internal
        view
        returns (bool ok, uint256 w0, uint256 w1)
    {
        uint256 cap = SOURCE_VIEW_GAS;
        assembly ("memory-safe") {
            let p := mload(0x40)
            ok := staticcall(cap, target, add(data, 0x20), mload(data), p, 0x40)
            ok := and(ok, eq(returndatasize(), shl(5, words)))
            w0 := mul(mload(p), ok)
            w1 := mul(mload(add(p, 0x20)), and(ok, eq(words, 2)))
        }
    }
}
