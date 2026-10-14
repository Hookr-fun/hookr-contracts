// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {Actor} from "./mocks/Actors.sol";
import {IHookrLaneEvents} from "../../src/interfaces/IHookrLaneEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";
import {ScriptedLaneFixture} from "./utils/ScriptedLaneFixture.sol";

/// @notice The executor's legs inside a frame: a leg after a push runs, the pushes around a leg add up, one
///         direction per pool of the frame (audit finding F-012), a band added earlier does not capture the LP leg
///         (F-014) and the partner's asks (a leg through another pool pays its Rules, the LP leg follows the family).
contract ExecutorLegsTest is ScriptedLaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// F-012. The executor may swap after it pushed: it pushes after each cycle and legs again, and its
    /// pushes add up. One direction per pool per frame still holds (next test).
    function test_legAfterAPushRuns() public {
        exec.set(ScriptedExecutor.Mode.PUSH_THEN_LEG, 1e18);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        Tally memory t = _tally(vm.getRecordedLogs());
        assertEq(exec.lastLegError().length, 0, "the leg after the push ran");
        assertEq(t.failed, 0);
        assertEq(t.succeeded, 2, "the push stands");
        assertEq(t.pushed, 2e18);
    }

    /// F-012. Push, leg, push in one frame: both pushes land as one split of their sum.
    function test_pushesAroundALegAddUp() public {
        exec.set(ScriptedExecutor.Mode.PUSH_LEG_PUSH, 1e18);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        Tally memory t = _tally(vm.getRecordedLogs());
        assertEq(exec.lastLegError().length, 0, "the leg between the pushes ran");
        assertEq(t.failed, 0);
        assertEq(t.succeeded, 2, "one outcome per phase: both pushes are in the quote");
        assertEq(t.splits, 2, "one split per phase");
        assertEq(t.pushed, 4e18, "two pushes of 1e18 in each phase");
        assertEq(t.reported, 2 * _profitOf(2e18), "each split reports the profit of its summed push");
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// F-012. The executor swaps the triggering pool in one direction per frame.
    function test_oneDirectionPerFrame() public {
        exec.set(ScriptedExecutor.Mode.LEG_BOTH_WAYS, 1e18);
        _buy(key, ETH, whale, 1e18);
        assertEq(_wrappedReason(exec.lastLegError()), IHookrLaneEvents.LegDirection.selector);
    }

    /// F-014. The LP leg was donated in the arb recapture's own swap, so a narrow band added one transaction before the
    /// trigger took most of it. It is now a pending donation, donated only from a later block: a band added and removed
    /// within the arb recapture's block collects only swap fees, and the next block's flush pays the whole leg to the
    /// liquidity still in range, here the launch position, whose owner collects it as LP fees.
    function test_bandAddedEarlierDoesNotCaptureLpLeg() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        Actor band = _newActor(key);
        band.modify(key, -600, 600, 1e26);
        _buy(key, ETH, whale, 1e18);
        band.modify(key, -600, 600, -1e26);
        // The scripted push undoes nothing of the whale's buy, so neither phase credits a trader.
        (,,, uint256 lpLeg) = _split(9e18, false, POT_BPS, TRADER_BPS);
        assertEq(_accrued(key), 2 * lpLeg, "LP leg of both phases, pending");
        (,, uint256 fresh0,,) = _recap().pendingDonation(id);
        assertEq(fresh0, 2 * lpLeg, "in this block's bucket");
        // Nobody reaches it directly.
        vm.prank(attacker);
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        _recap().claimPool(id, attacker);
        vm.prank(attacker);
        vm.expectRevert(IHookrLauncher.NotOwner.selector);
        launcher.claimRecapture(family, 0, attacker);
        // The launch position's swap fees so far, collected in the arb recapture's block.
        vm.prank(creator);
        launcher.withdraw(family, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        // Next block: an add outside the range flushes a part of the leg before it lands, to the launch position
        // alone; the rest follows a full release period later.
        vm.roll(vm.getBlockNumber() + 1);
        band.modify(key, 60_000, 60_060, 1e18);
        _flushAll(key);
        assertEq(_accrued(key), 0, "donated");
        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        launcher.withdraw(family, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        uint256 got = creator.balance - creatorBefore;
        assertApproxEqAbs(got, 2 * lpLeg, 2, "the family owner collects the LP leg as fees");
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// Partner ask (i). The executor routes a leg through another pool of this root: an ordinary swap that pays that pool's
    /// full rules and fees, while the profit is still pushed to the triggering pool.
    function test_partner_legThroughOtherPoolPaysItsRules() public {
        exec.setOther(stdKey);
        uint256 snap = vm.snapshotState();
        exec.set(ScriptedExecutor.Mode.REVERT, 0);
        uint256 outsideOut = exec.outsideSwap(stdKey, 1e18);
        vm.revertToState(snap);
        exec.set(ScriptedExecutor.Mode.LEG_OTHER_THEN_PUSH, 1e18);
        uint128 potBefore = _pot();
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Tally memory t = _tally(logs);
        assertEq(t.succeeded, 2);
        assertEq(t.pushed, 2e18, "the profit reached the triggering pool");
        (,, uint256 potLeg,) = _split(1e18, false, POT_BPS, TRADER_BPS);
        assertEq(uint256(_pot() - potBefore), 2 * potLeg);
        assertEq(exec.legOuts(0), outsideOut, "the leg paid exactly what an ordinary swap pays");
        uint256 fees;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(root) && logs[i].topics[0] == HOOK_FEE
                    && logs[i].topics[1] == PoolId.unwrap(stdKey.toId())
            ) {
                fees++;
            }
        }
        assertEq(fees, 2, "the other pool's rules charged each leg");
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// Partner ask (ii): there is no separate creator leg; the LP leg accrues to the launch position and follows the
    /// family, so after a two-step transfer only the new family owner takes it.
    function test_partner_lpLegFollowsTheFamily() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        _buy(key, ETH, whale, 1e18);
        // With the creator's liquidity gone, the pending LP leg becomes the family owner's accrual at its flush.
        _pendingToOwner(key, family, 0, creator);
        uint256 lp = _ownerAccrued(key);
        assertGt(lp, 0);
        address heir = makeAddr("heir");
        vm.prank(creator);
        launcher.transferFamily(family, heir, 0);
        vm.prank(heir);
        launcher.acceptFamily(family);
        vm.prank(creator);
        vm.expectRevert(IHookrLauncher.NotOwner.selector);
        launcher.claimRecapture(family, 0, creator);
        vm.prank(heir);
        assertEq(launcher.claimRecapture(family, 0, heir), 1);
        vm.prank(heir);
        rules.claim(ETH);
        assertEq(heir.balance, lp);
        assertTrue(rules.accountingInvariant(ETH));
    }
}
