// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title HookrSwapRouter
/// @notice Production settlement boundary for graduated Hookr pools.
/// @dev Unlike PoolSwapTest, every entrypoint binds the output recipient and hookData recipient,
///      enforces a deadline and an execution-time amount bound, settles only measured deltas, and
///      refunds only the native input left from the current call. Hookr pools are native-ETH or
///      HOOKR currency0 / ERC-20 currency1 pools; an ERC-20 quote settles by transferFrom (the
///      payer approves this router), pays no msg.value, and needs no refund — the pull is exact.
contract HookrSwapRouter is IUnlockCallback {
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    int24 internal constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;
    IHooks public immutable hook;
    /// @notice The one ERC-20 quote this router accepts as currency0 (the HOOKR token). Native ETH
    ///         is always accepted; any other currency0 is refused.
    address public immutable quoteToken;

    uint256 private unlocked = 1;

    struct ExactInputParams {
        PoolKey key;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
        address recipient;
        uint256 deadline;
    }

    struct ExactOutputParams {
        PoolKey key;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        uint160 sqrtPriceLimitX96;
        address recipient;
        uint256 deadline;
    }

    struct CallbackData {
        address payer;
        address recipient;
        PoolKey key;
        SwapParams swapParams;
        bool exactInput;
        uint128 amountBound;
    }

    event SwapExecuted(
        address indexed payer,
        address indexed recipient,
        address indexed token,
        bool zeroForOne,
        bool exactInput,
        uint256 amountIn,
        uint256 amountOut
    );

    error Reentrancy();
    error NotPoolManager();
    error CallbackNotActive();
    error DeadlineExpired(uint256 deadline, uint256 timestamp);
    error InvalidPoolKey();
    error InvalidRecipient();
    error InvalidAmount();
    error AmountTooLarge();
    error InvalidNativeValue(uint256 expected, uint256 received);
    error TooLittleReceived(uint256 minimum, uint256 received);
    error TooMuchRequested(uint256 maximum, uint256 requested);
    error UnexpectedDelta();
    error TransferFailed();
    error SettlementMismatch(uint256 expected, uint256 settled);

    constructor(IPoolManager poolManager_, IHooks hook_, address quoteToken_) {
        if (address(poolManager_) == address(0) || address(hook_) == address(0)) revert InvalidPoolKey();
        poolManager = poolManager_;
        hook = hook_;
        quoteToken = quoteToken_;
    }

    modifier nonReentrant() {
        if (unlocked != 1) revert Reentrancy();
        unlocked = 2;
        _;
        unlocked = 1;
    }

    /// @notice Stable deployment identity for post-deploy readbacks and agent health checks.
    function contractName() external pure returns (string memory) {
        return "HookrSwapRouter";
    }

    /// @notice Candidate generation. Runtime code hash remains the release authority.
    function contractVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    /// @notice Execute an exact-input buy or sell with an execution-time minimum output.
    function exactInput(ExactInputParams calldata p) external payable nonReentrant returns (uint256 amountOut) {
        _validate(p.key, p.recipient, p.deadline, p.amountIn);
        if (p.amountOutMinimum == 0) revert InvalidAmount();
        _validateNativeValue(p.key, p.zeroForOne, p.amountIn);

        SwapParams memory swapParams = SwapParams({
            zeroForOne: p.zeroForOne,
            amountSpecified: -int256(uint256(p.amountIn)),
            sqrtPriceLimitX96: p.sqrtPriceLimitX96
        });
        (uint256 amountInUsed, uint256 received) = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData({
                        payer: msg.sender,
                        recipient: p.recipient,
                        key: p.key,
                        swapParams: swapParams,
                        exactInput: true,
                        amountBound: p.amountOutMinimum
                    })
                )
            ),
            (uint256, uint256)
        );
        if (received < p.amountOutMinimum) revert TooLittleReceived(p.amountOutMinimum, received);
        if (amountInUsed > p.amountIn) revert UnexpectedDelta();
        _refundNative(p.key, p.zeroForOne, uint256(p.amountIn) - amountInUsed);

        emit SwapExecuted(
            msg.sender, p.recipient, Currency.unwrap(p.key.currency1), p.zeroForOne, true, amountInUsed, received
        );
        return received;
    }

    /// @notice Execute an exact-output buy or sell with an execution-time maximum input.
    function exactOutput(ExactOutputParams calldata p) external payable nonReentrant returns (uint256 amountIn) {
        _validate(p.key, p.recipient, p.deadline, p.amountOut);
        if (p.amountInMaximum == 0 || p.amountInMaximum > uint128(type(int128).max)) revert InvalidAmount();
        _validateNativeValue(p.key, p.zeroForOne, p.amountInMaximum);

        SwapParams memory swapParams = SwapParams({
            zeroForOne: p.zeroForOne,
            amountSpecified: int256(uint256(p.amountOut)),
            sqrtPriceLimitX96: p.sqrtPriceLimitX96
        });
        (uint256 used, uint256 amountOutReceived) = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData({
                        payer: msg.sender,
                        recipient: p.recipient,
                        key: p.key,
                        swapParams: swapParams,
                        exactInput: false,
                        amountBound: p.amountInMaximum
                    })
                )
            ),
            (uint256, uint256)
        );
        if (used > p.amountInMaximum) revert TooMuchRequested(p.amountInMaximum, used);
        if (amountOutReceived < p.amountOut) revert TooLittleReceived(p.amountOut, amountOutReceived);
        _refundNative(p.key, p.zeroForOne, uint256(p.amountInMaximum) - used);

        emit SwapExecuted(
            msg.sender, p.recipient, Currency.unwrap(p.key.currency1), p.zeroForOne, false, used, amountOutReceived
        );
        return used;
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (unlocked != 2) revert CallbackNotActive();

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = poolManager.swap(data.key, data.swapParams, abi.encode(data.recipient));
        (int128 inputDelta, int128 outputDelta) =
            data.swapParams.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (inputDelta >= 0 || outputDelta <= 0) revert UnexpectedDelta();

        uint256 amountIn = uint256(-int256(inputDelta));
        uint256 amountOut = uint256(int256(outputDelta));
        if (data.exactInput) {
            uint256 specified = uint256(-data.swapParams.amountSpecified);
            if (amountIn > specified || amountOut < data.amountBound) {
                if (amountOut < data.amountBound) revert TooLittleReceived(data.amountBound, amountOut);
                revert UnexpectedDelta();
            }
        } else {
            if (amountIn > data.amountBound) revert TooMuchRequested(data.amountBound, amountIn);
            if (amountOut < uint256(data.swapParams.amountSpecified)) {
                revert TooLittleReceived(uint256(data.swapParams.amountSpecified), amountOut);
            }
        }

        Currency inputCurrency = data.swapParams.zeroForOne ? data.key.currency0 : data.key.currency1;
        Currency outputCurrency = data.swapParams.zeroForOne ? data.key.currency1 : data.key.currency0;
        _settle(inputCurrency, data.payer, amountIn);
        poolManager.take(outputCurrency, data.recipient, amountOut);
        return abi.encode(amountIn, amountOut);
    }

    function _validate(PoolKey calldata key, address recipient, uint256 deadline, uint128 amount) internal view {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        address c0 = Currency.unwrap(key.currency0);
        if (
            (c0 != address(0) && c0 != quoteToken) || Currency.unwrap(key.currency1) == address(0)
                || address(key.hooks) != address(hook) || key.fee != DYNAMIC_FEE_FLAG || key.tickSpacing != TICK_SPACING
        ) revert InvalidPoolKey();
        if (amount == 0) revert InvalidAmount();
        if (amount > uint128(type(int128).max)) revert AmountTooLarge();
    }

    function _validateNativeValue(PoolKey calldata key, bool zeroForOne, uint256 maximumInput) internal view {
        bool nativeInput = zeroForOne && Currency.unwrap(key.currency0) == address(0);
        uint256 expected = nativeInput ? maximumInput : 0;
        if (msg.value != expected) revert InvalidNativeValue(expected, msg.value);
    }

    function _refundNative(PoolKey calldata key, bool zeroForOne, uint256 amount) internal {
        if (amount == 0 || !zeroForOne || Currency.unwrap(key.currency0) != address(0)) return;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _settle(Currency currency, address payer, uint256 amount) internal {
        uint256 paid;
        if (Currency.unwrap(currency) == address(0)) {
            paid = poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            _safeTransferFrom(Currency.unwrap(currency), payer, address(poolManager), amount);
            paid = poolManager.settle();
        }
        if (paid != amount) revert SettlementMismatch(amount, paid);
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory result) = token.call(abi.encodeWithSelector(bytes4(0x23b872dd), from, to, amount));
        if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TransferFailed();
        }
    }
}
