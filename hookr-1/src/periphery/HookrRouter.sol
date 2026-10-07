// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrRootRoute} from "../interfaces/IHookrRootRoute.sol";
import {IHookrRouter} from "../interfaces/IHookrRouter.sol";
import {IHookrForwarder} from "../interfaces/IHookrForwarder.sol";
import {IHookrSwapGate} from "../interfaces/IHookrSwapGate.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrEngagementReceiptSink} from "../interfaces/IHookrEngagementReceiptSink.sol";
import {HookrSettlement} from "../libraries/HookrSettlement.sol";
import {HookrSwapPreflight} from "../libraries/HookrSwapPreflight.sol";
import {HookrReleased} from "../base/HookrReleased.sol";

/// @title HookrRouter
/// @notice Single-pool swaps. Optional rewards run after settlement.
contract HookrRouter is HookrReleased, IHookrRouter, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    struct Request {
        Swap params;
        address payer; // Identity: hookData payer, receipt payer, Programs participant.
        address funder; // Pays the input: msg.sender on both entry points.
        uint256 outputFee; // Output-side relayer fee; zero on `swap`.
        bool receipt;
        address feeRecipient; // Receives `outputFee`; zero on `swap`.
    }

    struct Result {
        uint256 amountIn;
        uint256 amountOut;
        HookrTypes.ExecutionReceipt receipt;
    }

    /// @inheritdoc IHookrRouter
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrRouter
    IHookrRegistry public immutable registry;
    /// @inheritdoc IHookrRouter
    address public immutable forwarder;
    /// @inheritdoc IHookrRouter
    bytes32 public immutable forwarderCodeHash;
    /// @dev Gas forwarded to a root's `router()` getter.
    uint256 private constant ROUTER_PROBE_GAS = 10_000;
    /// @dev Gas kept above a gate's admitted gas, besides the 1/64 a call withholds, for the call itself.
    uint256 private constant GATE_CALL_RESERVE = 10_000;
    uint256 private _rewardNonce;
    /// @dev Swap state machine: 0 idle, 1 a gated swap's gate vouching, 2 entered, 3 in the unlock, 4 settled, 5
    ///      delivering. Cleared with the transaction.
    uint8 private transient _state;
    bytes32 private transient _pending;

    constructor(IPoolManager manager, IHookrRegistry _registry, address _forwarder) {
        if (
            address(manager).code.length == 0 || address(_registry).code.length == 0
                || address(_registry.poolManager()) != address(manager)
        ) revert InvalidPool();
        poolManager = manager;
        registry = _registry;
        if (_forwarder != address(0)) {
            if (
                _forwarder.code.length == 0 || IHookrForwarder(_forwarder).router() != address(this)
                    || IHookrForwarder(_forwarder).registry() != address(_registry)
            ) revert InvalidForwarder(_forwarder);
            forwarderCodeHash = _forwarder.codehash;
        }
        forwarder = _forwarder;
    }

    /// @inheritdoc IHookrRouter
    function swap(Swap calldata params, address engagement, uint256[] calldata campaigns)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut)
    {
        return _swap(params, msg.sender, 0, address(0), engagement, campaigns, false);
    }

    /// @inheritdoc IHookrRouter
    function swapFor(
        Swap calldata params,
        address payer,
        uint256 outputFee,
        address feeRecipient,
        address engagement,
        uint256[] calldata campaigns
    ) external returns (uint256 amountIn, uint256 amountOut) {
        address pinned = forwarder;
        if (msg.sender != pinned || pinned == address(0) || pinned.codehash != forwarderCodeHash) {
            revert NotForwarder(msg.sender);
        }
        if (payer == address(0)) revert InvalidSwap();
        if (Currency.unwrap(params.zeroForOne ? params.key.currency0 : params.key.currency1) == address(0)) {
            revert NativeInputUnsupported();
        }
        if ((outputFee == 0) != (feeRecipient == address(0)) || feeRecipient == address(this)) {
            revert InvalidFee(outputFee, feeRecipient);
        }
        (amountIn, amountOut) = _swap(params, payer, outputFee, feeRecipient, engagement, campaigns, true);
        emit SwapRelayed(params.key.toId(), payer, feeRecipient, outputFee);
    }

    /// @inheritdoc IHookrRouter
    function swapGated(
        Swap calldata params,
        address payer,
        address gate,
        bytes calldata data,
        address engagement,
        uint256[] calldata campaigns
    ) external payable returns (uint256 amountIn, uint256 amountOut) {
        if (payer == address(0) || gate == address(0)) revert InvalidSwap();
        if (_state != 0) revert Reentered();
        _state = 1;
        _vouch(address(params.key.hooks), gate, params, payer, data);
        _state = 0;
        // The same call `swap` makes, with the vouched payer: the optimizer keeps one copy of _swap for both.
        (amountIn, amountOut) = _swap(params, payer, 0, address(0), engagement, campaigns, false);
        emit SwapGated(params.key.toId(), payer, gate, msg.sender);
    }

    /// @dev The funder is always `msg.sender`: the user on `swap`, the pinned forwarder on `swapFor`, the gate's caller
    ///      on `swapGated`. A direct or gated swap requires a registered root that reports this router through a
    ///      bounded `router()` call, so roots without a pinned router, such as factory pair roots, are refused. A
    ///      relayed swap skips the root check: the pinned forwarder requires `registry.isRoot` and a root route for the
    ///      same key. A key its root did not initialize cannot exist, and every registered root shares the registry's
    ///      PoolManager. A gated swap's gate has vouched before this runs.
    ///      ERC-20 output goes from the PoolManager straight to `recipient` and `feeRecipient`, and a token that
    ///      calls its recipients runs their code inside the unlock; native output passes through this router so
    ///      that native recipients never run code inside the unlock.
    function _swap(
        Swap calldata params,
        address payer,
        uint256 outputFee,
        address feeRecipient,
        address engagement,
        uint256[] calldata campaigns,
        bool relayed
    ) private returns (uint256, uint256) {
        if (_state != 0) revert Reentered();
        _state = 2;
        if (
            !HookrSwapPreflight.passes(params, address(this), address(poolManager), forwarder) || campaigns.length > 8
                || (engagement == address(0) && campaigns.length != 0)
                || (engagement != address(0) && (campaigns.length == 0 || engagement.code.length == 0))
        ) {
            revert InvalidSwap();
        }
        IHookrRoot root = IHookrRoot(address(params.key.hooks));
        PoolId id = params.key.toId();
        if (!relayed && (!registry.isRoot(address(root)) || !_pinsThisRouter(address(root)))) revert InvalidPool();
        Currency input = params.zeroForOne ? params.key.currency0 : params.key.currency1;
        Currency output = params.zeroForOne ? params.key.currency1 : params.key.currency0;
        uint256 maximum = params.amountSpecified < 0 ? uint256(-int256(params.amountSpecified)) : params.amountBound;
        if (msg.value != (Currency.unwrap(input) == address(0) ? maximum : 0)) revert InvalidSwap();
        uint256 nativeBefore = address(this).balance - msg.value;
        bytes memory data =
            abi.encode(Request(params, payer, msg.sender, outputFee, engagement != address(0), feeRecipient));
        _pending = keccak256(data);
        Result memory result = abi.decode(poolManager.unlock(data), (Result));
        if (_state != 4) revert InvalidCallback();
        _state = 5;
        if (result.amountIn > maximum) revert Slippage();
        if (Currency.unwrap(output) == address(0)) {
            if (address(this).balance != nativeBefore + result.amountOut) revert HookrSettlement.BalanceMismatch();
            HookrSettlement.send(output, feeRecipient, outputFee);
            HookrSettlement.send(output, params.recipient, result.amountOut - outputFee);
        }
        if (Currency.unwrap(input) == address(0)) HookrSettlement.send(input, msg.sender, maximum - result.amountIn);
        if (address(this).balance != nativeBefore) revert HookrSettlement.BalanceMismatch();
        if (engagement != address(0)) {
            HookrTypes.ExecutionReceipt memory receipt = result.receipt;
            if (
                PoolId.unwrap(receipt.id) != PoolId.unwrap(id) || receipt.payer != payer
                    || receipt.beneficiary != params.recipient || receipt.inputAmount != result.amountIn
                    || receipt.outputAmount != result.amountOut || receipt.policyHash != root.policyHash(id)
                    || receipt.actualQuote == 0 || block.timestamp > type(uint64).max
            ) revert InvalidReceipt();
            IHookrEngagementReceiptSink(engagement)
                .recordExecution(
                    IHookrEngagementReceiptSink.EngagementReceipt({
                    chainId: block.chainid,
                    root: address(root),
                    poolId: PoolId.unwrap(id),
                    configHash: receipt.policyHash,
                    quoteAsset: _quoteOf(root, id),
                    participant: payer,
                    quoteVolume: receipt.actualQuote,
                    executionId: keccak256(abi.encode(block.chainid, address(this), ++_rewardNonce)),
                    executedAt: uint64(block.timestamp),
                    flowType: 0
                }),
                    campaigns
                );
        }
        emit SwapExecuted(id, payer, params.recipient, result.amountIn, result.amountOut);
        _state = 0;
        return (result.amountIn, result.amountOut);
    }

    /// @inheritdoc IHookrRouter
    function sweep(Currency currency, address to) external returns (uint256 amount) {
        if (_state != 0) revert Reentered();
        if (to == address(0) || to == address(this)) revert InvalidSwap();
        _state = 2;
        amount = HookrSettlement.balance(currency, address(this));
        if (amount != 0) HookrSettlement.send(currency, to, amount);
        _state = 0;
        emit Swept(currency, to, amount);
    }

    /// @inheritdoc IUnlockCallback
    /// @notice Executes only the committed swap and settles the caller's exact input and output.
    /// @dev First clears a currency an earlier call in the transaction left synced on the PoolManager (`sync` needs no
    ///      unlock): the root refuses a burning buy while the subject is synced, and any swap on a pool whose arb
    ///      recapture lane is on while any currency is. The router has no sync of its own open here. When nothing is
    ///      synced this costs one read.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _state != 2 || keccak256(data) != _pending) {
            revert InvalidCallback();
        }
        _state = 3;
        delete _pending;
        if (!poolManager.getSyncedCurrency().isAddressZero()) poolManager.sync(Currency.wrap(address(0)));
        Request memory request = abi.decode(data, (Request));
        Swap memory params = request.params;
        PoolId id = params.key.toId();
        BalanceDelta delta = poolManager.swap(
            params.key,
            SwapParams(params.zeroForOne, params.amountSpecified, params.sqrtPriceLimitX96),
            abi.encode(request.payer, params.recipient, id, request.receipt)
        );
        (int128 inDelta, int128 outDelta) =
            params.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (inDelta >= 0 || outDelta <= 0) revert InvalidSwap();
        Result memory result;
        result.amountIn = uint256(-int256(inDelta));
        result.amountOut = uint256(int256(outDelta));
        if (params.amountSpecified < 0) {
            if (
                result.amountIn > uint256(-int256(params.amountSpecified))
                    || result.amountOut < uint256(params.amountBound) + request.outputFee
            ) revert Slippage();
        } else {
            if (result.amountIn > params.amountBound || result.amountOut != uint128(params.amountSpecified)) {
                revert Slippage();
            }
            if (request.outputFee > result.amountOut) revert FeeExceedsOutput(request.outputFee, result.amountOut);
        }
        if (request.receipt) result.receipt = IHookrRoot(address(params.key.hooks)).takeReceipt(id);
        HookrSettlement.pay(
            poolManager,
            params.zeroForOne ? params.key.currency0 : params.key.currency1,
            request.funder,
            result.amountIn
        );
        Currency output = params.zeroForOne ? params.key.currency1 : params.key.currency0;
        if (Currency.unwrap(output) == address(0)) {
            HookrSettlement.take(poolManager, output, result.amountOut);
        } else {
            HookrSettlement.takeTo(poolManager, output, request.feeRecipient, request.outputFee);
            HookrSettlement.takeTo(poolManager, output, params.recipient, result.amountOut - request.outputFee);
        }
        _state = 4;
        return abi.encode(result);
    }

    /// @dev Refuses the swap while a brake holds `root` closed and the registry's owner can still reopen it
    ///      (`rootReopenable`), and unless `gate` is a live GATE admission of `root` whose runtime codehash is the
    ///      pinned one and, called with exactly the admission's gas, answers IHookrSwapGate.beforeUnlock with its
    ///      selector in one clean word. The gate always runs with all of that gas (InsufficientGateGas otherwise), so
    ///      the caller's gas limit can never change what it answers. Runs with the router locked (`_state` 1), so the
    ///      gate can enter no entry point of this router; only the first 32 bytes of its answer are copied.
    function _vouch(address root, address gate, Swap calldata params, address payer, bytes calldata data) private {
        if (registry.rootReopenable(root)) revert RootClosed(root);
        IHookrRegistry.Admission memory a = registry.admission(root, gate);
        if (a.kind != IHookrRegistry.Kind.GATE || a.implementation != gate) revert GateNotAdmitted(root, gate);
        if (gate.codehash != a.codeHash) revert GateCodeChanged(gate);
        bytes memory input = abi.encodeCall(
            IHookrSwapGate.beforeUnlock,
            (msg.sender, payer, params.key, params.zeroForOne, int256(params.amountSpecified), data)
        );
        bytes4 selector = IHookrSwapGate.beforeUnlock.selector;
        uint256 gasLimit = a.gasLimit;
        // A call passes on at most 63/64 of the gas left (EIP-150): keep enough that the gate runs with all of its gas.
        if (gasleft() < gasLimit + gasLimit / 63 + GATE_CALL_RESERVE) revert InsufficientGateGas(gate);
        bool vouched;
        assembly ("memory-safe") {
            let ok := call(gasLimit, gate, 0, add(input, 32), mload(input), 0, 32)
            vouched := and(and(ok, eq(returndatasize(), 32)), eq(mload(0), selector))
        }
        if (!vouched) revert GateRefused(gate);
    }

    /// @dev The pool's quote for the engagement receipt: the root's narrow read (`IHookrRootRoute.poolRoute`), or
    ///      `IHookrRoot.poolConfig` for a root without it, as HookrForwarder reads it. HookrRoot answers both from the
    ///      same stored quote, and the narrow read skips the whole configuration.
    function _quoteOf(IHookrRoot root, PoolId id) private view returns (address) {
        try IHookrRootRoute(address(root)).poolRoute(id) returns (Currency quote, address) {
            return Currency.unwrap(quote);
        } catch {
            return Currency.unwrap(root.poolConfig(id).quote);
        }
    }

    /// @dev Whether a bounded static call to `root.router()` returns exactly one word equal to this router.
    function _pinsThisRouter(address root) private view returns (bool pinned) {
        bytes4 selector = IHookrRoot.router.selector;
        assembly ("memory-safe") {
            mstore(0, selector)
            let ok := staticcall(ROUTER_PROBE_GAS, root, 0, 4, 0, 32)
            pinned := and(and(ok, eq(returndatasize(), 32)), eq(mload(0), address()))
        }
    }

    receive() external payable {
        if (msg.sender != address(poolManager) || _state != 3) revert InvalidCallback();
    }
}
