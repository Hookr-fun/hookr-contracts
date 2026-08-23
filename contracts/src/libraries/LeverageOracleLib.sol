// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title LeverageOracleLib
/// @notice A tick observation ring the hook writes on every swap, and the bounded walk that
///         turns it into a time-weighted average.
///
///         v4 gives a hook no TWAP for free, so the market keeps its own. Two constants
///         govern it and they are NOT independent: a window of `WINDOW_SEC` sampled no more
///         often than `MIN_SPACING_SEC` needs `WINDOW_SEC / MIN_SPACING_SEC` slots to cover,
///         and a walk shorter than that can never reach the far end of the window.
///
///         An earlier draft of this design set a 900s window, 45s spacing and an 8-step walk.
///         Twenty slots are needed; eight reach 360s; the walk fails on every pool that
///         actually trades, which is every pool this is for. `MAX_WALK` is now derived from
///         the other two rather than chosen, and `test_walkCoversWindow` fails if anyone
///         edits one of the three without the others.
library LeverageOracleLib {
    /// @dev Averaging window. Long enough that moving it costs real capital for real time.
    uint32 internal constant WINDOW_SEC = 900;
    /// @dev Minimum gap between stored observations, so one block cannot fill the ring.
    uint32 internal constant MIN_SPACING_SEC = 45;
    /// @dev Steps needed to cover the window, plus one so the walk can straddle its far edge.
    uint32 internal constant MAX_WALK = WINDOW_SEC / MIN_SPACING_SEC + 1;
    /// @dev Ring size. Two windows of headroom, so a quiet market keeps usable history.
    uint16 internal constant CARDINALITY = 64;

    /// @dev No `tick` field. Once the accumulator below became the source of truth, a per-slot
    ///      tick was written on every observation and read by nothing — and reading it was
    ///      precisely the bug: it is the tick as of the slot's own timestamp, not the tick that
    ///      stood over any interval the average is measured across.
    struct Observation {
        uint32 timestamp;
        /// Snapshot of `Ring.cumulative` as of `timestamp`.
        int56 tickCumulative;
        bool set;
    }

    struct Ring {
        Observation[CARDINALITY] obs;
        uint16 index;
        /// Clock of the accumulator below — advanced by EVERY swap, not just stored ones.
        uint32 lastTs;
        /// Running tick-seconds up to `lastTs`. The ring slots sample this; they do not define it.
        int56 cumulative;
    }

    /// @notice Seeds slot zero. Called once, at pool initialize.
    /// @dev Takes no tick. The accumulator starts at zero from this instant, and every interval
    ///      after it is credited by `write` with the tick that actually stood over that interval,
    ///      so the price at the seed moment is never weighted by anything.
    function seed(Ring storage ring, uint32 nowSec) internal {
        ring.obs[0] = Observation({timestamp: nowSec, tickCumulative: 0, set: true});
        ring.index = 0;
        ring.lastTs = nowSec;
        ring.cumulative = 0;
    }

    /// @notice Advances the accumulator on every swap, and samples it into a ring slot at most
    ///         once per MIN_SPACING_SEC.
    /// @dev The rate limit applies to the SLOT, never to the accumulator. It exists so one block
    ///      cannot fill the ring — not so 44 seconds of history may be thrown away.
    ///
    ///      Skipping the accumulator too is what made the window purchasable. `tick` is the
    ///      pre-swap tick, which is exactly the tick that stood over [lastTs, nowSec], so
    ///      crediting that interval here is the whole of the price history and costs the caller
    ///      nothing it did not already pay for. Crediting it instead at the NEXT stored slot,
    ///      weighted by that slot's own tick, let a trader choose the number: dump at
    ///      lastWrite+44 (this returned early, so the dump was never recorded), buy back at
    ///      lastWrite+45 (the dumped tick was stamped into the head and the buy restored spot in
    ///      the same transaction). One second of real displacement bought 45 seconds of window
    ///      weight. Twenty-four such cycles displaced 2.2% of the window and dragged the
    ///      reported average to 0.6736 against a spot of 1.0648 and an honest average of 1.0307,
    ///      with `stale` false throughout — 1.84 ETH of round-trip fees in a ~50 ETH pool, zero
    ///      net tokens. A solvent 2x position whose real health was 1.809 read 0.846 and was
    ///      force-closed for 98% of its collateral.
    ///
    ///      With the interval credited here, a same-block round trip contributes exactly zero
    ///      seconds of weight and a k-second displacement contributes exactly k.
    function write(Ring storage ring, int24 tick, uint32 nowSec) internal {
        Observation memory last = ring.obs[ring.index];
        if (!last.set) {
            seed(ring, nowSec);
            return;
        }

        ring.cumulative += int56(tick) * int56(uint56(nowSec - ring.lastTs));
        ring.lastTs = nowSec;

        if (nowSec < last.timestamp + MIN_SPACING_SEC) return;

        uint16 next = (ring.index + 1) % CARDINALITY;
        ring.obs[next] = Observation({timestamp: nowSec, tickCumulative: ring.cumulative, set: true});
        ring.index = next;
    }

    /// @notice Mean tick across the default `WINDOW_SEC` window, and whether it was covered.
    /// @dev Thin wrapper over `meanTickOver` — every existing caller (the 900s protection
    ///      band) keeps this exact signature, and windows other than the default go through
    ///      `meanTickOver` explicitly rather than adding more constants to reason about here.
    function meanTick(Ring storage ring, uint32 nowSec, int24 currentTick)
        internal
        view
        returns (int24 tick, bool covered)
    {
        return meanTickOver(ring, nowSec, currentTick, WINDOW_SEC, MAX_WALK);
    }

    /// @notice Mean tick across an ARBITRARY trailing window, read from the SAME ring the
    ///         900s average is read from — no separate accumulator, no separate storage.
    /// @dev `write` already records every interval at the tick that stood over it, so the ring
    ///      is a genuine history, not just a rolling 900s buffer; any window inside it can be
    ///      queried directly. `maxWalk` must be `windowSec / MIN_SPACING_SEC + 1`, exactly as
    ///      `MAX_WALK` is derived for the default window — the caller supplies it explicitly
    ///      because a `pure` derivation inside a `view` function would recompute it on every
    ///      call for no reason, but it is not a free parameter: get it wrong and the walk
    ///      either wastes gas overshooting or, worse, quietly reports covered when it is not.
    /// @dev `covered` is false rather than reverting, and the caller decides what a market
    ///      with too little history is allowed to do. A young pool is not a broken pool — it
    ///      is a pool that may not be lent against yet.
    /// @param currentTick The pool's live slot0 tick, which the caller already has.
    /// @dev The trailing stub [lastTs, nowSec] is extrapolated with `currentTick` rather than
    ///      with the head observation's stored tick. Using the stored tick was the second half
    ///      of the capture described on `write`: even with the accumulator advanced correctly,
    ///      a head written at a displaced tick would go on describing the stub for up to
    ///      MIN_SPACING_SEC after spot had already been restored. Reading the live tick makes
    ///      the stub describe the price that is actually standing right now, which no completed
    ///      round trip can leave behind.
    function meanTickOver(Ring storage ring, uint32 nowSec, int24 currentTick, uint32 windowSec, uint256 maxWalk)
        internal
        view
        returns (int24 tick, bool covered)
    {
        Observation memory head = ring.obs[ring.index];
        if (!head.set) return (0, false);

        int56 nowCumulative = ring.cumulative + int56(currentTick) * int56(uint56(nowSec - ring.lastTs));
        uint32 target = nowSec > windowSec ? nowSec - windowSec : 0;

        uint16 i = ring.index;
        Observation memory found = head;
        for (uint256 step = 0; step < maxWalk; step++) {
            uint16 prev = (i + CARDINALITY - 1) % CARDINALITY;
            Observation memory o = ring.obs[prev];
            if (!o.set || o.timestamp > found.timestamp) break; // unwritten slot, or wrapped
            found = o;
            i = prev;
            if (o.timestamp <= target) break;
        }

        // Coverage is a property of the observation the average is measured FROM, not of how
        // the walk ended. Deciding it only inside the loop meant a pool whose single seeded
        // observation already predates the window — a market nobody has traded since it was
        // created — reported uncovered forever, because the walk broke on the unwritten slot
        // behind the seed before it could look at the seed itself. `isProtected` then returned
        // true permanently, wedging deposit and openPosition shut with no way to reopen them
        // except a swap from someone with no reason to make one. An observation older than the
        // window is the strongest possible history: nothing has moved the price since.
        covered = found.timestamp <= target;

        uint32 span = nowSec - found.timestamp;
        if (span == 0) return (currentTick, false);
        tick = int24((nowCumulative - found.tickCumulative) / int56(uint56(span)));
        // A walk that ran out of steps still produces an average — it just describes a
        // shorter window than asked for, so the caller is told it is not covered.
    }
}
