# Guard window

The guard window is a temporary launch condition on a new-token market. It exists so the first blocks of a launch cannot be swept by one address before anyone else can transact.

It is available only on the new-token lane. Requesting it on an existing-asset market reverts `GuardRequiresLockedFoundingPosition` at admission. The reason is structural: the guard's liquidity lock only means something when the coordinator holds the only position, and on the existing-asset lane it holds none.

## What It Does While Open

The window is open while `block.number < guardEndBlock`. Four rules apply:

**Per-block buy cap.** `maxBuyQuoteAmount` bounds the total quote spent on buys in one block for this pool. A buy that would push the block's running total past it reverts `MaxBuyExceeded(attempted, max)`. The counter resets each block, and it is credited back when a buy consumes less quote than it requested.

**Snipe tax.** `snipeTaxPips` is added to the effective LP fee on buys. It is a surcharge, not a separate transfer. The creator receives 80% of it and the protocol 20% at the deployed share (`1 - s` and `s` in general), exactly like the surge surcharge.

**Exact-output buys blocked.** They revert `ExactOutputBlockedDuringGuard`. An exact-output buy would let a caller name the token amount and pay whatever it costs, which defeats a cap denominated in quote.

**Outside liquidity blocked.** `beforeAddLiquidity` reverts `ExternalLiquidityBlockedDuringGuard` for any sender other than the coordinator. Adding a wide position during the window would let someone absorb the tax they are about to pay.

## Who Receives the Snipe Tax

The founding position is the only liquidity while the window is open, so the creator's `lpFeeRecipient` receives the LP part of every guard-window fee: the base fee in full, and 80% of both the surge and the snipe tax (`1 - s` in general).

The consequence is worth stating plainly: a creator who buys their own launch through the guard gets most of the tax back. The dev-buy cap of 5% of supply is what bounds how much that is worth.

There is no collect-time withholding. `collectLpFees` routes both currencies 100% to `lpFeeRecipient`.

## Separating the Streams

The module keeps a per-pool guard-window quote counter so an interface can show guard-window earnings and post-guard earnings as separate lines even though both are paid to the same address. The counter is informational; it does not gate any transfer.

## Bounds

| Field | Bound |
| --- | --- |
| `guardEndBlock` | strictly greater than the opening block, and at most `MAX_GUARD_BLOCKS = 100,000` blocks ahead |
| `snipeTaxPips` | `baseFeePips + snipeTaxPips <= MAX_TOTAL_FEE_PIPS` (50%) |
| `maxBuyQuoteAmount` | `uint96`, in quote units; zero disables the cap |
| `lockedLiquidityProvider` | must be the coordinator when the guard is on, and zero when it is off |

When `guardEndBlock` is zero the other three fields must all be zero. The config validator rejects any other combination.

## After the Window Closes

Every guard rule stops at `guardEndBlock`. Exact-output buys work, anyone can add liquidity, the snipe tax is gone, and the buy cap stops counting. The surge fee, the cuts and the protocol share continue for the life of the pool.
