// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Hookr market band
/// @notice An oracle price band for a Hookr pool: refuse a swap that leaves the band (circuit breaker), or surcharge
///         it from a simulated move priced before the swap, and guard the quote depth toward the band edge. Any Hookr
///         advisory that owns a pool's advisory slot can embed it next to its own advice.
/// @dev Checks over a frozen Band plus one bounded read of an external price feed (Chainlink-style
///      `latestRoundData()`) and the PoolManager's `slot0`, liquidity and initialized ticks. The simulated move and
///      the quote depth walk the pool's initialized ticks, as a v4 swap does, so a narrow position around the price
///      counts only over its own range; each walk reads at most MAX_STEPS bitmap words. Every read is a view, so the band
///      works under the root's STATICCALL. A failed or stale feed read returns `ok = false`; the embedding advisory
///      reverts, so a fail-closed pool refuses the swap and a fail-open pool is charged its admitted cap. The caller
///      clamps nothing: `beforeSwap` already applies the frozen surcharge limits.
library HookrMarketBand {
    using StateLibrary for IPoolManager;

    /// @notice Per-pool knobs, supplied at bind and frozen.
    /// @param mode REFUSE or SURCHARGE.
    /// @param flags INVERT or zero.
    /// @param bandBps Band half-width: the edges are the reference times and divided by (1 + bandBps / 10,000).
    /// @param rampBps SURCHARGE: excursion beyond the edge at which the full surcharge applies.
    /// @param staleness Largest age of the feed's answer, in seconds.
    /// @param surchargePips SURCHARGE: the full surcharge, in pips of the swap input. Zero in REFUSE.
    /// @param minDepth Smallest quote the active range may hold toward the band edge, raw quote units. Zero is off. An
    ///        arb recapture leg is not held to it.
    struct Knobs {
        uint8 mode;
        uint8 flags;
        uint16 bandBps;
        uint16 rampBps;
        uint32 staleness;
        uint24 surchargePips;
        uint128 minDepth;
    }

    /// @notice A pool's frozen band. Three storage slots, all read on the swap path.
    /// @param feed The admitted price feed.
    /// @param bits BOUND, REFUSING, NEGATE and QUOTE_IS_0.
    /// @param numExp Scale: the feed ratio is answer * 10^numExp / 10^denExp in raw units.
    /// @param denExp See numExp.
    /// @param bandTicks Band half-width in ticks.
    /// @param rampTicks SURCHARGE ramp in ticks.
    /// @param staleness Largest answer age, seconds.
    /// @param codeHash The feed's runtime code hash at bind.
    /// @param minDepth Smallest quote depth toward the edge, raw quote units; zero is off. At most MAX_MIN_DEPTH.
    /// @param surchargePips The full surcharge before the limits.
    /// @param limit Largest surcharge once the Rules launch guard has ended.
    /// @param guardLimit Largest surcharge while the Rules launch guard lasts.
    /// @param guardEnd Rules launch guard end, on the block.number clock, saturated at 2^32 - 1.
    /// @param tickSpacing The pool's tick spacing, for the walks over its initialized ticks.
    /// @param buyReserveBps SURCHARGE: the largest share of an exact-output buy the root adds to the swapped output
    ///        (the Rules burn), in bps. The walk swaps the specified amount grossed up by it.
    /// @param sellReserveBps SURCHARGE: the same for an exact-output sell (the Rules quote take), in bps, rounded up.
    struct Band {
        address feed;
        uint8 bits;
        uint8 numExp;
        uint8 denExp;
        uint24 bandTicks;
        uint24 rampTicks;
        uint24 staleness;
        bytes32 codeHash;
        uint104 minDepth;
        uint24 surchargePips;
        uint24 limit;
        uint24 guardLimit;
        uint32 guardEnd;
        int16 tickSpacing;
        uint16 buyReserveBps;
        uint16 sellReserveBps;
    }

    /// @notice Mode: refuse any swap that leaves the band; fail-closed pools only.
    uint8 internal constant REFUSE = 1;
    /// @notice Mode: surcharge a swap by its simulated excursion beyond the band.
    uint8 internal constant SURCHARGE = 2;
    /// @notice Knob flag: the feed prices the quote in units of the subject instead of the subject in the quote.
    uint8 internal constant INVERT = 1;

    /// @notice Band bit: the band is bound.
    uint8 internal constant BOUND = 1;
    /// @notice Band bit: REFUSE mode.
    uint8 internal constant REFUSING = 2;
    /// @notice Band bit: the feed's asset A is currency1, so the reference tick is negated.
    uint8 internal constant NEGATE = 4;
    /// @notice Band bit: the pool's quote is currency0.
    uint8 internal constant QUOTE_IS_0 = 8;
    /// @notice Band bit: a recapture lane pool. A swap by its frozen lane executor is an arb recapture leg: never
    ///         surcharged, and refused when it ends beyond the edge it moved toward, checked exactly after its swap.
    uint8 internal constant LANE = 16;

    uint16 internal constant MIN_BAND_BPS = 50;
    uint16 internal constant MAX_BAND_BPS = 5_000;
    uint16 internal constant DEFAULT_BAND_BPS = 1_000;
    uint16 internal constant MIN_RAMP_BPS = 50;
    uint16 internal constant MAX_RAMP_BPS = 5_000;
    uint16 internal constant DEFAULT_RAMP_BPS = 1_000;
    uint32 internal constant MIN_STALENESS = 60;
    /// @dev Covers a stock feed's longest regular quiet period on 4663, a holiday weekend (76.2 h, Labor Day 2026).
    uint32 internal constant MAX_STALENESS = 4 days;
    /// @dev Covers ETH/USD's 24-hour heartbeat on 4663 with an hour of slack (one heartbeat gap measured 86,427 s).
    uint32 internal constant DEFAULT_STALENESS = 25 hours;
    uint128 internal constant MIN_MIN_DEPTH = 0;
    uint128 internal constant MAX_MIN_DEPTH = 1e30;
    uint128 internal constant DEFAULT_MIN_DEPTH = 0;
    uint24 internal constant MIN_SURCHARGE_PIPS = 1;
    uint24 internal constant MAX_SURCHARGE_PIPS = 100_000;
    uint24 internal constant DEFAULT_SURCHARGE_PIPS = 10_000;
    uint8 internal constant DEFAULT_MODE = REFUSE;
    /// @notice Largest decimals of a feed or a token.
    uint8 internal constant MAX_DECIMALS = 36;

    /// @notice Most steps one walk over the pool's ticks takes; each reads one bitmap word and at most one tick. A walk
    ///         that runs out prices the rest of the swap at the worst case: the full surcharge, or no further depth.
    uint256 internal constant MAX_STEPS = 16;
    /// @notice Most bitmap words the widest in-band walk may span, checked at bind (`spanFits`), so running out of
    ///         steps takes more than MAX_STEPS - MAX_SPAN_WORDS initialized ticks on the path.
    uint256 internal constant MAX_SPAN_WORDS = 4;

    /// @notice Gas forwarded to the feed's `latestRoundData`.
    uint256 internal constant ORACLE_READ_GAS = 80_000;
    /// @notice ABI-encoded size of `abi.encode(address, Knobs)`, the bind data of an advisory that embeds nothing else.
    uint256 internal constant ENCODED_SIZE = 256;

    /// @dev Phase bits, as HookrTypes.
    uint8 private constant BEFORE_SWAP = 1;
    uint8 private constant AFTER_SWAP = 2;
    uint256 private constant ROUND_DATA_SIZE = 160;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant BPS = 10_000;

    /// @notice Returns the first failed rule, or zero when the knobs are valid.
    /// @dev Codes: 1 unknown mode, 2 unknown flag, 3 band out of range, 4 ramp out of range, 5 staleness out of range,
    ///      6 minDepth above its maximum, 7 surcharge out of range for the mode or above `capPips`, 8 REFUSE on a
    ///      fail-open pool, 9 phases (REFUSE binds BEFORE and AFTER; SURCHARGE binds BEFORE, AFTER optional, and the
    ///      guard's bind requires AFTER on a recapture lane pool).
    function validate(Knobs memory k, bool failOpen, uint8 phases, uint256 capPips)
        internal
        pure
        returns (uint256 code)
    {
        if (k.mode != REFUSE && k.mode != SURCHARGE) return 1;
        if (k.flags & ~INVERT != 0) return 2;
        if (k.bandBps < MIN_BAND_BPS || k.bandBps > MAX_BAND_BPS) return 3;
        if (k.rampBps < MIN_RAMP_BPS || k.rampBps > MAX_RAMP_BPS) return 4;
        if (k.staleness < MIN_STALENESS || k.staleness > MAX_STALENESS) return 5;
        if (k.minDepth > MAX_MIN_DEPTH) return 6;
        if (k.mode == REFUSE) {
            if (k.surchargePips != 0) return 7;
            if (failOpen) return 8;
            if (phases != (BEFORE_SWAP | AFTER_SWAP)) return 9;
        } else {
            if (k.surchargePips < MIN_SURCHARGE_PIPS || k.surchargePips > MAX_SURCHARGE_PIPS) return 7;
            if (k.surchargePips > capPips) return 7;
            if (phases & BEFORE_SWAP == 0 || phases & ~(BEFORE_SWAP | AFTER_SWAP) != 0) return 9;
        }
    }

    /// @notice Largest whole number of ticks t with 1.0001^t <= 1 + bps / 10,000.
    function bpsToTicks(uint256 bps) internal pure returns (uint24) {
        uint256 sqrtX96 = Math.sqrt(((BPS + bps) << 192) / BPS);
        return uint24(TickMath.getTickAtSqrtPrice(uint160(sqrtX96)));
    }

    /// @notice Whether a walk from anywhere in the band to one ramp past either edge spans at most MAX_SPAN_WORDS
    ///         bitmap words at `tickSpacing`.
    function spanFits(uint24 bandTicks, uint24 rampTicks, int24 tickSpacing) internal pure returns (bool) {
        if (tickSpacing <= 0) return false;
        uint256 span = 2 * uint256(bandTicks) + uint256(rampTicks);
        return span / (uint256(uint24(tickSpacing)) * 256) + 2 <= MAX_SPAN_WORDS;
    }

    /// @notice Freezes valid knobs into a Band.
    /// @param k Knobs that passed `validate`.
    /// @param feed The admitted feed.
    /// @param codeHash The feed's admitted code hash.
    /// @param feedDecimals The feed's admitted decimals.
    /// @param subjectDecimals Decimals of the pool's subject.
    /// @param quoteDecimals Decimals of the pool's quote.
    /// @param quoteIs0 Whether the quote is currency0.
    function freeze(
        Knobs memory k,
        address feed,
        bytes32 codeHash,
        uint8 feedDecimals,
        uint8 subjectDecimals,
        uint8 quoteDecimals,
        bool quoteIs0
    ) internal pure returns (Band memory b) {
        bool invert = k.flags & INVERT != 0;
        // The feed prices one unit of A in units of B.
        (uint8 decA, uint8 decB) = invert ? (quoteDecimals, subjectDecimals) : (subjectDecimals, quoteDecimals);
        // A is currency0 exactly when A is the subject and the quote is currency1, or A is the quote and is currency0.
        bool aIs0 = invert == quoteIs0;
        b.feed = feed;
        b.bits = BOUND | (k.mode == REFUSE ? REFUSING : 0) | (aIs0 ? 0 : NEGATE) | (quoteIs0 ? QUOTE_IS_0 : 0);
        b.numExp = decB;
        b.denExp = feedDecimals + decA;
        b.bandTicks = bpsToTicks(k.bandBps);
        b.rampTicks = bpsToTicks(k.rampBps);
        b.staleness = uint24(k.staleness);
        b.codeHash = codeHash;
        b.minDepth = uint104(k.minDepth);
        b.surchargePips = k.surchargePips;
    }

    /// @notice Reads the feed and returns the reference tick of the pool (currency1 per currency0, raw units).
    /// @dev `ok` is false when the feed's code changed, the call fails, runs out of its gas or returns anything but
    ///      five words, the answer is not in (0, 2^96), `updatedAt` is zero, in the future or older than the band's
    ///      staleness, or the scaled price is outside the PoolManager's range.
    function referenceTick(Band memory b) internal view returns (bool ok, int24 tick) {
        (bool read, uint256 answer) = readFeed(b.feed, b.codeHash, b.staleness);
        if (!read) return (false, 0);
        return scaledTick(answer, b.numExp, b.denExp, b.bits & NEGATE != 0);
    }

    /// @notice One bounded read of `latestRoundData()`; `answer` is valid only when `ok`.
    function readFeed(address feed, bytes32 codeHash, uint256 staleness)
        internal
        view
        returns (bool ok, uint256 answer)
    {
        if (feed.codehash != codeHash) return (false, 0);
        bytes memory output = new bytes(ROUND_DATA_SIZE);
        bytes4 selector = bytes4(keccak256("latestRoundData()"));
        uint256 updatedAt;
        assembly ("memory-safe") {
            let input := mload(0x40)
            mstore(input, selector)
            ok := staticcall(ORACLE_READ_GAS, feed, input, 4, add(output, 32), ROUND_DATA_SIZE)
            ok := and(ok, eq(returndatasize(), ROUND_DATA_SIZE))
            answer := mload(add(output, 64))
            updatedAt := mload(add(output, 128))
        }
        if (!ok) return (false, 0);
        // A negative int256 answer reads as a value above 2^255 and fails the range check.
        if (answer == 0 || answer >= 1 << 96) return (false, 0);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > staleness) {
            return (false, 0);
        }
    }

    /// @notice Tick of answer * 10^numExp / 10^denExp, negated when `negate`; `ok` is false outside the range.
    function scaledTick(uint256 answer, uint256 numExp, uint256 denExp, bool negate)
        internal
        pure
        returns (bool ok, int24 tick)
    {
        uint256 num = answer * 10 ** numExp;
        uint256 den = 10 ** denExp;
        uint256 whole = num / den;
        uint256 sqrtX96;
        if (whole < 1 << 64) {
            sqrtX96 = Math.sqrt(FullMath.mulDiv(num, 1 << 192, den));
        } else if (whole < 1 << 128) {
            sqrtX96 = Math.sqrt(FullMath.mulDiv(num, 1 << 64, den)) << 64;
        } else {
            return (false, 0);
        }
        if (sqrtX96 < TickMath.MIN_SQRT_PRICE || sqrtX96 >= TickMath.MAX_SQRT_PRICE) return (false, 0);
        tick = TickMath.getTickAtSqrtPrice(uint160(sqrtX96));
        if (negate) tick = -tick;
        ok = true;
    }

    /// @notice Before-swap advice for the swap on `id`.
    /// @param leg Whether the swap is an arb recapture leg: the pool is a LANE pool and the sender is its frozen lane
    ///        executor. A leg is never surcharged and walks nothing: it is refused here only from a price already
    ///        beyond the edge it moves toward, and its end is checked exactly after its swap (`afterSwap`), so a leg is
    ///        never decided on a walk that ran out of steps. minDepth does not apply to a leg.
    /// @return ok False when the feed read failed; the caller must revert.
    /// @return reject REFUSE: the price is already beyond the edge the swap moves toward, or the quote depth toward
    ///         that edge is below minDepth. A leg: the price is already beyond that edge. Never true for any other
    ///         SURCHARGE swap.
    /// @return surchargePips SURCHARGE, other than a leg: the ramped surcharge, clamped to the frozen limit of the
    ///         current block.
    function beforeSwap(
        Band memory b,
        IPoolManager manager,
        PoolId id,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bool leg
    ) internal view returns (bool ok, bool reject, uint256 surchargePips) {
        int24 ref;
        (ok, ref) = referenceTick(b);
        if (!ok) return (false, false, 0);
        (uint160 price, int24 tick,,) = manager.getSlot0(id);
        if (price == 0) return (false, false, 0);
        (int24 lower, int24 upper) = edges(ref, b.bandTicks);
        bool beyond = zeroForOne ? tick < lower : tick > upper;
        if (leg) return (true, beyond, 0);
        bool restorative = zeroForOne ? tick > upper : tick < lower;
        // A REFUSE swap is checked exactly after the swap, so before it only the depth is walked.
        bool refusing = b.bits & REFUSING != 0;
        bool shallow;
        uint128 liquidity;
        if (b.minDepth != 0 || !refusing) liquidity = manager.getLiquidity(id);
        if (b.minDepth != 0 && !beyond && !restorative) {
            uint256 depth = walkDepth(
                Walk(manager, id, b.tickSpacing, zeroForOne, price, tick, liquidity),
                TickMath.getSqrtPriceAtTick(zeroForOne ? lower : upper),
                b.bits & QUOTE_IS_0 != 0,
                b.minDepth
            );
            shallow = depth < b.minDepth;
        }
        if (refusing) return (true, beyond || shallow, 0);
        uint256 full = b.surchargePips;
        if (!shallow) {
            // The surcharge is the input-weighted excursion over the whole simulated path, so splitting a move pays what
            // the one swap pays.
            (uint256 num, uint256 den) = walkExcursion(
                Walk(manager, id, b.tickSpacing, zeroForOne, price, tick, liquidity),
                grossSpecified(b, zeroForOne, amountSpecified),
                sqrtPriceLimitX96,
                zeroForOne ? lower : upper,
                b.rampTicks
            );
            full = num == 0 ? 0 : FullMath.mulDivRoundingUp(full, num, den);
        }
        uint256 cap = block.number < b.guardEnd ? b.guardLimit : b.limit;
        surchargePips = full < cap ? full : cap;
    }

    /// @notice The amount the PoolManager swaps for a specified amount: an exact-output amount grossed up by the
    ///         reserve the root adds on top of it, `S + ceil(S * r / (10,000 - r))`. Exact input unchanged.
    function grossSpecified(Band memory b, bool zeroForOne, int256 amountSpecified) internal pure returns (int256) {
        if (amountSpecified <= 0) return amountSpecified;
        uint256 r = zeroForOne == (b.bits & QUOTE_IS_0 != 0) ? b.buyReserveBps : b.sellReserveBps;
        uint256 s = uint256(amountSpecified);
        if (r == 0) return amountSpecified;
        // An amount of 2^128, which the walk prices at the full surcharge, for a reserve of the whole output.
        if (s >= 1 << 128 || r >= BPS) return int256(1 << 128);
        return int256(s + (s * r + (BPS - r) - 1) / (BPS - r));
    }

    /// @notice After-swap check: whether the swap left the price beyond the edge it moved toward.
    /// @param leg Whether the swap is an arb recapture leg (see `beforeSwap`).
    /// @return ok False when the feed read failed; the caller must revert.
    /// @return reject REFUSE and a leg: the post-swap tick is beyond that edge. Never true for any other SURCHARGE swap.
    function afterSwap(Band memory b, IPoolManager manager, PoolId id, bool zeroForOne, bool leg)
        internal
        view
        returns (bool ok, bool reject)
    {
        if (!leg && b.bits & REFUSING == 0) return (true, false);
        int24 ref;
        (ok, ref) = referenceTick(b);
        if (!ok) return (false, false);
        (, int24 tick,,) = manager.getSlot0(id);
        (int24 lower, int24 upper) = edges(ref, b.bandTicks);
        reject = zeroForOne ? tick < lower : tick > upper;
    }

    /// @notice A walk's position: the pool, the direction, and the price, tick and liquidity so far.
    struct Walk {
        IPoolManager manager;
        PoolId id;
        int24 spacing;
        bool zeroForOne;
        uint160 price;
        int24 tick;
        uint128 liquidity;
    }

    /// @notice The price the swap reaches, crossing initialized ticks as a v4 swap does, at no fee, clamped to
    ///         `limit` and the price range.
    /// @dev Never reverts. A liquidity gap, an amount of at least 2^128 or a walk that runs out of MAX_STEPS reaches
    ///      the limit, the worst case for the surcharge. The fee is ignored, so an exact-input move is overestimated.
    function walkSwap(Walk memory w, int256 amountSpecified, uint160 limit) internal view returns (uint160) {
        uint160 lim = _clampLimit(w.zeroForOne, w.price, limit);
        uint256 a = amountSpecified < 0 ? uint256(-(amountSpecified + 1)) + 1 : uint256(amountSpecified);
        if (a >= 1 << 128) return lim;
        int256 remaining = amountSpecified;
        for (uint256 i; i < MAX_STEPS; ++i) {
            if (remaining == 0 || w.price == lim) return w.price;
            (int24 next, bool initialized, uint160 nextPrice) = _nextTick(w);
            uint160 target = w.zeroForOne ? (nextPrice < lim ? lim : nextPrice) : (nextPrice > lim ? lim : nextPrice);
            (uint160 reached, uint256 amountIn, uint256 amountOut,) =
                SwapMath.computeSwapStep(w.price, target, w.liquidity, remaining, 0);
            // Both amounts are below 2^128 here: each is bounded by the remaining amount's side of the step.
            remaining = remaining < 0 ? remaining + int256(amountIn) : remaining - int256(amountOut);
            if (reached == nextPrice) {
                _cross(w, next, initialized);
            } else if (reached != w.price) {
                w.tick = TickMath.getTickAtSqrtPrice(reached);
            }
            w.price = reached;
        }
        return remaining == 0 ? w.price : lim;
    }

    /// @notice The swap's input-weighted excursion beyond `edge`, walked as `walkSwap` walks, as a share `num / den` of
    ///         the full surcharge.
    /// @dev Each step's input is weighted by the mean of its start and end excursions (ticks beyond `edge`, capped at
    ///      `ramp`), so the share is the path integral of the ramp over the swap's input divided by that input. Steps
    ///      stop at `edge` and at one ramp past it, so no step straddles either. Splitting a move into several swaps
    ///      sums the same integral; the input a tick costs grows with the excursion, so a split pays at least what the
    ///      one swap pays. Past the ramp the walk goes on to the swap's limit, so input the limit (or the end of the
    ///      pool's liquidity) leaves unspent is never counted. An exact-input walk that runs out of MAX_STEPS
    ///      steps past the ramp weights its remaining input at the full ramp, an upper bound on what it spends. An
    ///      amount of at least 2^128, or any other walk that runs out of MAX_STEPS steps (the stops at the edge and the
    ///      ramp count) with input left before its limit, returns the full share (1 / 1). With no input at all (a
    ///      liquidity gap) the share is the end's excursion over the ramp. Never reverts.
    function walkExcursion(Walk memory w, int256 amountSpecified, uint160 limit, int24 edge, uint24 ramp)
        internal
        view
        returns (uint256 num, uint256 den)
    {
        bool z = w.zeroForOne;
        uint160 lim = _clampLimit(z, w.price, limit);
        if (amountSpecified <= -(1 << 128) || amountSpecified >= 1 << 128) return (1, 1);
        uint160 edgePrice = TickMath.getSqrtPriceAtTick(edge);
        uint160 rampPrice;
        {
            (int24 lo, int24 hi) = edges(edge, ramp);
            rampPrice = TickMath.getSqrtPriceAtTick(z ? lo : hi);
        }
        int256 remaining = amountSpecified;
        uint256 exc = _excursion(z, w.tick, edge, ramp);
        uint256 weighted;
        uint256 total;
        for (uint256 i; i < MAX_STEPS; ++i) {
            if (remaining == 0 || w.price == lim) return _share(weighted, total, exc, ramp);
            (int24 next, bool initialized, uint160 nextPrice) = _nextTick(w);
            uint160 target = z ? (nextPrice < lim ? lim : nextPrice) : (nextPrice > lim ? lim : nextPrice);
            uint160 bound = (z ? edgePrice < w.price : edgePrice > w.price) ? edgePrice : rampPrice;
            if (z ? bound < w.price && bound > target : bound > w.price && bound < target) target = bound;
            uint160 reached;
            uint256 amountIn;
            (reached, amountIn, remaining) = _step(w, target, remaining);
            if (amountIn >= 1 << 128) return (1, 1);
            if (reached == nextPrice) {
                _cross(w, next, initialized);
            } else if (reached != w.price) {
                w.tick = TickMath.getTickAtSqrtPrice(reached);
            }
            w.price = reached;
            // The end excursion reads the tick the price reached; after a downward crossing that is `next`.
            uint256 excEnd = _excursion(z, reached == nextPrice ? next : w.tick, edge, ramp);
            // At most MAX_STEPS terms, each input below 2^128 and each excursion below 2^24: no overflow.
            unchecked {
                weighted += amountIn * (exc + excEnd);
                total += amountIn;
            }
            exc = excEnd;
        }
        if (remaining == 0 || w.price == lim) return _share(weighted, total, exc, ramp);
        // Out of steps past the ramp with exact input left: the swap spends at most that input, all at the full
        // rate, so weighting the whole of it bounds the share from above without charging the full surcharge.
        if (remaining < 0 && exc == ramp) {
            uint256 rest = uint256(-remaining);
            return _share(weighted + rest * 2 * ramp, total + rest, exc, ramp);
        }
        return (1, 1);
    }

    /// @dev One fee-less swap step toward `target`: the price reached, the input and the amount left.
    function _step(Walk memory w, uint160 target, int256 remaining)
        private
        pure
        returns (uint160 reached, uint256 amountIn, int256 left)
    {
        uint256 amountOut;
        (reached, amountIn, amountOut,) = SwapMath.computeSwapStep(w.price, target, w.liquidity, remaining, 0);
        if (amountIn >= 1 << 128) return (reached, amountIn, remaining);
        left = remaining < 0 ? remaining + int256(amountIn) : remaining - int256(amountOut);
    }

    /// @dev The share of the full surcharge: the weighted input over the input times twice the ramp, or with no input
    ///      the end's excursion over the ramp.
    function _share(uint256 weighted, uint256 total, uint256 excEnd, uint24 ramp)
        private
        pure
        returns (uint256 num, uint256 den)
    {
        if (total == 0) return (excEnd, ramp);
        return (weighted, total * 2 * uint256(ramp));
    }

    /// @dev Ticks beyond `edge` in the direction of the move, capped at `ramp`; zero inside.
    function _excursion(bool zeroForOne, int24 tick, int24 edge, uint24 ramp) private pure returns (uint256) {
        int256 e = zeroForOne ? int256(edge) - tick : int256(tick) - edge;
        if (e <= 0) return 0;
        return uint256(e) < ramp ? uint256(e) : ramp;
    }

    /// @notice The quote the pool's liquidity holds between the price and `edge`, crossing initialized ticks.
    /// @dev Stops once `enough` is reached. A walk that runs out of MAX_STEPS counts nothing beyond where it stopped,
    ///      so the result never overstates the depth. Never reverts.
    function walkDepth(Walk memory w, uint160 edge, bool quoteIs0, uint256 enough)
        internal
        view
        returns (uint256 depth)
    {
        if (w.zeroForOne ? edge >= w.price : edge <= w.price) return 0;
        for (uint256 i; i < MAX_STEPS; ++i) {
            (int24 next, bool initialized, uint160 nextPrice) = _nextTick(w);
            bool last = w.zeroForOne ? nextPrice <= edge : nextPrice >= edge;
            uint160 end = last ? edge : nextPrice;
            depth += quoteDepth(w.price, w.liquidity, end, quoteIs0);
            if (last || depth >= enough) return depth;
            _cross(w, next, initialized);
            w.price = nextPrice;
        }
    }

    /// @dev The next initialized tick in the walk's direction within one bitmap word, or the word's last tick, as
    ///      v4's TickBitmap.nextInitializedTickWithinOneWord, clamped to the tick range, with its price.
    function _nextTick(Walk memory w) private view returns (int24 next, bool initialized, uint160 nextPrice) {
        int24 spacing = w.spacing;
        int24 compressed = TickBitmap.compress(w.tick, spacing);
        unchecked {
            if (w.zeroForOne) {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 masked =
                    w.manager.getTickBitmap(w.id, wordPos) & (type(uint256).max >> (uint256(type(uint8).max) - bitPos));
                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * spacing
                    : (compressed - int24(uint24(bitPos))) * spacing;
            } else {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(++compressed);
                uint256 masked = w.manager.getTickBitmap(w.id, wordPos) & ~((1 << bitPos) - 1);
                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * spacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * spacing;
            }
        }
        if (next < TickMath.MIN_TICK) next = TickMath.MIN_TICK;
        else if (next > TickMath.MAX_TICK) next = TickMath.MAX_TICK;
        nextPrice = TickMath.getSqrtPriceAtTick(next);
    }

    /// @dev Moves the walk across `next`: applies the tick's net liquidity when it is initialized, saturating at the
    ///      uint128 range instead of reverting.
    function _cross(Walk memory w, int24 next, bool initialized) private view {
        if (initialized) {
            (, int128 net) = w.manager.getTickLiquidity(w.id, next);
            int256 delta = w.zeroForOne ? -int256(net) : int256(net);
            int256 l = int256(uint256(w.liquidity)) + delta;
            w.liquidity = l < 0 ? 0 : l > int256(uint256(type(uint128).max)) ? type(uint128).max : uint128(uint256(l));
        }
        w.tick = w.zeroForOne ? next - 1 : next;
    }

    /// @dev The swap's limit clamped to the price range and to the side of `price` the swap moves toward.
    function _clampLimit(bool zeroForOne, uint160 price, uint160 limit) private pure returns (uint160) {
        uint256 lim = limit;
        if (zeroForOne) {
            if (lim < TickMath.MIN_SQRT_PRICE) lim = TickMath.MIN_SQRT_PRICE;
            if (lim > price) lim = price;
        } else {
            if (lim >= TickMath.MAX_SQRT_PRICE) lim = TickMath.MAX_SQRT_PRICE - 1;
            if (lim < price) lim = price;
        }
        return uint160(lim);
    }

    /// @notice The band edges around `ref`, clamped to the tick range.
    function edges(int24 ref, uint24 bandTicks) internal pure returns (int24 lower, int24 upper) {
        int256 lo = int256(ref) - int256(uint256(bandTicks));
        int256 hi = int256(ref) + int256(uint256(bandTicks));
        lower = lo < TickMath.MIN_TICK ? TickMath.MIN_TICK : int24(lo);
        upper = hi > TickMath.MAX_TICK ? TickMath.MAX_TICK : int24(hi);
    }

    /// @notice The quote amount the active liquidity holds between `price` and `edge`.
    /// @dev Never reverts for prices in the PoolManager's range and liquidity below 2^128: each product is divided
    ///      before it could overflow. Rounds down.
    function quoteDepth(uint160 price, uint128 liquidity, uint160 edge, bool quoteIs0) internal pure returns (uint256) {
        (uint256 lo, uint256 hi) = price < edge ? (uint256(price), uint256(edge)) : (uint256(edge), uint256(price));
        uint256 diff = hi - lo;
        if (!quoteIs0) return FullMath.mulDiv(liquidity, diff, Q96);
        // amount0 = L * Q96 * (hi - lo) / hi / lo, as v4's getAmount0Delta: diff < hi keeps the first quotient below
        // L * Q96 < 2^224.
        return FullMath.mulDiv(uint256(liquidity) << 96, diff, hi) / lo;
    }

    /// @notice The price the swap reaches on the active range alone, clamped to its limit and the price range.
    /// @dev Ignores tick crossings, so it is not used on the swap path (see `walkSwap`); kept as the single-range
    ///      reference the math tests pin. Never reverts. A zero liquidity or
    ///      an amount of at least 2^128 reaches the limit.
    function simulate(uint160 price, uint128 liquidity, bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        pure
        returns (uint160)
    {
        uint256 lim = limit;
        if (zeroForOne) {
            if (lim < TickMath.MIN_SQRT_PRICE) lim = TickMath.MIN_SQRT_PRICE;
            if (lim > price) lim = price;
        } else {
            if (lim >= TickMath.MAX_SQRT_PRICE) lim = TickMath.MAX_SQRT_PRICE - 1;
            if (lim < price) lim = price;
        }
        uint256 a = amountSpecified < 0 ? uint256(-(amountSpecified + 1)) + 1 : uint256(amountSpecified);
        if (liquidity == 0 || a >= 1 << 128) return uint160(lim);
        uint256 p = price;
        uint256 l = liquidity;
        uint256 next;
        if (zeroForOne) {
            if (amountSpecified < 0) {
                // Currency0 in: L * P / (L + a * P / Q96).
                next = FullMath.mulDiv(l, p, l + FullMath.mulDiv(a, p, Q96));
            } else {
                // Currency1 out: P - a * Q96 / L.
                uint256 d = FullMath.mulDiv(a, Q96, l);
                next = d >= p ? 0 : p - d;
            }
            if (next < lim) next = lim;
        } else {
            if (amountSpecified < 0) {
                // Currency1 in: P + a * Q96 / L.
                next = p + FullMath.mulDiv(a, Q96, l);
            } else {
                // Currency0 out: L * P / (L - a * P / Q96); past the range's reserves it reaches the limit. When
                // L - d <= L >> 96 the ratio is at least 2^96, beyond any limit, and the division could overflow.
                uint256 d = FullMath.mulDiv(a, p, Q96);
                next = d >= l || l - d <= l >> 96 ? type(uint256).max : FullMath.mulDiv(l, p, l - d);
            }
            if (next > lim) next = lim;
        }
        return uint160(next);
    }
}
