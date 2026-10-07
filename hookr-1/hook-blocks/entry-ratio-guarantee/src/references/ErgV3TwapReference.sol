// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IErgPriceReference} from "../interfaces/IErgPriceReference.sol";
import {IV3ObservationSource} from "../interfaces/IV3ObservationSource.sol";

/// @title ErgV3TwapReference
/// @notice A price reference: the time-weighted tick of one Uniswap v3 pool on the same pair over a long window, refused
///         while a short window disagrees with it. Bound to one v4 currency pair at construction.
/// @dev v3 writes an observation at the first swap of each block with the tick that held before it, so a price
///      pushed and restored inside one transaction does not move either window; moving the reference needs the
///      manipulated price held across blocks, exposed to arbitrage. The answer is the long window's floored mean
///      tick. The short window is a breaker: while the two windows disagree by more than `maxDivergenceTicks` the
///      reference refuses, so a fast move closes deposits until the long window catches up.
///      Declared tolerance (`errorTicks`, `errorSqrtPips`). Fair is the short-window mean the source would have shown
///      without manipulation (`s0`). The model is an attacker who changes the source's path over no more than the
///      last `shortWindow` seconds, starting from any state in which the reference would answer: the honest means
///      `s0` and `l0` satisfy `|s0 - l0| < D + 1`, with `D = maxDivergenceTicks`. Such a change adds the same
///      tick-seconds `A` to both windows, so the answer's mean moves by `A / long` and the gap by
///      `A * (long - short) / (short * long)`. The gap check before and after gives
///      `|A| * (long - short) / (short * long) < 2 * (D + 1)`, so the answer's mean sits less than
///      `(D + 1) + 2 * (D + 1) * short / (long - short) = (D + 1) * (long + short) / (long - short)` ticks from fair,
///      and flooring adds less than one tick. `errorTicks` is `ceil((D + 1) * (long + short) / (long - short)) + 1`,
///      capped at the largest v4 tick, and `errorSqrtPips` its sqrt-price distance rounded up. Answering the short
///      window instead would allow about twice that, because an attacker who waits for a genuine gap and pushes
///      against it moves the short window by the whole push.
///      Not covered by the declaration: a source held off for longer than the short window; a genuine move larger
///      than the divergence bound, which an attacker could make the reference answer by pushing the source back
///      toward the stale long window; and fair itself trailing the market inside the short window. Each costs the
///      attacker the hold against arbitrage, and the pool's draw cap bounds what one exit can take.
///      Native currency0 maps to `wrappedNative`; only a pair whose two assets have equal decimals on both sides
///      (ETH and WETH) is supported, which the mapping guarantees.
contract ErgV3TwapReference is IErgPriceReference {
    /// @notice The v3 pool read.
    IV3ObservationSource public immutable source;
    /// @notice v4 currency0 this reference serves.
    address public immutable currency0;
    /// @notice v4 currency1 this reference serves.
    address public immutable currency1;
    /// @notice True when the v3 pool sorts the pair the other way (its tick is negated).
    bool public immutable invert;
    /// @notice Short TWAP window in seconds; used only for the agreement check.
    uint32 public immutable shortWindow;
    /// @notice Long TWAP window in seconds; its tick is returned.
    uint32 public immutable longWindow;
    /// @notice Largest allowed difference between the two windows' ticks.
    int24 public immutable maxDivergenceTicks;
    /// @notice Declared tolerance in ticks:
    ///         `ceil((maxDivergenceTicks + 1) * (longWindow + shortWindow) / (longWindow - shortWindow)) + 1`, capped at
    ///         the largest v4 tick.
    uint24 public immutable errorTicks;
    /// @inheritdoc IErgPriceReference
    uint24 public immutable errorSqrtPips;

    /// @notice Thrown when the v3 pool does not trade the v4 pair.
    error PairMismatch();
    /// @notice Thrown for a zero or inverted window pair or a negative divergence bound.
    error InvalidWindows();
    /// @notice Thrown when the key is not the bound pair.
    error WrongPair();
    /// @notice Thrown when the two windows disagree by more than the bound.
    /// @param shortTick The short-window tick
    /// @param longTick The long-window tick
    error ReferenceUnstable(int24 shortTick, int24 longTick);

    /// @param source_ The v3 pool
    /// @param currency0_ v4 currency0 (zero for native ETH)
    /// @param currency1_ v4 currency1
    /// @param wrappedNative The ERC20 the v3 pool uses for native ETH
    /// @param shortWindow_ Short window in seconds
    /// @param longWindow_ Long window in seconds, above the short window
    /// @param maxDivergenceTicks_ Largest allowed tick difference between the windows
    constructor(
        IV3ObservationSource source_,
        address currency0_,
        address currency1_,
        address wrappedNative,
        uint32 shortWindow_,
        uint32 longWindow_,
        int24 maxDivergenceTicks_
    ) {
        if (shortWindow_ == 0 || longWindow_ <= shortWindow_ || maxDivergenceTicks_ < 0) {
            revert InvalidWindows();
        }
        address a = currency0_ == address(0) ? wrappedNative : currency0_;
        address b = currency1_;
        address t0 = source_.token0();
        address t1 = source_.token1();
        bool inv;
        if (t0 == a && t1 == b) inv = false;
        else if (t0 == b && t1 == a) inv = true;
        else revert PairMismatch();
        source = source_;
        currency0 = currency0_;
        currency1 = currency1_;
        invert = inv;
        shortWindow = shortWindow_;
        longWindow = longWindow_;
        maxDivergenceTicks = maxDivergenceTicks_;
        uint256 span = longWindow_ - shortWindow_;
        uint256 ticks =
            ((uint256(uint24(maxDivergenceTicks_)) + 1) * (uint256(longWindow_) + shortWindow_) + span - 1) / span + 1;
        uint256 maxTick = uint256(uint24(TickMath.MAX_TICK));
        if (ticks > maxTick) ticks = maxTick;
        errorTicks = uint24(ticks);
        errorSqrtPips = _sqrtPips(int24(uint24(ticks)));
    }

    /// @dev `ceil((sqrt(1.0001 ^ ticks) - 1) * 1e6)`, capped at the uint24 maximum. TickMath rounds the sqrt price up.
    function _sqrtPips(int24 ticks) private pure returns (uint24) {
        uint256 q = uint256(1) << 96;
        uint256 pips = ((uint256(TickMath.getSqrtPriceAtTick(ticks)) - q) * 1_000_000 + q - 1) / q;
        return pips > type(uint24).max ? type(uint24).max : uint24(pips);
    }

    /// @inheritdoc IErgPriceReference
    function referenceSqrtPriceX96(PoolKey calldata key) external view returns (uint160) {
        (, int24 longTick) = _stableTicks(key);
        return TickMath.getSqrtPriceAtTick(longTick);
    }

    /// @inheritdoc IErgPriceReference
    /// @dev The short window's floored mean tick, under the same pair check and breaker as the answer. After a
    ///      genuine move the long window trails the market by up to `maxDivergenceTicks` while the reference still
    ///      answers; the short window is this reference's own fair price, so the entry it records does not carry
    ///      that trail. The short window moves further than the answer under the documented
    ///      manipulation, less than `2 * (maxDivergenceTicks + 1) * longWindow / (longWindow - shortWindow)` ticks
    ///      plus one for flooring, but only the cover cap reads it, which never pays more than the position's own
    ///      deficit, so it bounds griefing of the reserve's currency mix, not the reserve's value.
    function entrySqrtPriceX96(PoolKey calldata key) external view returns (uint160) {
        (int24 shortTick,) = _stableTicks(key);
        return TickMath.getSqrtPriceAtTick(shortTick);
    }

    /// @dev Both window ticks for the bound pair; refuses a wrong pair or windows further apart than the bound.
    function _stableTicks(PoolKey calldata key) private view returns (int24 shortTick, int24 longTick) {
        if (Currency.unwrap(key.currency0) != currency0 || Currency.unwrap(key.currency1) != currency1) {
            revert WrongPair();
        }
        (shortTick, longTick) = twapTicks();
        int24 gap = shortTick > longTick ? shortTick - longTick : longTick - shortTick;
        if (gap > maxDivergenceTicks) revert ReferenceUnstable(shortTick, longTick);
    }

    /// @notice The short- and long-window mean ticks in v4 orientation.
    /// @return shortTick Mean tick over `shortWindow`
    /// @return longTick Mean tick over `longWindow`
    function twapTicks() public view returns (int24 shortTick, int24 longTick) {
        uint32[] memory ago = new uint32[](3);
        ago[0] = longWindow;
        ago[1] = shortWindow;
        (int56[] memory cumulatives,) = source.observe(ago);
        longTick = _mean(cumulatives[2] - cumulatives[0], longWindow);
        shortTick = _mean(cumulatives[2] - cumulatives[1], shortWindow);
        if (invert) {
            longTick = -longTick;
            shortTick = -shortTick;
        }
    }

    /// @dev Arithmetic mean tick rounded toward negative infinity, as the v3 OracleLibrary does.
    function _mean(int56 delta, uint32 window) private pure returns (int24 tick) {
        int56 w = int56(uint56(window));
        tick = int24(delta / w);
        if (delta < 0 && delta % w != 0) tick--;
    }
}
