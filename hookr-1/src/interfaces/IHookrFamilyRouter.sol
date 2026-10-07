// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRouter} from "./IHookrRouter.sol";
import {IHookrSwapGate} from "./IHookrSwapGate.sol";
import {IHookrLauncherView} from "./IHookrLauncherView.sol";

/// @title IHookrFamilyRouter
/// @notice Interface for HookrFamilyRouter, the best-route family mode of a Multi-pool launch: one trade, in one input
///         currency and one output currency, split across the pools of one HookrLauncher family, with every leg's
///         minimum and the trade's total minimum checked on chain and all legs or none.
/// @dev A family's members are its subject paired with distinct quote assets (HookrLauncher refuses two members with
///      one quote), so a trade reaches a member quoted in an asset other than its own currency by converting through
///      a reference pool the leg names: on a buy the leg's input converts into the member's quote before the member's
///      swap, on a sell the member's quote output converts into the trade's output after it. A member quoted in the
///      trade's own currency (the input on a buy, the output on a sell) takes no conversion. A reference pool is a
///      hookless Uniswap v4 pool, which this router swaps in its own PoolManager unlock, or a pool of a registered
///      Hookr root that names HookrRouter and admitted this router as its GATE, which it swaps through the router's
///      gated swap like a member; any other hooked pool is refused, since its hook could hold back value this router
///      could not pass on.
///      Every swap on a Hookr pool runs through HookrRouter.swapGated with this router as the funder and as the gate
///      the pool's root admitted (kind GATE), vouching only for the account that called `trade`, so the root records
///      that trader for receipts, Programs credit, compliance and Rules claims (its arb recapture share, refunds).
///      This router is inert until a queued `ADMIT` of kind GATE for it executes on a root: until then, and while a
///      brake holds that root closed (`IHookrRegistry.rootReopenable`), HookrRouter refuses every leg on that root.
///      Invariants: the caller pays exactly the sum of the legs' inputs (balance delta, so a fee-on-transfer input is
///      refused; native: the call's value equals it); each swap uses all of its input (a partial fill reverts); every
///      leg's output reaches the recipient, at least its minimum, and their sum at least the trade's minimum; this
///      router's balance of every currency the trade touched ends where it started, so no dust stays here; one leg's
///      failure reverts the whole trade (no try/catch). Each leg's swap is the first of its own PoolManager unlock, so
///      an arb recapture leg needs its lane's entry floor (IHookrLaneRoot) left when it starts, on top of what the legs
///      before it spent.
interface IHookrFamilyRouter is IHookrSwapGate {
    /// @notice One leg of a family trade.
    struct Leg {
        /// @notice The member pool: a pool HookrLauncher launched in the trade's family, named once per trade.
        PoolKey key;
        /// @notice The conversion pool, or all zero for a member quoted in the trade's own currency: on a buy its two
        ///         currencies are the trade's input and the member's quote, on a sell the member's quote and the
        ///         trade's output. Hookless, or a pool of a registered Hookr root that names HookrRouter.
        PoolKey conversion;
        /// @notice The leg's input in the trade's input currency, all of it swapped; nonzero.
        uint128 amountIn;
        /// @notice The least output of the leg in the trade's output currency.
        uint128 minOut;
        /// @notice The program ids the member swap is recorded for through the trade's engagement sink: none without
        ///         one, 1 to 8 with one.
        uint256[] campaigns;
    }

    /// @notice A trade across the pools of one family.
    struct FamilyTrade {
        /// @notice The HookrLauncher family whose pools the legs trade.
        bytes32 familyId;
        /// @notice The currency the caller pays: a quote asset on a buy, the family's subject on a sell. Zero is
        ///         native.
        Currency input;
        /// @notice The currency the recipient receives: the family's subject on a buy, a quote asset on a sell.
        Currency output;
        /// @notice The legs, 1 to 8, executed in order.
        Leg[] legs;
        /// @notice The least sum of the legs' outputs.
        uint256 minTotalOut;
        /// @notice The receiver of every leg's output; not zero, this router, HookrRouter or the PoolManager. A sell
        ///         with a converting leg pays the caller only: that leg's member swap pays this router, so the member
        ///         pool's compliance screens the caller as its payer and could not screen another recipient.
        address recipient;
        /// @notice The last timestamp, in seconds, at which the trade may execute.
        uint256 deadline;
        /// @notice Zero, or the Programs receipt sink HookrRouter records each member swap for its leg's campaigns.
        address engagement;
    }

    /// @notice One leg of a family trade ran: `amountIn` of the trade's input paid for `amountOut` of its output.
    /// @param familyId The family.
    /// @param member The member pool.
    /// @param conversion The reference pool the leg converted through; zero for none.
    /// @param amountIn The leg's input in the trade's input currency.
    /// @param amountOut The leg's output in the trade's output currency.
    event FamilyLeg(
        bytes32 indexed familyId, PoolId indexed member, PoolId indexed conversion, uint256 amountIn, uint256 amountOut
    );

