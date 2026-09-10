# Leveraged Hooks — source audit record

Seven adversarial passes over `contracts/src/Leverage*.sol`, on branch
`nodes/leveraged-hooks-impl`. This file exists so the next reviewer starts from what is
already known rather than rediscovering it — including the things that were reported,
investigated, and turned out **not** to be defects.

**Status: not deployable, but converging.** All five of the original criticals now have a
fix and a passing regression: the oracle, per-position marking, per-block liquidation stacking
(on its second attempt — the first was tried and broken by an adversary), the deployment-fatal
`setFactory` gate, and the redemption sandwich (on its fourth attempt — the previous three are
recorded in Rejected below, and this one's own residual is documented rather than hidden: the
short-window gate can stay engaged longer than its nominal 90s during genuine market silence,
a liveness cost, not a security regression). The reserve/NAV-zero path is mitigated rather
than proven — no regression exists for it, and that gap is stated plainly in its own section.
The open list below is not a backlog of polish; items with no regression test are marked as
such, and the one documented residual on the sandwich fix should be read before treating this
as closed.

---

## How to audit this system

What worked and what did not, measured across every pass so far:

**Invariant tests found nothing.** Eight invariants at 128,000 calls each ran green while
four separate criticals were live. Worse, the suite was not reaching the code: over 500
sequenced calls it landed **one** successful open, **zero** liquidations and **zero**
closes, because `setUp` never warmed the observation ring and `isProtected` refused almost
every action. Every handler action is wrapped in `try/catch`, so Foundry reported
`reverts: 0` and the run looked healthy. Fixed in `973d38e` — the ring is warmed, the book
is seeded with lendable cash, `warp` re-warms, and `afterInvariant` now fails a starved run.

The structural invariants (sums match, index monotonic) are correctly written but were
never the right tool here: **every critical found in this system was a valuation or
reachability bug**, where the ledger agreed with itself perfectly while describing a market
that did not exist.

**Finder consensus is not evidence.** Four independent finders reported
`LeverageFactory.pendingToken` as a security hole. It is genuinely never assigned — and it
is the left operand of `&&` inside a revert condition, so a dead-true term makes the guard
*stricter*, never looser. Only the verify phase caught that.

**Only reproduction counts.** In the fourth pass, 45 findings became 19 confirmed and 4
refuted once every claim had to carry a running PoC. In the fifth, three of three proposed
fixes were broken by their own adversaries. Any finding in this system should be treated as
a hypothesis until a test exhibits it.

### Traps that have each cost hours

- **`vm.warp(block.timestamp + dt)` inside a loop does not advance.** Under `via_ir` the
  optimiser hoists `block.timestamp`, so every iteration warps to the same instant. This has
  produced a false "REFUTED" three separate times. Track the clock in an explicit variable
  and warp to absolute values.
- **A hook cannot observe its own swaps.** `Hooks.beforeSwap`/`afterSwap` both begin
  `if (msg.sender == address(self)) return`.
- **v4 passes the immediate caller of `poolManager` as `sender`**, so a shared router can
  never satisfy an exclusivity gate.
- **`PoolManager.sync` is permissionless and its transient slot is never cleared.** Every
  settle site must re-sync immediately before settling. (Checked and clean — see Refuted.)
- **`Hooks.isValidHookAddress` short-circuits flag validation for dynamic-fee pools**, which
  is why `LeverageHook`'s constructor asserts the mined flags itself.
- **EIP-170 binds on the library, not the factory.** `LeverageDeployLib` is 24,096 / 24,576 (480 bytes of margin)
  and embeds BOTH `HookrToken`'s creation code (3,779 B) and `LeverageMarket`'s (19,099 B), so
  a few hundred bytes of growth in the market bricks deployment of the *library*. Note the
  margin is self-inflicted: splitting the library frees ~4,194 B, which the marking design
  established is a prerequisite for any substantial change to `LeverageMarket`.

---

## Findings, individually

Three of the six major findings — the oracle, per-position marking, and the deployment-fatal
`setFactory` gate — were fixed early enough in this file's history that they were written up
directly under `## Fixed` below and never appear as a numbered item here. What remains in
THIS section is the other three, tracked individually because their status differs from each
other: read each heading, they are not all the same word. Every item has a reproduction; none
is speculative. Two are labelled FIXED with a regression that fails without the change; one is
PARTIALLY ADDRESSED with no regression at all (said plainly, not implied). Item 4 is a bucket
of lower-severity findings still genuinely open, not a fourth major finding. This section is
not titled "Fixed" because item 1 is not, and folding a mitigated-not-proven finding under a
"Fixed" heading is exactly the kind of overclaim this file exists to prevent.

