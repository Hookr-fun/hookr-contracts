# Swapping and quoting

## Introduction

A Hookr pool is an ordinary Uniswap v4 pool with a dynamic fee. Any v4 caller can trade it. This guide covers what changes when you route through the Universal Router versus the Hookr router, and how to get a quote that matches what the swap will actually cost.

## Through the Universal Router

Nothing special is required. Build a `V4_SWAP` command against the pool's `PoolKey` and send empty `hookData`.

```
Commands.V4_SWAP
  Actions.SWAP_EXACT_IN_SINGLE   (key, zeroForOne, amountIn, amountOutMinimum, hookData = "")
  Actions.SETTLE_ALL             (inputCurrency, amountIn)
  Actions.TAKE_ALL               (outputCurrency, amountOutMinimum)
```

An ERC-20 input is pulled through Permit2, so the payer approves the token to Permit2 and then approves the Universal Router as a Permit2 spender with an amount and an expiry. A plain ERC-20 approval to the Universal Router is not read and the swap will fail to settle.

Every rule applies: the base fee, the surge fee, the guard window, the burn, and the LP reward. One thing does not.

**The pot leg is skipped.** The pot pays a specific wallet, and the hook can only authenticate a recipient carried in `hookData` from the pool's registered router or quoter. The Universal Router is not that router, so a swap through it runs with `activePotBps = 0`: it pays no pot cut and cannot win the pot. That is the intended behaviour, because crediting the router contract would make the pot unwinnable for anyone.

Sending non-empty `hookData` from an untrusted caller reverts `UntrustedHookData`.

## Through the Hookr Router

Use this when the trader should be eligible for the pot.

```solidity
uint256 amountOut = router.exactInput{value: amountIn}(
    HookrKernelRouterV3.ExactInputParams({
        key:               key,
        zeroForOne:        true,
        amountIn:          uint128(amountIn),
        amountOutMinimum:  uint128(minOut),
        sqrtPriceLimitX96: MIN_SQRT_PRICE_LIMIT,
        recipient:         trader,
        deadline:          block.timestamp + 300
    }),
    hex""
);
```

The router builds the authenticated `hookData` envelope itself. You do not construct it.

For an ERC-20 input, set `msg.value` to zero and approve the router directly. The router uses a plain `transferFrom`, not Permit2.

`exactOutput` takes `amountOut` and `amountInMaximum` and returns the input consumed, refunding any unused native value.

## The Price Limit Matters

On any pool with input cuts, an exact-input buy must use the canonical full-fill limit:

```solidity
sqrtPriceLimitX96 = zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT;
```

Anything else reverts `PartialFillUnsupportedWithInputCuts`. The cut is taken off the input before the swap runs, so a partial fill would leave the trader having paid a cut on quote that never reached the pool.

Input cuts means a non-zero LP reward or pot on that swap (the pot only through a trusted caller), or a non-zero surge, snipe tax or burn at a non-zero protocol share. A base-fee-only pool has none, so it accepts partial fills like any ordinary v4 pool.

Use `amountOutMinimum` for slippage on these pools, not a price limit.

## Quoting

Use the Hookr quoter. It runs the real hook callbacks, the real module walk and the real fee override, then reverts to discard the state.

```solidity
(uint256 amountIn, uint256 amountOut) = quoter.quote(
    HookrKernelQuoterV1.QuoteParams({
        key:               key,
        payer:             trader,
        recipient:         trader,
        zeroForOne:        true,
        amountSpecified:   -int128(uint128(amountIn)),   // negative for exact input
        amountBound:       uint128(minOut),
        sqrtPriceLimitX96: MIN_SQRT_PRICE_LIMIT
    }),
    hex""
);
```

It is not a `view` function, because it calls `poolManager.unlock`. Call it with `eth_call`, or with a static call from another contract.

Pass the real `recipient`. The pot leg is recipient-specific, so a different recipient can produce a different result.

A revert that is not `QuoteResult` bubbles up unchanged. A guard-window rejection or a cap breach reaches you as the same error the swap would have thrown, which is what you want to show a user.

## Quoting a Universal Router Swap

Use Uniswap's `V4Quoter` instead. It sees the same pool without the pot cut, which is exactly what a Universal Router swap pays.

Do not quote through the Hookr quoter and then route through the Universal Router. The Hookr quote includes the pot cut, so the two will disagree by `potBps` on a pool with a pot.

## What a Trader Actually Pays

| Quadrant | LP fee | Cuts | Protocol |
| --- | --- | --- | --- |
| Exact-input buy | base + size-scaled surge + snipe | LP reward, pot, burn | share of the surcharge and of each cut |
| Exact-output buy | base + the full surge ceiling | none | share of the surcharge, on the quote input |
| Exact-input sell | base + size-scaled surge | none | share of the surcharge, on the quote output |
| Exact-output sell | base + the full surge ceiling | none | none |

Exact-output swaps pay the surge ceiling rather than a size-scaled surge, because the hook has no input amount when it must set the fee. On a pool with a wide gap between `baseFeePips` and `maxFeePips`, that difference is large. Price it before routing exact-output.

## Guard-Window Behaviour

While a new-token pool's guard window is open:

- Exact-output buys revert `ExactOutputBlockedDuringGuard`.
- A buy that would push the block's running total past `maxBuyQuoteAmount` reverts `MaxBuyExceeded(attempted, max)`.
- Buys pay `snipeTaxPips` on top of the base and surge fees.
- Sells are unaffected.

Quote before every guard-window buy. The per-block cap is shared across every trader, so a quote from one block can be wrong in the next.

## Next Steps

Read [Providing liquidity](./providing-liquidity.md) for the LP side of the same pool.
