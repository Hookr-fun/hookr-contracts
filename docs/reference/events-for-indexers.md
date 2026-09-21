# Events for indexers

Which contract emits what, and how to keep the streams apart. Every event below is on a contract in this repository; the PoolManager's own `Swap`, `Initialize` and `ModifyLiquidity` are unchanged and still the source of truth for price and depth. There are two root hooks, and a pool's `PoolKey.hooks` says which one it is on: the default root `0xb3cA29cF721380CEe8b8e4755F3865Ebc68Fe8cC` or the recapture root `0xb914f955294799de4b891bd2EA8AF628Fa1c68CC`. Index both.

## Stream Separation

Six value streams run through a Hookr pool and they must not be summed together. Each has exactly one authoritative source.

| Stream | Denominated in | Source event | Notes |
| --- | --- | --- | --- |
| Base LP fee | both currencies | PoolManager fee growth | Not a Hookr event. Read it from the position or from the pool state |
| Surge and snipe surcharge, LP part | both currencies | PoolManager fee growth | Arrives as ordinary fee growth through the fee override; indistinguishable from the base fee on chain |
| Protocol share | quote | `ProtocolShareAccrued` | One event per stream per swap |
| LP-reward donation | quote | `LpRewardsDonated` | Donated in-swap, so it lands as fee growth for whoever is in range |
| Pot | quote | `HookFeesAccrued` for inflow, `JackpotHit` for payout | The pot balance is also readable as `potWei(poolId)` |
| Burn | subject | `AutoBurn` | The protocol's slice of the burn appears in `ProtocolShareAccrued`, in quote |

The LP part of a surcharge cannot be separated from the base fee by watching events, because both arrive as the same v4 fee growth. To split them, recompute: the pool's `baseFeePips` is in its frozen `StackLimits`, and the effective fee for a swap is recoverable from the swap's own amounts. Do not present a guessed split as measured.

## Per-Pool Counters

Cheaper than replaying events, and always consistent with them.

```solidity
potWei(poolId)                        // current pot balance
potBuyCount(poolId)                   // qualifying buys counted
guardLpEarnedQuote(poolId)            // cumulative guard-window quote LP earnings
totalHookFeesWei(poolId)              // cumulative LP-reward plus pot cuts
totalBurnedTokens(poolId)             // cumulative subject burned
totalLpDonatedWei(poolId)             // cumulative LP donations
totalPotPaidWei(poolId)               // cumulative pot payouts
totalProtocolShareWei(poolId)         // cumulative protocol share, all streams
protocolShareByStream(poolId, stream) // cumulative protocol share for one stream
```

`guardLpEarnedQuote` is what separates guard-window earnings from post-guard earnings for a founding position. Both are paid to the same `lpFeeRecipient`, so the counter is the only way to show them as two lines.

## HookrMarketCoordinatorV5

| Event | When | Index on |
| --- | --- | --- |
| `MarketCreated` | a market is opened | `poolId`, `subject`, `creator` |
| `ProtocolShareResolved` | same transaction as `MarketCreated` | `poolId`, `creator` |
| `CreatorBuyExecuted` | an initial creator buy settles | `poolId`, `subject`, `creator` |
| `LpFeesCollected` | `collectLpFees` runs | `poolId`, `recipient` |
| `CreatorTierSet`, `CreatorTierCleared` | owner changes a tier | `creator` |
| `DefaultProtocolShareBpsSet` | owner changes the default share for future pools | nothing indexed; one `uint24` argument |
| `MarketOpeningPauseSet` | owner pauses or unpauses opening | none |
| `OwnerProposed`, `OwnerSet` | ownership transfer | `pendingOwner` on the proposal, `owner` on the set |

`MarketCreated` carries the origin, so filter on it to tell the two lanes apart. `origin == NEW_TOKEN` has a founding position and possibly a guard window; `origin == EXISTING_TOKEN` has neither, and its `creator` records only who opened the pool.

## HookrNativeMechanicsBlockV2

| Event | When | Index on |
| --- | --- | --- |
| `HookFeesAccrued` | an exact-input buy takes an LP-reward or pot cut | `poolId` |
| `ProtocolShareAccrued` | any stream credits the protocol share | `poolId`, `stream` |
| `LpRewardsDonated` | quote is donated to in-range LPs | `poolId` |
| `JackpotHit` | the pot pays out | `poolId`, `winner` |
| `AutoBurn` | subject output is burned | `poolId` |
| `Claimed` | an account pulls its claim balance | `quote`, `account`, `to` |

The stream on `ProtocolShareAccrued` is a typed, indexed enum, so an indexer can filter on it directly:

```solidity
enum ProtocolStream { Surcharge, Guard, LpReward, Pot, Burn }
```

`Guard` only ever accrues on an exact-input buy inside a guard window, so guard-window protocol revenue is separable without arithmetic. A deferred slice taken in `afterSwap` is always pure surge and reports as `Surcharge`.

`HookFeesAccrued.burnWei` is always zero. The burn is reported by `AutoBurn`, in subject units.

`Claimed` covers three different things: a pot win, a royalty payment, and the treasury forwarder's own collection. Distinguish them by the `account`: the forwarder's address for the protocol share, `royaltyTo` for royalties, a trader for a pot win.

