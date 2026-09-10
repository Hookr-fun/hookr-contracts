# HookrKernelRouterV3

Source: [`src/HookrKernelRouterV3.sol`](../../src/HookrKernelRouterV3.sol)

**Implements:** `IUnlockCallback`, `IHookrKernelIntegrationV1`, `IHookrKernelRouterV2`

The trusted router. Settles swaps against a frozen stack and carries an authenticated payer and recipient

Being the pool's registered router is what makes the pot leg work: the accounting kernel decodes `hookData` only from the pool's `limits.trustedRouter` or `limits.trustedQuoter`, at its registered runtime code hash.

## Identity

Two `pure` getters every contract in the graph carries, so an integrator can confirm what it is holding without a bytecode comparison.

```solidity
function contractName() external pure returns (string memory);   // "HookrKernelRouterV3"
function contractVersion() external pure returns (string memory); // "3.0.0"
```

## Constants

| Name | Type | Value |
| --- | --- | --- |
| `KERNEL_FAMILY_ID` | `bytes32` | `keccak256("HOOKR_SWAP_DELTA_V1")` |
| `ROUTER_INTEGRATION_KIND` | `bytes32` | `keccak256("HOOKR_KERNEL_INTEGRATION_ROUTER")` |
| `DYNAMIC_FEE_FLAG` | `uint24` | `0x800000` |
| `MIN_SQRT_PRICE_LIMIT` | `uint160` | 4295128740 |
| `MAX_SQRT_PRICE_LIMIT` | `uint160` | 1461446703485210103287273052203988822378723970341 |
| `MAX_MODULE_DATA_LENGTH` | `uint256` | 3,904 |

## Integration Identity

The registry round-trips a registration through these three getters and reverts `IntegrationMetadataMismatch` if the values it was handed disagree with what the implementation answers, so a router cannot be registered under a family or version it does not serve.

```solidity
function integrationKind() external pure returns (bytes32);      // ROUTER_INTEGRATION_KIND
function integrationFamilyId() external pure returns (bytes32);  // KERNEL_FAMILY_ID
function integrationVersion() external pure returns (uint32);    // 3
```

`HookrMarketCoordinatorInitialBuyLibV4` requires integration version 3 of the pool's registered router before it will run a creator buy through it.

## State Variables

| Name | Type | Description |
| --- | --- | --- |
| `poolManager` | `IPoolManager` | Immutable |
| `stackRegistry` | `IHookrStackRegistryV1` | Immutable |
| `coordinator` | `address` | Immutable. The only caller allowed to run an initial creator buy |
| `coordinatorCodeHash` | `bytes32` | Immutable. Re-checked on every initial buy |

## Functions

### constructor

Reverts `InvalidWiring` unless the registry's PoolManager matches, the registry's `coordinator()` already equals this argument, and the coordinator's own `poolManager()` and `stackRegistry()` round-trip to the same addresses. Deploy it after `setCoordinatorOnce`.

```solidity
constructor(IPoolManager poolManager_, IHookrStackRegistryV1 stackRegistry_, address coordinator_);
```

### exactInput

Swaps up to a maximum input. Native input requires `msg.value == amountIn` and refunds the remainder; ERC-20 input requires `msg.value == 0` and an allowance to this router. A price limit may cause a partial fill, and the minimum-output bound still applies.

```solidity
function exactInput(ExactInputParams calldata params, bytes calldata moduleData)
    external
    payable
    returns (uint256 amountOut);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`params`|`ExactInputParams`|Pool, direction, amounts, price limit, recipient and deadline|
|`moduleData`|`bytes`|Data forwarded to the pool's modules; at most `MAX_MODULE_DATA_LENGTH` bytes|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountOut`|`uint256`|Output delivered to the recipient|

