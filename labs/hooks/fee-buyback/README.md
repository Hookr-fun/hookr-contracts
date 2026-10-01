# `fee-buyback` — a fee hook that buys back a token and pays LPs

A standalone Uniswap v4 hook that charges a **quote-denominated hook fee** on top of the pool's
dynamic LP fee, and — on a permissionless crank — splits what it collected: a slice to the owner, a
slice **donated into the pool** so it accrues to in-range liquidity pro rata, and the rest swapped
into a configured **hook token** and sent to a configured sink (the burn address by default).

The prototype is here because Hookr's own fee machinery — the kernel's specified-leg quote take,
minted as ERC-6909 claims to a claim sink, with the native block's `protocolShareBps` on each
opt-in stream — is the shape a launcher-side revenue split takes inside a Hookr stack. This hook is
the standalone equivalent: it owns the pool's `hooks` address, so it can charge its own fee with a
`beforeSwap` delta and route it without a kernel.

## On a swap

| Quadrant (`zeroForOne` × exact in/out) | Hook fee | LP fee |
| --- | --- | --- |
| exact-input buy (quote in) | **yes** — `hookFeePips` of the quote input | via the override the hook sets |
| exact-output sell (quote out) | **yes** — `hookFeePips` of the quote output | same |
| exact-input sell (quote out) | no | same |
| exact-output buy (quote in) | no | same |

`beforeSwap` returns a positive **specified-currency delta** in the quote, which the PoolManager
takes from the swap's specified leg and credits to the hook; `afterSwap` takes that credit into the
hook's own balance. The two quadrants that carry a fee are exactly the quadrants a Hookr
specified-leg quote take covers (`isBuy == exactInput`); `verification/FeeSplit.lean` proves that
predicate is the same as "the quote is the specified currency", and the hook charges on the raw
fields, not on the semantic one.

`beforeSwap` also returns the LP-fee override (`lpFeePips | OVERRIDE_FEE_FLAG`) for every swap, so
the pool's fee is the configured one and not a cached value.

## What it takes, from whom, and where it goes

**From whom:** the trader, in the pool's quote currency, **on top of** the pool's LP fee. The hook
never touches the LP fee, and it never holds subject tokens.

**Where it goes**, per crank (defaults; all weights are configurable, subject to the ceilings):

| Leg | Default | Mechanism |
| --- | --- | --- |
| owner | 10% of the hook fee | `quote.transfer(ownerFeeRecipient, …)`; `ownerBps ≤ 1_000` is enforced by `HookFeeSplit` |
| LPs | 10% of the hook fee | `PoolManager.donate`, which credits every unit of in-range liquidity pro rata — no position register, no custody, no staking |
| buyback | 80%, plus the integer dust | exact-input `swap` on the configured `buybackKey` (quote → `hookToken`), output sent to `buybackSink` |

The split is conservative by construction: `buybackBps` takes the remainder, so the three legs sum
to exactly the collected amount and nothing is stranded in the hook (`split_conservation` in the
Lean file, replayed through the contract by `test/FeeSplitParity.t.sol`).

The buyback's floor is `slippageFloor(spotOut, maxSlippageBps)` where `spotOut` is the buyback
pool's pre-swap spot price converted raw-to-raw. A crank's `minHookOut` argument can only *raise*
that floor, never lower it; the realised output is checked after the swap, so a crank that cannot
meet the floor reverts and the fee stays put.

`crank(uint256 minHookOut)` is permissionless: the split is fixed by the config, the floor cannot be
sandbagged, and the owner cannot slow-walk a distribution (only the fee's *parameters* are
owner-gated, and those are timelocked).

## Owner powers, and their limits

- The parameter set is **proposed** by the owner and takes effect only after `configDelay`
  (≥ 1 day) — the hook token, the buyback venue, the recipient, the weights, the fee rate, the
  slippage allowance and the pause flag.
- Hard ceilings, in the library, not the docs: owner share ≤ 10% of the hook fee, hook fee ≤ 10% of
  the swap's specified amount, slippage allowance ≤ 20%, weights must sum to 10,000 bps.
