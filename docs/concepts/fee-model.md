# Fee model

The contracts are the authority. Every formula on this page is written the way `HookrNativeMechanicsBlockV2`, `HookrNativeMechanicsCoordinatorLibV2` and `HookrMarketCoordinatorV5` compute it, in integer arithmetic.

## 1. The One Sentence

**The protocol never takes a slice of the base LP fee. It takes a share from inside each opted-in add-on, 20% at the deployed default, and the trader pays exactly the amounts the pool was configured with.**

There is no flat protocol fee on any leg of any swap.

## 2. Streams and the Share

| Config field | Stream | Who pays it | Where it goes, at the deployed 20% share |
| --- | --- | --- | --- |
| `baseFeePips` | Base LP fee | every swap | **100% to in-range LPs. The protocol takes nothing from it.** |
| `maxFeePips` above base | Surge surcharge | swaps that move price | 80% to in-range LPs, 20% to the protocol |
| `snipeTaxPips` | Guard snipe tax | buys during the guard window | 80% to the creator, 20% to the protocol. The creator's 80% arrives as LP fee on the founding position, the only liquidity during the guard, and `collectLpFees` pays it to the creator's `lpFeeRecipient` |
| `lpBps` | LP-reward cut | exact-input buys | 80% donated to in-range LPs, 20% to the protocol |
| `potBps` | Nth-buy pot cut | exact-input buys through a trusted caller | 80% into the pot, 20% to the protocol |
| `burnBps` | Auto-burn | exact-input buys | 80% of the withheld subject burned to `0x...dEaD`, 20% taken in **quote** by the protocol |
| `royaltyBps` | Creator royalty | share of the LP-reward + pot cuts | to `royaltyTo`, computed on the 80% that remains **after** the protocol's 20%; the protocol takes no share of royalty |

20% is the pool's `protocolShareBps` of `2_000`: the value every pool opened so far carries, and the coordinator's `defaultProtocolShareBps` for the next one. In general the split is `1-s` to the LP side and `s` to the protocol, where `s` is the share frozen into the pool's immutable module config at market creation. A creator tier of zero means the protocol takes nothing from that creator's pools.

