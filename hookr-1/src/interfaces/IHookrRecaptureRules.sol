// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrLaneRules} from "./IHookrLaneRules.sol";
import {IHookrRecaptureEvents} from "./IHookrRecaptureEvents.sol";

/// @title IHookrRecaptureRules
/// @notice What HookrRules serves from its fallback through its HookrRecapture module: the lane's split, King of the
///         Pool, the pool's LP accrual and the creator knobs' bounds and defaults. Events are emitted by the Rules.
/// @dev Split of one arb recapture's push, in the currency pushed: the protocol takes RECAPTURE_PROTOCOL_BPS (25%) of
///      the profit the push reports (`reportedProfit`) first, at most the push, on every pool alike and never split
///      with an integrator; on a push in the quote the King of the Pool pot takes RulesConfig.potBps of the rest and
///      the trader named on the after-phase `traderBps` of the part its own swap accounts for; the remainder
///      (`lpBps`, rounding dust, any trader share the basis does not cover, and on a push in another currency the
///      trader and pot shares too) is the LP share. In the pool's two currencies it is donated to the in-range
///      liquidity from a later L2 block (ArbSys.arbBlockNumber(), not block.number), or is the liquidity owner's
///      accrual when there is none; in any other currency it is the owner's accrual.
interface IHookrRecaptureRules is IHookrLaneRules, IHookrRecaptureEvents {
    /// @notice Closes an elapsed King of the Pool epoch: credits the leader min(pot, spend * maxPrizeBps / 10,000)
    ///         and releases potReleaseBps of the carried pot per closed epoch to the LP accrual. Permissionless.
    /// @param id The pool.
    function settleEpoch(PoolId id) external;

    /// @notice Moves the pool's liquidity owner accrual, in every currency, into `to`'s claims. Only the pool's
    ///         liquidity owner (for a launched pool, HookrLauncher: claimRecapture for the family owner, and every
    ///         withdraw or fee collection of the member). Returns how many currencies moved; zero when nothing did.
    /// @param id The pool.
    /// @param to The account whose claims receive the accrual.
    /// @return moved The number of currencies moved.
    function claimPool(PoolId id, address to) external returns (uint256 moved);

    /// @notice The frozen recapture config, the pot share and the protocol share. Zeros without recapture.
    ///         `protocolShareBps` is the pool's whole share: its prize ceiling was checked on what Hookr keeps after the
    ///         pool's integrator (`prizeBoundFor` with the rate from `integration(id)`).
    /// @param id The pool.
    /// @return rc The frozen recapture configuration.
    /// @return potBps The pot share of the remainder, in basis points.
    /// @return protocolShareBps The pool's whole protocol share, in basis points.
    function recaptureConfig(PoolId id)
        external
        view
        returns (HookrTypes.RecaptureConfig memory rc, uint16 potBps, uint16 protocolShareBps);

    /// @notice The King of the Pool epoch; a rollover is due from block.timestamp >= epochEnd.
    /// @param id The pool.
    /// @return epochStart The running epoch's start.
    /// @return epochEnd The running epoch's end.
    /// @return leader The epoch's leader, or zero.
    /// @return leaderAmount The quote the leading buy spent.
    /// @return pot The pot carried and accrued.
    function hill(PoolId id)
        external
        view
        returns (uint64 epochStart, uint64 epochEnd, address leader, uint128 leaderAmount, uint128 pot);

    /// @notice The prize the leader would get if the epoch closed now, and the pot one closure would carry.
    /// @param id The pool.
    /// @return leader The epoch's leader, or zero.
    /// @return prize The prize the leader would be credited.
    /// @return carried The pot one closure would carry.
    function pendingPrize(PoolId id) external view returns (address leader, uint256 prize, uint256 carried);

    /// @notice The pool's unclaimed liquidity owner accrual in `currency`.
    /// @param id The pool.
    /// @param currency The currency.
    /// @return The unclaimed accrual.
    function poolAccrued(PoolId id, Currency currency) external view returns (uint256);

