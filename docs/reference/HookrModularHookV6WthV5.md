# HookrModularHookV6WthV5

Source: [`src/HookrModularHookV6WthV5.sol`](../../src/HookrModularHookV6WthV5.sol), base [`src/HookrSwapKernelV5Wth.sol`](../../src/HookrSwapKernelV5Wth.sol)

**Inherits:** `HookrSwapKernelV5Wth`

The recapture root hook, at [`0xb914f955294799de4b891bd2EA8AF628Fa1c68CC`](https://robinhoodchain.blockscout.com/address/0xb914f955294799de4b891bd2EA8AF628Fa1c68CC). One of two roots on the registry. Every pool opened with kernel id `0xd8b6c165b82efc3b7498081f071ea4f2476e2fb9c61b2e614aba2a016f94555a` names it in `PoolKey.hooks`, freezes its stack against it, and runs the same five rules as a pool on the default root, on the same `HookrSwapAccountingKernelV3` by `DELEGATECALL` and the same `HookrNativeMechanicsBlockV2`. What it adds is a correction lane that is always on.

The contract body is a constructor that forwards to `HookrSwapKernelV5Wth` and the two identity getters, exactly as [`HookrModularHookV6`](./HookrModularHookV6.md) forwards to `HookrSwapKernelV3`. The four constructor arguments are the same four values: the PoolManager, the registry `0x5b7f…5BA3`, the coordinator `0x53A1…2442` and the accounting kernel `0x5305…E060`. This page describes the base, since that is where the behaviour is.

## Identity

```solidity
function contractName() external pure returns (string memory);   // "HookrModularHookV6WthV5"
function contractVersion() external pure returns (string memory); // "6.0.0"
```

## What Differs From the Default Root

`HookrSwapKernelV5Wth` is a copy of `HookrSwapKernelV3`, not a subclass: nothing in V3 that decides whether a correction runs is `virtual`, and V3 is part of a deployed, verified contract that cannot be edited. Five things differ from the copied source and nothing else does:

1. `_tryCorrection` no longer requires a trusted caller. A swap routed through the Universal Router or any aggregator reaches the executor too. The only pool exempt is one whose frozen stack names no correction executor, which on this root is a plain pool wearing the root's name.
2. Both `beforeSwap` and `afterSwap` attempt the correction on every qualifying swap, with or without a signed plan. Requiring a plan in `beforeSwap` let an arbitrageur move the reference venue first and close on this pool second, with nothing left for `afterSwap` to correct. A `beforeSwap` attempt on a quote-denominated swap is sized by converting the quote amount to subject at the pool's spot price (floored, so the hint can only be low); an uninitialized pool or an amount over `uint128` means no attempt.
3. `_prepare` leaves the correction recipient at zero for an unauthenticated caller instead of writing the raw `sender` into it, so the trader's share can never be paid to a router or aggregator contract that merely relayed the swap.
4. It links [`HookrModularCorrectionLibV3`](./HookrModularCorrectionLibV3.md), which makes the plan optional and, without a recipient, moves the trader's 2,000 bps to the triggering pool's LPs.
5. The correction window admits two senders instead of one: the pool's frozen correction executor, and the single contract that executor forwards every correction to, read once per transaction from `wthExecutor()` on the adapter with a 30,000-gas `staticcall`. The bound executor is the contract the seal already trusts to be called during the correction, so admitting its swap back into this pool for the length of that call widens nothing; a third sender, a different pool, or any non-empty `hookData` still reverts `ReentrantCallback`.

Everything else is the copied behaviour: the `DELEGATECALL` to the pinned accounting kernel with its code-hash check, the V2 correction storage namespace, the nested-callback guard, the try/catch isolation, and the three correction events.

## The One Place a Swap Can Fail on the Partner's Word

Before the delegated `beforeSwap` body, on a pool with an executor, the root asks the bound executor whether any v3 pool in WTH's registry for this pair is currently locked for re-entrancy. A lock means the caller is inside that pool's callback, which in observed traffic is an arbitrage bot that moved the reference venue first and is closing here. On a clean `true` the swap reverts `MevCallbackRefused(subject, quote)`, which takes the spread away from the bot and leaves the gap for the pool's own correction on the next swap.

The conditions are narrow. The read is a `staticcall` with a 200,000-gas stipend (`MEV_CHECK_GAS_STIPEND`), so a hostile executor can waste that much and nothing else. It is tried under two selectors, `0x6075521e` (`checkV3PoolsMev`) and `0x85c30352` (`checkV3PoolsMEV`), because the partner's code used both spellings and the kernel pins selectors rather than importing their interface. Only a successful call returning exactly one word equal to `1` refuses; a revert, a missing function, a short return or any other word is read as no MEV and the swap proceeds, so an executor that stops answering cannot brick the pool. It runs only outside the correction window, so the executor's own swap back into the pool is never refused.

This check sits outside the kernel's `try/catch` on purpose. Everything else on the correction path is fail-open; this is the one exception, and no surface may describe the root as unable to fail a user's swap.

## Constants

| Name | Type | Value |
| --- | --- | --- |
| `REQUIRED_FLAGS` | `uint160` | `0x28cc` (10444) |
| `KERNEL_FAMILY_ID` | `bytes32` | `keccak256("HOOKR_SWAP_DELTA_V1")` |
| `KERNEL_INSTANCE_LAYOUT_ID` | `bytes32` | `keccak256("HOOKR_KERNEL_INSTANCE_LAYOUT_V1")` |
| `STATEFUL_MODULE_MAGIC` | `bytes32` | `keccak256("HOOKR_STATEFUL_SWAP_MODULE_V1")` |
| `DYNAMIC_FEE_FLAG` | `uint24` | `0x800000` |
| `MEV_CHECK_GAS_STIPEND` | `uint256` | 200,000 |
| `MIN_SQRT_PRICE_LIMIT` | `uint160` | 4295128740 |
| `MAX_SQRT_PRICE_LIMIT` | `uint160` | 1461446703485210103287273052203988822378723970341 |

## State Variables

The same five immutables as the default root: `poolManager`, `stackRegistry`, `coordinator`, `accountingKernel` and `accountingKernelCodeHash`. The contract declares no storage of its own; `STORAGE_LAYOUT.json` pins it as a delegatecall host with none, and the constructor's one raw `sstore(1, 1)` initializes the accounting kernel's callback-state slot in the root's storage, the same convention the default root follows.

## Functions

`beforeSwap`, `afterSwap`, the `fallback` that forwards every other selector to the accounting kernel, `contractName`, `contractVersion`, `statefulModuleKernelMagic` and `kernelInstanceLayoutId` have the signatures and the meaning given on [`HookrModularHookV6`](./HookrModularHookV6.md#functions). The differences are the ones listed above.

### The correction, step by step

On a qualifying swap, in each phase:

1. The root marks the correction window in transient storage (state, executor, bound executor, pool id).
2. It calls `HookrModularCorrectionLibV3.dispatch` inside `try/catch` with the pool key, the swap direction, the trigger amount, the authenticated recipient (zero for an untrusted caller), the pool's frozen creator, the frozen `correctionMaxVolumeBps` and `correctionMinProfitQuote`, the phase, and the raw correction payload if a trusted router supplied one.
3. The library calls the adapter, the adapter calls WTH's executor, and the executor may swap into this pool; that inner swap's callbacks are admitted by `_checkCorrectionCallback` and return immediately with zero deltas.
4. The window is cleared and one event is emitted. `frozen correctionMaxVolumeBps` and `correctionMinProfitQuote` are forwarded to the adapter but WTH's interface takes neither, so sizing and the profit floor are WTH's own; the values a pool freezes are not caps Hookr enforces.

## Events

```solidity
event CorrectionAttemptSucceeded(PoolId indexed poolId, uint8 indexed phase, bytes32 indexed planDigest, uint256 realizedProfitQuote);
event CorrectionAttemptFailed(PoolId indexed poolId, uint8 indexed phase, bytes32 payloadHash, bytes32 reasonHash);
event CorrectionAttemptSkipped(PoolId indexed poolId, uint8 indexed phase, bytes32 payloadHash, bytes32 reasonHash);
```

`phase` is 1 for `beforeSwap` and 2 for `afterSwap`. On `Failed`, `reasonHash` is `keccak256(abi.encode(ok, returnSize, firstWord, secondWord))` of the executor call, or `keccak256(reason)` of a revert inside the library. On `Skipped`, it is one of the library's skip constants, listed on its page. These three events are emitted from this root's address only; the default root's lane never runs.

## Errors

The default root's errors, plus:

| Error | When |
| --- | --- |
| `MevCallbackRefused(address subject, address quote)` | the bound executor's MEV view returned a clean `true` for this pair before the swap |

## The Sealed Profile

`HookrStackRegistryV2.rootProfile(0xd8b6c165…)` reads sealed since block 61,272,550: version 1, one module (the native block, `moduleSetHash` identical to the default profile's), the same router and quoter integrations, and correction-executor integration `0xc4ae59ad…` whose implementation is [`HookrWthExecutorAdapterV1`](./HookrWthExecutorAdapterV1.md) at its registered code hash. `createStack` rejects any stack on this root whose `correctionExecutor` is not that adapter, and the registry admits the executor on a pool only when the quote is native ETH sorted as `currency0`, the creator is non-zero, `correctionMaxVolumeBps` is in `(0, 5000]`, `correctionMinProfitQuote` is non-zero, and `correctionFeePolicyId` equals the adapter's `feePolicyId()`. A pool that leaves all five correction fields zero is admitted too, and on it the lane never runs.

## Gas

A correction is fail-open, which makes its cost invisible to `eth_estimateGas`: the estimate converges on the cheapest gas at which the swap still succeeds, and a swap that skipped the correction succeeded. A caller who wants the correction to run sets the gas limit from a measured floor rather than from the node's estimate. `hookr-sdk` 0.2.0 applies a 1,100,000 floor to swaps on this root's pools. A swap sent with less may skip the correction and still settle.

## Address Mining

`address & 0x3fff == 0x28cc`, mined through `HookrReleaseCreate2FactoryV1` with salt `0x7a973dab…6bb80` in block 61,270,834. See [Hook permissions](./hook-permissions.md).

## Listing

Not on Uniswap's routing allowlist and not on the hooklist as of 2026-09-21. Pools on it trade through the Universal Router and the Hookr router, because the hook accepts any caller; Uniswap's own interface does not route to them.
