// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title IHookrRulesClaimExit
/// @notice The two HookrRules calls outside `IHookrRules` a tax queue uses: the PoolManager its claims live in, and
///         the ERC-6909 exit for a quote whose transfers are restricted, taxed or paused.
interface IHookrRulesClaimExit {
    /// @notice The PoolManager the Rules' claims live in.
    function poolManager() external view returns (IPoolManager);

    /// @notice Pays the caller's whole claim of `currency` to `to` as PoolManager ERC-6909 claims.
    /// @return amount The claim paid.
    function claimAsClaims(Currency currency, address to) external returns (uint256 amount);
}
