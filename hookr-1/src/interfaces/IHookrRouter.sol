// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHookrRegistry} from "./IHookrRegistry.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title IHookrRouter
/// @notice Interface for HookrRouter, the single-pool swap router for Hookr roots. Optional rewards run after
///         settlement.
interface IHookrRouter {
    /// @notice The parameters of a single-pool swap.
    struct Swap {
        /// @notice The pool. Its hooks are a registered Hookr root; a direct `swap` also needs the root to name this
        ///         router.
        PoolKey key;
        /// @notice The direction: true sells currency0 for currency1, false sells currency1 for currency0.
        bool zeroForOne;
        /// @notice Negative for an exact input, positive for an exact output; never zero or int128's minimum.
        int128 amountSpecified;
        /// @notice The minimum output of an exact input or the maximum input of an exact output; never zero.
        uint128 amountBound;
        /// @notice The sqrt price at which the swap stops, as in Uniswap v4's SwapParams.
        uint160 sqrtPriceLimitX96;
        /// @notice The beneficiary of the output; never zero, this router, the PoolManager or the router's forwarder.
        address recipient;
        /// @notice The last timestamp, in seconds, at which the swap may execute.
        uint256 deadline;
    }

    /// @notice The swap's fields are invalid: amounts, bound, recipient, deadline or campaigns.
    error InvalidSwap();
    /// @notice The pool's hooks are not a registered root that names this router.
    error InvalidPool();
    /// @notice The PoolManager's callback did not complete the unlock this router started.
    error InvalidCallback();
    /// @notice The swap broke the caller's bound.
    error Slippage();
    /// @notice The call re-entered the router.
    error Reentered();
    /// @notice The engagement receipt could not be recorded.
    error InvalidReceipt();
    /// @notice `caller` is not the pinned forwarder.
    error NotForwarder(address caller);
    /// @notice `forwarder` is not the contract the router pinned.
    error InvalidForwarder(address forwarder);
    /// @notice The swap's input is native currency, which a relayed swap cannot carry.
    error NativeInputUnsupported();
    /// @notice The relayer fee `outputFee` and the recipient `feeRecipient` disagree: zero exactly when the other is
    ///         zero.
    error InvalidFee(uint256 outputFee, address feeRecipient);
    /// @notice The fee `fee` is above the output `amountOut`.
    error FeeExceedsOutput(uint256 fee, uint256 amountOut);

    /// @notice A brake holds `root` closed and the registry's owner can still reopen it (`rootReopenable`): no gate
    ///         vouches on it until it reopens.
    error RootClosed(address root);

    /// @notice `gate` is not a live GATE admission of `root`: never admitted there, revoked, or bonded by a bond that
    ///         no longer covers it.
    error GateNotAdmitted(address root, address gate);

    /// @notice `gate`'s runtime codehash differs from the one its admission pinned.
    error GateCodeChanged(address gate);

    /// @notice `gate` did not vouch: it reverted, ran out of its gas, or answered anything but its selector.
    error GateRefused(address gate);

    /// @notice Less gas is left than `gate` needs to run with all of its admitted gas.
    error InsufficientGateGas(address gate);

    /// @notice A swap executed.
    /// @param poolId The pool.
    /// @param payer The account that paid the input.
    /// @param recipient The account that received the output.
    /// @param amountIn The input paid.
    /// @param amountOut The output delivered.
    event SwapExecuted(
        PoolId indexed poolId, address indexed payer, address indexed recipient, uint256 amountIn, uint256 amountOut
    );
    /// @notice A relayed swap took its output fee.
    /// @param poolId The pool.
    /// @param payer The identity the swap was made for.
    /// @param feeRecipient The receiver of the fee.
    /// @param outputFee The fee taken from the gross output.
    event SwapRelayed(PoolId indexed poolId, address indexed payer, address indexed feeRecipient, uint256 outputFee);

    /// @notice A gated swap on `poolId` ran for `payer`, vouched for by `gate` and funded by `funder`.
    /// @param poolId The pool.
    /// @param payer The identity the swap was made for.
    /// @param gate The gate that vouched.
    /// @param funder The account that funded the input.
    event SwapGated(PoolId indexed poolId, address indexed payer, address indexed gate, address funder);
    /// @notice An idle balance was sent out of the router.
    /// @param currency The currency swept.
    /// @param to The recipient.
    /// @param amount The amount swept.
    event Swept(Currency indexed currency, address indexed to, uint256 amount);

    /// @notice Returns the registry whose roots this router trades through.
    /// @return The immutable Hookr admission registry.
    function registry() external view returns (IHookrRegistry);

    /// @notice Returns the only caller of `swapFor`, which a swap's recipient can never be.
    /// @return The immutable forwarder; zero when relayed swaps are disabled.
    function forwarder() external view returns (address);

