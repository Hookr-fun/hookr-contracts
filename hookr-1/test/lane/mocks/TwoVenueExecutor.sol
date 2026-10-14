// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HookrTypes} from "../../../src/types/HookrTypes.sol";
import {IHookrRoot} from "../../../src/interfaces/IHookrRoot.sol";
import {IHookrLaneExecutor} from "../../../src/interfaces/callback/IHookrLaneExecutor.sol";
import {IHookrLaneRoot} from "../../../src/interfaces/IHookrLaneRoot.sol";

/// @title TwoVenueExecutor
/// @notice Test mock of a partner arb recapture executor, NOT the partner's executor. It runs a real two-venue
///         arbitrage between the triggering Hookr pool and its reference v4 pool, both legs inside the outer swap's
///         unlock with flash accounting. The reference pool is the triggering pool's pair with a fee, tick spacing and
///         hooks fixed at deployment, so no owner can re-route an arb recapture after the root pins this contract's
///         code hash. Each leg is priced with its venue's LP fee and v4 protocol fee in the leg's direction and stops
///         at the fee-adjusted meeting price, where the last unit bought on one venue and sold on the other breaks
///         even, or at MAX_CROSSINGS initialized ticks, whichever comes first, so positions anyone adds on a leg's path
///         shrink an arb recapture instead of pushing its gas past the root's fixed grant. It keeps `partnerBps` of the
///         realized quote profit for `partner` and pushes the rest to the root's sink as ERC-6909 claims, exactly as
///         the Hookr 1 executor ABI asks. No profit, no opportunity: it reverts and the root records
///         `CorrectionFailed`; the swap still completes.
/// @dev The meeting prices are placed around the arithmetic mean m of the two starting sqrt prices: the leg that
///      buys the subject targets m * R^(1/4) or m / R^(1/4) and the leg that sells it the other, where
///      R = (1 - fee of the buy leg) * (1 - fee of the sell leg), so the subject's quote prices on the two venues
///      end a factor R apart. A venue whose starting price is already past its target leaves no opportunity.
///      Leftover subject from a partial second leg is kept by this contract as inventory. The root's laneGasCap
///      must cover both legs at MAX_CROSSINGS cold crossings each, measured, not the honest path's peak.
contract TwoVenueExecutor is IHookrLaneExecutor {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    /// @notice Most initialized ticks one leg crosses; the leg stops at the last one it may cross.
    uint256 public constant MAX_CROSSINGS = 4;
    /// @notice Most bitmap words without an initialized tick one leg's limit search reads.
    uint256 public constant MAX_EMPTY_WORDS = 8;
    uint256 private constant PIPS = 1_000_000;
    uint256 private constant WAD = 1e18;

    IPoolManager public immutable poolManager;
    /// @notice The one root this executor serves.
    address public immutable root;
    address public immutable partner;
    /// @notice The partner's share of each arb recapture's realized profit, kept before the push. Must equal the rate
    ///         the registry pins for the lane; the root never reads it.
    uint16 public immutable partnerBps;
    /// @notice The reference venue's static LP fee in pips.
    uint24 public immutable refFee;
    /// @notice The reference venue's tick spacing.
    int24 public immutable refTickSpacing;
    /// @notice The reference venue's hooks, zero for a hookless pool.
    address public immutable refHooks;
    /// @notice The first leg's exact quote input.
    uint128 public immutable maxQuoteIn;

    error NotRoot();
    error NoOpportunity();
    error NoProfit(uint256 quoteIn, uint256 quoteOut);
    error InvalidVenue();

    /// @notice Emitted after a profitable arb recapture, before the root emits CorrectionSucceeded.
    event ArbRecaptured(
        PoolId indexed id,
        bool subjectCheapOnHookr,
        uint256 quoteIn,
        uint256 quoteOut,
        uint256 partnerShare,
        uint256 pushed
    );

    /// @param _manager The PoolManager.
    /// @param _root The root this executor serves. It is deployed after this contract, since it pins this
    ///        contract's code hash, so its address is predicted.
    /// @param _partner Receives the partner's share of each arb recapture.
    /// @param _partnerBps The partner's share in basis points.
    /// @param _refFee The reference venue's static LP fee in pips.
    /// @param _refTickSpacing The reference venue's tick spacing.
    /// @param _refHooks The reference venue's hooks, zero for a hookless pool; never `_root`.
    /// @param _maxQuoteIn The first leg's exact quote input.
    constructor(
        IPoolManager _manager,
        address _root,
        address _partner,
        uint16 _partnerBps,
        uint24 _refFee,
        int24 _refTickSpacing,
        address _refHooks,
        uint128 _maxQuoteIn
    ) {
        if (
            address(_manager).code.length == 0 || _root == address(0) || _partner == address(0) || _partnerBps >= 10_000
                || _refFee > LPFeeLibrary.MAX_LP_FEE || _refTickSpacing < TickMath.MIN_TICK_SPACING
                || _refTickSpacing > TickMath.MAX_TICK_SPACING || _refHooks == _root || _maxQuoteIn == 0
        ) revert InvalidVenue();
        poolManager = _manager;
        root = _root;
        partner = _partner;
        partnerBps = _partnerBps;
        refFee = _refFee;
        refTickSpacing = _refTickSpacing;
        refHooks = _refHooks;
        maxQuoteIn = _maxQuoteIn;
    }

    /// @notice Returns the reference venue of a Hookr pool: its pair with the fixed fee, spacing and hooks.
    function venue(PoolKey memory hookrPool) public view returns (PoolKey memory) {
        return PoolKey(hookrPool.currency0, hookrPool.currency1, refFee, refTickSpacing, IHooks(refHooks));
    }

    /// @inheritdoc IHookrLaneExecutor
    /// @dev The two-venue executor watches no v3 pool: it never refuses a swap.
    function checkV3PoolsMev(address, address, address, bool) external pure returns (bool) {
        return false;
    }

    /// @inheritdoc IHookrLaneExecutor
    function executeArbitrage(PoolKey calldata key, address) external returns (uint256 profit) {
        if (msg.sender != root) revert NotRoot();
        PoolId id = key.toId();
        PoolKey memory ref = venue(key);
        HookrTypes.PoolConfig memory pc = IHookrRoot(root).poolConfig(id);
        bool subjectIs0 = pc.subject == key.currency0;
        (uint160 pH,, uint24 protocolH,) = poolManager.getSlot0(id);
        (uint160 pR,, uint24 protocolR, uint24 lpR) = poolManager.getSlot0(ref.toId());
        if (pR == 0) revert NoOpportunity();
        // Price is currency1 per currency0. The subject is cheaper where its quote price is lower.
        bool cheapOnHookr = subjectIs0 ? pH < pR : pH > pR;
        // Buying the subject pays the quote: zeroForOne when the quote is currency0. A Hookr leg on a pool without an
        // advisory pays the base LP fee; this mock prices every Hookr leg that way and so does not price an advised
        // pool's surcharge and take, which a production executor reads from the root's quoteLeg.
        (uint160 targetBuy, uint160 targetSell) = _targets(
            (uint256(pH) + uint256(pR)) / 2,
            cheapOnHookr ? _swapFee(protocolH, !subjectIs0, pc.baseLpFeePips) : _swapFee(protocolR, !subjectIs0, lpR),
            cheapOnHookr ? _swapFee(protocolR, subjectIs0, lpR) : _swapFee(protocolH, subjectIs0, pc.baseLpFeePips),
            subjectIs0
        );
        (uint160 pBuy, uint160 pSell) = cheapOnHookr ? (pH, pR) : (pR, pH);
        if (subjectIs0 ? pBuy >= targetBuy || pSell <= targetSell : pBuy <= targetBuy || pSell >= targetSell) {
            revert NoOpportunity();
        }
        PoolKey memory buyVenue = cheapOnHookr ? key : ref;
        PoolKey memory sellVenue = cheapOnHookr ? ref : key;
        BalanceDelta d1 = poolManager.swap(
            buyVenue,
            SwapParams(!subjectIs0, -int256(uint256(maxQuoteIn)), _limit(buyVenue, !subjectIs0, targetBuy)),
            ""
        );
        (int128 q1, int128 s1) = subjectIs0 ? (d1.amount1(), d1.amount0()) : (d1.amount0(), d1.amount1());
        if (s1 <= 0 || q1 >= 0) revert NoOpportunity();
        uint256 quoteIn = uint256(uint128(-q1));
        uint256 subjectGot = uint256(uint128(s1));
        BalanceDelta d2 = poolManager.swap(
            sellVenue, SwapParams(subjectIs0, -int256(subjectGot), _limit(sellVenue, subjectIs0, targetSell)), ""
        );
        (int128 q2, int128 s2) = subjectIs0 ? (d2.amount1(), d2.amount0()) : (d2.amount0(), d2.amount1());
        uint256 quoteOut = q2 > 0 ? uint256(uint128(q2)) : 0;
        uint256 subjectSold = s2 < 0 ? uint256(uint128(-s2)) : 0;
        if (quoteOut <= quoteIn) revert NoProfit(quoteIn, quoteOut);
        profit = quoteOut - quoteIn;
        if (subjectGot > subjectSold) poolManager.take(pc.subject, address(this), subjectGot - subjectSold);
        uint256 partnerShare = profit * partnerBps / 10_000;
        uint256 pushed = profit - partnerShare;
        if (partnerShare != 0) poolManager.take(pc.quote, partner, partnerShare);
        if (pushed != 0) {
            poolManager.mint(root, pc.quote.toId(), pushed);
            IHookrLaneRoot(root).settleRecapture(key, pc.quote, pushed);
        }
        emit ArbRecaptured(id, cheapOnHookr, quoteIn, quoteOut, partnerShare, pushed);
    }

    /// @notice The fee in pips a swap in direction `zeroForOne` pays on a pool with packed protocol fee `packed`
    ///         and LP fee `lpFee`: the protocol fee on the input, then the LP fee on the rest.
    function _swapFee(uint24 packed, bool zeroForOne, uint24 lpFee) private pure returns (uint256) {
        uint16 protocolFee =
            zeroForOne ? ProtocolFeeLibrary.getZeroForOneFee(packed) : ProtocolFeeLibrary.getOneForZeroFee(packed);
        return protocolFee == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(protocolFee, lpFee);
    }

    /// @notice The sqrt-price targets of the buy and sell legs around `mid` for fees `feeBuy` and `feeSell` in pips.
    function _targets(uint256 mid, uint256 feeBuy, uint256 feeSell, bool subjectIs0)
        private
        pure
        returns (uint160 targetBuy, uint160 targetSell)
    {
        if (feeBuy >= PIPS || feeSell >= PIPS) revert NoOpportunity();
        // R^(1/4) in WAD, where R = (PIPS - feeBuy) * (PIPS - feeSell) / PIPS^2.
        uint256 root4 = Math.sqrt(Math.sqrt((PIPS - feeBuy) * (PIPS - feeSell) * 1e24) * WAD);
        uint256 low = mid * root4 / WAD;
        uint256 high = mid * WAD / root4;
        // Buying the subject raises its quote price: sqrtP rises when it is currency0 and falls when it is currency1.
        (uint256 b, uint256 s) = subjectIs0 ? (low, high) : (high, low);
        targetBuy = _clamp(b);
        targetSell = _clamp(s);
    }

    function _clamp(uint256 sqrtPrice) private pure returns (uint160) {
        if (sqrtPrice <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (sqrtPrice >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(sqrtPrice);
    }

    /// @notice The sqrt-price limit for a leg toward `target`: `target`, or the price of the MAX_CROSSINGS-th
    ///         initialized tick on the way, or of the word boundary after MAX_EMPTY_WORDS words with none.
    function _limit(PoolKey memory k, bool zeroForOne, uint160 target) private view returns (uint160) {
        PoolId id = k.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        uint256 crossings;
        uint256 empty;
        while (true) {
            (int24 next, bool initialized) = _nextTick(id, tick, k.tickSpacing, zeroForOne);
            if (next < TickMath.MIN_TICK) next = TickMath.MIN_TICK;
            if (next > TickMath.MAX_TICK) next = TickMath.MAX_TICK;
            uint160 at = TickMath.getSqrtPriceAtTick(next);
            if (zeroForOne ? at <= target : at >= target) return target;
            if (initialized ? ++crossings == MAX_CROSSINGS : ++empty == MAX_EMPTY_WORDS) return at;
            unchecked {
                tick = zeroForOne ? next - 1 : next;
            }
        }
    }

    /// @dev Port of `TickBitmap.nextInitializedTickWithinOneWord` over an extsload-read bitmap word.
    function _nextTick(PoolId id, int24 tick, int24 tickSpacing, bool lte)
        private
        view
        returns (int24 next, bool initialized)
    {
        unchecked {
            int24 compressed = TickBitmap.compress(tick, tickSpacing);
            if (lte) {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);
                uint256 masked = poolManager.getTickBitmap(id, wordPos) & mask;
                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(++compressed);
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = poolManager.getTickBitmap(id, wordPos) & mask;
                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }
}
