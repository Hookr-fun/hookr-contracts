// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";

/// @title IHookrRulesKnobs
/// @notice A pool's Rules knobs (HookrTypes.RulesKnobs) as bound, and the dynamic fee's reach bound: what HookrRules
///         serves from its fallback through its HookrRecapture module, so no selector joins the Rules' dispatcher
///         ahead of the swap calls. The dynamic fee's default tempo is HookrRules' `dynamicFeeParameters()`.
interface IHookrRulesKnobs {
    /// @notice The pool's dynamic fee tempo: its own knobs, or the defaults for a dynamic fee pool bound with them.
    ///         Zeros for a pool without dynamic fees or an unbound pool.
    /// @param id The pool.
    /// @return window Seconds without an anchor move after which the reference steps toward the anchor, once per
    ///         window.
    /// @return reset Seconds after which the reference steps even while the anchor keeps moving, and seconds without an
    ///         anchor move after which the reference joins the anchor.
    /// @return carryBps Share of the reference's distance from the anchor that a step keeps, in basis points.
    /// @return moveTicks Ticks the anchor must move from where the last counted move left it to count as a move.
    function dynamicFeeParameters(PoolId id)
        external
        view
        returns (uint256 window, uint256 reset, uint256 carryBps, uint256 moveTicks);

    /// @notice The pool's Rules knobs as bound: its minimum dynamic fee liquidity and tempo (zeros without dynamic
    ///         fees, the defaults where it bound them) and its Snipe curve (SNIPE_CURVE_LINEAR unless it bound
    ///         another). Zeros for an unbound pool.
    /// @param id The pool.
    /// @return knobs The pool's knobs.
    function rulesKnobs(PoolId id) external view returns (HookrTypes.RulesKnobs memory knobs);

    /// @notice The dynamic fee's reach bound every dynamic fee pool binds within (HookrDynamicFee.withinReach): its span
    ///         (maxFeePips less its base fee, in pips) times its dynamicFeeSens squared at most `maxReach`, and its span
    ///         times its protocolShareBps times (`reserveScale` - dynamicFeeSens squared) at most
    ///         `maxReserve` x `reserveScale`.
    /// @return maxReach HookrDynamicFee.MAX_REACH.
    /// @return maxReserve HookrDynamicFee.MAX_RESERVE.
    /// @return reserveScale HookrDynamicFee.RESERVE_SCALE.
    function dynamicFeeReachBound() external view returns (uint256 maxReach, uint256 maxReserve, uint256 reserveScale);
}
