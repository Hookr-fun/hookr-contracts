// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHookrRecaptureEvents
/// @notice The events and errors of the arb recapture module. HookrRecapture runs at a Rules contract's address by
///         DELEGATECALL (through the Rules' fallback) and emits and reverts with them there, so IHookrRecaptureRules,
///         HookrRecapture and HookrRules inherit this one declaration.
interface IHookrRecaptureEvents {
    /// @notice The pool is not a King of the Pool pool.
    error NotKoth();
    /// @notice The King of the Pool epoch has not ended.
    error EpochOpen();

    /// @notice A King of the Pool pool's `maxPrizeBps` is above `bound`, the widest prize its native rules admit: half
    ///         of what the protocol keeps of LP Rewards and Auto Burn in basis points of a buy, after the pool's
    ///         integrator rate (`prizeBoundFor`). Raised at bind.
    error PrizeAboveBound(uint256 maxPrizeBps, uint256 bound);

    /// @notice One arb recapture push's split, in `currency`. `traderAmount`, `lp`, `pot` and `protocol` are what Hookr
    ///         paid out of the push and add up to it. `reportedProfit` is the profit the executor's push reports at the
    ///         pool's frozen partner share: push x 10,000 / (10,000 - partnerBps), rounded down, as HookrLane._run
    ///         computes it (the root's CorrectionSucceeded `reportedProfit` for the same push), and `protocol` is 25%
    ///         of it, at most the push. Hookr never sees the arbitrage's real profit or the share the partner kept, so
    ///         `reportedProfit` is not proof of what the executor earned or paid.
    /// @param id The pool.
    /// @param trader The after-phase's authenticated payer, or zero.
    /// @param traderAmount What Hookr paid the trader out of the push, as a Rules claim.
    /// @param lp What Hookr paid out as the LP share.
    /// @param pot What Hookr paid into the King of the Pool pot.
    /// @param protocol What Hookr paid the protocol, 25% of `reportedProfit` and at most the push.
    /// @param currency The currency of the push.
    /// @param reportedProfit The profit the executor's push reports at the pool's frozen partner share; not proof of
    ///         payment.
    event RecaptureSplit(
        PoolId indexed id,
        address indexed trader,
        uint256 traderAmount,
        uint256 lp,
        uint256 pot,
        uint256 protocol,
        Currency currency,
        uint256 reportedProfit
    );
    /// @notice A pool's pending LP share was donated to its in-range liquidity.
    /// @param id The pool.
    /// @param amount0 The currency0 donated.
    /// @param amount1 The currency1 donated.
    event LpShareDonated(PoolId indexed id, uint256 amount0, uint256 amount1);
    /// @notice An amount accrued to the pool's liquidity owner.
    /// @param id The pool.
    /// @param currency The currency.
    /// @param amount The amount accrued.
    event PoolAccrued(PoolId indexed id, Currency indexed currency, uint256 amount);
    /// @notice The root swept its claims in a currency to the protocol recipient.
    /// @param currency The currency.
    /// @param amount The amount swept.
    event ClaimsSwept(Currency indexed currency, uint256 amount);
    /// @notice A King of the Pool epoch closed and its leader was credited the prize.
    /// @param id The pool.
    /// @param winner The epoch's leader.
    /// @param amount The prize credited, in the pool's quote.
    /// @param epochStart The closed epoch's start.
    event KingCrowned(PoolId indexed id, address indexed winner, uint256 amount, uint64 epochStart);
    /// @notice A buy took the lead of a King of the Pool epoch.
    /// @param id The pool.
    /// @param leader The new leader.
    /// @param amount The quote the leading buy spent.
    /// @param epochStart The epoch's start.
    event LeaderChanged(PoolId indexed id, address indexed leader, uint256 amount, uint64 epochStart);
    /// @notice A sell in the same transaction as a leading buy voided the crown and restored the earlier leader.
    /// @param id The pool.
    /// @param voided The leader whose crown was voided.
    /// @param restored The leader restored.
    /// @param epochStart The epoch's start.
    event CrownVoided(PoolId indexed id, address indexed voided, address indexed restored, uint64 epochStart);
    /// @notice One or more elapsed King of the Pool epochs closed and the next one started.
    /// @param id The pool.
    /// @param closedEpochStart The start of the first epoch closed.
    /// @param nextEpochStart The start of the epoch now running.
    /// @param potCarried The pot carried into it.
    event EpochRolled(PoolId indexed id, uint64 closedEpochStart, uint64 nextEpochStart, uint256 potCarried);
    /// @notice A closed epoch released part of the pot to the LP share.
    /// @param id The pool.
    /// @param amount The amount released, in the pool's quote.
    event PotReleased(PoolId indexed id, uint256 amount);
    /// @notice The pool's liquidity owner accrual in a currency moved into an account's claims.
    /// @param id The pool.
    /// @param to The account credited.
    /// @param currency The currency.
    /// @param amount The amount moved.
    event PoolClaimed(PoolId indexed id, address indexed to, Currency indexed currency, uint256 amount);
}
