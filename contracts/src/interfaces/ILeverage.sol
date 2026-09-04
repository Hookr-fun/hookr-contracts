// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Shared types for Leveraged Hooks. Breaks the hook <-> market import cycle: both
///         sides depend on this file and neither depends on the other's implementation.
interface ILeverage {
    /// @notice Per-market risk configuration, written once by the factory.
    struct MarketConfig {
        /// Fraction of collateral value that may be borrowed against, in bps.
        uint16 ltvBps;
        /// Health hits 1 here. Strictly above ltvBps, so a position opens with room.
        uint16 liqThresholdBps;
        /// Liquidator's cut of the seized collateral, in bps. Bounded by construction.
        uint16 liqBonusBps;
        /// Share of interest routed to the market's own reserve, in bps.
        uint16 reserveFactorBps;
        /// Utilisation at which the borrow curve steepens, in WAD.
        uint64 kinkWad;
        /// Utilisation past which new borrowing is refused outright, in WAD.
        uint64 maxUtilisationWad;
        /// Quote-side depth the pool must hold before leverage opens at all, in wei.
        ///
        /// Nearly every attack measured against this design scaled with one ratio: the size of
        /// the trade the market is forced to make against the depth available to absorb it.
        /// The redemption sandwich, the unwind's execution, and `_seizeCap` are all governed by
        /// it. A depth floor does not patch those paths; it removes the regime they live in.
        ///
        /// Enforced CONTINUOUSLY on new borrowing, never as a one-time unlock. Crossing the
        /// floor, opening positions and then withdrawing the liquidity would put the book back
        /// in the thin regime with leverage already outstanding. Closing, repaying and
        /// liquidating stay open below the floor — the point is to stop adding risk, not to
        /// trap the risk already there.
        uint128 minPoolQuoteWei;
        /// Protocol-level hard cap on credit for this market, in wei.
        uint128 protocolCapWei;
    }

    /// @notice One trader's position. Debt is stored scaled by the borrow index, so interest
    ///         accrues to it without touching per-position storage.
    struct Position {
        /// Collateral tokens held by the market on this position's behalf.
        uint128 collateral;
        /// Principal scaled by the index at open: owed = scaledDebt * index / WAD.
        uint128 scaledDebt;
    }

    /// @notice A price reading the market trusts, plus why.
    struct PriceView {
        /// Spot, as quote-wei per whole token.
        uint256 spotWad;
        /// Time-weighted average over the configured window.
        uint256 twapWad;
        /// True when spot and the average disagree past the configured tolerance.
        bool deviated;
        /// True when the ring cannot cover the window yet.
        bool stale;
    }

    error NotFactory();
    error NotMarket();
    error AlreadyRegistered();
    error PoolNotRegistered();
    error Protected();
    error BadConfig();
}

/// @notice What the market needs from the hook.
interface ILeverageHook {
    /// @notice Registers a pool and its owning market. One-shot, factory-gated.
    function registerPool(PoolKey calldata key, address market) external;

    /// @notice Spot, TWAP, deviation and staleness for a registered pool.
    function priceView(PoolId id) external view returns (ILeverage.PriceView memory);

    /// @notice True when the market must refuse anything that adds risk.
    function isProtected(PoolId id) external view returns (bool);

    /// @notice True when spot sits materially below the market's OWN RECENT (not full-window)
    ///         history. Narrower than `isProtected`: it exists so a redemption's unwind can
    ///         decline to sell into a pool that has just been pushed down, without waiting on
    ///         the full 900s window to notice.
    function isRecentlyDislocated(PoolId id) external view returns (bool);

    /// @notice The market that owns a pool, or address(0).
    function marketOf(PoolId id) external view returns (address);
}

/// @notice What the HOOK needs from the market, and nothing else.
///
///         Deliberately its own interface rather than a method on a fat `ILeverageMarket`: the
///         hook is the one contract in the system that runs inside somebody else's swap, so the
///         surface it can reach into the market with is the surface an incoming trader can
///         reach by trading. One function, one caller, one direction.
interface ILeverageQueue {
    /// @notice Liquidates one position INTO THE POOL, ahead of the swap that is about to
    ///         execute. Called from `beforeSwap`, inside the caller's own `unlock`.
    /// @param trader The position to take.
    /// @param projectedPriceWad The quote-per-token price the incoming swap would leave behind
    ///        if it executed against the pool as it stands right now.
    /// @return tokensSold Collateral sold into the pool ahead of the incoming swap.
    /// @dev Reverts rather than returning zero when the position may not be taken. The hook
    ///      relies on that: see `LeverageHook._drainQueue` for why one refusal ends the pass.
    function liquidateAhead(address trader, uint256 projectedPriceWad) external returns (uint256 tokensSold);

    /// @notice Interest index the book's bucket keys are normalised by.
    function borrowIndex() external view returns (uint256);

    /// @notice Occupied-octave mask over the credit book.
    function bookOct() external view returns (uint256);

    /// @notice Occupied-mantissa mask within one octave.
    function bookSub(uint256 octave) external view returns (uint256);

    /// @notice First position filed in a bucket, or address(0).
    function bucketHead(uint256 bucket) external view returns (address);

    /// @notice The next position in the same bucket, or address(0).
    function bucketNext(address trader) external view returns (address);
}
