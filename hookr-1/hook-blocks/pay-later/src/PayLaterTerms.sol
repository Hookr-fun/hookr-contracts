// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title Pay Later terms
/// @notice The immutable economic terms of one Pay Later vault and the hard bounds every vault enforces.
/// @dev Amounts in `units` are raw subject-token units; `minPremium` is raw quote units. Block counts use the
///      contract's `block.number`: on Robinhood Chain (Arbitrum Nitro) that is the parent-chain (L1) height, about
///      12 seconds per block, while on a local anvil fork it is the L2 height. Every window here is relative, so the
///      same terms read the same way on both clocks; only their wall-clock length changes.
library PayLaterTerms {
    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;
    /// @notice Largest token amount any term may name (keeps every product inside 256 bits).
    uint256 internal constant HARD_MAX_UNITS = 1e36;
    /// @notice Lowest premium, in basis points of the strike.
    uint16 internal constant MIN_PREMIUM_BPS = 100;
    /// @notice Highest premium, in basis points of the strike.
    uint16 internal constant MAX_PREMIUM_BPS = 5_000;
    /// @notice Highest strike markup over the reference price, in basis points.
    uint16 internal constant MAX_MARKUP_BPS = 5_000;
    /// @notice Shortest tenor in seconds.
    uint32 internal constant MIN_TENOR = 5 minutes;
    /// @notice Longest tenor in seconds.
    uint32 internal constant MAX_TENOR = 7 days;
    /// @notice Longest price window, in blocks of the contract clock.
    uint16 internal constant MAX_WINDOW_BLOCKS = 64;
    /// @notice Largest share of the founding band's virtual subject depth that one block may reserve, in basis points.
    uint16 internal constant MAX_BLOCK_DEPTH_BPS = 100;
    /// @notice Fewest blocks over which the recorded high may decay (about an hour of 12-second parent blocks). Always
    ///         longer than the longest price window, so a recorded high outlives every strike window.
    uint32 internal constant MIN_ANCHOR_DECAY_BLOCKS = 300;
    /// @notice Most blocks over which the recorded high may decay (about a week of 12-second parent blocks).
    uint32 internal constant MAX_ANCHOR_DECAY_BLOCKS = 50_400;
    /// @notice Least top guard: none. Only a direct deployment can use it; the factory enforces its own floor.
    uint16 internal constant MIN_TOP_GUARD_BPS = 0;
    /// @notice Largest top guard: opens stop once the reference price is within half of the band-top price.
    uint16 internal constant MAX_TOP_GUARD_BPS = 5_000;
    /// @notice Lowest protocol share of every premium, in basis points (the Hookr 1 protocol floor).
    uint16 internal constant MIN_PROTOCOL_SHARE_BPS = 2_000;
    /// @notice Highest protocol share of every premium, in basis points.
    uint16 internal constant MAX_PROTOCOL_SHARE_BPS = 5_000;
    /// @notice Least band reach, in basis points: the subject's band-top price must be at least 10x its spot price
    ///         (100,000 bps) when a factory lists a vault and whenever a vault takes custody of the family. Above the
    ///         band's top the reference pool holds none of the band's liquidity and cannot see the market (limit A1),
    ///         so the reach keeps that blind spot a 10x rally away from the price at which custody began. A safety
    ///         limit, not a knob.
    uint256 internal constant MIN_BAND_REACH_BPS = 100_000;

    /// @notice Suggested premium: 5% of the strike.
    uint16 internal constant DEFAULT_PREMIUM_BPS = 500;
    /// @notice Suggested strike markup: none (strike at the reference).
    uint16 internal constant DEFAULT_STRIKE_MARKUP_BPS = 0;
    /// @notice Suggested tenor: one hour.
    uint32 internal constant DEFAULT_TENOR = 1 hours;
    /// @notice Suggested price window: 25 blocks (about five minutes of parent blocks).
    uint16 internal constant DEFAULT_PRICE_WINDOW_BLOCKS = 25;
    /// @notice Suggested depth share: 6 bps per block, the largest the factory admits on a 0.25% base LP fee (fee / 400).
    uint16 internal constant DEFAULT_BLOCK_DEPTH_BPS = 6;
    /// @notice Suggested decay of the recorded high: 7,200 blocks (about a day of parent blocks).
    uint32 internal constant DEFAULT_ANCHOR_DECAY_BLOCKS = 7_200;
    /// @notice Suggested top guard: opens stop once the reference price is within 10% of the band-top price.
    uint16 internal constant DEFAULT_TOP_GUARD_BPS = 1_000;
    /// @notice Suggested factory floor on the top guard: 5% of the band-top price.
    uint16 internal constant DEFAULT_TOP_GUARD_FLOOR_BPS = 500;
    /// @notice Suggested protocol share of every premium: the 2,000 bps floor.
    uint16 internal constant DEFAULT_PROTOCOL_SHARE_BPS = 2_000;

    /// @notice One vault's terms. Frozen at construction.
    /// @param premiumBps Premium paid at open, in basis points of the strike. The walkthrough uses 500 (5%).
    /// @param strikeMarkupBps Strike above the reference price, in basis points. Zero sells at the reference.
    /// @param tenor Seconds from open to expiry. The walkthrough uses 3,600 (one hour).
    /// @param priceWindowBlocks Blocks of recorded prices the strike looks back over; see `PayLaterVault`.
    /// @param maxBlockDepthBps Most subject one block may reserve, in basis points of the founding band's virtual
    ///        subject depth at the reference price (L * 2^96 / sqrtPrice). Bounds what a price manipulation can buy;
    ///        the factory admits at most a quarter of the pool's base LP fee rate (see `PayLaterFactory`).
    /// @param anchorDecayBlocks Blocks over which the recorded high decays linearly to zero. It sizes the depth cap
    ///        only (never a strike): shorter clears an upward grief of the cap sooner, longer keeps the cap anchored
    ///        after a fall for longer. The fee argument that prices manipulation holds with the high fully decayed.
    /// @param topGuardBps Guard below the band's top, in basis points of the band-top price. An open is refused while
    ///        the reference price (the highest of the spot price and every recording in the window) is at or above
    ///        (1 - topGuardBps / 10,000) times the band-top price. Near and above the top the pool holds little or none
    ///        of the band's liquidity and cannot see the market (limit A1). Zero turns the guard off; the factory
    ///        refuses a guard below its floor.
    /// @param minOrderUnits Smallest reservation, in subject units.
    /// @param maxOrderUnits Largest reservation, in subject units.
    /// @param maxUnitsPerBlock Most subject units that may be reserved in one block, across all buyers.
    /// @param maxActiveUnits Most subject units reserved at once, across all open positions.
    /// @param maxInventory Most subject units the vault keeps as inventory (free plus reserved). Harvested subject
    ///        beyond it is owed to the beneficiary instead of becoming credit capacity.
    /// @param minPremium Premium floor in raw quote units, charged when the percentage premium is smaller.
    struct Terms {
        uint16 premiumBps;
        uint16 strikeMarkupBps;
        uint32 tenor;
        uint16 priceWindowBlocks;
        uint16 maxBlockDepthBps;
        uint32 anchorDecayBlocks;
        uint16 topGuardBps;
        uint128 minOrderUnits;
        uint128 maxOrderUnits;
        uint128 maxUnitsPerBlock;
        uint128 maxActiveUnits;
        uint128 maxInventory;
        uint128 minPremium;
    }

    /// @notice Type string used for the terms commitment.
    bytes32 internal constant TERMS_TYPEHASH = keccak256(
        "Terms(uint16 premiumBps,uint16 strikeMarkupBps,uint32 tenor,uint16 priceWindowBlocks,uint16 maxBlockDepthBps,uint32 anchorDecayBlocks,uint16 topGuardBps,uint128 minOrderUnits,uint128 maxOrderUnits,uint128 maxUnitsPerBlock,uint128 maxActiveUnits,uint128 maxInventory,uint128 minPremium)"
    );

    /// @notice Returns whether the terms are inside every hard bound.
    /// @dev Order sizes nest: min <= maxOrder <= maxPerBlock <= maxActive <= maxInventory <= HARD_MAX_UNITS.
    ///      The decay of the recorded high lies in [MIN_ANCHOR_DECAY_BLOCKS, MAX_ANCHOR_DECAY_BLOCKS] and the top guard in
    ///      [MIN_TOP_GUARD_BPS, MAX_TOP_GUARD_BPS].
    function valid(Terms memory t) internal pure returns (bool) {
        return t.premiumBps >= MIN_PREMIUM_BPS && t.premiumBps <= MAX_PREMIUM_BPS && t.strikeMarkupBps <= MAX_MARKUP_BPS
            && t.tenor >= MIN_TENOR && t.tenor <= MAX_TENOR && t.priceWindowBlocks != 0
            && t.priceWindowBlocks <= MAX_WINDOW_BLOCKS && t.maxBlockDepthBps != 0
            && t.maxBlockDepthBps <= MAX_BLOCK_DEPTH_BPS && t.anchorDecayBlocks >= MIN_ANCHOR_DECAY_BLOCKS
            && t.anchorDecayBlocks <= MAX_ANCHOR_DECAY_BLOCKS && t.topGuardBps <= MAX_TOP_GUARD_BPS
            && t.minOrderUnits != 0 && t.minOrderUnits <= t.maxOrderUnits && t.maxOrderUnits <= t.maxUnitsPerBlock
            && t.maxUnitsPerBlock <= t.maxActiveUnits && t.maxActiveUnits <= t.maxInventory
            && t.maxInventory <= HARD_MAX_UNITS;
    }

    /// @notice Every knob's lower bound, upper bound and suggested default, as three `Terms` values.
    /// @dev The unit caps (`minOrderUnits` to `maxInventory`) and `minPremium` are raw token amounts, so they have no
    ///      token-independent default: `defaults` leaves them zero and the app sizes them from the band (a zero cap is
    ///      refused, so the defaults alone are not valid terms). Unit caps must also nest (see `valid`); `minPremium`
    ///      has no upper bound because each buyer's `maxPremium` bounds what it pays. The factory further limits
    ///      `maxBlockDepthBps` to the reference pool's base LP fee in pips / 400.
    function bounds() internal pure returns (Terms memory lo, Terms memory hi, Terms memory defaults) {
        lo = Terms(MIN_PREMIUM_BPS, 0, MIN_TENOR, 1, 1, MIN_ANCHOR_DECAY_BLOCKS, MIN_TOP_GUARD_BPS, 1, 1, 1, 1, 1, 0);
        uint128 m = uint128(HARD_MAX_UNITS);
        hi = Terms(
            MAX_PREMIUM_BPS,
            MAX_MARKUP_BPS,
            MAX_TENOR,
            MAX_WINDOW_BLOCKS,
            MAX_BLOCK_DEPTH_BPS,
            MAX_ANCHOR_DECAY_BLOCKS,
            MAX_TOP_GUARD_BPS,
            m,
            m,
            m,
            m,
            m,
            type(uint128).max
        );
        defaults.premiumBps = DEFAULT_PREMIUM_BPS;
        defaults.strikeMarkupBps = DEFAULT_STRIKE_MARKUP_BPS;
        defaults.tenor = DEFAULT_TENOR;
        defaults.priceWindowBlocks = DEFAULT_PRICE_WINDOW_BLOCKS;
        defaults.maxBlockDepthBps = DEFAULT_BLOCK_DEPTH_BPS;
        defaults.anchorDecayBlocks = DEFAULT_ANCHOR_DECAY_BLOCKS;
        defaults.topGuardBps = DEFAULT_TOP_GUARD_BPS;
    }

    /// @notice The subject's band-top price over its spot price, in basis points, rounded down (`MIN_BAND_REACH_BPS`).
    /// @dev Both inputs are the subject's normalized sqrt prices in the quote (Q96), as the vault normalizes them. The
    ///      sqrt ratio is below 2^224 for any pool price; from 2^128 (a price ratio of 2^64) on, the reach saturates
    ///      at `type(uint256).max` instead of overflowing.
    /// @param topSqrtX96 The band-top normalized sqrt price.
    /// @param spotSqrtX96 The spot normalized sqrt price, nonzero.
    function bandReachBps(uint256 topSqrtX96, uint256 spotSqrtX96) internal pure returns (uint256) {
        uint256 ratio = FullMath.mulDiv(topSqrtX96, 1 << 96, spotSqrtX96);
        if (ratio >= 1 << 128) return type(uint256).max;
        return FullMath.mulDiv(ratio * ratio, BPS, 1 << 192);
    }

    /// @notice Commitment to the exact terms, for off-chain display and comparison.
    function hash(Terms memory t) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                TERMS_TYPEHASH,
                t.premiumBps,
                t.strikeMarkupBps,
                t.tenor,
                t.priceWindowBlocks,
                t.maxBlockDepthBps,
                t.anchorDecayBlocks,
                t.topGuardBps,
                t.minOrderUnits,
                t.maxOrderUnits,
                t.maxUnitsPerBlock,
                t.maxActiveUnits,
                t.maxInventory,
                t.minPremium
            )
        );
    }
}
