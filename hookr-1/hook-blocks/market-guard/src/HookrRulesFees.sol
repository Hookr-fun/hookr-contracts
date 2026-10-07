// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HookrTypes} from "hookr/types/HookrTypes.sol";

/// @title Hookr Rules fee bounds
/// @notice The parts of HookrRules' fee math the market guard freezes at bind, copied because the Rules keep them
///         private: `_protocolPips` and `_buyParts` line for line, the largest native LP fee `_validate` bounds, and
///         the largest sell quote take `_validate` bounds, the Hookr minimum included.
/// @dev Internal library. The protocol's share of each LP Rewards and Auto Burn slice is taken in pips of the gross
///      buyer spend, rounded up; the burn left after it is whole basis points, rounded down. A copy that floors the
///      share per basis point instead overstates the burn by up to 1 bps and LP Rewards by up to 99 pips.
///      `test/RulesFeesDifferential.t.sol` checks `buyParts`, `maxLp` and `maxSellTake` against a deployed
///      HookrRules; a package change to that math must be ported here.
library HookrRulesFees {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant NATIVE_CEILING = 600_000;

    /// @notice HookrRules._protocolPips: the protocol's share of a `bps` slice of a buy, in pips, rounded up.
    function protocolPips(uint256 bps, uint256 shareBps) internal pure returns (uint256) {
        unchecked {
            return (bps * shareBps + 99) / 100;
        }
    }

    /// @notice HookrRules._buyParts without the quote take: a buy's LP Rewards in pips of pool input (LP Rewards less
    ///         its protocol share less the royalty) and the subject burn in whole basis points.
    /// @dev Every input is at most 16 bits, so no product overflows; with protocolShareBps and royaltyBps at most BPS
    ///      (`inRange`) no difference is negative.
    function buyParts(HookrTypes.RulesConfig memory c) internal pure returns (uint256 lpReward, uint256 burnBps) {
        unchecked {
            uint256 lpSlice = protocolPips(c.lpBps, c.protocolShareBps);
            uint256 lpNet = uint256(c.lpBps) * 100 - lpSlice;
            uint256 royaltyPips = lpNet * c.royaltyBps / BPS;
            uint256 burnSlice = protocolPips(c.burnBps, c.protocolShareBps);
            lpReward = lpNet - royaltyPips;
            burnBps = (uint256(c.burnBps) * 100 - burnSlice) / 100;
        }
    }

    /// @notice The largest quote take HookrRules charge on a sell, in pips of the quote that leaves the pool: the
    ///         protocol share of the dynamic fee's span, or the pool's Hookr minimum when that is larger, as
    ///         HookrRules._validate bounds a sell (`max(span * share / BPS, minimum)`). Sells pay no Snipe, LP Rewards,
    ///         Auto Burn or royalty, so a sell's rule share is its dynamic fee share alone, and `_quote` tops a share
    ///         below the minimum up to it. `minimum` is the one the pool froze at bind (`minimumFee`).
    /// @dev A sell's dynamic fee is at most the span (a sell's room, NATIVE_CEILING less base, holds every span the
    ///      Rules accept), and its share rounds down, so no sell takes more. Requires `inRange(c)`. The exact-output
    ///      sell that `simulationQuote` prices for a dynamic fee pool adds the span's share on top of the minimum;
    ///      that figure only sizes the simulation that prices the dynamic fee, and the root reserves the real take.
    function maxSellTake(HookrTypes.RulesConfig memory c, uint256 base, uint256 minimum)
        internal
        pure
        returns (uint256 take)
    {
        uint256 span = c.maxFeePips > base ? c.maxFeePips - base : 0;
        take = span * c.protocolShareBps / BPS;
        if (minimum > take) take = minimum;
    }

    /// @notice Whether the shares are at most whole: HookrRules refuses protocolShareBps above 5,000 and royaltyBps
    ///         above 1,000, so only a foreign Rules reporting the Hookr schema fails this.
    function inRange(HookrTypes.RulesConfig memory c) internal pure returns (bool) {
        return c.protocolShareBps <= BPS && c.royaltyBps <= BPS;
    }

    /// @notice The largest native LP fee (base included) the Rules charge after their guard (`after_`) and at any
    ///         time (`guard`), on a pool with base fee `base`, and the subject burn of a buy in basis points.
    /// @dev `guard` is HookrRules._validate's `maximumLp`, the figure the Rules admit against the pool cap; its clipped
    ///      branch is written with dynamic fee + Snipe = room, which is what clipping leaves. `after_` is the largest
    ///      HookrRules._quote charges once the guard has ended: base + LP Rewards + the dynamic fee clipped to the room
    ///      they leave under NATIVE_CEILING, less the dynamic fee's protocol share (a quote take, not an LP fee), which
    ///      grows with the dynamic fee. Both are at least maxFeePips, the ceiling of a sell's LP fee. A configuration
    ///      whose base and LP Rewards fill NATIVE_CEILING, which the Rules refuse above it, bounds both at
    ///      NATIVE_CEILING. Requires `inRange(c)`; every term is then below 2^26 and no difference is negative.
    function maxLp(HookrTypes.RulesConfig memory c, uint256 base)
        internal
        pure
        returns (uint256 after_, uint256 guard, uint256 burnBps)
    {
        uint256 floor_;
        (floor_, burnBps) = buyParts(c);
        unchecked {
            floor_ += base;
            if (floor_ >= NATIVE_CEILING) return (NATIVE_CEILING, NATIVE_CEILING, burnBps);
            uint256 share = c.protocolShareBps;
            uint256 span = c.maxFeePips > base ? c.maxFeePips - base : 0;
            uint256 snipe = c.snipeTaxPips;
            // Buys: the dynamic fee is clipped to the room left by base and LP Rewards, then Snipe to what remains.
            uint256 room = NATIVE_CEILING - floor_;
            uint256 dynamicFee = span > room ? room : span;
            after_ = floor_ + dynamicFee - dynamicFee * share / BPS;
            if (span + snipe > room) {
                // Clipped: the dynamic fee and Snipe fill the room between two separately rounded shares. Bound both
                // possible one-pip rounding outcomes across every input size, not only the endpoint.
                uint256 slice = room * share / BPS;
                if (slice != 0) --slice;
                guard = floor_ + room - slice;
            } else {
                guard = after_ + snipe - snipe * share / BPS;
            }
        }
        // Caps always cover maxFeePips, the ceiling of a sell's total LP fee.
        if (after_ < c.maxFeePips) after_ = c.maxFeePips;
        if (guard < c.maxFeePips) guard = c.maxFeePips;
    }
}
