// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrFeeSwapAdapter} from "../../interfaces/IHookrFeeSwapAdapter.sol";
import {HookrAsset} from "../../libraries/HookrAsset.sol";

/// @title HookrV4ExactInputAdapter
/// @notice Single-pool exact-input swap on a Uniswap v4 PoolManager, for tax conversion routes.
/// @dev `routeData` is exactly `abi.encode(PoolKey)`; the route registry freezes its hash, so the pool is chosen by
///      the route curator, never by a signer or caller. The swap must consume the full input (a partial fill at the
///      price limit reverts) and deliver at least `minAmountOut` straight from the PoolManager to `recipient`.
///      Permissionless and stateless between calls: it holds nothing, so anyone using it spends only their own funds.
contract HookrV4ExactInputAdapter is IHookrFeeSwapAdapter, IUnlockCallback {
    IPoolManager public immutable poolManager;
    uint256 private _lock = 1;

    error InvalidRoute();
    error InvalidAmount();
    error InvalidNativeValue(uint256 expected, uint256 received);
    error PartialFill(uint256 requested, uint256 consumed);
    error TooLittleReceived(uint256 minimum, uint256 received);
    error ReentrantCall();
    error Unauthorized();

    /// @param manager The v4 PoolManager every route of this adapter swaps on.
    constructor(IPoolManager manager) {
        if (address(manager).code.length == 0) revert InvalidRoute();
        poolManager = manager;
    }

    /// @inheritdoc IHookrFeeSwapAdapter
    function executeExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata routeData
    ) external payable returns (uint256 amountOut) {
        if (_lock != 1) revert ReentrantCall();
        _lock = 2;
        if (routeData.length != 160) revert InvalidRoute();
        PoolKey memory key = abi.decode(routeData, (PoolKey));
        if (keccak256(routeData) != keccak256(abi.encode(key))) revert InvalidRoute();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (!((c0 == tokenIn && c1 == tokenOut) || (c0 == tokenOut && c1 == tokenIn))) revert InvalidRoute();
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max)) || recipient == address(0)) {
            revert InvalidAmount();
        }
        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert InvalidNativeValue(amountIn, msg.value);
        } else {
            if (msg.value != 0) revert InvalidNativeValue(0, msg.value);
            HookrAsset.pullExact(tokenIn, msg.sender, amountIn);
        }
        amountOut = abi.decode(poolManager.unlock(abi.encode(key, c0 == tokenIn, amountIn, recipient)), (uint256));
        if (amountOut < minAmountOut) revert TooLittleReceived(minAmountOut, amountOut);
        _lock = 1;
    }

    /// @notice Executes the committed swap, pays the full input and delivers the output to the recipient.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _lock != 2) revert Unauthorized();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, address recipient) =
            abi.decode(data, (PoolKey, bool, uint256, address));
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );
        (int128 inDelta, int128 outDelta) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (inDelta >= 0 || uint256(uint128(-inDelta)) != amountIn) {
            revert PartialFill(amountIn, inDelta >= 0 ? 0 : uint256(uint128(-inDelta)));
        }
        if (outDelta <= 0) revert TooLittleReceived(1, 0);
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        if (input.isAddressZero()) {
            poolManager.settle{value: amountIn}();
        } else {
            poolManager.sync(input);
            HookrAsset.send(Currency.unwrap(input), address(poolManager), amountIn);
            poolManager.settle();
        }
        uint256 out = uint256(uint128(outDelta));
        poolManager.take(output, recipient, out);
        return abi.encode(out);
    }
}
