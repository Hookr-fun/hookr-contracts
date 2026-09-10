# Hook finance frontiers: 16 mechanisms for credit and leverage

Status: **mechanism research, not an implementation or a promise to deploy.** Prepared
2026-08-15. Each design still needs a complete specification, simulations, invariant
tests, an adversarial review, and independent audit. “Novel” here means a mechanism-level
combination that is not already implemented in this repository; it is not a claim that no
one has ever proposed something similar.

The point of v4 hooks is not to hide a conventional lending protocol behind `beforeSwap`.
The interesting frontier is making the pool itself an underwriting sensor, execution
venue, liquidation path, and source of programmable cash flow. The proposals below push
on that frontier while respecting what v4 can actually do.

## Hard constraints before the fun starts

1. **A hook is fixed when a pool is created.** The hook address is in `PoolKey`; these
   mechanisms create a new pool rather than attaching to a live one.
2. **Every PoolManager unlock must settle.** Long-lived debt cannot be an unsettled v4
   delta. A separate market/vault owns the debt ledger and custody; the hook observes and
   enforces pool-local rules. ERC-6909 claims can represent settled PoolManager custody,
   not an everlasting negative balance.
3. **Do not nest unlocks.** A hook executes inside the caller's PoolManager action. It
   should return deltas or update its own state, not begin another unlock.
4. **Hook data is a hint, not identity.** Routers choose it. Authorization uses the real
   callback `sender`, signatures, or state established by a trusted market contract.
5. **Hook-returned deltas are real liabilities.** They require the appropriate permission
   bits in the mined hook address, strict signed-math limits, partial-fill handling, and
   explicit settlement. Dynamic-fee overrides likewise require a dynamic-fee pool.
6. **A spot price is not an oracle.** Any design below mentioning price means a bounded
   observation ring, minimum history, manipulation-cost/depth checks, and a protected mode.
7. **Liquidation depth must be committed depth.** If credit capacity counts arbitrary LP
   liquidity, an LP can inflate capacity and withdraw before stress. Count only locked,
   slashable, or market-owned liquidity.
8. **Tokens are adversarial.** Fee-on-transfer, rebasing, callback, pausable, blocklist,
   and malformed-return tokens can invalidate accounting. Admission must be explicit.

The existing split in this repository—stateless `LeverageHook` plus a per-pool
`LeverageMarket` that owns value and debt—is the safe default shape for these experiments.

## Design matrix

| # | Mechanism | Primitive | Capital source | Primary edge | Main failure mode |
|---:|---|---|---|---|---|
| 1 | Swap-stream margin | Per-swap deltas | Trader escrow | Position grows through ordinary flow | toxic partial fills |
| 2 | Liquidity-as-collateral credit | Liquidity callbacks | LP position | In-place LP collateral | range/value manipulation |
| 3 | Exit-queue senior credit | Withdrawal gate | LP vault | Maturity transformation | bank-run reflexivity |
| 4 | Order-flow liquidations | `beforeSwap` routing | Incoming swaps | Liquidate without auctions | book ordering grief |
| 5 | Volatility-contingent leverage | Oracle + fee override | Lending vault | Countercyclical LTV/rates | oracle manipulation |
| 6 | Loss-first fee bonds | Fee diversion | Future LP fees | Underwrite with future cash flow | fee-collapse insolvency |
| 7 | Cross-pool collateral mesh | Hook attestations | Multi-vault | Portfolio margin | correlated contagion |
| 8 | Perpetual funding AMM | Dynamic fees/deltas | Long/short margin | Funding settles in trades | one-sided flow |
| 9 | Impact-minted options | Swap-impact meter | Option buyers/LP premium | Converts impact into convex cover | jump/oracle mismatch |
| 10 | Just-in-time flash refinance | Atomic unlock | Destination lender | Liquidation-free migration | callback/reentry risk |
| 11 | Intent-backed credit lines | Signed swap intents | Solvers | Borrow only when sale exists | solver censorship |
| 12 | Time-sliced liquidation lanes | Dynamic tolls | Liquidators | Dutch execution in the pool | latency games |
| 13 | Range-maturity term loans | Tick ranges | Fixed-term lenders | Yield curve encoded as liquidity | maturity cliffs |
| 14 | Inventory-repo borrowing | Directional flow | Market makers | Finance useful inventory | adverse selection |
| 15 | Debt that becomes liquidity | Conversion trigger | Lenders | Bad debt recapitalizes pool | governance capture |
| 16 | Cross-pool basis perps | Synchronized observations | Margin vault | Trade fragmented-market basis | asynchronous oracle state |

