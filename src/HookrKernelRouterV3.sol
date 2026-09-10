// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IHookrKernelIntegrationV1} from "./interfaces/IHookrKernelIntegrationV1.sol";
import {IHookrKernelRouterV2} from "./interfaces/IHookrKernelRouterV2.sol";
import {IHookrStackRegistryV1} from "./interfaces/IHookrStackRegistryV1.sol";
import {HookrModuleTypesV1} from "./libraries/HookrModuleTypesV1.sol";

/// @title Hookr Kernel Router V3
/// @notice Exact-input and exact-output settlement boundary for frozen SWAP_DELTA_V1 stacks.
/// @dev Output is first taken into this contract and delivered after the PoolManager relocks, keeping
///      recipient callbacks outside the unlock. ERC20 paths compare router and recipient balance
///      changes; native paths require a successful transfer and no retained router balance.
/// @dev V3 differences from `HookrKernelRouterV2` (deployed and left untouched): the initial
///      creator buy works on every quote currency. The input currency is the market's *quote*,
///      which may sort into `currency1`, so the direction, the price limit, the native-value check
///      and the retained-balance check are all derived from the frozen subject/quote identity
///      instead of assuming a native `currency0`. An ERC-20 quote is pulled from the creator by the
///      same `_settle` path every other swap uses, so the creator must approve this router for
///      `quoteAmountIn` before the launch transaction. `KERNEL_FAMILY_ID` is unchanged; the
///      registry integration version is 3.
contract HookrKernelRouterV3 is IUnlockCallback, IHookrKernelIntegrationV1, IHookrKernelRouterV2 {
    using PoolIdLibrary for PoolKey;

    /// @notice Kernel family supported by this router.
    bytes32 public constant KERNEL_FAMILY_ID = keccak256("HOOKR_SWAP_DELTA_V1");
    /// @notice Integration kind used by the stack registry.
    bytes32 public constant ROUTER_INTEGRATION_KIND = keccak256("HOOKR_KERNEL_INTEGRATION_ROUTER");
    /// @notice Uniswap v4 dynamic-fee flag required by supported pools.
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;
    /// @notice Inclusive lower square-root price bound accepted by the router.
    uint160 public constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    /// @notice Inclusive upper square-root price bound accepted by the router.
    uint160 public constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    /// @notice Maximum hook module-data length accepted by a swap.
    uint256 public constant MAX_MODULE_DATA_LENGTH = 3_904;
    uint256 private constant TOKEN_QUERY_GAS = 50_000;

    bytes4 private constant POOL_MANAGER_SELECTOR = bytes4(keccak256("poolManager()"));
    bytes4 private constant STACK_REGISTRY_SELECTOR = bytes4(keccak256("stackRegistry()"));
    bytes4 private constant COORDINATOR_SELECTOR = bytes4(keccak256("coordinator()"));
    bytes4 private constant INTEGRATION_ID_FOR_SELECTOR = bytes4(keccak256("integrationIdFor(address)"));

    /// @notice Uniswap v4 PoolManager used for swaps and settlement.
    IPoolManager public immutable override poolManager;
    /// @notice Registry containing the immutable stack for each supported pool.
    IHookrStackRegistryV1 public immutable override stackRegistry;
    /// @notice Coordinator authorized to execute an initial creator buy.
    address public immutable coordinator;
    /// @notice Runtime code hash expected from the coordinator.
    bytes32 public immutable coordinatorCodeHash;

    // 1 = idle, 2 = unlock requested, 3 = inside callback, 4 = callback completed.
    uint256 private _callbackState = 1;

    /// @notice Parameters for a swap with a caller-specified maximum input.
    struct ExactInputParams {
        /// @notice Pool key for the swap.
        PoolKey key;
        /// @notice True to swap currency0 for currency1.
        bool zeroForOne;
        /// @notice Maximum input amount in input-currency base units.
        uint128 amountIn;
        /// @notice Minimum output amount in output-currency base units.
        uint128 amountOutMinimum;
        /// @notice Square-root price limit encoded as Q64.96.
        uint160 sqrtPriceLimitX96;
        /// @notice Account receiving output currency.
        address recipient;
        /// @notice Last block timestamp at which the swap may execute.
        uint256 deadline;
    }

    /// @notice Parameters for a swap requiring a fixed output amount.
    struct ExactOutputParams {
        /// @notice Pool key for the swap.
        PoolKey key;
        /// @notice True to swap currency0 for currency1.
        bool zeroForOne;
        /// @notice Output amount required in output-currency base units.
        uint128 amountOut;
        /// @notice Maximum input amount in input-currency base units.
        uint128 amountInMaximum;
        /// @notice Square-root price limit encoded as Q64.96.
        uint160 sqrtPriceLimitX96;
        /// @notice Account receiving output currency.
        address recipient;
        /// @notice Last block timestamp at which the swap may execute.
        uint256 deadline;
    }

    struct CallbackData {
        address payer;
        address recipient;
        PoolKey key;
        SwapParams swapParams;
        bool exactInput;
        bool requireFullInput;
        uint128 amountBound;
        bytes moduleData;
    }

    struct CallbackResult {
        uint128 amountIn;
        uint128 amountOut;
        uint256 outputBalanceBefore;
    }

    /// @notice Emitted after a swap settles and output is delivered.
    /// @param poolId Pool that executed the swap.
    /// @param stackHash Commitment to the immutable hook stack.
    /// @param payer Account funding the input currency.
    /// @param recipient Account receiving the output currency.
    /// @param kernel Root hook implementation bound to the pool.
    /// @param currencyIn Input ERC20 address, or address(0) for native currency.
    /// @param currencyOut Output ERC20 address, or address(0) for native currency.
    /// @param exactInput True for a maximum-input swap and false for a fixed-output swap.
    /// @param amountIn Input amount consumed.
    /// @param amountOut Output amount delivered.
    /// @param moduleDataHash Hash of module data forwarded to the hook stack.
    event SwapExecuted(
        PoolId indexed poolId,
        bytes32 indexed stackHash,
        address indexed payer,
        address recipient,
        address kernel,
        address currencyIn,
        address currencyOut,
        bool exactInput,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 moduleDataHash
    );

    error InvalidWiring();
    error NotCoordinator(address expected, address actual);
    error CoordinatorCodeHashMismatch(bytes32 expected, bytes32 actual);
    error Reentrancy();
    error NotPoolManager();
    error CallbackNotActive();
    error CallbackNotCompleted();
    error DeadlineExpired(uint256 deadline, uint256 timestamp);
    error InvalidStack();
    error StackNotInitialized();
    error UntrustedStackRouter(address expected, address actual);
    error InvalidRecipient();
    error InvalidAmount();
    error InvalidSqrtPriceLimit();
    error ModuleDataTooLarge();
    error InvalidNativeValue(uint256 expected, uint256 received);
    error TooLittleReceived(uint256 minimum, uint256 received);
    error TooMuchRequested(uint256 maximum, uint256 requested);
    error PartialFill(uint256 expected, uint256 actual);
    error UnexpectedDelta();
    error TransferFailed();
    error BalanceQueryFailed();
    error InputDebitMismatch(uint256 expected, uint256 debited);
    error SettlementMismatch(uint256 expected, uint256 settled);
    error OutputCustodyMismatch(uint256 expected, uint256 received);
    error OutputDeliveryMismatch(uint256 expected, uint256 received);
    error RetainedBalance(address currency, uint256 expected, uint256 actual);
    error UnexpectedNativeSender();

    /// @notice Initializes the router with immutable PoolManager, registry, and coordinator wiring.
    /// @param poolManager_ Uniswap v4 PoolManager used for swaps and settlement.
    /// @param stackRegistry_ Registry containing immutable pool stacks.
    /// @param coordinator_ Coordinator authorized to execute initial creator buys.
    constructor(IPoolManager poolManager_, IHookrStackRegistryV1 stackRegistry_, address coordinator_) {
        if (
            address(poolManager_) == address(0) || address(poolManager_).code.length == 0
                || address(stackRegistry_) == address(0) || address(stackRegistry_).code.length == 0
                || coordinator_ == address(0) || coordinator_.code.length == 0
        ) revert InvalidWiring();
        (bool ok, uint256 result) =
            _staticcallWord(address(stackRegistry_), type(uint256).max, abi.encodeWithSelector(POOL_MANAGER_SELECTOR));
        if (!ok || result > type(uint160).max) revert InvalidWiring();
        // `result` is explicitly bounded to uint160 immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(uint160(result)) != address(poolManager_)) {
            revert InvalidWiring();
        }
        (ok, result) =
            _staticcallWord(address(stackRegistry_), type(uint256).max, abi.encodeWithSelector(COORDINATOR_SELECTOR));
        if (!ok || result > type(uint160).max) revert InvalidWiring();
        // The preceding bound proves this conversion cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(uint160(result)) != coordinator_) revert InvalidWiring();
        (ok, result) = _staticcallWord(coordinator_, type(uint256).max, abi.encodeWithSelector(POOL_MANAGER_SELECTOR));
        if (!ok || result > type(uint160).max) revert InvalidWiring();
        // The preceding bound proves this conversion cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(uint160(result)) != address(poolManager_)) revert InvalidWiring();
        (ok, result) = _staticcallWord(coordinator_, type(uint256).max, abi.encodeWithSelector(STACK_REGISTRY_SELECTOR));
        if (!ok || result > type(uint160).max) revert InvalidWiring();
        // The preceding bound proves this conversion cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(uint160(result)) != address(stackRegistry_)) revert InvalidWiring();
        poolManager = poolManager_;
        stackRegistry = stackRegistry_;
        coordinator = coordinator_;
        coordinatorCodeHash = coordinator_.codehash;
    }

    modifier nonReentrant() {
        if (_callbackState != 1) revert Reentrancy();
        _callbackState = 2;
        _;
        _callbackState = 1;
    }

    /// @notice Returns the contract's release name.
    /// @return Contract name.
    function contractName() external pure returns (string memory) {
        return "HookrKernelRouterV3";
    }

    /// @notice Returns the contract's semantic version.
    /// @return Contract version.
    function contractVersion() external pure returns (string memory) {
        return "3.0.0";
    }

    /// @notice Returns the stack-registry integration kind.
    /// @return Integration kind identifier.
    function integrationKind() external pure override returns (bytes32) {
        return ROUTER_INTEGRATION_KIND;
    }

    /// @notice Returns the supported kernel family.
    /// @return Kernel-family identifier.
    function integrationFamilyId() external pure override returns (bytes32) {
        return KERNEL_FAMILY_ID;
    }

    /// @notice Returns the router integration version.
    /// @return Integration version.
    function integrationVersion() external pure override returns (uint32) {
        return 3;
    }

    /// @notice Swaps up to a specified input amount through an initialized immutable stack.
    /// @dev For native input, msg.value must equal amountIn and unused input is refunded. For ERC20
    ///      input, msg.value must be zero and the payer must approve this router. A price limit may
    ///      cause a partial fill; the minimum-output bound still applies.
    /// @param params Pool, direction, amount, price, recipient, and deadline parameters.
    /// @param moduleData Encoded data forwarded to the pool's hook stack.
    /// @return amountOut Output amount delivered to the recipient.
    function exactInput(ExactInputParams calldata params, bytes calldata moduleData)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        HookrModuleTypesV1.StackCore memory core = _validate(
            params.key, params.recipient, params.deadline, params.amountIn, params.sqrtPriceLimitX96, moduleData.length
        );
        if (params.amountOutMinimum == 0) revert InvalidAmount();

        Currency inputCurrency = params.zeroForOne ? params.key.currency0 : params.key.currency1;
        _validateNativeValue(inputCurrency, params.amountIn);
        uint256 nativeBalanceBefore = address(this).balance - msg.value;
        uint256 inputBalanceBefore = _routerTokenBalance(inputCurrency);

        CallbackData memory data = CallbackData({
            payer: msg.sender,
            recipient: params.recipient,
            key: params.key,
            swapParams: SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: -int256(uint256(params.amountIn)),
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            }),
            exactInput: true,
            requireFullInput: false,
            amountBound: params.amountOutMinimum,
            moduleData: moduleData
        });
        CallbackResult memory result = _execute(data, core, params.amountIn, nativeBalanceBefore, inputBalanceBefore);
        return result.amountOut;
    }

    /// @notice Swaps for a fixed output amount through an initialized immutable stack.
    /// @dev For native input, msg.value must equal amountInMaximum and unused input is refunded. For
    ///      ERC20 input, msg.value must be zero and the payer must approve this router.
    /// @param params Pool, direction, amount, price, recipient, and deadline parameters.
    /// @param moduleData Encoded data forwarded to the pool's hook stack.
    /// @return amountIn Input amount consumed from the payer.
    function exactOutput(ExactOutputParams calldata params, bytes calldata moduleData)
        external
        payable
        nonReentrant
        returns (uint256 amountIn)
    {
        HookrModuleTypesV1.StackCore memory core = _validate(
            params.key, params.recipient, params.deadline, params.amountOut, params.sqrtPriceLimitX96, moduleData.length
        );
        if (params.amountInMaximum == 0 || params.amountInMaximum > uint128(type(int128).max)) {
            revert InvalidAmount();
        }

        Currency inputCurrency = params.zeroForOne ? params.key.currency0 : params.key.currency1;
        _validateNativeValue(inputCurrency, params.amountInMaximum);
        uint256 nativeBalanceBefore = address(this).balance - msg.value;
        uint256 inputBalanceBefore = _routerTokenBalance(inputCurrency);

        CallbackData memory data = CallbackData({
            payer: msg.sender,
            recipient: params.recipient,
            key: params.key,
            swapParams: SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: int256(uint256(params.amountOut)),
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            }),
            exactInput: false,
            requireFullInput: false,
            amountBound: params.amountInMaximum,
            moduleData: moduleData
        });
        CallbackResult memory result =
            _execute(data, core, params.amountInMaximum, nativeBalanceBefore, inputBalanceBefore);
        return result.amountIn;
    }

    /// @inheritdoc IHookrKernelRouterV2
    function exactInputInitialBuy(IHookrKernelRouterV2.InitialBuyParams calldata params, bytes calldata moduleData)
        external
        payable
        override
        nonReentrant
        returns (uint256 quoteAmountIn, uint256 subjectAmountOut)
    {
        if (msg.sender != coordinator) revert NotCoordinator(coordinator, msg.sender);
        bytes32 actualCoordinatorCodeHash = coordinator.codehash;
        if (actualCoordinatorCodeHash != coordinatorCodeHash) {
            revert CoordinatorCodeHashMismatch(coordinatorCodeHash, actualCoordinatorCodeHash);
        }

        // The buy spends the market's quote, whichever side it sorts to. The direction therefore
        // depends on the frozen stack, so the core is read first and the shared `_validate` checks
        // are applied inline rather than re-reading the registry to learn the price limit.
        HookrModuleTypesV1.StackCore memory core = _checkedCore(params.key);
        // A deadline is intentionally enforced against the inclusion timestamp.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > params.deadline) revert DeadlineExpired(params.deadline, block.timestamp);
        if (params.creator == address(0) || params.creator == address(this)) revert InvalidRecipient();
        if (params.quoteAmountIn == 0 || params.quoteAmountIn > uint128(type(int128).max)) revert InvalidAmount();
        if (moduleData.length > MAX_MODULE_DATA_LENGTH) revert ModuleDataTooLarge();
        if (params.subjectAmountOutMinimum == 0 || core.subject == address(0)) revert InvalidStack();

        // `_checkedCore` already proved the key's two currencies are exactly {subject, quote}, so
        // one comparison fixes the direction, the canonical full-fill limit and the input currency.
        bool quoteIsCurrency0 = Currency.unwrap(params.key.currency0) == core.quote;
        uint160 priceLimit = quoteIsCurrency0 ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT;

        Currency inputCurrency = quoteIsCurrency0 ? params.key.currency0 : params.key.currency1;
        _validateNativeValue(inputCurrency, params.quoteAmountIn);
        uint256 nativeBalanceBefore = address(this).balance - msg.value;
        uint256 inputBalanceBefore = _routerTokenBalance(inputCurrency);
        CallbackData memory data = CallbackData({
            payer: params.creator,
            recipient: params.creator,
            key: params.key,
            swapParams: SwapParams({
                zeroForOne: quoteIsCurrency0,
                amountSpecified: -int256(uint256(params.quoteAmountIn)),
                sqrtPriceLimitX96: priceLimit
            }),
            exactInput: true,
            requireFullInput: true,
            amountBound: params.subjectAmountOutMinimum,
            moduleData: moduleData
        });
        CallbackResult memory result =
            _execute(data, core, params.quoteAmountIn, nativeBalanceBefore, inputBalanceBefore);
        return (result.amountIn, result.amountOut);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (_callbackState != 2) revert CallbackNotActive();
        _callbackState = 3;

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        HookrModuleTypesV1.StackCore memory core = _checkedCore(data.key);
        _validateCallbackData(data);

        // HookrHookDataV1.encode is internal. Keep this raw encoding byte-for-byte canonical.
        bytes memory hookData = abi.encode(uint256(1), data.payer, data.recipient, core.stackHash, data.moduleData);
        BalanceDelta delta = poolManager.swap(data.key, data.swapParams, hookData);
        (uint128 amountIn, uint128 amountOut) = _amounts(data, delta);

        Currency inputCurrency = data.swapParams.zeroForOne ? data.key.currency0 : data.key.currency1;
        Currency outputCurrency = data.swapParams.zeroForOne ? data.key.currency1 : data.key.currency0;
        _settle(inputCurrency, data.payer, amountIn);
        uint256 outputBalanceBefore = _takeOutput(outputCurrency, amountOut);

        _callbackState = 4;
        return abi.encode(
            CallbackResult({amountIn: amountIn, amountOut: amountOut, outputBalanceBefore: outputBalanceBefore})
        );
    }

    /// @notice Accepts native output only from the PoolManager during an active unlock callback.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert UnexpectedNativeSender();
        if (_callbackState != 3) revert CallbackNotActive();
    }

    function _execute(
        CallbackData memory data,
        HookrModuleTypesV1.StackCore memory core,
        uint128 inputMaximum,
        uint256 nativeBalanceBefore,
        uint256 inputBalanceBefore
    ) internal returns (CallbackResult memory result) {
        bytes memory rawResult = poolManager.unlock(abi.encode(data));
        if (_callbackState != 4) revert CallbackNotCompleted();
        if (rawResult.length != 96) revert UnexpectedDelta();
        result = abi.decode(rawResult, (CallbackResult));

        if (result.amountIn > inputMaximum) revert TooMuchRequested(inputMaximum, result.amountIn);
        if (data.requireFullInput && result.amountIn != inputMaximum) {
            revert PartialFill(inputMaximum, result.amountIn);
        }
        if (data.exactInput) {
            if (result.amountOut < data.amountBound) {
                revert TooLittleReceived(data.amountBound, result.amountOut);
            }
        } else if (result.amountOut < uint256(data.swapParams.amountSpecified)) {
            revert TooLittleReceived(uint256(data.swapParams.amountSpecified), result.amountOut);
        }

        Currency inputCurrency = data.swapParams.zeroForOne ? data.key.currency0 : data.key.currency1;
        Currency outputCurrency = data.swapParams.zeroForOne ? data.key.currency1 : data.key.currency0;
        _deliverOutput(outputCurrency, data.recipient, result.amountOut, result.outputBalanceBefore);
        _refundNative(inputCurrency, inputMaximum - result.amountIn, data.payer);

        if (Currency.unwrap(inputCurrency) != address(0)) {
            uint256 actualInputBalance = _balanceOf(Currency.unwrap(inputCurrency), address(this));
            if (actualInputBalance != inputBalanceBefore) {
                revert RetainedBalance(Currency.unwrap(inputCurrency), inputBalanceBefore, actualInputBalance);
            }
        }
        if (address(this).balance != nativeBalanceBefore) {
            revert RetainedBalance(address(0), nativeBalanceBefore, address(this).balance);
        }

        emit SwapExecuted(
            data.key.toId(),
            core.stackHash,
            data.payer,
            data.recipient,
            core.kernel,
            Currency.unwrap(inputCurrency),
            Currency.unwrap(outputCurrency),
            data.exactInput,
            result.amountIn,
            result.amountOut,
            keccak256(data.moduleData)
        );
    }

    function _validate(
        PoolKey calldata key,
        address recipient,
        uint256 deadline,
        uint128 amount,
        uint160 sqrtPriceLimitX96,
        uint256 moduleDataLength
    ) internal view returns (HookrModuleTypesV1.StackCore memory core) {
        // A deadline is intentionally enforced against the inclusion timestamp.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        if (amount == 0 || amount > uint128(type(int128).max)) revert InvalidAmount();
        if (sqrtPriceLimitX96 < MIN_SQRT_PRICE_LIMIT || sqrtPriceLimitX96 > MAX_SQRT_PRICE_LIMIT) {
            revert InvalidSqrtPriceLimit();
        }
        if (moduleDataLength > MAX_MODULE_DATA_LENGTH) revert ModuleDataTooLarge();
        core = _checkedCore(key);
    }

    function _validateCallbackData(CallbackData memory data) internal view {
        if (data.payer == address(0) || data.recipient == address(0) || data.recipient == address(this)) {
            revert InvalidRecipient();
        }
        if (data.moduleData.length > MAX_MODULE_DATA_LENGTH) revert ModuleDataTooLarge();
        if (
            data.swapParams.sqrtPriceLimitX96 < MIN_SQRT_PRICE_LIMIT
                || data.swapParams.sqrtPriceLimitX96 > MAX_SQRT_PRICE_LIMIT
        ) revert InvalidSqrtPriceLimit();
        int256 amountSpecified = data.swapParams.amountSpecified;
        int256 maxAmount = int256(type(int128).max);
        if (amountSpecified == 0 || amountSpecified > maxAmount || amountSpecified < -maxAmount) {
            revert InvalidAmount();
        }
        if (data.exactInput) {
            if (data.swapParams.amountSpecified >= 0 || data.amountBound == 0) revert InvalidAmount();
        } else if (data.swapParams.amountSpecified <= 0 || data.amountBound == 0) {
            revert InvalidAmount();
        }
    }

    function _checkedCore(PoolKey memory key) internal view returns (HookrModuleTypesV1.StackCore memory core) {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        bytes32 registeredIntegrationId = _registeredIntegrationId();
        core = stackRegistry.stack(key.toId());
        if (!core.configured) revert InvalidStack();
        if (!core.initialized) revert StackNotInitialized();
        if (core.limits.trustedRouter != address(this)) {
            revert UntrustedStackRouter(address(this), core.limits.trustedRouter);
        }
        if (
            key.fee != DYNAMIC_FEE_FLAG || uint160(currency0) >= uint160(currency1) || address(key.hooks) != core.kernel
                || core.kernel == address(0) || core.kernelId == bytes32(0) || core.kernelFamilyId != KERNEL_FAMILY_ID
                || core.kernelCodeHash == bytes32(0) || core.kernel.code.length == 0
                || core.kernelCodeHash != core.kernel.codehash || core.stackHash == bytes32(0)
                || core.trustedRouterIntegrationId != registeredIntegrationId
                || core.trustedRouterCodeHash != address(this).codehash || core.subject == core.quote
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

    function _amounts(CallbackData memory data, BalanceDelta delta)
        internal
        pure
        returns (uint128 amountIn, uint128 amountOut)
    {
        (int128 inputDelta, int128 outputDelta) =
            data.swapParams.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
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

        if (data.exactInput) {
            uint256 specifiedInput = uint256(-data.swapParams.amountSpecified);
            if (input > specifiedInput) revert UnexpectedDelta();
            if (output < data.amountBound) revert TooLittleReceived(data.amountBound, output);
        } else {
            if (input > data.amountBound) revert TooMuchRequested(data.amountBound, input);
            uint256 specifiedOutput = uint256(data.swapParams.amountSpecified);
            if (output < specifiedOutput) revert TooLittleReceived(specifiedOutput, output);
        }
    }

    function _validateNativeValue(Currency inputCurrency, uint256 maximumInput) internal view {
        uint256 expected = Currency.unwrap(inputCurrency) == address(0) ? maximumInput : 0;
        if (msg.value != expected) revert InvalidNativeValue(expected, msg.value);
    }

    function _settle(Currency currency, address payer, uint256 amount) internal {
        poolManager.sync(currency);
        uint256 paid;
        if (Currency.unwrap(currency) == address(0)) {
            paid = poolManager.settle{value: amount}();
        } else {
            address token = Currency.unwrap(currency);
            uint256 payerBefore = _balanceOf(token, payer);
            _safeTransferFrom(token, payer, address(poolManager), amount);
            uint256 payerAfter = _balanceOf(token, payer);
            uint256 debited = payerAfter > payerBefore ? 0 : payerBefore - payerAfter;
            if (debited != amount) revert InputDebitMismatch(amount, debited);
            paid = poolManager.settle();
        }
        if (paid != amount) revert SettlementMismatch(amount, paid);
    }

    function _takeOutput(Currency currency, uint256 amount) internal returns (uint256 balanceBefore) {
        address token = Currency.unwrap(currency);
        balanceBefore = token == address(0) ? address(this).balance : _balanceOf(token, address(this));
        poolManager.take(currency, address(this), amount);
        uint256 balanceAfter = token == address(0) ? address(this).balance : _balanceOf(token, address(this));
        if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != amount) {
            revert OutputCustodyMismatch(amount, balanceAfter < balanceBefore ? 0 : balanceAfter - balanceBefore);
        }
    }

    function _deliverOutput(Currency currency, address recipient, uint256 amount, uint256 balanceBefore) internal {
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            uint256 nativeCurrentBalance = address(this).balance;
            if (nativeCurrentBalance < balanceBefore || nativeCurrentBalance - balanceBefore != amount) {
                revert OutputCustodyMismatch(
                    amount, nativeCurrentBalance < balanceBefore ? 0 : nativeCurrentBalance - balanceBefore
                );
            }
            (bool ok,) = payable(recipient).call{value: amount}("");
            if (!ok) revert TransferFailed();
            if (address(this).balance != balanceBefore) {
                revert RetainedBalance(address(0), balanceBefore, address(this).balance);
            }
            return;
        }

        uint256 tokenCurrentBalance = _balanceOf(token, address(this));
        if (tokenCurrentBalance < balanceBefore || tokenCurrentBalance - balanceBefore != amount) {
            revert OutputCustodyMismatch(
                amount, tokenCurrentBalance < balanceBefore ? 0 : tokenCurrentBalance - balanceBefore
            );
        }
        uint256 recipientBefore = _balanceOf(token, recipient);
        _safeTransfer(token, recipient, amount);
        uint256 recipientAfter = _balanceOf(token, recipient);
        uint256 received = recipientAfter < recipientBefore ? 0 : recipientAfter - recipientBefore;
        if (received != amount) revert OutputDeliveryMismatch(amount, received);
        uint256 routerAfter = _balanceOf(token, address(this));
        if (routerAfter != balanceBefore) revert RetainedBalance(token, balanceBefore, routerAfter);
    }

    function _refundNative(Currency inputCurrency, uint256 amount, address payer) internal {
        if (amount == 0 || Currency.unwrap(inputCurrency) != address(0)) return;
        (bool ok,) = payable(payer).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _routerTokenBalance(Currency currency) internal view returns (uint256) {
        address token = Currency.unwrap(currency);
        return token == address(0) ? 0 : _balanceOf(token, address(this));
    }

    function _balanceOf(address token, address account) internal view returns (uint256 balance) {
        (bool ok, uint256 result) =
            _staticcallWord(token, TOKEN_QUERY_GAS, abi.encodeWithSelector(bytes4(0x70a08231), account));
        if (!ok) revert BalanceQueryFailed();
        balance = result;
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        if (!_callOptionalBool(token, abi.encodeWithSelector(bytes4(0xa9059cbb), to, amount))) {
            revert TransferFailed();
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        if (!_callOptionalBool(token, abi.encodeWithSelector(bytes4(0x23b872dd), from, to, amount))) {
            revert TransferFailed();
        }
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

    function _callOptionalBool(address target, bytes memory input) internal returns (bool valid) {
        bool ok;
        uint256 returnSize;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := call(gas(), target, 0, add(input, 0x20), mload(input), 0, 0x20)
            returnSize := returndatasize()
            word := mload(0)
        }
        return ok && (returnSize == 0 || (returnSize == 32 && word == 1));
    }
}
