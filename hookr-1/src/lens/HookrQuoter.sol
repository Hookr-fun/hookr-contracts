// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrRules} from "../interfaces/IHookrRules.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrRouter} from "../interfaces/IHookrRouter.sol";
import {IHookrQuoter} from "../interfaces/IHookrQuoter.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {HookrSwapPreflight} from "../libraries/HookrSwapPreflight.sol";

/// @title HookrQuoter
/// @notice Simulates a swap. All simulated state is reverted.
contract HookrQuoter is HookrReleased, IHookrQuoter {
    using PoolIdLibrary for *;
    using TransientStateLibrary for IPoolManager;

    /// @inheritdoc IHookrQuoter
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrQuoter
    IHookrRegistry public immutable registry;
    /// @dev Quote state machine: 0 idle, 2 entered, 3 in the unlock, 4 simulating. Cleared with the transaction, like
    ///      the router's; every quote also resets it, so several quotes can run in one transaction.
    uint8 private transient _state;
    /// @dev Whether the running quote is detailed: its simulation also measures the payer's claim.
    bool private transient _detailed;
    bytes32 private transient _pending;
    /// @dev The payer's claim a detailed simulation measured, carried from `simulate` to `unlockCallback`.
    uint256 private transient _claim;

    constructor(IPoolManager manager, IHookrRegistry _registry) {
        if (address(manager).code.length == 0 || address(_registry).code.length == 0) revert InvalidQuote();
        poolManager = manager;
        registry = _registry;
    }

    /// @inheritdoc IHookrQuoter
    function quote(IHookrRouter.Swap calldata params, address payer)
        external
        returns (HookrTypes.ExecutionReceipt memory receipt)
    {
        _check(params, payer);
        (receipt,,) = _run(abi.encode(Request(params, payer)), false);
    }

    /// @inheritdoc IHookrQuoter
    function quoteDetailed(IHookrRouter.Swap calldata params, address payer)
        external
        returns (HookrTypes.ExecutionReceipt memory receipt, uint256 traderClaim, uint256 gasEstimate)
    {
        _check(params, payer);
        return _run(abi.encode(Request(params, payer)), true);
    }

    /// @inheritdoc IHookrQuoter
    function quoteExactInputSingle(QuoteExactSingleParams calldata params)
        external
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        HookrTypes.ExecutionReceipt memory receipt;
        (receipt,, gasEstimate) = _run(_single(params, true), false);
        if (receipt.inputAmount != params.exactAmount) revert NotEnoughLiquidity(params.poolKey.toId());
        amountOut = receipt.outputAmount;
    }

    /// @inheritdoc IHookrQuoter
    function quoteExactOutputSingle(QuoteExactSingleParams calldata params)
        external
        returns (uint256 amountIn, uint256 gasEstimate)
    {
        HookrTypes.ExecutionReceipt memory receipt;
        (receipt,, gasEstimate) = _run(_single(params, false), false);
        amountIn = receipt.inputAmount;
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only the PoolManager, inside a quote's own unlock: runs the committed simulation and returns its receipt
    ///      through a typed revert (`QuoteResult`, or `QuoteDetail` with the payer's claim for a detailed quote).
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _state != 2 || keccak256(data) != _pending) {
            revert InvalidCallback();
        }
        _state = 3;
        // Wrap every untrusted failure before emitting our own result error.
        try this.simulate(abi.decode(data, (Request))) returns (HookrTypes.ExecutionReceipt memory receipt) {
            if (_detailed) revert QuoteDetail(receipt, _claim);
            revert QuoteResult(receipt);
        } catch (bytes memory reason) {
            revert SimulationFailed(reason);
        }
    }

    /// @inheritdoc IHookrQuoter
    /// @dev A detailed quote also reads the payer's claim in the pool's quote from the pool's Rules before and after
    ///      the swap, inside this wrapped frame, and leaves the difference less the receipt's refund in `_claim`.
    ///      First clears a currency an earlier call in the transaction left synced, as HookrRouter.unlockCallback does,
    ///      so the quote runs as the router's swap would; the clearing reverts with the rest of the simulation.
    function simulate(Request calldata request) external returns (HookrTypes.ExecutionReceipt memory receipt) {
        if (msg.sender != address(this) || _state != 3) revert InvalidCallback();
        _state = 4;
        if (!poolManager.getSyncedCurrency().isAddressZero()) poolManager.sync(Currency.wrap(address(0)));
        IHookrRouter.Swap calldata params = request.params;
        PoolId id = params.key.toId();
        IHookrRoot root = IHookrRoot(address(params.key.hooks));
        bool detailed = _detailed;
        IHookrRules rules;
        Currency quoteCurrency;
        uint256 claimBefore;
        if (detailed) {
            HookrTypes.PoolConfig memory config = root.poolConfig(id);
            (rules, quoteCurrency) = (IHookrRules(config.rules), config.quote);
            claimBefore = rules.claimable(quoteCurrency, request.payer);
        }
        BalanceDelta delta = poolManager.swap(
            params.key,
            SwapParams(params.zeroForOne, params.amountSpecified, params.sqrtPriceLimitX96),
            abi.encode(request.payer, params.recipient, id, true)
        );
        receipt = root.takeReceipt(id);
        (int128 input, int128 output) =
            params.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (
            input >= 0 || output <= 0 || receipt.inputAmount != uint256(-int256(input))
                || receipt.outputAmount != uint256(int256(output))
        ) revert InvalidQuote();
        if (params.amountSpecified < 0) {
            if (
                receipt.inputAmount > uint256(-int256(params.amountSpecified))
                    || receipt.outputAmount < params.amountBound
            ) revert InvalidQuote();
        } else if (receipt.inputAmount > params.amountBound || receipt.outputAmount != uint128(params.amountSpecified))
        {
            revert InvalidQuote();
        }
        if (detailed) {
            uint256 claimAfter = rules.claimable(quoteCurrency, request.payer);
            uint256 owed = claimBefore + receipt.quoteRefund;
            _claim = claimAfter > owed ? claimAfter - owed : 0;
        }
    }

    /// @dev The checks a router-shaped quote passes before it simulates: no quote running, a payer, a pool this quoter
    ///      simulates (`_routerOf`) and the router's own field checks against that pool's router and its forwarder.
    function _check(IHookrRouter.Swap calldata params, address payer) private view {
        if (_state != 0 || payer == address(0)) revert InvalidQuote();
        (address router, address forwarder) = _routerOf(params.key);
        if (!HookrSwapPreflight.passes(params, router, address(poolManager), forwarder)) revert InvalidQuote();
    }

    /// @dev The encoded request a single-pool quote stands for: the router-shaped swap with `msg.sender` as payer and
    ///      recipient, no price limit, a minimum output of one unit (exact input) or no maximum input (exact output)
    ///      and a deadline of now, checked as `_check` checks a quote.
    function _single(QuoteExactSingleParams calldata params, bool exactInput) private view returns (bytes memory) {
        if (_state != 0) revert InvalidQuote();
        if (params.hookData.length != 0) revert InvalidHookData();
        uint128 amount = params.exactAmount;
        if (amount == 0 || amount > uint128(type(int128).max)) revert InvalidQuote();
        int128 specified = exactInput ? -int128(amount) : int128(amount);
        uint128 bound = exactInput ? 1 : type(uint128).max;
        (address router, address forwarder) = _routerOf(params.poolKey);
        if (!HookrSwapPreflight.passes(
                msg.sender, specified, bound, block.timestamp, router, address(poolManager), forwarder
            )) {
            revert InvalidQuote();
        }
        bool zeroForOne = params.zeroForOne;
        return abi.encode(
            Request(
                IHookrRouter.Swap({
                    key: params.poolKey,
                    zeroForOne: zeroForOne,
                    amountSpecified: specified,
                    amountBound: bound,
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                    recipient: msg.sender,
                    deadline: block.timestamp
                }),
                msg.sender
            )
        );
    }

    /// @dev The router and forwarder of a pool this quoter simulates: its hooks are a registered root that shares this
    ///      quoter's PoolManager, pins this quoter and initialized the pool.
    function _routerOf(PoolKey calldata key) private view returns (address router, address forwarder) {
        IHookrRoot root = IHookrRoot(address(key.hooks));
        if (
            !registry.isRoot(address(root)) || address(root.poolManager()) != address(poolManager)
                || root.quoter() != address(this) || !root.knownPool(key.toId())
        ) revert InvalidQuote();
        router = root.router();
        forwarder = IHookrRouter(router).forwarder();
    }

    /// @dev Runs the encoded request in the always-reverting frame, decodes its result (the receipt, and the payer's
    ///      claim for a detailed quote) and measures the frame's gas. Any other revert of the frame is rethrown.
    function _run(bytes memory data, bool detailed)
        private
        returns (HookrTypes.ExecutionReceipt memory receipt, uint256 traderClaim, uint256 gasEstimate)
    {
        _state = 2;
        _detailed = detailed;
        _pending = keccak256(data);
        uint256 gasBefore = gasleft();
        try poolManager.unlock(data) {
            revert InvalidQuote();
        } catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            _state = 0;
            _detailed = false;
            delete _pending;
            // The receipt is 13 static words; a detailed result adds the claim.
            uint256 size = detailed ? 14 * 32 : 13 * 32;
            bytes4 result = detailed ? QuoteDetail.selector : QuoteResult.selector;
            if (reason.length != 4 + size || bytes4(reason) != result) {
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            }
            // Strip the error selector. The rest is static ABI data.
            assembly ("memory-safe") {
                reason := add(reason, 4)
                mstore(reason, size)
            }
            if (detailed) (receipt, traderClaim) = abi.decode(reason, (HookrTypes.ExecutionReceipt, uint256));
            else receipt = abi.decode(reason, (HookrTypes.ExecutionReceipt));
        }
    }
}
