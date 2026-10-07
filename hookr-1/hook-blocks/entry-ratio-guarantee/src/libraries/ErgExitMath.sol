// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ErgTypes} from "../interfaces/ErgTypes.sol";

/// @title Entry Ratio Guarantee exit settlement
/// @notice Pure settlement of one exit: forfeited fees into the reserve, less the protocol's share, then, if the
///         entry ratio is requested, one exchange leg in which the reserve pays the LP's deficit currency and takes
///         its surplus currency at the position's own conversion rate (surplus / deficit), scaled down pro rata when
///         the reference saw a smaller deficit, or the reserve, the pool's coverage or the pool's draw budget cannot
///         pay the whole deficit.
/// @dev Every rounding goes to the reserve: forfeits and takes round up, payments and the protocol's share round
///      down. The target for each currency is the entry amount minus one unit, because the PoolManager rounds the
///      deposit up and the withdrawal down; the reserve never pays for that rounding.
library ErgExitMath {
    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;
    /// @notice Units per currency the reserve never pays: the PoolManager's own add/remove rounding.
    uint256 internal constant ROUNDING_TOLERANCE = 1;
    /// @notice Fee denominator (pips).
    uint256 internal constant PIPS = 1_000_000;

    /// @notice Inputs of one exit.
    /// @param principal0 currency0 principal released by the removal (delta minus fees)
    /// @param principal1 currency1 principal released by the removal
    /// @param fees0 currency0 fees accrued by the position since deposit
    /// @param fees1 currency1 fees accrued by the position since deposit
    /// @param entry0 currency0 paid at deposit
    /// @param entry1 currency1 paid at deposit
    /// @param reserve0 The pool's currency0 reserve before this exit
    /// @param reserve1 The pool's currency1 reserve before this exit
    /// @param forfeitBps Share of fees forfeited (10,000 = all)
    /// @param guarantee True when the entry-ratio leg is requested
    /// @param coverageBps Share of the deficit the reserve covers
    /// @param maxDrawBps Largest share of the reserve (after forfeits) the leg may pay
    /// @param drawRoom0 currency0 the pool's draw window still allows, over all exits
    /// @param drawRoom1 currency1 the pool's draw window still allows
    /// @param refPrincipal0 currency0 the position would release at the reference price (read only when the entry
    ///        ratio is requested); a capped leg never converts at a cheaper rate than this principal implies
    /// @param refPrincipal1 currency1 the position would release at the reference price
    /// @param refEntry0 currency0 the position would have cost at the reference price of its deposit (read only when
    ///        the entry ratio is requested). With `refPrincipal0` it gives the deficit the reference saw between entry
    ///        and exit; the leg pays no more than that
    /// @param refEntry1 currency1 the position would have cost at the reference price of its deposit
    /// @param protocolShareBps Share of the forfeited fees paid to the protocol instead of the reserve, charged on
    ///        every forfeit except the leg's waiver (see `waiver`)
    /// @param feePips The pool's static LP fee in pips; it prices the leg's waiver
    struct Inputs {
        uint256 principal0;
        uint256 principal1;
        uint256 fees0;
        uint256 fees1;
        uint256 entry0;
        uint256 entry1;
        uint256 reserve0;
        uint256 reserve1;
        uint256 forfeitBps;
        bool guarantee;
        uint256 coverageBps;
        uint256 maxDrawBps;
        uint256 drawRoom0;
        uint256 drawRoom1;
        uint256 refPrincipal0;
        uint256 refPrincipal1;
        uint256 refEntry0;
        uint256 refEntry1;
        uint256 protocolShareBps;
        uint256 feePips;
    }

    /// @notice Settles one exit.
    /// @param x The exit inputs
    /// @return r The settlement; `lp0 + forfeited0 + protocol0 + taken0 == principal0 + fees0 + paid0` and likewise
    ///         for 1
    function settle(Inputs memory x) internal pure returns (ErgTypes.ExitResult memory r) {
        // Every forfeit pays the protocol its share except the leg's waiver: `phi / (1 - phi)` of what the reserve
        // takes, in the currency it takes. A leg's loss to the reserve is at most that
        // much of what it takes when `2 * (band + reference error) <= fee`, so the reserve keeps what
        // the bounds need; and the fees that manufacturing a leg earns are at least that much of the take, so the
        // waiver never exceeds the fees a manufactured leg itself forfeits and a dust leg waives dust. In the paid
        // currency nothing is waived, so the leg draws only on the reserve plus what the reserve keeps of this
        // exit's forfeit there.
        r.forfeited0 = forfeit(x.fees0, x.forfeitBps);
        r.forfeited1 = forfeit(x.fees1, x.forfeitBps);
        if (x.guarantee) {
            uint256 target0 = x.entry0 > ROUNDING_TOLERANCE ? x.entry0 - ROUNDING_TOLERANCE : 0;
            uint256 target1 = x.entry1 > ROUNDING_TOLERANCE ? x.entry1 - ROUNDING_TOLERANCE : 0;
            // The same targets at the deposit's reference price: the leg covers only a deficit the reference also
            // saw between entry and exit, so a price pushed inside the band cannot manufacture one.
            uint256 refTarget0 = x.refEntry0 > ROUNDING_TOLERANCE ? x.refEntry0 - ROUNDING_TOLERANCE : 0;
            uint256 refTarget1 = x.refEntry1 > ROUNDING_TOLERANCE ? x.refEntry1 - ROUNDING_TOLERANCE : 0;
            if (x.principal0 < target0 && x.principal1 > target1) {
                (r.paid0, r.taken1) = leg(
                    target0 - x.principal0,
                    x.principal1 - target1,
                    gap(refTarget0, x.refPrincipal0),
                    x.reserve0 + kept(r.forfeited0, x.protocolShareBps),
                    x.coverageBps,
                    x.maxDrawBps,
                    x.drawRoom0
                );
                r.taken1 = rateFloor(
                    r.paid0,
                    r.taken1,
                    target0 - x.principal0,
                    x.principal1 - target1,
                    x.coverageBps,
                    gap(refTarget0, x.refPrincipal0),
                    gap(x.refPrincipal1, refTarget1)
                );
            } else if (x.principal1 < target1 && x.principal0 > target0) {
                (r.paid1, r.taken0) = leg(
                    target1 - x.principal1,
                    x.principal0 - target0,
                    gap(refTarget1, x.refPrincipal1),
                    x.reserve1 + kept(r.forfeited1, x.protocolShareBps),
                    x.coverageBps,
                    x.maxDrawBps,
                    x.drawRoom1
                );
                r.taken0 = rateFloor(
                    r.paid1,
                    r.taken0,
                    target1 - x.principal1,
                    x.principal0 - target0,
                    x.coverageBps,
                    gap(refTarget1, x.refPrincipal1),
                    gap(x.refPrincipal0, refTarget0)
                );
            }
        }
        (r.forfeited0, r.protocol0) = split(r.forfeited0, x.protocolShareBps, waiver(r.taken0, x.feePips));
        (r.forfeited1, r.protocol1) = split(r.forfeited1, x.protocolShareBps, waiver(r.taken1, x.feePips));
        r.hookDelta0 = int256(r.forfeited0 + r.taken0) - int256(r.paid0);
        r.hookDelta1 = int256(r.forfeited1 + r.taken1) - int256(r.paid1);
        r.lp0 = x.principal0 + x.fees0 + r.paid0 - r.forfeited0 - r.protocol0 - r.taken0;
        r.lp1 = x.principal1 + x.fees1 + r.paid1 - r.forfeited1 - r.protocol1 - r.taken1;
    }

    /// @notice The forfeit a leg keeps from the protocol's share, in the currency the reserve takes:
    ///         `ceil(taken * fee / (1 - fee))`. The fee a position earns on the input that built its surplus is at
    ///         least this much of the surplus, and the reserve's loss on a leg inside the composed band is at most
    ///         this much of what it takes, so the waiver sits between the two.
    /// @param taken Units the reserve takes in one currency
    /// @param feePips The pool's static LP fee in pips
    /// @return Units of that currency's forfeit exempt from the protocol's share
    function waiver(uint256 taken, uint256 feePips) internal pure returns (uint256) {
        if (taken == 0) return 0;
        if (feePips >= PIPS) return type(uint256).max;
        return FullMath.mulDivRoundingUp(taken, feePips, PIPS - feePips);
    }

    /// @notice What the reserve keeps of a forfeit with no waiver: the forfeit less the protocol's share.
    /// @param forfeited Units forfeited in one currency
    /// @param protocolShareBps Share paid to the protocol
    /// @return Units kept by the reserve
    function kept(uint256 forfeited, uint256 protocolShareBps) internal pure returns (uint256) {
        return forfeited - FullMath.mulDiv(forfeited, protocolShareBps, BPS);
    }

    /// @notice Splits a forfeit between the reserve and the protocol. The waived part stays in the reserve; the
    ///         protocol's share of the rest rounds down, so the rounding stays with the reserve.
    /// @param forfeited Units forfeited in one currency
    /// @param protocolShareBps Share paid to the protocol
    /// @param waived Units exempt from the share (capped at `forfeited`)
    /// @return toReserve Units kept by the reserve
    /// @return toProtocol Units owed to the protocol
    function split(uint256 forfeited, uint256 protocolShareBps, uint256 waived)
        internal
        pure
        returns (uint256 toReserve, uint256 toProtocol)
    {
        if (waived > forfeited) waived = forfeited;
        toProtocol = FullMath.mulDiv(forfeited - waived, protocolShareBps, BPS);
        toReserve = forfeited - toProtocol;
    }

    /// @notice The exchange leg: pay part of the deficit, take the same fraction of the surplus.
    /// @dev The covered deficit is the smaller of the position's deficit and the deficit the reference saw between
    ///      the deposit and the exit. Without that cap a narrow range deposited beside the price and pushed
    ///      through inside the exercise band showed its whole entry as a deficit, and one actor could spend every draw
    ///      window's room on legs like that at a small cost, converting the reserve out of the currency honest
    ///      exercisers need. The reference, not the pool price, decides how much loss there is to cover.
    /// @param deficit Units of the deficit currency needed to restore the entry target
    /// @param surplus Units of the other currency above its entry target
    /// @param refDeficit The same currency's deficit from the deposit's reference price to the exit's
    /// @param available Reserve of the deficit currency, including this exit's own forfeits
    /// @param coverageBps Share of the deficit the pool covers
    /// @param maxDrawBps Largest share of `available` one exit may pay
    /// @param room What the pool's draw window still allows in the deficit currency
    /// @return pay Units of the deficit currency the reserve pays, rounded down
    /// @return take Units of the surplus currency the reserve takes, `ceil(surplus * pay / deficit)`
    function leg(
        uint256 deficit,
        uint256 surplus,
        uint256 refDeficit,
        uint256 available,
        uint256 coverageBps,
        uint256 maxDrawBps,
        uint256 room
    ) internal pure returns (uint256 pay, uint256 take) {
        pay = FullMath.mulDiv(deficit < refDeficit ? deficit : refDeficit, coverageBps, BPS);
        uint256 cap = FullMath.mulDiv(available, maxDrawBps, BPS);
        if (cap > room) cap = room;
        if (pay > cap) pay = cap;
        if (pay == 0) return (0, 0);
        take = FullMath.mulDivRoundingUp(surplus, pay, deficit);
    }

    /// @notice The take of a capped leg, floored at the reference's rate. A leg paid in full or pro rata by
    ///         coverage converts at the position's own rate, which moves with the exit price in proportion to the
    ///         payment, so a pushed price gains nothing at first order. A leg the draw cap or the reserve limits pays a
    ///         fixed amount whatever the price, and its rate (the average price of the whole path from entry) would
    ///         fall as a pushed price shortens that path. Such a leg takes at least `refSurplus * pay / refDeficit`,
    ///         the rate from the deposit's reference price to the exit's, and never more than the surplus. A leg
    ///         capped by the reference's own deficit counts as capped.
    /// @param pay Units of the deficit currency the leg pays
    /// @param take Units of the surplus currency the leg takes at the position's own rate
    /// @param deficit The position's deficit at the exit price
    /// @param surplus The position's surplus at the exit price
    /// @param coverageBps Share of the deficit the pool covers
    /// @param refDeficit The same currency's deficit from the deposit's reference price to the exit's
    /// @param refSurplus The other currency's surplus from the deposit's reference price to the exit's
    /// @return The take, never below the reference rate on a capped leg and never above `surplus`
    function rateFloor(
        uint256 pay,
        uint256 take,
        uint256 deficit,
        uint256 surplus,
        uint256 coverageBps,
        uint256 refDeficit,
        uint256 refSurplus
    ) internal pure returns (uint256) {
        if (pay == 0 || refDeficit == 0 || pay >= FullMath.mulDiv(deficit, coverageBps, BPS)) {
            return take;
        }
        uint256 atReference = FullMath.mulDivRoundingUp(refSurplus, pay, refDeficit);
        if (atReference > take) take = atReference;
        return take > surplus ? surplus : take;
    }

    /// @notice `a - b`, or zero when `b >= a`.
    function gap(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    /// @notice The forfeited share of accrued fees, rounded up and never above `fees`.
    /// @param fees Fees accrued in one currency
    /// @param bps Share forfeited
    /// @return The forfeited units
    function forfeit(uint256 fees, uint256 bps) internal pure returns (uint256) {
        if (bps >= BPS) return fees;
        return FullMath.mulDivRoundingUp(fees, bps, BPS);
    }
}
