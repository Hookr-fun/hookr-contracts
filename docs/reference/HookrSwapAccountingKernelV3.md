# HookrSwapAccountingKernelV3

Source: [`src/HookrSwapAccountingKernelV3.sol`](../../src/HookrSwapAccountingKernelV3.sol)

**Implements:** `IHooks`

The callback bodies the root hook delegates to. Never called directly by the PoolManager

Every function here runs in the root hook's storage context by `DELEGATECALL`. Deploying it separately is what keeps the root's own runtime inside the EIP-170 limit while carrying the full accounting path; the kernel itself is 23,965 bytes, 611 short of the limit.

## Identity

Two `pure` getters every contract in the graph carries, so an integrator can confirm what it is holding without a bytecode comparison.

```solidity
function contractName() external pure returns (string memory);   // "HookrSwapAccountingKernelV3"
function contractVersion() external pure returns (string memory); // "3.0.0"
```

## Constants

| Name | Type | Value |
| --- | --- | --- |
| `REQUIRED_FLAGS` | `uint160` | `0x28cc` (10444) |
| `KERNEL_FAMILY_ID` | `bytes32` | `keccak256("HOOKR_SWAP_DELTA_V1")` |
| `KERNEL_INSTANCE_LAYOUT_ID` | `bytes32` | `keccak256("HOOKR_KERNEL_INSTANCE_LAYOUT_V1")` |
| `DYNAMIC_FEE_FLAG` | `uint24` | `0x800000` |
| `MAX_HOOK_DATA_LENGTH` | `uint256` | 4096 |
| `MIN_SQRT_PRICE_LIMIT` | `uint160` | 4295128740 |
| `MAX_SQRT_PRICE_LIMIT` | `uint160` | 1461446703485210103287273052203988822378723970341 |

## State Variables

| Name | Type | Description |
| --- | --- | --- |
| `poolManager` | `IPoolManager` | Immutable. The v4 singleton |
| `stackRegistry` | `IHookrStackRegistryV1` | Immutable. Source of every pool's frozen stack |
| `coordinator` | `address` | Immutable. The only address allowed to initialize a pool |

The root hook checks all three against its own at construction.

## Functions

### constructor

```solidity
constructor(IPoolManager poolManager_, IHookrStackRegistryV1 stackRegistry_, address coordinator_);
```

Reverts `InvalidWiring` for a zero or codeless argument.

### beforeInitialize

Accepts pool initialization from the coordinator only, once per pool, only when the `PoolKey` matches the frozen stack. Marks the stack initialized and emits `MarketInitialized`.

```solidity
function beforeInitialize(address sender, PoolKey calldata key, uint160) external returns (bytes4);
```

Reverts `NotCoordinator`, `StackAlreadyInitialized`, `InvalidStack`, or `NotPoolManager`.

### beforeAddLiquidity

Walks the pool's frozen modules and calls each one's `beforeAddLiquidity` inside its registered gas limit. A module returning false or reverting fails the add.

```solidity
function beforeAddLiquidity(
    address sender,
    PoolKey calldata key,
    ModifyLiquidityParams calldata params,
    bytes calldata hookData
) external view returns (bytes4);
```

Reverts `HookDataTooLarge`, `ModuleCallFailed(moduleId, phase, reasonHash)`, `InvalidModuleResult(moduleId)`, `ModuleCodeChanged(moduleId, expected, actual)`.

### beforeSwap

Resolves the caller, walks the modules, aggregates their requested takes, checks them against the pool's frozen caps, credits the claim recipients, and returns the `BeforeSwapDelta` and the fee override.

```solidity
function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
    external
    returns (bytes4, BeforeSwapDelta, uint24);
```

Reverts `AggregateCapExceeded`, `SwapAmountOutOfRange`, `UnsupportedSwapDirection`, `UnsupportedSpecifiedQuoteTake`, `PartialFillUnsupportedWithInputCuts`, `UntrustedHookData`, `InvalidHookData`, `TrustedIntegrationCodeChanged(integrationId, expected, actual)`.

### afterSwap

Same walk for the unspecified leg and the subject take. Reverts `MissingBeforeSwap` if the in-flight context from `beforeSwap` is absent.

```solidity
function afterSwap(
    address sender,
    PoolKey calldata key,
    SwapParams calldata params,
    BalanceDelta delta,
    bytes calldata hookData
) external returns (bytes4, int128);
```

### syncBaseFee

Pushes the pool's frozen `baseLpFeePips` into the PoolManager's dynamic-fee cache. Permissionless; reverts `StackNotInitialized` before the pool is initialized. Useful for any consumer that reads the cached fee directly rather than simulating a swap.

```solidity
function syncBaseFee(PoolKey calldata key) external;
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The pool to sync|

### inFlight

The `beforeSwap` context recorded for a pool inside the current transaction.

```solidity
function inFlight(PoolId poolId) external view returns (bytes32 contextHash, uint128 specifiedQuoteTake);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`contextHash`|`bytes32`|Hash binding sender, pool, direction, amount, price limit and hookData|
|`specifiedQuoteTake`|`uint128`|Quote already taken off the specified leg|

### previewQuoteTax

Pure helper computing the quote take for an aggregate rate, either grossing up or netting down.