    /// @notice A family trade completed.
    /// @param familyId The family.
    /// @param trader The caller: the payer of the input and the identity of every Hookr swap.
    /// @param recipient The receiver of the output.
    /// @param input The currency paid.
    /// @param output The currency received.
    /// @param amountIn The sum of the legs' inputs.
    /// @param amountOut The sum of the legs' outputs.
    event FamilyTraded(
        bytes32 indexed familyId,
        address indexed trader,
        address indexed recipient,
        Currency input,
        Currency output,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice `sweep` sent this router's idle balance of `currency` to `to`.
    /// @param currency The currency swept; zero is native.
    /// @param to The recipient.
    /// @param amount The amount sent.
    event Swept(Currency indexed currency, address indexed to, uint256 amount);

    /// @notice A trade's shape is refused: a zero family id, no leg or more than 8, an input equal to the output,
    ///         neither of them the family's subject, a zero amount, a passed deadline, a recipient that cannot
    ///         receive, a sell with a converting leg paying another account than the caller, campaigns without an
    ///         engagement sink or 9 or more, a native value that does not match the input, or a conversion that
    ///         delivers nothing.
    error InvalidTrade();
    /// @notice The pool is not a member of the trade's family.
    error NotFamilyMember(PoolId id);
    /// @notice The member pool is named by an earlier leg of the trade.
    error DuplicatePool(PoolId id);
    /// @notice The member is quoted in an asset other than the trade's own currency and the leg names no reference
    ///         pool, or it is quoted in the trade's own currency and the leg names one.
    error MixedCurrencies(PoolId id);
    /// @notice The reference pool's currencies are not the conversion's, or its hooks are neither absent nor a
    ///         registered Hookr root.
    error InvalidConversion(PoolId id);
    /// @notice A swap of leg `leg` used `used` of its `requested` input: the pool ran out of liquidity.
    error LegPartiallyFilled(uint256 leg, uint256 used, uint256 requested);
    /// @notice Leg `leg` delivered `amountOut`, below its `minOut`.
    error LegBelowMinimum(uint256 leg, uint256 amountOut, uint256 minOut);
    /// @notice The legs delivered `amountOut` in all, below the trade's `minTotalOut`.
    error TotalBelowMinimum(uint256 amountOut, uint256 minTotalOut);
    /// @notice This router received `received` of the input instead of `expected`: a token that takes a fee on
    ///         transfer.
    error InputNotReceived(uint256 received, uint256 expected);
    /// @notice A permit for native input, for another token than the input, or one that does not cover the trade.
    error InvalidPermit();
    /// @notice This router's balance of `currency` did not end where the trade started.
    error BalanceChanged(Currency currency);
    /// @notice A call into this router while it trades, or `sweep` during a trade.
    error Reentered();
    /// @notice A callback, a vouch request or a native transfer this router did not ask for.
    error InvalidCallback();

    /// @notice Returns HookrRouter, which runs every swap on a Hookr pool.
    /// @return The router, fixed at construction.
    function router() external view returns (IHookrRouter);

    /// @notice Returns the launcher whose families this router trades.
    /// @return HookrLauncher, fixed at construction.
    function launcher() external view returns (IHookrLauncherView);

    /// @notice Returns the PoolManager every pool of a trade lives on.
    /// @return The router's PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns Permit2, which a trade's `permit` signature transfer goes through.
    /// @return Permit2, fixed at construction.
    function permit2() external view returns (address);

    /// @notice Splits one trade across a family's pools: takes the sum of the legs' inputs from the caller, runs every
    ///         leg in order and pays every leg's output to the recipient.
    /// @dev On a buy (`output` is the family's subject) each leg converts its input into its member's quote through its
    ///      reference pool, if it names one, then swaps it on the member for the subject; on a sell (`input` is the
    ///      subject) each leg swaps its input on the member for the member's quote, then converts that through its
    ///      reference pool into `output`, if it names one. Every swap is an exact input with no price limit that must
    ///      use all of its input; a member swap's minimum is its leg's `minOut` when no conversion follows it, and a
    ///      leg's output is checked against `minOut` in every case. The input arrives by `transferFrom` from the caller
    ///      (an allowance to this router), or by a Permit2 signature transfer when `permit` is not empty, or as the
    ///      call's value when it is native. Atomic: any leg's failure reverts the trade.
    /// @param request The family, currencies, legs, minimums, recipient, deadline and engagement sink of the trade.
    /// @param permit Empty, or `abi.encode(IPermit2Signature.PermitTransferFrom permit, bytes signature)`: a Permit2
    ///        signature transfer from the caller of at least the legs' sum of the input token to this router.
    /// @return amountIn The sum of the legs' inputs, paid by the caller.
    /// @return amountOut The sum of the legs' outputs, paid to the recipient.
    function trade(FamilyTrade calldata request, bytes calldata permit)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut);

    /// @notice Sends this router's idle balance of `currency` to `to`. The router holds nothing between trades, so any
    ///         idle balance is stray; anyone may call, never during a trade.
    /// @param currency The currency to sweep; zero is native.
    /// @param to The recipient; not zero and not this router.
    /// @return amount The amount sent.
    function sweep(Currency currency, address to) external returns (uint256 amount);
}
