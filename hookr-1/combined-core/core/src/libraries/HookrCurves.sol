// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Release-identical floor rounding for Anti-Snipe and Exit Clock.
library HookrCurves {
    error InvalidCurve();

    /// @dev Native callers bound top/floor to pips or bps and horizon to their frozen timing limits.
    function rate(uint256 top, uint256 floor, uint256 horizon, uint256 age, uint8 curve)
        internal pure returns (uint256)
    {
        if (floor > top || curve > 2) revert InvalidCurve();
        if (age >= horizon) return floor;
        if (curve == 0) return floor + (top - floor) * (horizon - age) / horizon;
        uint256 n = age * 8 / horizon;
        if (curve == 2) return floor + (top - floor) * (8 - n) / 8;
        uint256 h = (top - floor) >> n;
        uint256 l = n == 7 ? 0 : h >> 1;
        return floor + l + (h - l) * (horizon - (age * 8 - n * horizon)) / horizon;
    }
}
