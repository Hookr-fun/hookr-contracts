// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHookrLaneEvents} from "./IHookrLaneEvents.sol";
// Re-exported: `import {IHookrLaneExecutor} from "IHookrLaneRoot.sol"` keeps compiling for executor harnesses.
import {IHookrLaneExecutor} from "./callback/IHookrLaneExecutor.sol";

/// @title IHookrLaneRoot
/// @notice A pool whose Rules froze recapture at bind freezes the registry lane of its root (executor, runtime
///         codehash, partner share) and the family its launcher reported, at initialization. On each of its swaps the
///         root reads the executor's live switch from the registry once: while it is on, the root runs the lane in a
///         self-called frame before the swap and after it, each with exactly the switch's gas cap, and a swap that
///         reaches the lane with less than the gas floor (`laneOf`) reverts. The floor funds both calls and the
///         swap's work between them whatever the before-phase spends, so an `eth_estimateGas` limit funds the mined
///         swap too. A route through several lane pools of the root must bring the sum of their floors to its first
///         lane swap (a later one requires its own floor plus the earlier floors less what the transaction spent since
///         the first check), so the estimate of such a route funds the mined route, and every lane swap of it runs
///         both arb recaptures. No lane runs in the transaction that initialized the pool. A before-phase arb
///         recapture credits no trader; an after-phase one credits the swap's authenticated payer with the part of
///         the push its own swap accounts for (its quote times its own price move), only when the arb recapture
///         undid its move.
interface IHookrLaneRoot is IHookrLaneEvents {
    /// @notice The pool's frozen lane and its live switch. Zeros for a pool without a lane.
    /// @param id The pool.
    /// @return executor The frozen executor.
    /// @return codeHash The executor's frozen runtime codehash; the lane is skipped while the executor's code differs.
    /// @return partnerBps The frozen partner share: the part of an arb recapture's profit the executor keeps, from
    ///         which each push's profit is taken.
    /// @return family The frozen family: legs on the pool's lane siblings with the same family and executor are
    ///         arb recapture legs. Zero: legs only on the pool itself.
    /// @return on Whether the executor's switch on this root is on.
    /// @return gasCap The switch's gas per lane call.
    /// @return gasFloor The gas a swap on the pool must carry when it reaches the lane while the switch is on (the
    ///         before-phase's whole grant, 600,000 for its split and the swap's own work until the after-phase, and
    ///         the after-phase's floor `cap + cap/63 + 155,000`: `2 × cap + cap/63 + 755,000`), else zero. A router
    ///         sends at least this plus the swap's own gas up to the lane, and a route through several lane pools of
    ///         the root the sum of their floors plus its own gas, which `eth_estimateGas` finds.
    function laneOf(PoolId id)
        external
        view
        returns (
            address executor,
            bytes32 codeHash,
            uint16 partnerBps,
            bytes32 family,
            bool on,
            uint32 gasCap,
            uint256 gasFloor
        );

