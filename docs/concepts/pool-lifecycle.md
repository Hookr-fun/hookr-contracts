# Pool lifecycle

A Hookr pool is created once and never reconfigured. This page follows one pool from creation to steady state.

## 1. The Creator Picks a Configuration

The caller assembles a `MarketParams`: the quote currency, the tick spacing, the opening square-root price, the `kernelId` of the sealed root profile, the module selections, and the `StackLimits`. The native mechanics module is mandatory, so exactly one selection carries a `HookrNativeMechanicsBlockV2.Config` in its `config` field.

Two fields must agree across the two structures: `limits.baseLpFeePips` and the module config's `baseFeePips`. Admission rejects a mismatch.

## 2. Admission

`HookrMarketCoordinatorV5` calls into `HookrNativeMechanicsCoordinatorLibV2`, which walks the selections and proves, for the one selection whose `moduleKey` is `keccak256("HOOKR_NATIVE_MECHANICS")`:

- The registered module version is exactly 2 and its config schema hash matches.
- Its execution mode is `STATEFUL_V1`, its phase mask covers all phases, and its on-chain code hash still equals the one the catalog registered.
- `validateProtocolShare(config)` returns true, which proves the share is within `MAX_PROTOCOL_SHARE_BPS`, that the config names the module's own immutable recipient, and that an ERC-20 quote's pot floor is at least one thousandth of a whole unit.
- The module's immutable recipient equals `coordinator.treasuryBeneficiary()`.
- The config's share equals `coordinator.protocolShareBps(creator)`, or the call reverts `ProtocolShareTierMismatch`.
- A guard window is requested only on the new-token lane, or the call reverts `GuardRequiresLockedFoundingPosition`.
- The guard end block is in the future and no more than `MAX_GUARD_BLOCKS` ahead.

Every one of these reads is gas-bounded. A target that reverts or returns a short word fails admission closed.

## 3. The Stack Is Frozen

`HookrStackRegistryV2.createStack` derives per-pool caps by calling `validateStack` on the module, checks them against the catalog's registration ceiling, and stores one `StackCore` for the `PoolId`. The record holds the kernel, the subject and quote, the stack hash, and the trusted router and quoter with their code hashes; alongside it the registry stores the frozen config hash of each module, which `frozenModuleConfigHash(poolId, module)` returns.

From here the pool's behaviour is fully determined. Nothing in the registry, the catalog, or the coordinator can change it.

## 4. The Pool Is Initialized

The coordinator initializes the v4 pool with `fee = 0x800000` and `hooks = the root hook`. `beforeInitialize` accepts the call only from the coordinator, only once, and only when the `PoolKey` matches the frozen stack. It emits `MarketInitialized` and marks the stack initialized.

## 5. Liquidity

**New-token lane.** The coordinator places the entire fixed supply in one token-only band whose quote-side edge sits exactly on the opening price (the lower edge when the token sorts as `currency0`, the upper edge when it sorts as `currency1`). The coordinator owns that position and exposes no removal path. Any sub-unit quantization residue is burned.

**Existing-asset lane.** No liquidity is added. LPs mint their own positions through the v4 `PositionManager`.

## 6. The Optional Creator Buy

On the new-token lane only, the coordinator can execute one exact-input buy for the creator in the same transaction, after the band is seeded. It is available on every quote currency. It passes through the guard like any other buy, so it pays the snipe tax and respects `maxBuyQuoteAmount`, and the subject it delivers may not exceed `MAX_INITIAL_BUY_SUBJECT`, 5% of supply, measured after any burn.

## 7. Trading

Swaps arrive through the Universal Router, the Hookr router, the Hookr quoter in simulation, or any other v4 caller. See [Swapping and quoting](../guides/swapping-and-quoting.md).

## 8. Fee Collection

Founding-position fees accumulate inside the PoolManager until someone calls `collectLpFees(poolId)`, which is permissionless. Both currencies go to the creator's `lpFeeRecipient`.

Protocol shares accumulate in the module's `claimable[quote][protocolRecipient]` ledger until someone calls `collect(quote)` on the treasury forwarder, which is also permissionless.

Pot payouts and royalties land in the same claim ledger under the winner's or the royalty recipient's address, and they call `claim(quote)` or `claimTo(quote, to)` themselves.

## What Ends

Nothing. A Hookr pool has no expiry, no migration, and no shutdown. The guard window closes at its configured block and every other rule runs for as long as the pool exists.
