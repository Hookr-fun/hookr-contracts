# HookrKernelQuoterV1

Source: [`src/HookrKernelQuoterV1.sol`](../../src/HookrKernelQuoterV1.sol)

**Implements:** `IUnlockCallback`, `IHookrKernelIntegrationV1`

The trusted quoter. Simulates a swap through the real code path and reverts with the result

A Hookr quote runs the same hook callbacks, the same module walk and the same fee override a real swap would, then reverts to discard the state. That is what makes it accurate on a pool with surge fees, a guard window, or input cuts, where a curve-only quote would be wrong.

Being the pool's registered quoter also means the pot leg is simulated. A quote from the Uniswap `V4Quoter` sees the same pool without the pot cut, which is what a Universal Router swap would actually pay.

## Identity

Two `pure` getters every contract in the graph carries, so an integrator can confirm what it is holding without a bytecode comparison.

```solidity
function contractName() external pure returns (string memory);   // "HookrKernelQuoterV1"
function contractVersion() external pure returns (string memory); // "1.1.0"
```

## Constants

| Name | Type | Value |
| --- | --- | --- |
| `KERNEL_FAMILY_ID` | `bytes32` | `keccak256("HOOKR_SWAP_DELTA_V1")` |
| `QUOTER_INTEGRATION_KIND` | `bytes32` | `keccak256("HOOKR_KERNEL_INTEGRATION_QUOTER")` |
| `DYNAMIC_FEE_FLAG` | `uint24` | `0x800000`, the `PoolKey.fee` every Hookr pool carries |
| `MAX_MODULE_DATA_LENGTH` | `uint256` | 3,904 |
| `MIN_SQRT_PRICE_LIMIT` | `uint160` | 4295128740 |
| `MAX_SQRT_PRICE_LIMIT` | `uint160` | 1461446703485210103287273052203988822378723970341 |

## State Variables

| Name | Type | Description |
| --- | --- | --- |
| `poolManager` | `IPoolManager` | Immutable. The v4 singleton the simulation unlocks |
| `stackRegistry` | `IHookrStackRegistryV1` | Immutable. Source of the pool's frozen stack |

## Integration Identity

The registry round-trips a registration through these three getters and reverts `IntegrationMetadataMismatch` if the values it was handed disagree with what the implementation answers, so a quoter cannot be registered under a family or version it does not serve.

```solidity
function integrationKind() external pure returns (bytes32);      // QUOTER_INTEGRATION_KIND
function integrationFamilyId() external pure returns (bytes32);  // KERNEL_FAMILY_ID
function integrationVersion() external pure returns (uint32);    // 1
```

## Functions

### constructor

```solidity
constructor(IPoolManager poolManager_, IHookrStackRegistryV1 stackRegistry_);
```

### quote

Simulates the swap and returns the delta-aware amounts. Not a view function: it calls `poolManager.unlock`, so use `eth_call` or a static call from another contract.

```solidity
function quote(QuoteParams calldata params, bytes calldata moduleData)
    external
    returns (uint256 amountIn, uint256 amountOut);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`params`|`QuoteParams`|Pool key, payer, recipient, direction, signed amount, bound and price limit|
|`moduleData`|`bytes`|Data forwarded to the pool's modules|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Input the swap would consume|
|`amountOut`|`uint256`|Output the swap would deliver|

`amountSpecified` follows the v4 convention: negative for exact input, positive for exact output. Pass the real `recipient` you intend to swap with, because the pot leg is recipient-specific and a different recipient can produce a different result.

### integrationKind, integrationFamilyId, integrationVersion

```solidity
function integrationKind() external pure returns (bytes32);
function integrationFamilyId() external pure returns (bytes32);
function integrationVersion() external pure returns (uint32);
```

### unlockCallback

Executes the simulated swap and reverts with `QuoteResult`, which `quote` catches and authenticates against the expected quote id.

```solidity
function unlockCallback(bytes calldata rawData) external returns (bytes memory);
```

## Structs

### QuoteParams

```solidity
struct QuoteParams {
    PoolKey key;
    address payer;
    address recipient;
    bool zeroForOne;
    int128 amountSpecified;
    uint128 amountBound;
    uint160 sqrtPriceLimitX96;
}
```

## Errors

### QuoteResult

Not a failure. The internal successful-simulation carrier that `quote` decodes.

```solidity
error QuoteResult(bytes32 quoteId, uint128 amountIn, uint128 amountOut);
```

### Others

`InvalidWiring`, `Reentrancy`, `NotPoolManager`, `CallbackNotActive`, `InvalidStack`, `StackNotInitialized`, `UntrustedStackQuoter(expected, actual)`, `InvalidIdentity`, `InvalidAmount`, `InvalidAmountBound`, `InvalidSqrtPriceLimit`, `ModuleDataTooLarge`, `UnexpectedDelta`, `TooLittleReceived(minimum, received)`, `TooMuchRequested(maximum, requested)`, `InvalidQuoteResult`, `SimulationDidNotRevert`.

A revert that is not `QuoteResult` bubbles up unchanged, so a guard-window rejection or a cap breach reaches the caller as the error the swap would have thrown.
