// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title Entry Ratio Guarantee types
/// @notice Shared records of the Entry Ratio Guarantee hook, its vault and its registrar.
/// @dev Amounts are raw currency units; times are `block.timestamp`
///      seconds, never `block.number`, because on Robinhood Chain (Arbitrum Nitro) `block.number` is the parent
///      chain's height while an anvil fork reports the L2 height.
library ErgTypes {
    /// @notice The protection an LP buys when it deposits. Chosen at deposit and immutable afterwards.
    /// @dev LOCK: the principal cannot leave before `unlockAt`; every exit forfeits all accrued fees, and the LP
    ///      may ask for the entry ratio at any exit after that, until the pool's LOCK coverage lapses (never, when the
    ///      pool sets no coverage horizon). OPTION: the principal may leave after a short
    ///      minimum hold; an exit that exercises inside the window forfeits all fees for the entry ratio, an exit
    ///      that does not exercise forfeits the pool's premium share of fees and keeps the pool ratio.
    enum Term {
        LOCK,
        OPTION
    }

    /// @notice The terms a pool's creator chooses at registration. Every field is bounded by `validateTerms`.
    /// @dev The entry band is not a creator choice: the hook derives it as half the pool fee less the reference's
    ///      declared tolerance. Field order matches `PoolTerms` and the `InvalidTerms` field index (0 reference ..
    ///      6 draw cap); `lockCoverageSeconds` is `PoolTerms` field 8, after the derived band, and
    ///      `protocolShareBps` field 9.
    /// @param priceReference The IErgPriceReference read at registration, at every deposit and at every exercise;
    ///        the registrar must allow it for the pool's currency pair (checked at registration and at every deposit,
    ///        never at an exit)
    /// @param lockSeconds LOCK term: seconds the principal is locked after deposit, 1 day to 730 days
    /// @param optionHoldSeconds OPTION term: seconds before any exit and before the exercise window opens,
    ///        1 hour to 730 days
    /// @param optionWindowSeconds OPTION term: length of the exercise window after the hold, 1 hour to 730 days
    /// @param optionPremiumBps OPTION term: share of accrued fees forfeited by an exit that does not exercise,
    ///        1,000 to 10,000
    /// @param coverageBps Share of an exercised deficit the reserve pays, before the draw cap, 1 to 10,000
    /// @param maxDrawBps Largest share of the pool's reserve (after the exit's own forfeits) the exits of one draw
    ///        window (`DRAW_WINDOW_SECONDS`) may draw together, 1 to 10,000
    /// @param lockCoverageSeconds LOCK term: seconds after the lock ends during which an exit may still ask for the
    ///        entry ratio, 1 day to 730 days; zero keeps the right open for the position's life
    /// @param protocolShareBps Share of every forfeited fee (the premium) paid to the protocol instead of the
    ///        reserve, from the hook's `minProtocolShareBps` (never below 2,000) to 5,000. An exit whose entry-ratio
    ///        leg pays keeps the leg's waiver out of it: `fee / (1 - fee)` of what the reserve takes, in that currency
    struct CreatorTerms {
        address priceReference;
        uint32 lockSeconds;
        uint32 optionHoldSeconds;
        uint32 optionWindowSeconds;
        uint16 optionPremiumBps;
        uint16 coverageBps;
        uint16 maxDrawBps;
        uint32 lockCoverageSeconds;
        uint16 protocolShareBps;
    }

    /// @notice Immutable terms of one registered pool: the creator's terms plus the derived entry band.
    /// @param priceReference The IErgPriceReference read at every deposit (entry band) and at every exercise (exercise
    ///        band and the leg's reference amounts)
    /// @param lockSeconds LOCK term: seconds the principal is locked after deposit
    /// @param optionHoldSeconds OPTION term: seconds before any exit and before the exercise window opens
    /// @param optionWindowSeconds OPTION term: length of the exercise window after the hold; the right then lapses
    /// @param optionPremiumBps OPTION term: share of accrued fees forfeited by an exit that does not exercise
    /// @param coverageBps Share of an exercised deficit the reserve pays, before the draw cap
    /// @param maxDrawBps Largest share of the pool's reserve (after the exit's own forfeits) the exits of one draw
    ///        window may draw together
    /// @param maxEntrySqrtDeviationPips Largest distance between the pool's sqrt price and the reference's sqrt
    ///        price at deposit, in pips of the reference; set at registration to half the pool fee, rounded down,
    ///        less the reference's declared tolerance
    /// @param lockCoverageSeconds LOCK term: seconds after the lock ends during which an exit may still ask for the
    ///        entry ratio; zero means the right never lapses
    /// @param protocolShareBps Share of every forfeited fee paid to the protocol instead of the reserve; an exit whose
    ///        entry-ratio leg pays keeps the leg's waiver out of it
    struct PoolTerms {
        address priceReference;
        uint32 lockSeconds;
        uint32 optionHoldSeconds;
        uint32 optionWindowSeconds;
        uint16 optionPremiumBps;
        uint16 coverageBps;
        uint16 maxDrawBps;
        uint24 maxEntrySqrtDeviationPips;
        uint32 lockCoverageSeconds;
        uint16 protocolShareBps;
    }

    /// @notice One enrolled position. The PoolManager position is owned by the vault with salt = bytes32(id).
    /// @param owner The LP allowed to withdraw
    /// @param start Deposit timestamp
    /// @param unlockAt LOCK: end of the principal lock. OPTION: end of the minimum hold, start of the window
    /// @param expiry OPTION: last second the right can be exercised. LOCK: last second the entry ratio can be asked
    ///        for, or zero when the pool's LOCK coverage never lapses
    /// @param term LOCK or OPTION
    /// @param open True until the position exits
    /// @param poolId The registered pool
    /// @param tickLower Lower tick of the vault's position
    /// @param tickUpper Upper tick of the vault's position
    /// @param liquidity Liquidity the vault holds for the position
    /// @param entry0 currency0 actually paid at deposit (the PoolManager rounds this up)
    /// @param entry1 currency1 actually paid at deposit (the PoolManager rounds this up)
    /// @param entryReference The reference's entry sqrt price (Q64.96, `entrySqrtPriceX96`) at deposit; the leg
    ///        covers only the deficit the reference saw from this price to its answer at the exit
    struct Position {
        address owner;
        uint40 start;
        uint40 unlockAt;
        uint40 expiry;
        Term term;
        bool open;
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 entry0;
        uint128 entry1;
        uint160 entryReference;
    }

    /// @notice The outcome of one exit, as settled by the hook or previewed.
    /// @param lp0 currency0 the LP receives
    /// @param lp1 currency1 the LP receives
    /// @param forfeited0 Fees in currency0 moved to the reserve (the forfeit less the protocol's share)
    /// @param forfeited1 Fees in currency1 moved to the reserve (the forfeit less the protocol's share)
    /// @param paid0 Reserve currency0 paid to the LP to restore the entry ratio
    /// @param paid1 Reserve currency1 paid to the LP to restore the entry ratio
    /// @param taken0 Surplus currency0 the LP gives the reserve in exchange
    /// @param taken1 Surplus currency1 the LP gives the reserve in exchange
    /// @param hookDelta0 Signed reserve change in currency0 (positive: into the reserve)
    /// @param hookDelta1 Signed reserve change in currency1 (positive: into the reserve)
    /// @param protocol0 The protocol's share of the forfeited currency0 fees, credited to the protocol recipient.
    ///        The hook's PoolManager delta for the exit is `hookDelta0 + protocol0`
    /// @param protocol1 The protocol's share of the forfeited currency1 fees
    struct ExitResult {
        uint256 lp0;
        uint256 lp1;
        uint256 forfeited0;
        uint256 forfeited1;
        uint256 paid0;
        uint256 paid1;
        uint256 taken0;
        uint256 taken1;
        int256 hookDelta0;
        int256 hookDelta1;
        uint256 protocol0;
        uint256 protocol1;
    }
}
