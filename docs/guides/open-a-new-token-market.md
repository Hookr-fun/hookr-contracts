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

Four of these are not free choices. `poolId` must be the pool you are about to open. `kernel` must be the root hook. `lockedLiquidityProvider` must be the coordinator whenever `guardEndBlock` is non-zero, and the zero address whenever it is not. `protocolRecipient` and `protocolShareBps` must be exactly what the coordinator resolves for you, or admission reverts.

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

`poolKeyFor` sorts the currencies, sets `fee` to `0x800000`, and names the root hook. Take `key.toId()` for the config's `poolId`.

## Assemble the Market Parameters

```solidity
MarketParams memory market = MarketParams({
    quote:           address(0),
    subjectAmount:   uint128(SUPPLY),          // must equal SUPPLY
    quoteAmount:     0,                        // must be zero
    lpFeeRecipient:  yourFeeRecipient,         // must not be zero or the coordinator
    tickSpacing:     60,
    sqrtPriceX96:    openingPrice,             // must sit exactly on a usable tick
    kernelId:        kernelId,
    modules:         selections,               // one entry: the native module and cfg
    limits:          limits
});
```

`limits.baseLpFeePips` must equal the config's `baseFeePips`. `limits.trustedRouter` and `limits.trustedQuoter` must be the registered Hookr router and quoter, or the pot leg cannot work and the registry rejects the stack. Leave every correction field zero.

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
