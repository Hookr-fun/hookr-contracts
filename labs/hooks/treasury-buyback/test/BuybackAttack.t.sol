// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {HookrBuybackBurn} from "../src/HookrBuybackBurn.sol";
import {BuybackBase} from "./BuybackBase.sol";

/// @notice The attacks on a buyback priced off the shared log, on a pool nobody arbitrages (the worst case: every
///         price the attacker sets stays until they move it). Each measures what the attacker gets.
contract BuybackAttackTest is BuybackBase {
    function hookrIs0() internal pure virtual override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        warmUp();
        fund(100e18);
    }

    /// @notice 1. Pump HOOKR in the same transaction and trigger the buyback into it: the floor refuses anything past
    ///         the 300 bps allowance, whatever the pump.
    function test_attack_sameTransactionPumpIsRefused() public {
        moveTo(400); // ~4.1% over the reference
        vm.expectRevert("TestBuybackRouter: bound");
        buyback.buyback(1e18);
        assertEq(burned(), 0);
    }

    /// @notice 2. Pump, record, and keep the price up until the buyback a few minutes later, before anyone records
    ///         again: the one clamped record lifts the mean by its weight, so the buyback pays at most the floor's
    ///         300 bps plus that lift over the reference.
    function test_attack_oneOwnedRecordAddsAtMostItsWeightToTheFloor() public {
        (, int24 ref) = plog.mean(logId, 1800);
        wait(300);
        moveTo(5000);
        plog.record(logId); // clamped to +500
        wait(299);
        (, int24 lifted) = plog.mean(logId, 1800);
        // In HOOKR's orientation (higher = pricier).
        int256 lift = hookrIs0() ? int256(lifted) - ref : int256(ref) - lifted;
        console2.log("one owned record standing 299 s lifts the 1800 s mean by (ticks)", lift);
        // Hold the pool at the highest price the floor still accepts, and sell into the buyback.
        uint256 fair = expectedAt(CAP, ref);
        int24 lo = 0;
        int24 hi = 1000;
        for (uint256 i; i < 12; ++i) {
            int24 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            moveTo(mid);
            bool ok;
            try buyback.buyback(CAP) {
                ok = true;
            } catch {}
            vm.revertToState(snap);
            if (ok) lo = mid;
            else hi = mid;
        }
        moveTo(lo);
        uint256 out = buyback.buyback(CAP);
        uint256 lossBps = (fair - out) * 10_000 / fair;
        console2.log("highest held price the buyback took, ticks over the reference", int256(lo));
        console2.log("HOOKR short of fair on one cap (bps)", lossBps);
        assertLe(lift, 84, "500 x 299 / 1800");
        // 300 bps floor + the lift + the pool's 0.30% fee and the cap's own impact.
        assertLt(lossBps, 300 + 84 + 30 + 30);
    }

    /// @notice 3. Own every record for a whole window and hold the price there (the log's pinned limitation, the
    ///         recorder's SL-2 here): the reference follows the held price, so each cap buys at the held price. The
    ///         spend limit bounds it to one cap per period, never the balance.
    function test_attack_heldPriceBuysOneCapAPeriod() public {
        uint256 fair = expectedAt(CAP, 0);
        // Walk to +2000 (~22%) in clamped steps and hold for a window.
        holdAt(2000, 4);
        holdAt(2000, 7);
        uint256 out = buyback.buyback(CAP);
        console2.log("held +2000 for a window: HOOKR short of fair on one cap (bps)", (fair - out) * 10_000 / fair);
        assertGt((fair - out) * 10_000 / fair, 1500, "limitation: a held reference buys at the held price");
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.SpendLimitExceeded.selector, 1, 0));
        buyback.buyback(1);
        assertEq(quote.balanceOf(address(buyback)), 100e18 - CAP, "the rest of the balance is untouched");
    }

    /// @notice 4. Dumping HOOKR before the buyback only hands it more HOOKR per quote.
    function test_attack_dumpBeforeTheBuybackPaysTheBuyback() public {
        uint256 fair = expectedAt(CAP, 0);
        moveTo(-1000);
        uint256 out = buyback.buyback(CAP);
        assertGt(out, fair, "bought cheap from the dumper");
    }

    /// @notice 5. Records cannot be stacked to warm a fresh log faster: one per interval, so a buyback bound to a new
    ///         pool waits a full window whoever records.
    function test_attack_recordSpamCannotShortenTheWarmUp() public {
        uint256 c = plog.count(logId);
        for (uint256 i; i < 10; ++i) {
            vm.prank(address(uint160(0xA000 + i)));
            plog.record(logId);
        }
        assertEq(plog.count(logId), c);
    }
}

contract BuybackAttackFlippedTest is BuybackAttackTest {
    function hookrIs0() internal pure override returns (bool) {
        return false;
    }
}