## 1. Swap-stream margin (continuous leverage)

**Idea.** Instead of “borrow, then swap” as one large transaction, a trader escrows margin
and authorizes a schedule: acquire at most `x` collateral on each eligible sell into the
pool until target leverage is reached. `beforeSwap` recognizes only the trusted stream
executor and returns a bounded delta that co-funds that slice; `afterSwap` records actual
execution and advances debt only by settled output.

This turns organic opposing flow into a time-weighted leverage engine. The trader avoids a
large initial price impact; the pool earns fees on every slice; lenders cap their exposure
to observed executable depth rather than a hypothetical liquidation quote.

**Why a hook matters.** A keeper cannot atomically intercept all pool flow or apply the
same per-swap capacity rule. The hook sees the canonical swap, exact direction, current
liquidity, and actual delta.

**Guardrails.** Per-block and per-window borrow caps; exact accounting from returned
deltas; a hard price limit; cancellation nonce; no leverage increase in protected mode;
and an invariant that a partial fill increases debt no faster than collateral received.

## 2. Liquidity-as-collateral revolving credit

**Idea.** Let an LP lock a v4 position with the market and borrow against the conservative
value of both legs plus accrued fees. The hook rejects removal unless the market proves the
post-removal health factor. As price crosses the LP's range, the collateral naturally
rotates between assets, so the debt facility finances market making without forcing an LP
to unwind first.

Credit value is not the position's spot mark. It is the minimum of (a) TWAP-valued token
amounts at adverse ticks, (b) realizable value after an immediate full-range rebalance,
and (c) committed liquidation depth. Fees remain trapped as additional collateral until
health exceeds a withdrawal threshold.

**Frontier extension.** Issue two claims: a senior lender claim on principal and an LP
residual claim on fees/upside. This makes “leveraged LPing” a native tranched product.

**Guardrails.** Market-owned or lock-wrapped positions only; adverse-range valuation;
fee-growth proofs; cooldown on range changes; no external liquidity counted as depth; and
liquidation that burns/withdraws the position before selling either leg.

## 3. Exit-queue senior credit

**Idea.** An LP vault promises instant-ish withdrawals in normal conditions but queues
redemptions during utilization spikes. The otherwise idle queue becomes an underwriting
primitive: borrowers can draw only against the fraction of pool liquidity committed past
the loan's liquidation horizon. In return, queued LPs receive a senior share of interest.

`beforeRemoveLiquidity` makes commitment enforceable at the pool boundary. A dynamic exit
toll rises with utilization and pays stayers, while a free in-kind exit remains available
when it does not impair borrower solvency.

**Novel payoff.** Liquidity duration, rather than merely liquidity quantity, becomes the
credit capacity input. LPs select duration buckets and form an onchain term structure.

**Guardrails.** Never promise par; publish NAV and queue age; cap maturity mismatch;
service exits FIFO within a bucket; prohibit operator reprioritization; and offer a
haircut-transparent emergency in-kind strip rather than freezing forever.

## 4. Order-flow liquidations

**Idea.** Maintain an onchain queue of underwater collateral lots ordered by conservative
trigger tick. When an incoming swap wants that collateral, the hook lets the market fill a
bounded portion from the liquidation lot before—or via hook deltas alongside—the AMM.
Buyers receive normal execution, unhealthy debt is repaid, and liquidation avoids a
separate auction plus a second price-impacting swap.

Opposing swaps can similarly repay quote debt directly. The pool becomes a continuous
liquidation auction whose bid is ordinary user flow.

**Why it is powerful.** Liquidators usually need capital and extract a discount. Here the
next taker supplies capital unknowingly at an execution price bounded against the pool,
allowing more of the discount to recapitalize lenders or reward the trader's residual.

**Guardrails.** Deterministic queue ordering; bounded work per callback; no worse execution
for the taker than their signed limit; exact-output/partial-fill proofs; dust aggregation;
and a permissionless fallback liquidation when organic flow is absent.

## 5. Volatility-contingent leverage

