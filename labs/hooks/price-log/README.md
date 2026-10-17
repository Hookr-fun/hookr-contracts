# Price Log (lab)

A shared, oracle-less price log for Uniswap v4 pools: anyone may open a log for a pool, anyone may record into it, and
any contract may read its time-weighted means. It is the Drawdown Burn engine's record ring
(`labs/hooks/drawdown-burn`, draft PR #17) taken out of the engine, so several Hook Blocks on one pool can share one
record stream instead of each keeping its own. No owner, no admin key, no oracle, no new core.

Nothing here is deployed, listed or admitted. It is a lab: step 1 of the contract lifecycle.

Readers today: the Drawdown Burn engine and the Treasury Buyback port (`labs/hooks/treasury-buyback`). Candidates for
later: the Range Vault's TWAP source (its open question 1), Floor Bid D-8 (a keeper rebalance needs a max-deviation
mean), Vesting Milestone time-in-range (needs new factory code).

## How it works

One `HookrPriceLog` per PoolManager holds every log. A log is a pool plus its parameters, and its id is the hash of
both, so:

- nobody can open a log under someone else's id with other parameters (a hostile seed tick is simply another log);
- opening the same pool with the same parameters again finds the same log, so blocks that agree share history;
- nothing about a log can change once it is opened.

`record(id)` writes the pool's spot tick at most once per `interval`:

- each record is clamped to `maxMoveTicks` from the previous one;
- it is refused while the PoolManager is unlocked, so a free pump inside an unlock cannot be recorded;
- a record taken under `minLiquidity` of in-range liquidity is marked thin;
- the first record is refused inside an unlock or thin, and clamped to `seedTick` (the opening price) when the log has
  one. A log can be opened before its pool exists; it takes its first record once the pool trades.

`mean(id, window)` and `meanUntil(id, window, end)` are time-weighted over the step function of the records:

- a record weighs nothing in a window that ends when it is written, so a pumped record counts only for the time it
  stands, until the next record replaces it, at least one interval later;
- a mean fails closed (`ok = false`) when the ring does not reach back to the window's start, when a record that weighs
  in it is thin, or when the window is longer than `MAX_WINDOW_INTERVALS` (48) intervals;
- `meanFresh(id, window, maxStand)` also fails closed when a record that weighs in the window stood longer than
  `maxStand` seconds (until the next record, or now), so a reader can refuse a mean one old or pumped record dominates
  because nobody recorded after it;
- ticks are the pool's own (currency0's price in currency1); a reader whose subject is currency1 negates them, which is
  exact because the mean rounds toward zero.

Other views: `meanFresh`, `latest`, `recordAt`, `recent(n)`, `params`, `poolOf`, `count`, `isOpen`, `servable`, `logId`.

## Parameters

Each is fixed when the log is opened, checked against its bounds there, and cannot change after.

| Parameter | Default (Drawdown Burn, Treasury Buyback) | Bounds |
|---|---|---|
| `interval` | 300 s | 60 s to 1 h |
| `maxMoveTicks` | 500 (~5.1%) | 10 to 5,000 |
| `minLiquidity` | per pool (fork: 1e18) | > 0 |
| `hasSeedTick` / `seedTick` | the opening pool tick for a log opened before its pool | strictly inside the tick range; 0 when unset |

Fixed, not knobs: the 64-record ring, the 48-interval longest window (inside the ring at the fastest pace), the refusal
inside an unlock, and no owner. A reader sets its own window inside the log's bounds and checks the log's parameters
when it binds.

## Gas

Local pool (`test_gas_readsColdAndWarm`, `gas.log`); "cold" is storage slots not yet touched in the transaction
(`vm.cool`), with the log's account already warm (a first call to it in a transaction adds 2,500).

| Call | Cold | Warm |
|---|---|---|
| `record` | 41,416 | |
| `mean` 900 s (4 records) | 16,981 | 6,754 |
| `mean` 1,800 s (7 records) | 26,408 | 10,183 |
| `mean` 3,600 s (13 records) | 45,264 | 17,039 |
| `recent(13)` | 53,286 | |

On the live 4663 pool (`labs/hooks/treasury-buyback/fork-run.log`): `record` 45,407 with the log's and the
PoolManager's slots cold; `mean` 1,800 s 26,411 cold / 10,290 warm; `mean` 60 s 7,557 / 3,436. `meanFresh` reads the
same slots.

## Tests

`forge test --root labs --match-path 'hooks/price-log/test/*'`: 60 pass, every suite on rising and on falling pool
ticks. The attack suite's figures are in `attack-run.log`.

| Suite | What it shows |
|---|---|
| `HookrPriceLog.t.sol` (20 × 2) | Opening: idempotent, keyed by parameters, every bound; unknown logs revert; the first record waits for the pool and for liquidity, clamps to the seed, is the spot without one, and is refused inside an unlock; once per interval; the clamp; refusal inside an unlock only when a record is due; the thin flag; the ring wrapping at 64; the newest record weighing nothing; exact time weighting; failing closed; a thin record failing a mean only while it weighs; past-ending means; `meanFresh` refusing a record that stood too long and matching `mean` otherwise; a fuzz of price paths against an independent model of the step function; gas |
| `PriceLogInvariant.t.sol` (3 × 2) | Over random swaps, waits, records, records from inside an unlock and liquidity pulls: records move at most the clamp and come at least an interval apart; nothing is ever written from inside an unlock; every mean equals the model and stays inside the records it weighs |
| `PriceLogAttack.t.sol` (7 × 2) | A flash pump inside an unlock (refused); pump, record, dump in one transaction (recorded +500 of +5,000, weighs nothing that block, moves the 1,800 s mean 83 ticks after one interval); owning every record for a window (the newest at +3,000 after six, the mean +1,748, exactly the clamp's triangle); a hostile seed (another log); record spam (one per interval); JIT liquidity around each record (defeats the thin flag: pinned limitation); a past-ending mean ignores later records |

## What the tests do not show

- **JIT liquidity defeats the thin flag** (`test_attack_jitLiquidityAroundEachRecordDefeatsTheThinFlag`). Whoever can
  pull a pool's liquidity can add a position around each record and remove it after, so a thin pool reads deep and moves
  for dust; only the clamp bounds it. The Oracle Recorder's S2-1 in this design. Read logs only on pools whose liquidity
  is locked.
- **An attacker who owns every record for a window moves the mean, with no price held.** A record needs only a pump,
  the record and the dump in one transaction, so the pool sits at the true price between records and arbitrage has
  nothing to correct. The cost is one round trip of fees per record, and the attacker has to be first to record each
  interval. One clamped step per interval, so six owned records put the 1,800 s mean 1,748 ticks (~19%) over the
  truth on the local pool. Readers bound what a moved mean can buy (the buyback's spend cap; the engine's rise cap), and
  a keeper that records the moment each record is due takes the records from the attacker.
- **It lags fast real moves, both ways**: at 500 ticks a record every 5 minutes, an 8x rally took 43 records (3.6 h) on
  the fork, and a crash registers just as slowly.
- **One log per parameter set.** Readers that ask for different parameters on one pool record separately; a reader
  should take the defaults unless it has a reason not to.
- Not run: an independent review or attack round, a log read by two different blocks on one fork pool at once.
