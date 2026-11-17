// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrLaneRoot} from "../interfaces/IHookrLaneRoot.sol";
import {IHookrRulesConfig} from "../interfaces/IHookrRulesConfig.sol";
import {HookrOwnedRootTypes as F} from "./HookrOwnedRootTypes.sol";

/// @title HookrOwnedConformance
/// @notice The check the profile book and the owned-root factory share: whether a pool's frozen terms fit a Rules
///         module, an advisory list, caps, a rule mask and a lane choice.
/// @dev Internal functions only: compiled into HookrOwnedProfiles and HookrOwnedRootFactory, never linked and never on
///      a swap path. It reads the root's pool record, the pool's frozen RulesConfig and its frozen lane.
library HookrOwnedConformance {
    /// @notice Whether pool `id` of `root` binds `rules`, no advisory or one of `advisories`, declared caps inside
    ///         `caps`, only features in `mask`, and a recapture lane only when `laneAllowed`.
    /// @param root The root the pool belongs to.
    /// @param id The pool.
    /// @param rules The Rules module the pool must bind.
    /// @param advisories The advisories the pool may bind besides none.
    /// @param caps The ceiling of the pool's declared caps.
    /// @param mask The features the pool may use (HookrOwnedRootTypes).
    /// @param laneAllowed Whether the pool may carry the root's recapture lane.
    /// @return Whether the pool fits.
    function poolFits(
        address root,
        PoolId id,
        address rules,
        address[] memory advisories,
        HookrTypes.Caps memory caps,
        bytes32 mask,
        bool laneAllowed
    ) internal view returns (bool) {
        IHookrRoot r = IHookrRoot(root);
        if (!r.knownPool(id)) return false;
        HookrTypes.PoolConfig memory pc = r.poolConfig(id);
        if (pc.rules != rules) return false;
        if (pc.advisory != address(0)) {
            bool listed;
            for (uint256 i; i < advisories.length; ++i) {
                if (advisories[i] == pc.advisory) listed = true;
            }
            if (!listed) return false;
        }
        if (!F.capsWithin(pc.caps, caps)) return false;
        if (F.features(IHookrRulesConfig(rules).config(id)) & ~mask != 0) return false;
        if (!laneAllowed) {
            (address executor,,,,,,) = IHookrLaneRoot(root).laneOf(id);
            if (executor != address(0)) return false;
        }
        return true;
    }
}
