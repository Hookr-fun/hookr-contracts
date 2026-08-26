// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title LeverageMath
/// @notice Pure arithmetic for Leveraged Hooks: interest accrual, borrow pricing, position
///         health, credit capacity and LP share conversion.
///
///         Kept free of storage and of any Uniswap type on purpose. Every rule in the
///         published design that can be stated as arithmetic lives here, where it can be
///         fuzzed directly instead of only through a pool.
///
///         Two conventions hold throughout, and the tests pin both:
///
///         1. ROUNDING FAVOURS THE MARKET. Debt owed rounds up, shares minted round down,
///            value credited rounds down. A rounding rule that favours the individual is a
///            slow leak out of the LP balance sheet, paid by whoever withdraws last.
///         Products go through v4-core's FullMath rather than `a * b / c`. A fuzz run found
///         the naive form overflowing on a market whose share supply had drifted far from its
///         equity — an arithmetic revert exactly when an LP is trying to leave.
///
///         2. CAPACITY IS A MINIMUM, NEVER A SUM. `creditCapacity` takes the most
///            conservative of its terms, so no term — bonded $HOOKR least of all — can lift
///            a ceiling above what the liquidity actually supports.
library LeverageMath {
    /// @dev 1.0 in 18-decimal fixed point.
    uint256 internal constant WAD = 1e18;
    /// @dev 100% in basis points.
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    error ZeroDebt();
    error BadThreshold();
    error BadKink();

    // ------------------------------------------------------------------ interest

    /// @notice Advances a borrow index forward by `dt` seconds at `ratePerYearWad`.
    /// @dev Linear (simple) accrual within a step rather than continuous compounding. Every
    ///      touch of the market re-accrues, so the step is normally small and the difference
    ///      is dust — and a closed form nobody can reproduce by hand is worse than a slightly
    ///      conservative one they can. Rounds the index UP so debt never drifts down.
    function accrueIndex(uint256 index, uint256 ratePerYearWad, uint256 dt) internal pure returns (uint256) {
        if (dt == 0 || ratePerYearWad == 0) return index;
        uint256 growth = (ratePerYearWad * dt) / SECONDS_PER_YEAR;
        return index + FullMath.mulDivRoundingUp(index, growth, WAD);
    }

    /// @notice What a principal booked at `indexAtOpen` owes once the index reaches `index`.
    /// @dev Rounds up: the market is owed the remainder, not the borrower.
    function debtOwed(uint256 principal, uint256 indexAtOpen, uint256 index) internal pure returns (uint256) {
        if (principal == 0) return 0;
        if (indexAtOpen == 0) revert ZeroDebt();
        return FullMath.mulDivRoundingUp(principal, index, indexAtOpen);
    }

    // ------------------------------------------------------------------ borrow pricing

    /// @notice Two-slope borrow rate. Cheap below the kink, punitive above it.
    /// @dev The shape is the design's "as utilisation climbs, borrowing gets more expensive,
    ///      and past a threshold new leverage is refused outright" — this function prices the
    ///      first half; the refusal is a policy check, not arithmetic.
    /// @param utilisation borrowed / (borrowed + idle), in WAD.
    /// @param kinkWad utilisation at which the steep slope begins.
    function borrowRatePerYearWad(
        uint256 utilisation,
        uint256 kinkWad,
        uint256 baseRateWad,
        uint256 slope1Wad,
        uint256 slope2Wad
    ) internal pure returns (uint256) {
        if (kinkWad == 0 || kinkWad >= WAD) revert BadKink();
        if (utilisation <= kinkWad) {
            return baseRateWad + (slope1Wad * utilisation) / kinkWad;
        }
        uint256 excess = utilisation - kinkWad;
        uint256 denom = WAD - kinkWad;
        // Utilisation can exceed WAD only if bad debt has been written down; clamp so the
        // rate stays defined rather than overflowing into nonsense.
        if (excess > denom) excess = denom;
        return baseRateWad + slope1Wad + (slope2Wad * excess) / denom;
    }

    /// @notice borrowed / (borrowed + idle), in WAD. Zero when nothing is lent.
    function utilisationWad(uint256 borrowed, uint256 idle) internal pure returns (uint256) {
        uint256 total = borrowed + idle;
        if (total == 0) return 0;
        return (borrowed * WAD) / total;
    }

    // ------------------------------------------------------------------ position health

    /// @notice Health in WAD: 1e18 is exactly at the liquidation threshold.
    /// @dev Collateral is discounted by the threshold BEFORE the comparison, so "health" is
    ///      measured against the point a liquidator may act rather than against insolvency.
    ///      Liquidation therefore begins while the position is still over-collateralised —
    ///      the room the design reserves for exit fees, incentive, impact and interest.
    function healthFactorWad(uint256 collateralValueQuote, uint256 debtQuote, uint256 thresholdBps)
        internal
        pure
        returns (uint256)
    {
        if (thresholdBps == 0 || thresholdBps > BPS) revert BadThreshold();
        if (debtQuote == 0) return type(uint256).max;
        uint256 adjusted = FullMath.mulDiv(collateralValueQuote, thresholdBps, BPS);
        return FullMath.mulDiv(adjusted, WAD, debtQuote);
    }

    /// @notice The collateral price at which health reaches exactly 1.
    /// @dev Quote per whole token, in WAD. Rounds UP: quoting a liquidation price below the
    ///      true one would tell a trader they have more room than they do.
    function liquidationPriceWad(uint256 debtQuote, uint256 collateralTokens, uint256 thresholdBps)
        internal
        pure
        returns (uint256)
    {
        if (thresholdBps == 0 || thresholdBps > BPS) revert BadThreshold();
        if (collateralTokens == 0) return type(uint256).max;
        // price = debt * BPS * WAD / (collateral * threshold), in two full-precision steps
        // so neither product has to fit in 256 bits on its own.
        uint256 numerator = FullMath.mulDivRoundingUp(debtQuote, BPS * WAD, thresholdBps);
        return FullMath.mulDivRoundingUp(numerator, 1, collateralTokens);
    }

    /// @notice Borrowable quote for `equity` at `leverageWad` total exposure.
    /// @dev 2x on 2 ETH of equity borrows 2 ETH. Rounds DOWN so a rounding step can never
    ///      hand out more credit than the requested leverage implies.
    function borrowForEquity(uint256 equityQuote, uint256 leverageWad) internal pure returns (uint256) {
        if (leverageWad <= WAD) return 0;
        return (equityQuote * (leverageWad - WAD)) / WAD;
    }

    // ------------------------------------------------------------------ credit capacity

    /// @notice The most conservative of the ceiling's terms.
    /// @dev The load-bearing rule of the whole token design. Terms combine as a minimum, so
    ///      bonded $HOOKR can bind a market's ceiling and can never raise it past what the
    ///      liquidity and the executable liquidation depth already allow.
    function creditCapacity(
        uint256 liquidityTerm,
        uint256 liquidationDepthTerm,
        uint256 hookrBondTerm,
        uint256 protocolLimitTerm
    ) internal pure returns (uint256 capacity) {
        capacity = liquidityTerm;
        if (liquidationDepthTerm < capacity) capacity = liquidationDepthTerm;
        if (hookrBondTerm < capacity) capacity = hookrBondTerm;
        if (protocolLimitTerm < capacity) capacity = protocolLimitTerm;
    }

    /// @notice Scales a capacity term down as conditions worsen.
    /// @dev Volatility, utilisation and oracle quality are not separate caps in the design —
    ///      they tighten the terms the minimum is taken over. `hairCutBps` of 0 leaves a term
    ///      untouched; 10_000 removes it entirely.
    function haircut(uint256 term, uint256 hairCutBps) internal pure returns (uint256) {
        if (hairCutBps >= BPS) return 0;
        return (term * (BPS - hairCutBps)) / BPS;
    }

    /// @notice Credit still available under a ceiling, saturating at zero.
    /// @dev Outstanding can exceed capacity after the ceiling contracts — falling liquidity
    ///      shrinks the cap under loans already written. That is a real state, not an error:
    ///      it means no new credit, not that existing credit is void.
    function availableCredit(uint256 capacity, uint256 outstanding) internal pure returns (uint256) {
        return capacity > outstanding ? capacity - outstanding : 0;
    }

    // ------------------------------------------------------------------ LP shares

    /// @notice Net asset value of the market, with collateral deliberately excluded.
    /// @dev The double-count the design exists to rule out: a borrower's locked collateral and
    ///      the receivable secured by it are two sides of ONE position. Counting both would
    ///      inflate the market by the size of its own lending book. Only the receivable is an
    ///      LP asset, and it is carried at the lower of face and recoverable value by the
    ///      caller before it reaches here.
    function marketEquity(uint256 idleQuote, uint256 inventoryValueQuote, uint256 performingReceivable, uint256 badDebt)
        internal
        pure
        returns (uint256)
    {
        uint256 assets = idleQuote + inventoryValueQuote + performingReceivable;
        return assets > badDebt ? assets - badDebt : 0;
    }

    /// @dev Virtual offset, in the spirit of ERC-4626's decimal offset. The first depositor of
    ///      an empty market cannot mint one wei-share and then donate to inflate its price,
    ///      because every conversion is done against (supply + OFFSET) and (equity + 1).
    uint256 internal constant VIRTUAL_SHARES = 1e3;

    /// @notice Shares minted for a deposit. Rounds DOWN — the market keeps the remainder.
    function sharesForDeposit(uint256 depositQuote, uint256 totalShares, uint256 equityQuote)
        internal
        pure
        returns (uint256)
    {
        return FullMath.mulDiv(depositQuote, totalShares + VIRTUAL_SHARES, equityQuote + 1);
    }

    /// @notice Quote redeemable for shares. Rounds DOWN — the market keeps the remainder.
    function quoteForShares(uint256 shares, uint256 totalShares, uint256 equityQuote) internal pure returns (uint256) {
        return FullMath.mulDiv(shares, equityQuote + 1, totalShares + VIRTUAL_SHARES);
    }

    /// @notice The exit fee a withdrawal pays, rising with utilisation.
    /// @dev Not a punishment: an LP leaving a heavily borrowed market takes liquidity the
    ///      remaining LPs need to stand behind loans they now carry a larger share of. The
    ///      fee stays in the market, so it accrues to exactly those LPs.
    function exitFeeBps(uint256 utilisation, uint256 kinkWad, uint256 maxFeeBps) internal pure returns (uint256) {
        if (utilisation <= kinkWad) return 0;
        uint256 denom = WAD - kinkWad;
        if (denom == 0) return maxFeeBps;
        uint256 excess = utilisation - kinkWad;
        if (excess > denom) excess = denom;
        return (maxFeeBps * excess) / denom;
    }

    /// @notice How much of a redemption the market can settle in cash right now.
    /// @dev The rule the design will not bend: a withdrawal may never take the liquid quote
    ///      asset that outstanding loans are standing on. Whatever is not immediately payable
    ///      is the caller's problem to queue — this function only refuses to overdraw.
    function serviceableWithdrawal(uint256 requestedQuote, uint256 idleQuote, uint256 reservedQuote)
        internal
        pure
        returns (uint256)
    {
        uint256 free = idleQuote > reservedQuote ? idleQuote - reservedQuote : 0;
        return requestedQuote < free ? requestedQuote : free;
    }
}
