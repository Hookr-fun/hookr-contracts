// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {HookrMarketCalendar} from "./HookrMarketCalendar.sol";

/// @title HookrSessionTiers
/// @notice An LP-fee surcharge that follows the US equity session: regular hours, pre-market, after-hours,
/// overnight, and closed (weekends, NYSE closures and the evening before them). Any Hookr advisory that owns a
/// pool's advisory slot can add these tiers to its own surcharge, so a pool keeps a higher off-market fee whatever
/// else its advisory does.
/// @dev Pure math over a calendar Session. The session comes from the shared calendar kept by HookrSessionAdvisory
/// (`sessionAt`), read with `read`, so every pool uses one calendar and its timelocked year appends. The caller
/// clamps the returned value to its own caps.
library HookrSessionTiers {
    /// @notice Per-pool tiers, frozen when the pool binds.
    /// @param regularPips Surcharge during regular hours.
    /// @param preMarketPips Surcharge from 04:00 to the open.
    /// @param afterHoursPips Surcharge for four hours after the close.
    /// @param overnightPips Surcharge from the end of after-hours to 04:00 before a trading day.
    /// @param closedPips Surcharge on weekends, closures and the evening before them.
    /// @param openRampSeconds Seconds after the open over which the surcharge moves linearly from the pre-market to
    ///        the regular value. Zero disables.
    /// @param closeRampSeconds Seconds before the close over which the surcharge moves linearly from the regular to
    ///        the after-hours value. Zero disables.
    /// @param flags UNCOVERED_AS_CLOSED or zero.
    struct Tiers {
        uint24 regularPips;
        uint24 preMarketPips;
        uint24 afterHoursPips;
        uint24 overnightPips;
        uint24 closedPips;
        uint16 openRampSeconds;
        uint16 closeRampSeconds;
        uint8 flags;
    }

    /// @notice Flag: a weekday outside the calendar is charged the closed surcharge.
    uint8 internal constant UNCOVERED_AS_CLOSED = 1;
    /// @notice Largest combined open and close ramp: the shortest regular session.
    uint256 internal constant MAX_RAMP_SECONDS = 12_600;
    /// @notice ABI-encoded size of Tiers.
    uint256 internal constant ENCODED_SIZE = 256;
    /// @notice Gas forwarded to the calendar's `sessionAt`.
    uint256 internal constant READ_GAS = 40_000;
    /// @dev ABI-encoded size of HookrMarketCalendar.Session.
    uint256 private constant SESSION_SIZE = 128;

    error InvalidTiers(uint256 code);

    /// @notice Returns true when every tier is zero, so the pool has no session surcharge.
    function isEmpty(Tiers memory t) internal pure returns (bool) {
        return (uint256(t.regularPips) | t.preMarketPips | t.afterHoursPips | t.overnightPips | t.closedPips) == 0;
    }

    /// @notice Reverts unless the flags are known, the ramps fit the shortest session and every tier is at most
    ///         `capPips`.
    /// @dev Codes: 1 unknown flag, 2 ramps too long, 3 tier above the cap.
    function check(Tiers memory t, uint256 capPips) internal pure {
        uint256 code = validate(t, capPips);
        if (code != 0) revert InvalidTiers(code);
    }

    /// @notice Returns the first code `check` would revert with, or zero when the tiers are valid.
    /// @dev Lets a caller revert with its own error while applying the same rules.
    function validate(Tiers memory t, uint256 capPips) internal pure returns (uint256 code) {
        if (t.flags & ~UNCOVERED_AS_CLOSED != 0) return 1;
        if (uint256(t.openRampSeconds) + t.closeRampSeconds > MAX_RAMP_SECONDS) return 2;
        if (highest(t) > capPips) return 3;
    }

    /// @notice Returns the largest of the five tiers: the most any session or ramp can charge.
    function highest(Tiers memory t) internal pure returns (uint256 pips) {
        pips = t.regularPips;
        if (t.preMarketPips > pips) pips = t.preMarketPips;
        if (t.afterHoursPips > pips) pips = t.afterHoursPips;
        if (t.overnightPips > pips) pips = t.overnightPips;
        if (t.closedPips > pips) pips = t.closedPips;
    }

    /// @notice Returns the surcharge for session `s`, with the open and close ramps. Not clamped.
    /// @dev Never above `highest(t)`. A REGULAR session must have OPEN <= second < close, as the calendar and `read`
    ///      guarantee; otherwise it reverts.
    function value(Tiers memory t, HookrMarketCalendar.Session memory s) internal pure returns (uint256 pips) {
        if (!s.covered && t.flags & UNCOVERED_AS_CLOSED != 0) {
            pips = t.closedPips;
        } else if (s.tier == HookrMarketCalendar.Tier.REGULAR) {
            pips = t.regularPips;
            uint256 elapsed = s.second - HookrMarketCalendar.OPEN;
            uint256 remaining = s.close - s.second;
            if (elapsed < t.openRampSeconds) {
                pips = _lerp(t.preMarketPips, t.regularPips, elapsed, t.openRampSeconds);
            } else if (remaining <= t.closeRampSeconds) {
                pips = _lerp(t.regularPips, t.afterHoursPips, t.closeRampSeconds - remaining, t.closeRampSeconds);
            }
        } else if (s.tier == HookrMarketCalendar.Tier.PRE_MARKET) {
            pips = t.preMarketPips;
        } else if (s.tier == HookrMarketCalendar.Tier.AFTER_HOURS) {
            pips = t.afterHoursPips;
        } else if (s.tier == HookrMarketCalendar.Tier.OVERNIGHT) {
            pips = t.overnightPips;
        } else {
            pips = t.closedPips;
        }
    }

    /// @notice Reads the session at `timestamp` from the shared calendar with a bounded static call.
    /// @dev `ok` is false when the call fails, runs out of its gas or returns anything but one well-formed Session: a
    ///      known tier, a second of day and a close inside the day, and for REGULAR a second in [OPEN, close). The
    ///      swapper sets the gas of the whole transaction, so a caller whose own gas is not guaranteed must not
    ///      charge less on a failed read than on a successful one; `valueAt` charges the highest tier.
    function read(address calendar, uint256 timestamp)
        internal
        view
        returns (bool ok, HookrMarketCalendar.Session memory s)
    {
        bytes memory input = abi.encodeWithSignature("sessionAt(uint256)", timestamp);
        bytes memory output = new bytes(SESSION_SIZE);
        assembly ("memory-safe") {
            ok := staticcall(READ_GAS, calendar, add(input, 32), mload(input), add(output, 32), SESSION_SIZE)
            ok := and(ok, eq(returndatasize(), SESSION_SIZE))
        }
        if (!ok) return (false, s);
        uint256 tier = uint256(bytes32(_word(output, 0)));
        if (tier > uint256(type(HookrMarketCalendar.Tier).max)) return (false, s);
        s.tier = HookrMarketCalendar.Tier(tier);
        s.second = uint256(_word(output, 1));
        s.close = uint256(_word(output, 2));
        s.covered = _word(output, 3) != 0;
        if (s.second >= HookrMarketCalendar.DAY || s.close > HookrMarketCalendar.CLOSE) return (false, s);
        if (s.tier == HookrMarketCalendar.Tier.REGULAR) {
            if (s.second < HookrMarketCalendar.OPEN || s.second >= s.close) return (false, s);
        }
    }

    /// @notice Surcharge at `timestamp` read from `calendar`; the highest tier when the read fails, so starving or
    ///         breaking the read never lowers the fee.
    function valueAt(Tiers memory t, address calendar, uint256 timestamp) internal view returns (uint256) {
        (bool ok, HookrMarketCalendar.Session memory s) = read(calendar, timestamp);
        return ok ? value(t, s) : highest(t);
    }

    /// @dev Linear move from `from` to `to` after `elapsed` of `span` seconds.
    function _lerp(uint256 from, uint256 to, uint256 elapsed, uint256 span) private pure returns (uint256) {
        return from > to ? from - (from - to) * elapsed / span : from + (to - from) * elapsed / span;
    }

    function _word(bytes memory data, uint256 index) private pure returns (bytes32 w) {
        assembly ("memory-safe") {
            w := mload(add(add(data, 32), mul(index, 32)))
        }
    }
}
