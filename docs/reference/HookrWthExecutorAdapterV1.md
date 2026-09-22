# HookrWthExecutorAdapterV1

Source: [`src/HookrWthExecutorAdapterV1.sol`](../../src/HookrWthExecutorAdapterV1.sol)

**Implements:** `IHookrArbExecutorV3`, `IHookrKernelIntegrationV1`

The single boundary between the recapture root and WTH's own arbitrage executor, at [`0x28AF7A3645080e926a3101461e0Ec0594D42D806`](https://robinhoodchain.blockscout.com/address/0x28AF7A3645080e926a3101461e0Ec0594D42D806). The root speaks `IHookrArbExecutorV3` and the registry admits correction executors only if they answer `IHookrKernelIntegrationV1`; WTH's contract does neither, so this adapter answers both and forwards one narrowed call. It is the address WTH's executor accepts as its caller, and the address every pool on the recapture root freezes as `correctionExecutor`.

What it deliberately does not do: it holds no funds (no `receive`, no `fallback`, no payable function), keeps no accounting, and never decides how much profit exists. WTH's executor pays every recipient directly.

## Identity

```solidity
function contractName() external pure returns (string memory);   // "HookrWthExecutorAdapterV1"
function contractVersion() external pure returns (string memory); // "1.1.0"
```

## Constants

| Name | Value |
| --- | --- |
| `INTEGRATION_KIND` | `keccak256("HOOKR_KERNEL_INTEGRATION_CORRECTION_EXECUTOR")` |
| `INTEGRATION_FAMILY_ID` | `keccak256("HOOKR_SWAP_DELTA_V1")` |
| `INTEGRATION_VERSION` | 1 |
| `SPLIT_TOTAL_BPS` | 8,000: the three shares the root names must sum to this; WTH keeps the remaining 2,000 bps internally, 1,000 for itself and 1,000 for Hookr |
| `EXECUTOR_CALL_GAS_LIMIT` | 2,200,000: the most gas handed to WTH's executor |
| `ADAPTER_GAS_RESERVE` | 60,000: kept back so the adapter can always return or bubble a revert |

## State Variables

| Name | Type | Description |
| --- | --- | --- |
| `poolManager` | `IPoolManager` | Immutable |
| `stackRegistry` | `IHookrStackRegistryV1` | Immutable. Where the caller's frozen stack is read |
| `executionClock` | `IHookrExecutionClockV1` | Immutable. `HookrArbSysBlockClockV1` at `0x72841e61…0F92`; the constructor requires it to answer `executionBlockNumber()` |
| `owner` | `address` | The deployer, `0xF4Ab…B3eE`. Two-step transfer |
| `pendingOwner` | `address` | |
| `wthExecutor` | `address` | WTH's executor, `0xc356cf51134e0DF02BFE880115DD8c66Ead45803`. Set once, in block 61,272,510, and immutable afterwards |

Ownership controls `setExecutorOnce`, which has been spent, and nothing else the lane does.

## Functions

### setExecutorOnce

```solidity
function setExecutorOnce(address executor_) external onlyOwner;
```

Binds WTH's executor. Reverts `ExecutorAlreadySet` on any second call, `ZeroAddress` for an address without code. Spent on this deployment.

### feePolicyId

```solidity
function feePolicyId() external pure returns (bytes32); // HookrWthFeePolicyV2.FEE_POLICY_ID
```

Read by the registry before a pool may name this adapter; the pool's frozen `correctionFeePolicyId` must equal it. The policy is creator 4,000 / trader 2,000 / triggering pool's LPs 2,000 / WTH 1,000 / Hookr 1,000 bps.

### routeAdmissionOpen

Always `true`. Admission is WTH's to decide inside their own executor.

### executionBlockNumber

Forwards to the execution clock, which reads the L2 execution height rather than `block.number` (an L1 height on this chain).

### executeArbitrage

```solidity
function executeArbitrage(HookrArbTypesV3.ExecutionRequest calldata request)
    external
    returns (uint256 realizedProfitQuote, bytes32 planDigest);
```

Forwards one correction. In order:

1. Reverts `ExecutorNotSet` if no executor is bound.
2. Requires the caller to be `request.targetKey.hooks`, and reads that pool's frozen stack from the registry: it must be configured and initialized, its kernel must be the caller at the caller's current code hash and in this adapter's family, its subject must be non-zero and differ from its quote, its `correctionExecutor` must be this adapter at this adapter's code hash with a non-zero integration id, and its `correctionFeePolicyId` must be the fee policy. Anything else reverts `NotTargetHook` or `NotRegisteredKernel`. So only the recapture root, on behalf of a pool that froze this adapter, can make it call WTH.
3. Restates WTH's split rules at the boundary: the three named shares sum to 8,000, no trader share without a rebate recipient, no creator share without a creator, and the creator equals the pool's frozen `correctionCreator`. Otherwise `BadSplit`.
4. Forwards `min(gasleft() - 60,000, 2,200,000)` gas to `wthExecutor.executeArbitrage(targetKey, rebateRecipient, split)`; reverts `InsufficientGas` if less than the reserve remains.
5. Bubbles the executor's revert data unchanged (`ExecutorCallFailed` if there was none), requires exactly one returned word (`BadExecutorReturn`), and returns it as the realised profit with `keccak256(abi.encode(targetKey, rebateRecipient, split))` as the plan digest.

Every failure reverts, and the root's `try/catch` turns that into a `CorrectionAttemptFailed` event rather than a failed user swap. The frozen `maxArbVolumeBps` and `poolMinProfitQuote` arrive in the request but are not forwarded: WTH's interface takes neither, so sizing and the profit floor are WTH's own.

## Events

| Event | When |
| --- | --- |
| `ExecutorSet(address indexed executor)` | `setExecutorOnce` |
| `OwnerProposed`, `OwnerSet` | ownership transfer |

## Errors

`ZeroAddress`, `NotOwner`, `NotPendingOwner`, `ExecutorAlreadySet`, `ExecutorNotSet`, `NotTargetHook`, `NotRegisteredKernel`, `BadSplit`, `BadExecutorReturn`, `InsufficientGas`, `InvalidExecutionClock`, `ExecutorCallFailed`.

## Trust Boundary

Behind this adapter is WTH's executor, a contract Hookr did not write, cannot read and cannot verify: 62,358 bytes at `0xc356cf51…5803` with no source on any explorer. The adapter bounds what it can do to a Hookr pool to three things: consume up to 2,200,000 gas per attempt, swap back into the triggering pool during the correction window (which the root admits only from this adapter or the executor, on that pool, with empty `hookData`), and pay or not pay the recipients it is asked to pay. It cannot fail a user's swap through this adapter. The one path by which it can is the root's MEV refusal, described on the [root's page](./HookrModularHookV6WthV5.md), which is a `staticcall` to the executor made directly by the root.

## Verification

Blockscout full match, verified 2026-09-13T03:45:44Z; Sourcify exact match for creation and runtime bytecode. Deployed in tx `0x99f7bc3a…9be42`, block 61,264,312. Runtime 4,492 bytes, three storage slots (`owner`, `pendingOwner`, `wthExecutor`), pinned in `STORAGE_LAYOUT.json`.
