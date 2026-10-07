// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BestRouteTypes} from "../HookrBestRouteTypes.sol";

/// @title Hookr best-route quote surface
/// @notice A typed, ERC-165-detectable quote surface: compare a Hookr pool with Uniswap v3 and hookless v4
///         venues for one exact-input trade, and build the one Universal Router call that executes a route.
/// @dev `quote` and `quoteRoute` simulate swaps and revert every simulated state change; call them with
///      `eth_call`. They are not `view` because the simulations call the pools.
interface IHookrBestRoute {
    /// @notice Quotes the Hookr pool and every alternative, picks the best and decides whether to offer it.
    function quote(BestRouteTypes.Request calldata request) external returns (BestRouteTypes.Result memory result);

    /// @notice Quotes one explicit route for `amountIn`.
    function quoteRoute(BestRouteTypes.Step[] calldata steps, uint128 amountIn, address payer, uint32 gasBudget)
        external
        returns (BestRouteTypes.RouteQuote memory route);

    /// @notice Builds the Universal Router call for one explicit route.
    function planRoute(
        BestRouteTypes.Step[] calldata steps,
        address currencyIn,
        address currencyOut,
        uint128 amountIn,
        uint128 minAmountOut,
        uint64 deadline
    ) external view returns (BestRouteTypes.Plan memory plan);

    /// @notice Which approval `owner` still needs before the router can pull `amount` of `token` until `deadline`.
    function approvalNeed(address owner, address token, uint256 amount, uint64 deadline)
        external
        view
        returns (BestRouteTypes.ApprovalNeed);
}
