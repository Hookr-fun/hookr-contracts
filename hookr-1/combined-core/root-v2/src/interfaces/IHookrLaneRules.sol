// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../types/HookrTypes.sol";

/// @title IHookrLaneRules
/// @notice The Rules half of the recapture lane: whether a pool froze recapture at bind, and the split of the
///         Hookr side of each arb recapture the root credits to the Rules module.
interface IHookrLaneRules {
    /// @notice 0: no recapture. 1: recapture. 2: recapture with King of the Pool, for which the root keeps the
    ///         same-transaction liquidity ledger. Read once by the root at initialization.
    /// @param id The pool.
    /// @return The pool's recapture mode.
    function recaptureMode(PoolId id) external view returns (uint256);

    /// @notice Splits `amount` of `currency` claims the root transferred for one arb recapture on pool `key`. Root
    ///         only. The protocol's cut comes first, in `currency`: 25% of `reportedProfit` (RECAPTURE_PROTOCOL_BPS),
    ///         at most `amount`, on every pool alike. In the pool's quote the trader leg and the King of the Pool pot
    ///         are paid as configured from the rest; in any other currency their shares join the LP share, since the
    ///         basis and the pot are quote units. An LP share in one of the pool's two currencies becomes a pending
    ///         donation to the pool's in-range liquidity (`flushRecapture`), or the liquidity owner's accrual when the
    ///         pool has no in-range liquidity; in any other currency it is the liquidity owner's accrual in that
    ///         currency.
    /// @param key The pool.
    /// @param currency The currency of the push.
    /// @param trader The after-phase's authenticated payer, or zero (every before-phase push).
    /// @param amount The claims the root transferred for the push, in `currency`.
    /// @param traderBasis The part of the push the trader's own swap can account for, in quote units: the trader leg is
    ///        paid on the rest's part of min(amount, traderBasis) of a quote push and the rest of the trader share goes
    ///        to the LP share. Zero for an arb recapture the trader's move did not open.
    /// @param reportedProfit The realized profit this push stands for, in `currency`: the push at the pool's frozen
    ///        partner share, push x 10,000 / (10,000 - partnerBps), rounded down (the root works it out; the executor's
    ///        own return is not read). A frame that pushed in several currencies calls this once per currency.
    /// @return credited Always `amount`.
    function settleRecapture(
        PoolKey calldata key,
        Currency currency,
        address trader,
        uint256 amount,
        uint256 traderBasis,
        uint256 reportedProfit
    ) external returns (uint256 credited);

    /// @notice Credits `amount` of pool `id`'s quote to `recipient`: the advisory take of one recapture executor leg on
    ///         the pool, which runs no rule. The root mints the claims to the Rules right after. Root only, and only
    ///         for a bound pool with recapture on.
    /// @param id The pool.
    /// @param recipient The account credited.
    /// @param amount The advisory take, in the pool's quote.
    /// @return credited Always `amount`.
    function settleLeg(PoolId id, address recipient, uint256 amount) external returns (uint256 credited);

    /// @notice Carries a dynamic fee pool's state for one recapture executor leg, which is charged no dynamic fee: the
    ///         reference steps or joins the anchor by the windows, and the anchor moves toward the leg's end, as for an
    ///         ordinary swap priced on `simulation` and settled with `quoteAmount` of the pool's quote. Charges and
    ///         credits nothing. Root only, called fail-open after the leg's swap: a refusal leaves the state as it was.
    /// @param context The leg as an unauthenticated swap of the executor.
    /// @param simulation The leg's start price and tick, and its end: where it stopped, or for a leg that ended at its
    ///        price limit in an empty range, the last price with liquidity, as a simulation of the swap would find it.
    /// @param quoteAmount The quote through the pool in the leg's swap delta.
    function carryLeg(
        HookrTypes.SwapContext calldata context,
        HookrTypes.SwapSimulation calldata simulation,
        uint256 quoteAmount
    ) external;

    /// @notice Releases the pool's LP share accrued before this L2 block (ArbSys.arbBlockNumber()), each part x min(L2
    ///         blocks since its release block, the pool's releaseBlocks) / releaseBlocks, rounded up (a share is
    ///         released from the L2 block after it accrued, what is left of it from the last flush; the blocks counted
    ///         are capped at 10 a second of block.timestamp plus one second's worth), and donates it to
    ///         the pool's in-range liquidity (PoolManager.donate, settled by burning the Rules' own claims), or moves
    ///         it to the liquidity owner's accrual when the pool has no in-range liquidity. Root only, inside the
    ///         PoolManager's unlock and outside any lane frame: before every liquidity add and removal lands and at the
    ///         start of every outer swap.
    /// @param key The pool.
    /// @return pending Whether any share is still pending after the call.
    function flushRecapture(PoolKey calldata key) external returns (bool pending);

    /// @notice Credits `amount` of `currency` claims the root just transferred to the protocol recipient's claim
    ///         (IHookrLaneRoot.sweepClaims). Root only.
    /// @param currency The currency swept.
    /// @param amount The amount of claims transferred.
    function creditSweep(Currency currency, uint256 amount) external;
}