**Idea.** Treat leverage terms as a state machine derived from pool microstructure. Stable,
deep, two-sided flow gradually raises borrow caps and lowers rates. Tick jumps, shallow
depth, one-sided volume, or spot/TWAP divergence instantly stop leverage increases and
raise a dynamic LP fee; sustained stress then steps down liquidation thresholds slowly
enough to avoid a single-block cliff.

Borrowers can buy a **term lock**: pay an upfront premium to freeze maintenance margin for
`N` blocks. The premium funds a first-loss reserve, turning predictable risk parameters
into an insurable product rather than governance discretion.

**Guardrails.** Hysteresis; minimum observation age; bounded ring reads; separate “no new
risk” and “liquidate” thresholds; never let a manipulable spot observation directly lower
margin; and value locks under an adverse volatility scenario.

## 6. Loss-first fee bonds

**Idea.** Finance loans against the pool's *future* fees. Bonders deposit first-loss
capital and receive a programmed fraction of LP fees, origination fees, and surge fees
until principal plus a capped return is repaid. Their deposit expands credit capacity;
losses slash it before passive LP principal.

This is revenue-based financing for a pool. A successful pool can bootstrap lending before
it has deep idle lender deposits, while fee bond prices reveal the market's view of future
volume and credit quality.

**Push further.** Auction discrete fee epochs. Junior “traffic bonds” absorb volume risk;
senior credit deposits absorb only residual borrower loss. The hook routes each realized
fee by a fixed waterfall rather than trusting an offchain revenue report.

**Guardrails.** Do not count projected fees as present collateral; only the posted bond
raises hard capacity. Cap return and duration; isolate epochs; prohibit circular borrowing
to buy the same bond; and slash from realized bad debt, not mark-to-market noise.

## 7. Cross-pool collateral mesh

**Idea.** A coordinator accepts locked positions or debt-free collateral across several
hooked pools. Each pool hook exports a minimal, lagged risk attestation—TWAP, committed
depth, utilization, protected status—not a callable “price oracle.” The coordinator grants
portfolio credit from the minimum of per-asset limits and a correlation stress matrix.

A trader could collateralize ETH/token-A liquidity, borrow quote in token-B's pool, and
have repayment sourced from fee cash flows across both. Hooks locally freeze risk-increasing
actions when the global account becomes unhealthy, but local swaps remain live.

**Novel payoff.** Productive liquidity becomes cross-market margin without transferring
every asset into a monolithic lending pool.

**Guardrails.** Delayed/median attestations; caps per hook implementation and asset;
one-way failure isolation; no synchronous hook-to-hook calls; global nonce and replay
protection; correlation floors; and a rule that one protected pool cannot manufacture a
healthy global mark for another.

## 8. Perpetual funding AMM

**Idea.** Add a virtual long/short ledger beside the spot pool. Traders post margin to the
market; position changes execute a real hedge through the v4 pool. The hook measures net
open interest and realizes funding continuously as a direction-sensitive fee adjustment:
swaps that worsen skew pay, while swaps that reduce skew receive a bounded rebate funded
from previously collected funding.

Unlike a periodic funding transfer, every relevant trade settles a small piece of the
imbalance. A keeper only checkpoints idle periods. LP inventory plus an external hedge
vault backs net exposure; neither virtual PnL nor funding is left as a PoolManager delta.

**Guardrails.** Segregated margin; capped negative fees/rebates; mark from lagged TWAP plus
impact bands; open-interest cap from executable hedge depth; insurance fund; socialized
loss rules fixed at creation; and permissionless deleveraging before insolvency.

## 9. Impact-minted liquidation options

**Idea.** Large, risk-reducing trades pay an impact premium that mints short-lived put-like
coverage for leveraged accounts. If the time-window TWAP later crosses a strike, coverage
pays quote into liquidation, reducing forced selling. If it expires, the premium flows to
LPs or option writers.

The strike and notional derive from observed post-trade impact, so the users who consume
the most immediate depth automatically finance future crash depth. Coverage can be
fungible by expiry/strike bucket rather than per account.

**Guardrails.** A swap cannot mint coverage on a self-induced one-block wick; require
pre/post TWAP windows, delayed activation, maximum issuance per epoch, fully funded payout
buckets, no payout to the triggering manipulator, and conservative exercise settlement.

