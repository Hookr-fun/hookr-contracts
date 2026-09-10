# RWA and ERC-20 quotes

Every rule works on every quote currency. This page covers what changes when the quote is not native ETH, and what to know before pairing a tokenized stock.

## ERC-20 Quotes

The claim ledger is keyed by quote currency, so a native-quoted pool and an ERC-20-quoted pool share the module without their balances ever crossing. `claim`, `claimTo`, `collect` and `accountingInvariant` all take the quote address, with `address(0)` meaning native.

Four things differ from a native quote:

**Payment.** `openNewTokenMarket` and `openExistingTokenMarket` require `msg.value == 0` when `quote != address(0)`, and revert `InvalidPayment(expected, received)` otherwise. The coordinator itself pulls no quote on either lane: `quoteAmount` must be zero, and the only quote that moves at launch is the creator buy, which the router pulls (next paragraph).

**The creator buy.** For an ERC-20 quote the creator approves the Hookr router for the quote token before launching. The launch reverts otherwise.

**The pot floor.** A native quote uses the fixed `MIN_POT_BUY_WEI = 0.001 ether`. An ERC-20 quote must set `potMinBuyWei` to at least `10 ** (decimals - 3)`, one thousandth of one whole unit. Admission enforces this with a gas-bounded `decimals()` read and rejects a token whose decimals are below 3 or above `MAX_QUOTE_DECIMALS = 36`, or whose `decimals()` call fails. USDG has six decimals, so its floor is 1,000 base units.

**Transfer behaviour.** The coordinator and the module both compare balances before and after every ERC-20 movement; the coordinator reverts `TaxedTransfer` on a mismatch and the module reverts `ClaimTransferFailed`. A fee-on-transfer or rebasing quote will not work as a Hookr quote currency.

## Robinhood Tokenized Stocks

A Robinhood stock token on chain 4663 is a `BeaconProxy` over a shared `Stock` implementation. Four properties matter to anyone integrating a pool that holds one.

**A shared pause and blocklist registry.** Pause and blocklist state lives in one chain-wide contract, not per token: [`0xe10b6f6B275de231345c20D14Ab812db62151b00`](https://robinhoodchain.blockscout.com/address/0xe10b6f6B275de231345c20D14Ab812db62151b00). The ERC-1967 beacon slot of both NFLX and AAPL holds that address, and it answers `implementation()` and `isBlocked(address)`, so the same contract carries the implementation pointer and the access state. A pause halts transfers of that token, which halts every pool holding it. This is fail-closed: swaps revert rather than settling at a stale price.

**A blocklist.** The implementation checks `from`, `to` and `spender`. A blocked address cannot trade the pool, and a pool whose hook or router is blocked stops working for everyone.

**`adminBurn`.** A privileged role can burn a holder's balance. The supply a Hookr pool prices against is not fixed by the token's own contract.

**ERC-8056 `uiMultiplier`.** Corporate actions change a display multiplier. It changes what an interface should show. It does not change pool math, tick spacing, or any Hookr rule.

## Combinations to Warn On

The contract permits all of these. The judgment is the integrator's.

| Combination | Why it needs a warning |
| --- | --- |
| Burn with a tokenized stock as subject | Every buy destroys a claim on a real share. |
| Burn with a stablecoin as subject | Every buy destroys a unit of the peg. |
| Burn with any subject the creator does not control | If the token blocks the transfer to `0x...dEaD`, every buy reverts and the pool fails closed. Test one buy before launching. |
| Any pool holding a stock on either side | A pause of that token halts this pool. Corporate actions change the displayed multiplier, not the pool math. |
| Pot or LP reward with a stock as quote | Payouts and donations are denominated in shares. |
| Subject is HOOKR with burn enabled | Allowed and coherent. Every buy burns HOOKR. |

Two combinations the contract rejects outright: subject equal to quote, and a guard window on the existing-asset lane.

## What the Hook Does Not Add

There is no stock-specific code path. A market pairing a tokenized stock satisfies the same `StackLimits` preconditions as any other market: the trusted router and quoter must be registered integrations, and `maxLpFeePips` must cover the base fee plus the surge cap. The properties above come from the token, not from the hook.
