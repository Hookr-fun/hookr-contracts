# HookrNativeMechanicsCoordinatorLibV2

Source: [`src/libraries/HookrNativeMechanicsCoordinatorLibV2.sol`](../../src/libraries/HookrNativeMechanicsCoordinatorLibV2.sol)

Coordinator-side admission and fee routing for the native mechanics module

A linked library, executed by `DELEGATECALL`, so its storage writes and its transfers happen in the coordinator's context.

## Constants

| Name | Type | Value |
| --- | --- | --- |
| `MODULE_KEY` | `bytes32` | `keccak256("HOOKR_NATIVE_MECHANICS")` |
| `CONFIG_SCHEMA_HASH` | `bytes32` | the canonical config schema hash the module must report |
| `REQUIRED_PHASE_MASK` | `uint8` | all phases |
| `MIN_MODULE_VERSION` | `uint32` | 2 |
| `MAX_MODULE_VERSION` | `uint32` | 2 |
| `QUERY_GAS` | `uint32` | 150,000 |
| `MAX_GUARD_BLOCKS` | `uint256` | 100,000 |
| `GUARD_ACCOUNTING_STORAGE_SLOT` | `bytes32` | the fixed slot in the coordinator's storage that holds every pool's guard-accounting record |

Both version bounds are 2, so only `HookrNativeMechanicsBlockV2` admits through this library. A module at any other version fails closed.

## Functions

### validateOrigin

Resolves the one canonical native module in the selections and proves every admission fact. Returns zero for both values when no native module is selected, which is how the coordinator detects a stack that would have no rules.

```solidity
function validateOrigin(
    IHookrNativeMechanicsCatalogReadV1 registry,
    uint8 origin,
    uint24 baseLpFeePips,
    HookrModuleTypesV1.ModuleSelection[] calldata selections,
    address treasuryReader,
    address creator
) public view returns (address module, bytes32 codeHash);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`registry`|`IHookrNativeMechanicsCatalogReadV1`|Registry exposing the module snapshot|
|`origin`|`uint8`|1 for the new-token lane, anything else for the existing-asset lane|
|`baseLpFeePips`|`uint24`|The base fee the stack limits declare|
|`selections`|`ModuleSelection[]`|The module selections being frozen|
|`treasuryReader`|`address`|Contract exposing `treasuryBeneficiary()` and `protocolShareBps(address creator)`; the coordinator passes itself|
|`creator`|`address`|Account opening the market|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`module`|`address`|The bound native-mechanics implementation, or zero|
|`codeHash`|`bytes32`|Its runtime code hash at admission time|

Every external read here, except the coordinator's own `treasuryBeneficiary()`, is a gas-bounded `staticcall` that requires a full 32-byte return word. A target that reverts, runs long, or returns a short word fails admission rather than being treated as absent.

### validateAndRecordMarket

Runs `validateOrigin` and records the module binding for the pool atomically.

```solidity
function validateAndRecordMarket(
    IHookrNativeMechanicsCatalogReadV1 registry,
    uint8 origin,
    uint24 baseLpFeePips,
    HookrModuleTypesV1.ModuleSelection[] calldata selections,
    bytes32 poolId,
    address treasuryReader,
    address creator
) public returns (address module);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`module`|`address`|The bound implementation; the coordinator reverts `NativeMechanicsModuleRequired` on zero|

### recordMarket

Writes the module and its code hash into the pool's guard-accounting record. Reverts `InvalidGuardAccounting` if a record already exists for that pool, and `InvalidNativeMechanicsModule` when exactly one of the module address and its code hash is zero.

```solidity
function recordMarket(bytes32 poolId, address module, bytes32 moduleCodeHash) public;
```

### guardLpEarned

Reads the module's cumulative guard-window quote earnings, but only from the exact implementation recorded at market creation and only while its runtime code hash is unchanged. Reverts `InvalidNativeMechanicsModule` on drift.

```solidity
function guardLpEarned(address module, bytes32 expectedCodeHash, bytes32 poolId)
    public
    view
    returns (uint256 earned);
```

### guardAccounting

Per-pool guard-window view for interfaces: the module recorded for the pool and its cumulative guard-window earnings. Nothing is withheld and nothing is pending, so there is nothing else to report.

```solidity
function guardAccounting(bytes32 poolId) public view returns (address module, uint256 cumulativeEarned);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`module`|`address`|The native module recorded for this pool|
|`cumulativeEarned`|`uint256`|Cumulative guard-window quote LP earnings, read from that module at its recorded code hash|

### routeFoundingPositionFees

Sends both collected currencies to `lpFeeRecipient` and emits `LpFeesCollected`. Executed by `DELEGATECALL`, so the transfers originate from the coordinator.

```solidity
function routeFoundingPositionFees(FeeRouteInput memory input) public {
    if (input.amount0 != 0) _refund(input.currency0, input.lpFeeRecipient, input.amount0);
    if (input.amount1 != 0) _refund(input.currency1, input.lpFeeRecipient, input.amount1);
    emit LpFeesCollected(input.poolId, input.lpFeeRecipient, input.amount0, input.amount1);
}
```

That is the whole body. There is no withholding branch and no treasury read.

ERC-20 transfers inside `_refund` are balance-checked on both sides and revert `TaxedTransfer` if either party's balance moves by anything other than the exact amount.

## Structs

### FeeRouteInput

```solidity
struct FeeRouteInput {
    bytes32 poolId;
    address currency0;
    address currency1;
    address lpFeeRecipient;
    uint256 amount0;
    uint256 amount1;
}
```

### GuardAccounting

```solidity
struct GuardAccounting {
    address module;
    bytes32 moduleCodeHash;
}
```

## Events

`LpFeesCollected(bytes32 indexed poolId, address indexed recipient, uint256 amount0, uint256 amount1)`; the library declares `poolId` as `bytes32`, the coordinator as `PoolId`, and the topic is the same.

## Errors

`InvalidNativeMechanicsModule`, `ProtocolShareTierMismatch(expected, actual)`, `GuardRequiresLockedFoundingPosition`, `InvalidGuardAccounting`, `TransferFailed`, `TaxedTransfer`, `NativeTransferFailed`.
