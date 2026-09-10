// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IHookrKernelIntegrationV1} from "./interfaces/IHookrKernelIntegrationV1.sol";
import {IHookrStackRegistryV1} from "./interfaces/IHookrStackRegistryV1.sol";
import {HookrModuleTypesV1} from "./libraries/HookrModuleTypesV1.sol";

/// @title Hookr Kernel Quoter V1
/// @notice State-reverting exact quote boundary for frozen SWAP_DELTA_V1 stacks.
/// @dev A successful callback deliberately reverts with QuoteResult. The external quote function
///      catches that typed revert after PoolManager and all hook/module state have rolled back.
contract HookrKernelQuoterV1 is IUnlockCallback, IHookrKernelIntegrationV1 {
    using PoolIdLibrary for PoolKey;

    bytes32 public constant KERNEL_FAMILY_ID = keccak256("HOOKR_SWAP_DELTA_V1");
    bytes32 public constant QUOTER_INTEGRATION_KIND = keccak256("HOOKR_KERNEL_INTEGRATION_QUOTER");
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;
    uint160 public constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 public constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 public constant MAX_MODULE_DATA_LENGTH = 3_904;

    bytes4 private constant POOL_MANAGER_SELECTOR = bytes4(keccak256("poolManager()"));
    bytes4 private constant INTEGRATION_ID_FOR_SELECTOR = bytes4(keccak256("integrationIdFor(address)"));

    IPoolManager public immutable override poolManager;
    IHookrStackRegistryV1 public immutable override stackRegistry;

    // 1 = idle, 2 = unlock requested, 3 = inside callback. State 3 always rolls back.
    uint256 private _callbackState = 1;

    /// @dev Negative amountSpecified is exact input with amountBound=minOut. Positive is exact
    ///      output with amountBound=maxIn.
    struct QuoteParams {
        PoolKey key;
        address payer;
        address recipient;
        bool zeroForOne;
        int128 amountSpecified;
        uint128 amountBound;
        uint160 sqrtPriceLimitX96;
    }

    struct CallbackData {
        QuoteParams params;
        bytes moduleData;
    }

    /// @notice Internal successful simulation result; quote() catches and authenticates it.
    error QuoteResult(bytes32 quoteId, uint128 amountIn, uint128 amountOut);

    error InvalidWiring();
    error Reentrancy();
    error NotPoolManager();
    error CallbackNotActive();
    error InvalidStack();
    error StackNotInitialized();
    error UntrustedStackQuoter(address expected, address actual);
    error InvalidIdentity();
    error InvalidAmount();
    error InvalidAmountBound();
    error InvalidSqrtPriceLimit();
    error ModuleDataTooLarge();
    error UnexpectedDelta();
    error TooLittleReceived(uint256 minimum, uint256 received);
    error TooMuchRequested(uint256 maximum, uint256 requested);
    error InvalidQuoteResult();
    error SimulationDidNotRevert();

    constructor(IPoolManager poolManager_, IHookrStackRegistryV1 stackRegistry_) {
        if (
            address(poolManager_) == address(0) || address(poolManager_).code.length == 0
                || address(stackRegistry_) == address(0) || address(stackRegistry_).code.length == 0
        ) revert InvalidWiring();
        (bool ok, uint256 result) =
            _staticcallWord(address(stackRegistry_), type(uint256).max, abi.encodeWithSelector(POOL_MANAGER_SELECTOR));
        if (!ok || result > type(uint160).max) revert InvalidWiring();
        // `result` is explicitly bounded to uint160 immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(uint160(result)) != address(poolManager_)) {
            revert InvalidWiring();
        }
        poolManager = poolManager_;
        stackRegistry = stackRegistry_;
    }

    function contractName() external pure returns (string memory) {
        return "HookrKernelQuoterV1";
    }

    function contractVersion() external pure returns (string memory) {
        return "1.1.0";
    }

    function integrationKind() external pure override returns (bytes32) {
        return QUOTER_INTEGRATION_KIND;
    }

    function integrationFamilyId() external pure override returns (bytes32) {
        return KERNEL_FAMILY_ID;
    }

    function integrationVersion() external pure override returns (uint32) {
        return 1;
    }

    /// @notice Returns the final delta-aware amounts while reverting all simulated state changes.
    function quote(QuoteParams calldata params, bytes calldata moduleData)
        external
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (_callbackState != 1) revert Reentrancy();
        _validate(params, moduleData.length);

        bytes memory callbackData = abi.encode(CallbackData({params: params, moduleData: moduleData}));
        bytes32 expectedQuoteId = keccak256(callbackData);
        _callbackState = 2;
        try poolManager.unlock(callbackData) returns (bytes memory) {
            revert SimulationDidNotRevert();
        } catch (bytes memory reason) {
            (uint128 quotedIn, uint128 quotedOut) = _decodeQuoteResult(reason, expectedQuoteId);
            _callbackState = 1;
            return (quotedIn, quotedOut);
        }
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (_callbackState != 2) revert CallbackNotActive();
        _callbackState = 3;

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        HookrModuleTypesV1.StackCore memory core = _validate(data.params, data.moduleData.length);

        // HookrHookDataV1.encode is internal. Keep this raw encoding byte-for-byte canonical.
        bytes memory hookData =
            abi.encode(uint256(1), data.params.payer, data.params.recipient, core.stackHash, data.moduleData);
        BalanceDelta delta = poolManager.swap(
            data.params.key,
            SwapParams({
                zeroForOne: data.params.zeroForOne,
                amountSpecified: int256(data.params.amountSpecified),
                sqrtPriceLimitX96: data.params.sqrtPriceLimitX96
            }),
            hookData
        );
        (uint128 amountIn, uint128 amountOut) = _amounts(data.params, delta);
        revert QuoteResult(keccak256(rawData), amountIn, amountOut);
    }

    function _validate(QuoteParams memory params, uint256 moduleDataLength)
        internal
        view
        returns (HookrModuleTypesV1.StackCore memory core)
    {
        if (
            params.payer == address(0) || params.recipient == address(0) || params.payer == address(this)
                || params.recipient == address(this)
        ) revert InvalidIdentity();
        if (params.amountSpecified == 0 || params.amountSpecified == type(int128).min) revert InvalidAmount();
        if (params.amountBound == 0 || params.amountBound > uint128(type(int128).max)) {
            revert InvalidAmountBound();
        }
        if (params.sqrtPriceLimitX96 < MIN_SQRT_PRICE_LIMIT || params.sqrtPriceLimitX96 > MAX_SQRT_PRICE_LIMIT) {
            revert InvalidSqrtPriceLimit();
        }
        if (moduleDataLength > MAX_MODULE_DATA_LENGTH) revert ModuleDataTooLarge();
        core = _checkedCore(params.key);
    }

    function _checkedCore(PoolKey memory key) internal view returns (HookrModuleTypesV1.StackCore memory core) {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        bytes32 registeredIntegrationId = _registeredIntegrationId();
        core = stackRegistry.stack(key.toId());
        if (!core.configured) revert InvalidStack();
        if (!core.initialized) revert StackNotInitialized();
        if (core.limits.trustedQuoter != address(this)) {
            revert UntrustedStackQuoter(address(this), core.limits.trustedQuoter);
        }
        if (
            key.fee != DYNAMIC_FEE_FLAG || uint160(currency0) >= uint160(currency1) || address(key.hooks) != core.kernel
                || core.kernel == address(0) || core.kernelId == bytes32(0) || core.kernelFamilyId != KERNEL_FAMILY_ID
                || core.kernelCodeHash == bytes32(0) || core.kernel.code.length == 0
                || core.kernelCodeHash != core.kernel.codehash || core.stackHash == bytes32(0)
                || core.trustedQuoterIntegrationId != registeredIntegrationId
                || core.trustedQuoterCodeHash != address(this).codehash || core.subject == core.quote
                || core.subject == address(0)
                || !((currency0 == core.subject && currency1 == core.quote)
                    || (currency0 == core.quote && currency1 == core.subject))
        ) revert InvalidStack();
    }

    function _registeredIntegrationId() internal view returns (bytes32 integrationId) {
        (bool ok, uint256 result) = _staticcallWord(
            address(stackRegistry),
            type(uint256).max,
            abi.encodeWithSelector(INTEGRATION_ID_FOR_SELECTOR, address(this))
        );
        if (!ok) revert InvalidStack();
        integrationId = bytes32(result);
        if (integrationId == bytes32(0)) revert InvalidStack();
    }

    function _staticcallWord(address target, uint256 gasLimit, bytes memory input)
        internal
        view
        returns (bool ok, uint256 word)
    {
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(gasLimit, target, add(input, 0x20), mload(input), 0, 0x20)
            if iszero(eq(returndatasize(), 0x20)) { ok := 0 }
            word := mload(0)
        }
    }

    function _amounts(QuoteParams memory params, BalanceDelta delta)
        internal
        pure
        returns (uint128 amountIn, uint128 amountOut)
    {
        (int128 inputDelta, int128 outputDelta) =
            params.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (inputDelta >= 0 || outputDelta <= 0) revert UnexpectedDelta();
        // Sign checks above and the explicit bounds below make these conversions lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 input = uint256(-int256(inputDelta));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 output = uint256(int256(outputDelta));
        if (input > uint256(uint128(type(int128).max)) || output > uint256(uint128(type(int128).max))) {
            revert UnexpectedDelta();
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        amountIn = uint128(input);
        // forge-lint: disable-next-line(unsafe-typecast)
        amountOut = uint128(output);

        if (params.amountSpecified < 0) {
            uint256 specifiedInput = uint256(-int256(params.amountSpecified));
            if (input > specifiedInput) revert UnexpectedDelta();
            if (output < params.amountBound) revert TooLittleReceived(params.amountBound, output);
        } else {
            if (input > params.amountBound) revert TooMuchRequested(params.amountBound, input);
            uint256 specifiedOutput = uint256(uint128(params.amountSpecified));
            if (output < specifiedOutput) revert TooLittleReceived(specifiedOutput, output);
        }
    }

    function _decodeQuoteResult(bytes memory reason, bytes32 expectedQuoteId)
        internal
        pure
        returns (uint128 amountIn, uint128 amountOut)
    {
        if (reason.length < 4) _bubble(reason);
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
        if (selector != QuoteResult.selector) _bubble(reason);
        if (reason.length != 100) revert InvalidQuoteResult();

        bytes32 quoteId;
        uint256 rawAmountIn;
        uint256 rawAmountOut;
        assembly ("memory-safe") {
            quoteId := mload(add(reason, 0x24))
            rawAmountIn := mload(add(reason, 0x44))
            rawAmountOut := mload(add(reason, 0x64))
        }
        if (
            quoteId != expectedQuoteId || rawAmountIn > uint256(uint128(type(int128).max))
                || rawAmountOut > uint256(uint128(type(int128).max))
        ) revert InvalidQuoteResult();
        // The preceding checks bound both decoded words below int128.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        amountIn = uint128(rawAmountIn);
        // forge-lint: disable-next-line(unsafe-typecast)
        amountOut = uint128(rawAmountOut);
    }

    function _bubble(bytes memory reason) internal pure {
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
