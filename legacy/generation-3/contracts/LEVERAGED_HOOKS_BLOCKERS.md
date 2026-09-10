# Leveraged Hooks — blocker register

`LEVERAGED_HOOKS_ARCHITECTURE.md` was reviewed by two independent adversarial passes before
any contract was written: one for Uniswap v4 feasibility against the vendored core, one for
economic soundness. **Both returned `needs-revision`.** Every item below was verified against
source, and every one of them would have been expensive to find after implementation.

Nothing in the architecture ships until the fatals are closed. This file is the gate.

---

## Fatal — v4 feasibility

### F1 · The factory cannot embed `new LeverageMarket(...)`

`LeverageFactory.create` deploys both a token and a market inline, so both creation codes land
in the factory's own runtime and it exceeds EIP-170. **The repo already hit this exact wall and
wrote it down** — see the note at `src/libraries/HookrLaunchpadLib.sol:168`, where an inline
`new HookrToken(...)` was moved into a linked library for the same reason.

*Fix.* Deploy through a linked library, as `HookrLaunchpadLib.deployToken` already does, or
CREATE2 from a minimal deployer whose only job is the `new`.

### F2 · The protected-state check deadlocks

Three constants contradict each other: `twapShortSec = 900`, `minObsSpacingSec = 45`, and
`boundedWalk(id, cfg.twapShortSec, 8)`. A pool trading at least once per 45s window writes one
observation per 45s, so covering 900s needs 20 slots. Eight steps reaches 360s and the walk
fails — on exactly the pools this product targets.

*Fix.* Size the walk to `twapShortSec / minObsSpacingSec` with headroom, or shorten the window.
Pin the relationship in a test so the three constants cannot drift apart again.

### F3 · Liquidation is arithmetically unsatisfiable during a decline

The execution floor is `seize * twapShort * (1 - maxSlippage)` while execution fills at roughly
spot. `seize` cancels from both sides, so the condition collapses to `spot/twapShort >= 0.95/(1
- impact - fee)` — independent of size. The stated remedy ("retry smaller") is false: shrinking
the seize removes only the impact term. A token down 20% over fifteen minutes cannot be
liquidated at any size, which is precisely when it must be.

*Fix.* Do not use a lagging TWAP as a price floor on an asset you are selling. Reference the
floor to a pre-trade spot snapshot taken inside the same `unlock`, and use the TWAP only as a
one-sided ceiling against upward manipulation.

### F4 · NAV marks with a one-way ratchet

Shares are minted **and** redeemed valuing market-owned tokens at `min(spot, twapShort,
twapLong)`. On a rally the mark pins to the lagging TWAP and understates NAV, so deposits mint
too many shares — and `redeemInKind` settles physically, so the mispricing is captured
immediately rather than converging.

*Fix.* Quote the two sides against different bounds: mint at `max(...)`, redeem at `min(...)`,
so the gap is a cost to both sides instead of a gift to one.

### F5 · The leverage pool has no swap route

`HookrSwapRouter._validate` reverts `InvalidPoolKey` when `key.hooks != hook` against its
constructor immutable (`src/HookrSwapRouter.sol:214`), and the design's exclusivity gate keeps
outside LPs out. So nothing can arbitrage the pool — and every risk term in the design
(`riskPrice`, `capLiquidity`, `capDepth`, the liquidation trigger, the NAV mark) is derived
from a price that is only meaningful if competitive flow keeps it honest.

The architecture dismisses this as "a UI problem, not a protocol problem." It is not. A
leverage pool nobody can trade is a leverage pool nobody can arbitrage.

*Fix.* Ship a hook-generalised router as a v1 dependency, not as follow-up work.

---

## Serious

| # | Problem | Fix |
|---|---|---|
| S1 | `surge` copied "verbatim" from `HookrHook` without its exact-input guard reverts every exact-output swap (`HookrHook.sol:403` casts `-amountSpecified`). | Carry the guard with the formula, or compute surge only for exact-input. |
| S2 | Hook and factory are mutually immutable with no setter, so the pair cannot be deployed: the hook's mined salt depends on the factory address, and the factory needs the hook address at construction. | Break the cycle — a one-shot setter on one side, or mine against a CREATE2-predicted factory address. |
| S3 | `availableWei = min(ceiling, capReserve) - totalDebt` subtracts debt twice, because `capReserve` is already net of it. Credit dies around 45% utilisation. | Subtract `totalDebt` only from the gross ceilings. |
| S4 | NAV subtracts `insuranceQuote` twice (once inside `A1`, again as liability `L3`), and invariant I7 enshrines the double-subtraction so the property test would prove the bug. | Pick one representation; restate I7 against it. |
| S5 | The spec re-invents share math this repo has already shipped and fuzz-tested, with a strictly weaker naive formula. | Call `LeverageMath.sharesForDeposit` / `quoteForShares`. **Already resolved** — see below. |
| S6 | A redemption ticket is a free, cancellable, perpetual claim on the entire liquid tier, so the dominant strategy is to enqueue everything on day one and own all future instant liquidity for a gas fee. | Make queue position cost something, expire tickets, or serve pro-rata instead of FIFO. |
| S7 | Receivable strips accrue zero interest under the stated rules, contradicting the prose and making invariant I24 unprovable. | Denominate strips in scaled debt units, exactly as positions already are. |

## Minor

- **M1** · The exit fee is computed, quoted, then handed back: burning `payNow/sharePrice`
  shares burns only the shares matching the cash paid, so the fee shares stay with the
  redeemer. Burn gross, pay net.
- **M2** · `PoolManager.donate` is permissionless, so "the only possible donor is this market"
  is false and NAV is externally movable.
- **M3** · The harness credited with proving the flag/fee/liquidity invariants mines
  `0x00CC` — not the flags the design specifies — so it proves none of them.

---

## What is already built and verified

`src/libraries/LeverageMath.sol` + `test/LeverageMath.t.sol` — **20 fuzz and directed tests
passing.** This is the arithmetic layer, written and tested before the architecture landed, and
both reviews independently pointed at it as the canonical version (S5, and v4-critique item 6).

It pins, as executable properties, the rules the published design states in prose:

- capacity is the **minimum** of its terms, and more bonded $HOOKR can never push a ceiling
  past what liquidity and liquidation depth already allow;
- rounding always favours the market — debt up, shares down;
- market equity **excludes borrower collateral**, which is the double count the whole design
  exists to rule out;
- health reaches 1 while a position is still over-collateralised, which is the room reserved
  for exit fees, incentive, impact and oracle lag;
- a first depositor cannot mint dust and donate to inflate the share price.

One real bug was found by fuzzing during that work: naive `a * b / c` overflowed on a market
whose share supply had drifted far from its equity — an arithmetic revert exactly when an LP is
trying to leave. Products now go through v4-core's `FullMath`.

---

## Order of work

1. Close F1–F5 in the architecture. F3 and F5 are design changes, not edits.
2. Re-run both adversarial passes against the revised design.
3. Stand up a real harness that mines the specified flags and proves the pool-level invariants
   before any credit code exists (M3).
4. Implement hook → market → factory, with the flow libraries linked out for size.
5. Wire the UI behind the release-manifest gate, which requires a checked-in manifest with an
   address, ordered receipts and block-pinned reads before anything renders as live.

Until step 5 has that evidence, `STATUS` in `src/lib/module-market.ts` stays `design` and the
site keeps saying nothing is deployed.
