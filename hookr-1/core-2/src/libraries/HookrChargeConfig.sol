// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice C4's owned-field validation and conservative Bound. Whole-carrier canonicality belongs to C2.
/// @dev Separating these checks avoids embedding the other modules' codec validation in this runtime.
library HookrChargeConfig {
    error CoreBlocksConfig();
    function validateAndBound(uint32 hot, uint128 cold, uint16 share, bool lane) internal pure returns (uint256) {
        if (share == 0 || share > 5_000) revert CoreBlocksConfig();
        uint256 b;
        uint256 buy = hot & 127;
        uint256 sell = (hot >> 7) & 127;
        uint8 cutTo = uint8((hot >> 14) & 7);
        uint8 sellTo = uint8((hot >> 24) & 7);
        if (buy > 100 || sell > 100 || (buy | sell == 0 ? cutTo != 0 : cutTo == 0 || cutTo > 4)) revert CoreBlocksConfig();
        if (sellTo != 0 && (buy == 0 || sell == 0 || sellTo > 4 || sellTo == cutTo)) revert CoreBlocksConfig();
        if (buy != 0) b = _buy(b, uint24(buy * 1_000), cutTo, uint24(buy * 1_000), share);
        if (sell != 0) b = _sell(b, uint24(sell * 1_000), sellTo == 0 ? cutTo : sellTo, share);
        bool on;
        if (hot & (1 << 20) != 0) {
            on = true;
            uint256 top = (cold >> 19) & 127;
            uint256 floor = (cold >> 26) & 127;
            uint256 horizon = (cold >> 33) & 63;
            uint8 out = uint8((cold >> 42) & 7);
            if (top == 0 || top > 100 || floor >= top || ((cold >> 39) & 1 == 0 ? horizon == 0 : horizon < 3 || horizon > 30)
                || (cold >> 40) & 3 > 2 || out > 4 || (out == 0 && top * share < 10)) revert CoreBlocksConfig();
            b = _sell(b, uint24(top * 1_000), out, share);
        } else if ((uint256(cold) >> 19) & ((1 << 26) - 1) != 0) revert CoreBlocksConfig();
        if (hot & (1 << 21) != 0) {
            on = true;
            uint256 cap = (cold >> 46) & 63;
            uint256 bounty = (cold >> 58) & 31;
            if (cap == 0 || cap > (lane ? 14 : 56) || (cold >> 52) & 31 > 20 || bounty == 0 || bounty > 20) revert CoreBlocksConfig();
        } else if ((uint256(cold) >> 45) & ((1 << 18) - 1) != 0) revert CoreBlocksConfig();
        if (hot & (1 << 22) != 0) {
            on = true;
            uint256 ceiling = (cold >> 63) & 255;
            uint256 floor = (cold >> 71) & 255;
            uint8 out = uint8((cold >> 82) & 7);
            // Only the reviewed W1 tempo ships until named-pool calibration supports another preset.
            if (ceiling == 0 || ceiling > 200 || floor > ceiling || (cold >> 79) & 7 != 0
                || out > 4 || (out == 0 && ceiling * 500 * share < 10_000)) revert CoreBlocksConfig();
            // A non-LP outflow never clips. LP-outflow minima need the aggregate gross LP-room proof.
            b = _buy(b, uint24(ceiling * 500), out, out == 0 ? 0 : uint24(floor * 500), share);
            b = _sell(b, uint24(ceiling * 500), out, share);
        } else if ((uint256(cold) >> 63) & ((1 << 22) - 1) != 0) revert CoreBlocksConfig();
        if (hot & (1 << 17) != 0) {
            on = true;
            uint256 maximum = (cold >> 116) & 15;
            uint8 out = uint8((cold >> 120) & 7);
            // Never the LP fee (an in-range provider collects it back) and never the liquidity owner (a creator who
            // sandwiches its own pool would be paid its own charge; audit 10-31, 1.3): the holder pot, the crown or a
            // named payee.
            if (maximum < 5 || maximum > 15 || out < 2 || out > 4) revert CoreBlocksConfig();
            b = _buy(b, uint24(maximum * 10_000), out, 0, share);
            b = _sell(b, uint24(maximum * 10_000), out, share);
        } else if ((uint256(cold) >> 114) & 511 != 0) revert CoreBlocksConfig();
        if (!on && (buy | sell) == 0) revert CoreBlocksConfig();
        return b;
    }
    function _buy(uint256 b, uint24 gross, uint8 out, uint24 minimum, uint16 share) private pure returns (uint256) {
        (uint24 lp, uint24 take) = _maximum(gross, out, share);
        // Validated maxima total <=350000 buy/450000 sell pips, far below uint24.max; minima <=200000.
        unchecked {
            b += uint256(lp) + (uint256(take) << 24) + (uint256(minimum) << (out == 3 ? 96 : 120));
        }
        return b | uint256(1 << out) << 144;
    }
    function _sell(uint256 b, uint24 gross, uint8 out, uint16 share) private pure returns (uint256) {
        (uint24 lp, uint24 take) = _maximum(gross, out, share);
        unchecked { b += (uint256(lp) << 48) + (uint256(take) << 72); }
        return b | uint256(1 << out) << 152;
    }
    function _maximum(uint24 gross, uint8 out, uint16 share) private pure returns (uint24 lp, uint24 take) {
        if (out != 0) return (0, gross);
        take = uint24(uint256(gross) * share / 10_000);
        unchecked { lp = gross - take; } // share<=5000 ensures take<=gross.
    }
}