    /// @notice What a recapture leg of `params` on `key`, sent by the caller, would pay the pool's advisory: the advisory
    ///         asked in each phase it is bound for as the leg asks it, the caller as sender, payer and beneficiary,
    ///         unauthenticated, from the current state. The root's own code, not the lane's. Writes nothing (declared
    ///         non-view because it makes the advisory's bounded calls). Only a `staticcall` inside the frame, right
    ///         before the leg, sees the leg's state; an `eth_call` from the executor's address is an estimate, which an
    ///         advisory that reads the PoolManager's lock or anything else the frame changes can answer differently.
    ///         Bound the worst case with the pool's caps instead (`poolConfig`: the LP cap and the quote cap, and the
    ///         advisory's admitted quote cap in the registry), and settle on the leg's actual delta. Each phase asked
    ///         can spend the pool's `advisoryGasLimit`: give the call at least `2 × (limit + limit / 63) + 60,000`.
    ///         Even inside the frame the after phase is asked on the pool's state before the swap, not after it: its
    ///         answer is the leg's only for an advisory whose after phase depends on the amounts passed alone. One that
    ///         reads the price, tick, liquidity or anything else the swap changes (a band that refuses a swap ending
    ///         out of range, a tax priced on where the swap ends) can pass or price the quote and refuse or charge the
    ///         leg differently. The root cannot see what an advisory reads, so `afterPreSwap` is set whenever the after
    ///         phase was asked. For the leg's exact outcome from any advisory, run the leg inside the frame in a call
    ///         that swaps and reverts with its result, then swap for real.
    ///         Reverts `NotALeg` unless the pool is a lane pool whose frozen executor is the caller and, inside a frame,
    ///         the frame's executor is the caller and the pool is the frame's pool or a lane sibling of its family;
    ///         the frame's per-leg gates (one direction per pool, at most 7 siblings) are not
    ///         checked. Reverts where the leg would be refused: `SwapRejected`, `ModuleCallReverted` with the first 132
    ///         bytes of its revert data from a strict advisory that reverts with data, `ModuleCallFailed` from one that
    ///         fails otherwise, `InvalidModuleResult` for an answer the root refuses, `AggregateCapExceeded`.
    ///         Selector `quoteLeg((address,address,uint24,int24,address),(bool,int256,uint160),int128,int128)`,
    ///         `0xba835629`.
    /// @param key The lane pool the leg swaps on.
    /// @param params The leg's swap parameters.
    /// @param amount0 With `amount1`, the pool's own swap delta for the leg, the `BalanceDelta` the root's afterSwap
    ///        receives and the PoolManager's `Swap` event carries, before the root's charges: not what
    ///        `PoolManager.swap` returns to the executor. With `A` the specified input, `Q` the specified output and
    ///        `t` the before-phase take in pips: an exact-input buy's specified side is `-(A - floor(A × t / 1e6))`; an
    ///        exact-output sell's is `Q + ceil(Q × t / (1e6 - t))`; an exact-output buy's is `Q` and an exact-input sell's
    ///        `-A`. The unspecified side is the pool's own, before an exact-input sell's or exact-output buy's take. Simulate
    ///        the pool's swap of that specified amount at the quoted `lpFeePips`. Both zero: the after phase is not
    ///        asked (`afterSkipped`).
    /// @param amount1 The pool's other swap delta, as `amount0` describes.
    /// @return lpFeePips The LP fee the leg pays: the base fee plus the advisory's surcharge.
    /// @return takePips The advisory's quote take over the phases asked, in pips. With `t` this take, an exact-input
    ///         buy pays `floor(A × t / 1e6)` of its specified input `A`, an exact-output buy pays
    ///         `floor(q × 1e6 / (1e6 - t)) - q` beside the quote `q` that filled, an exact-input sell pays
    ///         `floor(Q × t / 1e6)` of the gross quote `Q` out, and an exact-output sell pays `ceil(Q × t / (1e6 - t))`
    ///         on top of its specified output `Q`.
    /// @return recipient The account the take is credited to in the pool's Rules.
    /// @return fullPath True for a buy leg during the pool's launch guard, which pays the trader's whole path instead:
    ///         price it with the Hookr quoter.
    /// @return afterSkipped True when the pool's advisory is bound for the after phase and was not asked because both
    ///         amounts are zero: `takePips` covers the before phase alone, and an after-phase take or refusal is not in
    ///         it. Quote again with the pool's swap delta.
    /// @return afterPreSwap True when the after phase was asked: on the pool's state before the swap, so its take and
    ///         refusal are the leg's only for an advisory whose after phase reads the amounts alone. Bound the rest with
    ///         the caps above, or run the leg as a reverting trial inside the frame.
    function quoteLeg(PoolKey calldata key, SwapParams calldata params, int128 amount0, int128 amount1)
        external
        returns (
            uint24 lpFeePips,
            uint24 takePips,
            address recipient,
            bool fullPath,
            bool afterSkipped,
            bool afterPreSwap
        );

    /// @notice The module this root delegates its cold paths to (initialization and the lane) and that module's
    ///         runtime codehash, both fixed in the root's runtime code. The registry checks them at registration.
    /// @return module The lane module.
    /// @return codeHash The module's runtime codehash.
    function laneModule() external view returns (address module, bytes32 codeHash);

    /// @notice Receives the Hookr side of one arb recapture: `amount` of `currency`, which the executor minted to this
    ///         root as PoolManager ERC-6909 claims right before. Only the frozen executor, inside an open frame on
    ///         `key`, in `key.currency0`, `key.currency1` or a member of the registry's settlement set
    ///         (`IHookrLanes.settlementCurrencies`, read when the frame opens), backed by claims minted since the frame
    ///         opened. Pushes add up per currency, a frame may push in several currencies, and legs may run between
    ///         pushes; each currency's push is split on its own when the executor returns, as the profit the push
    ///         stands for at the pool's frozen partner share (push x 10,000 / (10,000 - partnerBps)). A claim minted to
    ///         the root and not pushed reverts the frame. The value `executeArbitrage` returns is not read for money.
    ///         Selector `settleRecapture((address,address,uint24,int24,address),address,uint256)`.
    /// @param key The lane pool whose frame is open.
    /// @param currency The currency of the push.
    /// @param amount The amount pushed, which the executor minted to the root as claims right before.
    function settleRecapture(PoolKey calldata key, Currency currency, uint256 amount) external;

    /// @notice Moves every ERC-6909 claim of `currency` this root holds to the Rules of lane pool `id` as a claim of
    ///         their protocol recipient. Permissionless; refused while a swap, a pool binding or a frame is active.
    ///         The root holds no claims at rest, so it reaches only claims minted to it outside a push.
    /// @param id The lane pool whose Rules receive the claims.
    /// @param currency The currency to move.
    /// @return amount The amount moved.
    function sweepClaims(PoolId id, Currency currency) external returns (uint256 amount);

    /// @notice True when liquidity added to `id` in this transaction overlaps the current swap's path above the
    ///         tolerance. King of the Pool pools only; false elsewhere.
    /// @param id The pool.
    /// @return True when liquidity added in this transaction overlaps the swap's path.
    function sameTxLiquidityOnPath(PoolId id) external view returns (bool);
}
