// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";

/// @title IHookrRulesConfig
/// @notice Frozen native rules configuration of a pool bound to HookrRules.
interface IHookrRulesConfig {
    /// @notice Returns the stored native rules configuration.
    /// @param id The pool.
    /// @return The pool's frozen native rules configuration.
    function config(PoolId id) external view returns (HookrTypes.RulesConfig memory);
}
