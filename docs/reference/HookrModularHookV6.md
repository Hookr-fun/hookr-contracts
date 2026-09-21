# HookrModularHookV6

Source: [`src/HookrModularHookV6.sol`](../../src/HookrModularHookV6.sol)

**Inherits:** `HookrSwapKernelV3`

The default root hook. One of two roots on the registry, serving every pool opened on the default kernel id, with per-PoolId frozen state. The other, [`HookrModularHookV6WthV5`](./HookrModularHookV6WthV5.md), runs the same rules on the same accounting kernel and adds a correction lane.

The contract body is a constructor that forwards to `HookrSwapKernelV3` and the two identity getters. Everything else on this page is inherited from `HookrSwapKernelV3`, which handles `beforeSwap` and `afterSwap` itself and forwards every other selector to `HookrSwapAccountingKernelV3` by `DELEGATECALL`. The separate name gives the deployed root its own identity and its own CREATE2 mining target.

## Identity

Two `pure` getters every contract in the graph carries, so an integrator can confirm what it is holding without a bytecode comparison.

```solidity
function contractName() external pure returns (string memory);   // "HookrModularHookV6"
function contractVersion() external pure returns (string memory); // "6.0.0"
```

## Constants

| Name | Type | Value |
| --- | --- | --- |
| `REQUIRED_FLAGS` | `uint160` | `0x28cc` (10444) |
| `KERNEL_FAMILY_ID` | `bytes32` | `keccak256("HOOKR_SWAP_DELTA_V1")` |
| `KERNEL_INSTANCE_LAYOUT_ID` | `bytes32` | `keccak256("HOOKR_KERNEL_INSTANCE_LAYOUT_V1")` |
| `STATEFUL_MODULE_MAGIC` | `bytes32` | `keccak256("HOOKR_STATEFUL_SWAP_MODULE_V1")` |
| `DYNAMIC_FEE_FLAG` | `uint24` | `0x800000` |
| `MIN_SQRT_PRICE_LIMIT` | `uint160` | 4295128740 |
| `MAX_SQRT_PRICE_LIMIT` | `uint160` | 1461446703485210103287273052203988822378723970341 |

## State Variables

| Name | Type | Description |
| --- | --- | --- |
| `poolManager` | `IPoolManager` | Immutable. The v4 singleton |
| `stackRegistry` | `IHookrStackRegistryV1` | Immutable. Source of every pool's frozen stack |
| `coordinator` | `address` | Immutable. The only address allowed to initialize a pool |
| `accountingKernel` | `HookrSwapAccountingKernelV3` | Immutable. The `DELEGATECALL` target |
| `accountingKernelCodeHash` | `bytes32` | Immutable. Checked before every delegation |

## Functions

### constructor

Cross-checks every wiring fact before pinning it: the accounting kernel must report the same PoolManager, stack registry, coordinator, kernel family, layout id, required flags and stateful magic, and every dependency must have code. Reverts `InvalidWiring` otherwise.

```solidity
constructor(
    IPoolManager poolManager_,
    IHookrStackRegistryV1 stackRegistry_,
    address coordinator_,
    HookrSwapAccountingKernelV3 accountingKernel_
);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolManager_`|`IPoolManager`|The Uniswap v4 singleton|
|`stackRegistry_`|`IHookrStackRegistryV1`|Registry holding each pool's frozen stack|
|`coordinator_`|`address`|The market coordinator|
|`accountingKernel_`|`HookrSwapAccountingKernelV3`|Implementation the hook delegates its callbacks to|

### beforeSwap

Resolves the pool's frozen stack and requires the `PoolKey` to match it, authenticates the caller against the pool's trusted router and quoter at their registered code hashes, decodes `hookData` only for a trusted caller, then delegates to the accounting kernel with a re-encoded envelope that carries the payer, the recipient, the `stackHash` and the module payload, with the correction legs stripped; for an untrusted caller the raw `hookData` is forwarded unchanged. A call from anything other than the PoolManager is forwarded to the accounting kernel, which rejects it.

```solidity
function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
    external
    returns (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sender`|`address`|The address that called `swap` on the PoolManager|
|`key`|`PoolKey`|The pool being swapped|
|`params`|`SwapParams`|Direction, signed amount and price limit|
|`hookData`|`bytes`|Empty from an untrusted caller; an authenticated envelope from the trusted router or quoter|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`selector`|`bytes4`|`IHooks.beforeSwap.selector`|
|`delta`|`BeforeSwapDelta`|Quote taken off the specified currency|
|`feeOverride`|`uint24`|Effective LP fee for this swap, with the override flag set|