### 1. Reserve grows on unpayable paper interest — PARTIALLY ADDRESSED, UNCOVERED

The reserve is booked on index growth rather than realised cash. After 6× 365-day accruals at
92.86% utilisation, `reserveQuote` = **407.76 ETH** against the market's entire quote-side
assets of **52.70 ETH**. `navQuote` floors at 0 and `redeem()` reverts `InsufficientLiquidity`.

While NAV is 0, `sharesForDeposit` divides by `(equity + 1)` = 1 wei. A permissionless 1 ETH
deposit mints **1.013e21 shares** against an honest LP's 13. Liquidating the stuck position
then releases the reserve, NAV returns to 102.7 ETH, and the honest LP's redemption pays
**1 wei instead of 1.318 ETH** while the 1 ETH depositor's shares are worth 103.7 ETH.

Note the originally reported cause — "the reserve has no release path" — is **wrong**;
`_bookShortfall` drains it correctly. Fixing the reported cause would have done nothing.

**What was done:** `accrue` caps `reserveQuote` at half the cash behind it — cover the market
cannot pay is not cover — and `deposit` refuses while `navQuote(true)` is zero, closing the
inflation window however NAV got there. Both are conservative: the cap only reduces a
liability, the guard only refuses.

**Neither has a regression, and that is the honest status.** Reproducing the finding needs a
book held near the 90% ceiling while interest compounds against a fixed idle balance; every
attempt in this harness either had its opens refused on capacity or settled at ~11%
utilisation, where the reserve accrues 0.03 ETH. A first attempt that clamped to the FULL
balance passed its own test while leaving NAV so small that a real redemption rounded to zero
— the same freeze wearing a different number, caught only because the test drove an actual
redemption rather than asserting on NAV. Treat this as mitigated-not-fixed.

### 2. The redemption unwind is sandwichable — FIXED, one residual documented below

`_execUnwind` sells the removed token leg back into the same pool. A sandwicher takes
**+33.63 ETH** while the redeeming LP loses **45.2 ETH** on a 100 ETH deposit. The effects
compound: a depressed spot shrinks `positionReserves().quoteSide`, so `_unwindForRedemption`
removes a *larger* slice and enlarges the victim trade.

Three direct fixes were tried before this one and all three failed — see Rejected below,
including the two that reused the 900s average as the reference and one (`MAX_UNWIND_DISCOUNT_BPS`)
that gated on it and turned into a cheap DoS. The 900s mean is too slow a reference on its
own: a push that only walks spot down through headroom it already had above the average still
paid, measured at +2.74 tokens with spot 30.27% above the mean.

**The landed fix reads a SECOND, much shorter window from the same ring** — no new
accumulator, no new storage beyond the ring already there. `LeverageOracleLib.meanTick` was
generalised to `meanTickOver(ring, now, tick, windowSec, maxWalk)`, and
`LeverageHook.isRecentlyDislocated(id)` reads it over `RECENT_WINDOW_SEC = 90` with a tight,
one-sided `RECENT_DEVIATION_BPS = 150` band (spot below only — the direction a sandwich
needs). `_unwindForRedemption` declines (returns, does not revert) when this is true, and
`redeem()` distinguishes the resulting "nothing payable" state with a NEW error,
`PriceProtected()`, from the ordinary `InsufficientLiquidity()` — so a caller can tell a
transient refusal from a hard one.