    /// @notice Every currency the pool's liquidity owner accrual has held.
    /// @param id The pool.
    /// @return The currencies the accrual has held.
    function poolAccruedCurrencies(PoolId id) external view returns (Currency[] memory);

    /// @notice The pool's pending LP donation: `due` is released from the L2 block of the last flush, `fresh` accrued
    ///         in `freshBlock` and is released from the L2 block after it. `freshBlock` is an L2 height
    ///         (ArbSys.arbBlockNumber(), equal to eth_blockNumber and a receipt's blockNumber), not block.number.
    /// @param id The pool.
    /// @return due0 The currency0 released now.
    /// @return due1 The currency1 released now.
    /// @return fresh0 The currency0 accrued in `freshBlock`.
    /// @return fresh1 The currency1 accrued in `freshBlock`.
    /// @return freshBlock The L2 block the fresh amounts accrued in.
    function pendingDonation(PoolId id)
        external
        view
        returns (uint256 due0, uint256 due1, uint256 fresh0, uint256 fresh1, uint256 freshBlock);

    /// @notice The config the launch wizard and SDK pre-fill: arb recaptures on, King of the Pool off.
    /// @return rc The default recapture configuration.
    /// @return potBps The default pot share, in basis points.
    function recaptureDefaults() external pure returns (HookrTypes.RecaptureConfig memory rc, uint16 potBps);

    /// @notice The largest maxPrizeBps a King of the Pool pool may freeze with these native rules: half the protocol's
    ///         share of LP Rewards and Auto Burn in basis points of a buy. A pool with an integrator is bound on the
    ///         share the protocol keeps after the integrator's rate: pass that kept share, or use `prizeBoundFor`.
    /// @param lpBps The pool's LP Rewards rate, in basis points of a buy.
    /// @param burnBps The pool's Auto Burn rate, in basis points of a buy.
    /// @param protocolShareBps The share the protocol keeps, in basis points.
    /// @return The largest maxPrizeBps.
    function prizeBound(uint16 lpBps, uint16 burnBps, uint16 protocolShareBps) external pure returns (uint256);

    /// @notice The largest maxPrizeBps the bind admits for a pool naming an integrator at `integratorBps` (0 for none):
    ///         `prizeBound` on protocolShareBps x (10,000 - integratorBps) / 10,000, rounded down.
    /// @param lpBps The pool's LP Rewards rate, in basis points of a buy.
    /// @param burnBps The pool's Auto Burn rate, in basis points of a buy.
    /// @param protocolShareBps The pool's whole protocol share, in basis points.
    /// @param integratorBps The integrator's rate of that share, in basis points, zero for none.
    /// @return The largest maxPrizeBps.
    function prizeBoundFor(uint16 lpBps, uint16 burnBps, uint16 protocolShareBps, uint16 integratorBps)
        external
        pure
        returns (uint256);

    /// @notice The least protocolShareBps a pool binding now must have: the larger of the Rules' immutable floor and
    ///         their treasury's governed floor, the effective floor the bind checks.
    /// @return The effective floor, in basis points.
    function protocolShareFloor() external view returns (uint16);

    /// @notice The Hookr minimum pool `id` froze at bind, in pips of a swap: zero for a pool without one, which every
    ///         pool with arb recapture is. Served from the Rules' fallback for every pool, with recapture or not.
    /// @param id The pool.
    /// @return The Hookr minimum in pips, zero for none.
    function minimumFee(PoolId id) external view returns (uint16);

    /// @notice The module HookrRules delegates to and its runtime codehash, both fixed in the Rules' runtime.
    /// @return module The module.
    /// @return codeHash The module's runtime codehash.
    function recaptureModule() external view returns (address module, bytes32 codeHash);