- Block constant `MAX_PROTOCOL_SHARE_BPS = 5_000` (50%). A config above it is structurally invalid, and `_authorize` re-checks the pair (rate at or below the ceiling, recipient equal to the block's immutable `protocolRecipient`) on **every swap and every liquidity add**, so a pool admitted outside the bound could not trade even if admission were bypassed.
- Coordinator `defaultProtocolShareBps` starts at `2_000` (20%) and mirrors the same ceiling.
- The owner can change the default and set a per-creator `creatorTier`, both at or below the ceiling. Both are resolved **once**, when `openNewTokenMarket` or `openExistingTokenMarket` opens the market, and frozen into the config, which is pinned by `frozenModuleConfigHash` and re-verified by hash on every swap. **A live pool's share can never be changed by anyone, including the owner.**

**Worst case for any future pool: a 50% slice of the opted-in add-ons, and never any slice of the base LP fee. A pool that opts into nothing but a base fee generates zero protocol revenue.**

## 3. Per-Quadrant Math

Notation: `x` is the swap's specified amount, `BPS = 10_000`, `PIPS = 1_000_000`, `/` is integer division (floor). `base = baseFeePips`, `surge` is the surge component in pips (the exact-input depth curve, or `maxFeePips - base` for exact-output), `snipe = snipeTaxPips` when the guard is active on a buy and 0 otherwise. Both are clamped so `base + surge + snipe <= MAX_TOTAL_FEE_PIPS` (surge is clamped first, then snipe into whatever room is left).

The protocol's surcharge slice is always the exact complement of the LP's:

```
pSurge = (surge * s) / BPS          lpSurge = surge - pSurge
pSnipe = (snipe * s) / BPS          lpSnipe = snipe - pSnipe
lpFeeSurchargePips = lpSurge + lpSnipe
```

so the trader's total fee rate is `base + surge + snipe` in every quadrant that carries a slice. The split moves value between LPs and the protocol; it never adds to the price.

### 3.1 Exact-input buy (quote in, quote is the specified currency)

Everything lands on the quote input leg in `beforeSwap`. With `activePot = potBps` for a trusted caller and `0` otherwise, `T = lpBps + activePot`:

```
burnP     = (burnBps * s) / BPS                 // protocol's slice of the burn, in bps of subject
takePips  = pSurge + pSnipe + burnP * 100       // protocol pips leg, on the quote input
B         = (x * T) / BPS                       // the gross configured cut
P         = (x * takePips) / PIPS               // the protocol pips leg, in quote

lpNet     = lpBps    - (lpBps    * s) / BPS     // LP-reward weight after the protocol slice
potNet    = activePot- (activePot* s) / BPS     // pot weight after the protocol slice
Pb        = T - lpNet - potNet                  // the protocol's weight inside the cut

kBase     = B - (B * royaltyBps) / BPS
donation  = (T - lpNet == 0) ? kBase : (kBase * lpNet) / T     // to in-range LPs, via v4 donate
potAdd    = (kBase * potNet) / T                               // into the pot
royalty   = ((B - (B * Pb) / T) * royaltyBps) / BPS            // royalty AFTER the protocol slice
protocol  = B - donation - potAdd - royalty                    // the protocol's slice of the cut
```

Trader pays `B + P`. LPs receive `base + lpSurge + lpSnipe` as the v4 LP fee plus `donation` as a v4 donation. `potAdd` goes to the pot, `royalty` to `royaltyTo`, `protocol + P` to the protocol. Every wei is accounted for: `B + P = donation + potAdd + royalty + protocol + P`.

The subject output is burned at the reduced weight `burnBps - burnP`; the protocol's `burnP` rides in `takePips` as quote (see section 4).

`T == 0` (no LP-reward cut and no active pot) means no bps leg at all: the weights and the royalty weight are reported as zero and only `P` is charged.

### 3.2 Exact-output buy (quote in, subject is the specified currency)

There is no LP-reward, pot or burn leg on this quadrant. The specified currency is the subject, and the kernel only accepts a specified-leg quote take when the quote *is* the specified currency. `surge` uses the configured ceiling `maxFeePips - base` because the input is unknown when `beforeSwap` must set the LP fee. Guard windows block exact-output buys outright, so `snipe = 0`.

`beforeSwap` reduces the LP fee to `base + lpSurge`; `afterSwap` takes `pSurge` pips of the quote input (the unspecified currency) for the protocol.

### 3.3 Exact-input sell (subject in, quote is the unspecified output)

`surge` is the exact-input depth curve on the subject input. `snipe = 0` (the snipe tax applies to buys only). `beforeSwap` reduces the LP fee to `base + lpSurge`, so the surcharge the trader pays in subject tokens is `1-s` of what it would otherwise be; `afterSwap` takes `pSurge` pips of the **quote output** for the protocol.

The two legs are denominated differently (the surcharge is charged in subject, the slice is taken in quote), so the protocol's slice is `s` of the surcharge *valued at the swap's own execution price, net of the effective fee*. That approximation is deliberate: the protocol must never hold subject tokens.

Because `beforeSwap` cannot know the post-swap pool state that `afterSwap` would need to recompute the depth curve, the block carries `pSurge + pSnipe` from `beforeSwap` to `afterSwap` in **transient storage** (EIP-1153, keyed by pool id, cleared on read). The value never survives the transaction, and only the pool's own kernel can write it: `_authorize` proves `msg.sender` is the frozen kernel before anything is stored.

### 3.4 Exact-output sell (subject in, quote is the specified output)

**Exempt.** The unspecified currency is the subject, so any afterSwap take would be denominated in subject tokens, which the protocol must never hold. The LP fee is therefore **not** reduced on this quadrant: `lpFeeSurchargePips = surge` and the whole surcharge stays with LPs. This asymmetry is intentional and is the only quadrant where LPs keep 100% of a surcharge on a pool with `s > 0`.

## 4. The Burn Slice, and Why It Is Quote-Denominated

`burnBps` is a cut of the **subject output** of an exact-input buy. The protocol must never hold subject tokens, so its share is taken in quote instead:

- The subject burn is reduced to `burnBps - burnP` where `burnP = (burnBps * s) / BPS`.
- `burnP * 100` pips are added to the protocol's pips leg **on the gross quote input `x`**, the same base the LP-reward and pot cuts use.

The two are exact complements in *rate*: whatever bps of subject the protocol gives up burning, it charges as the same bps of the gross quote input. They are not exact complements in *value*, because the subject output and the quote input differ by the execution price and the effective fee. The slice is based on the same gross quote amount the other input cuts use. The alternative (pricing the burn slice off the realised subject output) would require a second afterSwap quote take on a leg the kernel does not allow, and would make the protocol's take depend on the trade's own slippage.

A consequence of the integer floor: for `burnBps * s < BPS` (for example `burnBps = 1` at `s = 2_000`) `burnP` is 0, so the full burn happens and the protocol takes nothing. Rounding on every stream is toward the LP, pot or burn side, never toward the protocol, except for the sub-wei residue described in section 5.

## 5. Rounding, and Where Dust Goes

All slices are floors of the protocol's rate, so **the protocol's rate is never above `s`**: `pSurge`, `pSnipe` and `burnP` are each `floor(. * s / BPS)`, and the cut weight `Pb` is the sum of two such floors, one for the LP-reward weight and one for the pot weight.

Inside the cut leg the order of computation is: LP donation by weight, pot by weight, royalty by formula, and the protocol takes the residual. That ordering is what makes the accounting exact and underflow-free (`donation + potAdd <= kBase <= B` and `royalty <= B - kBase <= B - donation - potAdd` both hold for every input) at the cost of the protocol absorbing at most a few wei of integer residue per swap. On any non-dust trade the protocol's realised share of the cut leg is exactly `Pb / T <= s`.

The protocol, not the pot, absorbs the shared rounding dust.

## 6. Guard Window and the Founding Position

The guard window (`guardEndBlock`, `snipeTaxPips`, `maxBuyQuoteAmount`, `lockedLiquidityProvider`) interacts with the fee model in four ways:

- Base fee earned during the guard belongs to the founding position like any other LP fee.
- The snipe tax is split 80/20 like the surge (`1-s` / `s` in general). During the guard the founding position is the only liquidity, so **the creator keeps the 80%**: it accrues as the founding position's LP fee and `collectLpFees` pays it to the creator's `lpFeeRecipient`.
- `HookrNativeMechanicsCoordinatorLibV2.routeFoundingPositionFees` routes **100% of both currencies** to `lpFeeRecipient`. There is no collect-time withholding. `LpFeesCollected` always reports the gross amounts.
- `HookrNativeMechanicsBlockV2.guardLpEarnedQuote(poolId)` is an informational per-pool counter of quote-denominated LP earnings accrued *while the guard was active* (the v4 LP fee on the buy plus the LP-reward donation). It is not an input to any transfer. `HookrMarketCoordinatorV5.guardLpFeeAccounting(poolId)` returns `(module, cumulativeEarned)`.

## 7. Attribution: Events and Counters

The block emits, per accrual:

```
event ProtocolShareAccrued(bytes32 indexed poolId, uint8 indexed stream, uint256 amount);
enum ProtocolStream { Surcharge, Guard, LpReward, Pot, Burn }   // 0..4
```

and keeps `protocolShareByStream[poolId][stream]` plus the per-pool total `totalProtocolShareWei[poolId]`. `AutoBurn`, `LpRewardsDonated`, `JackpotHit`, `HookFeesAccrued` and `Claimed` report the other streams.

`Guard` carries the snipe-tax slice and only ever appears on exact-input buys inside a guard window, so guard-window and post-guard protocol revenue stay separable. Deferred (afterSwap) slices are always pure surge and are attributed to `Surcharge`.

## 8. Partial Fills

The kernel forces the canonical full-fill price limit whenever the specified leg carries a take. A pool with **only** a base LP fee has no specified-leg take at all and therefore **allows partial fills** (a non-canonical `sqrtPriceLimitX96` is accepted). A pool with a surge, guard, burn, LP-reward or pot leg has a nonzero specified-leg take on an exact-input buy, at a nonzero protocol share and, for the pot leg, only through a trusted caller, and then reverts `PartialFillUnsupportedWithInputCuts` for a non-canonical limit. Both behaviours are covered by the source repository's test suite, which this package does not ship.

## 9. Claims and Solvency

Every non-donated amount (royalty, pot, protocol) is minted to the block as backed ERC-6909 and tracked in `totalClaimLiability[quote]`, per quote currency. `claim` / `claimTo` burn the module's own balance and verify the delivered amount equals the debited amount, so a fee-on-transfer or under-delivering quote reverts the claim rather than silently short-paying. `claimBalance(quote) >= totalClaimLiability[quote]` is the per-quote solvency invariant and is asserted after every scenario in the source repository's test suite (not shipped here).

The protocol's share accrues to `claimable[quote][protocolRecipient]` where `protocolRecipient` is the block's immutable address: `HookrTreasuryForwarderV1`, whose permissionless `collect(quote)` claims and forwards to one owner-settable target.

## 10. Config Schema

The `Config` struct is 640 ABI-encoded bytes with twenty fields; `protocolRecipient` (`address`) and `protocolShareBps` (`uint24`, value at most 5,000) are the last two, in that order. The schema **string** is `HookrNativeMechanicsBlockV2.Config(...)`, listing every field in order; the catalog stores the hash the registrar supplies, and the registry re-reads it off the module when it freezes a stack, so the two cannot disagree for an open pool. Any encoder that produces bytes for a different schema fails closed at admission, because the admission library pins this literal and the config hash is re-derived on every swap.

`protocolShareBps` is basis points of each add-on, never pips of the quote leg. An encoder that treats it as a flat rate on the quote leg produces a config that prices completely differently, which is why the schema hash, not just the layout, is part of admission.

## 11. Initial Creator Buy ("Dev Buy")

- **Every quote.** ETH, HOOKR, USDG, stock tokens, any ERC-20. Neither the initial-buy library (`HookrMarketCoordinatorInitialBuyLibV4`) nor the router (`HookrKernelRouterV3`) carries a native-only gate.
- **Ordering-aware.** The input currency is the *quote*, which may be `currency1`; `zeroForOne = (quote == currency0)` and the price limit follows the direction. Native value is validated against the quote currency, and an ERC-20 quote is pulled from the creator through the router's `_settle` path: **the creator must approve the router for `quoteAmountIn` before the launch transaction**. The coordinator requires `msg.value == 0` for an ERC-20 quote.
- **5%-of-supply ceiling.** `HookrMarketCoordinatorV5.MAX_INITIAL_BUY_SUBJECT = SUPPLY * 500 / 10_000` = 5e25 (5% of the 1e27 fixed supply). It is enforced on the amount actually **delivered to the creator**, after any burn, and reverts `InitialBuyAboveCap(subjectOut, cap)`. The same rule applies to every quote. `maxInitialBuySubject()` exposes the constant so an interface can solve for the largest quote amount that lands on it.
- The buy still passes through the guard: it pays the snipe tax and respects `maxBuyQuoteAmount`.

## 12. What an Integrator Encodes

- `protocolRecipient` and then `protocolShareBps` (bps, at most 5,000) as the config's last two fields.
- The rate to encode comes from `HookrMarketCoordinatorV5.protocolShareBps(creator)`; admission rejects any other value with `ProtocolShareTierMismatch`.
- Index `ProtocolShareAccrued`; read `totalProtocolShareWei(poolId)` and `protocolShareByStream(poolId, stream)`.
- Quote the trader's cost as `base + surge + snipe` LP fee plus `lpBps + potBps` of the input plus the protocol pips leg. A waterfall that sums the configured amounts is correct; there is no separate protocol row to add.
