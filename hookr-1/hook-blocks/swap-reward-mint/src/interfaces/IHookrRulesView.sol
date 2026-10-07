// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";

/// @title Hookr rules read surface used by the swap reward
/// @notice Public getters `HookrRules` already exposes but `IHookrRules` does not declare.
/// @dev Every function here exists on Hookr 1 `HookrRules` as a public immutable or view.
interface IHookrRulesView {
    /// @notice The immutable Uniswap v4 PoolManager the rules settle against.
    function poolManager() external view returns (IPoolManager);

    /// @notice The immutable admission registry, which also keeps the reviewed quote catalog.
    function registry() external view returns (IHookrRegistry);

    /// @notice The immutable recipient of the rules' protocol share.
    function protocolRecipient() external view returns (address);

    /// @notice The immutable lowest protocol share, in basis points, a pool on these rules may bind with.
    function minProtocolShareBps() external view returns (uint16);

    /// @notice The frozen native rules configuration of a bound pool. Unbound pools return zero fields.
    function config(PoolId id) external view returns (HookrTypes.RulesConfig memory);
}
