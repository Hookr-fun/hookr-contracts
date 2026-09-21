# HookrModularCorrectionLibV3

Source: [`src/libraries/HookrModularCorrectionLibV3.sol`](../../src/libraries/HookrModularCorrectionLibV3.sol)

The fail-open correction dispatcher the recapture root links, at [`0x11996B4e04571718d49454fC52830dc7fA0FF99C`](https://robinhoodchain.blockscout.com/address/0x11996B4e04571718d49454fC52830dc7fA0FF99C). An external library: `HookrSwapKernelV5Wth` calls `dispatch` by `DELEGATECALL` inside its `try/catch`, so the library runs in the root's context and a revert in it is a skipped correction. It is linked only into the recapture root; the default root links `HookrModularCorrectionLibV2`, whose lane never runs.

Same gas stipend, return-shape checks and skip taxonomy as V2. The one behavioural change is that a correction plan is optional: a swap that arrives without an authenticated recipient still reaches the executor, with `rebateRecipient = address(0)` and the trader's share reassigned to the triggering pool's LPs; a swap that carries a signed plan keeps every V2 check and the V2 split.

## Constants

| Name | Value | Meaning |
| --- | --- | --- |
| `EXECUTOR_GAS_STIPEND` | 2,300,000 | Ceiling handed to the correction executor: exactly the adapter's `EXECUTOR_CALL_GAS_LIMIT` plus its `ADAPTER_GAS_RESERVE`. The EVM forwards at most 63/64 of what remains, so a caller who sends less simply gives the executor less |
| `DISPATCH_GAS_RESERVE` | 800,000 | Retained for readers; no longer an admission condition. Gating on a fixed floor let any caller take the arbitrage by sending just under it |
| `CLOCK_GAS_STIPEND` | 30,000 | For the execution-height read when a plan is present |
| `SIGNED_HOOK_DATA_LENGTH` | 480 | The one accepted length of a signed plan payload |
| `FALLBACK_TRADER_BPS`, `FALLBACK_CREATOR_BPS`, `FALLBACK_TRIGGER_POOL_BPS` | 0, 4,000, 4,000 | The split without a recipient; with one, `HookrWthFeePolicyV2`'s 2,000 / 4,000 / 2,000 |

Skip reasons, each the `keccak256` of its name: `HOOKR_CORRECTION_V3_INELIGIBLE`, `HOOKR_CORRECTION_V3_BAD_PAYLOAD`, `HOOKR_CORRECTION_V3_PHASE_MISMATCH`, `HOOKR_CORRECTION_V3_EXPIRED`, `HOOKR_CORRECTION_V3_CLOCK_UNAVAILABLE`, `HOOKR_CORRECTION_V3_LOW_GAS` (declared, not emitted by this version).

## dispatch

```solidity
function dispatch(
    address executor,
    PoolKey calldata key,
    bool outerZeroForOne,
    uint128 triggerBaseAmount,
    address authenticatedRecipient,
    address creator,
    uint16 maxArbVolumeBps,
    uint96 poolMinProfitQuote,
    uint8 phase,
    bytes calldata raw
) public returns (DispatchResult memory result);
```

1. Skips `INELIGIBLE` when the executor, the trigger amount or the creator is zero. A zero creator with a 4,000 bps creator share is exactly the shape the executor must reject, so it is skipped here first.
2. Builds the split: the fallback without a recipient, the fee policy's with one.
3. If a raw payload arrived: without a recipient it is `BAD_PAYLOAD` (plans only ever travel inside an authenticated router envelope); otherwise it is decoded strictly (480 bytes, every field range-checked), must name this recipient and the current plan version, must be for this phase (`PHASE_MISMATCH`), and must not be past its `maxBlock` at the executor's execution height (`CLOCK_UNAVAILABLE` if that read fails) or its deadline (`EXPIRED`).
4. Calls `executor.executeArbitrage(request)` with the stipend, reading at most two returned words. Anything but success with exactly 64 bytes returned is `STATUS_FAILED` with `reasonHash = keccak256(abi.encode(ok, returnSize, firstWord, secondWord))`; otherwise `STATUS_SUCCEEDED` with the realised profit and the plan digest.

The root emits one of its three `CorrectionAttempt*` events from the result.

## Verification

This address holds no verified source on Blockscout or Sourcify. It was deployed on 2026-09-11 (tx `0xaed05dd5…975fc2`, block 60,326,894) for an earlier recapture root under a profile that did not append the ipfs metadata hash, so its trailer is a solc-version-only CBOR and no full match is reachable at the address. Its 3,007 runtime bytes are 2,995 bytes of code plus that trailer; the code equals this repository's build of the file once the trailer and the library's self-address immutable are masked. The file itself is byte-identical to the one in the recapture root's verified bundle on Blockscout, which lists this address as the root's external library. Treat the address as unverified and the source as reviewed.