## 10. Just-in-time flash refinance

**Idea.** During one PoolManager unlock, repay debt in market A, release collateral, swap
only the necessary portion, and settle a new loan in market B. The destination lender signs
a maximum-rate/minimum-collateral commitment. No user bridge loan and no transient
uncollateralized state survives the unlock.

The hooks enforce that source removal and destination addition correspond to one signed
refinance hash. This creates a permissionless refinancing market where solvers compete on
route, lender, and slippage.

**Guardrails.** One coordinator owns the unlock; hooks never recursively unlock; balances
must settle before return; destination credit is committed before source collateral moves;
EIP-712 chain/pool/nonces; callback allowlist by code hash; and atomic revert on any health
or price-limit failure.

## 11. Intent-backed credit lines

**Idea.** A borrower receives a credit line only when a solver has signed an executable
future sale intent for the financed asset. The intent specifies decay, minimum proceeds,
expiry, and solver bond. Borrow capacity is the lesser of normal collateral value and the
bonded exit quote after stress. When pool flow crosses the quote, the hook can trigger the
intent and repay directly.

This connects lending to a precommitted liquidation market. Solvers earn an option premium
for standing ready; their slashable bonds make quotes more credible than free offchain
orders.

**Guardrails.** Multiple competing intents; partial-fill accounting; slash only objective
failures; permissionless execution after expiry; quote diversity requirements; no solver
ability to censor ordinary swaps; and conventional liquidation remains the backstop.

## 12. Time-sliced liquidation lanes

**Idea.** Replace a binary liquidation bonus with lanes. An unhealthy account enters a
short exclusive lane for small backstops, then a public Dutch lane, then a final pool-owned
unwind. The hook applies a direction-aware toll to trades that worsen the pool's liquidation
inventory and rebates trades that consume it. Lane parameters are fixed from health and
elapsed time, not keeper choice.

This combines auction price discovery with live AMM liquidity and prevents one searcher
from taking the entire account merely for arriving first.

**Guardrails.** No exclusive allowlist; lane eligibility is provable (for example,
per-address rolling size caps); monotonically increasing discount; total-seizure cap;
bounded callback work; and an immediate escape hatch for deeply insolvent accounts.

## 13. Range-maturity term loans

**Idea.** Encode lender duration using isolated liquidity ranges in a companion credit
vault. Near-price ranges represent short-dated, highly liquid lending; farther ranges
represent longer-duration capital and activate as price/risk moves. Borrowers select a
maturity band and pay the marginal rate of the last activated range.

The actual v4 LP liquidity remains committed execution depth, while separate vault shares
track credit claims; ticks are a transparent allocation/indexing device, not a claim that
AMM liquidity itself can remain unsettled debt.

**Novel payoff.** A continuously quoted lending yield curve can emerge from the same price
geometry that liquidates collateral.

**Guardrails.** Separate AMM value from debt accounting; lock ranges through maturity;
prevent last-block range insertion; batch maturities to bound gas; pro-rata defaults within
a band; and keep a reserve between adjacent maturity cliffs.

## 14. Inventory-repo borrowing for market makers

**Idea.** Market makers lock the inventory the pool needs most (the scarce side implied by
range composition and recent directional flow) and borrow the abundant side. Their rate
falls when their quoted/locked inventory reduces imbalance and rises when they amplify it.
The hook measures contribution from actual swaps, not claimed quotes.

This is onchain repo: short-duration financing secured by useful inventory. A maker can
roll the loan while continuing to provide depth; failure transfers the inventory to the
market for orderly sale.

**Guardrails.** Credit only locked, non-withdrawable inventory; contribution averaged over
time; ignore self-trading and same-block round trips; cap rebates below base interest;
adverse TWAP haircuts; and require maker loss-first equity.

## 15. Debt that converts into locked liquidity

**Idea.** Lenders choose a convertible tranche. If bad debt exhausts junior reserves, part
of their claim converts at a predetermined adverse price into long-duration, market-owned
LP shares instead of forcing an immediate fire sale. The hook locks converted liquidity
for a recovery epoch and directs elevated stress fees to those shares.

This makes the resolution asset productive: insolvency adds execution depth precisely when
the pool needs it. It is closer to a bank bail-in than an algorithmic stablecoin peg.

