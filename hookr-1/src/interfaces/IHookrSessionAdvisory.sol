// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IHookrGoverned} from "./IHookrGoverned.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrMarketCalendar} from "../libraries/HookrMarketCalendar.sol";

/// @title IHookrSessionAdvisory
/// @notice Interface for HookrSessionAdvisory, the fee-only BEFORE_SWAP advisory whose LP-fee surcharge follows the US
///         equity session.
interface IHookrSessionAdvisory is IHookrGoverned {
    /// @notice Per-pool schedule, abi-encoded as the bind data. The same fields, in the same order, as
    ///         HookrSessionTiers.Tiers.
    struct Schedule {
        /// @notice The surcharge during regular hours.
        uint24 regularPips;
        /// @notice The surcharge from 04:00 to the open.
        uint24 preMarketPips;
        /// @notice The surcharge for four hours after the close.
        uint24 afterHoursPips;
        /// @notice The surcharge from the end of after-hours to 04:00 before a trading day.
        uint24 overnightPips;
        /// @notice The surcharge on weekends, closures and the evening before them.
        uint24 closedPips;
        /// @notice The seconds after the open over which the surcharge moves linearly from the pre-market to the
        ///         regular value; zero disables.
        uint16 openRampSeconds;
        /// @notice The seconds before the close over which the surcharge moves linearly from the regular to the
        ///         after-hours value; zero disables.
        uint16 closeRampSeconds;
        /// @notice UNCOVERED_AS_CLOSED, or zero.
        uint8 flags;
    }

    /// @notice Frozen pool state. One storage slot. Its first eight fields are the pool's Schedule.
    struct Bound {
        /// @notice The surcharge during regular hours.
        uint24 regularPips;
        /// @notice The surcharge from 04:00 to the open.
        uint24 preMarketPips;
        /// @notice The surcharge for four hours after the close.
        uint24 afterHoursPips;
        /// @notice The surcharge from the end of after-hours to 04:00 before a trading day.
        uint24 overnightPips;
        /// @notice The surcharge on weekends, closures and the evening before them.
        uint24 closedPips;
        /// @notice The seconds after the open over which the surcharge moves linearly from the pre-market to the
        ///         regular value; zero disables.
        uint16 openRampSeconds;
        /// @notice The seconds before the close over which the surcharge moves linearly from the regular to the
        ///         after-hours value; zero disables.
        uint16 closeRampSeconds;
        /// @notice UNCOVERED_AS_CLOSED, or zero.
        uint8 flags;
        /// @notice The largest surcharge once the Rules launch guard has ended.
        uint24 limit;
        /// @notice The largest surcharge while the Rules launch guard is active.
        uint24 guardLimit;
        /// @notice The Rules guard end, on the Rules block.number clock.
        uint40 guardEnd;
        /// @notice Whether the pool is bound.
        bool bound;
    }

    /// @notice Pool `id` is already bound by `binder`.
    error AlreadyBound(address binder, PoolId id);
    /// @notice `binder` has not bound pool `id`.
    error UnknownPool(address binder, PoolId id);
    /// @notice The schedule is malformed or breaks a bound; `code` names the failed check.
    error InvalidSchedule(uint256 code);
    /// @notice The pool's configuration cannot take this advisory; `code` names the failed check.
    error InvalidPoolConfig(uint256 code);

    /// @notice A pool was bound to a schedule.
    /// @param binder The root or pair root that bound it.
    /// @param id The pool.
    /// @param schedule The pool's schedule.
    /// @param limit The largest surcharge once the guard has ended.
    /// @param guardLimit The largest surcharge while the guard is active.
    event SessionBound(address indexed binder, PoolId indexed id, Schedule schedule, uint24 limit, uint24 guardLimit);
    /// @notice A calendar year was appended.
    /// @param year The year.
    /// @param closed The full-day closures, month * 100 + day.
    /// @param early The 13:00 early closes, month * 100 + day.
    event YearAppended(uint256 indexed year, uint16[] closed, uint16[] early);

    /// @notice Weekday `monthDay` (month * 100 + day) of `year`, New York day `day` since 1970-01-01, now carries `mark`
    ///         (MARK_NONE: its mark was cleared).
    /// @param day The New York day number since 1970-01-01.
    /// @param year The day's year.
    /// @param monthDay The day's date, month * 100 + day.
    /// @param mark The mark the day now carries.
    event SessionDayMarked(uint256 indexed day, uint16 year, uint16 monthDay, uint8 mark);

    /// @notice Returns the surcharge the pool bound by `binder` would receive at `timestamp` on the current block.
    /// @param binder The root or pair root that bound the pool.
    /// @param id The pool.
    /// @param timestamp The time to price.
    /// @return The surcharge in pips.
    function surchargeAt(address binder, PoolId id, uint256 timestamp) external view returns (uint24);

    /// @notice Returns the frozen state of a pool bound by `binder`.
    /// @param binder The root or pair root that bound the pool.
    /// @param id The pool.
    /// @return The pool's frozen state.
    function schedule(address binder, PoolId id) external view returns (Bound memory);

    /// @notice Returns the session at `timestamp`, the owner's day marks included.
    /// @param timestamp The time.
    /// @return The session.
    function sessionAt(uint256 timestamp) external view returns (HookrMarketCalendar.Session memory);

    /// @notice Returns the last calendar year with closures and early closes.
    /// @return The year.
    function lastCoveredYear() external view returns (uint256);

    /// @notice Appends the next calendar year; consumes a queued APPEND_YEAR with the exact arguments.
    /// @param year The year after the last covered year.
    /// @param closed Full-day closures on weekdays, month * 100 + day, strictly ascending.
    /// @param early 13:00 early closes on weekdays, month * 100 + day, strictly ascending, not closures.
    function appendYear(uint16 year, uint16[] calldata closed, uint16[] calldata early) external;

    /// @notice Marks a weekday closed (MARK_CLOSED) or as a 13:00 early close (MARK_EARLY_CLOSE), or clears its mark
    ///         (MARK_NONE), for every pool that reads this calendar: this advisory's pools, on HookrRoot and on pair
    ///         roots, and every session tier read through `sessionAt` (HookrFeeAdvisory's). Consumes a queued
    ///         MARK_SESSION_DAY with the exact arguments. The day must be the current New York day or later and a
    ///         weekday the calendar covers, and an early close only a day the calendar does not close: a mark never
    ///         opens a day the calendar closes, and a cleared day follows the calendar again. Executing it voids every
    ///         MARK_SESSION_DAY of the same date queued before it, so the mark in force is replaced only by a mark
    ///         queued after it took effect.
    /// @param year The day's year, from 2026.
    /// @param monthDay The day's date, month * 100 + day.
    /// @param mark MARK_NONE, MARK_EARLY_CLOSE or MARK_CLOSED.
    function markSessionDay(uint16 year, uint16 monthDay, uint8 mark) external;

    /// @notice Returns the mark of weekday `monthDay` (month * 100 + day) of `year`: MARK_NONE, MARK_EARLY_CLOSE or
    ///         MARK_CLOSED. Reverts with InvalidDate for a date that is not a weekday.
    /// @param year The day's year.
    /// @param monthDay The day's date, month * 100 + day.
    /// @return The mark.
    function sessionDayMark(uint16 year, uint16 monthDay) external view returns (uint8);
}
