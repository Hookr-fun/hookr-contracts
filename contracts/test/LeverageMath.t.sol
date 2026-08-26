// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LeverageMath} from "../src/libraries/LeverageMath.sol";

/// @notice Properties of the Leveraged Hooks arithmetic, fuzzed directly rather than through
///         a pool. Every test here is one sentence from the published design turned into an
///         assertion — if the prose and the code ever disagree, one of these fails.
contract LeverageMathTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant BPS = 10_000;

    // ------------------------------------------------------------------ capacity

    /// The load-bearing rule of the token design.
    function testFuzz_capacityIsTheMinimum(uint256 a, uint256 b, uint256 c, uint256 d) public pure {
        uint256 cap = LeverageMath.creditCapacity(a, b, c, d);
        assertLe(cap, a);
        assertLe(cap, b);
        assertLe(cap, c);
        assertLe(cap, d);
        // ...and it is exactly one of them, never something in between.
        assertTrue(cap == a || cap == b || cap == c || cap == d);
    }

    /// Bonded $HOOKR may bind a ceiling. It may never raise one.
    function testFuzz_bondCannotLiftCapacity(uint256 liq, uint256 depth, uint256 bond, uint256 more) public pure {
        liq = bound(liq, 0, type(uint128).max);
        depth = bound(depth, 0, type(uint128).max);
        bond = bound(bond, 0, type(uint128).max);
        more = bound(more, bond, type(uint128).max);
        uint256 limit = type(uint256).max;
        uint256 before = LeverageMath.creditCapacity(liq, depth, bond, limit);
        uint256 afterMoreBond = LeverageMath.creditCapacity(liq, depth, more, limit);
        // More bond never reduces capacity (min is monotonic)...
        assertGe(afterMoreBond, before);
        // ...and never pushes it past what liquidity and depth allow.
        assertLe(afterMoreBond, liq < depth ? liq : depth);
    }

    function testFuzz_haircutOnlyTightens(uint256 term, uint256 bps) public pure {
        term = bound(term, 0, type(uint128).max);
        bps = bound(bps, 0, BPS);
        assertLe(LeverageMath.haircut(term, bps), term);
        assertEq(LeverageMath.haircut(term, 0), term);
        assertEq(LeverageMath.haircut(term, BPS), 0);
    }

    /// A ceiling that contracts under existing loans is a real state, not a revert.
    function test_availableCreditSaturatesAtZero() public pure {
        assertEq(LeverageMath.availableCredit(5 ether, 8 ether), 0);
        assertEq(LeverageMath.availableCredit(8 ether, 5 ether), 3 ether);
    }

    // ------------------------------------------------------------------ interest

    /// Debt never drifts downward through rounding.
    function testFuzz_debtNeverRoundsDown(uint256 principal, uint256 growthBps) public pure {
        principal = bound(principal, 1, type(uint96).max);
        growthBps = bound(growthBps, 0, 50_000);
        uint256 index0 = WAD;
        uint256 index1 = WAD + (WAD * growthBps) / BPS;
        uint256 owed = LeverageMath.debtOwed(principal, index0, index1);
        assertGe(owed, principal);
    }

    function testFuzz_indexIsMonotonic(uint256 rate, uint256 dt, uint256 extra) public pure {
        rate = bound(rate, 0, 10 * WAD);
        dt = bound(dt, 0, 365 days);
        extra = bound(extra, 0, 365 days);

        // `>= WAD` from a fixed WAD start is satisfied by an accrueIndex that never accrues at
        // all, so it did not test the name. Monotonicity is a statement about the ORDERING in
        // dt: more time may never produce a smaller index, or interest would be retroactively
        // forgiven.
        uint256 near = LeverageMath.accrueIndex(WAD, rate, dt);
        uint256 far = LeverageMath.accrueIndex(WAD, rate, dt + extra);
        assertGe(near, WAD);
        assertGe(far, near, "more elapsed time may never shrink the index");
    }

    function test_accrualIsLinearWithinAStep() public pure {
        // 10% for a full year on a fresh index.
        uint256 idx = LeverageMath.accrueIndex(WAD, WAD / 10, 365 days);
        assertApproxEqAbs(idx, WAD + WAD / 10, 2);
    }

    // ------------------------------------------------------------------ borrow rate

    function testFuzz_rateRisesWithUtilisation(uint256 u1, uint256 u2) public pure {
        u1 = bound(u1, 0, WAD);
        u2 = bound(u2, u1, WAD);
        uint256 kink = (WAD * 8) / 10;
        uint256 r1 = LeverageMath.borrowRatePerYearWad(u1, kink, WAD / 100, WAD / 10, 3 * WAD);
        uint256 r2 = LeverageMath.borrowRatePerYearWad(u2, kink, WAD / 100, WAD / 10, 3 * WAD);
        assertGe(r2, r1);
    }

    function test_rateIsSteeperPastTheKink() public pure {
        uint256 kink = (WAD * 8) / 10;
        uint256 base = WAD / 100;
        uint256 s1 = WAD / 10;
        uint256 s2 = 3 * WAD;
        uint256 atKink = LeverageMath.borrowRatePerYearWad(kink, kink, base, s1, s2);
        uint256 atFull = LeverageMath.borrowRatePerYearWad(WAD, kink, base, s1, s2);
        assertEq(atKink, base + s1);
        assertEq(atFull, base + s1 + s2);
    }

    // ------------------------------------------------------------------ health

    /// Liquidation is reachable while the position is still over-collateralised — that gap is
    /// the room the design reserves for fees, incentive, impact and oracle lag.
    function test_healthHitsOneBeforeInsolvency() public pure {
        uint256 debt = 100 ether;
        uint256 threshold = 8_000; // 80%
        uint256 collateralAtHealthOne = 125 ether; // 125 * 0.8 == 100
        assertEq(LeverageMath.healthFactorWad(collateralAtHealthOne, debt, threshold), WAD);
        // Still worth more than the debt at the moment it becomes liquidatable.
        assertGt(collateralAtHealthOne, debt);
    }

    function testFuzz_healthFallsAsDebtGrows(uint256 collateral, uint256 d1, uint256 d2) public pure {
        collateral = bound(collateral, 1 ether, type(uint96).max);
        d1 = bound(d1, 1, type(uint96).max);
        d2 = bound(d2, d1, type(uint96).max);
        uint256 h1 = LeverageMath.healthFactorWad(collateral, d1, 8_000);
        uint256 h2 = LeverageMath.healthFactorWad(collateral, d2, 8_000);
        assertGe(h1, h2);
    }

    function test_noDebtIsInfinitelyHealthy() public pure {
        assertEq(LeverageMath.healthFactorWad(1 ether, 0, 8_000), type(uint256).max);
    }

    /// The quoted liquidation price must never flatter the trader.
    function testFuzz_liquidationPriceRoundsUp(uint256 debt, uint256 collateral) public pure {
        debt = bound(debt, 1, type(uint64).max);
        collateral = bound(collateral, 1e12, type(uint64).max);
        uint256 p = LeverageMath.liquidationPriceWad(debt, collateral, 8_000);
        // The ceil property, asserted directly rather than through a lossy round trip:
        // collateral * price * threshold >= debt * BPS * WAD, i.e. the quoted price is never
        // below the true one. A round trip through `collateral * p / WAD` floors, so it was
        // measuring the test's own rounding rather than the library's.
        assertGe(collateral * p * 8_000, debt * BPS * WAD);
    }

    function test_borrowForEquityMatchesLeverage() public pure {
        assertEq(LeverageMath.borrowForEquity(2 ether, 2 * WAD), 2 ether);
        assertEq(LeverageMath.borrowForEquity(2 ether, 3 * WAD), 4 ether);
        // 1x and below borrows nothing rather than underflowing.
        assertEq(LeverageMath.borrowForEquity(2 ether, WAD), 0);
        assertEq(LeverageMath.borrowForEquity(2 ether, WAD / 2), 0);
    }

    // ------------------------------------------------------------------ balance sheet

    /// The double count the whole design exists to rule out.
    function test_marketEquityExcludesBorrowerCollateral() public pure {
        uint256 idle = 10 ether;
        uint256 inventory = 5 ether;
        uint256 receivable = 2 ether;
        uint256 equity = LeverageMath.marketEquity(idle, inventory, receivable, 0);
        assertEq(equity, 17 ether);
        // This used to re-call the function with identical arguments and assert the result
        // equalled itself. `marketEquity` has no collateral parameter at all — the property
        // about borrower collateral is asserted end-to-end in
        // LeverageEndToEndTest::test_ownedTokensExcludesBorrowerCollateral. What IS testable
        // here is the fourth parameter, bad debt, which must come straight off LP value.
        assertEq(LeverageMath.marketEquity(idle, inventory, receivable, 1 ether), equity - 1 ether);
    }

    function testFuzz_badDebtOnlyReducesEquity(uint256 idle, uint256 inv, uint256 recv, uint256 bad) public pure {
        idle = bound(idle, 0, type(uint96).max);
        inv = bound(inv, 0, type(uint96).max);
        recv = bound(recv, 0, type(uint96).max);
        bad = bound(bad, 0, type(uint96).max);
        uint256 withBad = LeverageMath.marketEquity(idle, inv, recv, bad);
        uint256 without = LeverageMath.marketEquity(idle, inv, recv, 0);
        assertLe(withBad, without);
    }

    // ------------------------------------------------------------------ LP shares

    /// A first depositor cannot mint dust and donate to inflate the share price.
    function test_inflationAttackIsNotProfitable() public pure {
        // Attacker mints the smallest possible position in an empty market...
        uint256 attackerShares = LeverageMath.sharesForDeposit(1, 0, 0);
        assertGt(attackerShares, 0);
        // ...then donates a large amount to the market.
        uint256 donated = 100 ether;
        uint256 supply = attackerShares;
        uint256 equity = 1 + donated;
        // A normal depositor still receives a meaningful, non-zero share.
        uint256 victimShares = LeverageMath.sharesForDeposit(10 ether, supply, equity);
        assertGt(victimShares, 0);
        uint256 victimOut = LeverageMath.quoteForShares(victimShares, supply + victimShares, equity + 10 ether);
        // They get back materially what they put in rather than losing it to the attacker.
        assertGe(victimOut, 9.9 ether);
    }

    function testFuzz_roundTripNeverMintsValue(uint256 deposit, uint256 supply, uint256 equity) public pure {
        deposit = bound(deposit, 1, type(uint96).max);
        supply = bound(supply, 0, type(uint96).max);
        equity = bound(equity, 0, type(uint96).max);
        uint256 shares = LeverageMath.sharesForDeposit(deposit, supply, equity);
        uint256 out = LeverageMath.quoteForShares(shares, supply + shares, equity + deposit);
        // Depositing and immediately redeeming can never return more than was put in.
        assertLe(out, deposit);
    }

    function testFuzz_exitFeeOnlyAppliesPastTheKink(uint256 u) public pure {
        uint256 kink = (WAD * 8) / 10;
        u = bound(u, 0, WAD);
        uint256 fee = LeverageMath.exitFeeBps(u, kink, 500);
        if (u <= kink) assertEq(fee, 0);
        assertLe(fee, 500);

        // Both assertions above are satisfied by an exitFeeBps that always returns 0, so the
        // fee has to be pinned somewhere it must be non-zero. Full utilisation is the one
        // point the curve is defined to reach its maximum. (Just past the kink is NOT a sound
        // place to require fee > 0: `(500 * excess) / denom` legitimately floors to zero
        // there.)
        assertEq(LeverageMath.exitFeeBps(WAD, kink, 500), 500, "the curve must reach its cap");

        // And it may never fall as utilisation rises.
        uint256 higher = u < WAD ? u + (WAD - u) / 2 : WAD;
        assertGe(LeverageMath.exitFeeBps(higher, kink, 500), fee, "the fee is non-decreasing");
    }

    /// A withdrawal may never take the liquid asset outstanding loans stand on.
    function testFuzz_withdrawalNeverOverdrawsReserved(uint256 want, uint256 idle, uint256 reserved) public pure {
        want = bound(want, 0, type(uint96).max);
        idle = bound(idle, 0, type(uint96).max);
        reserved = bound(reserved, 0, type(uint96).max);
        uint256 paid = LeverageMath.serviceableWithdrawal(want, idle, reserved);
        assertLe(paid, want);
        if (reserved >= idle) assertEq(paid, 0);
        else assertLe(paid, idle - reserved);
    }
}
