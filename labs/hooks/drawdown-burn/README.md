# Drawdown Burn (lab)

A burn engine for one Hookr pool that spends what the pool's sell tax collects on buybacks that burn the token, with a
burn share set by how far the price sits under its all-time high, and keeps the rest as a wall: a buy order at a fixed
distance under the high whose fills are burned too. It needs no oracle, no new core and no owner. Built for Ika's RHUB
burn (X post 2026-10-16 08:35Z; TG rhub x WTH 10-06 21:27Z and 10-17 13:41-13:42Z), with Ika's numbers as defaults.

Nothing here is deployed, listed or admitted. It is a lab: step 1 of the contract lifecycle.

## How it fits a pool

The pool runs two blocks that are live today: **Auto Burn** on buys (Rules `burnBps`, taken in the token and sent to the
dead address inside the swap) and **Tax + Conversion** on sells (`HookrDirectionalTax`, taken in the quote), with the
sell leg's recipient set to this engine. The engine is one periphery contract per pool, deployed before the pool so its
address can be that recipient. It reads the sell queue from the advisory (`terms(root, id).sellQueue`) on each run.
Anyone may also fund it directly, so a pool whose tax already pays a treasury can forward from there.

`run()` is permissionless:

1. Records the price if a record is due (below).
2. Collects the tax: `payCreator()` on the sell queue. A queue with nothing due reverts; the run goes on.
3. Splits the new income by the drawdown tier: the burn share into the burn budget, the rest into the wall reserve.
4. Works the wall: if the price is under the wall price (the high less `wallOffsetBps`), buys up to that price and burns.
5. Spends the burn budget (unless a flow epoch is accumulating): buys the token, never above the reference price plus
   `maxSlippageBps`, and burns it.

Both buys share one spend cap that refills over `refillSeconds` (Ika: 200 ARB per ~12 s). A run pays its caller
`tipBps` of what it spent, and the co-author `coAuthorBps` (decision 9).

## How it prices without an oracle

Every price it acts on comes from its own records, never from the spot of the transaction that calls it (the OpenZaps
v3.1 relative-floor bug, KupiaSec 10-15, was a floor built from same-transaction spot).

- **Records.** `checkpoint()` is permissionless and writes the pool's spot tick at most once per `checkpointInterval`.
  Each record is clamped to `maxMoveTicks` from the previous one, and refused while the PoolManager is unlocked, so a
  free pump inside one unlock cannot be recorded and a paid pump moves one record by a bounded step. The ring holds 64.
- **Means.** Time-weighted over the step function of the records; the newest record weighs nothing when written, so a
  pumped record counts only for the time it stands, which is a whole interval in which anyone may record over it.
- **The high.** Ratchets up only when every record across `athWindow` seconds (at least `athMinCheckpoints` of them)
  sits above it, to the lowest of those records, never by more than `athRiseCapBpsPerHour` for the time since the last
  rise. It never goes down. Nobody can set it after launch; `initialAth` may seed it at launch (RHUB today: 9.69M ARB).
- **Thin records.** A record taken while in-range liquidity is under `minLiquidity` is marked thin. A window that weighs
  one cannot raise the high, set a tier, price a buyback or close an epoch.
- **Flow epochs.** Ika's switch, without counting swaps: in a pool whose liquidity did not move, net quote in or out
  over an epoch is fixed by where the price started and ended. At each epoch's first record the engine compares the mean
  over `epochWindow` with the epoch's open: up by more than the dead band accumulates (net in), down by more spends
  (net out), inside it keeps the mode. Construction refuses a dead band that one clamped record could cross.

## Parameters

Every one is fixed in the constructor, checked against its bounds there, and cannot change after.

