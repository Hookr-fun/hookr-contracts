// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title HookrMarketCalendar
/// @notice Maps a unix timestamp to a US equity trading session in New York time.
/// @dev The UTC offset follows the US rule: daylight time from 02:00 local on the second Sunday of March to 02:00
///      local on the first Sunday of November. NYSE full-day closures and 13:00 early closes for 2026 through 2030
///      are constants. Later years are read from an append-only storage extension. Days are indexed from
///      2026-01-01 in New York time; one bit per day marks a closure or an early close. A covered weekday may also
///      carry a mark (`mark`): a closure or an early close the calendar does not publish, such as an unscheduled NYSE
///      closure. A day the calendar closes stays closed; any other covered weekday takes its mark when it has one,
///      ahead of its compiled or appended kind.
library HookrMarketCalendar {
    /// @notice Session tiers.
    /// @dev OVERNIGHT is 20:00 (17:00 after an early close) to 04:00 before a trading day. CLOSED covers weekends,
    ///      full-day closures and the evening before them.
    enum Tier {
        REGULAR,
        PRE_MARKET,
        AFTER_HOURS,
        OVERNIGHT,
        CLOSED
    }

    /// @notice Session state at one instant.
    /// @param tier The session tier.
    /// @param second New York second of day.
    /// @param close New York second of day at which the regular session closes (16:00, or 13:00 on an early close).
    /// @param covered False when a weekday that decides the tier lies outside the calendar.
    struct Session {
        Tier tier;
        uint256 second;
        uint256 close;
        bool covered;
    }

    /// @notice Calendar years appended after deployment, and the marked days.
    /// @param endDay First day index not covered. Zero means the constant range only.
    /// @param lastYear Last covered year. Zero means 2030.
    /// @param closed Full-day closure bits by 256-day word.
    /// @param early Early-close bits by 256-day word.
    /// @param marks Day marks, two bits a day by 128-day word, days indexed as for `closed`: FULL (0) for none, EARLY
    ///        for a 13:00 early close, SHUT for a full-day closure.
    struct Extension {
        uint32 endDay;
        uint16 lastYear;
        mapping(uint256 word => uint256) closed;
        mapping(uint256 word => uint256) early;
        mapping(uint256 word => uint256) marks;
    }

    /// @notice Days from 1970-01-01 to 2026-01-01.
    uint256 internal constant EPOCH_DAY = 20_454;
    /// @notice Days covered by constants: 2026-01-01 through 2030-12-31.
    uint256 internal constant CONSTANT_DAYS = 1826;
    /// @notice First year the calendar covers.
    uint256 internal constant FIRST_YEAR = 2026;
    /// @notice Last year covered by constants.
    uint256 internal constant CONSTANT_LAST_YEAR = 2030;
    uint256 internal constant DAY = 86_400;
    uint256 internal constant EST = 18_000;
    uint256 internal constant EDT = 14_400;
    uint256 internal constant PRE_OPEN = 14_400;
    uint256 internal constant OPEN = 34_200;
    uint256 internal constant CLOSE = 57_600;
    uint256 internal constant EARLY_CLOSE = 46_800;
    uint256 internal constant EXTENDED = 14_400;
    uint256 internal constant EVENING = 72_000;

    /// @notice A day's kind: a full session. As a mark: none.
    uint256 internal constant FULL = 0;
    /// @notice A day's kind and mark: a 13:00 early close.
    uint256 internal constant EARLY = 1;
    /// @notice A day's kind and mark: a full-day closure.
    uint256 internal constant SHUT = 2;
    uint256 private constant UNKNOWN = 3;

    /// @notice Returns the session at `timestamp`.
    function session(Extension storage x, uint256 timestamp) internal view returns (Session memory s) {
        uint256 offset = utcOffset(timestamp);
        uint256 local = timestamp > offset ? timestamp - offset : 0;
        uint256 day = local / DAY;
        s.second = local % DAY;
        s.close = CLOSE;
        uint256 kind = dayKind(x, day);
        s.covered = kind != UNKNOWN;
        if (kind == SHUT) {
            s.tier = Tier.CLOSED;
            if (s.second >= EVENING) {
                uint256 next = dayKind(x, day + 1);
                if (next != SHUT) {
                    s.tier = Tier.OVERNIGHT;
                    s.covered = next != UNKNOWN;
                }
            }
            return s;
        }
        if (kind == EARLY) s.close = EARLY_CLOSE;
        if (s.second < PRE_OPEN) {
            s.tier = Tier.OVERNIGHT;
        } else if (s.second < OPEN) {
            s.tier = Tier.PRE_MARKET;
        } else if (s.second < s.close) {
            s.tier = Tier.REGULAR;
        } else if (s.second < s.close + EXTENDED) {
            s.tier = Tier.AFTER_HOURS;
        } else {
            uint256 next = dayKind(x, day + 1);
            s.tier = next == SHUT ? Tier.CLOSED : Tier.OVERNIGHT;
            if (next == UNKNOWN) s.covered = false;
        }
    }

    /// @notice Returns the New York offset from UTC in seconds at `timestamp`.
    function utcOffset(uint256 timestamp) internal pure returns (uint256) {
        (uint256 y, uint256 m, uint256 d) = civil(timestamp / DAY);
        if (m > 3 && m < 11) return EDT;
        if (m < 3 || m > 11) return EST;
        uint256 second = timestamp % DAY;
        if (m == 3) {
            uint256 start = 8 + (7 - weekday(dayOf(y, 3, 1))) % 7;
            if (d != start) return d > start ? EDT : EST;
            return second >= 7 hours ? EDT : EST;
        }
        uint256 end = 1 + (7 - weekday(dayOf(y, 11, 1))) % 7;
        if (d != end) return d < end ? EDT : EST;
        return second < 6 hours ? EDT : EST;
    }

    /// @notice Returns FULL (0), EARLY (1), SHUT (2) or UNKNOWN (3) for New York day `day` since 1970-01-01.
    /// @dev Weekends are SHUT in every year. An uncovered weekday is UNKNOWN. A covered weekday the compiled or
    ///      appended calendar closes is SHUT without its mark being read; any other covered weekday is its mark when it
    ///      has one (EARLY or SHUT), else its compiled or appended kind.
    function dayKind(Extension storage x, uint256 day) internal view returns (uint256) {
        uint256 w = weekday(day);
        if (w == 0 || w == 6) return SHUT;
        if (day < EPOCH_DAY) return UNKNOWN;
        uint256 i = day - EPOCH_DAY;
        if (i >= CONSTANT_DAYS && i >= x.endDay) return UNKNOWN;
        uint256 kind = _published(x, i);
        if (kind == SHUT) return SHUT;
        uint256 marked = _markAt(x, i);
        return marked == FULL ? kind : marked;
    }

    /// @notice Appends `year` to the extension. Dates are month * 100 + day, strictly ascending weekdays.
    /// @dev Reverts unless `year` directly follows the last covered year and every date is a valid weekday.
    function append(Extension storage x, uint256 year, uint16[] calldata closed, uint16[] calldata early) internal {
        uint256 last = x.lastYear == 0 ? CONSTANT_LAST_YEAR : x.lastYear;
        if (year != last + 1 || year > type(uint16).max - 1 || closed.length > 16 || early.length > 8) {
            revert InvalidYear(year);
        }
        _mark(x.closed, year, closed);
        _mark(x.early, year, early);
        for (uint256 j; j < early.length; ++j) {
            uint256 i = _index(year, early[j]);
            if (x.closed[i >> 8] & (uint256(1) << (i & 255)) != 0) revert InvalidDate(early[j]);
        }
        x.lastYear = uint16(year);
        x.endDay = uint32(dayOf(year + 1, 1, 1) - EPOCH_DAY);
    }

    /// @notice Returns the last covered year.
    function lastYear(Extension storage x) internal view returns (uint256) {
        return x.lastYear == 0 ? CONSTANT_LAST_YEAR : x.lastYear;
    }

    /// @notice Gives weekday `monthDay` (month * 100 + day) of `year` the mark `kind`: SHUT for a full-day closure,
    ///         EARLY for a 13:00 early close, or FULL to clear its mark, so the day follows the calendar again. Returns
    ///         the day's New York day since 1970-01-01.
    /// @dev Reverts as `checkMark` does at `timestamp`. Only the day's two bits of its 128-day word change.
    function mark(Extension storage x, uint256 year, uint256 monthDay, uint256 kind, uint256 timestamp)
        internal
        returns (uint256 day)
    {
        day = checkMark(x, year, monthDay, kind, timestamp);
        uint256 i = day - EPOCH_DAY;
        uint256 shift = (i & 127) << 1;
        mapping(uint256 word => uint256) storage marks = x.marks;
        marks[i >> 7] = (marks[i >> 7] & ~(uint256(3) << shift)) | (kind << shift);
    }

    /// @notice Returns the New York day since 1970-01-01 that a mark of `kind` on weekday `monthDay` (month * 100 +
    ///         day) of `year` would take at `timestamp`; reverts unless the mark may take effect then.
    /// @dev InvalidDate unless the date is a weekday. InvalidMark with a code: 1 `kind` is none of FULL, EARLY and
    ///      SHUT; 2 the day is before 2026 or before the New York day of `timestamp`; 3 the calendar does not cover the
    ///      day (its year is not appended yet); 4 an early close on a day the compiled or appended calendar closes, which
    ///      a mark never opens.
    function checkMark(Extension storage x, uint256 year, uint256 monthDay, uint256 kind, uint256 timestamp)
        internal
        view
        returns (uint256 day)
    {
        if (kind > SHUT) revert InvalidMark(1);
        if (year < FIRST_YEAR) revert InvalidMark(2);
        day = weekdayOf(year, monthDay);
        if (day < localDay(timestamp)) revert InvalidMark(2);
        uint256 i = day - EPOCH_DAY;
        if (i >= CONSTANT_DAYS && i >= x.endDay) revert InvalidMark(3);
        if (kind == EARLY && _published(x, i) == SHUT) revert InvalidMark(4);
    }

    /// @notice Returns the mark of New York day `day` since 1970-01-01: FULL for none, EARLY or SHUT.
    function markOf(Extension storage x, uint256 day) internal view returns (uint256) {
        return day < EPOCH_DAY ? FULL : _markAt(x, day - EPOCH_DAY);
    }

    /// @notice Returns the New York day since 1970-01-01 at `timestamp`, as `session` reads it.
    function localDay(uint256 timestamp) internal pure returns (uint256) {
        uint256 offset = utcOffset(timestamp);
        return (timestamp > offset ? timestamp - offset : 0) / DAY;
    }

    /// @notice Returns the day since 1970-01-01 of weekday `monthDay` (month * 100 + day) of `year`, a year from 1970.
    /// @dev Reverts InvalidDate on an invalid date or a weekend.
    function weekdayOf(uint256 year, uint256 monthDay) internal pure returns (uint256 day) {
        uint256 m = monthDay / 100;
        uint256 d = monthDay % 100;
        if (m == 0 || m > 12 || d == 0 || d > 31) revert InvalidDate(monthDay);
        day = dayOf(year, m, d);
        (uint256 cy, uint256 cm,) = civil(day);
        uint256 w = weekday(day);
        if (cy != year || cm != m || w == 0 || w == 6) revert InvalidDate(monthDay);
    }

    /// @notice Day of week for days since 1970-01-01. 0 is Sunday.
    function weekday(uint256 day) internal pure returns (uint256) {
        return (day + 4) % 7;
    }

    /// @notice Civil date for days since 1970-01-01.
    function civil(uint256 day) internal pure returns (uint256 y, uint256 m, uint256 d) {
        unchecked {
            uint256 z = day + 719_468;
            uint256 era = z / 146_097;
            uint256 doe = z % 146_097;
            uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
            uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            uint256 mp = (5 * doy + 2) / 153;
            d = doy - (153 * mp + 2) / 5 + 1;
            m = mp < 10 ? mp + 3 : mp - 9;
            y = yoe + era * 400 + (m <= 2 ? 1 : 0);
        }
    }

    /// @notice Days since 1970-01-01 for a civil date in 1970 or later.
    function dayOf(uint256 year, uint256 month, uint256 dayOfMonth) internal pure returns (uint256) {
        unchecked {
            uint256 y = year - (month <= 2 ? 1 : 0);
            uint256 era = y / 400;
            uint256 yoe = y - era * 400;
            uint256 doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + dayOfMonth - 1;
            return era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468;
        }
    }

    error InvalidYear(uint256 year);
    error InvalidDate(uint256 monthDay);
    /// @notice A day mark that cannot take effect; `checkMark` lists the codes.
    error InvalidMark(uint256 code);

    function _mark(mapping(uint256 => uint256) storage bits, uint256 year, uint16[] calldata dates) private {
        uint256 previous;
        for (uint256 j; j < dates.length; ++j) {
            if (dates[j] <= previous) revert InvalidDate(dates[j]);
            previous = dates[j];
            uint256 i = _index(year, dates[j]);
            bits[i >> 8] |= uint256(1) << (i & 255);
        }
    }

    /// @dev Day index of a weekday date in `year`. Reverts on an invalid date or a weekend.
    function _index(uint256 year, uint256 monthDay) private pure returns (uint256) {
        return weekdayOf(year, monthDay) - EPOCH_DAY;
    }

    /// @dev The compiled or appended kind of covered day index `i`: SHUT, EARLY or FULL.
    function _published(Extension storage x, uint256 i) private view returns (uint256) {
        uint256 closedWord;
        uint256 earlyWord;
        if (i < CONSTANT_DAYS) {
            (closedWord, earlyWord) = _constant(i >> 8);
        } else {
            closedWord = x.closed[i >> 8];
            earlyWord = x.early[i >> 8];
        }
        uint256 bit = uint256(1) << (i & 255);
        if (closedWord & bit != 0) return SHUT;
        if (earlyWord & bit != 0) return EARLY;
        return FULL;
    }

    /// @dev The mark of day index `i`: its two bits of its 128-day word.
    function _markAt(Extension storage x, uint256 i) private view returns (uint256) {
        return (x.marks[i >> 7] >> ((i & 127) << 1)) & 3;
    }

    /// @dev NYSE 2026-2030 closure and early-close bits for one 256-day word.
    function _constant(uint256 word) private pure returns (uint256 closed, uint256 early) {
        if (word < 4) {
            if (word == 0) return (0x0200000000000000008002000001000000000000100000000000400000040001, 0);
            if (word == 1) {
                return (
                    0x0000000000000002000000000400000040002040000002000000000000000000,
                    0x0000000000000000000000000000000000000020000004000000000000000000
                );
            }
            if (word == 2) {
                return (
                    0x0000040000040000002000000000000000000020000000000000004000200008,
                    0x0000000000000000004000000000000000000000000000000000000000000000
                );
            }
            return (
                0x0000000000020000000000000008001000008000000000040000000000002000,
                0x0000000000000000000000000004000000000000000000000000000000000000
            );
        }
        if (word == 4) {
            return (
                0x0002000008000000000000010000000002000000004001020000000200000000,
                0x8000000000000000000000000000000000000000000000000000000400000000
            );
        }
        if (word == 5) {
            return (
                0x0000002000000200002040000000200000000000000000002000000000000001,
                0x0000000000000000000020000000400000000000000000000000000000000000
            );
        }
        if (word == 6) {
            return (
                0x0000000000000000000002000000000000002000400000800000000200000000,
                0x0000000000000000000000000000000000001000000000000000000000000000
            );
        }
        return (
            0x0000000000000000000000000000000000000000000000000000000008000001,
            0x0000000000000000000000000000000000000000000000000000000004000002
        );
    }
}
