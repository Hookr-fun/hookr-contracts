# Collecting fees

## Introduction

Four different balances accumulate around a Hookr pool and each one is collected differently. This guide covers all four and who can trigger them.

## Founding-Position Fees

A new-token market's founding position is held by the coordinator. Its fees sit inside the PoolManager until someone calls:

```solidity
(uint256 amount0, uint256 amount1) = coordinator.collectLpFees(poolId);
```

Anyone can call this. Both currencies go 100% to the market's `lpFeeRecipient`, chosen at launch and frozen: the creator's own wallet by default, or whoever a launcher named for its user. The caller gets nothing for calling it, so in practice the creator or their interface does.

There is no collect-time withholding. Everything the founding position earned, including the base fee and the LP part of the guard-window snipe tax, reaches `lpFeeRecipient`.

`collectLpFees` reverts `InvalidMarketArgs` for a pool the coordinator never opened and `NoFoundingPosition` on an existing-asset market, which has no position.

### Splitting Guard from Post-Guard

Both streams pay the same recipient, so an interface that wants to show them separately has to read the counter:

```solidity
uint256 guardEarned = nativeBlock.guardLpEarnedQuote(PoolId.unwrap(poolId)); // the block's counters take bytes32
```

That is cumulative guard-window quote earnings for the pool. Subtract it from cumulative collected quote to get post-guard earnings. The counter is informational and gates no transfer.

## Pot Winnings and Royalties

Both land in the module's claim ledger under the recipient's own address.

```solidity
nativeBlock.claim(quote);              // pays msg.sender
nativeBlock.claimTo(quote, recipient); // pays someone else
```

`quote` is the pool's quote currency, with `address(0)` for native. Balances are per quote, so a recipient owed both ETH and USDG calls twice.

Check first, because a zero balance reverts `NothingToClaim`:

```solidity
uint256 owed = nativeBlock.claimable(quote, account);
```

A claim measures the recipient's balance before and after and reverts `ClaimTransferFailed` unless it rose by exactly the debited amount. A quote token that under-delivers fails the claim rather than silently paying less.

## Protocol Share

Accrues to `claimable[quote][protocolRecipient]`, where the recipient is the treasury forwarder. Two permissionless calls move it:

```solidity
uint256 collected = forwarder.collect(quote);  // module -> forwarder -> target
forwarder.sweep(token);                        // forwarder -> target
```

`collect` claims and forwards in one call. If the target rejects the payment the funds are already out of the module, `ForwardDeferred` is emitted, and they rest on the forwarder until `sweep` runs. Nothing owed returns zero rather than reverting.

`sweep` pushes whatever the forwarder itself holds. It reverts when the target refuses, because at that point there is nothing left to rescue.

Only the destination is governed. Anyone can call either function.

## LP-Reward Donations

Nothing to collect. Donations are made inside the swap through the PoolManager's donate path, so they land as fee growth for whoever is in range at that moment and are collected with the rest of a position's fees through `PositionManager`.

## Reconciling

For a dashboard, keep accrued and collected as separate numbers.

| Number | Source |
| --- | --- |
| Protocol accrued | `ProtocolShareAccrued` events, or `claimable(quote, forwarder)` for the outstanding part |
| Protocol collected | `Collected` plus `Swept` events on the forwarder |
| Pot balance | `potWei(PoolId.unwrap(poolId))` (every block counter takes `bytes32`) |
| Pot paid out | `totalPotPaidWei(PoolId.unwrap(poolId))` |
| Subject burned | `totalBurnedTokens(PoolId.unwrap(poolId))` |
| LP donated | `totalLpDonatedWei(PoolId.unwrap(poolId))` |
| Founding fees collected | `market.cumulativeFee0` and `cumulativeFee1` from `getMarket(poolId)` |

Accrued is what the pool owes. Collected is what reached an address. Presenting the first as revenue received overstates it.

## Next Steps

Read [Events for indexers](../reference/events-for-indexers.md) for the full event surface.
