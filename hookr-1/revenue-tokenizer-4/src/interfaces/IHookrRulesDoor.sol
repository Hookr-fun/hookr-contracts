// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";

/// @title Hookr Rules, the subset a revenue token's doors use
/// @notice The functions of `HookrRules` (the standard Rules and the King of the Pool whole-pot Rules) that the revenue
///         token, the family forwarder and the state view read or call, as the release declares them: `claimable`,
///         `claim`, `claimTo` and `poolManager` from IHookrRules, `claimAsClaims` from IHookrProtocolClaimsTransfer,
///         `config` from IHookrRulesConfig, `registry` from IHookrRulesState.
/// @dev A Rules claim belongs to the address it was credited to and `claim` pays only the caller's own claim, so the
///      revenue token itself must call `claim` for what a pool's `royaltyTo` or Hook Block recipient earned it, and the
///      forwarder calls `claimTo(currency, forwarder)` for the credit the lock moved into the forwarder's claims.
interface IHookrRulesDoor {
    /// @notice The PoolManager these Rules settle through.
    /// @return The PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice The only root that binds and settles these Rules.
    /// @return The trusted root.
    function trustedRoot() external view returns (address);

    /// @notice The registry whose roots and quotes the Rules trust.
    /// @return The registry.
    function registry() external view returns (IHookrRegistry);

    /// @notice A pool's frozen native rules configuration; zero fields for an unbound pool.
    /// @param id The pool.
    /// @return The pool's rules configuration.
    function config(PoolId id) external view returns (HookrTypes.RulesConfig memory);

    /// @notice `beneficiary`'s backed claim in `currency`, raw units.
    /// @param currency The currency of the claim.
    /// @param beneficiary The account the claim belongs to.
    /// @return The claim in raw units.
    function claimable(Currency currency, address beneficiary) external view returns (uint256);

    /// @notice Pays the caller's claim in `currency` to the caller, at most 2^127 - 1 per call.
    /// @param currency The currency to claim.
    /// @return The amount paid.
    function claim(Currency currency) external returns (uint256);

    /// @notice Pays the caller's claim in `currency` to `to`: not zero, the PoolManager, the Rules or their root.
    /// @param currency The currency to claim.
    /// @param to The account paid.
    /// @return The amount paid.
    function claimTo(Currency currency, address to) external returns (uint256);

    /// @notice Moves the caller's whole claim in `currency` to `to` as PoolManager ERC-6909 claims. Moves no token.
    /// @param currency The currency to move.
    /// @param to The account that receives the claims.
    /// @return amount The amount moved.
    function claimAsClaims(Currency currency, address to) external returns (uint256 amount);
}
