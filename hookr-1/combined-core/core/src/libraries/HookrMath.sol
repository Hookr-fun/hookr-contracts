// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title HookrMath
/// @notice Integer floor square root, including zero and the whole uint256 domain.
library HookrMath {
    function sqrt(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) return 0;
        // A power-of-two upper estimate: 2^ceil(bitLength(x)/2). At most 2^128.
        uint256 value = x;
        uint256 log;
        if (value >> 128 != 0) {
            value >>= 128;
            log += 128;
        }
        if (value >> 64 != 0) {
            value >>= 64;
            log += 64;
        }
        if (value >> 32 != 0) {
            value >>= 32;
            log += 32;
        }
        if (value >> 16 != 0) {
            value >>= 16;
            log += 16;
        }
        if (value >> 8 != 0) {
            value >>= 8;
            log += 8;
        }
        if (value >> 4 != 0) {
            value >>= 4;
            log += 4;
        }
        if (value >> 2 != 0) {
            value >>= 2;
            log += 2;
        }
        if (value >> 1 != 0) log += 1;
        result = uint256(1) << ((log + 2) / 2);
        // The upper estimate is less than twice sqrt(x). Seven Newton steps cover its 128 result bits.
        for (uint256 i; i < 7; ++i) {
            result = (result + x / result) / 2;
        }
        uint256 lower = x / result;
        if (lower < result) result = lower;
    }
}
