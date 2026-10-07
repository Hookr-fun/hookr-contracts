// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ModuleMarketTypes} from "../interfaces/ModuleMarketTypes.sol";

/// @title Module marketplace math
/// @notice The bond ladder, the revenue-split bounds and the split arithmetic, as pure functions.
/// @dev Mirrors `src/lib/module-market.ts` (RISK_TIERS, REPUTATION_BANDS, requiredBond, REVENUE_ROUTES):
///      the tier SCALES the reputation ladder rather than clipping it, so every rung stays distinct and a
///      credit module's best case is still 75% of its floor. All numbers are opening values for review.
library ModuleMarketMath {
    uint256 internal constant BPS = 10_000;
    /// @notice The relief the longest record earns before a tier scales it (the TRUSTED band).
    uint256 internal constant TOP_BAND_DISCOUNT_BPS = 5_000;

    uint16 internal constant DEVELOPER_MIN_BPS = 2_000;
    uint16 internal constant DEVELOPER_MAX_BPS = 6_000;
    uint16 internal constant BACKERS_MIN_BPS = 1_000;
    uint16 internal constant BACKERS_MAX_BPS = 4_000;
    uint16 internal constant BACKERS_DEFAULT_BPS = 2_500;
    /// @dev The protocol's share of every usage fee is a market knob frozen at construction and stamped into each
    ///      version at publish. Its floor is the Hookr genesis protocol-share floor (20%); the owner picks the rate
    ///      above it. The app's design table opened at 15%.
    uint16 internal constant PROTOCOL_MIN_BPS = 2_000;
    uint16 internal constant PROTOCOL_MAX_BPS = 4_000;
    uint16 internal constant PROTOCOL_DEFAULT_BPS = 2_000;
    /// @dev The slash-compensation reserve's share, a market knob frozen at construction like the protocol share.
    uint16 internal constant RESERVE_MIN_BPS = 500;
    uint16 internal constant RESERVE_MAX_BPS = 2_000;
    uint16 internal constant RESERVE_DEFAULT_BPS = 1_000;

    uint24 internal constant MAX_LP_FEE_PIPS = 600_000;
    uint24 internal constant PIPS = 1_000_000;

    /// @notice The lowest tier a version may be published at, whatever its manifest declares. Anything that can
    ///         charge or refuse is PARAMS, and every phase-one advisory can refuse a swap: a strict advisory's reject
    ///         refuses it, a fail-open advisory's reject reverts it, and no admission or manifest shape prevents
    ///         either. READ, which needs no bond, is kept for a slot that cannot refuse.
    ModuleMarketTypes.RiskTier internal constant MIN_TIER = ModuleMarketTypes.RiskTier.PARAMS;

    error SplitOutOfBounds(uint8 route, uint16 bps);
    error SplitTotal(uint256 total);
    error InvalidManifest();

    /// @notice A tier's opening bond floor in whole bond tokens: 0, 25,000, 100,000, 250,000.
    function floorWhole(ModuleMarketTypes.RiskTier tier) internal pure returns (uint256) {
        if (tier == ModuleMarketTypes.RiskTier.READ) return 0;
        if (tier == ModuleMarketTypes.RiskTier.PARAMS) return 25_000;
        if (tier == ModuleMarketTypes.RiskTier.ASSETS) return 100_000;
        return 250_000;
    }

    /// @notice The most a track record may take off a tier's floor: 50% for tiers 0-2, 25% for credit.
    function maxDiscountBps(ModuleMarketTypes.RiskTier tier) internal pure returns (uint256) {
        return tier == ModuleMarketTypes.RiskTier.CREDIT ? 2_500 : 5_000;
    }

    /// @notice Nominal band relief before tier scaling: 0%, 25%, 50%.
    function bandDiscountBps(ModuleMarketTypes.Band band) internal pure returns (uint256) {
        if (band == ModuleMarketTypes.Band.NEW) return 0;
        if (band == ModuleMarketTypes.Band.ESTABLISHED) return 2_500;
        return 5_000;
    }

    /// @notice The relief a band earns in a tier: (band / top band) * tier maximum, in basis points.
    function reliefBps(ModuleMarketTypes.RiskTier tier, ModuleMarketTypes.Band band) internal pure returns (uint256) {
        return bandDiscountBps(band) * maxDiscountBps(tier) / TOP_BAND_DISCOUNT_BPS;
    }

    /// @notice What a publisher in `band` must have bonded behind a version of `tier`, in raw token units.
    /// @dev Rounded up, so the requirement is never below the ladder. There is no path to zero for a tier
    ///      with a non-zero floor: relief is at most 50%. Credit: 250,000 / 218,750 / 187,500 whole tokens.
    function requiredBond(ModuleMarketTypes.RiskTier tier, ModuleMarketTypes.Band band, uint256 unit)
        internal
        pure
        returns (uint256)
    {
        uint256 gross = floorWhole(tier) * unit * (BPS - reliefBps(tier, band));
        return (gross + BPS - 1) / BPS;
    }

    /// @notice Reverts unless the manifest is structurally valid for a phase-one advisory.
    function checkManifest(ModuleMarketTypes.Manifest memory m) internal pure {
        if (
            m.phaseMask == 0 || m.phaseMask & ~uint8(3) != 0 || m.maxLpFeeSurchargePips > MAX_LP_FEE_PIPS
                || m.maxQuoteTakePips >= PIPS
        ) revert InvalidManifest();
    }

    /// @notice Reverts unless `protocolBps` and `reserveBps` sit inside their bounds and leave the developer and
    ///         backers a remainder that some in-bounds developer/backers pair can fill exactly.
    function checkShares(uint16 protocolBps, uint16 reserveBps) internal pure {
        if (protocolBps < PROTOCOL_MIN_BPS || protocolBps > PROTOCOL_MAX_BPS) revert SplitOutOfBounds(2, protocolBps);
        if (reserveBps < RESERVE_MIN_BPS || reserveBps > RESERVE_MAX_BPS) revert SplitOutOfBounds(3, reserveBps);
        uint256 rest = BPS - protocolBps - reserveBps;
        if (rest < uint256(DEVELOPER_MIN_BPS) + BACKERS_MIN_BPS || rest > uint256(DEVELOPER_MAX_BPS) + BACKERS_MAX_BPS)
        {
            revert SplitTotal(uint256(protocolBps) + reserveBps);
        }
    }

    /// @notice The developer share a publisher can actually reach once the market's protocol and reserve shares are
    ///         fixed: the developer bounds intersected with what the backers bounds leave.
    function developerRange(uint16 protocolBps, uint16 reserveBps) internal pure returns (uint16 min, uint16 max) {
        uint256 rest = BPS - protocolBps - reserveBps;
        uint256 lo = rest > BACKERS_MAX_BPS ? rest - BACKERS_MAX_BPS : 0;
        uint256 hi = rest - BACKERS_MIN_BPS;
        min = uint16(lo > DEVELOPER_MIN_BPS ? lo : DEVELOPER_MIN_BPS);
        max = uint16(hi < DEVELOPER_MAX_BPS ? hi : DEVELOPER_MAX_BPS);
    }

    /// @notice The split the publish flow pre-fills: the market's protocol and reserve shares, backers at their
    ///         default clamped into reach, and the developer taking the remainder.
    function defaultSplit(uint16 protocolBps, uint16 reserveBps)
        internal
        pure
        returns (ModuleMarketTypes.Split memory s)
    {
        uint256 rest = BPS - protocolBps - reserveBps;
        (uint16 devMin, uint16 devMax) = developerRange(protocolBps, reserveBps);
        uint256 backers = BACKERS_DEFAULT_BPS;
        if (rest - backers < devMin) backers = rest - devMin;
        if (rest - backers > devMax) backers = rest - devMax;
        s = ModuleMarketTypes.Split({
            developerBps: uint16(rest - backers),
            backersBps: uint16(backers),
            protocolBps: protocolBps,
            reserveBps: reserveBps
        });
    }

    /// @notice Reverts with the first out-of-bounds route (0 developer, 1 backers, 2 protocol, 3 reserve) or
    ///         with the total when the shares do not sum to 100%. The protocol and reserve shares must equal the
    ///         market's frozen rates.
    function checkSplit(ModuleMarketTypes.Split memory s, uint16 protocolBps, uint16 reserveBps) internal pure {
        if (s.developerBps < DEVELOPER_MIN_BPS || s.developerBps > DEVELOPER_MAX_BPS) {
            revert SplitOutOfBounds(0, s.developerBps);
        }
        if (s.backersBps < BACKERS_MIN_BPS || s.backersBps > BACKERS_MAX_BPS) {
            revert SplitOutOfBounds(1, s.backersBps);
        }
        if (s.protocolBps != protocolBps) revert SplitOutOfBounds(2, s.protocolBps);
        if (s.reserveBps != reserveBps) revert SplitOutOfBounds(3, s.reserveBps);
        uint256 total = uint256(s.developerBps) + s.backersBps + s.protocolBps + s.reserveBps;
        if (total != BPS) revert SplitTotal(total);
    }

    /// @notice Splits `amount` exactly: each route is floored and the reserve takes the remainder, so the four
    ///         parts always sum to `amount` and rounding can only ever favour the reserve.
    function splitAmounts(uint256 amount, ModuleMarketTypes.Split memory s)
        internal
        pure
        returns (uint256 developer, uint256 backers, uint256 protocol, uint256 reserve)
    {
        developer = amount * s.developerBps / BPS;
        backers = amount * s.backersBps / BPS;
        protocol = amount * s.protocolBps / BPS;
        reserve = amount - developer - backers - protocol;
    }
}
