// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRegistry} from "./IHookrRegistry.sol";

/// @title IHookrRulesState
/// @notice HookrRules' own surface beside its role interfaces (IHookrRules, IHookrRulesConfig, IHookrDynamicFeeRules,
///         IHookrFeeOnlyRules, IHookrProtocolClaims, IHookrProtocolClaimsTransfer) and IHookrRecaptureRules, which its
///         fallback serves from HookrRecapture: its wiring, its reference state and integrations, and the events and
///         errors only the Rules raise.
interface IHookrRulesState {
    /// @notice The pool is already bound to these Rules.
    error AlreadyBound();
    /// @notice Only the pool's liquidity owner may add liquidity while the launch guard runs.
    error GuardLiquidity();
    /// @notice A buy under the launch guard must be an exact input.
    error GuardExactOutput();
    /// @notice A buy under the launch guard would raise the quote spent to `actual`, above the `limit`.
    error GuardBuyLimit(uint256 actual, uint256 limit);
    /// @notice The caller has no claim in the currency.
    error NothingToClaim();
    /// @notice The PoolManager or the recipient moved a different amount than the claim.
    error ClaimFailed();
    /// @notice A claim re-entered the Rules.
    error ReentrantClaim();
    /// @notice A pool without arb recapture cannot take a King of the Pool pot share of `potBps`.
    error PotUnavailable(uint16 potBps);
    /// @notice A dynamic fee pool's swap must be quoted through the root's simulation.
    error SimulationRequired();
    /// @notice `integrator` cannot be a pool's integrator: it is zero, not on the treasury's list or one of the Rules'
    ///         own addresses.
    error UnknownIntegrator(address integrator);

    /// @notice The root froze a pool's configuration in the Rules.
    /// @param id The pool.
    /// @param root The root that bound it.
    /// @param configHash The hash of the pool's configuration.
    /// @param config The pool's ABI-encoded native rules configuration.
    event RulesBound(PoolId indexed id, address indexed root, bytes32 configHash, bytes config);
    /// @notice A beneficiary withdrew a claim.
    /// @param quote The currency claimed.
    /// @param beneficiary The account whose claim was paid.
    /// @param to The recipient.
    /// @param amount The amount paid.
    event Claimed(Currency indexed quote, address indexed beneficiary, address indexed to, uint256 amount);

    /// @notice The pool's integrator was credited `amount` of `quote`: its frozen rate of Hookr's share of one swap's
    ///         rule fees. The same swap's FeesAllocated `protocol` is what the protocol recipient kept.
    /// @param id The pool.
    /// @param quote The currency credited.
    /// @param integrator The pool's integrator.
    /// @param amount The amount credited.
    event IntegratorPaid(PoolId indexed id, Currency indexed quote, address indexed integrator, uint256 amount);

    /// @notice Returns the registry whose treasury and admissions the Rules read.
    /// @return The registry.
    function registry() external view returns (IHookrRegistry);

    /// @notice Lowest protocolShareBps a pool may bind with, whatever the treasury's governed floor. The effective
    ///         floor at bind is the larger of the two (see `bind`).
    /// @return The lowest protocol share a pool may bind with, in basis points.
    function minProtocolShareBps() external view returns (uint16);

    /// @notice Whether the trusted root simulates swaps. A dynamic fee pool binds only when it does.
    /// @return True when the trusted root simulates swaps.
    function rootSimulates() external view returns (bool);

    /// @notice Returns all outstanding claims in this currency.
    /// @param currency The currency.
    /// @return The claims outstanding in the currency.
    function totalLiability(Currency currency) external view returns (uint256);

    /// @notice The pool's frozen integrator and its rate of every Hookr rule-fee share on the pool, in basis points.
    ///         Zeros for a pool without one.
    /// @param id The pool.
    /// @return integrator The pool's frozen integrator, or zero.
    /// @return integratorBps The integrator's rate of every Hookr rule-fee share, in basis points.
    function integration(PoolId id) external view returns (address integrator, uint16 integratorBps);

    /// @notice Returns the dynamic fee's default tempo, which a dynamic fee pool bound with the default Rules knobs
    ///         uses. A pool's own is `dynamicFeeParameters(PoolId)` (IHookrRulesKnobs, served by the fallback).
    /// @return window Seconds without an anchor move after which the reference steps toward the anchor, once per
    ///         window.
    /// @return reset Seconds after which the reference steps even while the anchor keeps moving, and seconds without an
    ///         anchor move after which the reference joins the anchor.
    /// @return carryBps Share of the reference's distance from the anchor that a step keeps, in basis points.
    /// @return moveTicks Ticks the anchor must move from where the last counted move left it to count as a move.
    function dynamicFeeParameters()
        external
        pure
        returns (uint256 window, uint256 reset, uint256 carryBps, uint256 moveTicks);

    /// @notice Returns the pool's dynamic fee state. Every field is zero for a pool without dynamic fees, and every
    ///         field except minLiquidity is zero before the pool's first swap. A launch's dev buy does not count: it is
    ///         charged from the launch price and starts nothing, so the next swap starts the state at the post-buy
    ///         price and every later swap, either way, is charged as on a pool launched at that price.
    /// @param id The pool.
    /// @return minLiquidity A swap carries the anchor to its end price only when its quote covers this liquidity
    ///         between the anchor and that price. Frozen at bind.
    /// @return referenceTick The tick of the price the dynamic fee measures from.
    /// @return anchorTick The tick of the executed price swaps with real notional have carried the pool to.
    /// @return movedAt The last time a swap carried the anchor to its own end price at least `moveTicks` from movedTick.
    /// @return referenceAt The time the reference's steps toward the anchor are counted to.
    /// @return movedTick The anchor tick at movedAt.
    function referenceState(PoolId id)
        external
        view
        returns (
            uint256 minLiquidity,
            int24 referenceTick,
            int24 anchorTick,
            uint40 movedAt,
            uint40 referenceAt,
            int24 movedTick
        );
}
