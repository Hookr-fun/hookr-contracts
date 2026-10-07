// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IHookrAdvisoryFeeCounter
/// @notice The advisory fees a Rules module credited on each pool's swaps, so a recipient whose Rules claim also holds
///         other credits can tell one pool's advisory revenue from the rest. HookrRules serves it from its fallback
///         through its HookrRecapture module, so its selector stays out of the dispatcher of the swap calls.
/// @dev Day-one consumer: a per-pool revenue vault. Rules
///      claims are kept per currency and account across every pool, so the vault's claim can also hold another pool's
///      advisory fees or a royalty that names it; the vault books as this pool's revenue at most the counter less
///      what it already booked for the pool, and the rest of what it realizes as surplus. The counter does not tell
///      recipients apart, so it is a recipient's revenue only where that recipient is the pool's one advisory
///      recipient, as that vault is (its tax advisory binds only with the vault as recipient).
///      Invariants:
///      - The counter of pool `id` moves only when HookrRules.settleSwap credits a nonzero advisory fee on the pool:
///        the quote take the pool's admitted advisory charged on a swap, by exactly the amount credited to the
///        advice's recipient, in raw units of the pool's quote.
///      - It only grows: a claim paid out, or any other credit, leaves it as it is.
///      - It never moves funds and backs nothing: claims and liabilities are what HookrRules owes.
///      - A swap without an advisory fee, and every other entry point, never reads or writes it. An arb recapture
///        executor leg's advisory take (IHookrLaneRules.settleLeg, inside the executor's gas-capped call) is credited
///        to the advice's recipient like a swap's but is not counted; its FeesAllocated event reports it.
///      Inert until an advisory that takes quote is admitted through the registry's timelock and a pool binds it.
interface IHookrAdvisoryFeeCounter {
    /// @notice Every advisory fee HookrRules credited on pool `id`'s swaps since its bind, in raw units of the pool's
    ///         quote: the quote take its advisory charged on each swap, credited to the advice's recipient as a Rules
    ///         claim: the sum of `advisoryFee` over the FeesAllocated events of the pool's swaps, without the takes of
    ///         executor legs, which FeesAllocated also reports. Zero for an unbound pool and for a pool whose advisory
    ///         never took quote on a swap.
    /// @param id The pool.
    /// @return The advisory fees credited on the pool's swaps, in raw units of the pool's quote.
    function advisoryFeeCredited(PoolId id) external view returns (uint256);
}
