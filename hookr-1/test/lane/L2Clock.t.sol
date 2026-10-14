// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {HookrRootStorage} from "../../src/libraries/HookrRootStorage.sol";
import {HookrClock} from "../../src/libraries/HookrClock.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {ArbSysKit} from "../kit/ArbSysMock.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {Actor} from "./mocks/Actors.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";

/// @notice The recapture release runs on Robinhood Chain's own block number (ArbSys.arbBlockNumber(), about 10 a
///         second), the launch guard on block.number (the parent chain's height, about every 12 seconds). The Nitro
///         clock model (ArbSysKit) keeps the two about 74M apart and moves L2 120 blocks per parent block, or alone.
contract L2ClockTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    ScriptedExecutor internal exec;
    PoolKey internal key;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e28);
        exec.setRoot(address(root));
        tokenA.transfer(address(exec), 1e27);
        _openLane(address(exec));
        key = _openRecapture(ETH);
        _nextBlock();
    }

    // ───────────── helpers ─────────────

    /// @dev The lane's `laneDue` word for `k`: slot 8 of the root's pool record, after the executor and partner share.
    function _laneDue(PoolKey memory k) internal view returns (uint256) {
        bytes32 base = keccak256(abi.encode(PoolId.unwrap(k.toId()), HookrRootStorage.SLOT));
        uint256 w = uint256(vm.load(address(root), bytes32(uint256(base) + 8)));
        require(address(uint160(w)) == address(exec), "slot 8 holds the lane executor");
        return uint40(w >> 176);
    }

    function _donated(Vm.Log[] memory logs) internal view returns (uint256 donated, uint256 events) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rules)) continue;
            if (logs[i].topics[0] == IHookrRecaptureEvents.LpShareDonated.selector) {
                (uint256 a0, uint256 a1) = abi.decode(logs[i].data, (uint256, uint256));
                donated += a0 + a1;
                events++;
            }
        }
    }

    /// @dev A dust add at the top of the tick range: it changes no in-range liquidity and flushes the pending share.
    function _poke(PoolKey memory k) internal returns (uint256 donated) {
        int24 top = TickMath.maxUsableTick(k.tickSpacing);
        Actor a = _newActor(k);
        // Above the price the add takes currency0 only: fund it with the pool's quote when that is a token.
        Currency q = _poolQuote(k);
        if (!q.isAddressZero()) IERC20(Currency.unwrap(q)).transfer(address(a), 1e6);
        vm.recordLogs();
        a.modify(k, top - k.tickSpacing, top, 1);
        (donated,) = _donated(vm.getRecordedLogs());
    }

    /// @dev One authenticated buy whose two lane calls each push `amount` of the pool's quote; returns the LP share
    ///      left pending.
    function _pushed(PoolKey memory k, uint256 amount) internal returns (uint256 pending) {
        exec.set(ScriptedExecutor.Mode.PUSH, amount);
        _buy(k, ETH, whale, 1e20);
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        pending = _pending(k);
        assertGt(pending, 0, "an LP share is pending");
    }

    function _pendingParts(PoolKey memory k) internal view returns (uint256 due, uint256 fresh, uint256 freshBlock) {
        (uint256 d0, uint256 d1, uint256 f0, uint256 f1, uint256 fb) = _recap().pendingDonation(k.toId());
        return (d0 + d1, f0 + f1, fb);
    }

    // ───────────── the release clock ─────────────

    /// A second flush in the push's own L2 block releases nothing; one L2 block later (about 100 ms, inside the same
    /// parent block) a flush releases exactly 1/R of the share, R the pool's release period in L2 blocks.
    function test_clock_releaseFollowsL2() public {
        uint256 pending = _pushed(key, 9e18);
        uint256 parent = vm.getBlockNumber();
        assertEq(_poke(key), 0, "the push's own L2 block releases nothing");
        _stepL2(1);
        uint256 donated = _poke(key);
        assertEq(donated, _releasedAfter(pending, 1, RELEASE), "one L2 block: 1/R of the share");
        assertGt(donated, 0);
        assertEq(vm.getBlockNumber(), parent, "without a parent step");
        (uint256 due, uint256 fresh,) = _pendingParts(key);
        assertEq(due, pending - donated, "the rest is due");
        assertEq(fresh, 0, "the fresh share merged");
        // Still in that L2 block: nothing more.
        assertEq(_poke(key), 0, "a second flush in one L2 block releases nothing");
    }

    /// A parent block that passes while the L2 clock stands still releases nothing and merges nothing: block.number is
    /// not the release clock.
    function test_clock_parentStepWithoutL2StepReleasesNothing() public {
        uint256 pending = _pushed(key, 9e18);
        (, uint256 fresh0, uint256 stamp) = _pendingParts(key);
        uint256 l2 = _l2();
        vm.roll(vm.getBlockNumber() + 5);
        vm.warp(vm.getBlockTimestamp() + 60);
        ArbSysKit.install(vm, l2, vm.getBlockNumber());
        assertEq(_l2(), l2, "L2 held");
        assertEq(_poke(key), 0, "five parent blocks, no L2 block: nothing released");
        (uint256 due, uint256 fresh, uint256 fb) = _pendingParts(key);
        assertEq(due, 0, "nothing merged");
        assertEq(fresh, fresh0, "the share is still fresh");
        assertEq(fb, stamp);
        assertEq(fresh, pending);
    }

    /// pendingDonation().freshBlock is the L2 height (eth_blockNumber, a receipt's blockNumber), not block.number.
    function test_clock_freshBlockIsTheL2Height() public {
        _pushed(key, 9e18);
        (,, uint256 fb) = _pendingParts(key);
        assertEq(fb, _l2(), "stamped with ArbSys.arbBlockNumber()");
        assertTrue(fb != vm.getBlockNumber(), "not block.number");
        // About 74M apart offline and about 48M under a whole-suite fork run, where block.number is the fork's parent
        // height (LaneFixture._parentClock).
        assertGt(fb, vm.getBlockNumber() + 40_000_000, "the two clocks are tens of millions apart here");
    }

    /// The bounds are L2 blocks: about 2 minutes, an hour and 24 hours at 10 a second. One below the least and one
    /// above the most refuse the bind; the bounds themselves bind.
    function test_clock_boundsAreL2Blocks() public {
        IHookrRecaptureRules r = _recap();
        assertEq(r.MIN_RELEASE_BLOCKS(), 1_200);
        assertEq(r.DEFAULT_RELEASE_BLOCKS(), 36_000);
        assertEq(r.MAX_RELEASE_BLOCKS(), 864_000);
        (HookrTypes.RecaptureConfig memory d,) = r.recaptureDefaults();
        assertEq(d.releaseBlocks, 36_000, "the wizard pre-fills about an hour");
        HookrTypes.RecaptureConfig memory rc = _recaptureOnlyRc();
        uint32[4] memory values = [uint32(1_199), 1_200, 864_000, 864_001];
        for (uint256 i; i < values.length; ++i) {
            rc.releaseBlocks = values[i];
            bool valid = values[i] == 1_200 || values[i] == 864_000;
            IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
            members[0] = _laneMember(ETH, _laneRules(false), rc);
            HookrToken subject = _newSubject();
            if (!valid) {
                vm.expectRevert();
                this.launchAsCreator(subject, members);
                continue;
            }
            (, PoolKey[] memory keys) = this.launchAsCreator(subject, members);
            (HookrTypes.RecaptureConfig memory got,,) = r.recaptureConfig(keys[0].toId());
            assertEq(got.releaseBlocks, values[i]);
        }
    }

    function launchAsCreator(HookrToken subject, IHookrLauncher.Member[] memory members)
        external
        returns (bytes32, PoolKey[] memory)
    {
        require(msg.sender == address(this));
        return _launchAs(creator, subject, members);
    }

    /// On an idle chain L2 blocks come slower than 10 a second, which only slows the release: an hour (300 parent
    /// blocks) that carried 252 L2 blocks (0.07 a second) releases 252/36,000 of a share at the default period, far
    /// less than the whole share an hour of full blocks releases.
    function test_clock_anIdleChainOnlySlowsTheRelease() public {
        HookrTypes.RecaptureConfig memory rc = _recaptureOnlyRc();
        rc.releaseBlocks = _recap().DEFAULT_RELEASE_BLOCKS();
        PoolKey memory k = _openPool(ETH, _laneRules(false), rc);
        _nextBlock();
        uint256 pending = _pushed(k, 9e18);
        uint256 l2 = _l2();
        ArbSysKit.nextParent(vm, 300);
        ArbSysKit.install(vm, l2 + 252, vm.getBlockNumber());
        uint256 donated = _poke(k);
        assertEq(donated, _releasedAfter(pending, 252, 36_000), "252 L2 blocks of release");
        assertLe(donated * 36_000, pending * 252 + 36_000, "at most 252/36,000 of the share");
        console2.log("idle hour: released bps of the share", donated * 10_000 / pending);
        // A saturated hour releases the rest.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        ArbSysKit.install(vm, l2 + 252 + 36_000, vm.getBlockNumber());
        assertEq(_poke(k), pending - donated, "36,000 L2 blocks later the rest is released");
    }

    // ───────────── the lane's pending flag ─────────────

    /// `laneDue` is a flag with no clock: 1 after a push and while a flush leaves a share pending, 0 once none is. So
    /// an add one L2 block after the push, still inside the push's parent block, flushes before it lands: the new
    /// liquidity gets none of what that flush released.
    function test_clock_flagFlushesBeforeAnAddInTheSameParentBlock() public {
        assertEq(_laneDue(key), 0, "nothing pending yet");
        uint256 pending = _pushed(key, 9e18);
        assertEq(_laneDue(key), 1, "a push sets the flag");
        uint256 parent = vm.getBlockNumber();
        _stepL2(1);
        Actor newcomer = _newActor(key);
        uint256 e0 = address(newcomer).balance;
        vm.recordLogs();
        newcomer.modify(key, -60_000, 60_000, 1e24);
        (uint256 donated, uint256 events) = _donated(vm.getRecordedLogs());
        assertEq(events, 1, "the add flushed");
        assertEq(donated, _releasedAfter(pending, 1, RELEASE), "one L2 block of release, before the add landed");
        assertEq(vm.getBlockNumber(), parent, "same parent block");
        assertEq(_laneDue(key), 1, "a share is still pending");
        // The newcomer leaves in the same L2 block: that flush releases nothing and it was not in range for the first.
        newcomer.modify(key, -60_000, 60_000, -1e24);
        assertLe(address(newcomer).balance, e0, "the newcomer got none of the released part");
        // A full release period later everything is released and the flag clears.
        ArbSysKit.nextParent(vm, RELEASE_PARENTS);
        _poke(key);
        assertEq(_pending(key), 0, "all released");
        assertEq(_laneDue(key), 0, "the flag clears once nothing is pending");
    }

    // ───────────── JIT at L2 granularity ─────────────

    /// Liquidity added and removed in the push's own L2 block gets nothing of the pending share, even though it sits
    /// alone at the price with ten times the launch position's liquidity.
    function test_clock_sameL2BlockJitGetsNothing() public {
        uint256 pending = _pushed(key, 9e18);
        Actor atk = _newActor(key);
        (int24 lo, int24 hi) = _tight(key);
        uint256 e0 = address(atk).balance;
        vm.recordLogs();
        atk.modify(key, lo, hi, 1e25);
        atk.modify(key, -6000, 6000, 1);
        atk.modify(key, lo, hi, -1e25);
        (uint256 donated,) = _donated(vm.getRecordedLogs());
        assertEq(donated, 0, "nothing released in the push's own L2 block");
        assertLe(address(atk).balance, e0, "no gain");
        assertEq(_pending(key), pending, "the share is intact");
    }

    /// Added one L2 block after the push (its add flushes first) and removed one L2 block later, a position alone at
    /// the price with ten times the launch liquidity takes at most its pro-rata part of that one L2 block's release:
    /// at most ceil(due / R) plus a raw unit.
    function test_clock_jitHeldOneL2BlockTakesAtMostOneRth() public {
        uint256 pending = _pushed(key, 9e18);
        Actor atk = _newActor(key);
        (int24 lo, int24 hi) = _tight(key);
        _stepL2(1);
        uint256 e0 = address(atk).balance;
        vm.recordLogs();
        atk.modify(key, lo, hi, 1e25);
        (uint256 first,) = _donated(vm.getRecordedLogs());
        assertEq(first, _releasedAfter(pending, 1, RELEASE), "the add flushed one L2 block's part first");
        uint256 inEth = e0 - address(atk).balance;
        _stepL2(1);
        vm.recordLogs();
        uint256 e1 = address(atk).balance;
        atk.modify(key, lo, hi, -1e25);
        (uint256 second,) = _donated(vm.getRecordedLogs());
        uint256 outEth = address(atk).balance - e1;
        uint256 gain = outEth > inEth ? outEth - inEth : 0;
        assertEq(second, _releasedAfter(pending - first, 1, RELEASE), "the removal flushed one L2 block's part");
        console2.log("pending, released while held, attacker gain", pending, second, gain);
        assertLe(gain, second + 1, "at most the one L2 block's release");
        assertLe(gain * RELEASE, pending + 2 * RELEASE, "at most about 1/R of the share");
    }

    /// @dev The L2-only steps ArbSysKit has taken (its `extra` word).
    function _l2Steps() internal view returns (uint256) {
        return uint64(uint256(vm.load(ArbSysKit.ARB_SYS, bytes32(0))) >> 192);
    }

    function _tight(PoolKey memory k) internal view returns (int24 lo, int24 hi) {
        (, int24 tick,,) = manager.getSlot0(k.toId());
        lo = tick >= 0 ? (tick / 60) * 60 : ((tick - 59) / 60) * 60;
        hi = lo + 60;
    }

    // ───────────── parent-chain inbox bursts ─────────────

    /// Every parent-chain inbox (delayed) message becomes its own L2 block, and the sequencer includes a burst of them
    /// under one timestamp (on Robinhood Chain blocks 75,021,983 to 75,022,012 all carry 1,790,621,033). A position
    /// ten times the launch liquidity, added in the push's own L2 block and removed one second later with a whole
    /// release period of inbox blocks in that second, is credited ten sequencer blocks and one second's allowance:
    /// 20 L2 blocks of release, not 1,210 (the whole share).
    function test_clock_inboxBurstAddsAtMostOneSecond() public {
        uint256 pending = _pushed(key, 9e18);
        Actor atk = _newActor(key);
        (int24 lo, int24 hi) = _tight(key);
        uint256 e0 = address(atk).balance;
        atk.modify(key, lo, hi, 1e25);
        uint256 inEth = e0 - address(atk).balance;
        uint256 parent = vm.getBlockNumber();
        uint256 t = vm.getBlockTimestamp();
        ArbSysKit.inboxBurst(vm, RELEASE);
        _stepL2(10);
        assertEq(vm.getBlockTimestamp(), t + 1, "one second");
        assertEq(vm.getBlockNumber(), parent, "one parent block");
        uint256 e1 = address(atk).balance;
        vm.recordLogs();
        atk.modify(key, lo, hi, -1e25);
        (uint256 donated,) = _donated(vm.getRecordedLogs());
        uint256 outEth = address(atk).balance - e1;
        uint256 gain = outEth > inEth ? outEth - inEth : 0;
        console2.log("pending, released in the burst second, attacker gain", pending, donated, gain);
        assertEq(donated, _releasedAfter(pending, 20, RELEASE), "ten sequencer blocks and one second's allowance");
        assertLe(gain, donated + 1, "at most what was released while held");
        assertLt(donated * 50, pending, "under 2% of the share");
    }

    /// A flush in every block of an inbox burst (each message can carry the dust add that flushes) does not renew the
    /// allowance: the burst's second releases ten L2 blocks' worth, one flush each, and every later flush in it
    /// nothing. Nothing is lost: a release period later the rest is released.
    function test_clock_aFlushInEveryInboxBlockAddsNothing() public {
        uint256 pending = _pushed(key, 9e18);
        uint256 t = vm.getBlockTimestamp();
        uint256 total;
        uint256 releasing;
        for (uint256 i; i < 200; ++i) {
            ArbSysKit.inboxBurst(vm, 1);
            uint256 out = _poke(key);
            total += out;
            if (out != 0) ++releasing;
        }
        assertEq(vm.getBlockTimestamp(), t, "one timestamp");
        assertEq(releasing, 10, "one second's allowance, one L2 block a flush");
        assertLe(total, _releasedAfter(pending, 10, RELEASE) + 10, "10/R of the share and a raw unit a flush");
        ArbSysKit.nextParent(vm, RELEASE_PARENTS);
        total += _poke(key);
        assertEq(_pending(key), 0, "drained");
        assertEq(total, pending, "every unit released");
    }

    /// At the default period (36,000) a position added one sequencer block after the push (its add merges the fresh
    /// share into the due one) and removed one second and a 1,000-block burst later is credited between the ten
    /// sequencer blocks and 20 L2 blocks, not 1,010.
    function test_clock_inboxBurstAtTheDefaultPeriod() public {
        HookrTypes.RecaptureConfig memory rc = _recaptureOnlyRc();
        rc.releaseBlocks = _recap().DEFAULT_RELEASE_BLOCKS();
        PoolKey memory k = _openPool(ETH, _laneRules(false), rc);
        _nextBlock();
        _pushed(k, 9e18);
        _stepL2(1);
        Actor atk = _newActor(k);
        (int24 lo, int24 hi) = _tight(k);
        vm.recordLogs();
        atk.modify(k, lo, hi, 1e25);
        (uint256 first,) = _donated(vm.getRecordedLogs());
        assertGt(first, 0, "the add flushed first");
        uint256 due = _pending(k);
        ArbSysKit.inboxBurst(vm, 1_000);
        _stepL2(10);
        vm.recordLogs();
        atk.modify(k, lo, hi, -1e25);
        (uint256 donated,) = _donated(vm.getRecordedLogs());
        console2.log("due, released in the burst second", due, donated);
        assertGe(donated, _releasedAfter(due, 10, 36_000), "the sequencer blocks release");
        assertLe(donated, _releasedAfter(due, 20, 36_000), "at most 20 L2 blocks' part");
    }

    /// A flush in a second whose allowance an inbox burst already spent releases nothing and still moves the release
    /// block to its own: the L2 blocks past the pace are dropped, not paid in one lump at the next second. A position
    /// added in the last L2 block of that second and removed in the first of the next is credited one L2 block's part.
    function test_clock_aSpentSecondDropsItsExtraBlocks() public {
        _pushed(key, 9e18);
        _stepL2(1);
        assertGt(_poke(key), 0, "the fresh share merges");
        uint256 t = vm.getBlockTimestamp();
        ArbSysKit.inboxBurst(vm, 20);
        assertGt(_poke(key), 0, "the burst's flush spends the second's allowance");
        ArbSysKit.inboxBurst(vm, 9);
        assertEq(_poke(key), 0, "a spent second releases nothing");
        Actor atk = _newActor(key);
        (int24 lo, int24 hi) = _tight(key);
        uint256 e0 = address(atk).balance;
        vm.recordLogs();
        atk.modify(key, lo, hi, 1e25);
        (uint256 first,) = _donated(vm.getRecordedLogs());
        assertEq(first, 0, "the add flushed nothing");
        uint256 inEth = e0 - address(atk).balance;
        uint256 due = _pending(key);
        ArbSysKit.inboxBurst(vm, 1);
        vm.warp(t + 1);
        uint256 e1 = address(atk).balance;
        vm.recordLogs();
        atk.modify(key, lo, hi, -1e25);
        (uint256 donated,) = _donated(vm.getRecordedLogs());
        uint256 outEth = address(atk).balance - e1;
        uint256 gain = outEth > inEth ? outEth - inEth : 0;
        console2.log("due, released across a one-L2-block hold, attacker gain", due, donated, gain);
        assertEq(donated, _releasedAfter(due, 1, RELEASE), "one L2 block's part");
        assertLe(gain, donated + 1, "at most what was released while held");
    }

    /// After one inbox burst, a steady chain of ten sequencer blocks a second with a flush in every block: each second
    /// boundary pays a one-L2-block hold one L2 block's part, however many of the second's flushes released nothing.
    function test_clock_aSpentSecondDoesNotCarryALump() public {
        _pushed(key, 9e18);
        _stepL2(1);
        _poke(key);
        ArbSysKit.inboxBurst(vm, 20);
        assertGt(_poke(key), 0, "the burst's flush spends the second's allowance");
        Actor atk = _newActor(key);
        (int24 lo, int24 hi) = _tight(key);
        for (uint256 c; c < 4; ++c) {
            uint256 idle;
            // Up to the last sequencer block of this second: ArbSysKit moves the time on every tenth L2-only step.
            while (_l2Steps() % 10 != 9) {
                _stepL2(1);
                if (_poke(key) == 0) ++idle;
            }
            if (c == 0) assertGt(idle, 0, "flushes in a spent second release nothing");
            atk.modify(key, lo, hi, 1e25);
            uint256 due = _pending(key);
            uint256 t = vm.getBlockTimestamp();
            _stepL2(1);
            assertEq(vm.getBlockTimestamp(), t + 1, "the first block of the next second");
            vm.recordLogs();
            atk.modify(key, lo, hi, -1e25);
            (uint256 donated,) = _donated(vm.getRecordedLogs());
            assertEq(donated, _releasedAfter(due, 1, RELEASE), "one L2 block's part at every boundary");
        }
    }

    // ───────────── a clock that cannot be read ─────────────

    /// With 0x64 empty or holding Nitro's 0xfe placeholder, a swap that pushes nothing completes and its flush fails
    /// open, leaving the share pending; a swap whose arb recapture pushes reverts, since its LP share cannot be stamped
    /// (fail closed where value moves). The placeholder burns at most READ_GAS per read. With the clock back, the next
    /// flush releases what the stopped time owes.
    function test_clock_deadClockFailsOpenOnFlushAndClosedOnPush() public {
        uint256 pending = _pushed(key, 9e18);
        _stepL2(1);
        (uint256 due0, uint256 fresh0, uint256 fb0) = _pendingParts(key);
        bytes memory mock = address(100).code;
        bytes32 word = vm.load(address(100), bytes32(0));
        uint256[2] memory used;
        bytes[2] memory dead = [bytes(""), bytes(hex"fe")];
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            vm.etch(address(100), dead[i]);
            // No push: the swap completes and the flush leaves everything as it was.
            vm.recordLogs();
            _buy(key, ETH, minnow, 1e18);
            used[i] = vm.lastCallGas().gasTotalUsed;
            (uint256 donated,) = _donated(vm.getRecordedLogs());
            assertEq(donated, 0, "nothing released without a clock");
            (uint256 due, uint256 fresh, uint256 fb) = _pendingParts(key);
            assertEq(due, due0);
            assertEq(fresh, fresh0);
            assertEq(fb, fb0);
            assertEq(_laneDue(key), 1, "still flagged");
            // A push cannot stamp its LP share: the swap reverts.
            exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
            IHookrRouter.Swap memory p = _swapParams(key, ETH, true, true, 1e18, minnow);
            vm.prank(minnow);
            vm.expectRevert();
            router.swap{value: 1e18}(p, address(0), new uint256[](0));
            exec.set(ScriptedExecutor.Mode.NOTHING, 0);
            vm.revertToState(snap);
        }
        console2.log("no-push swap gas, clock empty / placeholder", used[0], used[1]);
        assertLe(used[1], used[0] + HookrClock.READ_GAS, "the placeholder burns at most READ_GAS");
        // The clock back: the next flush releases what one L2 block owes.
        vm.etch(address(100), mock);
        vm.store(address(100), bytes32(0), word);
        assertEq(_poke(key), _releasedAfter(pending, 1, RELEASE));
    }

    /// A King of the Pool epoch rollover that releases pot to in-range liquidity reads the clock too, and fails closed:
    /// with `0x64` empty or `0xfe`, the first swap after the epoch ends reverts though it pushes nothing and the lane is
    /// switched off, settleEpoch reverts, and the epoch stays open. With the clock back the next swap closes it.
    function test_clock_deadClockRevertsAKingOfTheHillRollover() public {
        PoolKey memory k = _openKoth(ETH);
        _nextBlock();
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        _buy(k, ETH, whale, 1e20);
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        _flushAll(k);
        assertEq(_pending(k), 0, "nothing pending: no flush reads the clock");
        (uint64 start,,, uint128 pot) = _hill(k);
        assertGt(pot, 0, "the pot holds part of the push");
        vm.warp(uint256(start) + PERIOD);
        _nextBlock();
        registry.stopExecutorLane(address(root), address(exec));
        bytes memory mock = address(100).code;
        bytes32 word = vm.load(address(100), bytes32(0));
        bytes[2] memory dead = [bytes(""), bytes(hex"fe")];
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            vm.etch(address(100), dead[i]);
            IHookrRouter.Swap memory p = _swapParams(k, ETH, true, true, 1e18, minnow);
            vm.prank(minnow);
            vm.expectRevert();
            router.swap{value: 1e18}(p, address(0), new uint256[](0));
            vm.expectRevert(HookrClock.ClockUnavailable.selector);
            _recap().settleEpoch(k.toId());
            (uint64 still,,, uint128 potStill) = _hill(k);
            assertEq(still, start, "the epoch stays open");
            assertEq(potStill, pot);
            vm.revertToState(snap);
        }
        vm.etch(address(100), mock);
        vm.store(address(100), bytes32(0), word);
        _buy(k, ETH, minnow, 1e18);
        (uint64 next,,, uint128 carried) = _hill(k);
        assertEq(next, start + PERIOD, "the next swap closed the epoch");
        assertLt(carried, pot, "and released pot");
        assertGt(_pending(k), 0, "as a pending donation stamped with the L2 height");
    }

    // ───────────── the guard stays on the parent clock ─────────────

    /// A launch guard of 100 parent blocks, then 12,000,000 L2 blocks (the equivalent of 100,000 parent blocks) with no
    /// parent step: Snipe is still charged, exact-output buys are still refused, third-party adds are still refused,
    /// the launch principal is still locked, and two buys one L2 block apart in one parent block share its buy cap.
    /// Rolling past the guard's end opens all of them.
    function test_clock_guardStaysOnParentClock() public {
        HookrTypes.RulesConfig memory r = _laneRules(false);
        uint256 guardEnd = vm.getBlockNumber() + 100;
        r.guardEndBlock = uint40(guardEnd);
        r.snipeTaxPips = 500_000;
        r.maxBuyQuoteAmount = 1e22;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(ETH, r, _recaptureOnlyRc());
        (bytes32 family, PoolKey[] memory keys) = _launchAs(creator, _newSubject(), members);
        PoolKey memory g = keys[0];
        _nextBlock();
        _stepL2(12_000_000);
        assertLt(vm.getBlockNumber(), guardEnd, "inside the guard on block.number");
        // Snipe (50%).
        uint256 out = _buy(g, ETH, whale, 1e18);
        assertLt(out, 0.6e18, "Snipe is charged");
        // Exact-output buys.
        IHookrRouter.Swap memory p = _swapParams(g, ETH, true, false, 1e17, whale);
        p.amountBound = 1e18;
        vm.prank(whale);
        vm.expectRevert();
        router.swap{value: 1e18}(p, address(0), new uint256[](0));
        // Third-party liquidity.
        Actor lp = _newActor(g);
        vm.expectRevert();
        lp.modify(g, -60_000, 60_000, 1e18);
        // The launch principal.
        uint128 l = launcher.position(family, 0).liquidity;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.PrincipalLocked.selector, family, uint8(0), guardEnd));
        launcher.withdraw(family, 0, l, 0, 0, creator, vm.getBlockTimestamp());
        // The per-parent-block buy cap: 1e22 of quote, shared by two buys one L2 block apart.
        _buy(g, ETH, minnow, 1e22 - 2e18);
        _stepL2(1);
        vm.prank(attacker);
        vm.expectRevert();
        router.swap{value: 1e19}(_swapParams(g, ETH, true, true, 1e19, attacker), address(0), new uint256[](0));
        // Past the guard's end on block.number everything opens.
        vm.roll(guardEnd);
        vm.warp(vm.getBlockTimestamp() + 1200);
        out = _buy(g, ETH, whale, 1e18);
        assertGt(out, 0.9e18, "no Snipe after the guard");
        p.deadline = vm.getBlockTimestamp();
        vm.prank(whale);
        router.swap{value: 1e18}(p, address(0), new uint256[](0));
        lp.modify(g, -60_000, 60_000, 1e18);
        vm.prank(creator);
        launcher.withdraw(family, 0, l / 2, 0, 0, creator, vm.getBlockTimestamp());
    }

    // ───────────── dust: a partial release rounds up ─────────────

    /// @dev A recapture pool on a fresh `decimals`-decimal quote the registry catalogs, funded for the fixture's people
    ///      and the executor.
    function _dustPool(uint8 decimals) internal returns (PoolKey memory k, MockERC20 q) {
        q = new MockERC20("Q", "Q", decimals);
        q.mint(address(this), 1e30);
        q.mint(address(exec), 1e30);
        address[5] memory people = [creator, whale, minnow, attacker, address(mover)];
        for (uint256 i; i < people.length; ++i) {
            q.mint(people[i], 1e30);
            vm.startPrank(people[i]);
            q.approve(address(router), type(uint256).max);
            q.approve(address(launcher), type(uint256).max);
            vm.stopPrank();
        }
        _catalogQuote(address(q));
        k = _openRecapture(Currency.wrap(address(q)));
        _nextBlock();
    }

    function _lpShares(Vm.Log[] memory logs) internal view returns (uint256 lp) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rules)) continue;
            if (logs[i].topics[0] == IHookrRecaptureEvents.RecaptureSplit.selector) {
                (, uint256 share,,,,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, Currency, uint256));
                lp += share;
            }
        }
    }

    /// A pending share under R raw units (dust of a 6- or 8-decimal quote: 300 pushed twice leaves 450 units of LP
    /// share) releases at most one unit over amount x age / R per flush, never the whole remainder to one L2 block's
    /// liquidity, and drains fully: in one unit per flush while every flush is one L2 block apart, at once a full
    /// period later. A tiny fresh share merged into it is never lost: every unit of LP share is donated.
    function test_clock_dustReleasesAtMostOneUnitOverFloorAndDrains() public {
        uint8[2] memory decimals = [uint8(6), 8];
        for (uint256 d; d < 2; ++d) {
            (PoolKey memory k, MockERC20 q) = _dustPool(decimals[d]);
            Currency quote = Currency.wrap(address(q));
            exec.set(ScriptedExecutor.Mode.PUSH, 300);
            vm.recordLogs();
            _buy(k, quote, whale, 10 ** decimals[d]);
            uint256 lp = _lpShares(vm.getRecordedLogs());
            exec.set(ScriptedExecutor.Mode.NOTHING, 0);
            uint256 pending = _pending(k);
            assertEq(pending, lp, "the LP share is pending");
            assertLt(pending, RELEASE, "dust: under R raw units");
            uint256 donated;
            uint16[6] memory ages = [uint16(1), 1, 1, 7, 100, 333];
            for (uint256 i; i < ages.length; ++i) {
                (uint256 due, uint256 fresh,) = _pendingParts(k);
                uint256 before = due + fresh;
                _stepL2(ages[i]);
                uint256 out = _poke(k);
                uint256 floor = before * ages[i] / RELEASE;
                assertGe(out, floor, "at least the proportional part");
                // One unit per part rounded: the due part and, when one waits, the fresh part.
                assertLe(out, floor + (fresh != 0 && due != 0 ? 2 : 1), "at most one unit over it per part");
                assertGt(out, 0, "a nonzero share always releases something");
                donated += out;
                // A tiny fresh share lands on top of the due one once.
                if (i == 2) {
                    exec.set(ScriptedExecutor.Mode.PUSH, 3);
                    vm.recordLogs();
                    _buy(k, quote, minnow, 10 ** decimals[d]);
                    lp += _lpShares(vm.getRecordedLogs());
                    exec.set(ScriptedExecutor.Mode.NOTHING, 0);
                }
            }
            ArbSysKit.nextParent(vm, RELEASE_PARENTS);
            donated += _poke(k);
            assertEq(_pending(k), 0, "fully drained");
            assertEq(donated, lp, "every unit of LP share donated, the tiny fresh one included");
            assertTrue(rules.accountingInvariant(quote));
        }
    }
}