    /// @notice Least share of an arb recapture's post-protocol remainder a pool may credit the trader: 0.
    /// @return The least trader share, in basis points.
    function MIN_TRADER_BPS() external view returns (uint16);
    /// @notice Most share of an arb recapture's post-protocol remainder a pool may credit the trader: 5,000.
    /// @return The most trader share, in basis points.
    function MAX_TRADER_BPS() external view returns (uint16);
    /// @notice The trader share the launch wizard and SDK pre-fill: 2,500.
    /// @return The pre-filled trader share, in basis points.
    function DEFAULT_TRADER_BPS() external view returns (uint16);
    /// @notice The LP share the launch wizard and SDK pre-fill with King of the Pool off: 7,500, the rest.
    /// @return The pre-filled LP share, in basis points.
    function DEFAULT_LP_BPS() external view returns (uint16);
    /// @notice Most share of the remainder a King of the Pool pool may put in its pot (RulesConfig.potBps): 5,000.
    /// @return The most pot share, in basis points.
    function MAX_POT_BPS() external view returns (uint16);
    /// @notice The pot share the wizard pre-fills when the creator turns King of the Pool on: 2,500.
    /// @return The pre-filled pot share, in basis points.
    function DEFAULT_POT_BPS() external view returns (uint16);
    /// @notice Shortest King of the Pool epoch: 1 hour.
    /// @return The shortest epoch, in seconds.
    function MIN_PERIOD() external view returns (uint32);
    /// @notice Longest King of the Pool epoch: 30 days.
    /// @return The longest epoch, in seconds.
    function MAX_PERIOD() external view returns (uint32);
    /// @notice The epoch the wizard pre-fills: 1 day.
    /// @return The pre-filled epoch, in seconds.
    function DEFAULT_PERIOD() external view returns (uint32);
    /// @notice Least share of the carried pot a closed epoch releases to the LP accrual: 2,500.
    /// @return The least release, in basis points.
    function MIN_POT_RELEASE_BPS() external view returns (uint16);
    /// @notice Most share of the carried pot a closed epoch releases: 10,000, all of it.
    /// @return The most release, in basis points.
    function MAX_POT_RELEASE_BPS() external view returns (uint16);
    /// @notice The release the wizard pre-fills: 5,000, half the carried pot per closed epoch.
    /// @return The pre-filled release, in basis points.
    function DEFAULT_POT_RELEASE_BPS() external view returns (uint16);
    /// @notice Least prize ceiling of a King of the Pool pool: 1; the most is the pool's `prizeBound`.
    /// @return The least prize ceiling, in basis points.
    function MIN_PRIZE_BPS() external view returns (uint16);
    /// @notice The share of the protocol fee a winning buy paid that its prize may reach: 5,000, half.
    /// @return The share of the protocol fee a prize may reach, in basis points.
    function PRIZE_SHARE_OF_FEE_BPS() external view returns (uint16);
    /// @notice The protocol's cut of every arb recapture, in basis points of the profit its push reports: 2,500.
    /// @return The protocol's cut, in basis points of the reported profit.
    function RECAPTURE_PROTOCOL_BPS() external view returns (uint16);
    /// @notice From this many closed epochs in one rollover on, the whole carried pot is released: 256.
    /// @return The closed-epoch count that releases the whole pot.
    function FULL_RELEASE_EPOCHS() external view returns (uint256);
    /// @notice Least releaseBlocks of a recapture pool, in L2 blocks: 1,200, about 2 minutes.
    /// @return The least release period, in L2 blocks.
    function MIN_RELEASE_BLOCKS() external view returns (uint32);
    /// @notice Most releaseBlocks of a recapture pool, in L2 blocks: 864,000, about 24 hours.
    /// @return The most release period, in L2 blocks.
    function MAX_RELEASE_BLOCKS() external view returns (uint32);
    /// @notice The releaseBlocks the wizard pre-fills, in L2 blocks: 36,000, about an hour.
    /// @return The pre-filled release period, in L2 blocks.
    function DEFAULT_RELEASE_BLOCKS() external view returns (uint32);
}
