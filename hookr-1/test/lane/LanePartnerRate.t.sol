// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {MockIdleExecutor} from "../mocks/MockIdleExecutor.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";

/// @notice The partner's rate is the one the registry pinned when it opened the lane (at most 2,500 bps). The root
///         never reads the executor's `partnerBps()` nor what its call returns: every push lands, and the profit it
///         stands for is the push at the pinned rate, push x 10,000 / (10,000 - rate), of which the protocol takes 25%.
contract LanePartnerRateTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ScriptedExecutor internal exec;
    PoolKey internal key;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e28);
        exec.setRoot(address(root));
        _openLane(address(exec));
        key = _openKoth(ETH);
    }

    /// @dev Runs an authenticated buy with the executor in `mode` for an amount of 1e19 and returns the count
    ///      of failed and succeeded arb recaptures and the last failure reason.
    function _run(ScriptedExecutor.Mode mode) internal returns (uint256 failed, uint256 succeeded, bytes4 reason) {
        exec.set(mode, 1e19);
        (,,, uint128 potBefore) = _hill(key);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e20);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        (failed, succeeded, reason) = (o.failed, o.succeeded, o.lastReason);
        if (succeeded == 0) {
            (,,, uint128 pot) = _hill(key);
            assertEq(pot, potBefore, "a refused arb recapture leaves the pot");
        }
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// The pinned rate is frozen into the pool and reported by laneOf.
    function test_theQueuedRateIsPinned() public view {
        (,, uint16 partnerBps,,,,) = IHookrLaneRoot(address(root)).laneOf(key.toId());
        assertEq(partnerBps, PARTNER_BPS);
    }

    /// The registry refuses a rate above the agreed 25% at OPEN_LANE, when queued and when executed, and opens one at
    /// it.
    function test_aRateAboveTwentyFivePercentCannotOpen() public {
        bytes memory above = abi.encode(address(root), address(exec), address(exec).codehash, LANE_GAS, uint16(2_501));
        vm.expectRevert(IHookrRegistry.InvalidLane.selector);
        registry.queue(OPEN_LANE, above);
        vm.expectRevert(IHookrRegistry.InvalidLane.selector);
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, LANE_GAS, 2_501);
        _openLane(address(exec), LANE_GAS, 2_500);
        PoolKey memory k = _openKoth(ETH);
        (,, uint16 partnerBps,,,,) = IHookrLaneRoot(address(root)).laneOf(k.toId());
        assertEq(partnerBps, 2_500);
    }

    /// Control: at the pinned rate a push of the profit net of 25% lands in both phases.
    function test_pushNetOfThePinnedRateLands() public {
        (uint256 failed, uint256 succeeded,) = _run(ScriptedExecutor.Mode.PUSH_NET);
        assertEq(failed, 0);
        assertEq(succeeded, 2);
    }

    /// An executor that reports a higher or a lower rate changes nothing: the pinned rate decides.
    function test_theExecutorsReportedRateIsNeverRead() public {
        exec.setPartnerBps(5_000);
        vm.expectCall(address(exec), abi.encodeWithSignature("partnerBps()"), 0);
        (uint256 failed, uint256 succeeded,) = _run(ScriptedExecutor.Mode.PUSH_NET);
        assertEq(failed, 0);
        assertEq(succeeded, 2, "a rate reported above the pinned one does not fail the frame");
        exec.setPartnerBps(0);
        (failed, succeeded,) = _run(ScriptedExecutor.Mode.PUSH_NET);
        assertEq(succeeded, 2, "a rate reported below the pinned one does not raise the push owed");
    }

    /// A push below what the executor returns lands, and is split as the push: the profit is the push at the pinned
    /// rate, whatever the call returned.
    function test_aPushBelowItsReturnIsSplitAsThePush() public {
        exec.set(ScriptedExecutor.Mode.SKIM, 1e19);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        assertEq(o.failed, 0);
        assertEq(o.succeeded, 2);
        assertEq(o.pushedBefore, 5e18);
        assertEq(o.profitBefore, _profitOf(5e18), "the push at the fixture's partner share, not the 1e19 returned");
        assertEq(o.profitAfter, _profitOf(5e18));
        assertEq(_splits(logs).protocol, 2 * _cut(_profitOf(5e18), 5e18));
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// At the agreed 25% the executor keeps 25% of a profit P and pushes 75%: the root reads P back from the push and
    /// the protocol takes 25% of it.
    function test_atTwentyFivePercentThePushStandsForTheWholeProfit() public {
        _openLane(address(exec), LANE_GAS, 2_500);
        PoolKey memory k = _openKoth(ETH);
        exec.setKeepBps(2_500);
        exec.set(ScriptedExecutor.Mode.PUSH_NET, 1e19);
        vm.recordLogs();
        _buy(k, ETH, whale, 1e20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        assertEq(o.succeeded, 2);
        assertEq(o.pushedBefore, 7.5e18, "75% pushed");
        assertEq(o.profitBefore, 1e19, "P read back from the push");
        assertEq(o.profitAfter, 1e19);
        assertEq(_splits(logs).protocol, 2 * 2.5e18, "the protocol's 25% of P in each phase");
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// Below the cap the pool's own pinned rate decides: a lane reopened at 1,000 freezes 1,000 into the pools opened
    /// after it, whose executor keeps 10% of a profit P and pushes 90%; the root reads P back from the push at 1,000 and
    /// the protocol takes 25% of it, while the pool opened before keeps the 2,500 it froze.
    function test_belowTheCapThePushStandsForTheWholeProfitAtThePoolsRate() public {
        _openLane(address(exec), LANE_GAS, 1_000);
        PoolKey memory k = _openKoth(ETH);
        (,, uint16 partnerBps,,,,) = IHookrLaneRoot(address(root)).laneOf(k.toId());
        assertEq(partnerBps, 1_000, "the new pool froze the lower rate");
        (,, partnerBps,,,,) = IHookrLaneRoot(address(root)).laneOf(key.toId());
        assertEq(partnerBps, PARTNER_BPS, "the earlier pool keeps the rate it froze");
        exec.setKeepBps(1_000);
        exec.set(ScriptedExecutor.Mode.PUSH_NET, 1e19);
        vm.recordLogs();
        _buy(k, ETH, whale, 1e20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        assertEq(o.succeeded, 2);
        assertEq(o.pushedBefore, 9e18, "90% pushed");
        assertEq(o.profitBefore, 1e19, "P read back from the push at 1,000");
        assertEq(o.profitAfter, 1e19);
        assertEq(_splits(logs).protocol, 2 * 2.5e18, "the protocol's 25% of P in each phase");
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// A lane opened at 1,500, below the 2,500 cap, still opens, freezes 1,500 into its pools and splits each profit P
    /// at it: the executor keeps 15% of P and pushes 85%, the root reads P back from the push at 1,500, Hookr takes 25%
    /// of P and the remaining 60% goes to the trader, the pot and the LPs as the pool configured.
    function test_aLaneAtFifteenPercentSplitsAtItsOwnRate() public {
        _openLane(address(exec), LANE_GAS, 1_500);
        PoolKey memory k = _openKoth(ETH);
        (,, uint16 partnerBps,,,,) = IHookrLaneRoot(address(root)).laneOf(k.toId());
        assertEq(partnerBps, 1_500, "the new pool froze 1,500");
        exec.setKeepBps(1_500);
        exec.set(ScriptedExecutor.Mode.PUSH_NET, 1e19);
        vm.recordLogs();
        _buy(k, ETH, whale, 1e20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        Splits memory t = _splits(logs);
        assertEq(o.succeeded, 2);
        assertEq(o.pushedBefore, 8.5e18, "85% pushed");
        assertEq(o.profitBefore, 1e19, "P read back from the push at 1,500");
        assertEq(o.profitAfter, 1e19);
        assertEq(t.count, 2);
        assertEq(t.protocol, 2 * 2.5e18, "Hookr's 25% of P in each phase");
        assertEq(t.trader + t.pot + t.lp, 2 * 6e18, "the other 60% of P to the trader, the pot and the LPs");
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// An executor that has no `partnerBps()` at all opens and runs.
    function test_anExecutorWithoutARateGetterWorks() public {
        /// @dev Has no partnerBps().
        MockIdleExecutor rateless = new MockIdleExecutor();
        _openLane(address(rateless));
        PoolKey memory k = _openKoth(ETH);
        vm.recordLogs();
        _buy(k, ETH, whale, 1e20);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2);
        assertEq(o.failed, 0);
    }
}
