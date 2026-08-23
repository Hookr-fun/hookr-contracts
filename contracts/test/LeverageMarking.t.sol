// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LeverageEndToEndTest} from "./LeverageEndToEnd.t.sol";
import {LeverageMarket} from "../src/LeverageMarket.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";

/// @notice The credit book is marked per position, not in aggregate.
///
///         `_recoverableDebt` used to mark the book as
///         `min(collateralHeld * price * thr, totalDebt())` — the WHOLE book's collateral
///         against the WHOLE book's debt. But `min(SUM, SUM) != SUM of min`. Collateral that
///         secured little or no debt lifted the impairment mark on every OTHER receivable, so
///         an impaired book could be made to look whole by parking collateral beside it.
///
///         That was directly and atomically profitable. `borrowForEquity` returns 0 for
///         leverage <= 1x and the origination gate was guarded on `borrow > 0`, so
///         `openPosition{value: X}(WAD, 0)` was a free, zero-risk, zero-debt collateral
///         deposit; `addCollateral` has no capacity, utilisation or health gate at all and does
///         the same job for a genuine borrower. Measured against the build with this fix
///         reverted, on the book `_impairedBook()` sets up: one 15 ETH injection fabricated
///         +4.44 ETH of NAV out of nothing (166.585 -> 171.024) and netted the attacker
///         +1.44 ETH over simply redeeming — taken from the LPs who stayed. With the fix the
///         same injection moves NAV by EXACTLY 0 and the round trip loses 0.08 ETH to pool
///         fees.
///
///         Each exploit test compares the SAME state down two paths with `vm.snapshotState`,
///         so what is asserted is the exploit's edge over doing nothing, not an absolute number
///         a fee or an accrual could move. The control runs the identical script on an
///         UNIMPAIRED book: it loses money there too, which is what proves these tests measure
///         the MARK rather than a refusal or a trading cost.
contract LeverageMarkingTest is LeverageEndToEndTest {
    /// Two real borrowers, then a price collapse that leaves them deeply underwater.
    ///
    /// Two, not one: with a single position `min(SUM, SUM)` and `SUM of min` are the same
    /// number, so a one-position book cannot tell the broken formula from the fixed one. The
    /// defect needs one receivable to be impaired while another position's collateral is free
    /// to be miscounted as backing for it.
    ///
    /// The dump is sized against the POOL, not against the creator's bag. Selling the creator's
    /// whole holding is ~5,000x the pool's token side: it crushes the price so far that the
    /// oracle's own warming buys then move it 100% a round, the market never stops being
    /// `Protected()`, and every deposit below reverts for a reason that has nothing to do with
    /// the mark. Twice the pool's token side lands the borrowers at health ~0.33 with a price
    /// the market still trusts.
    function _impairedBook() internal {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 120 ether}();
        _warmOracle();

        for (uint256 i = 0; i < 2; i++) {
            address b = address(uint160(0x5000 + i));
            vm.deal(b, 1_000 ether);
            vm.prank(b);
            market.openPosition{value: 4 ether}(2 * WAD, 0);
            // Re-warm between opens: each open is a swap, and two back to back leave the market
            // `Protected()` on its own deviation.
            _warmOracle();
        }
        assertGt(market.totalDebt(), 7 ether, "setup: the book needs real debt to impair");

        _dump(2);
        _warmOracle();
        _warmOracle();

        assertLt(market.liquidationHealthOf(address(uint160(0x5000))), WAD, "setup: the book must be impaired");
        assertFalse(hook.isProtected(id), "setup: the market must trust its price, or nothing below tests the mark");
    }

    /// The same book, never impaired.
    function _healthyBook() internal {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 120 ether}();
        _warmOracle();

        for (uint256 i = 0; i < 2; i++) {
            address b = address(uint160(0x5000 + i));
            vm.deal(b, 1_000 ether);
            vm.prank(b);
            market.openPosition{value: 4 ether}(2 * WAD, 0);
            _warmOracle();
        }
        assertGt(market.liquidationHealthOf(address(uint160(0x5000))), WAD, "setup: the book must NOT be impaired");
        assertFalse(hook.isProtected(id), "setup: the market must trust its price");
    }

    /// Sells `mult` times the pool's own token side into it.
    function _dump(uint256 mult) internal {
        (, uint256 tokenSide) = market.positionReserves();
        uint256 bag = tokenSide * mult;
        token.transfer(arb, bag);
        vm.prank(arb);
        token.approve(address(router), type(uint256).max);
        vm.prank(arb);
        router.swap(
            LeverageRouter.SwapArgs({
                key: key,
                zeroForOne: false,
                amountSpecified: -int256(bag),
                sqrtPriceLimitX96: MAX_LIMIT,
                amountBound: 0,
                recipient: arb,
                deadline: type(uint256).max
            })
        );
    }

    /// The attacker enters as an ordinary LP at the honest, already-impaired price.
    function _attackerBecomesAnLp() internal returns (uint256 shares) {
        vm.deal(keeper, 10_000 ether);
        vm.prank(keeper);
        shares = market.deposit{value: 60 ether}();
        assertGt(shares, 0, "setup: the attacker must hold shares to redeem");
    }

    /// The honest baseline: hold the shares, redeem them, take what the book is really worth.
    function _honestProfit(uint256 shares) internal returns (int256) {
        uint256 before = keeper.balance;
        vm.prank(keeper);
        market.redeem(shares);
        return int256(keeper.balance) - int256(before);
    }

    // ---------------------------------------------------------------- the three exploits

    /// EXPLOIT 1, the atomic one. `openPosition{value: X}(WAD, 0)` borrows nothing, so it was a
    /// pure collateral deposit that the aggregate formula counted as backing for everybody
    /// else's debt — and being debt-free it sails past every capacity and health gate. Open,
    /// redeem against the lifted mark, close to take the collateral back.
    function test_atomicZeroDebtOpenCannotProfit() public {
        _impairedBook();
        uint256 shares = _attackerBecomesAnLp();

        uint256 snap = vm.snapshotState();
        int256 honest = _honestProfit(shares);
        vm.revertToState(snap);

        uint256 before = keeper.balance;
        vm.prank(keeper);
        try market.openPosition{value: 15 ether}(WAD, 0) {
            vm.prank(keeper);
            market.redeem(shares);
            vm.prank(keeper);
            market.closePosition(0);
        } catch {}
        int256 exploit = int256(keeper.balance) - int256(before);

        assertLe(exploit, honest, "the zero-debt open must not beat simply redeeming");
    }

    /// EXPLOIT 2, and the one that matters most, because it is not a degenerate zero-debt
    /// artefact. A GENUINE, healthy, debt-bearing 1.2x borrower masks the impairment just as
    /// well: its collateral vastly exceeds the debt it secures, and the surplus was credited to
    /// everyone else. This position is filed in the book and opens normally, so the
    /// zero-leverage refusal cannot be what makes this test pass.
    ///
    /// The size arrives through `addCollateral`, which has no capacity gate — the hole the
    /// audit named. Opening at this size directly is refused by the capacity gate for an
    /// unrelated reason (a trader may not borrow against equity arriving in the same call), so
    /// routing through `addCollateral` is what makes the exploit reachable at all.
    function test_healthyBorrowerVariantCannotProfit() public {
        _impairedBook();
        uint256 shares = _attackerBecomesAnLp();

        uint256 snap = vm.snapshotState();
        int256 honest = _honestProfit(shares);
        vm.revertToState(snap);

        uint256 before = keeper.balance;
        vm.prank(keeper);
        market.openPosition{value: 2 ether}((WAD * 12) / 10, 0);
        vm.prank(keeper);
        market.addCollateral{value: 15 ether}(0);
        vm.prank(keeper);
        market.redeem(shares);
        vm.prank(keeper);
        market.closePosition(0);
        int256 exploit = int256(keeper.balance) - int256(before);

        assertLe(exploit, honest, "a healthy 1.2x borrower must not beat simply redeeming");
    }

    /// THE CONTROL. The identical script on an UNIMPAIRED book loses money — it always did,
    /// because a round trip through the pool pays the fee twice. This is what proves the two
    /// tests above are measuring the mark: if the script were unprofitable merely because
    /// opening is refused, or because trading costs dominate, it would look exactly like this
    /// here, and the impaired case would have nothing extra to explain.
    function test_theSameScriptOnAnUnimpairedBookIsUnprofitable() public {
        _healthyBook();
        uint256 shares = _attackerBecomesAnLp();

        uint256 snap = vm.snapshotState();
        int256 honest = _honestProfit(shares);
        vm.revertToState(snap);

        uint256 before = keeper.balance;
        vm.prank(keeper);
        market.openPosition{value: 2 ether}((WAD * 12) / 10, 0);
        vm.prank(keeper);
        market.addCollateral{value: 15 ether}(0);
        vm.prank(keeper);
        market.redeem(shares);
        vm.prank(keeper);
        market.closePosition(0);
        int256 exploit = int256(keeper.balance) - int256(before);

        assertLe(exploit, honest, "the script must not profit on a healthy book either");
    }

    // ---------------------------------------------------------------- the mark itself

    /// The mark, isolated from every fee and gate: collateral posted to one position cannot
    /// raise the marked value of anybody else's debt by a single wei.
    ///
    /// `addCollateral` is NAV-neutral for the market by construction — ETH comes in, the tokens
    /// it buys leave again as the BORROWER's collateral, which `ownedTokens` excludes. So the
    /// exact expected movement is zero. Under the aggregate formula the same call moved NAV by
    /// +4.44 ETH: value the market invented for itself and paid out to whoever redeemed next.
    function test_collateralOnOnePositionCannotLiftAnotherPositionsMark() public {
        _impairedBook();

        vm.deal(keeper, 10_000 ether);
        vm.prank(keeper);
        market.openPosition{value: 2 ether}((WAD * 12) / 10, 0);

        uint256 markBefore = market.navQuote(false);
        vm.prank(keeper);
        market.addCollateral{value: 15 ether}(0);
        uint256 markAfter = market.navQuote(false);

        assertEq(markAfter, markBefore, "collateral on one position lifted the mark on another's debt");
    }

    // ---------------------------------------------------------------- the book's wiring

    /// A book with no underwater position marks at exactly face, and the read never enters its
    /// loop. That is the case that matters for gas, because navQuote sits inside deposit,
    /// redeem and openPosition.
    function test_aPerformingBookMarksAtExactlyFace() public {
        _healthyBook();
        assertGt(market.totalDebt(), 0, "setup: there must be debt to mark");
        assertEq(market.bookedScaled(), market.totalScaledDebt(), "book must be wired to the ledger");
        assertGt(market.navQuote(false), 0, "a performing book must still have a NAV");
    }

    /// A freshly opened, levered position is never haircut. The origination LTV gate keeps its
    /// normalised liquidation price well below the price bucket, so it cannot open into the one
    /// bucket where the bound is approximate. Under a coarser bucket geometry this would have
    /// been a permanent, systematic depression of `sharePriceWad` — the number the UI shows and
    /// the number redeeming LPs are paid at — for every new borrower.
    function test_aFreshMaxLeveragePositionIsNotHaircut() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 120 ether}();
        _warmOracle();

        uint256 navBefore = market.navQuote(false);
        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);

        // The borrowed ETH left the market and came back as a receivable. If that receivable
        // were haircut on origination, NAV would fall the moment the position opened and every
        // LP would pay for a loss that has not happened.
        assertGe(market.navQuote(false) + 0.2 ether, navBefore, "a fresh position must not be haircut");
        assertEq(market.bookedScaled(), market.totalScaledDebt(), "book must be wired to the ledger");
    }

    /// Interest cannot migrate a position between buckets, so `accrue()` is deliberately not a
    /// book write site and there is no staleness story to tell. The bucket key is
    /// `scaledDebt / collateral`, which contains no borrowIndex, and the read normalises the
    /// price by that same index.
    function test_accrualNeverNeedsABookRewrite() public {
        _healthyBook();
        uint256 t = block.timestamp;
        uint256 indexBefore = market.borrowIndex();
        for (uint256 i = 0; i < 8; i++) {
            // Absolute warps. `vm.warp(block.timestamp + dt)` in a loop does NOT advance under
            // via_ir: the optimiser hoists block.timestamp out of the loop.
            t += 30 days;
            vm.warp(t);
            market.accrue();
            assertEq(market.bookedScaled(), market.totalScaledDebt(), "book drifted across an accrual");
        }
        assertGt(market.borrowIndex(), indexBefore, "setup: interest must actually have accrued");
    }

    /// Every position write site keeps the book in lockstep. Five sites mutate `positions`, and
    /// a missed one fails SILENTLY — no revert, just a mark that is quietly wrong, which is the
    /// same class of defect the book exists to fix.
    function test_everyPositionWriteSiteKeepsTheBookWired() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 120 ether}();
        _warmOracle();
        assertEq(market.bookedScaled(), market.totalScaledDebt(), "after deposit");

        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);
        assertEq(market.bookedScaled(), market.totalScaledDebt(), "after openPosition");

        vm.prank(trader);
        market.addCollateral{value: 1 ether}(0);
        assertEq(market.bookedScaled(), market.totalScaledDebt(), "after addCollateral");

        vm.prank(trader);
        market.repay{value: 0.5 ether}();
        assertEq(market.bookedScaled(), market.totalScaledDebt(), "after repay");

        vm.prank(trader);
        market.closePosition(0);
        assertEq(market.bookedScaled(), market.totalScaledDebt(), "after closePosition");
        assertEq(market.bookedScaled(), 0, "a closed-out book holds nothing");
    }

    /// A full liquidation clears the book by the same door as a close; a partial one re-files
    /// the position with what is left of it.
    function test_liquidationKeepsTheBookWired() public {
        _impairedBook();
        address b = address(uint160(0x5000));
        assertLt(market.liquidationHealthOf(b), WAD, "setup: liquidatable");

        vm.prank(keeper);
        market.liquidate(b, 0);
        assertEq(market.bookedScaled(), market.totalScaledDebt(), "after liquidate");
    }

    /// A zero-leverage open borrows nothing, and is refused rather than silently booked as a
    /// free collateral deposit wearing a leveraged position's clothes.
    function test_aZeroLeverageOpenIsRefused() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 120 ether}();
        _warmOracle();
        vm.prank(trader);
        vm.expectRevert(LeverageMarket.NothingToDo.selector);
        market.openPosition{value: 2 ether}(WAD, 0);
    }

    /// The per-position mark is a TIGHTENING, never a loosening: it can never exceed the
    /// aggregate formula it replaced, at any price, on any book. `navQuote(true)` deliberately
    /// keeps that aggregate as an upper bound for the deposit side, so it must dominate
    /// `navQuote(false)` — otherwise the LP entry/exit spread would be inverted and depositing
    /// then immediately redeeming would be free money. Fuzzed over the impairment depth.
    function testFuzz_theEntryMarkAlwaysDominatesTheExitMark(uint256 dumpMult) public {
        dumpMult = bound(dumpMult, 1, 6);

        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 120 ether}();
        _warmOracle();
        vm.prank(trader);
        market.openPosition{value: 4 ether}(2 * WAD, 0);
        _warmOracle();

        _dump(dumpMult);
        _warmOracle();
        _warmOracle();

        assertGe(market.navQuote(true), market.navQuote(false), "the entry mark must dominate the exit mark");
        assertEq(market.bookedScaled(), market.totalScaledDebt(), "book must stay wired");
    }

    // --------------------------------------------------- the deposit side of the same defect

    // HONEST NOTE ON COVERAGE. `navQuote(true)` was moved off the old aggregate formula onto
    // the same per-position mark as `navQuote(false)`, because an adversary showed the
    // asymmetry left the injection primitive alive with the DEPOSITOR as its victim. That
    // change is reasoned, not measured: three attempts to build a regression that fails against
    // the aggregate and passes against the per-position mark all passed BOTH ways.
    //
    // Why it is hard here: every route that posts masking collateral also buys tokens, which
    // lifts the price and un-impairs the book before the mark can be read; and once the
    // aggregate pins at `face`, the two formulas agree. A test that discriminates needs a
    // fixture where the masker's collateral is large in TOKEN terms at the moment of
    // measurement — which means minting it before the decline without moving the price, i.e. a
    // seeded position rather than a bought one.
    //
    // Recorded in contracts/AUDIT.md as an uncovered property. Do not read the test below as
    // covering it: it asserts an ordering that holds under both formulas.

    function test_theEntryMarkIsNotAboveWhatTheExitMarkWillPay() public {
        // The masking position is built BEFORE the decline. Adding it afterwards buys tokens,
        // which lifts the price and un-impairs the book before the mark can be read — which is
        // why two earlier versions of this test passed against both formulas.
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 120 ether}();
        _warmOracle();

        // Two ordinary leveraged borrowers, who will go underwater.
        for (uint256 i = 0; i < 2; i++) {
            address b = address(uint160(0x5000 + i));
            vm.deal(b, 1_000 ether);
            vm.prank(b);
            market.openPosition{value: 4 ether}(2 * WAD, 0);
            _warmOracle();
        }

        // The masker: minimal debt, large collateral. After the decline its collateral still
        // covers its own small debt with surplus, and an AGGREGATE mark donates that surplus to
        // the two underwater receivables.
        address masker = address(uint160(0x7001));
        vm.deal(masker, 2_000 ether);
        vm.prank(masker);
        market.openPosition{value: 1 ether}((WAD * 101) / 100, 0);
        _warmOracle();
        vm.prank(masker);
        market.addCollateral{value: 60 ether}(0);
        _warmOracle();

        _dump(6);
        _warmOracle();
        _warmOracle();

        assertLt(market.liquidationHealthOf(address(uint160(0x5000))), WAD, "setup: the book must be impaired");
        assertGt(market.liquidationHealthOf(masker), WAD, "setup: the masker must be over-collateralised");
        assertFalse(hook.isProtected(id), "setup: the market must trust its price");

        uint256 entry = market.navQuote(true);
        uint256 exit_ = market.navQuote(false);

        // Both marks read the same recoverable figure; they may differ only by which PRICE they
        // use — issuance marks down, redemption marks up — never by which formula. Under the
        // old asymmetry, entry carried the masker's surplus into every other receivable while
        // exit did not, so the gap was the masked impairment rather than the price spread.
        // Ordering only. This DOES catch a mark that quotes entry below exit — a one-way
        // ratchet that would let a depositor mint against a book cheaper than the one they can
        // redeem from. It does NOT catch the aggregate-versus-per-position choice; see the note
        // above.
        assertGe(entry, exit_, "issuance must never quote below redemption");
    }
}
