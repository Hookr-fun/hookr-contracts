// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title LeverageBookLib
/// @notice The credit book's bucket key format, and nothing else.
///
///         Extracted because the format now has TWO readers. `LeverageMarket` files positions
///         into buckets and reads them back as sums to mark itself; `LeverageHook` reads the
///         same buckets back as an ORDER — which position the next incoming sell reaches first
///         — to decide who is ahead of that sell in the queue. Two contracts encoding the same
///         layout privately is how a book gets written in one shape and read in another, and
///         the failure would be silent in the worst possible place: the hook would walk the
///         wrong buckets and either liquidate nobody or reach for positions the price has not
///         come near.
///
///         `internal` throughout, so it inlines into both and costs a link step in neither —
///         the same convention `LeverageMath` and `LeverageOracleLib` already follow.
library LeverageBookLib {
    /// @dev 16 buckets per octave.
    uint256 internal constant MANT = 4;
    uint256 internal constant EMAX = 250;
    /// @dev Everything at or past the top octave, plus collateral too small to register after
    ///      the threshold discount — a bucket whose members recover nothing.
    uint256 internal constant TAIL = (EMAX << MANT) | 15;

    function msb(uint256 x) internal pure returns (uint256 r) {
        unchecked {
            if (x >= 1 << 128) {
                x >>= 128;
                r += 128;
            }
            if (x >= 1 << 64) {
                x >>= 64;
                r += 64;
            }
            if (x >= 1 << 32) {
                x >>= 32;
                r += 32;
            }
            if (x >= 1 << 16) {
                x >>= 16;
                r += 16;
            }
            if (x >= 1 << 8) {
                x >>= 8;
                r += 8;
            }
            if (x >= 1 << 4) {
                x >>= 4;
                r += 4;
            }
            if (x >= 1 << 2) {
                x >>= 2;
                r += 2;
            }
            if (x >= 1 << 1) r += 1;
        }
    }

    /// @dev Bucket index for a normalised liquidation price: octave in the high bits, the four
    ///      leading mantissa bits below it.
    function key(uint256 q) internal pure returns (uint256) {
        uint256 e = msb(q);
        if (e >= EMAX) return TAIL;
        // Below 2**MANT the mantissa has no bits to read, so the octave is one whole bucket.
        // It MUST keep its own octave index: the read skips octaves below the price's, so
        // collapsing these into octave 0 dropped live shortfall for 1 <= price < 2**MANT and
        // the mark OVERSTATED — the exact error being fixed, reintroduced. Caught by fuzzing.
        if (e < MANT) return e << MANT;
        return (e << MANT) | ((q >> (e - MANT)) & 15);
    }

    function bounds(uint256 idx) internal pure returns (uint256 lo, uint256 hi) {
        if (idx == TAIL) return (type(uint256).max, type(uint256).max);
        uint256 e = idx >> MANT;
        uint256 m = idx & 15;
        if (e < MANT) return (e == 0 ? 0 : uint256(1) << e, uint256(1) << (e + 1));
        // Exact, with no truncation, because e >= MANT.
        lo = (16 + m) << (e - MANT);
        hi = (17 + m) << (e - MANT);
    }
}
