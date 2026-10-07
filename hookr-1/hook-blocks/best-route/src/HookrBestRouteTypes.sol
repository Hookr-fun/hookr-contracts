// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";

/// @title Hookr best-route types
/// @notice Shared shapes for comparing one exact-input trade on a Hookr pool with Uniswap v3 fee tiers,
///         hookless Uniswap v4 pools and one-hop paths through ETH or USDG, and for the one Universal Router
///         call that executes the chosen route.
/// @dev Currencies are plain addresses. On a v4 or Hookr step the zero address is native ETH. On a v3 step
///      both currencies are ERC-20 tokens, so native ETH appears there as WETH; the planner wraps and unwraps
///      between legs and at the ends.
library BestRouteTypes {
    /// @notice The venue one step trades on.
    /// @dev V3: a canonical Uniswap v3 pool, addressed by CREATE2 from the factory and the fee tier.
    ///      V4: a hookless Uniswap v4 pool on the pinned PoolManager. HOOKR: a pool of a registered Hookr root.
    enum Venue {
        V3,
        V4,
        HOOKR
    }

    /// @notice Why a route has, or does not have, a usable quote.
    /// @dev OK: fully filled at a positive output. NO_POOL: the pool does not exist or the step is not a venue
    ///      this contract quotes. NO_LIQUIDITY: the swap filled at zero output. PARTIAL_FILL: the venue consumed
    ///      less than the input, so executing it would strand the rest; it is never offered. FAILED: the venue
    ///      reverted or answered malformed data. OVER_BUDGET: the simulation ran out of its gas budget.
    ///      SKIPPED: the call did not have enough gas left to give the route its budget; raise the call gas.
    ///      BRAKED: a step of the route touches an asset the registry brakes as a quote
    ///      (`brakeOneQuoteInstantly`); it is not simulated and never planned.
    enum Status {
        OK,
        NO_POOL,
        NO_LIQUIDITY,
        PARTIAL_FILL,
        FAILED,
        OVER_BUDGET,
        SKIPPED,
        BRAKED
    }

    /// @notice One swap on one pool.
    /// @param venue The venue kind.
    /// @param currencyIn What goes in. v3: an ERC-20 (WETH for ETH). v4 and HOOKR: the pool currency.
    /// @param currencyOut What comes out, with the same convention.
    /// @param fee The v3 fee tier or the v4 PoolKey fee (the dynamic-fee flag for a Hookr pool).
    /// @param tickSpacing The v4 tick spacing; zero on v3.
    /// @param hooks The v4 hook: zero for a hookless pool, the root for a Hookr pool, zero on v3.
    struct Step {
        Venue venue;
        address currencyIn;
        address currencyOut;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// @notice One route and its simulated result.
    /// @param steps One or more steps, in execution order.
    /// @param status The quote status; only OK routes are compared.
    /// @param amountOut Output of the last step in its currency; zero unless OK or PARTIAL_FILL.
    /// @param amountInUsed Input the first step consumed.
    /// @param gasUsed Gas the simulation spent, a proxy for the execution cost of the swaps.
    struct RouteQuote {
        Step[] steps;
        Status status;
        uint256 amountOut;
        uint256 amountInUsed;
        uint256 gasUsed;
    }

    /// @notice One exact-input comparison for the Hookr pool on screen.
    /// @param hookrKey The Hookr pool's key. Its hook must be a registered root that initialized it.
    /// @param zeroForOne The trade direction in the Hookr pool: currency0 in when true.
    /// @param amountIn The exact input, raw units of the input currency, at most type(int128).max.
    /// @param slippageBps The trader's tolerance in basis points, at most MAX_SLIPPAGE_BPS.
    /// @param payer The identity the Hookr pool is quoted for; zero quotes for this contract.
    /// @param routeGas Gas budget per route simulation; zero means DEFAULT_ROUTE_GAS.
    /// @param hookrGas Gas budget for the Hookr pool's quote; zero means DEFAULT_HOOKR_GAS.
    /// @param deadline Unix seconds written into the Universal Router call; must not be in the past.
    /// @param offerMarginBps How far the best route must beat the Hookr pool to be offered, in basis points of the
    ///        Hookr quote, within [MIN_OFFER_MARGIN_BPS, MAX_OFFER_MARGIN_BPS]. Zero selects the default rule:
    ///        more than half the slippage.
    struct Request {
        PoolKey hookrKey;
        bool zeroForOne;
        uint128 amountIn;
        uint16 slippageBps;
        address payer;
        uint32 routeGas;
        uint32 hookrGas;
        uint64 deadline;
        uint16 offerMarginBps;
    }

    /// @notice The single Universal Router call that executes one route.
    /// @dev The trader sends `data` to `target` with `value` as msg.value. Output always goes to the account
    ///      that calls `execute`, and input is only ever pulled from that account (Permit2) or taken from
    ///      msg.value, so the call moves no one else's funds.
    /// @param laneGasFloor The sum of the recapture-lane entry floors of the route's Hookr steps whose lane is on
    ///        (`IHookrLaneRoot.laneOf`): what the route must still carry when it reaches its first lane swap. Zero
    ///        when the route touches no lane pool.
    /// @param gasLimit The least transaction gas limit to send the plan with when `laneGasFloor` is nonzero: the
    ///        floor plus the router's own work and the 1/64 each call keeps back (`laneRouteGas`). A lower limit
    ///        reverts `InsufficientLaneGas` in the root. Zero when the route touches no lane pool: estimate it.
    struct Plan {
        address target;
        uint256 value;
        bytes commands;
        bytes[] inputs;
        uint256 deadline;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes data;
        uint256 laneGasFloor;
        uint256 gasLimit;
    }

    /// @notice The comparison, the decision and, when the decision is yes, the plan.
    /// @param currencyIn The trader's input currency (a v4 currency: native ETH is zero).
    /// @param currencyOut The trader's output currency.
    /// @param hookr The Hookr pool's own quote, through the pinned HookrQuoter.
    /// @param routes Every alternative quoted, direct routes first, then one-hop routes by intermediate.
    /// @param best Index into `routes` of the best OK route, or NONE.
    /// @param gainBps The best route's output over the Hookr pool's, in basis points, clamped to +/-1e6.
    /// @param executable Whether the best route beats the Hookr pool by more than the request's offer margin.
    /// @param minAmountOut The best route's output less the slippage; zero unless executable.
    /// @param plan The Universal Router call for the best route; empty unless executable.
    /// @param quoteBadge The registry's badge for the Hookr pool's quote currency (`badgeForQuote`): NATIVE,
    ///        CATALOG and CLASS are reviewed; UNREVIEWED is an any-quote asset the app labels as unreviewed; NONE is
    ///        a quote that no longer qualifies for new pools (a brake, a dropped class or any-quote mode off).
    /// @param quoteBraked Whether either currency of the trade is braked as a quote. Then no alternative is quoted
    ///        and nothing is offered: the quoter never routes into or out of a braked quote.
    /// @param laneGasFloor The Hookr pool's recapture-lane entry floor while its lane is on, else zero. The Hookr
    ///        quote ran with at least `laneQuoteGas(laneGasFloor)`; a swap on the pool must carry the floor.
    struct Result {
        address currencyIn;
        address currencyOut;
        RouteQuote hookr;
        RouteQuote[] routes;
        uint256 best;
        int256 gainBps;
        bool executable;
        uint256 minAmountOut;
        Plan plan;
        IHookrRegistry.QuoteBadge quoteBadge;
        bool quoteBraked;
        uint256 laneGasFloor;
    }

    /// @notice Which approval an ERC-20 input still needs before the Universal Router can pull it.
    enum ApprovalNeed {
        NONE,
        ERC20_TO_PERMIT2,
        PERMIT2_TO_ROUTER
    }

    /// @notice The zero-based index that means "no route".
    uint256 internal constant NONE = type(uint256).max;
}