```solidity
function previewQuoteTax(uint256 poolQuote, uint16 aggregateRateBps, bool grossUp)
    external
    pure
    returns (uint256 tax, uint256 grossOrNetQuote);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolQuote`|`uint256`|Quote amount to compute against|
|`aggregateRateBps`|`uint16`|Sum of the module take rates|
|`grossUp`|`bool`|True to add the tax on top, false to carve it out|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`tax`|`uint256`|Quote taken|
|`grossOrNetQuote`|`uint256`|Gross or net amount depending on `grossUp`|

### contractName, contractVersion

```solidity
function contractName() external pure returns (string memory);
function contractVersion() external pure returns (string memory);
```

Return `"HookrSwapAccountingKernelV3"` and `"3.0.0"`.

### kernelInstanceLayoutId, statefulModuleKernelMagic

```solidity
function kernelInstanceLayoutId() external pure returns (bytes32);
function statefulModuleKernelMagic() external pure returns (bytes32);
```

Return `KERNEL_INSTANCE_LAYOUT_ID` and the stateful-module marker `keccak256("HOOKR_STATEFUL_SWAP_MODULE_V1")`. The root hook requires both to match its own constants at construction, and the registry reads the marker before it freezes a `STATEFUL_V1` module against the root.

### Unimplemented callbacks

`afterInitialize`, `afterAddLiquidity`, `beforeRemoveLiquidity`, `afterRemoveLiquidity`, `beforeDonate` and `afterDonate` all revert `HookNotCalled`. Their flag bits are not set, so the PoolManager never calls them; the reverts exist so a mis-mined address fails loudly.

## Caller Authentication

```solidity
if (sender == core.limits.trustedRouter) {
    if (sender.codehash != core.trustedRouterCodeHash) revert TrustedIntegrationCodeChanged(...);
    resolved.trustedCaller = true;
} else if (sender == core.limits.trustedQuoter) {
    if (sender.codehash != core.trustedQuoterCodeHash) revert TrustedIntegrationCodeChanged(...);
    resolved.trustedCaller = true;
}
if (!resolved.trustedCaller) {
    if (rawHookData.length != 0) revert UntrustedHookData();
    resolved.payer = sender;
    resolved.recipient = sender;
    return resolved;
}
```

An untrusted caller must send empty `hookData` and is treated as its own payer and recipient. A trusted caller's `hookData` is decoded as a `HookrHookDataV1.Envelope` and must carry the pool's own `stackHash`, or the decode reverts `InvalidHookData`.

This is why a Universal Router swap works normally but skips the pot leg: the Universal Router is not the pool's registered router, so no authenticated recipient exists to credit.

## Events

### MarketInitialized

Emitted once per pool when the coordinator initializes it

```solidity
event MarketInitialized(PoolId indexed poolId, bytes32 indexed stackHash, address indexed subject, address quote);
```

### ModuleFeeAccrued

Emitted per module per phase when a take is credited

```solidity
event ModuleFeeAccrued(
    PoolId indexed poolId,
    bytes32 indexed moduleId,
    bytes32 indexed attributionKey,
    address recipient,
    address quote,
    uint256 amount,
    bool isBuy,
    bool exactInput,
    bool afterSwapPhase
);
```

### ModuleFeeSkipped

Emitted when a take was requested but could not be credited to its recipient

```solidity
event ModuleFeeSkipped(
    PoolId indexed poolId, bytes32 indexed moduleId, bytes32 indexed attributionKey, address recipient, bytes32 reason
);
```

### StatefulModuleAction

Emitted per stateful module callback with the action the kernel executed

```solidity
event StatefulModuleAction(
    PoolId indexed poolId,
    bytes32 indexed moduleId,
    bytes32 indexed attributionKey,
    address currency,
    address recipient,
    uint256 amount,
    bool donation,
    bool afterSwapPhase
);
```

### HookFee

Emitted with the total hook-side fee amounts for a swap

```solidity
event HookFee(bytes32 indexed poolId, address indexed sender, uint128 feeAmount0, uint128 feeAmount1);
```

## Errors

`NotPoolManager`, `NotCoordinator`, `InvalidWiring`, `InvalidStack`, `StackNotInitialized`, `StackAlreadyInitialized`, `ModuleCodeChanged(moduleId, expected, actual)`, `TrustedIntegrationCodeChanged(integrationId, expected, actual)`, `ModuleCallFailed(moduleId, phase, reasonHash)`, `InvalidModuleResult(moduleId)`, `AggregateCapExceeded`, `SwapAmountOutOfRange`, `UnsupportedSwapDirection`, `UnsupportedSpecifiedQuoteTake`, `PartialFillUnsupportedWithInputCuts`, `StrictClaimSinkUnavailable(moduleId, recipient)`, `ClaimCreditFailed(moduleId, recipient, reasonHash)`, `ReentrantCallback`, `MissingBeforeSwap`, `HookDataTooLarge`, `UntrustedHookData`, `InvalidHookData`, `HookNotCalled`, `DeferredDonationUnavailable`.

`DeferredDonationUnavailable(poolId)` comes from the shared settlement library (`HookrStatefulSettlementLibV1`) and surfaces from `afterSwap` when a deferred quote donation cannot be settled.
