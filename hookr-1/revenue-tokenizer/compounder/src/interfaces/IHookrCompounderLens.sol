// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHookrRevenueCompounder} from "./IHookrRevenueCompounder.sol";

/// @title Hookr compounder lens
/// @notice The reads of a compounder that a front end wants and the compounder itself does not carry: the fees its
///         bands have earned and not realized, what the next deposit or redeem sees, previews of both, and every
///         fixed term at once. Stateless; one lens serves every compounder on a chain.
interface IHookrCompounderLens {
    /// @notice A compounder's fixed terms.
    /// @param token The revenue token.
    /// @param key The pool.
    /// @param tokenIsCurrency0 Whether the token is the pool's currency0.
    /// @param bandTicks The width of a band in ticks.
    /// @param tipBps The poker's tip, in basis points of the quote a poke gathers.
    /// @param tipCap The most a poke tips, in quote units.
    struct Terms {
        address token;
        PoolKey key;
        bool tokenIsCurrency0;
        int24 bandTicks;
        uint16 tipBps;
        uint128 tipCap;
    }

    /// @notice Every fixed term of `vault` at once.
    function terms(IHookrRevenueCompounder vault) external view returns (Terms memory);
    /// @notice The fees `vault`'s bands have earned and not yet realized.
    function pendingFees(IHookrRevenueCompounder vault) external view returns (uint256 tokens, uint256 quote);
    /// @notice What `vault`'s next deposit or redeem sees: its holdings plus its pending fees plus the quote it can
    ///         claim from the revenue token now.
    function totals(IHookrRevenueCompounder vault) external view returns (uint256 tokens, uint256 quote);
    /// @notice The shares `vault.deposit(tokensMax, quoteMax, ...)` would mint now and what it would take.
    function previewDeposit(IHookrRevenueCompounder vault, uint256 tokensMax, uint256 quoteMax)
        external
        view
        returns (uint256 shares, uint256 tokens, uint256 quote);
    /// @notice What `vault.redeem(shares, ...)` would pay now, to the rounding of each band.
    function previewRedeem(IHookrRevenueCompounder vault, uint256 shares)
        external
        view
        returns (uint256 tokens, uint256 quote);
}
