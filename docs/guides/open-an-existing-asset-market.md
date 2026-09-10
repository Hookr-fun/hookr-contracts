# Open an existing-asset market

## Introduction

An existing-asset market opens a fresh Uniswap v4 pool for a token that already exists, under the Hookr root hook. The coordinator initializes the pool and stops there: no liquidity, no position, no creator buy, no guard window.

Anyone can call it while market opening is not paused (`MarketOpeningPaused` otherwise; the owner can always open). It is one transaction and it commits the pool's rules forever.

## What This Lane Cannot Do

The guard window is rejected. `requiresLockedFoundingPosition` returns true for any config with a non-zero `guardEndBlock`, and admission reverts `GuardRequiresLockedFoundingPosition` on this origin. The guard's liquidity lock only means something when the coordinator holds the only position, and here it holds none.

`lpFeeRecipient`, `subjectAmount` and `quoteAmount` must all be zero. There is no founding position for fees to route to, so `collectLpFees` reverts `NoFoundingPosition` on this lane.

There is no creator buy. Buy through the router afterwards like anyone else.

## Pick a Base Fee Tier

On this lane you choose the base fee. Presets that match what traders expect from Uniswap:

| Tier | `baseLpFeePips` | Typical use |
| --- | --- | --- |
| 0.05% | 500 | stable pairs |
| 0.30% | 3000 | most pairs |
| 1.00% | 10000 | volatile or thin pairs |

Any value works as long as `baseLpFeePips + surge headroom + snipe tax` stays inside `MAX_TOTAL_FEE_PIPS` (50%), and as long as `limits.maxLpFeePips` covers the base fee plus the surge cap. Set the same number in both `limits.baseLpFeePips` and the module config's `baseFeePips`; admission rejects a mismatch.

## Build the Config

```solidity
HookrNativeMechanicsBlockV2.Config memory cfg = HookrNativeMechanicsBlockV2.Config({
    poolId:                  poolId,
    kernel:                  rootHook,
    subject:                 existingToken,
    quote:                   usdg,
    lockedLiquidityProvider: address(0),   // guard off
    guardEndBlock:           0,            // guard off
    baseFeePips:             3000,
    maxFeePips:              10000,
    snipeTaxPips:            0,            // must be zero when the guard is off
    surgeSens:               2,
    burnBps:                 0,
    lpBps:                   100,          // 1% of buy size
    potBps:                  0,
    royaltyBps:              0,
    potEveryNBuys:           0,
    maxBuyQuoteAmount:       0,            // must be zero when the guard is off
    potMinBuyWei:            0,
    royaltyTo:               address(0),   // must be zero when royaltyBps is zero
    protocolRecipient:       treasuryForwarder,
    protocolShareBps:        coordinator.protocolShareBps(msg.sender)
});
```

With the guard off, `lockedLiquidityProvider`, `snipeTaxPips` and `maxBuyQuoteAmount` must all be zero. The validator rejects any other combination rather than ignoring the stray fields.

## Send It

```solidity
PoolId poolId = coordinator.openExistingTokenMarket(
    ExistingTokenArgs({ subject: existingToken, market: market })
);
```

`msg.value` must be zero for an ERC-20 quote, and `market.quoteAmount` is zero on this lane, so it is zero for a native quote too.

The pool opens with no liquidity. It is tradeable the moment someone mints a position.

## Before You Open One

Opening a pool for a token you do not control commits that token's holders to rules you chose. Four things to check.

**The subject must permit a transfer to `0x…dEaD` if you enable the burn.** A pausable token, a blocklist, or a transfer hook that rejects it makes every buy revert and the pool fails closed. Test one buy on a fork before you launch.

**A tokenized stock brings a shared pause registry with it.** A pause of that token halts your pool. That is fail-closed rather than mispriced, but it is not something you control.

**Burning a stock destroys a claim on a real share, and burning a stablecoin destroys a dollar.** Both are permitted by the contract. Both are almost always wrong.

**`market.creator` records who opened the pool and nothing else.** No ownership check is performed on the subject token. Never present that field as ownership or as the token team's endorsement.

## Next Steps

Read [Providing liquidity](./providing-liquidity.md) to mint the first position.
