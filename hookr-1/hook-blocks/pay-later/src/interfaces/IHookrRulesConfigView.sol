// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";

/// @title IHookrRulesConfigView
/// @notice Read-only view of the Hookr 1 `HookrRules` configuration getter (not part of `IHookrRules`).
interface IHookrRulesConfigView {
    /// @notice Stored native rules configuration of a bound pool.
    function config(PoolId id) external view returns (HookrTypes.RulesConfig memory);
}
