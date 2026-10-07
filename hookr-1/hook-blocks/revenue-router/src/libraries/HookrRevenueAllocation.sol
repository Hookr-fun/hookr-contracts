// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HookrRevenueTypes} from "../interfaces/HookrRevenueTypes.sol";

/// @title Hookr revenue allocation
/// @notice Cumulative, house-monotone apportionment of a lifetime revenue total among fixed basis-point weights.
/// @dev Jefferson / D'Hondt highest averages, with an exact tie going to the later index. Ported with the same
///      semantics from `_cumulativeTargets` of the live release's reviewed revenue router (hookr-org main,
///      `contracts/src`). Properties the Revenue Router relies on, each proved in the fuzz suite:
///      1. Conservation: the targets of `total` sum to exactly `total`; no wei is left unallocated.
///      2. Lower quota and bounded bias: each target is at least floor(total * w / BPS). Highest averages
///         favours larger weights on the fewer-than-n leftover units, so a target can exceed its exact quota,
///         but by less than n - 1 units (n <= 8): at most seven wei over the split's whole lifetime per
///         currency, fixed by the lifetime total and not steerable by how deposits are fragmented.
///      3. House monotonicity: raising `total` never lowers any target. A split therefore credits
///         `target(new lifetime) - target(old lifetime)` per deposit and never needs a clawback.
///      4. Path independence: because credits are differences of one cumulative function, the final credit of
///         every payee depends only on the lifetime total, never on how deposits were fragmented or ordered.
///      Proof sketch of (3): the sequential highest-averages order over all (payee, seat) pairs is a strict total
///      order, so the Jefferson result for h units is the top-h prefix of that order. It satisfies lower quota,
///      so starting from floor quotas and adding the fewer-than-n remaining units greedily reaches the same
///      prefix, and a longer prefix contains a shorter one.
library HookrRevenueAllocation {
    /// @notice Thrown if an internal accounting bound fails. Unreachable for weights that sum to BPS.
    error AllocationInvariant();

    /// @notice Returns each weight's cumulative target for a lifetime total.
    /// @param weights Positive basis-point weights summing to exactly BPS, in configured order.
    /// @param total Lifetime amount to apportion, in raw currency units.
    /// @return out Cumulative credit per weight; the entries sum to `total`.
    function targets(uint256[] memory weights, uint256 total) internal pure returns (uint256[] memory out) {
        uint256 count = weights.length;
        out = new uint256[](count);
        uint256 allocated;
        for (uint256 i; i < count; ++i) {
            uint256 quota = Math.mulDiv(total, weights[i], HookrRevenueTypes.BPS);
            out[i] = quota;
            allocated += quota;
        }
        // Each floor loses less than one unit and the exact quotas sum to `total`, so fewer than `count` remain.
        uint256 remaining = total - allocated;
        if (remaining != 0 && remaining >= count) revert AllocationInvariant();
        while (remaining != 0) {
            uint256 best;
            for (uint256 i = 1; i < count; ++i) {
                if (_before(weights[i], out[i] + 1, i, weights[best], out[best] + 1, best)) best = i;
            }
            out[best] += 1;
            unchecked {
                --remaining;
            }
        }
    }

    /// @dev True when candidate's next average w_c / d_c beats current's w_b / d_b, compared without division in
    ///      512 bits; an exact tie goes to the later configured index.
    function _before(uint256 wC, uint256 dC, uint256 iC, uint256 wB, uint256 dB, uint256 iB)
        private
        pure
        returns (bool)
    {
        (uint256 cHigh, uint256 cLow) = _mul512(wC, dB);
        (uint256 bHigh, uint256 bLow) = _mul512(wB, dC);
        if (cHigh != bHigh) return cHigh > bHigh;
        if (cLow != bLow) return cLow > bLow;
        return iC > iB;
    }

    function _mul512(uint256 a, uint256 b) private pure returns (uint256 high, uint256 low) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            low := mul(a, b)
            high := sub(sub(mm, low), lt(mm, low))
        }
    }
}