- `paused` stops the hook fee but never blocks a swap.
- The owner cannot take the pool's LP fee, cannot move tokens out of the hook except through the
  split, and cannot change `owner`, `configDelay` or the pool binding — those are immutable.

## Build

From the repository root:

```sh
forge test --root labs --match-path "hooks/fee-buyback/*"
```

The Lean model is separate from Foundry and needs no Mathlib:

```sh
lean verification/FeeSplit.lean          # type-checks the model and every proof
lean --run verification/FeeSplit.lean    # regenerates test/FeeSplitParityCases.sol
forge fmt --root labs hooks/fee-buyback/test/FeeSplitParityCases.sol
```

`HookFeeSplit` is pure, so the model and the contract are compared case by case: 416 generated rows
of `(amount, weights, fee rate, spot, slippage)` with the model's owner/LP/buyback/fee/floor
outputs, replayed through the contract by `test/FeeSplitParity.t.sol`. The theorems in
`FeeSplit.lean` prove what the contract's comments claim — conservation of the split, the owner and
fee ceilings, the int128 fit of the fee, the slippage floor never exceeding the spot estimate and
being antitone in the allowance, and the quadrant equivalence — over the same functions the parity
test executes.

## What the tests do not show

- **No fork test, no live pool.** Everything runs against a `PoolManager` deployed from
  `lib/v4-core` with two mock ERC-20s. The hook has never been the `hooks` address of a real pool.
- **The LP leg rewards in-range liquidity at crank time.** `donate` credits whoever is in range when
  the crank lands, so a position opened just before a large crank captures a share of the donation.
  Nothing in the contract prevents that; the mitigation is frequent, small cranks
  (`minCrankQuote`), not a stronger mechanism.
- **The buyback floor is a spot estimate, not a TWAP.** Within `maxSlippageBps` the buyback can be
  executed against a manipulated price, and the floor does not model price impact or the venue's
  own fee. A production version wants a time-weighted reference.
- **No accounting for tokens that are not plain ERC-20s.** Fee-on-transfer, rebasing, or
  transfer-restricted quote/hook tokens break either the crank or its arithmetic; the hook pays for
  the buyback with an exact `transfer` and reverts if it fails. Native-currency quotes are handled
  by v4's `Currency.transfer` but are untested here.
- **`donate` needs in-range liquidity.** A pool whose price sits outside every position cannot
  receive the LP leg, so the crank reverts until it can. Nothing is lost — the fee stays in the hook,
  and the whole crank is atomic — but the distribution stalls.
- **No composition with a Hookr kernel.** A pool's `hooks` field points at one contract, so a pool
  protected by `MevOracleDeviationBlockV1` (whose fee lever is the kernel's) cannot also use this
  hook. The two are alternatives at the venue level, not layers. The equivalent inside a Hookr stack
  is a read-only module returning `quoteTakeBps` with a claim sink as `claimRecipient` — the same
  quadrants, the kernel's own claim accounting, and a `HookrTreasuryForwarderV1`-style splitter
  instead of this hook's self-custody.
- **The split's economic premise.** "90% of the fee" here means 90% of the *hook fee* — the owner
  takes 10% of it and the rest funds the buyback and the LP leg — not 90% of the pool's LP fee: the
  LP fee is never diverted. The trader's cost is therefore the pool's LP fee **plus** the hook fee.

## Layout

| Path | What it is |
| --- | --- |
| `src/FeeBuybackHook.sol` | the hook: fee delta, crank, timelocked config |
| `src/HookFeeSplit.sol` | the pure arithmetic the Lean model mirrors |
| `test/FeeBuybackHook.t.sol` | 15 tests over a real PoolManager, swaps, donation and buyback |
| `test/FeeSplitParity.t.sol` | replays the generated fixture through `HookFeeSplit` |
| `test/FeeSplitParityCases.sol` | generated by `verification/FeeSplit.lean` |
| `verification/FeeSplit.lean` | the model and its proofs (Std only) |