Four regressions in `contracts/test/LeverageExploits.t.sol`, each verified to fail with the
gate stubbed to always return false: a push that stays inside the 900s 500 bps band still
trips the 90s gate (closing exactly the gap the three prior attempts left open); the unwind's
own liquidity is provably untouched across a redemption attempted right after a push;
`PriceProtected()` fires distinctly from `InsufficientLiquidity()` when idle is exhausted and
the gate is the specific cause; and the gate clears — and a previously-blocked redemption
settles — once genuine, properly-spaced trading (not the attacker's) brings spot back near the
pool's own recent history.

**Residual, found and documented rather than hidden.** Empirical calibration (not just
reasoning) surfaced that the 90s window's `covered` semantics are borrowed from the 900s
window's, where "an observation older than the window is the strongest possible history" is
correct. For the SHORT window that is backwards: if the market goes quiet immediately after a
push (no further trades from anyone, not even organically), the walk cannot find an
observation near the true 90s boundary, falls back to whatever slot it *does* have, and ends
up averaging over a much wider span than 90s — so the gate can stay engaged far longer than
its nominal window during genuine silence. Measured: with no further trading, the gate was
still engaged after 400+ simulated seconds. This is NOT a security regression — the gate never
incorrectly clears while genuinely dislocated, and it degrades toward being over-conservative,
the safe direction — but it means "clears within ~90s" is not a guarantee; the honest property
is "clears within one swap of genuine trading resuming, however long that takes to happen."
Treat this as a liveness caveat on the fix, not as ground for reopening the security finding.

**`MarketConfig.minPoolQuoteWei`** (see `DEPTH FLOOR` below) does not fix the mechanism but
shrinks the ratio the whole attack scales on. The +33.63 ETH figure was measured on a ~50 ETH
pool; a market configured with a depth floor near or above that keeps the exploitable
shortfall-to-depth ratio small for as long as the floor holds, which is enforced continuously
on new borrowing rather than as a one-time unlock.

### 3. Liquidations stack within a block — FIXED

Three `liquidate()` calls in one block seized 11.509 tokens = **296% of the single-call cap**;
spot fell 2004 bps against a 500 bps per-call floor, and execution realised a 1085 bps
shortfall against the block-opening mark. `_seizeCap` read live `positionReserves()`, and each
seize sells into the pool, so the cap *grew* with every call while `_execSell` re-snapshotted
pre-trade spot inside each unlock. A per-block anchor was tried once before and broken — see
Rejected for the FIRST attempt, which set the anchor's price on every call it happened to
consider "better," letting a keeper renew the budget by restoring the pool between seizes.

The landed fix anchors THREE things once per block, on the first liquidation sell touched, and
never updates any of them again until `block.number` changes — including when a later call's
own numbers would look more favourable: the reference price (`liqAnchorPriceWad`), the token
side the budget is computed from (`liqAnchorTokenSide`, fixed rather than the live, growing
value), and the cumulative amount already sold this block (`liqBlockTokensSold`, subtracted
from the fixed budget rather than reset per call). All three state variables are market-level,
not per-position, so the ceiling bounds the whole block's aggregate regardless of how many
distinct positions are liquidated.

Regression: `test_restoringThePoolBetweenSeizesDoesNotRenewTheBudget`
(`contracts/test/LeverageExploits.t.sol`) drives five positions through `liquidate()` in one
block, buying the pool back up between every call — the exact move that broke the first
attempt. Fixed: `totalSeizedThisBlock` lands EXACTLY at `blockBudget` (to the wei), with the
trailing calls correctly refused `InsufficientLiquidity()`, and a roll to the next block
confirms the budget resets. Verified to fail without the fix: reverting `_seizeCap`/`_execSell`
to the pre-fix per-call version overshoots the same budget by ~7% under an identical scenario
(the original 296% figure was measured on a different setup; the mechanism is the same).

Governed by the same depth ratio as (2): a deeper pool means `_seizeCap` (tokenSide/25) sells
into more liquidity per call, shrinking the per-call and per-block shortfall alike. The depth
floor is complementary to this fix, not a substitute for it.

### DEPTH FLOOR — `MarketConfig.minPoolQuoteWei`

Added on the user's suggestion: gate leverage behind a minimum pool depth, since nearly every
attack above scales with one ratio — the size of the trade the market is forced to make
against the depth available to absorb it (the sandwich, the unwind's execution boundary at
f = 4.7%, and `_seizeCap`'s inversion are all governed by it). This does not patch any of those
paths; it shrinks the regime they live in.

Checked live against `positionReserves()` on every `openPosition`, not as a one-time unlock —
crossing the floor, opening positions, then withdrawing liquidity would put the book back in
the thin regime with leverage already outstanding. `closePosition`, `repay` and `liquidate`
stay open below the floor; only new borrowing is gated. Two regressions: refused below the
floor, permitted above it, same market, only the floor changed.

**Scope, stated plainly:** this is a deployment-time choice a market creator must opt into by
setting `minPoolQuoteWei > 0`. It does nothing for a market created with it at zero, and it
does not fix any of the mechanisms above — it only bounds how much they can extract while the
floor holds. It is not a substitute for closing the sandwich or the per-block liquidation
stacking; it is complementary risk reduction, most valuable on newly launched markets where the
pool starts thin by construction.

### 4. Lower severity, confirmed

- **Share quantum**: `VIRTUAL_SHARES = 1e3` is an absolute count, not a WAD-scaled offset, so
  the share unit is ≈0.1 ETH. Hard minimum deposit; every deposit forfeits its remainder —
  34% measured on a 0.1538 ETH deposit. `sharePriceWad()` returns ~1.15e36 rather than a WAD
  and is in the exported ABI surface.
- **Founding liquidity mints no shares** and is owned by nobody, permanently; the void also
  takes `1e3/(S+1e3)` of all future yield. *(Product decision: creator refund vs. permanent
  protocol-owned floor.)*
- **Utilisation ceiling measured pre-borrow** — lands at 92.86% against a 90% cap; only bites
  the next caller.
- **Self-liquidation** pays the borrower the 5% bonus and retires 5% less debt. NAV is
  bit-identical either way, so the reported "extra LP loss" mechanism is wrong; the leak is
  the borrower's own menu. Preferred fix is to zero the bonus, not revert.
- **`_seizeCap` loosens exactly when it should bind.** It is a twenty-fifth of the pool's
  *token* side — but a decline is caused by tokens being sold *into* the pool, so the crash
  that makes a position liquidatable also inflates the quantity the cap is a fraction of.
  Observed while repairing `test_aPartialSeizeDoesNotConfiscateTheExcess`: a position with
  5.09 tokens of collateral was seized in **full**, because the dump had pushed the token side
  past 127 tokens. The partial-seize path is therefore not reachable in any fixture that gets
  underwater by dumping, which means the residual-credit logic is untested and the "bounded
  seize" property does not hold in the scenario it was designed for. A cap denominated in the
  *quote* side, or in the position's own size, would not have this inversion.
- **`seedLiquidity` positive deltas** are left unsettled by `_execSeed`.
- **`donate` is ungated** into a pool the design describes as closed (a gift, not a theft, but
  `navQuote` cannot see it, so it surfaces as an unexplained NAV jump on the next unwind).
- **Surge-fee exemption is granted to every market swap**, not only liquidations: measured
  outsider 6000 pips vs market path 3000 pips.
- **~17 tests assert nothing about what they are named for** — see Test suite health.

---

## Fixed

`973d38e` — `_execUnwind` slippage floor (later removed, see below); `claimable` reserved out
of `idleQuote()` via `totalClaimable` plus a borrow bounded by owned cash; `seedLiquidity`
made genuinely one-shot; router residue no longer spendable via `settle{value:}`;
`openPosition` refuses to merge into an existing position; `formatWad` round-up carry;
`previewDeposit` VIRTUAL_SHARES; `previewRedeem` modelling the unwind; invariant suite
coverage starvation.

`9558df4` — removed the `_execUnwind` floor. It was blind to the sandwich by construction
(snapshot and swap sit inside one `unlock`, so the reference was the already-pushed price) and
it capped honest exits at `f ≤ 4.7%` — closed form `1 − 0.95/0.997 = 471 bps`, measured
independently at 472/475, 475/480 and 463/478 bps. `_seizeCap`'s 4% sat just under the same
bound, which is why liquidation cleared it and redemption did not.

`DEPLOYMENT` — the hook takes its admin as an explicit constructor argument, mined into the
salt, instead of inferring it from `msg.sender`. `contracts/script/DeployLeverage.s.sol` is the
deploy path that never existed, and `test/LeverageDeployShape.t.sol` deploys through a
third-party CREATE2 deployer rather than from the test contract — the shape that hid this for
five passes. Both new tests fail against the old constructor with `NotFactory()`.

`MARKING` — the book is marked per position. `_recoverableDebt` now sums
`min(debt_i, thr·p·collateral_i)` over a two-level bitmap of buckets keyed by index-normalised
liquidation price, so collateral securing nothing no longer lifts the mark on other
receivables. `openPosition` refuses a zero borrow, closing the free zero-debt entry. The
deploy library was split (`LeverageMarketDeployLib` 21,700 B, 2,876 B margin) — the size wall
earlier passes argued against was self-inflicted.

Both `navQuote(true)` and `navQuote(false)` read the per-position mark. The original fix kept
the aggregate on the deposit side, arguing an upper bound stops a depositor buying a cheapened
book; an adversary showed that leaves the injection primitive alive with the depositor as its
victim. **The deposit-side property has no discriminating regression** — three attempts passed
against both formulas — so that half is reasoned rather than measured. See the note in
`LeverageMarking.t.sol`.

`ORACLE` — the observation accumulator. `write` now credits every swap's interval to the tick
that actually stood over it and only the ring SLOT stays rate-limited; `meanTick` extrapolates
the trailing stub with the live slot0 tick rather than the stored head. Both halves are
required. An adversary rebuilt the capture from first principles against a matched control and
measured **capture = −45 bps** — the average moved *away* from the attacker — and confirmed a
same-block push-and-restore leaves the reference bit-identical. This unblocks everything that
needs a reference an attacker cannot set in-transaction.

Known behaviour change, stated rather than discovered later: the `covered` widening means a
pool that has NEVER traded is unprotected after 900s and accepts `deposit` and `openPosition`.
Benign in isolation (with no trades the average equals the initialize price) but wider than a
liveness fix.

Earlier passes fixed: the oracle recording the post-swap tick, NAV inflated by convexity, LP
shares denominated against a position with no withdrawal path, and liquidation seizing 100%
while the unwind floor then refused it.

---

## Rejected fixes — do not retry these as-is

- **Per-block liquidation anchor, FIRST attempt.** The budget was *renewable inside the
  block*: the anchor re-set its price whenever a later call's own number looked "better,"
  so restoring the pool between seizes made the anchor stop binding, degrading to the old
  per-call check. Renewing was profitable. A SECOND attempt, which never updates the anchor
  once set for a block and freezes the token-side baseline alongside it, is landed — see
  finding 3 above.
- **Aggregate ceiling on booked reserve.** Reintroduced the exact `min(SUM,SUM)` error it was
  meant to fix; one over-collateralised position lifts the ceiling for the whole book.
- **`isProtected` gate on the unwind.** A quiet push inside the 500 bps deviation band still
  pays, and gating the unwind *enlarges* the attacker's payoff, because the sale then proceeds
  instead of reverting.
- **Proceeds floor against pre-trade spot in `_execUnwind`.** See `9558df4`.
- **`MAX_UNWIND_DISCOUNT_BPS` gate on `_unwindForRedemption`, referenced to the 900s average.**
  Built on top of the fixed oracle and still broken. Its refusal `return`s before any unwind,
  so with idle exhausted `serviceableWithdrawal` yields 0 and `redeem` hits
  `revert InsufficientLiquidity()` — an ablation replacing the single guard line with a no-op
  made both LPs settle. Worse, it composes into a cheap repeatable DoS: an attacker paying
  ~0.026 ETH in fees blocked **39.76 ETH** of LP redemptions with the average bit-identical
  before and after. SUPERSEDED, not merely rejected: the landed fix (finding 2 above) is this
  same shape of gate — decline, don't revert the unwind — but referenced to a 90s window
  instead of the 900s one, which is what closes the quiet-push gap this attempt left open, and
  paired with a distinct `PriceProtected()` error so the DoS shape is at least legible rather
  than indistinguishable from a hard failure.
- **Per-position marking wired to the exit side only.** `navQuote(true)` — the mark every
  DEPOSIT is priced at — kept the old aggregate formula, on the reasoning that a higher NAV
  mints fewer shares. That treats the depositor as the adversary; the depositor is the victim,
  buying at the inflated aggregate and leaving at the honest per-position mark. It changed
  victims, not existence.

## Refuted — investigated, not defects

Recorded so they are not re-reported.

- **`pendingToken` is never assigned.** True, and harmless: a dead-true term on the left of
  `&&` in a revert condition makes the guard stricter. Delete it for tidiness only.
- **ERC-20 transfer return values are unchecked on five call sites.** True as a code-pattern
  observation, not exploitable given what those five sites actually touch. Four are in
  `LeverageMarket.sol` (`seedLiquidity`'s dust sweep, `_execSell`, `_execSeed`, `_execUnwind`)
  and move `token`, which is `immutable` and set exactly once from `LeverageDeployLib`'s
  `new HookrToken(...)` — never an externally supplied address. `HookrToken._transfer`
  unconditionally `return`s `true`; a failure is Solidity's own checked-arithmetic underflow
  on `balanceOf[from] -= value`, which **reverts**, never returns `false`. There is no path by
  which any of these four calls could silently fail. The fifth, `LeverageRouter.sol`'s
  `transferFrom` on the swap's input currency, DOES handle an arbitrary caller-supplied token
  — the router is deliberately not hook-pinned — so this one is not provably safe the same
  way. It is still not a theft path: v4's own delta accounting requires every currency's
  transient balance to net to zero before `unlock` returns, so a token that silently returns
  `false` instead of transferring leaves the input currency's delta unsettled and the whole
  transaction reverts (as `CurrencyNotSettled` or similar) — confusingly, but not silently.
  Worth a `require()` if the router is ever pointed at a genuinely non-standard token in
  practice; not worth spending EIP-170 margin on today.
- **Share-inflation donation attack.** Donations do raise NAV (`idleQuote()` is the raw
  balance), but the attack is self-destructive: measured attacker outlay 1000.10 ETH,
  recovered 1.10 ETH, **net −999.00 ETH**. The 1-wei opener is impossible because the share
  unit is already ~0.1 ETH. It is a griefing lever priced ~1000:1 against the attacker.
- **NAV manipulation by the marker.** The hybrid TWAP/spot mark *is* an accounting defect
  (mark exceeds realisable by `L(√T−√S)²/√T` when spot is below the average), but the
  manipulator cannot take it: crashing spot marks their own LP share down by strictly more
  than they can carry out, monotonically worse the harder they push (−0.33, −8.47, −11.55,
  −14.24, −17.69 ETH). The *early-redeemer* half is real and free, and needs the oracle fix.
- **`redeem` defeats `serviceableWithdrawal`.** Structurally true (a literal `0` is passed for
  reserved), but no loss: NAV fell 8.371 ETH while 11.924 ETH was paid out, and the *second*
  mover was paid more. Hardening only.
- **Reentrancy across the unlock boundary.** Attempted from `receive()` inside the router's
  unlock: nested `router.swap` → `AlreadyUnlocked`; direct `unlockCallback` → `NotPoolManager`;
  `modifyLiquidity` on the leverage pool → `LiquidityIsExclusive`.
- **`sync` transient-slot griefing.** A stray `sync` planted before `deposit`, `openPosition`,
  `closePosition`, `router.swap`, `createMarket` and `redeem` — all succeed. Every settle site
  re-syncs immediately before settling with no untrusted call in between.
- **Outside LP into a leverage pool.** Both add and remove refused; `salt` is always zero so
  there is exactly one position.
- **Hook flag mismatch**, `unlockCallback` spoofing, router deadline/slippage/griefing.
- **`_availableCreditExcluding` subtracting from the minimum.** Real, but proven by fuzz that
  `min(L,D,B,P) − v ≤ min(L−v,D,B,P)` unconditionally: it can only *refuse* credit it has,
  never write credit it does not. Availability defect, not solvency.

---

## Test suite health

An audit of all 61 tests found **five of five** tests in the section headed `// ---- the audit
fixes` asserted nothing about the fix they were named for, plus at least a dozen more
elsewhere. Most have since been repaired, each verified to fail without the fix it guards and
pass with it — not a fixed count, because this file has itself gone out of sync with the
repair count before (a batch of three fixes landed in `1a7f7a7` and was never added to the
running tally here, which is exactly the kind of drift a document like this accumulates if the
number is trusted instead of the "Still weak" list below it). Most recently,
`test_exitFeeCannotBeZeroedByAFlashDeposit`'s original attack shape left the flash-deposited
capital sitting in the market rather than withdrawing it back out, so it measured a
genuinely-lower-utilisation market (correctly zero-fee) rather than the round-trip the bug
name describes. Trust the list below over any running total.

**Still weak, not yet repaired:**

- `test_liquidationRefusesRatherThanSeizingIntoNoDepth` asserts `tokenSide > 0` on a market the
  guard does not apply to — the negation of the property. Reaching `tokenSide == 0` needs the
  price at the range edge, which no fixture here produces.
- `test_anAccruedReserveCannotLockEveryRedemption` never approaches the state it names —
  reserve 0.0125 ETH against ~50 ETH idle.
- `test_ringRateLimitsWithinASingleBlock` (`LeverageHook.t.sol`) passes because the pool is
  *already* stale before the loop runs, not because the rate limiter worked.

Recurring shapes to grep for:

- tests that return before reaching the call they exist to test (`if (health > WAD) return;`)
- `assertGe(<uint256>, 0)` — unfalsifiable
- assertions comparing a local to itself, or `assertEq(f(x), f(x))`
- tolerances wider than the bug (`assertApproxEqRel(…, 0.05e18)` on a defect worth 2.3%)
- `assertGe` where only `assertGt` discriminates the named regression
- bare `vm.expectRevert()` passing on the wrong reason
- setups that silently fail, so "the attack did not work" is unearned

When adding a regression here, prove it fails without the fix and passes with it, and say so
in the commit. A test that passes either way is worse than no test.