    /// @notice Executes a bounded swap (0x19b36adf) and optionally records rewards after settlement and delivery.
    /// @dev The payer is `msg.sender`: it pays the input, and partial-fill refunds are credited to it as
    ///      Rules claims. `recipient` is the beneficiary of the output: it is never zero, this router, the
    ///      PoolManager or the forwarder, and the swap reverts before any pool call when it is. An aggregator or
    ///      forwarder that calls this router is the payer and must expose `Rules.claimTo`, or have the user call
    ///      directly.
    /// @param params The pool, direction, amount, bound, price limit, recipient and deadline of the swap.
    /// @param engagement Zero, or the Programs receipt sink that records the swap for `campaigns`.
    /// @param campaigns The program ids the swap is recorded for: 1 to 8 with an `engagement`, none without.
    /// @return amountIn The input paid.
    /// @return amountOut The output delivered to `recipient`.
    function swap(Swap calldata params, address engagement, uint256[] calldata campaigns)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut);

    /// @notice Relayed swap (0x28672da5), callable only by the pinned forwarder, which calls it to execute a signed
    ///         intent. `payer` is the identity (hookData payer, receipt payer, Programs participant); the pinned
    ///         forwarder funds the ERC-20 input. `outputFee` of the gross output goes to `feeRecipient`.
    /// @dev Exact input: `amountBound` is the net minimum the recipient receives. Exact output: `amountSpecified`
    ///      is the gross output and the recipient receives `amountSpecified - outputFee`. `recipient` follows
    ///      `swap`'s rules.
    /// @param params The pool, direction, amount, bound, price limit, recipient and deadline of the swap.
    /// @param payer The identity the swap is made for; not zero.
    /// @param outputFee The relayer fee taken from the gross output; zero exactly when `feeRecipient` is zero.
    /// @param feeRecipient The receiver of `outputFee`; never this router.
    /// @param engagement Zero, or the Programs receipt sink that records the swap for `campaigns`.
    /// @param campaigns The program ids the swap is recorded for: 1 to 8 with an `engagement`, none without.
    /// @return amountIn The input paid by the forwarder.
    /// @return amountOut The gross output, `outputFee` included.
    function swapFor(
        Swap calldata params,
        address payer,
        uint256 outputFee,
        address feeRecipient,
        address engagement,
        uint256[] calldata campaigns
    ) external returns (uint256 amountIn, uint256 amountOut);

    /// @notice Gated swap (0xd70dbb98): `msg.sender` funds the input and `payer` is the identity (hookData payer,
    ///         receipt payer, Programs participant, the account the root's compliance checks and Rules claims name),
    ///         once `gate`, a live GATE admission of the pool's root, vouches for it (IHookrSwapGate.beforeUnlock)
    ///         before the unlock.
    /// @dev Day-one consumer: HookrFamilyRouter, which runs each leg of a Multi-pool launch trade through this function
    ///      with itself as the gate, vouching only for the trader who called it; later the limit-orders book.
    ///      Invariants: only a live, unrevoked GATE admission of the pool's own root (`registry.admission(root, gate)`
    ///      of kind GATE) whose runtime codehash is still the pinned one can vouch; none does while a brake holds that
    ///      root closed and the registry's owner can still reopen it (`IHookrRegistry.rootReopenable`, reverting
    ///      `RootClosed`), so `closeRoot` stops a gate the guardian may not revoke on a frozen root, an owned root's
    ///      copy included; the gate is called once, with exactly the admission's gas, under this router's reentrancy
    ///      lock, and its vouch serves this one swap;
    ///      `data` goes to the gate only, never to the root, so no executing path can carry a quote mode or any other
    ///      flag; `swap` and `swapFor` never ask a gate and keep their selectors and behaviour. Inert until a queued
    ///      `ADMIT` of kind GATE executes: until then every gate is refused (`GateNotAdmitted`). Otherwise as `swap`:
    ///      the same field checks, a registered root that names this router, native input sent as the call's value
    ///      with any unused part refunded to `msg.sender`, and the output paid to `recipient`.
    /// @param params The pool, direction, amount, bound, price limit, recipient and deadline of the swap.
    /// @param payer The identity the swap is made for; not zero.
    /// @param gate The pool root's GATE admission that vouches for `payer`.
    /// @param data Passed to the gate unread.
    /// @param engagement Zero, or the Programs receipt sink that records the swap for `campaigns`, with `payer` as the
    ///        participant.
    /// @param campaigns The program ids the swap is recorded for: 1 to 8 with an `engagement`, none without.
    /// @return amountIn The input paid by `msg.sender`.
    /// @return amountOut The output delivered to `recipient`.
    function swapGated(
        Swap calldata params,
        address payer,
        address gate,
        bytes calldata data,
        address engagement,
        uint256[] calldata campaigns
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    /// @notice Returns the PoolManager the router swaps on.
    /// @return The PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice The forwarder's code hash, pinned at construction.
    /// @return The forwarder's runtime codehash.
    function forwarderCodeHash() external view returns (bytes32);

    /// @notice Sends this router's idle balance of `currency` to `to`. The router never holds user funds
    ///         between calls, so any idle balance is stray. Anyone may call; it cannot run during a swap.
    /// @param currency The currency to sweep; address zero is native.
    /// @param to The recipient; not zero and not this router.
    /// @return amount The amount sent.
    function sweep(Currency currency, address to) external returns (uint256 amount);
}
