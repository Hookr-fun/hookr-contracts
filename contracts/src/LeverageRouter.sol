// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IERC20Router {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title LeverageRouter
/// @notice A spot route into leverage-enabled pools, generalised over the hook.
///
///         This is not a convenience. `HookrSwapRouter` pins `key.hooks` against a constructor
///         immutable and reverts `InvalidPoolKey` for anything else, so a leverage pool would
///         have had no route at all — and the exclusivity gate keeps outside LPs out. A pool
///         nobody can trade is a pool nobody can arbitrage, and every risk term in the credit
///         design (spot, the average, the deviation check, the liquidation trigger, the NAV
///         mark) is only meaningful if competitive flow keeps that price honest.
///
///         So the route ships with the market rather than after it.
contract LeverageRouter is IUnlockCallback {
    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error Expired();
    error BadRecipient();
    error TooLittleReceived();
    error TooMuchSpent();
    error WrongValue();

    struct SwapArgs {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        uint256 amountBound;
        address recipient;
        uint256 deadline;
    }

    constructor(IPoolManager manager) {
        poolManager = manager;
    }

    /// @dev Only the pool manager may push ETH here — a refund from a partial fill. An open
    ///      receive() turned stray transfers into a balance the next caller could claim.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert WrongValue();
    }

    /// @notice Swaps through any pool. Negative `amountSpecified` is exact-input.
    function swap(SwapArgs calldata args) external payable returns (BalanceDelta delta) {
        if (block.timestamp > args.deadline) revert Expired();
        if (args.recipient == address(0) || args.recipient == address(this)) revert BadRecipient();

        // Snapshot what this call is entitled to. Refunding `address(this).balance` really did
        // mean the whole balance: anything sent to the open receive() was claimable by the
        // next caller, and a swap could be funded out of it with msg.value set to zero.
        uint256 before = address(this).balance - msg.value;

        bytes memory res = poolManager.unlock(abi.encode(args, msg.sender, msg.value));
        delta = abi.decode(res, (BalanceDelta));

        uint256 nowBal = address(this).balance;
        if (nowBal > before) {
            (bool ok,) = msg.sender.call{value: nowBal - before}("");
            if (!ok) revert WrongValue();
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (SwapArgs memory args, address payer, uint256 funded) = abi.decode(data, (SwapArgs, address, uint256));

        BalanceDelta delta = poolManager.swap(
            args.key,
            SwapParams({
                zeroForOne: args.zeroForOne,
                amountSpecified: args.amountSpecified,
                sqrtPriceLimitX96: args.sqrtPriceLimitX96
            }),
            ""
        );

        (Currency inCur, Currency outCur) =
            args.zeroForOne ? (args.key.currency0, args.key.currency1) : (args.key.currency1, args.key.currency0);
        (int128 inDelta, int128 outDelta) =
            args.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());

        uint256 spent = uint256(int256(-inDelta));
        uint256 received = uint256(int256(outDelta));

        if (args.amountSpecified < 0) {
            if (received < args.amountBound) revert TooLittleReceived();
        } else {
            if (spent > args.amountBound) revert TooMuchSpent();
        }

        // Settle the input side.
        if (inCur.isAddressZero()) {
            // Residue in this contract is third-party ETH: `poolManager.take` can send here
            // from anyone's unlock. The `before` snapshot stops it leaving as a refund, but
            // `settle{value:}` draws on the raw balance — so a caller sending msg.value = 0
            // could buy a token with someone else's ETH. The comment above claimed this was
            // already closed; it was not.
            if (spent > funded) revert WrongValue();

            // Reset the transient synced-currency slot: `sync` is permissionless and nothing
            // in v4 clears it, so a stray sync(token) in the same transaction would push this
            // down the ERC-20 branch and revert NonzeroNativeValue.
            poolManager.sync(inCur);
            poolManager.settle{value: spent}();
        } else {
            poolManager.sync(inCur);
            IERC20Router(Currency.unwrap(inCur)).transferFrom(payer, address(poolManager), spent);
            poolManager.settle();
        }

        poolManager.take(outCur, args.recipient, received);
        return abi.encode(delta);
    }
}
