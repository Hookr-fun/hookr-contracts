# Open an existing-asset market

## Introduction

An existing-asset market opens a fresh Uniswap v4 pool for a token that already exists, under one of the two Hookr root hooks. The coordinator initializes the pool and stops there: no liquidity, no position, no creator buy, no guard window.

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

## Choose a Root

A market names its root by the `kernelId` in its market parameters, and the coordinator resolves the root hook from the registry's active kernel for that id. Two are open:

| Root | `kernelId` | Root hook |
| --- | --- | --- |
| Default: the five rules | `0x1be0c118b1c6520d97de31ee9f0c33069f0e715ffcdcb16c87a343752bb5be14` | `0xb3cA29cF721380CEe8b8e4755F3865Ebc68Fe8cC` |
| Recapture: the five rules plus WTH's correction lane | `0xd8b6c165b82efc3b7498081f071ea4f2476e2fb9c61b2e614aba2a016f94555a` | `0xb914f955294799de4b891bd2EA8AF628Fa1c68CC` |

On the default root, leave the five correction fields in `limits` at zero. On the recapture root, the lane runs only on a pool whose stack freezes them, and the registry admits that only for a native-ETH quote (`currency0 == address(0)`): `correctionExecutor` is `0x28AF7A3645080e926a3101461e0Ec0594D42D806` (the adapter the profile seals), `correctionCreator` is your address (on this lane `market.creator` records only who opened the pool, and this field is who the executor pays 40% of every realised correction to), `correctionFeePolicyId` is `0xd2653e091cb7002585fd8b1192b58f11b9c951061dc797123e37d5e2ccb45cef`, `correctionMaxVolumeBps` is in `(0, 5000]` and `correctionMinProfitQuote` is non-zero; the last two are frozen but not enforced, because WTH's interface takes neither. A pool opened on the recapture root with all five at zero is admitted and behaves as a plain pool. Swaps on a correcting pool should carry a gas limit of at least 1,100,000, because a correction is fail-open and `eth_estimateGas` converges on a swap that skipped it. The [`hookr-sdk`](https://www.npmjs.com/package/hookr-sdk) package, version 0.2.0, exports `ROOTS`, `RECAPTURE_CORRECTION`, `correctionFor`, `swapGasLimit` and `listRoots` for exactly these values. Read [HookrModularHookV6WthV5](../reference/HookrModularHookV6WthV5.md) before choosing it: on that root, and only there, a swap can be refused on WTH's answer. The recapture root is not on Uniswap's routing allowlist as of 2026-09-21, so Uniswap's own interface does not route to its pools.

## Build the Config

```solidity
HookrNativeMechanicsBlockV2.Config memory cfg = HookrNativeMechanicsBlockV2.Config({
    poolId:                  poolId,
    kernel:                  rootHook,      // the root for your kernelId
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