Set `sqrtPriceLimitX96` to `MIN_SQRT_PRICE_LIMIT` for `zeroForOne` or `MAX_SQRT_PRICE_LIMIT` otherwise on any pool with input cuts, or the swap reverts `PartialFillUnsupportedWithInputCuts` (the hook's error, bubbled up through the router).

### exactOutput

Swaps for a fixed output. Native input requires `msg.value == amountInMaximum` and refunds the remainder.

```solidity
function exactOutput(ExactOutputParams calldata params, bytes calldata moduleData)
    external
    payable
    returns (uint256 amountIn);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Input consumed from the payer|

### exactInputInitialBuy

The coordinator's same-transaction creator buy. Callable only by the coordinator, and only while the coordinator's runtime code hash still matches the one pinned at construction.

```solidity
function exactInputInitialBuy(IHookrKernelRouterV2.InitialBuyParams calldata params, bytes calldata moduleData)
    external
    payable
    returns (uint256 quoteAmountIn, uint256 subjectAmountOut);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`params`|`InitialBuyParams`|Pool key, creator, quote amount in, minimum subject out, deadline|
|`moduleData`|`bytes`|Data forwarded to the pool's modules|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`quoteAmountIn`|`uint256`|Quote consumed|
|`subjectAmountOut`|`uint256`|Subject delivered to the creator|

The input currency is the pool's own quote, which may sort into `currency1`. The router sets `zeroForOne` from whether the quote is `currency0`, validates `msg.value` against the quote currency, and pulls an ERC-20 quote from the creator through the same settle path the generic exact-input lane uses. The creator approves the router for the quote token before launching.

`requireFullInput` stays true: the buy must consume its whole input or revert.

### integrationKind, integrationFamilyId, integrationVersion

The identity triple the stack registry round-trips against the values passed to `registerIntegration`. A mismatch reverts `IntegrationMetadataMismatch` at registration. `integrationVersion()` returns 3, so the registration must pass 3 and `HookrMarketCoordinatorInitialBuyLibV4` requires exactly that value before it will run a creator buy.

```solidity
function integrationKind() external pure returns (bytes32);
function integrationFamilyId() external pure returns (bytes32);
function integrationVersion() external pure returns (uint32);
```

### unlockCallback

PoolManager unlock callback. Reverts `NotPoolManager`, `CallbackNotActive`, `CallbackNotCompleted`.

```solidity
function unlockCallback(bytes calldata rawData) external returns (bytes memory);
```

## Structs

### ExactInputParams

```solidity
struct ExactInputParams {
    PoolKey key;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
    address recipient;
    uint256 deadline;
}
```

### ExactOutputParams

```solidity
struct ExactOutputParams {
    PoolKey key;
    bool zeroForOne;
    uint128 amountOut;
    uint128 amountInMaximum;
    uint160 sqrtPriceLimitX96;
    address recipient;
    uint256 deadline;
}
```

## Events

### SwapExecuted

Emitted after a swap settles and output is delivered

```solidity
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
```

## Errors

`InvalidWiring`, `NotCoordinator(expected, actual)`, `CoordinatorCodeHashMismatch(expected, actual)`, `Reentrancy`, `NotPoolManager`, `CallbackNotActive`, `CallbackNotCompleted`, `DeadlineExpired(deadline, timestamp)`, `InvalidStack`, `StackNotInitialized`, `UntrustedStackRouter(expected, actual)`, `InvalidRecipient`, `InvalidAmount`, `InvalidSqrtPriceLimit`, `ModuleDataTooLarge`, `InvalidNativeValue(expected, received)`, `TooLittleReceived(minimum, received)`, `TooMuchRequested(maximum, requested)`, `PartialFill(expected, actual)`, `UnexpectedDelta`, `TransferFailed`, `BalanceQueryFailed`, `InputDebitMismatch(expected, debited)`, `SettlementMismatch(expected, settled)`, `OutputCustodyMismatch(expected, received)`, `OutputDeliveryMismatch(expected, received)`, `RetainedBalance(currency, expected, actual)`, `UnexpectedNativeSender`.

## Delivery Guarantees

Output is taken into the router first and delivered after the PoolManager relocks, which keeps a recipient callback outside the unlock. ERC-20 paths compare router and recipient balance deltas; native paths require a successful transfer and no retained router balance. Any mismatch reverts rather than settling short.
