# Open a new-token market

## Introduction

A new-token market deploys a fixed-supply ERC-20, opens a Uniswap v4 pool for it, places the whole supply in one coordinator-held sell band, and optionally buys some of it back for you in the same transaction. It is the only lane that can use a guard window.

This guide takes you through one launch on a native-ETH quote, then covers what changes for an ERC-20 quote.

## Build the Module Config

Everything a pool does lives in one struct. Start from the pool you intend to open and fill it in.

```solidity
HookrNativeMechanicsBlockV2.Config memory cfg = HookrNativeMechanicsBlockV2.Config({
    poolId:                  poolId,              // from poolKeyFor(...).toId()
    kernel:                  rootHook,
    subject:                 previewedTokenAddress,
    quote:                   address(0),          // native
    lockedLiquidityProvider: coordinator,         // required when the guard is on
    guardEndBlock:           uint40(block.number + 600),
    baseFeePips:             3000,                // 0.30%
    maxFeePips:              10000,               // 1.00% surge ceiling
    snipeTaxPips:            250000,              // 25% during the guard
    surgeSens:               2,
    burnBps:                 200,                 // 2% of subject output
    lpBps:                   50,                  // 0.5% of buy size
    potBps:                  50,                  // 0.5% of buy size
    royaltyBps:              500,                 // 5% of the cuts
    potEveryNBuys:           25,
    maxBuyQuoteAmount:       1 ether,
    potMinBuyWei:            0.001 ether,
    royaltyTo:               royaltyRecipient,
    protocolRecipient:       treasuryForwarder,
    protocolShareBps:        coordinator.protocolShareBps(creator)   // creator = the address that will call openNewTokenMarket
});
```

Four of these are not free choices. `poolId` must be the pool you are about to open. `kernel` must be the root hook you are opening on (see Choose a root below). `lockedLiquidityProvider` must be the coordinator whenever `guardEndBlock` is non-zero, and the zero address whenever it is not. `protocolRecipient` and `protocolShareBps` must be exactly what the coordinator resolves for you, or admission reverts.

Read the full rule set in [Config schema and limits](../reference/config-schema-and-limits.md) before you commit to values. The validator rejects several combinations that look reasonable, such as a non-zero `surgeSens` with `maxFeePips == baseFeePips`.

## Predict the Token Address

The config names the subject token, and the token does not exist yet. Ask the coordinator what address the launch will produce.

```solidity
address subject = coordinator.previewNewTokenAddress(args, intentId);
```

The address depends on the launch arguments, your address as `expectedCreator`, your `deploymentSalt` and the `intentId` you will pass. Any caller can compute it before the transaction is sent, which is what lets you build the config and the `PoolKey` first. Fill `subject` in and derive the `PoolKey`:

```solidity
PoolKey memory key = coordinator.poolKeyFor(subject, args.market);
```

`poolKeyFor` sorts the currencies, sets `fee` to `0x800000`, and names the root hook for the kernel id in `args.market`. Take `key.toId()` for the config's `poolId`.

## Choose a Root

A market names its root by the `kernelId` in its market parameters, and the coordinator resolves the root hook from the registry's active kernel for that id. Two are open:

| Root | `kernelId` | Root hook |
| --- | --- | --- |
| Default: the five rules | `0x1be0c118b1c6520d97de31ee9f0c33069f0e715ffcdcb16c87a343752bb5be14` | `0xb3cA29cF721380CEe8b8e4755F3865Ebc68Fe8cC` |
| Recapture: the five rules plus WTH's correction lane | `0xd8b6c165b82efc3b7498081f071ea4f2476e2fb9c61b2e614aba2a016f94555a` | `0xb914f955294799de4b891bd2EA8AF628Fa1c68CC` |

