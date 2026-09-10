// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IHookrKernelRouterV2} from "../interfaces/IHookrKernelRouterV2.sol";

/// @title Hookr Market Coordinator Initial Buy Lib V4
/// @notice Validation and execution boundary for the optional initial creator buy.
/// @dev V4 differences from `HookrMarketCoordinatorInitialBuyLibV3` (which is deployed and left
///      untouched):
///      1. The native-only gate is gone. A creator buy is available on every quote currency - ETH,
///         HOOKR, USDG, stock tokens, any ERC-20. Native value is forwarded only for a native
///         quote; for an ERC-20 quote the router pulls `quoteAmountIn` from the creator, who must
///         have approved the router beforehand, and the coordinator's own payment check already
///         requires `msg.value == 0`.
///      2. The settlement event names the subject explicitly instead of assuming it is
///         `key.currency1`. With an ERC-20 quote the subject may sort into `currency0`.
///      3. The router integration version required is 3 (`HookrKernelRouterV3`), whose
///         `exactInputInitialBuy` is ordering-aware.
library HookrMarketCoordinatorInitialBuyLibV4 {
    uint256 internal constant MAX_MODULE_DATA_LENGTH = 3_904;
    /// @notice Router integration version this library will execute a creator buy through.
    uint32 internal constant REQUIRED_ROUTER_INTEGRATION_VERSION = 3;
    uint256 private constant QUERY_GAS = 50_000;
    bytes4 private constant ROUTER_COORDINATOR_SELECTOR = bytes4(keccak256("coordinator()"));
    bytes4 private constant ROUTER_COORDINATOR_CODE_HASH_SELECTOR = bytes4(keccak256("coordinatorCodeHash()"));
    bytes4 private constant POOL_MANAGER_SELECTOR = bytes4(keccak256("poolManager()"));
    bytes4 private constant STACK_REGISTRY_SELECTOR = bytes4(keccak256("stackRegistry()"));
    bytes4 private constant INTEGRATION_VERSION_SELECTOR = bytes4(keccak256("integrationVersion()"));

    /// @notice Settlement identity for one initial creator buy, resolved by the coordinator.
    struct EmitContext {
        /// @notice Pool receiving the buy.
        PoolId poolId;
        /// @notice Subject token delivered by the buy.
        address subject;
        /// @notice Optional creator intent identifier.
        bytes32 intentId;
        /// @notice Commitment to the immutable hook stack.
        bytes32 stackHash;
        /// @notice Quote currency of the market; `address(0)` is native.
        address quote;
        /// @notice Router selected by the immutable stack.
        address router;
        /// @notice Compatibility field; always zero after quantization dust is burned.
        uint256 subjectSeedResidue;
        /// @notice Compatibility field; always zero because quote is not seeded.
        uint256 quoteSeedResidue;
    }

    event CreatorBuyExecuted(
        PoolId indexed poolId,
        address indexed subject,
        address indexed creator,
        bytes32 intentId,
        bytes32 stackHash,
        address router,
        uint256 requestedQuoteIn,
        uint256 actualQuoteIn,
        uint256 subjectOut,
        uint256 subjectOutMinimum,
        bytes32 moduleDataHash,
        uint256 creatorAllocation,
        uint256 subjectSeedResidue,
        uint256 quoteSeedResidue
    );

    error InvalidInitialBuy();
    error InitialBuyInputMismatch(uint256 expected, uint256 actual);

    /// @notice Validates optional initial-buy parameters and immutable router wiring.
    /// @dev A zero quote amount requires all companion buy fields to be empty. Every quote currency
    ///      is accepted for a nonzero buy.
    /// @param poolManager PoolManager expected from the router.
    /// @param stackRegistry Stack registry expected from the router.
    /// @param router Router selected by the immutable stack.
    /// @param quoteAmountIn Exact quote input, or zero to disable the buy.
    /// @param subjectAmountOutMinimum Minimum subject output for a nonzero buy.
    /// @param deadline Last block timestamp at which a nonzero buy may execute.
    /// @param moduleData Encoded data forwarded to the market's hook stack.
    function validate(
        address poolManager,
        address stackRegistry,
        address router,
        uint128 quoteAmountIn,
        uint128 subjectAmountOutMinimum,
        uint256 deadline,
        bytes calldata moduleData
    ) public view {
        if (quoteAmountIn == 0) {
            if (subjectAmountOutMinimum != 0 || deadline != 0 || moduleData.length != 0) {
                revert InvalidInitialBuy();
            }
            return;
        }
        // Inclusion-time expiry is the user-authorized execution bound.
        // forge-lint: disable-next-line(block-timestamp)
        bool expired = block.timestamp > deadline;
        if (
            quoteAmountIn > uint128(type(int128).max) || subjectAmountOutMinimum == 0 || expired
                || moduleData.length > MAX_MODULE_DATA_LENGTH || router == address(0) || router.code.length == 0
        ) revert InvalidInitialBuy();
        if (
            _readAddress(router, ROUTER_COORDINATOR_SELECTOR) != address(this)
                || _readAddress(router, POOL_MANAGER_SELECTOR) != poolManager
                || _readAddress(router, STACK_REGISTRY_SELECTOR) != stackRegistry
        ) revert InvalidInitialBuy();
        (bool ok, uint256 result) = _staticcallWord(router, abi.encodeWithSelector(INTEGRATION_VERSION_SELECTOR));
        if (!ok || result != REQUIRED_ROUTER_INTEGRATION_VERSION) revert InvalidInitialBuy();
        (ok, result) = _staticcallWord(router, abi.encodeWithSelector(ROUTER_COORDINATOR_CODE_HASH_SELECTOR));
        if (!ok || bytes32(result) != address(this).codehash) revert InvalidInitialBuy();
    }

    /// @notice Executes an initial creator buy and emits its settlement values from the coordinator.
    /// @dev Native value is attached only for a native quote. For an ERC-20 quote the router pulls
    ///      the input from the creator's own approval, so nothing flows through the coordinator.
    /// @param context Pool, subject, quote, router and intent identity for the emitted event.
    /// @param params Pool, creator, input, slippage, and deadline parameters.
    /// @param moduleData Encoded data forwarded to the market's hook stack.
    /// @return actualQuoteIn Quote amount consumed by the buy.
    /// @return subjectOut Subject amount delivered to the creator.
    function executeAndEmit(
        EmitContext memory context,
        IHookrKernelRouterV2.InitialBuyParams memory params,
        bytes calldata moduleData
    ) public returns (uint256 actualQuoteIn, uint256 subjectOut) {
        uint256 nativeValue = context.quote == address(0) ? params.quoteAmountIn : 0;
        (actualQuoteIn, subjectOut) =
            IHookrKernelRouterV2(context.router).exactInputInitialBuy{value: nativeValue}(params, moduleData);
        if (actualQuoteIn != params.quoteAmountIn) {
            revert InitialBuyInputMismatch(params.quoteAmountIn, actualQuoteIn);
        }
        emit CreatorBuyExecuted(
            context.poolId,
            context.subject,
            params.creator,
            context.intentId,
            context.stackHash,
            context.router,
            params.quoteAmountIn,
            actualQuoteIn,
            subjectOut,
            params.subjectAmountOutMinimum,
            keccak256(moduleData),
            0,
            context.subjectSeedResidue,
            context.quoteSeedResidue
        );
    }

    function _readAddress(address target, bytes4 selector) private view returns (address value) {
        (bool ok, uint256 result) = _staticcallWord(target, abi.encodeWithSelector(selector));
        if (!ok || result > type(uint160).max) revert InvalidInitialBuy();
        // The preceding bound proves this conversion cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        value = address(uint160(result));
    }

    function _staticcallWord(address target, bytes memory input) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(QUERY_GAS, target, add(input, 0x20), mload(input), 0, 0x20)
            if iszero(eq(returndatasize(), 0x20)) { ok := 0 }
            word := mload(0)
        }
    }
}
