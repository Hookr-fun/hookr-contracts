// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title Hookr share math
/// @notice The proportional deposit rule of a compounder: a depositor contributes the vault's own mix of revenue
///         tokens and quote, so no price is ever read to value a share. Used by the compounder and by the lens.
library HookrShareMath {
    /// @notice The shares `tokensMax` and `quoteMax` buy against `supply` shares over `totalTokens` and `totalQuote`,
    ///         and what they take: `min(tokensMax x supply / totalTokens, quoteMax x supply / totalQuote)` shares,
    ///         each side's amount `shares x total / supply` rounded up, which never exceeds its maximum. The first
    ///         deposit, and a deposit into a vault that holds nothing, takes `tokensMax` for as many shares. Zero
    ///         shares when nothing fits.
    function sharesFor(uint256 supply, uint256 totalTokens, uint256 totalQuote, uint256 tokensMax, uint256 quoteMax)
        internal
        pure
        returns (uint256 shares, uint256 tokens, uint256 quote)
    {
        if (supply == 0 || (totalTokens == 0 && totalQuote == 0)) return (tokensMax, tokensMax, 0);
        shares = type(uint256).max;
        if (totalTokens != 0) shares = FullMath.mulDiv(tokensMax, supply, totalTokens);
        if (totalQuote != 0) {
            uint256 byQuote = FullMath.mulDiv(quoteMax, supply, totalQuote);
            if (byQuote < shares) shares = byQuote;
        }
        if (shares == 0) return (0, 0, 0);
        // shares <= max x supply / total on each side, so each amount, rounded up, is at most its maximum.
        tokens = FullMath.mulDivRoundingUp(shares, totalTokens, supply);
        quote = FullMath.mulDivRoundingUp(shares, totalQuote, supply);
    }
}
