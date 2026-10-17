# Treasury Buyback on the price log (lab)

`HookrBuybackBurn` from the app repo's Treasury Buyback lab (`labs/hooks/treasury-buyback`, branch
`nodes/hookr-1-w7-treasury-buyback-gate` at `11a610f54`), ported to read the shared price log
(`labs/hooks/price-log`) instead of the Oracle Recorder. The recorder was kept out of the live set on 10-06, and the
buyback was held with it; this port needs nothing that is not live today.

Nothing here is deployed, listed or admitted. It is a lab: step 1 of the contract lifecycle. Not ported: the treasury
splitter (it reads no price and is unchanged in the app lab), the deploy-day files, scripts and earlier test suites.

## What the buyback does

Unchanged from the app lab: it spends the settlement currency it holds (the splitter's buyback leg) on HOOKR through the
pinned `HookrRouter`, burns every token it buys to the dead address in the same transaction, and refuses any buy below a
floor off the pool's time-weighted price. An owner with the `HookrGoverned` 30-minute timelock (the Safe, decision 4)
can pause at once, tighten at once and loosen only after the delay.

Kept as they were:

- **The 300 bps floor** (`DEFAULT_SLIPPAGE_BPS`, bounds 10 to 1,000), off whichever of the reference mean (1,800 s by
  default) and the short `SPOT_WINDOW` mean (60 s) prices HOOKR cheaper for the buyback.
- **The spend cap**: at most `spendCap` per `spendPeriod` (default one reference window), a token bucket; raising it
  waits the timelock, lowering it is immediate.
- The router's pinned code hash, the pause brake, the transient reentrancy lock, `collect`.

`HookrGoverned`, `HookrDelegation` and `IHookrGoverned` are vendored from `hookr-1/src` (the live release's source,
identical to the app lab's copy) under `vendor/hookr-1/`, with only the pragma relaxed from `^0.8.34` to `^0.8.26` to
build in this project's compiler.

## What changed

| | App lab (Oracle Recorder) | This port (price log) |
|---|---|---|
| Reference | `HookrOracleRead.consult` on the Rules' recorder | `HookrPriceLog.meanFresh` on the pool's log, pinned at construction (`priceLog`, immutable) |
| Bind | pool + Rules; the recorder must record the pool, no arb recapture lane, ring holds the window | pool + log id; the log must record that pool and serve the window with at least `MIN_RECORDS_PER_WINDOW` (4) intervals in it, at most 48 |
| Freshness | refuses a newest observation older than 300 s (`StaleReference`) | refuses (`NoHealthyReference`) when any record weighing in either mean stood longer than `MAX_STAND_INTERVALS` (2) intervals, so the log must be kept recorded (a keeper, 45k gas a record). The buyback also records when one is due; that record weighs nothing in either mean |
| Router | any router with code | also swaps on the PoolManager the log reads (`RouterManagerMismatch`), at construction and on `SET_ROUTER` |
| Inside an unlock | the router's unlock reverts | refuses first (`ManagerUnlocked`) |
| Before the pool exists | constructor reverts (`InvalidPool`) | deploys; `buyback` reverts `NoHealthyReference` until the log covers the window |
| Constructor | `(owner, hookr, router, pool, rules, spendCap)` | `(owner, hookr, router, priceLog, pool, logId, spendCap)` |
| `SET_POOL` | `abi.encode(PoolKey, rules)` | `abi.encode(PoolKey, logId)` |
| Compiler | 0.8.37 | 0.8.26 (this project's) |

**SL-1, resolved in code.** The handoff's SL-1: the owner's default for ANSWER-FORM item 32 skips HOOKR's reference pool
on day one, so the old constructor reverted `InvalidPool` and every later row of the deploy files ran on an empty
address. The block was held for it. Here the bind checks only that the key holds HOOKR and that the log is that key's,
and neither needs the pool to exist. The buyback deploys on day one bound to the pool's key and its log (opened with the
opening tick as its seed), and stays inert, failing closed, until the pool launches and the log has a full reference
window. `test_SL1_*` and the fork run show both halves. The deploy-day files in the app lab would need rendering again
for the new constructor; that is not done here.

The arb recapture lane check is gone: it existed because the recorder credited a lane leg's price to the quiet gap
before it. The log never records inside an unlock, so a leg is never recorded; the record after it is the settled price.

## Tests

`forge test --root labs --match-path 'hooks/treasury-buyback/test/*'`: 54 pass, each suite with HOOKR as currency0 and
as currency1; the three fork tests skip without an RPC.

| Suite | What it shows |
|---|---|
| `HookrBuybackBurn.t.sol` (15 × 2) | SL-1 on a fresh key (built before the pool, refuses, works a window after launch) and on the default setup; bind refusals (no HOOKR, another pool's log, an unopened log, a window under four intervals, no log contract, a router on another PoolManager); burning at the floor or better and holding nothing; the due record written by the buyback weighs nothing; the 300 bps default; refusal inside an unlock; a thin record still weighing; the cap and its refill; pause and timelocked unpause; `SET_WINDOW` checked against the log; re-pin of pool and log together; owner-only; a fuzz of price paths and same-transaction moves (a buyback either returns at least the floor and burns all of it, or spends nothing) |
| `BuybackInvariant.t.sol` (4 × 2) | Over random swaps, waits, records, funding and buybacks: never holds HOOKR; never buys under the floor; spends at most one cap up front plus one per period; plus a check that the handler's buys succeed |
| `BuybackAttack.t.sol` (8 × 2) | A same-transaction pump of 4% (refused); one owned record standing 299 s (lifts the mean 83 ticks; the highest held price the buyback then takes is +347 ticks, 379 bps short of fair on one cap); holding +2,000 for a window (one cap buys 1,844 bps short of fair, the next is refused, the balance untouched: SL-2 restated); six pump-record-dump records with no price held (mean +1,748; a sandwich at +2,013 sells one cap 1,855 bps short of fair); a reference nobody recorded for an hour (refused, then priced at the new price once records resume); one pumped record and no records after it (refused as stale); a dump before the buyback (buys cheap); record spam (no faster warm-up) |
| `BuybackFork.t.sol` (3) | On Robinhood Chain 4663, below |

### Fork run (4663, L2 block 91,088,307, parent 26,213,644)

`FOUNDRY_ETH_RPC_URL` from `~/.config/hookr/rpc.env` in the environment, never on a command line;
`FOUNDRY_FORK_BLOCK_NUMBER=91088307 forge test --root labs --match-contract BuybackFork -vv`. Output: `fork-run.log`.

The test pins the live Launcher, root `0x89c9…6aCc`, Rules `0x4a71…7942` and the PoolManager by runtime keccak (the
Drawdown Burn fork run's pins), checks the root names the live `HookrRouter` `0xC2Bc…93C9`, and launches a HOOKR
stand-in through the live Launcher as a plain reference pool (ETH/token, 0.30%, no Auto Burn, no tax).

| Step | Result |
|---|---|
| Log opened (seed = the opening tick) and buyback deployed before the pool exists | deploys; `buyback` reverts `NoHealthyReference` |
| Pool launched | the log refuses its first record (`ThinStart`) until the first buy puts liquidity in range; then records 177,230, the spot |
| 1 ETH of buys, the log catches up in 2 records and covers the window | |
| `record` / `mean` 1,800 s on the live pool | 45,407 / 26,411 cold, 10,290 warm |
| `buyback(0.01 ETH)` through the live router and root | 244,078 gas; 451,584 tokens burned, 44 bps short of fair at the reference (fee and impact); 0.04 ETH left |
| A second `buyback` at once | `SpendLimitExceeded` (the deploy-day 0.01 ETH cap); after a period with a keeper recording, it buys again |
| A ~5% pump through the live root in the same transaction | refused by the router's `Slippage()` at the buyback's floor |
| Six pump-record-dump round trips (0.6 ETH each), then the biggest sandwich the lifted floor accepts (0.887 ETH) | the mean moved 531 ticks; one cap bought 801 bps short of fair (about 0.0008 ETH of HOOKR); the records cost the attacker 0.028 ETH and the sandwich 0.006 ETH: net -0.035 ETH. Unprofitable at the 0.01 ETH cap on this pool's fees and depth |

## Known limitations

Each carries over from the app lab's HANDOFF unless marked new; none is fixed by the port.

- **Whoever writes every record for a window sets the reference (SL-2, wider than before).** No price has to be held:
  a pump, the record and the dump in one transaction writes one clamped step, so the pool sits at the true price
  between records. The attacker has to be first to record each interval and pays a round trip of fees per record, then
  sandwiches the buyback up to the lifted floor. Locally (0.30% pool, no other cost) six such records lifted the mean
  1,748 ticks and a sandwich sold one cap 1,855 bps short of fair. On the live fork pool it cost the attacker 0.035 ETH
  net to take 801 bps of one 0.01 ETH cap, so the cap is what makes it unprofitable: raise the cap only with the
  reference pool's depth and fees in view. A keeper recording the moment each record is due takes the records from
  the attacker. The spend cap bounds the rate, never the loss per cap; pause stops it.
- **New: liveness needs a keeper.** `meanFresh` refuses a reference with a record that stood over two intervals, so
  the buyback works only while someone records the log every interval (anyone may; 45k gas a record).
- **JIT liquidity defeats the thin flag** (the log's pinned limitation, the recorder's S2-1). The reference pool's
  liquidity must be locked.
- **The bucket bursts to about two caps inside one period (SL-3)**, **a re-pin keeps the raw cap (SL-4)**, **the queue
  accepts non-canonical entries (SL-5)**, **who owns the reference key (TB-G2)**: unchanged.
- **New: the log's parameters are the owner's choice at bind.** The contract checks that the log records the pool and
  serves the window; it does not require a seed tick. A log opened after the pool trades, without a seed, takes the spot
  as its first record. Open the reference pool's log before launch with the opening tick as its seed.
- **New: one log contract.** `priceLog` is immutable, so a fix to the log needs a new buyback.

## What still needs an attack round (runbook 6.0)

This is new bytecode, so the gate's attack round has to run on it before anything goes further:

1. `HookrPriceLog` itself: the record and seed paths, the clamp, the unlock refusal, the mean's step-function walk and
   its fail-closed cases, the id scheme, and what a reader can be made to read.
2. The buyback's new read path: the record-then-read order; `meanFresh` with `MAX_STAND_INTERVALS` in place of the
   staleness check; `MIN_RECORDS_PER_WINDOW`; the bind, `SET_POOL`, `SET_WINDOW` and `SET_ROUTER` checks against the
   log; the removal of the lane check; and above all pump-record-dump records feeding a sandwich, against the real
   reference pool's depth and fees and the deploy-day cap.
3. The deploy-day cap against the reference pool's real depth, with the log in place of the recorder.
4. The Drawdown Burn engine's changes: reading a log another block shares, the lazy high, the boundary-ending epoch
   close.
5. The vendored `HookrGoverned` compiled under 0.8.26 instead of 0.8.37 (same source, different compiler).
