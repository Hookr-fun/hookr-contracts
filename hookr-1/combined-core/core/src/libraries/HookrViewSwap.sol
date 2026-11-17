// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";

import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @title HookrViewSwap
/// @notice Read-only v4 swap preview with separately named raw, last-liquid and root-compatible fee outcomes.
/// @dev Derived from the pinned bench prototype; the original is retained unchanged under src/prototype/.
///      The virtual reversal uses the same immutable tick/bitmap data and the reverse direction's protocol fee.
///      Callers supply a bound pool's actual spacing and a validated LP fee, net of applicable quote reservations.
///      The walk runs inside the core's Rules call, which the root bounds by the admission's gas (2,000,000), while
///      the release root's simulation runs on the transaction's own gas (C1, 10-23). So the walk keeps a budget of
///      its own: WALK_BUDGET_GAS, counted in the most a read (WALK_READ_GAS) and a step (WALK_STEP_GAS) cost cold,
///      so it depends on the pool and the swap only, never on the gas a caller sends. A walk that would pass it
///      prices the fee at the swap's own price limit: the farthest the real swap can end, so the fee is never less
///      than the root's simulation would charge, and no tick layout runs the Rules call out of gas. Under the budget
///      the walk is the PoolManager's swap, step for step (C8); an empty word crossed with no liquidity is read, not
///      stepped, since the PoolManager's step there moves no amount.
library HookrViewSwap {
    using ProtocolFeeLibrary for uint16;
    using LPFeeLibrary for uint24;

    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant LIQUIDITY_OFFSET = 3;
    uint256 internal constant TICKS_OFFSET = 4;
    uint256 internal constant TICK_BITMAP_OFFSET = 5;
    /// @notice The walk's budget, in gas at cold reads: past it the fee is priced at the swap's price limit.
    uint256 internal constant WALK_BUDGET_GAS = 1_600_000;
    /// @notice The most one PoolManager read costs the walk (cold slot, call, slot hash, word cache).
    uint256 internal constant WALK_READ_GAS = 3_100;
    /// @notice The most one swap step costs the walk besides its reads (tick price, SwapMath, state).
    uint256 internal constant WALK_STEP_GAS = 4_200;
    /// @dev No bitmap word cached yet (a word position is an int16).
    int256 private constant NO_WORD = type(int256).max;

    error AmountOutOfRange();
    error SwapAmountCannotBeZero();
    error PoolNotInitialized();
    error InvalidFeeForExactOut();
    error InvalidTickSpacing();
    error PriceLimitAlreadyExceeded(uint160 current, uint160 limit);
    error PriceLimitOutOfBounds(uint160 limit);

    struct Result {
        uint160 sqrtPriceBeforeX96;
        int24 tickBefore;
        uint160 sqrtPriceAfterX96;
        int24 tickAfter;
        uint160 lastLiquidPriceX96;
        int24 lastLiquidTick;
        uint160 feePriceAfterX96;
        int24 feeTickAfter;
        bool hasLiquidPrice;
    }

    struct Input {
        PoolId id;
        int24 tickSpacing;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        uint24 lpFee;
        bool isBuy;
        uint24 quoteTakePips;
        uint16 subjectBurnBps;
    }

    struct Loop {
        bytes32 state;
        int24 spacing;
        bool zeroForOne;
        uint160 limit;
        uint24 swapFee;
        int256 remaining;
        uint160 sqrtPrice;
        int24 tick;
        uint128 liquidity;
        uint160 lastLiquidPrice;
        int24 lastLiquidTick;
        bool hasLiquidPrice;
        /// @dev Budget the swap spent, in WALK_READ_GAS and WALK_STEP_GAS units, carried into its swap back.
        uint256 spent;
        /// @dev The last bitmap word read and its position: the walk reads each word once.
        int256 wordPos;
        uint256 word;
    }

    function simulate(
        IPoolManager manager,
        PoolId id,
        int24 tickSpacing,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        uint24 lpFee
    ) public view returns (Result memory) {
        return _simulate(manager, id, tickSpacing, zeroForOne, amountSpecified, sqrtPriceLimitX96, lpFee);
    }

    /// @notice Uses the pre-quote take supplied by the core; no rates or amounts are silently clamped.
    /// @dev The core resolves the largest exact-output-sell reserve, advisory selection and all block takes.
    function simulateQuoted(IPoolManager manager, Input memory x) public view returns (Result memory) {
        int256 amount = netAmount(x.amountSpecified, x.isBuy, x.quoteTakePips, x.subjectBurnBps);
        return _simulate(manager, x.id, x.tickSpacing, x.zeroForOne, amount, x.sqrtPriceLimitX96, x.lpFee);
    }

    /// @dev HookrRoot._magnitude and _reserve, followed by its exact-input/output net amount; no core settings reads.
    function netAmount(int256 amountSpecified, bool isBuy, uint256 rate, uint256 burnBps)
        internal
        pure
        returns (int256)
    {
        if (amountSpecified == type(int256).min) revert AmountOutOfRange();
        bool exactInput = amountSpecified < 0;
        uint256 requested = exactInput ? uint256(-amountSpecified) : uint256(amountSpecified);
        uint256 reserved;
        if (!isBuy) {
            if (!exactInput && rate != 0) reserved = (requested * rate + (1_000_000 - rate) - 1) / (1_000_000 - rate);
        } else if (exactInput) {
            reserved = requested * rate / 1_000_000;
        } else if (burnBps != 0) {
            reserved = (requested * burnBps + (10_000 - burnBps) - 1) / (10_000 - burnBps);
        }
        if (!exactInput && requested + reserved > uint256(uint128(type(int128).max))) revert AmountOutOfRange();
        return exactInput ? -int256(requested - reserved) : int256(requested + reserved);
    }

    function _simulate(
        IPoolManager manager,
        PoolId id,
        int24 tickSpacing,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        uint24 lpFee
    ) private view returns (Result memory r) {
        if (amountSpecified == 0) revert SwapAmountCannotBeZero();
        if (tickSpacing <= 0 || tickSpacing > TickMath.MAX_TICK_SPACING) revert InvalidTickSpacing();
        lpFee.validate();
        Loop memory s;
        bytes32 state;
        assembly ("memory-safe") {
            mstore(0, id)
            mstore(32, 6) // POOLS_SLOT
            state := keccak256(0, 64)
        }
        s.state = state;
        uint256 slot0 = _load(manager, state);
        s.sqrtPrice = uint160(slot0);
        s.tick = int24(int256(slot0 >> 160));
        if (s.sqrtPrice == 0) revert PoolNotInitialized();
        uint24 protocolFee = uint24(slot0 >> 184);
        s.swapFee = _swapFee(protocolFee, zeroForOne, lpFee);
        if (amountSpecified > 0 && s.swapFee >= SwapMath.MAX_SWAP_FEE) revert InvalidFeeForExactOut();
        s.liquidity = uint128(_load(manager, bytes32(uint256(state) + LIQUIDITY_OFFSET)));
        s.spacing = tickSpacing;
        s.zeroForOne = zeroForOne;
        s.limit = sqrtPriceLimitX96;
        s.remaining = amountSpecified;
        s.wordPos = NO_WORD;
        if (s.liquidity != 0) {
            s.lastLiquidPrice = s.sqrtPrice;
            s.lastLiquidTick = s.tick;
            s.hasLiquidPrice = true;
        }
        r.sqrtPriceBeforeX96 = s.sqrtPrice;
        r.tickBefore = s.tick;
        bool complete = _walk(manager, s);
        r.sqrtPriceAfterX96 = s.sqrtPrice;
        r.tickAfter = s.tick;
        r.lastLiquidPriceX96 = s.lastLiquidPrice;
        r.lastLiquidTick = s.lastLiquidTick;
        r.hasLiquidPrice = s.hasLiquidPrice;
        if (!complete) {
            // Past the budget: priced at the price limit, which the real swap cannot pass. The raw fields above are
            // where the walk stopped. Settle carries the anchor no further than the executed price
            // (HookrRules._moveAnchor takes the nearer of the simulated end and the pool's price).
            r.feePriceAfterX96 = s.limit;
            r.feeTickAfter = TickMath.getTickAtSqrtPrice(s.limit);
            return r;
        }
        // The root repeats only when a limit is reached in an empty range, with the original price as reverse limit.
        while (s.sqrtPrice == s.limit && s.sqrtPrice != r.sqrtPriceBeforeX96 && s.liquidity == 0) {
            s.zeroForOne = !s.zeroForOne;
            s.limit = r.sqrtPriceBeforeX96;
            s.remaining = -1;
            s.swapFee = _swapFee(protocolFee, s.zeroForOne, lpFee);
            if (!_walk(manager, s)) {
                // Past the budget on the swap back: it stops where the swap last had liquidity (the tick it emptied,
                // whose liquidity takes the one wei when the reverse fee is nonzero, so exactly there), or back at
                // the start when the swap met none. Never past that point, so never a lower fee.
                (s.sqrtPrice, s.tick) = r.hasLiquidPrice
                    ? (r.lastLiquidPriceX96, r.lastLiquidTick)
                    : (r.sqrtPriceBeforeX96, r.tickBefore);
                break;
            }
        }
        r.feePriceAfterX96 = s.sqrtPrice;
        r.feeTickAfter = s.tick;
    }

    function _swapFee(uint24 protocolFee, bool zeroForOne, uint24 lpFee) private pure returns (uint24) {
        uint16 fee = zeroForOne ? uint16(protocolFee & 0xfff) : uint16(protocolFee >> 12);
        return fee == 0 ? lpFee : fee.calculateSwapFee(lpFee);
    }

    /// @dev The swap loop. Returns false, leaving the state where it stopped, when the next read or step would pass
    ///      WALK_BUDGET_GAS (at most one word read past it).
    function _walk(IPoolManager manager, Loop memory s) private view returns (bool) {
        // Applies to the original swap and to the virtual reversal, just as each real PoolManager.swap validates.
        if (s.zeroForOne ? s.limit >= s.sqrtPrice : s.limit <= s.sqrtPrice) {
            revert PriceLimitAlreadyExceeded(s.sqrtPrice, s.limit);
        }
        if (s.zeroForOne ? s.limit <= TickMath.MIN_SQRT_PRICE : s.limit >= TickMath.MAX_SQRT_PRICE) {
            revert PriceLimitOutOfBounds(s.limit);
        }
        bool exactOutput = s.remaining > 0;
        // The limit's tick, read by the empty-range scan only, on its first use.
        int24 limitTick;
        bool scanning;
        uint256 spent = s.spent;
        while (!(s.remaining == 0 || s.sqrtPrice == s.limit)) {
            uint160 start = s.sqrtPrice;
            (int24 tickNext, bool initialized, bool read) = _next(manager, s);
            unchecked {
                if (read) spent += WALK_READ_GAS;
            }
            if (!initialized && s.liquidity == 0) {
                if (!scanning) {
                    limitTick = TickMath.getTickAtSqrtPrice(s.limit);
                    scanning = true;
                }
                (tickNext, initialized, spent) = _scan(manager, s, tickNext, limitTick, spent);
            }
            unchecked {
                spent += WALK_STEP_GAS;
            }
            if (spent > WALK_BUDGET_GAS) return false;
            if (tickNext <= TickMath.MIN_TICK) tickNext = TickMath.MIN_TICK;
            if (tickNext >= TickMath.MAX_TICK) tickNext = TickMath.MAX_TICK;
            uint160 sqrtNext = TickMath.getSqrtPriceAtTick(tickNext);
            uint256 amountIn;
            uint256 amountOut;
            uint256 feeAmount;
            (s.sqrtPrice, amountIn, amountOut, feeAmount) = SwapMath.computeSwapStep(
                s.sqrtPrice,
                SwapMath.getSqrtPriceTarget(s.zeroForOne, sqrtNext, s.limit),
                s.liquidity,
                s.remaining,
                s.swapFee
            );
            unchecked {
                if (exactOutput) s.remaining -= int256(amountOut);
                else s.remaining += int256(amountIn + feeAmount);
            }
            if (s.sqrtPrice == sqrtNext) {
                if (initialized) {
                    unchecked {
                        spent += WALK_READ_GAS;
                    }
                    if (spent > WALK_BUDGET_GAS) return false;
                    bytes32 tickSlot = s.state;
                    assembly ("memory-safe") {
                        mstore(0, signextend(2, tickNext))
                        mstore(32, add(tickSlot, TICKS_OFFSET))
                        tickSlot := keccak256(0, 64)
                    }
                    int128 net = int128(int256(_load(manager, tickSlot)) >> 128);
                    unchecked {
                        if (s.zeroForOne) net = -net;
                    }
                    uint128 before = s.liquidity;
                    s.liquidity = LiquidityMath.addDelta(s.liquidity, net);
                    if (s.liquidity == 0 && before != 0) {
                        s.lastLiquidPrice = sqrtNext;
                        s.lastLiquidTick = s.zeroForOne ? tickNext : tickNext - 1;
                        s.hasLiquidPrice = true;
                    }
                }
                unchecked {
                    s.tick = s.zeroForOne ? tickNext - 1 : tickNext;
                }
            } else if (s.sqrtPrice != start) {
                s.tick = TickMath.getTickAtSqrtPrice(s.sqrtPrice);
            }
            if (s.liquidity != 0) {
                s.lastLiquidPrice = s.sqrtPrice;
                s.lastLiquidTick = s.tick;
                s.hasLiquidPrice = true;
            }
        }
        s.spent = spent;
        return true;
    }

    /// @dev TickBitmap.nextInitializedTickWithinOneWord over extsload.
    ///      `read`: whether its word was read from the PoolManager (not the word the walk read last).
    function _next(IPoolManager manager, Loop memory s)
        private
        view
        returns (int24 next, bool initialized, bool read)
    {
        int24 tick = s.tick;
        int24 spacing = s.spacing;
        unchecked {
            int24 compressed;
            assembly ("memory-safe") {
                tick := signextend(2, tick)
                spacing := signextend(2, spacing)
                compressed := sub(sdiv(tick, spacing), slt(smod(tick, spacing), 0))
            }
            if (s.zeroForOne) {
                (int16 wordPos, uint8 bitPos) = _position(compressed);
                uint256 word;
                (word, read) = _word(manager, s, wordPos);
                uint256 masked = word & (type(uint256).max >> (uint256(type(uint8).max) - bitPos));
                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * spacing
                    : (compressed - int24(uint24(bitPos))) * spacing;
            } else {
                ++compressed;
                (int16 wordPos, uint8 bitPos) = _position(compressed);
                uint256 word;
                (word, read) = _word(manager, s, wordPos);
                uint256 masked = word & ~((uint256(1) << bitPos) - 1);
                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * spacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * spacing;
            }
        }
    }

    /// @dev With no liquidity the PoolManager crosses an uninitialized word edge without moving any amount, and each
    ///      such step only carries the price to the next edge. So from the edge `next` of an empty word the walk reads
    ///      the following words alone, until an initialized tick or the word edge at or past the limit's tick, and the
    ///      loop then takes the one step the PoolManager's last step takes: the same end price, tick and amounts.
    ///      Each word it reads is a new one, charged WALK_READ_GAS; it stops early, with the budget passed, for
    ///      `_walk` to return.
    function _scan(IPoolManager manager, Loop memory s, int24 next, int24 limitTick, uint256 spent)
        private
        view
        returns (int24, bool, uint256)
    {
        int256 spacing = s.spacing;
        unchecked {
            if (s.zeroForOne) {
                // `next` is the lowest tick of an empty word: wordPos * 256 * spacing.
                int256 wordPos = (int256(next) / spacing) >> 8;
                while (next > limitTick && spent <= WALK_BUDGET_GAS) {
                    spent += WALK_READ_GAS;
                    (uint256 word,) = _word(manager, s, --wordPos);
                    if (word != 0) {
                        return (
                            int24((wordPos * 256 + int256(uint256(BitMath.mostSignificantBit(word)))) * spacing), true, spent
                        );
                    }
                    next = int24(wordPos * 256 * spacing);
                }
            } else {
                // `next` is the highest tick of an empty word: (wordPos * 256 + 255) * spacing.
                int256 wordPos = (int256(next) / spacing) >> 8;
                while (next < limitTick && spent <= WALK_BUDGET_GAS) {
                    spent += WALK_READ_GAS;
                    (uint256 word,) = _word(manager, s, ++wordPos);
                    if (word != 0) {
                        return (
                            int24((wordPos * 256 + int256(uint256(BitMath.leastSignificantBit(word)))) * spacing), true, spent
                        );
                    }
                    next = int24((wordPos * 256 + 255) * spacing);
                }
            }
        }
        return (next, false, spent);
    }

    /// @dev The tick bitmap word at `wordPos`, from the PoolManager (`fresh`) unless it is the word read last.
    function _word(IPoolManager manager, Loop memory s, int256 wordPos) private view returns (uint256 word, bool fresh) {
        if (wordPos == s.wordPos) return (s.word, false);
        fresh = true;
        bytes32 slot = s.state;
        assembly ("memory-safe") {
            mstore(0, wordPos)
            mstore(32, add(slot, TICK_BITMAP_OFFSET))
            slot := keccak256(0, 64)
        }
        word = _load(manager, slot);
        s.wordPos = wordPos;
        s.word = word;
    }

    /// @dev IExtsload.extsload(bytes32) on the PoolManager, through scratch space.
    function _load(IPoolManager manager, bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            mstore(0, 0x1e2eaeaf)
            mstore(32, slot)
            // The call first: Yul evaluates arguments right to left, so `returndatasize()` must follow it.
            let ok := staticcall(gas(), manager, 28, 36, 0, 32)
            if iszero(and(ok, eq(returndatasize(), 32))) {
                let p := mload(0x40)
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
            value := mload(0)
        }
    }

    /// @dev TickBitmap.position.
    function _position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        assembly ("memory-safe") {
            wordPos := sar(8, signextend(2, tick))
            bitPos := and(tick, 0xff)
        }
    }
}
