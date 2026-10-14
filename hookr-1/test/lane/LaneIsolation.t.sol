// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice Lane isolation on HookrRoot: several pushes in one frame, executor legs on a King of the Pool pool never
///         lead, the root's entry points refuse strangers, pools without a lane on the same root ignore a hostile
///         executor, a broken recapture module stops only the pools that reach it, and a quote runs the arb
///         recaptures without keeping their state.
contract LaneIsolationTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ScriptedExecutor internal exec;
    PoolKey internal key;
    PoolKey internal recaptureOnly;
    PoolKey internal stdKey;
    Currency internal tb;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e28);
        tokenB.transfer(address(exec), 1e27);
        exec.setRoot(address(root));
        _openLane(address(exec));
        tb = Currency.wrap(address(tokenB));
        key = _openKoth(ETH);
        recaptureOnly = _openRecapture(ETH);
        stdKey = _openStd(tb);
    }

    /// Two pushes in one frame are credited as one split of their sum.
    function test_sinkTwiceInOneArbRecapture() public {
        exec.set(ScriptedExecutor.Mode.SINK_TWICE, 9e18);
        (,,, uint128 potBefore) = _hill(key);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        Splits memory t = _splits(logs);
        assertEq(o.succeeded, 2);
        assertEq(o.pushedBefore + o.pushedAfter, 4 * 9e18);
        assertEq(t.count, 2, "one split per frame");
        (,, uint256 potLeg,) = _split(18e18, false, POT_BPS, TRADER_BPS);
        (,,, uint128 pot) = _hill(key);
        assertEq(pot - potBefore, 2 * potLeg);
    }

    /// The executor's legs on a King of the Pool pool pay the base LP fee (not the pool's LP Rewards) and never lead,
    /// and an unauthenticated ordinary swap cannot lead either.
    function test_legOnTriggeringPoolIsRuleFreeAndNeverLeads() public {
        uint256 snap = vm.snapshotState();
        exec.set(ScriptedExecutor.Mode.LEG_SAME_POOL, 1e22);
        _buy(key, ETH, whale, 1e18);
        uint256 insideOut = exec.legOuts(0);
        (, address leader, uint128 amount,) = _hill(key);
        assertEq(leader, whale, "the executor's 1e22 legs never lead");
        assertEq(amount, 1e18);
        vm.revertToState(snap);
        exec.set(ScriptedExecutor.Mode.REVERT, 0);
        uint256 outsideOut = exec.outsideSwap(key, 1e22);
        assertGt(insideOut, outsideOut, "an ordinary swap pays the LP Rewards and the quote take, a leg does not");
        (, leader,,) = _hill(key);
        assertEq(leader, address(0), "an unauthenticated executor swap cannot lead either");
    }

    /// The frame input (a PoolKey and a trader) from anyone but the root itself is refused.
    function test_laneFrame_selfOnly() public {
        (bool ok, bytes memory ret) = address(root).call(abi.encode(key, attacker));
        assertFalse(ok);
        assertEq(bytes4(ret), IHookrRootEvents.Unauthorized.selector);
    }

    function test_callbacks_managerOnly() public {
        HookrTypes.PoolConfig memory pc;
        vm.expectRevert(IHookrRootEvents.Unauthorized.selector);
        root.initializePool(key, pc, "", "", SQRT_ONE);
        vm.expectRevert(IHookrRootEvents.Unauthorized.selector);
        root.takeReceipt(key.toId());
        vm.expectRevert(IHookrRootEvents.Unauthorized.selector);
        root.beforeSwap(attacker, key, SwapParams(true, -1, MIN_PRICE), "");
        vm.expectRevert(IHookrRootEvents.Unauthorized.selector);
        root.beforeAddLiquidity(attacker, key, ModifyLiquidityParams(-60, 60, 1, 0), "");
    }

    /// Pools without a lane on the same root never call the executor, whatever it does.
    function test_isolation_poolsWithoutALaneIgnoreAHostileExecutor() public {
        exec.set(ScriptedExecutor.Mode.BURN_GAS, 0);
        uint256 calls = exec.calls();
        _buy(stdKey, tb, whale, 1e21);
        _sell(stdKey, tb, whale, 1e20);
        assertEq(exec.calls(), calls, "no lane call on a pool without a lane");
        assertTrue(rules.accountingInvariant(tb));
    }

    /// A broken recapture module stops the swaps that reach it (a King of the Pool pool's settlement), and nothing else:
    /// pools without recapture on the same Rules keep trading.
    function test_isolation_aBrokenRecaptureModuleStopsOnlyThePoolsThatReachIt() public {
        (address module,) = _recap().recaptureModule();
        vm.etch(module, hex"60006000fd");
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        IHookrRouter.Swap memory p = _swapParams(key, ETH, true, true, 1e20, whale);
        vm.prank(whale);
        vm.expectRevert();
        router.swap{value: 1e20}(p, address(0), new uint256[](0));
        _buy(stdKey, tb, whale, 1e21);
        _buy(recaptureOnly, ETH, whale, 1e20);
        assertTrue(rules.accountingInvariant(tb));
    }

    /// An executor that closes an elapsed epoch from inside a frame (settleEpoch is permissionless) crowns the leader
    ///  once, as anyone could; the rest of the swap and the new epoch are unaffected.
    function test_anExecutorRollingTheEpochInsideAFrameCrownsTheLeaderOnce() public {
        exec.setRules(address(rules));
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        _buy(key, ETH, whale, 2e22);
        (uint64 start,,, uint128 pot) = _hill(key);
        uint256 whaleBefore = rules.claimable(ETH, whale);
        vm.warp(uint256(start) + PERIOD);
        exec.set(ScriptedExecutor.Mode.SETTLE_EPOCH, 0);
        vm.recordLogs();
        _buy(key, ETH, minnow, 2e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 crowned;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(rules) && logs[i].topics[0] == IHookrRecaptureEvents.KingCrowned.selector) {
                crowned++;
            }
        }
        assertEq(crowned, 1, "one crown for the closed epoch");
        uint256 prize = uint256(2e22) / 100;
        assertEq(rules.claimable(ETH, whale) - whaleBefore, prize < pot ? prize : pot);
        (uint64 next, address leader,,) = _hill(key);
        assertEq(next, start + PERIOD);
        assertEq(leader, minnow, "the swap still leads the new epoch");
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// The quoter runs the swap with its arb recaptures and keeps none of their state.
    function test_quoterSimulatesArbRecaptureWithoutState() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        (,,, uint128 potBefore) = _hill(key);
        IHookrRouter.Swap memory p = _swapParams(key, ETH, true, true, 1e20, whale);
        HookrTypes.ExecutionReceipt memory r = quoter.quote(p, whale);
        assertGt(r.outputAmount, 0);
        (,,, uint128 pot) = _hill(key);
        assertEq(pot, potBefore, "the quote reverted every simulated push");
        assertEq(exec.calls(), 0);
    }
}
