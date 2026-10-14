// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrTypes} from "../../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../../src/support/HookrToken.sol";
import {IHookrLaneRoot} from "../../../src/interfaces/IHookrLaneRoot.sol";
import {MockIdleExecutor} from "../../mocks/MockIdleExecutor.sol";
import {LaneFixture} from "../LaneFixture.sol";
import {GasMeasure} from "../../utils/GasMeasure.sol";
import {ScriptedExecutor} from "../mocks/ScriptedExecutor.sol";
import {IHookrLaneEvents} from "../../../src/interfaces/IHookrLaneEvents.sol";

/// @notice Hostile executors on the lane inside HookrRoot. Every failure fails open, the swap
///         completes, and Rules' claims back every liability.
contract LaneHostileRoot is LaneFixture, GasMeasure {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    ScriptedExecutor internal exec;
    PoolKey internal key;
    PoolKey internal other;
    PoolKey internal noopKey;
    PoolKey internal plainNoLane;

    struct Tally {
        uint256 failed;
        uint256 succeeded;
        bytes4 lastReason;
        uint256 pushed;
    }

    function setUp() public {
        _setUpLane();
        /// @dev Does nothing and returns zero: the lane mechanism's own cost.
        MockIdleExecutor noop = new MockIdleExecutor();
        _openLane(address(noop));
        noopKey = _launchLane(_rc(true), 2500, 1);
        plainNoLane = _launchLane(_rc(false), 2500, 1);
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e28);
        exec.setRoot(address(root));
        _openLane(address(exec));
        key = _launchLane(_rc(true), 2500, 0);
        other = _launchLane(_rc(true), 2500, 0);
        exec.setOther(other);
    }

    function _rc(bool on) internal pure returns (HookrTypes.RecaptureConfig memory c) {
        if (!on) return c;
        c.on = true;
        c.traderBps = 2000;
        c.lpBps = 8000;
        c.releaseBlocks = RELEASE;
    }

    function _launchLane(HookrTypes.RecaptureConfig memory rc, uint16 share, uint16 lpBps)
        internal
        returns (PoolKey memory k)
    {
        HookrToken t = new HookrToken("S", "S", 1e30, address(this));
        t.approve(address(launcher), type(uint256).max);
        t.transfer(whale, 1e26);
        vm.prank(whale);
        t.approve(address(router), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        IHookrLauncher.Member memory m = members[0];
        m.quote = ETH;
        m.tickSpacing = 60;
        m.sqrtPriceX96 = SQRT_ONE;
        m.tickLower = -60_000;
        m.tickUpper = 60_000;
        m.liquidity = 1e24;
        m.amount0Max = 1e24;
        m.amount1Max = 1e24;
        m.config.rules = address(rules);
        m.config.baseLpFeePips = BASE_FEE;
        m.config.caps = HookrTypes.Caps(600_000, 200_000, 1000);
        m.config.rulesGasLimit = 2_000_000;
        m.config.policyId = keccak256("lane-hostile");
        m.rules.maxFeePips = BASE_FEE;
        m.rules.protocolShareBps = share;
        m.rules.lpBps = lpBps;
        m.recapture = rc;
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(t), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        k = launcher.position(family, 0).key;
    }

    function _tally(Vm.Log[] memory logs) internal view returns (Tally memory o) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(root)) continue;
            if (logs[i].topics[0] == FAILED) {
                o.failed++;
                o.lastReason = abi.decode(logs[i].data, (bytes4));
            } else if (logs[i].topics[0] == SUCCEEDED) {
                o.succeeded++;
                (, uint256 p) = abi.decode(logs[i].data, (uint256, uint256));
                o.pushed += p;
            }
        }
    }

    function _run(ScriptedExecutor.Mode mode, uint256 amount) internal returns (Tally memory o, uint256 out) {
        exec.set(mode, amount);
        vm.recordLogs();
        out = _buy(key, ETH, whale, 1e20);
        o = _tally(vm.getRecordedLogs());
        assertGt(out, 0, "the swap completed");
        assertTrue(rules.accountingInvariant(ETH), "claims back every liability");
        assertEq(manager.balanceOf(address(root), ETH.toId()), 0, "root holds no claims");
    }

    function _assertFailedTwice(Tally memory o, bytes4 reason) internal pure {
        assertEq(o.failed, 2, "both phases failed open");
        assertEq(o.succeeded, 0);
        assertEq(o.lastReason, reason);
    }

    // ───────────── the lane mechanism's own cost (an executor that returns 0) ─────────────

    function test_gas_noop_lane_buy() public {
        _buy(noopKey, ETH, minnow, 1e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.recordLogs();
        _buy(noopKey, ETH, whale, 1e18);
        _measure("root.noopLane.buy");
        Tally memory o = _tally(vm.getRecordedLogs());
        assertEq(o.succeeded, 2);
    }

    /// Same rules, no lane: a lane pool is never fee-only, so compare with the full path by giving the plain pool the
    /// same rules call (the protocol share alone keeps it fee-only; see root.noLane rows in LaneBenchRoot).
    function test_gas_noLane_buy() public {
        _buy(plainNoLane, ETH, minnow, 1e18);
        vm.roll(vm.getBlockNumber() + 1);
        _buy(plainNoLane, ETH, whale, 1e18);
        _measure("root.noLaneSameRules.buy");
    }

    // ───────────── hostile executors ─────────────

    function test_hostile_revertFailsOpen() public {
        (Tally memory o,) = _run(ScriptedExecutor.Mode.REVERT, 0);
        _assertFailedTwice(o, ScriptedExecutor.Boom.selector);
    }

    function test_hostile_openDeltaUnwound() public {
        (Tally memory o,) = _run(ScriptedExecutor.Mode.LEAVE_DELTA, 0);
        _assertFailedTwice(o, IHookrLaneEvents.LaneLeftDelta.selector);
    }

    function test_hostile_syncLeftUnwound() public {
        (Tally memory o,) = _run(ScriptedExecutor.Mode.LEAVE_SYNC, 0);
        _assertFailedTwice(o, IHookrLaneEvents.LaneLeftSync.selector);
    }

    function test_hostile_giftToRootUnwound() public {
        (Tally memory o,) = _run(ScriptedExecutor.Mode.GIFT_ROOT, 1e18);
        _assertFailedTwice(o, IHookrLaneEvents.LaneLeftDelta.selector);
    }

    function test_hostile_badReturnUnwound() public {
        (Tally memory o,) = _run(ScriptedExecutor.Mode.BAD_RETURN, 0);
        _assertFailedTwice(o, IHookrLaneEvents.LaneBadReturn.selector);
    }

    function test_hostile_gasBurnBoundedByGrant() public {
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        uint256 g0 = gasleft();
        _buy(key, ETH, whale, 1e20);
        uint256 baseline = g0 - gasleft();
        exec.set(ScriptedExecutor.Mode.BURN_GAS, 0);
        vm.recordLogs();
        g0 = gasleft();
        _buy(key, ETH, whale, 1e20);
        uint256 burned = g0 - gasleft();
        Tally memory o = _tally(vm.getRecordedLogs());
        _assertFailedTwice(o, IHookrLaneEvents.LaneOutOfGas.selector);
        assertLe(burned, baseline + 2 * uint256(LANE_GAS) + 100_000, "worst case is two grants plus the swap");
        console2.log("burned by a gas-burning executor", burned);
    }

    function test_hostile_unbackedSinkRefused() public {
        (Tally memory o,) = _run(ScriptedExecutor.Mode.SINK_UNBACKED, 1e18);
        _assertFailedTwice(o, IHookrLaneEvents.SinkUnbacked.selector);
    }

    /// A push the executor swallowed never happened: the frame returns with nothing pushed, whatever the call
    /// returned, and nothing is split.
    function test_hostile_swallowedSinkIsNoPush() public {
        uint256 before = rules.claimable(ETH, protocol);
        (Tally memory o,) = _run(ScriptedExecutor.Mode.SINK_SWALLOW, 1e18);
        assertEq(o.failed, 0);
        assertEq(o.succeeded, 2);
        assertEq(o.pushed, 0);
        assertEq(rules.claimable(ETH, protocol), before, "nothing split");
    }

    /// An executor that returns more than it pushed is split as its push; `partnerBps()` is never read.
    function test_hostile_skimIsSplitAsItsPush() public {
        vm.expectCall(address(exec), abi.encodeWithSignature("partnerBps()"), 0);
        (Tally memory o,) = _run(ScriptedExecutor.Mode.SKIM, 1e18);
        assertEq(o.failed, 0);
        assertEq(o.succeeded, 2);
        assertEq(o.pushed, 2 * 5e17);
        assertEq(rules.claimable(ETH, protocol), 2 * _cut(_profitOf(5e17), 5e17));
    }

    function test_partnerTwentyFivePercentSplitsFromTheProfitThePushStandsFor() public {
        (Tally memory o,) = _run(ScriptedExecutor.Mode.PUSH_NET, 1e18);
        assertEq(o.succeeded, 2, "75% of a profit of 1e18 pushed at the pinned 25%");
        assertEq(o.pushed, 2 * (1e18 - 2.5e17));
        // The protocol's 25% of the profit the push stands for (7.5e17 at 25%: 1e18) first; the scripted push undoes
        // nothing of the whale's buy, so the trader leg is zero.
        assertEq(rules.claimable(ETH, protocol), 2 * (1e18 * 25 / 100));
        assertEq(rules.claimable(ETH, whale), 0);
    }

    function test_hostile_sinkForOtherPoolRefused() public {
        (Tally memory o,) = _run(ScriptedExecutor.Mode.SINK_WRONG_POOL, 1e18);
        _assertFailedTwice(o, IHookrLaneEvents.SinkClosed.selector);
    }

    /// A leg after a push runs: an executor pushes after each cycle and legs again.
    function test_legAfterAPushRuns() public {
        (Tally memory o,) = _run(ScriptedExecutor.Mode.PUSH_THEN_LEG, 1e18);
        assertEq(o.succeeded, 2);
        assertEq(o.pushed, 2e18);
        assertEq(exec.lastLegError().length, 0, "the leg after the push ran");
    }

    function test_hostile_legBothWaysRefused() public {
        exec.set(ScriptedExecutor.Mode.LEG_BOTH_WAYS, 1e18);
        _buy(key, ETH, whale, 1e20);
        assertGt(exec.lastLegError().length, 0, "the reverse leg was refused");
    }

    function test_legThroughOtherPoolIsAnOrdinarySwapWithoutALane() public {
        (uint160 before,,,) = manager.getSlot0(other.toId());
        uint256 calls = exec.calls();
        uint256 protocolBefore = rules.claimable(ETH, protocol);
        (Tally memory o,) = _run(ScriptedExecutor.Mode.LEG_OTHER_POOL, 1e18);
        assertEq(o.succeeded, 2, "both frames passed with a nested swap inside");
        assertEq(exec.calls() - calls, 2, "the nested swap ran no lane of its own");
        (uint160 afterPrice,,,) = manager.getSlot0(other.toId());
        assertTrue(afterPrice != before, "the leg moved the other pool");
        assertEq(rules.claimable(ETH, protocol), protocolBefore, "no quote take on a 1% base-only pool");
        assertTrue(rules.accountingInvariant(ETH));
    }

    function test_legOnTriggeringPoolPaysBaseFee() public {
        uint256 snap = vm.snapshotState();
        exec.set(ScriptedExecutor.Mode.LEG_SAME_POOL, 1e22);
        _buy(key, ETH, whale, 1e18);
        uint256 insideOut = exec.legOuts(0);
        vm.revertToState(snap);
        exec.set(ScriptedExecutor.Mode.REVERT, 0);
        uint256 outsideOut = exec.outsideSwap(key, 1e22);
        assertApproxEqRel(insideOut, outsideOut, 0.002e18, "a leg pays the base LP fee like an ordinary swap");
    }

    function test_sinkClosedOutsideFrame() public {
        vm.prank(address(exec));
        vm.expectRevert(IHookrLaneEvents.SinkClosed.selector);
        IHookrLaneRoot(address(root)).settleRecapture(key, key.currency0, 1e18);
        vm.prank(attacker);
        vm.expectRevert(IHookrLaneEvents.SinkClosed.selector);
        IHookrLaneRoot(address(root)).settleRecapture(key, key.currency0, 1e18);
    }

    function test_moduleRefusesDirectCalls() public {
        // The module is only ever DELEGATECALLed by its root.
        address module = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(root), bytes1(0x01)))))
        );
        assertGt(module.code.length, 0, "the root deployed its module at nonce 1");
        vm.expectRevert();
        IHookrLaneRoot(module).settleRecapture(key, key.currency0, 1e18);
    }
}
