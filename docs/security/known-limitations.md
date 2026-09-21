# Known limitations

Facts a reviewer should know before reading anything else as a guarantee.

## The Protocol Share Ceiling Can Only Go Down

`MAX_PROTOCOL_SHARE_BPS` is a module constant with no setter. The owner can move the default and per-creator tiers anywhere inside it, for future pools only. Lowering the ceiling itself requires a new module, which requires a new catalog, a new registry, a new coordinator and a new root, because the binds involved are one-shot.

The worst case for any future pool is a 50% share of the opt-in add-ons, and never any share of the base LP fee.

## Registration Caps Are Permanent

`registerModule` fixes the module's structural ceiling for every pool it will ever serve. There is no updater and no raise path. Sizing them too low silently forecloses pool configurations that the module itself would accept; sizing them too high widens the reviewed surface. Treat the registration values as part of the audit scope, not as deployment parameters.

## One-Shot Binds Mean a New Module Needs a New Root

`setCoordinatorOnce` and `setCanonicalStatefulModuleOnce` each succeed once, `sealRootProfile` once per kernel,. A catalog, a registry and a root profile therefore serve exactly one module generation, and the next module needs a new set of all three.

## No Per-Pool Admin, Including in an Emergency

There is no kill switch, no fee override, no parameter change and no liquidity-removal path for a founding position. A pool that turns out to be misconfigured stays misconfigured. This is the deliberate trade for the immutability claim, and it is the right trade only if the interface's pre-launch validation is good.

## The Creator Keeps Most of Their Own Snipe Tax

The founding position is the only liquidity during the guard window, so a creator who buys their own launch through the guard recovers `1 - s` of the tax they pay. At the default share that is 80%.

The bound on the exploit is the dev-buy cap of 5% of supply, which limits how much a creator can cycle through their own guard in the launch transaction. It does not stop them from buying more from a second address afterwards, at which point they are paying the tax to themselves as an ordinary LP, which is the same position any other LP would be in.

## Exact-Output Sells Are Free of Protocol Take

The unspecified currency on an exact-output sell is the subject token. Taking a share there would leave the protocol holding subject tokens, which it never does. A market traded predominantly through exact-output sells earns the protocol nothing. Anyone modelling revenue needs to know this.

## A Base-Fee-Only Pool Earns Nothing

The protocol's revenue is a share of opt-in add-ons. A pool with no surge, no guard, no burn, no LP reward and no pot produces zero protocol revenue for its whole life.

## The Burn Slice Is Not the Burned Value

The burn withholds `burnBps` of subject output and burns 80% of it at the deployed share (`1 - s` in general). The protocol's 20% (`s`) is computed from gross quote input, not by converting the withheld subject amount at the execution price. The two differ by the price impact of the swap. This is a deliberate simplification that keeps the whole quote-side computation inside `beforeSwap`.

## Exact-Output Swaps Pay the Surge Ceiling

The hook has no input amount when `beforeSwap` must set the fee, so an exact-output swap pays `maxFeePips - baseFeePips` rather than a size-scaled surge. On a pool with a wide gap between the two, that is a large difference for a small trade.

## The Pot Leg Is Router-Dependent

A swap through the Universal Router, or any caller other than the pool's registered router or quoter, pays no pot cut and cannot win the pot. Two traders doing the same swap through different routers pay different amounts. An interface that shows one price for both is wrong.

## Partial Fills Are Unavailable on Most Pools

Any pool whose configured take on an exact-input buy is non-zero rejects a partial fill there: that is every pool with an LP reward or a pot (the pot only through a trusted caller), and every pool with a surge, a guard or a burn at a non-zero protocol share. Traders and aggregators used to setting a price limit must use `amountOutMinimum` instead.

## The Guard Is Per Block, Not Per Address

`maxBuyQuoteAmount` bounds the total quote spent on buys in one block for the pool, not per address. It raises the cost of sweeping a launch; it does not make it impossible for someone willing to spend across many blocks, and it does not distinguish one buyer from many.

## Tokenized Stocks Bring External Control

A Robinhood stock token is pausable and blocklistable through a chain-wide shared registry and carries an `adminBurn` role. A pause halts every pool holding it. None of that is in Hookr's control and none of it is mitigated here; the behaviour is fail-closed, which is the best available outcome, not an absence of risk.

## The Recapture Root Calls Code Hookr Cannot Read

Pools on the recapture root hand every swap, before and after, to WTH's arbitrage executor at `0xc356cf51134e0DF02BFE880115DD8c66Ead45803`, through Hookr's adapter. That executor is closed source and unverified, and Hookr does not control it. What it can do to a pool is bounded by the adapter and the kernel: consume up to 2,200,000 gas per attempt, swap back into the triggering pool inside the correction window, and pay or not pay the five shares of whatever profit it reports. What it cannot do is fail a user's swap through the correction path, because that path runs inside `try/catch`. Whether a correction actually runs, how large it is and whether the reported profit is honest are WTH's, and the two per-pool numbers that look like caps (`correctionMaxVolumeBps`, `correctionMinProfitQuote`) are frozen but not enforced, because WTH's interface takes neither.

## A Swap on the Recapture Root Can Be Refused

Only there, and only one way: before the swap body, the root asks WTH's executor whether a v3 pool in WTH's registry for the pair is locked, and reverts `MevCallbackRefused` on a clean `true`. That is designed to refuse an arbitrage bot closing a leg inside a v3 callback, but it is a partner's answer deciding a user's swap, read with a 200,000-gas `staticcall` and accepted only as a single true word. An executor that stops answering cannot brick the pool; an executor that answers `true` wrongly can refuse a legitimate swap until it stops. Nothing on the default root can do this.

## The Recapture Root's Correction Is Invisible to Gas Estimation

A correction is fail-open, so `eth_estimateGas` converges on the cheapest gas at which the swap succeeds, and a swap that skipped the correction succeeded. A caller who sizes the gas from the node's estimate will usually skip the correction the root exists for. Set the limit from a measured floor; `hookr-sdk` 0.2.0 uses 1,100,000.

## The Recapture Root's Linked Library Is Unverified at Its Address

`HookrModularCorrectionLibV3` at `0x11996B4e04571718d49454fC52830dc7fA0FF99C` was deployed without the metadata hash and no explorer can reach a full match there. Its code equals this repository's build once the trailer and the self-address immutable are masked, and the file is in the root's verified bundle, but a reader who trusts only explorer verification should treat the address as unverified.

## Deployed and Unaudited

The contracts are live on chain 4663. The evidence behind this documentation was gathered on two canary pools the deployer opened and traded: a throwaway token against ETH (pool id `0xe375174c3e1a06b3150df6e27b7c409c06f259b9853d6287cd5262d2de26cc15`, seven transactions) and HOOKR/ETH on the base fee alone (pool id `0x59fa67bc858058b4daad41ce138317c92e48fd9bccffdf2be646f18c2ec07720`, one position and one buy), a few thousandths of an ETH in all. Markets opened since by other addresses are not part of that evidence. Beyond that the evidence is source review, a full run of the deployment and trading path against a fork of chain 4663, and reads against the live contracts; nothing here has been exercised by trading from anyone else. No independent audit has been completed. Reading the source on the explorer is not the same as auditing it. See [Audit scope](./audit-scope.md) and [Deployments](../reference/deployments.md).