| Parameter | Default (Ika's where he gave one) | Bounds |
|---|---|---|
| `checkpointInterval` | 300 s | 60 s to 1 h |
| `maxMoveTicks` (per record) | 500 (~5.1%) | 10 to 5,000 |
| `minLiquidity` | per pool | > 0 |
| `athWindow` | 3,600 s | 300 s to 24 h, at most 48 intervals |
| `athMinCheckpoints` | 6 | 2 to 48, fitting the window |
| `athRiseCapBpsPerHour` | 0 (off); see decisions | 0, or 500 to 10,000 |
| `initialAth` | unset | any tick |
| `measure` | PRICE | PRICE or MARKET_CAP (circulating = supply less dead, zero and up to 4 excluded holders) |
| `tierEdgesBps` | 2,000 / 4,000 / 6,000 | rising, first > 0, last ≤ 9,500 |
| `tierBurnBps` (at/above high, then per band) | 0 / 2,500 / 5,000 / 7,500 / 10,000 | ≤ 10,000, never falling |
| `refWindow` (tiers, buyback price) | 900 s | 300 s to 24 h, at most 48 intervals |
| `spendCap` / `refillSeconds` | per pool (fork: 0.05 ETH) / 12 s | > 0 / 12 s to 7 days |
| `maxSlippageBps` over the reference | 300 | 10 to 1,000 |
| `wall` / `wallOffsetBps` | RESERVE / 6,000 | RESERVE or SINK (pays `wallSink`, e.g. a Floor bid vault) / 1,000 to 9,000 |
| `epochSwitch` / `epochLength` / `epochWindow` | off (Ika's live RHUB design) / 24 h / 3,600 s | on/off / 1 h to 7 days / 300 s to the epoch |
| `deadBandBps` | 100 | ≤ 2,000 and wider than one record can move the epoch mean |
| `netOutSinkBps` / `netOutSink` | 0 | share of a net-out spend sent to a sink (add LP) instead of bought back |
| `tipBps` (run caller) / `checkpointReward` | 0 / 0 | ≤ 50 / ≤ 1% of the spend cap, paid only from unallocated quote |
| `coAuthorBps` / `coAuthor` | 0 (decision 9) | ≤ 2,000 of what the engine spends |

Fixed, not knobs: the dead address, no owner, the 64-record ring, the refusal inside an unlock, no buy under 1% of the
spend cap, and the buy sizing below.

**Buy sizing.** A Hookr root refuses an unauthenticated exact-input buy that stops at its price limit with fees to
refund (`UnauthenticatedRefund`, HookrRoot.sol:557). The engine sizes each buy to reach at most the limit at the current
tick's liquidity and halves it up to three times if it still stops there.

## Tests

`forge test --root labs --match-path 'hooks/drawdown-burn/test/*'`: 107 pass, each suite in both orientations (the token
as currency0 and as currency1). The three fork tests skip without an RPC.

| Suite | What it shows |
|---|---|
| `HookrDrawdownBurn.t.sol` (31 × 2) | Bounds; seeding and `start()`; rate limit; clamp; refusal inside an unlock; thin records; time-weighted means; the high's first set, ratchet, rise cap, never falling; Ika's tiers; split and burn; the spend cap refilling; no buy above reference + slippage; the wall buying only under its price; SINK; tip and co-author; collecting from a queue; both epoch modes and the net-out sink; market-cap drawdown deepening with burns; fuzz on tick math, tier order, clamp and spend |
| `DrawdownBurnInvariant.t.sol` (6 × 2) | Over random swaps, waits, records, runs, donations and liquidity pulls: the high never falls and never exceeds what records held; records move at most the clamp; budgets stay backed; the engine never holds the token; spend stays within the cap |
| `DrawdownBurnAttack.t.sol` (8 × 2) | One-block pump around a record (records +500 of +5,000, high unmoved); free pump inside an unlock (refused); owning every record for 2 hours (lifts the high, and the rise cap bounds it); dump before a run (tier unchanged); sandwich (no buy); epoch boundary (one paid record cannot flip the mode, three can); liquidity pull (thin, no high, no spend); JIT liquidity around each record (passes the floor: a pinned limitation, below) |
| `DrawdownBurnFork.t.sol` (3) | On Robinhood Chain 4663, below |

### Fork run (4663, L2 block 91,088,307, parent 26,213,644)

`FOUNDRY_ETH_RPC_URL` from `~/.config/hookr/rpc.env` in the environment, never on a command line;
`FOUNDRY_FORK_BLOCK_NUMBER=91088307 forge test --root labs --match-contract DrawdownBurnFork -vv`. Output: `fork-run.log`.

The test pins the live Launcher, root `0x89c9…6aCc`, Rules `0x4a71…7942`, `HookrDirectionalTax` `0xE73f…1e1F` and the
PoolManager by runtime keccak, launches a new token through the live Launcher with Auto Burn 3.3% (`burnBps` 330) and a
3.3% sell tax paying the engine (deployed first, started after), and trades it with plain contracts.

| Step | Result |
|---|---|
| `checkpoint()` on the live pool | 59,809 gas |
| 40 ETH of buys move the price 21,115 ticks | the clamp took 43 records (3.6 h) to catch up; the high then equals the held price |
| Sells take 30.2% off | 0.330 ETH pending on the live sell queue; tier 2 |
| `run()`: collect + split + buyback through the live root | 368,673 gas; 0.264 ETH collected (80% after Hookr's share), half to the burn budget, half to the wall; 0.05 ETH (the cap) spent; 426,927 tokens to the dead address |
| Through the wall (60% under the high) | the wall reserve filled to 1 wei over six runs; 4.59M tokens burned; the price never above the wall price |
| Pump +5,000 ticks, record, dump (one transaction) | record +500; round trip lost 0.572 ETH of 8.90 ETH pumped (642 bps: Auto Burn, sell tax, LP fee) |
| Pump 1,000 ticks over the reference before a run | no buyback; 0.0675 ETH budget held for the next run |

## What the tests do not show

- **JIT liquidity defeats the floor** (`test_attack_jitLiquidityAroundEachRecordPassesTheFloor`). Whoever can pull the
  pool's liquidity can add a position around each record and remove it after, so a thin pool reads deep and moves for
  dust. This is the Oracle Recorder's S2-1 in this engine. Only the clamp and the rise cap bound the high then. The
  engine belongs on pools whose liquidity is locked (Launcher principal lock), with the rise cap on.
- **An attacker who owns every record for a window can lift the high.** Each record costs a paid round trip (642 bps of
  the pump on the fork pool), and 24 pumped records over two hours lifted it
  the full 5,000 ticks (local suite). The rise cap bounds it.
  Records come at most every interval, so an attacker needs to win one record per interval. The recorder makes them
  hold the price every second (COMPARISON.md).
- **A real move registers slowly.** At 500 ticks a record every 5 minutes, an 8x rally (21,115 ticks) took 43 records. Tiers and the
  high lag the price by that much; buybacks wait (the price is over the reference) and the wall is unaffected (it reads
  spot against its own fixed price).
- **The wall fills only when someone runs the engine.** It is a limit buy, not a resting liquidity position: it pays the
  swap fees instead of earning them, and keeper latency is its fill latency.
- **Size.** 27,605 bytes of runtime. Fine on 4663 (98,304-byte limit), over EIP-170 (24,576) for Ethereum or Monad.
- Not run: a pool with arb recapture on (the lane gas floor applies to the engine's own buys there), a native-quote pool
  in local tests (the fork covers native ETH), MARKET_CAP or epochs on the fork, an independent review.

## Next steps (OPERATING_PROCEDURES 5.1)

Review package (design, threat model, invariants) to `hookr-modular-hooks`; fork rehearsal evidence under
`contracts/release-evidence/<lane>/` in the app repo; a release plan; a canary. Each waits on Nodar.