On the default root, leave the five correction fields in `limits` at zero. On the recapture root, the lane runs only on a pool whose stack freezes them, and the registry admits that only for a native-ETH quote (`currency0 == address(0)`): `correctionExecutor` is `0x28AF7A3645080e926a3101461e0Ec0594D42D806` (the adapter the profile seals), `correctionCreator` is your address and is frozen as the creator the executor pays 40% of every realised correction to, `correctionFeePolicyId` is `0xd2653e091cb7002585fd8b1192b58f11b9c951061dc797123e37d5e2ccb45cef`, `correctionMaxVolumeBps` is in `(0, 5000]` and `correctionMinProfitQuote` is non-zero; the last two are frozen but not enforced, because WTH's interface takes neither. A pool opened on the recapture root with all five at zero is admitted and behaves as a plain pool. Swaps on a correcting pool should carry a gas limit of at least 1,100,000, because a correction is fail-open and `eth_estimateGas` converges on a swap that skipped it. The [`hookr-sdk`](https://www.npmjs.com/package/hookr-sdk) package, version 0.2.0, exports `ROOTS`, `RECAPTURE_CORRECTION`, `correctionFor`, `swapGasLimit` and `listRoots` for exactly these values. Read [HookrModularHookV6WthV5](../reference/HookrModularHookV6WthV5.md) before choosing it: on that root, and only there, a swap can be refused on WTH's answer. The recapture root is not on Uniswap's routing allowlist as of 2026-09-21, so Uniswap's own interface does not route to its pools.

## Assemble the Market Parameters

```solidity
MarketParams memory market = MarketParams({
    quote:           address(0),
    subjectAmount:   uint128(SUPPLY),          // must equal SUPPLY
    quoteAmount:     0,                        // must be zero
    lpFeeRecipient:  yourFeeRecipient,         // must not be zero or the coordinator
    tickSpacing:     60,
    sqrtPriceX96:    openingPrice,             // must sit exactly on a usable tick
    kernelId:        kernelId,                 // default or recapture, see above
    modules:         selections,               // one entry: the native module and cfg
    limits:          limits
});
```

`limits.baseLpFeePips` must equal the config's `baseFeePips`. `limits.trustedRouter` and `limits.trustedQuoter` must be the registered Hookr router and quoter, or the pot leg cannot work and the registry rejects the stack. Leave every correction field zero on the default root; fill all five as described under Choose a root for a correcting pool on the recapture root.

`sqrtPriceX96` has to land exactly on a usable tick for your `tickSpacing`. That tick becomes the founding band's edge on the price: the upper edge when the token sorts as `currency1` (every native-quote pool, since `address(0)` sorts first), the lower edge when it sorts as `currency0`. The whole supply sits on the token's side of it. The coordinator reverts `InvalidMarketArgs` otherwise.

## Add a Creator Buy

Optional, and available on every quote currency.

```solidity
InitialBuyParams memory initialBuy = InitialBuyParams({
    quoteAmountIn:           0.5 ether,
    subjectAmountOutMinimum: minimumSubject,
    deadline:                block.timestamp + 300,
    moduleData:              hex""
});
```

Three limits apply. The buy passes through the guard, so it pays the snipe tax and it must fit inside `maxBuyQuoteAmount` for its block. It must consume its whole input or it reverts. And the subject it delivers, net of any burn, may not exceed `MAX_INITIAL_BUY_SUBJECT`, which is 5% of supply, or the launch reverts `InitialBuyAboveCap`.

To land exactly on the cap, compute the quote amount from your opening price and your founding band, then check it against your own `maxBuyQuoteAmount` before submitting. A buy that clears the 5% cap but breaks the per-block cap still reverts the whole launch.

## Send It

```solidity
(address subject, PoolId poolId) = coordinator.openNewTokenMarket{value: 0.5 ether}(
    args,        // NewTokenArgs, with expectedCreator == msg.sender
    intentId,    // bytes32(0) skips the replay check, allowed only when deploymentSalt is non-zero
    subject      // optional address assertion; address(0) to skip
);
```

`msg.value` must equal `market.quoteAmount + initialBuy.quoteAmountIn` for a native quote, which here is just the creator buy. It must be zero for an ERC-20 quote.

In one transaction the coordinator deploys the token, freezes the stack, initializes the pool, seeds the band, runs your buy, and emits `MarketCreated`, `ProtocolShareResolved` and `CreatorBuyExecuted`.

## An ERC-20 Quote

Three things change.

Set `msg.value` to zero. The coordinator itself pulls no quote; the only quote that moves at launch is the creator buy, and the router pulls that from your approval (next paragraph). A fee-on-transfer quote fails there, with the router's `InputDebitMismatch` or `SettlementMismatch`.

Approve the Hookr router for the quote token as well, if you are doing a creator buy. The router pulls the quote from you directly, not from the coordinator.

Set `potMinBuyWei` to at least `10 ** (decimals - 3)` if the pot is on. For USDG, which has six decimals, that is 1,000 base units. Admission reads `decimals()` with a bounded call and rejects a token reporting fewer than 3 or more than 36.

## Next Steps

Read [Collecting fees](./collecting-fees.md) to route the founding position's earnings.
