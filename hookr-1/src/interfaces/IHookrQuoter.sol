// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrRegistry} from "./IHookrRegistry.sol";
import {IHookrRouter} from "./IHookrRouter.sol";

/// @title IHookrQuoter
/// @notice Interface for HookrQuoter, which simulates a swap on a Hookr pool. Every quote runs the swap as the root's
///         pinned router executes it, through the root's hooks and both arb recapture phases, inside a PoolManager
///         unlock that always reverts, so no state survives a quote. Besides the router-shaped `quote` and
///         `quoteDetailed`, it answers aggregators in Uniswap IV4Quoter's single-pool shape. The root has no quote mode:
///         it refuses hook data from every sender but its pinned router and quoter, so what a quote reports is what an
///         executing swap by the same payer at the same state gets, and no executing swap can skip an arb recapture.
/// @dev On an arb recapture pool the root asks its executor's MEV view (`checkV3PoolsMev`) with this quoter as the
///      swapper, where execution names the router or the PoolManager's locker; an executor that answers differently
///      for the quoter makes its pool's quotes differ from execution.
interface IHookrQuoter is IUnlockCallback {
    /// @notice A simulation request: the swap and the identity it is quoted for.
    struct Request {
        /// @notice The swap, as HookrRouter takes it.
        IHookrRouter.Swap params;
        /// @notice The payer: the identity the root authenticates (hook data payer, receipt payer, claim owner).
        address payer;
    }

    /// @notice The single-pool quote parameters of Uniswap's IV4Quoter.
    struct QuoteExactSingleParams {
        /// @notice The pool. Its hooks are a registered Hookr root that pins this quoter.
        PoolKey poolKey;
        /// @notice The direction: true sells currency0 for currency1, false sells currency1 for currency0.
        bool zeroForOne;
        /// @notice The exact input of `quoteExactInputSingle` or the exact output of `quoteExactOutputSingle`; not
        ///         zero and at most int128's maximum.
        uint128 exactAmount;
        /// @notice Must be empty: a Hookr root refuses hook data from every sender but its pinned router and quoter,
        ///         so there is no flag to pass.
        bytes hookData;
    }

    /// @notice The quote is malformed, runs inside another quote or names a pool this quoter cannot simulate: its
    ///         hooks are not a registered root of this quoter's PoolManager that pins this quoter and initialized the
    ///         pool, or the swap fails the root's router's field checks. Inside the simulation, a fill outside the swap's
    ///         bounds, returned wrapped in `SimulationFailed`.
    error InvalidQuote();
    /// @notice A single-pool quote carried hook data. The root refuses non-empty hook data from any other locker with
    ///         its own `InvalidHookData`, so no executing swap can carry it either.
    error InvalidHookData();
    /// @notice A single-pool exact-input quote would only fill part of its input, as Uniswap's V4Quoter reports it.
    /// @param poolId The pool.
    error NotEnoughLiquidity(PoolId poolId);
    /// @notice The result of a detailed simulation: the swap's receipt and the payer's arb recapture claim it credited.
    /// @param receipt The swap's execution receipt.
    /// @param traderClaim The payer's claim the swap credited, as `quoteDetailed` returns it.
    error QuoteDetail(HookrTypes.ExecutionReceipt receipt, uint256 traderClaim);

    /// @notice `unlockCallback` or `simulate` was called outside a quote's own frame.
    error InvalidCallback();

    /// @notice The simulated swap reverted with `reason`.
    /// @param reason The revert data of the swap's frame.
    error SimulationFailed(bytes reason);

    /// @notice The result of a simulation, the only way it leaves the reverting frame: the swap's receipt.
    /// @param receipt The swap's execution receipt.
    error QuoteResult(HookrTypes.ExecutionReceipt receipt);

    /// @notice Returns the PoolManager whose pools this quoter simulates.
    /// @return The immutable Uniswap v4 PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns the registry whose roots this quoter simulates.
    /// @return The immutable Hookr admission registry.
    function registry() external view returns (IHookrRegistry);

    /// @notice Returns simulated execution accounting (0x55f5bdd3). All pool and hook state changes revert.
    /// @dev The quote runs the swap as the pool would, dynamic fee included, against the pool's dynamic fee state at
    ///      the quote's block and timestamp. A trade that lands first can raise the fee. Apps should keep a slippage
    ///      buffer. Before simulating, the quote applies the router's own field checks (HookrSwapPreflight) against
    ///      the root's router and that router's forwarder, so a swap the router refuses on those grounds is never
    ///      quoted. Bounds read as on the router's `swap`: a relayed `swapFor` takes its outputFee from the output, so
    ///      quote it with the gross minimum. A quote is not proof of execution: balances, approvals and pool state
    ///      can change.
    /// @param params The pool, direction, amount, bound, price limit, recipient and deadline of the swap.
    /// @param payer The identity the swap is quoted for; not zero.
    /// @return receipt The swap's execution receipt.
    function quote(IHookrRouter.Swap calldata params, address payer)
        external
        returns (HookrTypes.ExecutionReceipt memory receipt);

