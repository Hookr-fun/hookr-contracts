// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLaneEvents} from "../../src/interfaces/IHookrLaneEvents.sol";
import {IHookrLaneRules} from "../../src/interfaces/IHookrLaneRules.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedLaneFixture} from "./utils/ScriptedLaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";

/// @notice The lane's checks on what comes back from the Rules and on who may be the executor, each with a
///         mutation-gate id: a settlement that credits less than the executor pushed is refused (LN-4), and the router
///         is never an executor (LN-5).
contract LaneBoundariesTest is LaneFixture {
    ScriptedExecutor internal exec;
    PoolKey internal key;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e30);
        exec.setRoot(address(root));
        _openLane(address(exec));
        key = _openKoth(ETH);
    }

    function _wrapped(bytes4 callback, bytes memory inner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(root),
            callback,
            inner,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _refusedCredit() internal view returns (bytes memory) {
        return _wrapped(
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(IHookrRootEvents.InvalidModuleResult.selector, address(rules))
        );
    }

    /// LN-4: the Rules must credit exactly what the executor pushed. A settlement that returns one unit short, or one
    /// over, is refused and the swap reverts; with the Rules answering truly, the same buy settles both phases.
    function test_aSettlementCreditThatIsNotThePushIsRefused() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 1e18);
        bytes4 settle = IHookrLaneRules.settleRecapture.selector;
        uint256[2] memory wrong = [uint256(1e18 - 1), uint256(1e18 + 1)];
        for (uint256 i; i < wrong.length; ++i) {
            vm.mockCall(address(rules), abi.encodeWithSelector(settle), abi.encode(wrong[i]));
            IHookrRouter.Swap memory p = _swapParams(key, ETH, true, true, 1e18, whale);
            vm.expectRevert(_refusedCredit());
            vm.prank(whale);
            router.swap{value: 1e18}(p, address(0), new uint256[](0));
            vm.clearMockedCalls();
        }
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        assertEq(_outcome(vm.getRecordedLogs()).succeeded, 2, "both phases settle");
    }

    /// LN-9: a push is backed to the unit. An executor that pushes one unit it never minted fails its frame with
    /// SinkUnbacked in both phases: the swap goes on, nothing is credited and the root keeps no claim.
    function test_aPushOneUnitShortOfItsBackingIsRefused() public {
        exec.set(ScriptedExecutor.Mode.SINK_UNBACKED, 1);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 0);
        assertEq(o.failed, 2);
        assertEq(o.lastReason, IHookrLaneEvents.SinkUnbacked.selector);
    }
}

/// @notice A removal lock the Rules report is read once at the pool's initialization and capped at 100,000 blocks, so a
///         Rules module cannot lock a pool's liquidity forever. Mutation gate LN-6 (the cap was not applied).
contract LaneRemovalLockCapTest is LaneFixture {
    function setUp() public {
        _setUpLane();
        ScriptedExecutor exec = new ScriptedExecutor(manager);
        exec.setRoot(address(root));
        _openLane(address(exec));
    }

    function test_aRulesRemovalLockIsCappedAtTheMaximum() public {
        vm.mockCall(
            address(rules),
            abi.encodeWithSelector(IHookrRules.removalLockedUntil.selector),
            abi.encode(type(uint256).max)
        );
        (, bytes32 family) = _openPoolWithFamily(ETH, _laneRules(false), _recaptureOnlyRc());
        vm.clearMockedCalls();
        uint128 liquidity = launcher.position(family, 0).liquidity;
        vm.prank(creator);
        vm.expectRevert();
        launcher.withdraw(family, 0, liquidity, 0, 0, creator, vm.getBlockTimestamp());
        vm.roll(vm.getBlockNumber() + 100_001);
        vm.prank(creator);
        launcher.withdraw(family, 0, liquidity, 0, 0, creator, vm.getBlockTimestamp());
        assertEq(launcher.position(family, 0).liquidity, 0, "the lock ran out at its cap");
    }
}

/// @notice A lane the registry opened with the router as its executor launches no pool: the lane's executor is never
///         the router or the quoter, whose own swaps it would otherwise run inside. Mutation gate LN-5.
contract LaneRouterExecutorTest is LaneFixture {
    function setUp() public {
        _setUpLane();
        _openLane(address(router));
    }

    function test_theRouterCannotBeTheExecutor() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(ETH, _laneRules(false), _recaptureOnlyRc());
        HookrToken subject = _newSubject();
        vm.expectRevert(IHookrRootEvents.InvalidConfig.selector);
        vm.prank(creator);
        launcher.launch{value: members[0].amount0Max}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
    }
}

/// @notice What a trader's own swap can account for in an arb recapture's push is its quote times its own price move,
///         and a move beyond 4x counts as 4x: a seller who moves the price down by more than that is paid the trader
///         leg on at most three times its quote, not on the whole push. Mutation gate LN-2 (the move was not clamped).
contract LaneMoveBasisTest is ScriptedLaneFixture {
    function test_aMoveBeyondFourTimesCountsAsFourTimes() public {
        // A pool thin enough that a seller of 3e18 subject moves its price down to a sixteenth.
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(ETH, _laneRules(false), _recaptureOnlyRc());
        members[0].liquidity = 1e18;
        (, PoolKey[] memory keys) = _launchAs(creator, _newSubject(), members);
        PoolKey memory thin = keys[0];
        // The executor legs the pool against the seller with a trifle, then pushes 7.5e18, far above three times the
        // seller's roughly 0.75e18 of quote, in both phases.
        ScriptedExecutor.Step[] memory steps = new ScriptedExecutor.Step[](1);
        steps[0] = ScriptedExecutor.Step(thin, true, 1e15);
        exec.setPlan(steps, true, false, ETH);
        exec.set(ScriptedExecutor.Mode.PLAN, 1e19);
        vm.recordLogs();
        _sell(thin, ETH, whale, 3e18);
        Splits memory t = _splits(vm.getRecordedLogs());
        uint256 pushed = 1e19 - 1e19 * uint256(PARTNER_BPS) / 10_000;
        uint256 fullShare = (pushed - _cut(_profitOf(pushed), pushed)) * TRADER_BPS / 10_000;
        emit log_named_uint("trader leg", t.trader);
        emit log_named_uint("full share of one push", fullShare);
        assertGt(t.trader, 0, "the seller's own move earned it a trader leg");
        assertLt(t.trader * 100, fullShare * 60, "but on three times its quote, not the whole push");
    }
}
