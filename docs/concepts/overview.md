# Overview

Hookr is two Uniswap v4 hooks that serve many pools: a default root that runs the five rules below, and a recapture root that runs the same five rules and adds a partner correction lane (see [Architecture](./architecture.md)). A pool opened through Hookr names one root and freezes a configuration at creation, and the root reads it on every callback. Nothing about that configuration can change afterwards, including by the Hookr owner.

The hook does five things, each independently switchable per pool:

- A surge LP fee that rises with trade size relative to in-range depth.
- A temporal guard window on newly launched tokens: a per-block quote buy cap, a snipe tax, exact-output buys blocked, and outside liquidity blocked.
- An auto-burn of a share of subject output on buys.
- An in-swap LP reward donated to in-range liquidity.
- An Nth-buy pot paid to the buyer who trips the counter.

All five work on any quote currency: native ETH, HOOKR, USDG, a Robinhood tokenized stock, or any other ERC-20.

## Two Lanes

A **new-token market** deploys a fixed-supply ERC-20, places the whole supply in one coordinator-held, token-only sell band, and optionally executes a creator buy in the same transaction. The band cannot be removed. This lane can use the guard window.

An **existing-asset market** initializes a fresh pool for a token that already exists. It adds no liquidity and holds no position; LPs use ordinary v4 periphery. This lane has no founding position, no guard window, and no creator buy. Opening one is permissionless while market opening is not paused, and records only who opened it, not who owns the token.

## What an Integrator Needs to Know

- The pool's `fee` field carries the v4 dynamic fee flag `0x800000`. The hook sets the effective fee per swap.
- The hook address encodes flags `0x28cc`: `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`, `afterSwap`, `beforeSwapReturnsDelta`, `afterSwapReturnsDelta`. Removing liquidity is not hooked.
- A swap through the Universal Router with empty `hookData` behaves normally. Every rule applies except the pot leg, which needs an authenticated recipient the hook can only get from the Hookr router or quoter.
- A pool with any input cut on an exact-input buy requires the canonical full-fill price limit. Base-fee-only pools accept partial fills.

## Where to Read Next

| You want to | Read |
| --- | --- |
| Understand what each contract does | [Architecture](./architecture.md) |
| Know exactly who pays what | [Fee model](./fee-model.md) |
| Open a market | [Open a new-token market](../guides/open-a-new-token-market.md) |
| Route a swap or a quote | [Swapping and quoting](../guides/swapping-and-quoting.md) |
| Check what the owner can do | [Immutability and ownership](./immutability-and-ownership.md) |
| Review the hook for allowlisting | [Hook permissions](../reference/hook-permissions.md) and [Invariants](../security/invariants.md) |