## HookrSwapAccountingKernelV3

Emitted from the root hook's address, because the kernel runs by `DELEGATECALL`, so the same event set arrives from both root addresses, `0xb3cA…e8cC` and `0xb914…68CC`. Point your indexer at both roots, not at the kernel.

| Event | When |
| --- | --- |
| `MarketInitialized` | the coordinator initializes a pool |
| `ModuleFeeAccrued` | a module's take is credited |
| `ModuleFeeSkipped` | a take was requested but could not be credited |
| `StatefulModuleAction` | per stateful module callback |
| `HookFee` | totals for one swap, in both currencies |

`ModuleFeeSkipped` is worth alerting on. It means a recipient could not receive a credit.

## The Recapture Root's Own Events

Three events and one revert appear only from the recapture root, `0xb914…68CC`, because only its lane runs.

| Event | When | Index on |
| --- | --- | --- |
| `CorrectionAttemptSucceeded` | WTH's executor returned a realised profit | `poolId`, `phase`, `planDigest` |
| `CorrectionAttemptFailed` | the executor call reverted or returned the wrong shape, or the dispatcher reverted | `poolId`, `phase` |
| `CorrectionAttemptSkipped` | the dispatcher declined to call: ineligible, bad or expired plan, wrong phase, clock unavailable | `poolId`, `phase` |

`phase` is 1 for `beforeSwap`, 2 for `afterSwap`, and an ordinary swap on an ETH-quoted pool produces one of these events per phase, so two per swap. `realizedProfitQuote` on `Succeeded` is what the executor reported, in quote; the split it paid is WTH's to account for, and the trader's share, the creator's share and the LPs' share are paid by WTH's executor directly rather than through any Hookr ledger, so none of them appears in `ProtocolShareAccrued` or the claim counters. `MevCallbackRefused(subject, quote)` is a revert, not an event: a swap that hit it never settled and emits nothing.

The executor's own swap back into the pool during a correction is an ordinary PoolManager `Swap` on the same pool id from the adapter or WTH's executor as sender, with no `SwapExecuted` on the router and zero deltas from the hook. Count it as a correction leg, not as a trade.

Three earlier recapture roots are superseded; the only pools on them are Hookr's own canary and rehearsal pools, which still emit the kernel's events from those addresses, which are listed in [legacy/README.md](../../legacy/README.md). An indexer that wants every Hookr pool includes them; nothing here recommends opening on them.

## HookrKernelRouterV3

| Event | When | Index on |
| --- | --- | --- |
| `SwapExecuted` | a swap settles and output is delivered | `poolId`, `stackHash`, `payer` |

Only swaps routed through the Hookr router emit this. A Universal Router swap on the same pool emits nothing here; use the PoolManager's own `Swap` for a complete picture, and treat `SwapExecuted` as the subset that carried an authenticated payer and recipient.

## HookrTreasuryForwarderV1

| Event | When | Index on |
| --- | --- | --- |
| `Collected` | an accrual was pulled and delivered | `quote`, `target` |
| `ForwardDeferred` | an accrual was pulled but the target refused it | `quote`, `target` |
| `Swept` | a held balance was pushed to the target | `token`, `target` |
| `TargetSet`, `NativeBlockSet` | owner rewires the forwarder | `target`, `nativeBlock` |
| `OwnerProposed`, `OwnerProposalCleared`, `OwnerSet` | ownership transfer | `pendingOwner` on the proposal, `owner` on the set; `OwnerProposalCleared` has no arguments |

Protocol revenue actually received is `Collected` plus `Swept`, not `ProtocolShareAccrued`. Accrual is what the pool owes; collection is what reached the target. A dashboard should show both, labelled as accrued and collected.

## HookrStackRegistryV2 and HookrModuleCatalogV1

Two registry events mark a pool's birth and are worth indexing: `StackConfigured(poolId, stackHash, kernelId, subject, quote, moduleCount)` when the coordinator freezes the stack, and `StackInitialized(poolId, stackHash, kernel)` when the kernel marks it initialized. Everything else on the registry and the catalog is administrative: `ModuleRegistered`, `ModuleRetired`, `CanonicalStatefulModuleSet`, `CoordinatorSet`, `IntegrationRegistered`, `IntegrationRetired`, `KernelRegistered`, `KernelRetired`, `KernelInstanceRegistered`, `KernelInstanceFactoryRegistered`, `KernelInstanceFactoryRetired`, `ExceptionalKernelInstanceRegistered`, `RootProfileSealed`, plus ownership events. None of those reaches a pool that is already open.

## Reconstructing a Pool's Configuration

Do not parse it out of events. Read it:

```solidity
HookrModuleTypesV1.StackCore memory core = registry.stack(poolId);
(HookrModuleTypesV1.ModuleSnapshot memory m, bytes memory config) = registry.moduleAt(poolId, 0);
HookrNativeMechanicsBlockV2.Config memory cfg = abi.decode(config, (HookrNativeMechanicsBlockV2.Config));
```

The config is frozen, so one read at any block is correct for the life of the pool.