**Guardrails.** Conversion terms immutable and visibly worst-case; non-convertible senior
tranche capped by hard reserves; no governance-triggered discretion; conversion only after
verified realized loss; minimum lock duration; and never describe converted shares as par.

## 16. Cross-pool basis perpetuals

**Idea.** Build a perp on the price difference between two v4 pools for the same or related
asset—for example, a new hooked pool versus the deepest reference pool. Each hook writes
bounded observations; a separate basis market settles funding from the lagged difference
and hedges legs atomically when possible.

Liquidity migrators can hedge convergence risk, while arbitrageurs finance the thinner
pool by taking the other side. Funding revenue can be routed to committed LPs in the weak
pool, turning basis into a direct incentive for depth where it is missing.

**Guardrails.** Never compare observations from different timestamps without a staleness
penalty; use independent manipulation budgets; cap open interest by the thinner leg;
handle chain reorg and sequencer downtime; isolate each reference pair; and fall back to
reduce-only when either pool is protected.

## Combinations worth prototyping

The mechanisms become more interesting in carefully bounded combinations:

1. **Productive margin loop:** liquidity-as-collateral (#2) + inventory repo (#14) +
   volatility-contingent terms (#5). LP inventory earns fees while financing only the side
   the pool needs.
2. **Auctionless recovery stack:** order-flow liquidation (#4) + liquidation options (#9)
   + time-sliced lanes (#12). Organic flow gets first use, insurance absorbs the jump, and
   explicit auctions remain the fallback.
3. **Thin-pool accelerator:** loss-first fee bonds (#6) + basis perps (#16) + convertible
   debt (#15). Bond capital opens conservative credit, basis traders subsidize depth, and
   the resolution path adds rather than removes liquidity.
4. **Credit router:** cross-pool mesh (#7) + intent-backed lines (#11) + flash refinance
   (#10). Portfolio collateral is portable without letting any hook synchronously trust
   another hook's callback.
5. **Continuous perp:** swap-stream margin (#1) + perpetual funding (#8) + order-flow
   liquidation (#4). Entry, funding, and exit all settle against real pool flow.

Do **not** combine everything. The safe unit is one custody contract, one explicit loss
waterfall, and a small hook state machine. Cross-pool and solver features should sit above
that unit and fail closed for new risk while preserving ordinary swaps and repayments.

## A build order that can falsify ideas cheaply

1. **Simulation first.** Replay volatile and one-sided swap traces. Measure bad debt,
   lender yield, LP drawdown, liquidation slippage, and callback gas against a plain
   borrow-then-swap baseline.
2. **Pure accounting model.** Define conservation equations for pool deltas, vault assets,
   debt, margin, fees, and insurance. Property-test partial fills and every rounding edge.
3. **Single-pool prototype.** Start with order-flow liquidations (#4) or volatility terms
   (#5); both reuse the repository's existing hook/market split without cross-pool trust.
4. **Adversarial token suite.** Include tax, rebase, callback, false/no-return, pause,
   blocklist, and balance-changing tokens before claiming arbitrary-asset support.
5. **Economic attacks.** Self-trade, JIT liquidity, oracle painting, queue stuffing,
   sandwiching, solver censorship, griefing via tiny positions, and correlated pool
   manipulation need executable proofs, not prose.
6. **Operational gates.** Mine/verify permission bits, verify deployed bytecode and one-shot
   bindings, rehearse deployment on a fork, cap initial TVL, and publish reduce-only and
   emergency-exit behavior before accepting deposits.

## Kill criteria

A mechanism should not ship if any of these remains true:

- solvency depends on uncommitted external liquidity;
- a hook callback performs an unbounded queue walk;
- a one-block spot move can increase credit or trigger profitable insurance;
- partial fills can increase debt without the corresponding collateral;
- an ordinary swap can be frozen by an unrelated borrower account;
- governance can change the loss waterfall after deposits;
- a cross-pool call can spread a revert or stale mark synchronously;
- “yield” depends primarily on recursive borrowing or self-generated volume;
- the emergency path needs the same oracle or solver that just failed; or
- the mechanism cannot explain, in one equation, who absorbs the first dollar of loss.

The frontier is not maximum leverage. It is making leverage **more executable**: debt sized
by durable depth, risk reduced by ordinary order flow, and failure resolved through explicit
capital rather than hidden accounting.
