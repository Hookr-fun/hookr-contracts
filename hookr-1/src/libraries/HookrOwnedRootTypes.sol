// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {HookrTypes} from "../types/HookrTypes.sol";

/// @title HookrOwnedRootTypes
/// @notice The rule subset an owned profile or an owned root allows, as a mask over the five features of HookrRules:
///         Anti-Snipe, dynamic fees, Auto Burn, LP Rewards and Royalty.
/// @dev HookrRules carries every feature behind its RulesConfig, so a rule subset is the one Rules module plus this
///      mask. Auto Burn is the only feature a cap switches off when a pool opens (a zero `maxSubjectTakeBps` makes
///      HookrRules refuse any burn at bind); the other four are soft: a pool's use of them is read from its frozen
///      configuration by the conformance views (HookrOwnedConformance) and checked when a pool is adopted into a
///      profile, never enforced at open. Internal constants and pure functions only: compiled into the contracts that
///      use them.
library HookrOwnedRootTypes {
    /// @notice A guard block is set (`guardEndBlock != 0`): the Anti-Snipe guard, the Snipe tax and the guard's buy
    ///         cap.
    bytes32 internal constant ANTI_SNIPE = bytes32(uint256(1));
    /// @notice Hookr dynamic fees (`dynamicFeeSens != 0`).
    bytes32 internal constant DYNAMIC_FEE = bytes32(uint256(2));
    /// @notice Auto Burn (`burnBps != 0`).
    bytes32 internal constant AUTO_BURN = bytes32(uint256(4));
    /// @notice LP Rewards (`lpBps != 0`).
    bytes32 internal constant LP_REWARDS = bytes32(uint256(8));
    /// @notice The creator royalty (`royaltyBps != 0`).
    bytes32 internal constant ROYALTY = bytes32(uint256(16));
    /// @notice Every feature: the widest mask.
    bytes32 internal constant ALL_FEATURES = bytes32(uint256(31));
    /// @notice The features no cap switches off when a pool opens. A root anyone may open pools on keeps all four, so
    ///         every rule it advertises is one its pools can use.
    bytes32 internal constant SOFT_FEATURES = bytes32(uint256(27));

    /// @notice The features a frozen rules configuration uses.
    /// @param c The pool's RulesConfig.
    /// @return mask The mask of the features `c` turns on.
    function features(HookrTypes.RulesConfig memory c) internal pure returns (bytes32 mask) {
        if (c.guardEndBlock != 0) mask |= ANTI_SNIPE;
        if (c.dynamicFeeSens != 0) mask |= DYNAMIC_FEE;
        if (c.burnBps != 0) mask |= AUTO_BURN;
        if (c.lpBps != 0) mask |= LP_REWARDS;
        if (c.royaltyBps != 0) mask |= ROYALTY;
    }

    /// @notice The caps an owned root's RULES admission carries: `caps`, with the subject cap at zero when `mask`
    ///         leaves Auto Burn out, which makes every burn fail at bind.
    /// @param caps The profile's caps.
    /// @param mask The root's rule mask.
    /// @return out The admission's caps.
    function hardCaps(HookrTypes.Caps memory caps, bytes32 mask) internal pure returns (HookrTypes.Caps memory out) {
        out = caps;
        if (mask & AUTO_BURN == 0) out.maxSubjectTakeBps = 0;
    }

    /// @notice Whether every field of `inner` is at or under the matching field of `outer`.
    /// @param inner The caps to check.
    /// @param outer The ceiling.
    /// @return Whether `inner` fits under `outer`.
    function capsWithin(HookrTypes.Caps memory inner, HookrTypes.Caps memory outer) internal pure returns (bool) {
        return inner.maxLpFeePips <= outer.maxLpFeePips && inner.maxQuoteTakePips <= outer.maxQuoteTakePips
            && inner.maxSubjectTakeBps <= outer.maxSubjectTakeBps;
    }
}
