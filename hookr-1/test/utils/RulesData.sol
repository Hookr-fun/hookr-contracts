// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrDynamicFee} from "../../src/libraries/HookrDynamicFee.sol";

/// @notice HookrRules' Rules data as HookrLauncher encodes it for a member with the default Rules knobs, for tests that
///         bind or open a pool directly: the config alone without dynamic fees, the config and its RulesKnobs with
///         them, and the config, its RulesKnobs and its RecaptureConfig for a recapture pool.
library RulesData {
    /// @notice The length of a recapture pool's Rules data: RulesConfig's 16 words, RulesKnobs' 6 and RecaptureConfig's
    ///         8.
    uint256 internal constant LANE_LENGTH = (16 + 6 + 8) * 32;

    /// @notice The default knobs of a pool whose minimum dynamic fee liquidity is `minLiquidity`: the default tempo
    ///         with it, all zero without it (a pool without dynamic fees), and the linear Snipe curve.
    function defaults(uint96 minLiquidity) internal pure returns (HookrTypes.RulesKnobs memory k) {
        if (minLiquidity == 0) return k;
        k.minDynamicFeeLiquidity = minLiquidity;
        k.windowSeconds = HookrTypes.DEFAULT_WINDOW_SECONDS;
        k.resetSeconds = HookrTypes.DEFAULT_RESET_SECONDS;
        k.carryBps = HookrTypes.DEFAULT_CARRY_BPS;
        k.moveTicks = HookrTypes.DEFAULT_MOVE_TICKS;
    }

    /// @notice A pool without arb recapture: `c` alone when `minLiquidity` is zero, else `c` with the default knobs.
    function encode(HookrTypes.RulesConfig memory c, uint96 minLiquidity) internal pure returns (bytes memory) {
        if (minLiquidity == 0) return abi.encode(c);
        return abi.encode(c, defaults(minLiquidity));
    }

    /// @notice The largest dynamic fee span (maxFeePips less the base fee) a pool with `sens` and `share` binds with:
    ///         the dynamic fee's reach bound (HookrDynamicFee.withinReach) within the 600,000-pip LP-fee ceiling less
    ///         `base`.
    function maxDynamicFeeSpan(uint256 sens, uint256 share, uint256 base) internal pure returns (uint256 span) {
        span = 600_000 - base;
        uint256 sens2 = sens * sens;
        if (HookrDynamicFee.MAX_REACH / sens2 < span) span = HookrDynamicFee.MAX_REACH / sens2;
        if (share != 0) {
            uint256 reserve = HookrDynamicFee.MAX_RESERVE * HookrDynamicFee.RESERVE_SCALE
                / (share * (HookrDynamicFee.RESERVE_SCALE - sens2));
            if (reserve < span) span = reserve;
        }
    }

    /// @notice Lowers `c.maxFeePips` in place, where it is above it, to `base` plus the widest span the reach bound
    ///         admits at `c`'s sensitivity and share; a config without dynamic fees is left alone.
    function clampToReach(HookrTypes.RulesConfig memory c, uint256 base) internal pure {
        if (c.dynamicFeeSens == 0) return;
        uint256 widest = base + maxDynamicFeeSpan(c.dynamicFeeSens, c.protocolShareBps, base);
        if (c.maxFeePips > widest) c.maxFeePips = uint24(widest);
    }

    /// @notice A recapture pool: `c`, the default knobs for `minLiquidity` and `rc`.
    function lane(HookrTypes.RulesConfig memory c, uint96 minLiquidity, HookrTypes.RecaptureConfig memory rc)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(c, defaults(minLiquidity), rc);
    }
}