    /// @notice `quote` with the payer's arb recapture claim and the simulation's gas (0x3d8d5b2a). All state changes
    ///         revert.
    /// @dev `traderClaim` is the rise of the pool Rules' `claimable(quote, payer)` across the simulated swap, less the
    ///      receipt's `quoteRefund` (a partial fill's refund, credited to the payer in the same currency), never
    ///      below zero. It is what the swap's after-phase arb recapture credits the payer (RecaptureSplit's
    ///      traderAmount), since the before-phase credits no trader and a push in any currency but the quote pays no
    ///      trader share. A payer that is also one of the pool's fee recipients (royalty, integrator, advisory or
    ///      protocol), or the leader of a King of the Pool epoch the swap closes, sees that credit in it too.
    ///      Execution credits the claim to the swap's authenticated payer (the caller of HookrRouter, the signer the
    ///      forwarder relays for, or the account the root's curated router reports), so it matches `payer` only for
    ///      that payer's swap; an unauthenticated swap credits no trader.
    /// @param params The pool, direction, amount, bound, price limit, recipient and deadline of the swap.
    /// @param payer The identity the swap is quoted for; not zero.
    /// @return receipt The swap's execution receipt, as `quote` returns it.
    /// @return traderClaim The payer's arb recapture claim the swap credited, in the pool's quote.
    /// @return gasEstimate The gas the simulation used, from the unlock to its revert: a cost, not a gas limit (a swap
    ///         on an arb recapture pool needs a gas limit of at least the lane's entry floor, `IHookrLaneRoot.laneOf`,
    ///         whatever it uses).
    function quoteDetailed(IHookrRouter.Swap calldata params, address payer)
        external
        returns (HookrTypes.ExecutionReceipt memory receipt, uint256 traderClaim, uint256 gasEstimate);

    /// @notice Uniswap IV4Quoter's exact-input single-pool quote (0xaa9d21cb): the output a swap of `exactAmount` in
    ///         delivers. All state changes revert.
    /// @dev `msg.sender` is the payer and the recipient: the address that will call HookrRouter, or lock the
    ///      PoolManager, when the swap executes. The swap has no price limit, no minimum output beyond one unit and
    ///      a deadline of now. Both arb recapture phases run as in execution. The after-phase never changes the
    ///      amount out, since the root fixes the swap's delta before it runs, so the amount is exact without any
    ///      flag; the trader's share of an arb recapture arrives as a claim (`quoteDetailed`). Quoted from the
    ///      Universal Router's address, a full fill, which owes no refund, equals that router's execution. A swap that
    ///      would only fill part of the input reverts `NotEnoughLiquidity`; `quote` reports the partial fill
    ///      HookrRouter would make.
    /// @param params The pool, direction and exact input; `hookData` must be empty.
    /// @return amountOut The output the swap delivers.
    /// @return gasEstimate The gas the simulation used, from the unlock to its revert: a cost, not a gas limit (a swap
    ///         on an arb recapture pool needs a gas limit of at least the lane's entry floor, `IHookrLaneRoot.laneOf`,
    ///         whatever it uses).
    function quoteExactInputSingle(QuoteExactSingleParams calldata params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);

    /// @notice Uniswap IV4Quoter's exact-output single-pool quote (0x58733073): the input a swap of `exactAmount` out
    ///         takes. All state changes revert.
    /// @dev As `quoteExactInputSingle`, with no maximum input. A swap that cannot deliver the whole output reverts,
    ///      as HookrRouter's would.
    /// @param params The pool, direction and exact output; `hookData` must be empty.
    /// @return amountIn The input the swap takes.
    /// @return gasEstimate The gas the simulation used, from the unlock to its revert: a cost, not a gas limit, as for
    ///         `quoteExactInputSingle`.
    function quoteExactOutputSingle(QuoteExactSingleParams calldata params)
        external
        returns (uint256 amountIn, uint256 gasEstimate);

    /// @notice Runs the committed simulation (0x74d3cd90). Only this quoter can call, inside its own unlock.
    /// @param request The swap and its payer.
    /// @return receipt The swap's execution receipt.
    function simulate(Request calldata request) external returns (HookrTypes.ExecutionReceipt memory receipt);
}
