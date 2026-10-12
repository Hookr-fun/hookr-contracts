// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test, console2} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrSessionTiers} from "../../src/libraries/HookrSessionTiers.sol";
import {HookrMarketCalendar} from "../../src/libraries/HookrMarketCalendar.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";

/// @notice Exposes the library's internal functions.
contract TiersHarness {
    function value(HookrSessionTiers.Tiers memory t, HookrMarketCalendar.Session memory s)
        external
        pure
        returns (uint256)
    {
        return HookrSessionTiers.value(t, s);
    }

    function read(address calendar, uint256 timestamp)
        external
        view
        returns (bool ok, HookrMarketCalendar.Session memory s)
    {
        return HookrSessionTiers.read(calendar, timestamp);
    }

    function valueAt(HookrSessionTiers.Tiers memory t, address calendar, uint256 timestamp)
        external
        view
        returns (uint256)
    {
        return HookrSessionTiers.valueAt(t, calendar, timestamp);
    }

    function check(HookrSessionTiers.Tiers memory t, uint256 cap) external pure {
        HookrSessionTiers.check(t, cap);
    }

    function validate(HookrSessionTiers.Tiers memory t, uint256 cap) external pure returns (uint256) {
        return HookrSessionTiers.validate(t, cap);
    }

    function isEmpty(HookrSessionTiers.Tiers memory t) external pure returns (bool) {
        return HookrSessionTiers.isEmpty(t);
    }

    function highest(HookrSessionTiers.Tiers memory t) external pure returns (uint256) {
        return HookrSessionTiers.highest(t);
    }
}

/// @notice The tier math of HookrSessionAdvisory before it used the library, kept verbatim as the differential
///         reference.
library ReferenceSessionMath {
    function value(HookrSessionTiers.Tiers memory b, HookrMarketCalendar.Session memory s)
        internal
        pure
        returns (uint256 value_)
    {
        if (!s.covered && b.flags & 1 != 0) {
            value_ = b.closedPips;
        } else if (s.tier == HookrMarketCalendar.Tier.REGULAR) {
            value_ = b.regularPips;
            uint256 elapsed = s.second - HookrMarketCalendar.OPEN;
            uint256 remaining = s.close - s.second;
            if (elapsed < b.openRampSeconds) {
                value_ = _lerp(b.preMarketPips, b.regularPips, elapsed, b.openRampSeconds);
            } else if (remaining <= b.closeRampSeconds) {
                value_ = _lerp(b.regularPips, b.afterHoursPips, b.closeRampSeconds - remaining, b.closeRampSeconds);
            }
        } else if (s.tier == HookrMarketCalendar.Tier.PRE_MARKET) {
            value_ = b.preMarketPips;
        } else if (s.tier == HookrMarketCalendar.Tier.AFTER_HOURS) {
            value_ = b.afterHoursPips;
        } else if (s.tier == HookrMarketCalendar.Tier.OVERNIGHT) {
            value_ = b.overnightPips;
        } else {
            value_ = b.closedPips;
        }
    }

    function _lerp(uint256 from, uint256 to, uint256 elapsed, uint256 span) private pure returns (uint256) {
        return from > to ? from - (from - to) * elapsed / span : from + (to - from) * elapsed / span;
    }
}

/// @notice Returns four fixed words as a Session, whatever it is asked.
contract WordsCalendar {
    uint256[4] internal w;

    function set(uint256 a, uint256 b, uint256 c, uint256 d) external {
        w = [a, b, c, d];
    }

    fallback() external {
        uint256[4] memory x = w;
        assembly ("memory-safe") {
            return(x, 128)
        }
    }
}

/// @notice Hostile calendars.
contract RevertingCalendar {
    fallback() external {
        revert("no");
    }
}

contract BurningCalendar {
    fallback() external {
        while (true) {}
    }
}

contract SizedCalendar {
    uint256 internal immutable size;

    constructor(uint256 size_) {
        size = size_;
    }

    fallback() external {
        uint256 n = size;
        assembly ("memory-safe") {
            return(0, n)
        }
    }
}

