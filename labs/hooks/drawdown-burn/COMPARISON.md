# Oracle-less engine vs the Oracle Recorder version

Two ways to give Ika's drawdown burn its hourly price. Spec v0 (2026-10-17) defaulted to the Oracle Recorder; this lab is
the version without it. Figures for this lab are from its tests and the 4663 fork run (README.md, `fork-run.log`);
figures for the recorder are from spec v0 and the recorder lab at `b3cca505b` (`labs/hooks/oracle-recorder`, app repo).

| | Oracle-less (this lab) | With the Oracle Recorder |
|---|---|---|
| **Where the price comes from** | The engine's own records: anyone writes the pool's spot at most once per 5 min, each clamped to 500 ticks from the last, refused inside an unlock | A Rules core that writes the pool's price on swaps, once per second, crediting at most 100 ticks a second |
| **What it needs on chain** | Nothing new: any pool on the live root with Auto Burn + Tax + Conversion. Proven on a fork: a pool launched through the live Launcher, tax collected from the live queue, buybacks through the live root | Pools launched on the recorder's own core, which is not deployed: the recorder and Treasury Buyback were kept out of the live set on 10-06 (`HOOKR_1_KEPT_OUT`). Its G3 attack round at `d47c522b7` found nothing in the module; S2-1 stays a pinned limitation |
| **Gas paid by traders** | 0 per swap | 20,650 per swap (prefilled slot), 37,812 (new slot), 5,660 (later swap in the same second) |
| **Gas paid by keepers** | `checkpoint()` 63,138 on the fork pool (31,033 to 154,925 locally, median 79,727); a record every 5 min is ~23.0M gas a day, ~0.00046 ETH at 0.02008 gwei. `run()` 371,881 on the fork with collect and buyback | A mean read ≤ 92,412 (120,000 budgeted) inside each run; no records to pay for |
| **One-block pump or dump** | Moves one record by at most 500 ticks; that record weighs nothing until time passes; the high needs every record of a full hour above it; tiers and the buyback read a 15-min mean. Fork: a +5,000-tick pump recorded +500, cost 642 bps of the ETH pumped | Barely moves an hourly mean (100 ticks a second at most) |
| **Sustained manipulation** | The attacker needs to win one record per interval (12 an hour), each a paid round trip (642 bps of the pump on the fork pool). On a plain 0.30% pool, 24 pumped records over two hours lifted the high 5,000 ticks with no cap; a 5%/h rise cap held it to ~940 | The attacker has to hold the price every second, or win every second's first swap, against arbitrage. Stronger on a pool others trade |
| **Quiet pool, nobody trading** | Weak: the attacker's records are the only ones | Weak too: one held push is recorded truthfully as the price (recorder finding F1) |
| **Liquidity owner** | JIT liquidity around a record passes the liquidity floor; a thin pool then moves for dust (pinned test). Same as the recorder's S2-1 | S2-1 (medium, open): JIT liquidity at a span's two writes inflates its depth figure; OR-G1 liquidity-owner finding |
| **Defenses both need** | Locked pool liquidity (Launcher principal lock); the per-hour rise cap; the spend cap; a buyback price limit from the mean, not spot | The same, plus a maximum read age (300 s recommended, D4) and a reference pool that is arbitraged |
| **Response to a real move** | Lags: 500 ticks a record, so an 8x rally took 43 records (3.6 h) to register | Follows within the window (100 ticks a second) |

**In one line:** the recorder version is harder to push on an actively traded pool and follows real moves faster, but it
costs every trader gas on every swap and needs a core that is not deployed. The oracle-less version runs on the
pools that exist today and costs traders nothing; its weak spot is that an attacker can buy one record per interval,
which the clamp, the hour-long window, the rise cap and the spend cap bound but do not remove.

## What Nodar decides

1. **Which version.** Default: oracle-less now, on pools of the live root; the recorder version only if the recorder's
   core is deployed.
2. **The rise cap's default.** Off is Ika's design (the high follows any held level). Default proposed: on, at 10% an
   hour: the clamp, the window and the spend cap slow an attacker who owns every record, and the rise cap is what limits
   how far the high can go.
3. **Locked liquidity as a condition.** Default: the engine is offered only for pools whose launch principal is locked
   for at least the engine's life; `minLiquidity` set to a share of the locked liquidity.
4. **Clamp and interval.** Default 500 ticks per 5 min. Wider follows real moves faster and lets one record move more.
5. **Decision 9, Ika's co-author share.** The engine pays `coAuthorBps` (0 to 20%) of everything it spends to a frozen
   address. Left at 0 until Nodar sets it. The usage fee rail cannot sit beside Tax + Conversion (one advisory per pool).
6. **Reference.** Default PRICE. Ika's post uses market cap, which deepens its own drawdown as it burns.
7. **The wall.** Default: the engine's own limit-buy wall (RESERVE). Alternative: pay a Floor bid vault (SINK) once Floor
   bid is live; Floor bid anchors to the current price, not the high, and does not burn its fills.
8. **RHUB's pool.** RHUB is on Arbitrum; Hook Blocks run only on Robinhood Chain pools. Nothing runs for Ika until RHUB
   (or a token he picks) has a Hookr pool on 4663.
