# Providing liquidity

## Introduction

Hookr pools take liquidity through the ordinary Uniswap v4 `PositionManager`. There is no Hookr-specific liquidity contract and no Hookr position NFT. This guide covers the one restriction the hook adds and the fee behaviour that follows from the fee model.

## Minting a Position

Use `PositionManager` exactly as you would on any v4 pool.

```
Actions.MINT_POSITION   (poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)
Actions.SETTLE_PAIR     (currency0, currency1)
```

Pass empty `hookData`. The hook's `beforeAddLiquidity` reads it only for length, and an oversized payload reverts `HookDataTooLarge`.

For an ERC-20 currency, approve the token to Permit2, then approve `PositionManager` as a Permit2 spender with an amount and an expiry. `PositionManager` pulls through Permit2 and a plain ERC-20 approval to it is not read.

## The Guard-Window Block

A new-token pool blocks outside liquidity while its guard window is open:

```
ExternalLiquidityBlockedDuringGuard
```

Any sender other than the coordinator reverts. The window closes at the pool's `guardEndBlock`, after which anyone can mint.

Check before you try:

```solidity
(HookrModuleTypesV1.ModuleSnapshot memory m, bytes memory config) = registry.moduleAt(poolId, 0);
HookrNativeMechanicsBlockV2.Config memory cfg =
    abi.decode(config, (HookrNativeMechanicsBlockV2.Config));
bool guardOpen = cfg.guardEndBlock != 0 && block.number < cfg.guardEndBlock;
```

Existing-asset pools never have a guard window, so they never block.

## Removing a Position

Removing liquidity is not hooked. The permission bits for `beforeRemoveLiquidity` and `afterRemoveLiquidity` are not set, so the PoolManager never calls the hook on a burn or a decrease.

No Hookr rule can trap an LP position, during the guard window or afterwards. Use `PositionManager` as normal.

## What You Earn

Three streams reach an in-range position, and only the first two are visible as v4 fee growth.

**The base LP fee, in full.** The protocol takes no share of it. A pool with no add-ons pays LPs everything a v3-style pool would.

**The LP part of the surge and snipe surcharge.** The hook sets the effective fee per swap by returning an override, so the surcharge arrives as ordinary fee growth. The protocol's share is carved out before the override is applied, so what you see is already net.

**In-swap LP-reward donations.** If the pool has `lpBps` set, part of every exact-input buy is donated to in-range liquidity inside the swap. It lands as fee growth for whoever is in range at that moment, so a position that goes out of range stops receiving it immediately, unlike a periodic distribution.

The burn and the pot do not reach LPs. The burn reduces subject supply; the pot pays one trader.

## Reading the Effective Fee

The pool's `fee` field is `0x800000`, the dynamic-fee flag, so it tells you nothing about what a swap costs. Two ways to get the real number:

Read the frozen base fee from the registry:

```solidity
HookrModuleTypesV1.StackCore memory core = registry.stack(poolId);
uint24 baseFee = core.limits.baseLpFeePips;
```

Or push it into the PoolManager's dynamic-fee cache, if you have a consumer that reads the cache directly:

```solidity
accountingKernel.syncBaseFee(key);
```

That call is permissionless and only ever writes the pool's own frozen base fee.

For the effective fee including surge on a given trade size, quote it. There is no view that returns it, because it depends on in-range depth at the moment of the swap.

## Concentrated Positions and Surge

The surge fee scales with trade size relative to in-range depth, so a narrow position sees higher effective fees on the same trade flow than a wide one. It also goes out of range faster. The usual concentrated-liquidity tradeoff applies, with the surge making both sides of it larger.

## Next Steps

Read [Collecting fees](./collecting-fees.md).
