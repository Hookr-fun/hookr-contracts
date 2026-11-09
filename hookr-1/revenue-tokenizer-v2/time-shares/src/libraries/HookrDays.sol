// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title Hookr day grid
/// @notice The fixed daily grid every time share sits on: UTC days counted from the Unix epoch, so day `d` runs from
///         `d x 86,400` to `(d + 1) x 86,400` seconds, end excluded. The same arithmetic everywhere, so a day never
///         means two things.
library HookrDays {
    /// @notice Seconds in one day.
    uint256 internal constant DAY = 1 days;

    /// @notice The day `timestamp` falls in.
    function dayOf(uint256 timestamp) internal pure returns (uint256) {
        return timestamp / DAY;
    }

    /// @notice The first second of day `day`.
    function startOf(uint256 day) internal pure returns (uint256) {
        return day * DAY;
    }

    /// @notice The first second after day `day`: the start of the next one.
    function endOf(uint256 day) internal pure returns (uint256) {
        return (day + 1) * DAY;
    }
}
