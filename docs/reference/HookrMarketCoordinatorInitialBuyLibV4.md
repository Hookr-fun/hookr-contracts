# HookrMarketCoordinatorInitialBuyLibV4

Source: [`src/libraries/HookrMarketCoordinatorInitialBuyLibV4.sol`](../../src/libraries/HookrMarketCoordinatorInitialBuyLibV4.sol)

A linked library. Validates and executes the creator's same-transaction buy

## Constants

| Name | Type | Value |
| --- | --- | --- |
| `MAX_MODULE_DATA_LENGTH` | `uint256` | 3,904 |
| `REQUIRED_ROUTER_INTEGRATION_VERSION` | `uint32` | 3 |

## Functions

### validate

Checks the creator buy before the token is deployed. A zero `quoteAmountIn` disables the buy and requires every companion field to be empty.

```solidity
function validate(
    address poolManager,
    address stackRegistry,
    address router,
    uint128 quoteAmountIn,
    uint128 subjectAmountOutMinimum,
    uint256 deadline,
    bytes calldata moduleData
) public view;
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolManager`|`address`|The v4 singleton the router must report|
|`stackRegistry`|`address`|The registry the router must report|
|`router`|`address`|The pool's trusted router, from `limits.trustedRouter`|
|`quoteAmountIn`|`uint128`|Quote the creator supplies; zero disables the buy|
|`subjectAmountOutMinimum`|`uint128`|Minimum subject the creator will accept|
|`deadline`|`uint256`|Last block timestamp at which the buy may execute|
|`moduleData`|`bytes`|Data forwarded to the pool's modules|

Reverts `InvalidInitialBuy` when the buy is enabled and any of these hold: `quoteAmountIn` exceeds `int128` max, `subjectAmountOutMinimum` is zero, the deadline has passed, `moduleData` is longer than `MAX_MODULE_DATA_LENGTH`, the router has no code, the router's `coordinator()`, `poolManager()` or `stackRegistry()` disagree with the coordinator's own, the router's `integrationVersion()` is not `REQUIRED_ROUTER_INTEGRATION_VERSION`, or the router's pinned `coordinatorCodeHash` is not the coordinator's current runtime code hash.

The quote currency is not an input to validation: the buy is available on every quote, native or ERC-20.

`REQUIRED_ROUTER_INTEGRATION_VERSION` is 3, which is what `HookrKernelRouterV3.integrationVersion()` returns. The registry registration for the router has to pass the same 3, or `registerIntegration` reverts `IntegrationMetadataMismatch`.

### executeAndEmit

Calls the router's `exactInputInitialBuy` and emits `CreatorBuyExecuted` from the coordinator's context. Reverts `InitialBuyInputMismatch(expected, actual)` unless the buy consumes exactly the requested quote.

```solidity
function executeAndEmit(
    EmitContext memory context,
    IHookrKernelRouterV2.InitialBuyParams memory params,
    bytes calldata moduleData
) public returns (uint256 actualQuoteIn, uint256 subjectOut);
```

One `EmitContext` carries the arguments, including the market's quote currency so the library knows whether to send value:

```solidity
struct EmitContext {
    PoolId poolId;
    address subject;
    bytes32 intentId;
    bytes32 stackHash;
    address quote;
    address router;
    uint256 subjectSeedResidue;
    uint256 quoteSeedResidue;
}
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`context`|`EmitContext`|Pool, subject, intent id, stack hash, quote currency, router, and the two always-zero residue fields|
|`params`|`InitialBuyParams`|Pool key, creator, quote in, minimum subject out, deadline|
|`moduleData`|`bytes`|Data forwarded to the pool's modules|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`actualQuoteIn`|`uint256`|Quote consumed by the buy|
|`subjectOut`|`uint256`|Subject delivered to the creator|

The coordinator checks `subjectOut` against `MAX_INITIAL_BUY_SUBJECT` after this returns, so the cap applies to what the creator actually receives, net of any burn.

Value forwarding is quote-aware:

```solidity
uint256 nativeValue = context.quote == address(0) ? params.quoteAmountIn : 0;
```

For an ERC-20 quote the call carries no value and the router pulls the quote from the creator, who approved it beforehand.

## Events

### CreatorBuyExecuted

Emitted by `executeAndEmit`, from the coordinator's address because the library runs by `DELEGATECALL`. It names the subject explicitly rather than leaving an indexer to infer it from currency ordering.

```solidity
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
```

`requestedQuoteIn` and `actualQuoteIn` differ when the pool fills the buy for less than the creator offered. `creatorAllocation` and the two residue fields are always zero in this release: the event's allocation argument is hard-coded to zero, and the coordinator burns quantization dust and reverts `ExcessiveSettlement` if any seed residue remains.

## Errors

`InvalidInitialBuy`, `InitialBuyInputMismatch(expected, actual)`.