/// @notice Unit, fuzz and adversarial tests of HookrSessionTiers, and a differential fuzz against
///         HookrSessionAdvisory's own tier math over 2026-2032 with 2031 appended.
contract HookrSessionTiersTest is Test {
    uint24 internal constant REGULAR = 1000;
    uint24 internal constant PRE = 4000;
    uint24 internal constant AFTER = 6000;
    uint24 internal constant NIGHT = 10_000;
    uint24 internal constant CLOSED = 20_000;

    TiersHarness internal h;
    HookrSessionAdvisory internal cal;
    WordsCalendar internal words;
    uint256 internal from2026;
    uint256 internal to2033;

    function setUp() public {
        h = new TiersHarness();
        words = new WordsCalendar();
        cal = new HookrSessionAdvisory(address(this), 1 days);
        cal.queue(cal.APPEND_YEAR(), abi.encode(uint16(2031), _closed2031(), _early2031()));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        cal.appendYear(2031, _closed2031(), _early2031());
        from2026 = HookrMarketCalendar.dayOf(2026, 1, 1) * 1 days;
        to2033 = HookrMarketCalendar.dayOf(2033, 1, 1) * 1 days;
    }

    // ------------------------------------------------------------ helpers

    function _tiers(uint16 openRamp, uint16 closeRamp, uint8 flags)
        internal
        pure
        returns (HookrSessionTiers.Tiers memory)
    {
        return HookrSessionTiers.Tiers(REGULAR, PRE, AFTER, NIGHT, CLOSED, openRamp, closeRamp, flags);
    }

    function _ny(uint256 y, uint256 m, uint256 d, uint256 hr, uint256 mi, uint256 sec, bool dst)
        internal
        pure
        returns (uint256)
    {
        return
            HookrMarketCalendar.dayOf(y, m, d) * 1 days + hr * 1 hours + mi * 1 minutes + sec + (dst ? 4 : 5) * 1 hours;
    }

    function _u16(uint256[] memory a) internal pure returns (uint16[] memory out) {
        out = new uint16[](a.length);
        for (uint256 i; i < a.length; ++i) {
            out[i] = uint16(a[i]);
        }
    }

    function _closed2031() internal pure returns (uint16[] memory) {
        uint256[] memory a = new uint256[](10);
        (a[0], a[1], a[2], a[3], a[4]) = (101, 120, 217, 411, 526);
        (a[5], a[6], a[7], a[8], a[9]) = (619, 704, 901, 1127, 1225);
        return _u16(a);
    }

    function _early2031() internal pure returns (uint16[] memory) {
        uint256[] memory a = new uint256[](3);
        (a[0], a[1], a[2]) = (703, 1128, 1224);
        return _u16(a);
    }

    function _at(HookrSessionTiers.Tiers memory t, uint256 ts) internal view returns (uint256) {
        return h.valueAt(t, address(cal), ts);
    }

    function _fuzzTiers(uint256 seed) internal pure returns (HookrSessionTiers.Tiers memory t) {
        uint256 r = uint256(keccak256(abi.encode(seed)));
        t.regularPips = uint24(r);
        t.preMarketPips = uint24(r >> 24);
        t.afterHoursPips = uint24(r >> 48);
        t.overnightPips = uint24(r >> 72);
        t.closedPips = uint24(r >> 96);
        uint256 open = (r >> 120) % (HookrSessionTiers.MAX_RAMP_SECONDS + 1);
        t.openRampSeconds = uint16(open);
        t.closeRampSeconds = uint16((r >> 140) % (HookrSessionTiers.MAX_RAMP_SECONDS - open + 1));
        t.flags = uint8((r >> 160) & 1);
        // Ramps of exactly zero and of the whole early-close session are the edges.
        if ((r >> 170) % 8 == 0) (t.openRampSeconds, t.closeRampSeconds) = (0, 0);
        if ((r >> 170) % 8 == 1) (t.openRampSeconds, t.closeRampSeconds) = (uint16(open), uint16(12_600 - open));
    }

    // ------------------------------------------------------------ check, validate, isEmpty, highest

    function testCheckCodes() public {
        HookrSessionTiers.Tiers memory t = _tiers(0, 0, 0);
        h.check(t, CLOSED);
        assertEq(h.validate(t, CLOSED), 0);
        t.flags = 2;
        vm.expectRevert(abi.encodeWithSelector(HookrSessionTiers.InvalidTiers.selector, 1));
        h.check(t, CLOSED);
        t = _tiers(12_000, 601, 0);
        vm.expectRevert(abi.encodeWithSelector(HookrSessionTiers.InvalidTiers.selector, 2));
        h.check(t, CLOSED);
        t = _tiers(12_000, 600, 0);
        h.check(t, CLOSED);
        vm.expectRevert(abi.encodeWithSelector(HookrSessionTiers.InvalidTiers.selector, 3));
        h.check(t, CLOSED - 1);
        // Flags win over ramps, ramps over caps.
        t = _tiers(12_600, 1, 2);
        assertEq(h.validate(t, 0), 1);
        t.flags = 0;
        assertEq(h.validate(t, 0), 2);
    }

    function testFuzzValidateMatchesCheck(uint256 seed, uint24 cap, uint8 flags) public {
        HookrSessionTiers.Tiers memory t = _fuzzTiers(seed);
        t.flags = flags;
        t.openRampSeconds = uint16(seed >> 200);
        t.closeRampSeconds = uint16(seed >> 216);
        uint256 code = h.validate(t, cap);
        if (code == 0) {
            h.check(t, cap);
        } else {
            vm.expectRevert(abi.encodeWithSelector(HookrSessionTiers.InvalidTiers.selector, code));
            h.check(t, cap);
        }
        bool tierAbove = t.regularPips > cap || t.preMarketPips > cap || t.afterHoursPips > cap || t.overnightPips > cap
            || t.closedPips > cap;
        uint256 expected =
            flags > 1 ? 1 : uint256(t.openRampSeconds) + t.closeRampSeconds > 12_600 ? 2 : tierAbove ? 3 : 0;
        assertEq(code, expected);
    }

    function testIsEmptyAndHighest() public view {
        HookrSessionTiers.Tiers memory t;
        assertTrue(h.isEmpty(t));
        t.openRampSeconds = 100;
        t.flags = 1;
        assertTrue(h.isEmpty(t), "ramps and flags alone charge nothing");
        assertEq(h.highest(t), 0);
        uint24[5] memory v = [uint24(7), 3, 9, 1, 2];
        for (uint256 i; i < 5; ++i) {
            HookrSessionTiers.Tiers memory u;
            (u.regularPips, u.preMarketPips, u.afterHoursPips, u.overnightPips, u.closedPips) =
            (v[i % 5], v[(i + 1) % 5], v[(i + 2) % 5], v[(i + 3) % 5], v[(i + 4) % 5]);
            assertFalse(h.isEmpty(u));
            assertEq(h.highest(u), 9);
        }
    }

    // ------------------------------------------------------------ calendar read

    function testReadMatchesCalendar() public view {
        uint256[5] memory ts = [
            _ny(2026, 9, 28, 11, 0, 0, true),
            _ny(2026, 11, 27, 12, 59, 59, false),
            _ny(2026, 11, 26, 20, 0, 0, false),
            _ny(2031, 11, 27, 12, 0, 0, false),
            _ny(2032, 3, 3, 11, 0, 0, false)
        ];
        for (uint256 i; i < ts.length; ++i) {
            (bool ok, HookrMarketCalendar.Session memory s) = h.read(address(cal), ts[i]);
            HookrMarketCalendar.Session memory e = cal.sessionAt(ts[i]);
            assertTrue(ok);
            assertEq(uint256(s.tier), uint256(e.tier));
            assertEq(s.second, e.second);
            assertEq(s.close, e.close);
            assertEq(s.covered, e.covered);
        }
    }

    function testReadRefusesHostileCalendars() public {
        HookrSessionTiers.Tiers memory t = _tiers(0, 0, 0);
        address[6] memory bad = [
            address(new RevertingCalendar()),
            address(new BurningCalendar()),
            address(new SizedCalendar(96)),
            address(new SizedCalendar(160)),
            address(new SizedCalendar(4096)),
            address(0xCa1e)
        ];
        for (uint256 i; i < bad.length; ++i) {
            (bool ok,) = h.read(bad[i], 1);
            assertFalse(ok);
            assertEq(h.valueAt(t, bad[i], _ny(2026, 9, 28, 11, 0, 0, true)), CLOSED, "highest tier");
        }
        // Precompiles return the wrong size or nothing.
        for (uint160 p = 1; p <= 0x11; ++p) {
            (bool ok,) = h.read(address(p), 1);
            assertFalse(ok);
        }
    }

    function testReadGasIsBounded() public {
        BurningCalendar burner = new BurningCalendar();
        HookrSessionTiers.Tiers memory t = _tiers(0, 0, 0);
        uint256 g = gasleft();
        h.valueAt(t, address(burner), 1);
        uint256 used = g - gasleft();
        console2.log("valueAt against a gas-burning calendar", used);
        assertLt(used, HookrSessionTiers.READ_GAS + 12_000);
    }

    /// @dev Malformed words: an out-of-range tier, second or close, and a REGULAR session outside [OPEN, close).
    function testReadRefusesMalformedSessions() public {
        uint256 regular = uint256(HookrMarketCalendar.Tier.REGULAR);
        uint256 open = HookrMarketCalendar.OPEN;
        uint256 close = HookrMarketCalendar.CLOSE;
        uint256[4][7] memory bad = [
            [uint256(5), 40_000, close, 1],
            [uint256(1), 86_400, close, 1],
            [uint256(1), 40_000, close + 1, 1],
            [regular, open - 1, close, 1],
            [regular, close, close, 1],
            [regular, 50_000, HookrMarketCalendar.EARLY_CLOSE, 1],
            [regular, open, open, 1]
        ];
        HookrSessionTiers.Tiers memory t = _tiers(0, 0, 0);
        for (uint256 i; i < bad.length; ++i) {
            words.set(bad[i][0], bad[i][1], bad[i][2], bad[i][3]);
            (bool ok,) = h.read(address(words), 0);
            assertFalse(ok);
            assertEq(h.valueAt(t, address(words), 0), CLOSED);
        }
        // Without the `second < close` check, a REGULAR session at its close with no close ramp divided by zero.
        words.set(regular, close, close, 1);
        assertEq(h.valueAt(t, address(words), 0), CLOSED);
        // Well-formed edges pass: the last regular second, a non-canonical true, the latest close.
        words.set(regular, close - 1, close, 7);
        (bool ok2, HookrMarketCalendar.Session memory s) = h.read(address(words), 0);
        assertTrue(ok2);
        assertTrue(s.covered);
        assertEq(h.valueAt(t, address(words), 0), REGULAR);
    }

    /// @dev Whatever four words a calendar returns, valueAt never reverts and never charges above the highest tier;
    ///      a well-formed session is priced exactly as `value` prices it.
    function testFuzzAnyCalendarWords(uint256 seed, uint256 a, uint256 b, uint256 c, uint256 d) public {
        HookrSessionTiers.Tiers memory t = _fuzzTiers(seed);
        if (seed % 2 == 0) {
            a = a % 6;
            b = b % 90_000;
            c = c % 60_000;
            d = d % 3;
        }
        words.set(a, b, c, d);
        uint256 v = h.valueAt(t, address(words), seed);
        assertLe(v, h.highest(t));
        (bool ok, HookrMarketCalendar.Session memory s) = h.read(address(words), seed);
        if (ok) assertEq(v, h.value(t, s));
        else assertEq(v, h.highest(t));
    }

    /// @dev The swapper sets the transaction's gas. For every gas budget, valueAt either runs out of gas itself or
    ///      charges at least the fully funded value.
    function testGasStarvationNeverLowersTheFee() public {
        // Regular hours are the dearest tier here and closed the cheapest, the case a closed-tier fallback got wrong.
        HookrSessionTiers.Tiers memory t = HookrSessionTiers.Tiers(9000, 100, 100, 100, 50, 0, 0, 0);
        uint256[2] memory ts = [_ny(2026, 9, 28, 11, 0, 0, true), _ny(2031, 3, 4, 11, 0, 0, false)];
        for (uint256 k; k < ts.length; ++k) {
            uint256 expected = _at(t, ts[k]);
            assertEq(expected, 9000);
            uint256 succeeded;
            for (uint256 g = 2_000; g < 80_000; g += 250) {
                vm.cool(address(cal));
                (bool ok, bytes memory out) =
                    address(h).call{gas: g}(abi.encodeCall(TiersHarness.valueAt, (t, address(cal), ts[k])));
                if (!ok) continue;
                ++succeeded;
                assertGe(abi.decode(out, (uint256)), expected, "starved read lowered the fee");
            }
            assertGt(succeeded, 0);
        }
    }

    /// @dev The calendar's cold worst case (an appended year, both day words from storage) fits READ_GAS with room.
    function testReadGasFitsCalendarWorstCase() public {
        uint256[3] memory ts =
            [_ny(2026, 9, 28, 11, 0, 0, true), _ny(2031, 7, 3, 21, 0, 0, true), _ny(2030, 12, 31, 21, 0, 0, false)];
        for (uint256 i; i < ts.length; ++i) {
            vm.cool(address(cal));
            uint256 g = gasleft();
            cal.sessionAt(ts[i]);
            uint256 used = g - gasleft();
            console2.log("cold sessionAt", used);
            assertLt(used, HookrSessionTiers.READ_GAS / 2);
        }
    }

    // ------------------------------------------------------------ tier and ramp math

    function testTiersThroughCalendar() public view {
        HookrSessionTiers.Tiers memory t = _tiers(0, 0, 0);
        assertEq(_at(t, _ny(2026, 9, 28, 3, 59, 59, true)), NIGHT);
        assertEq(_at(t, _ny(2026, 9, 28, 4, 0, 0, true)), PRE);
        assertEq(_at(t, _ny(2026, 9, 28, 9, 30, 0, true)), REGULAR);
        assertEq(_at(t, _ny(2026, 9, 28, 16, 0, 0, true)), AFTER);
        assertEq(_at(t, _ny(2026, 9, 28, 20, 0, 0, true)), NIGHT);
        assertEq(_at(t, _ny(2026, 9, 25, 20, 0, 0, true)), CLOSED);
        assertEq(_at(t, _ny(2026, 9, 26, 12, 0, 0, true)), CLOSED);
        assertEq(_at(t, _ny(2026, 11, 25, 20, 0, 0, false)), CLOSED, "evening before Thanksgiving");
        assertEq(_at(t, _ny(2026, 11, 27, 13, 0, 0, false)), AFTER, "early close");
        assertEq(_at(t, _ny(2026, 11, 27, 17, 0, 0, false)), CLOSED, "Friday after the early close");
    }

    function testDstSwitchDays() public view {
        HookrSessionTiers.Tiers memory t = _tiers(0, 0, 0);
        // 2026-03-08: Sunday evening turns overnight at 20:00 EDT; Monday opens at 09:30 EDT = 13:30 UTC.
        assertEq(_at(t, _ny(2026, 3, 8, 1, 59, 59, false)), CLOSED);
        assertEq(_at(t, _ny(2026, 3, 8, 3, 0, 0, true)), CLOSED);
        assertEq(_at(t, _ny(2026, 3, 8, 19, 59, 59, true)), CLOSED);
        assertEq(_at(t, _ny(2026, 3, 8, 20, 0, 0, true)), NIGHT);
        assertEq(_at(t, _ny(2026, 3, 9, 9, 29, 59, true)), PRE);
        assertEq(_at(t, _ny(2026, 3, 9, 9, 30, 0, true)), REGULAR);
        // 2026-11-01: the repeated 01:00 hour, then 20:00 EST; Monday opens at 09:30 EST = 14:30 UTC.
        assertEq(_at(t, _ny(2026, 11, 1, 1, 59, 59, true)), CLOSED);
        assertEq(_at(t, _ny(2026, 11, 1, 1, 0, 0, false)), CLOSED);
        assertEq(_at(t, _ny(2026, 11, 1, 19, 59, 59, false)), CLOSED);
        assertEq(_at(t, _ny(2026, 11, 1, 20, 0, 0, false)), NIGHT);
        assertEq(_at(t, _ny(2026, 11, 2, 9, 29, 59, false)), PRE);
        assertEq(_at(t, _ny(2026, 11, 2, 9, 30, 0, false)), REGULAR);
        assertEq(_at(t, _ny(2026, 10, 30, 15, 59, 59, true)), REGULAR);
        assertEq(_at(t, _ny(2026, 10, 30, 16, 0, 0, true)), AFTER);
    }

    function testUncoveredYears() public view {
        HookrSessionTiers.Tiers memory plain = _tiers(0, 0, 0);
        HookrSessionTiers.Tiers memory strict = _tiers(0, 0, 1);
        // 2031 is appended: its closures are covered for both.
        uint256 thanksgiving = _ny(2031, 11, 27, 12, 0, 0, false);
        assertEq(_at(plain, thanksgiving), CLOSED);
        assertEq(_at(strict, thanksgiving), CLOSED);
        assertEq(_at(strict, _ny(2031, 3, 4, 11, 0, 0, false)), REGULAR);
        // 2032 is not: a weekday prices by its session, or closed under the flag.
        uint256 t2032 = _ny(2032, 3, 3, 11, 0, 0, false);
        assertEq(_at(plain, t2032), REGULAR);
        assertEq(_at(strict, t2032), CLOSED);
        // The last covered evening before an uncovered weekday is uncovered too.
        assertEq(_at(strict, _ny(2031, 12, 30, 21, 0, 0, false)), NIGHT);
        assertEq(_at(strict, _ny(2031, 12, 31, 21, 0, 0, false)), CLOSED);
        assertEq(_at(plain, _ny(2031, 12, 31, 21, 0, 0, false)), NIGHT);
        // Weekends are closed in every year, covered or not.
        assertEq(_at(plain, _ny(2040, 6, 2, 12, 0, 0, true)), CLOSED);
        // Before 2026 every weekday is uncovered.
        assertEq(_at(strict, _ny(2025, 12, 31, 11, 0, 0, false)), CLOSED);
        assertEq(_at(plain, _ny(2025, 12, 31, 11, 0, 0, false)), REGULAR);
    }

    /// @dev Both ramps filling the whole 13:00 early-close session: continuous, monotone within each half, exact at the
    ///      ends, and the close ramp follows the early close.
    function testRampsFillEarlyCloseSession() public view {
        HookrSessionTiers.Tiers memory t = _tiers(5400, 7200, 0);
        uint256 day = _ny(2026, 11, 27, 0, 0, 0, false);
        uint256 open = day + HookrMarketCalendar.OPEN;
        uint256 close = day + HookrMarketCalendar.EARLY_CLOSE;
        assertEq(_at(t, open - 1), PRE);
        assertEq(_at(t, open), PRE);
        assertEq(_at(t, open + 2700), (uint256(PRE) + REGULAR) / 2);
        assertEq(_at(t, open + 5400), REGULAR);
        assertEq(_at(t, close - 7200), REGULAR);
        assertEq(_at(t, close - 3600), (uint256(REGULAR) + AFTER) / 2);
        assertEq(_at(t, close), AFTER);
        uint256 previous = PRE;
        for (uint256 s = open; s < close; s += 60) {
            uint256 v = _at(t, s);
            uint256 step = v > previous ? v - previous : previous - v;
            assertLe(step, 60 * uint256(AFTER - REGULAR) / 7200 + 1, "ramp jump");
            if (s <= open + 5400) assertLe(v, previous);
            else assertGe(v, previous);
            previous = v;
        }
        // On a full day the same close ramp starts three hours later.
        uint256 full = _ny(2026, 11, 30, 0, 0, 0, false);
        assertEq(_at(t, full + HookrMarketCalendar.CLOSE - 3600), (uint256(REGULAR) + AFTER) / 2);
        assertEq(_at(t, full + HookrMarketCalendar.EARLY_CLOSE - 3600), REGULAR);
    }

    function testFuzzValueNeverAboveHighest(uint256 seed, uint8 tier, uint256 second, bool early, bool covered)
        public
        view
    {
        HookrSessionTiers.Tiers memory t = _fuzzTiers(seed);
        HookrMarketCalendar.Session memory s;
        s.tier = HookrMarketCalendar.Tier(tier % 5);
        s.close = early ? HookrMarketCalendar.EARLY_CLOSE : HookrMarketCalendar.CLOSE;
        s.covered = covered;
        s.second = s.tier == HookrMarketCalendar.Tier.REGULAR
            ? bound(second, HookrMarketCalendar.OPEN, s.close - 1)
            : bound(second, 0, HookrMarketCalendar.DAY - 1);
        uint256 v = h.value(t, s);
        assertLe(v, h.highest(t));
        assertEq(v, ReferenceSessionMath.value(t, s));
    }

    // ------------------------------------------------------------ differential

    /// @dev HookrSessionTiers.valueAt over the shared calendar equals the pre-library tier math of
    ///      HookrSessionAdvisory, and HookrSessionAdvisory's own surcharge for a pool bound with the same schedule, for
    ///      random schedules and instants in 2026-2032 with 2031 appended.
    function testFuzzDifferentialAgainstSessionAdvisory(uint256 seed, uint256 timestamp) public {
        HookrSessionTiers.Tiers memory t = _fuzzTiers(seed);
        timestamp = bound(timestamp, from2026, to2033 - 1);
        if (seed % 4 == 0) {
            // Land near a session edge: 04:00, 09:30, the close, 20:00 and the DST switch hours.
            uint256[7] memory edges = [uint256(14_400), 34_200, 46_800, 57_600, 72_000, 25_200, 21_600];
            timestamp = (timestamp / 1 days) * 1 days + edges[(seed >> 8) % 7] + 14_400 + (seed >> 16) % 7200 - 3600;
        }
        PoolId id = PoolId.wrap(keccak256(abi.encode(seed, timestamp)));
        cal.bindPair(id, type(uint24).max, 60_000, abi.encode(t));

        uint256 lib = h.valueAt(t, address(cal), timestamp);
        assertEq(lib, ReferenceSessionMath.value(t, cal.sessionAt(timestamp)), "reference math");
        assertEq(lib, cal.surchargeAt(address(this), id, timestamp), "session advisory");
        vm.warp(timestamp);
        assertEq(lib, cal.surchargeForSwap(id, seed % 2 == 0, -1, 0, "", address(0)), "session advisory swap path");
    }

    /// @dev Every hour of 2026-2032 for one schedule with both ramps: the library and the advisory agree.
    function testDifferentialSweep() public {
        HookrSessionTiers.Tiers memory t = _tiers(1800, 900, 1);
        PoolId id = PoolId.wrap(bytes32(uint256(1)));
        cal.bindPair(id, type(uint24).max, 60_000, abi.encode(t));
        for (uint256 ts = from2026 + 1 hours / 2 + 7 minutes; ts < to2033; ts += 1 hours + 11 minutes) {
            assertEq(h.valueAt(t, address(cal), ts), cal.surchargeAt(address(this), id, ts));
        }
    }
}