Reverts `InvalidStack` when the stack is missing, uninitialized, bound to a different kernel or code hash, or when the key's currencies, `fee` or `hooks` disagree with it, and also when the trusted router or quoter's runtime code hash has changed. Reverts `InvalidHookData` when a trusted caller's envelope is too short or is not bound to the pool's `stackHash`.

### afterSwap

Same resolution and authentication, then delegates. Returns the unspecified-currency delta carrying the protocol share and the burn.

```solidity
function afterSwap(
    address sender,
    PoolKey calldata key,
    SwapParams calldata params,
    BalanceDelta delta,
    bytes calldata hookData
) external returns (bytes4 selector, int128 hookDelta);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`selector`|`bytes4`|`IHooks.afterSwap.selector`|
|`hookDelta`|`int128`|Amount taken on the unspecified currency|

### Every other selector

The contract's `fallback` re-checks the accounting kernel's code hash and forwards the raw calldata to it by `DELEGATECALL`, returning whatever it returns. `beforeInitialize`, `beforeAddLiquidity`, `syncBaseFee`, `inFlight` and `previewQuoteTax` are therefore served at the root's address, and the kernel's own reverts surface unchanged, including `HookNotCalled` for the callbacks this hook does not implement. Reverts `AccountingKernelCodeChanged(expected, actual)` if the kernel's code hash has moved. A kernel revert bubbles up with its own data; `DelegateCallFailed` is raised only on the `beforeSwap` and `afterSwap` path, when the kernel reverts without any data.

### contractName

```solidity
function contractName() external pure returns (string memory);
```

Returns `"HookrModularHookV6"`.

### contractVersion

```solidity
function contractVersion() external pure returns (string memory);
```

Returns `"6.0.0"`.

### statefulModuleKernelMagic

The opt-in marker a registry requires before it will freeze a `STATEFUL_V1` module against this root.

```solidity
function statefulModuleKernelMagic() external pure returns (bytes32);
```

### kernelInstanceLayoutId

The storage-layout lineage identifier.

```solidity
function kernelInstanceLayoutId() external pure returns (bytes32);
```

## The Correction Lane

`HookrSwapKernelV3` carries a correction lane for pools whose frozen `StackLimits` name a correction executor. After the accounting kernel returns, a trusted caller's correction payload can trigger one bounded, fail-open correction attempt per phase, reported by the three events below and guarded against nested callbacks by `ReentrantCallback`.

The default root's sealed profile names no correction-executor integration, and `createStack` rejects any stack whose `correctionExecutor` is not the profile's, so every pool on this root freezes all-zero correction fields and the lane never runs on it. The stack check still requires those fields to be consistently zero on every callback and reverts `InvalidStack` otherwise. The recapture root, `HookrModularHookV6WthV5`, seals one correction executor, `HookrWthExecutorAdapterV1`, and runs the lane on every qualifying swap; see [its page](./HookrModularHookV6WthV5.md).

## Events

### CorrectionAttemptSucceeded

```solidity
event CorrectionAttemptSucceeded(
    PoolId indexed poolId, uint8 indexed phase, bytes32 indexed planDigest, uint256 realizedProfitQuote
);
```

### CorrectionAttemptFailed

```solidity
event CorrectionAttemptFailed(PoolId indexed poolId, uint8 indexed phase, bytes32 payloadHash, bytes32 reasonHash);
```

### CorrectionAttemptSkipped

```solidity
event CorrectionAttemptSkipped(PoolId indexed poolId, uint8 indexed phase, bytes32 payloadHash, bytes32 reasonHash);
```

## Errors

| Error | When |
| --- | --- |
| `InvalidWiring()` | a constructor argument has no code or the accounting kernel reports different wiring |
| `AccountingKernelCodeChanged(bytes32 expected, bytes32 actual)` | the accounting kernel's runtime code hash differs from the one pinned at construction |
| `InvalidStack()` | the pool has no initialized stack for this root, the `PoolKey` disagrees with it, or a trusted integration's code hash has changed |
| `ReentrantCallback()` | a nested callback arrives outside the correction lane's expected state |
| `DelegateCallFailed()` | a delegation fails with no revert data |
| `InvalidHookData()` | a trusted caller's `hookData` is shorter than an envelope, carries the wrong version, a zero payer or recipient, is not bound to the pool's `stackHash`, or is not the canonical encoding |
| `InvalidPayload()` | a trusted caller's correction payload is malformed |

## Address Mining

The address must satisfy `address & 0x3fff == 0x28cc`, which is why it is mined: a CREATE2 salt through `HookrReleaseCreate2FactoryV1` produces an address with those low bits. See [Hook permissions](./hook-permissions.md).

## Listing

On Uniswap's routing allowlist and hooklist as of 2026-09-21, so Uniswap's own interface and API route swaps through pools on this root.
