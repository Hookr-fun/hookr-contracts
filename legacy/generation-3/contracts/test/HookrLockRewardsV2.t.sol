// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLaunchBoostV2} from "../src/HookrLaunchBoostV2.sol";
import {HookrLockRewardsV2} from "../src/HookrLockRewardsV2.sol";
import {IHookrLockRewardsV2} from "../src/interfaces/IHookrLockRewardsV2.sol";
import {HookrTokenTransfer} from "../src/libraries/HookrTokenTransfer.sol";
import {AdversarialHookrUtilityToken, MockHookrLaunchpad, MockHookrUtilityToken} from "./HookrLockRewardsV1.t.sol";

contract HookrLockRewardsV2Test is Test {
    MockHookrUtilityToken internal hookr;
    MockHookrLaunchpad internal launchpad;
    HookrLockRewardsV2 internal rewards;
    HookrLaunchBoostV2 internal boost;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal creator = address(0xC0FFEE);
    address internal outsider = address(0xBAD);
    address internal launchToken = address(0xF15);
    bytes32 internal intentId = keccak256("hookr.utility.v2.test.intent");

    function setUp() public {
        vm.warp(1_800_000_000);
        hookr = new MockHookrUtilityToken();
        launchpad = new MockHookrLaunchpad();
        rewards = new HookrLockRewardsV2(hookr, address(this));
        boost = new HookrLaunchBoostV2(
            hookr, HookrLaunchpad(payable(address(launchpad))), IHookrLockRewardsV2(address(rewards))
        );
        rewards.setRewardSourceOnce(address(boost));

        launchpad.setLaunch(launchToken, creator);
        launchpad.setIntent(creator, intentId, launchToken);
        hookr.mint(alice, 100_000_000 ether);
        hookr.mint(bob, 100_000_000 ether);
        hookr.mint(creator, 100_000_000 ether);
        hookr.mint(outsider, 100_000_000 ether);
    }

    function _approve(address account, address spender, uint256 amount) internal {
        vm.prank(account);
        hookr.approve(spender, amount);
    }

    function _lock(address account, uint256 amount, uint8 tier) internal returns (uint256 positionId) {
        _approve(account, address(rewards), amount);
        (, uint32 activation,, uint40 unlockAt,) = rewards.previewLock(amount, tier);
        vm.prank(account);
        positionId = rewards.lock(amount, tier, activation, unlockAt, block.timestamp + 1 hours);
    }

    function _boost(address token, uint256 amount, uint8 tier) internal returns (uint256 principal, uint256 fee) {
        _approve(creator, address(boost), amount);
        vm.prank(creator);
        return boost.boost(token, amount, tier, type(uint256).max, 0, block.timestamp + 1 hours);
    }

    function _assertSolvent() internal view {
        (uint256 rewardBalance, uint256 lockedPrincipal, uint256 reserve, uint256 rewardSurplus, bool rewardOk) =
            rewards.solvency();
        assertTrue(rewardOk);
        assertEq(rewardBalance, lockedPrincipal + reserve + rewardSurplus);
        assertEq(rewards.cumulativeBoostFeesNotified(), rewards.cumulativeRewardsClaimed() + reserve);
        assertLe(rewards.roundingCarry(), reserve);

        (uint256 boostBalance, uint256 boostPrincipal, uint256 boostSurplus, bool boostOk) = boost.solvency();
        assertTrue(boostOk);
        assertEq(boostBalance, boostPrincipal + boostSurplus);
        assertEq(boost.cumulativeGrossBoosted(), boost.cumulativePrincipalAdded() + boost.cumulativeFeesForwarded());
        assertEq(boost.cumulativeFeesForwarded(), rewards.cumulativeBoostFeesNotified());
    }

    function test_bootstrapScheduleIsTwoHoursThenPositiveMondayBridge() public view {
        assertEq(rewards.BOOTSTRAP_EPOCH_LENGTH(), 2 hours);
        assertEq(rewards.feeEpochStartsAt(), rewards.bootstrapStartedAt() + 2 hours);
        assertEq(rewards.claimEpochStartsAt(), rewards.feeEpochStartsAt() + 2 hours);
        assertGt(rewards.weeklyEpochsStartAt(), rewards.claimEpochStartsAt());
        assertLe(rewards.weeklyEpochsStartAt() - rewards.claimEpochStartsAt(), 7 days);
        assertEq((rewards.weeklyEpochsStartAt() - rewards.MONDAY_EPOCH_OFFSET()) % 7 days, 0);
        assertEq(rewards.epochStart(0), rewards.bootstrapStartedAt());
        assertEq(rewards.epochStart(1), rewards.feeEpochStartsAt());
        assertEq(rewards.epochStart(2), rewards.claimEpochStartsAt());
        assertEq(rewards.epochStart(3), rewards.weeklyEpochsStartAt());
        assertEq(boost.boostingOpensAt(), rewards.feeEpochStartsAt());
        assertFalse(boost.boostingOpen());
        assertEq(rewards.contractName(), "HookrLockRewards");
        assertEq(rewards.contractVersion(), "2");
        assertEq(boost.contractName(), "HookrLaunchBoost");
        assertEq(boost.contractVersion(), "2");
    }

    function test_exactBoundaryMappingAndWeeklyHandoff() public {
        uint40 start = rewards.bootstrapStartedAt();
        uint40 feeStart = rewards.feeEpochStartsAt();
        uint40 claimStart = rewards.claimEpochStartsAt();
        uint40 weeklyStart = rewards.weeklyEpochsStartAt();

        vm.warp(start);
        assertEq(rewards.currentEpoch(), 0);
        assertEq(rewards.epochAt(start), 0);
        vm.warp(feeStart - 1);
        assertEq(rewards.currentEpoch(), 0);
        assertEq(rewards.epochAt(feeStart - 1), 0);
        vm.warp(feeStart);
        assertEq(rewards.currentEpoch(), 1);
        assertEq(rewards.epochAt(feeStart), 1);
        vm.warp(claimStart - 1);
        assertEq(rewards.currentEpoch(), 1);
        assertEq(rewards.epochAt(claimStart - 1), 1);
        vm.warp(claimStart);
        assertEq(rewards.currentEpoch(), 2);
        assertEq(rewards.epochAt(claimStart), 2);
        vm.warp(weeklyStart - 1);
        assertEq(rewards.currentEpoch(), 2);
        assertEq(rewards.epochAt(weeklyStart - 1), 2);
        vm.warp(weeklyStart);
        assertEq(rewards.currentEpoch(), 3);
        assertEq(rewards.epochAt(weeklyStart), 3);
        vm.warp(weeklyStart + 7 days - 1);
        assertEq(rewards.currentEpoch(), 3);
        vm.warp(weeklyStart + 7 days);
        assertEq(rewards.currentEpoch(), 4);
        assertEq(rewards.epochAt(uint40(weeklyStart + 7 days)), 4);
    }

    function test_checkpointEmitsExactlyOneEventPerProcessedEpoch() public {
        _lock(alice, 1 ether, 0);
        vm.warp(rewards.claimEpochStartsAt());
        vm.recordLogs();
        assertEq(rewards.checkpoint(64), 2);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 checkpointSignature = keccak256("EpochCheckpointed(uint32,uint256,uint256,uint256,uint256)");
        uint256 checkpointEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(rewards) && logs[i].topics[0] == checkpointSignature) {
                ++checkpointEvents;
            }
        }
        assertEq(checkpointEvents, 2, "one event per processed epoch");
    }

    function test_exactMondayClaimBoundaryStillCreatesPositiveBridge() public {
        uint256 monday = uint256(rewards.MONDAY_EPOCH_OFFSET()) + 4_000 * 7 days;
        vm.warp(monday - 4 hours);
        MockHookrUtilityToken localToken = new MockHookrUtilityToken();
        HookrLockRewardsV2 localRewards = new HookrLockRewardsV2(localToken, address(this));
        assertEq(localRewards.claimEpochStartsAt(), monday);
        assertEq(localRewards.weeklyEpochsStartAt(), monday + 7 days);
        assertGt(localRewards.epochStart(3), localRewards.epochStart(2));
    }

    function testFuzz_epochStartsAndEpochAtAreExactInverses(uint16 rawEpoch) public view {
        uint32 epoch = uint32(bound(uint256(rawEpoch), 0, 500));
        uint40 start = rewards.epochStart(epoch);
        uint40 next = rewards.epochStart(epoch + 1);
        assertGt(next, start);
        assertEq(rewards.epochAt(start), epoch);
        assertEq(rewards.epochAt(next - 1), epoch);
    }

    function test_preOpenBoostAndPermitPathRevertAtomically() public {
        uint256 creatorBalance = hookr.balanceOf(creator);
        uint256 creatorNonce = hookr.nonces(creator);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV2.BoostingNotOpen.selector, rewards.feeEpochStartsAt()));
        boost.boost(launchToken, 100 ether, 0, 1 ether, 99 ether, block.timestamp + 1 hours);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV2.BoostingNotOpen.selector, rewards.feeEpochStartsAt()));
        boost.boostWithPermit(
            launchToken,
            100 ether,
            0,
            1 ether,
            99 ether,
            block.timestamp + 1 hours,
            27,
            bytes32(uint256(1)),
            bytes32(uint256(2))
        );

        assertEq(hookr.balanceOf(creator), creatorBalance);
        assertEq(hookr.nonces(creator), creatorNonce);
        assertEq(hookr.allowance(creator, address(boost)), 0);
        assertEq(boost.boostedTokensCount(), 0);
        assertEq(boost.totalBoostPrincipal(), 0);
        assertEq(rewards.rewardReserve(), 0);
        assertEq(rewards.checkpointEpoch(), 0);
    }

    function test_epochZeroLockFeeBearingEpochOneAndClaimEpochTwoSameDay() public {
        uint256 positionId = _lock(alice, 1 ether, 0);
        HookrLockRewardsV2.Position memory p = rewards.position(positionId);
        assertEq(p.activationEpoch, 1);
        assertEq(p.unlockAt, rewards.bootstrapStartedAt() + 30 days);
        assertEq(rewards.currentEligibleWeight(), 0);

        vm.warp(rewards.feeEpochStartsAt());
        (uint256 principal, uint256 fee) = _boost(launchToken, 100 ether, 0);
        assertEq(principal, 99 ether);
        assertEq(fee, 1 ether);
        assertEq(rewards.currentEligibleWeight(), 1 ether);
        assertEq(rewards.boostFeesByEpoch(1), 1 ether);

        vm.prank(alice);
        vm.expectRevert(HookrLockRewardsV2.NothingToClaim.selector);
        rewards.claim(positionId, alice);

        vm.warp(rewards.claimEpochStartsAt());
        uint256 before = hookr.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = rewards.claim(positionId, alice);
        assertGt(claimed, 0);
        assertLe(1 ether - claimed, 1);
        assertEq(hookr.balanceOf(alice) - before, claimed);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HookrLockRewardsV2.PositionStillLocked.selector, p.unlockAt));
        rewards.withdraw(positionId, alice);
        _assertSolvent();
    }

    function test_lateLockerCannotCaptureEpochOneFee() public {
        vm.warp(rewards.feeEpochStartsAt() - 1);
        uint256 aliceId = _lock(alice, 1_000 ether, 0);
        assertEq(rewards.position(aliceId).activationEpoch, 1);

        vm.warp(rewards.feeEpochStartsAt());
        uint256 bobId = _lock(bob, 10_000 ether, 2);
        assertEq(rewards.position(bobId).activationEpoch, 2);
        (, uint256 fee) = _boost(launchToken, 100 ether, 0);

        vm.warp(rewards.claimEpochStartsAt());
        rewards.checkpoint(64);
        assertGt(rewards.settledClaimable(aliceId), 0);
        assertEq(rewards.settledClaimable(bobId), 0);
        assertLe(fee - rewards.settledClaimable(aliceId), 1);
    }

    function test_multipleFeesAreProRataAndCannotBeClaimedTwice() public {
        uint256 aliceId = _lock(alice, 1_000 ether, 0);
        uint256 bobId = _lock(bob, 2_000 ether, 0);
        vm.warp(rewards.feeEpochStartsAt());
        (, uint256 firstFee) = _boost(launchToken, 10_000 ether, 0);
        (, uint256 secondFee) = _boost(launchToken, 20_000 ether, 0);

        vm.warp(rewards.claimEpochStartsAt());
        rewards.checkpoint(64);
        uint256 aliceClaimable = rewards.settledClaimable(aliceId);
        uint256 bobClaimable = rewards.settledClaimable(bobId);
        assertApproxEqAbs(bobClaimable, aliceClaimable * 2, 2);
        assertLe(firstFee + secondFee - aliceClaimable - bobClaimable, 2);

        vm.prank(alice);
        rewards.claim(aliceId, alice);
        vm.prank(alice);
        vm.expectRevert(HookrLockRewardsV2.NothingToClaim.selector);
        rewards.claim(aliceId, alice);
        vm.prank(bob);
        rewards.claim(bobId, bob);
        _assertSolvent();
    }

    function test_bridgeFeeRoutesToEpochTwoAndSettlesAtMonday() public {
        uint256 aliceId = _lock(alice, 1_000 ether, 0);
        vm.warp(rewards.feeEpochStartsAt());
        uint256 bobId = _lock(bob, 2_000 ether, 0);
        _boost(launchToken, 100 ether, 0);

        vm.warp(rewards.claimEpochStartsAt());
        vm.prank(alice);
        rewards.claim(aliceId, alice);
        (, uint256 bridgeFee) = _boost(launchToken, 100 ether, 0);
        assertEq(bridgeFee, 1 ether);
        assertEq(rewards.boostFeesByEpoch(2), bridgeFee);
        assertEq(rewards.settledClaimable(aliceId), 0);
        assertEq(rewards.settledClaimable(bobId), 0);

        vm.warp(rewards.weeklyEpochsStartAt());
        rewards.checkpoint(64);
        uint256 aliceClaimable = rewards.settledClaimable(aliceId);
        uint256 bobClaimable = rewards.settledClaimable(bobId);
        assertApproxEqAbs(bobClaimable, aliceClaimable * 2, 2);
        assertLe(bridgeFee - aliceClaimable - bobClaimable, 2);
        assertEq(rewards.currentEpoch(), 3);
        assertEq(rewards.checkpointEpoch(), 3);
    }

    function test_noCohortStillWaivesFeeAfterOpening() public {
        vm.warp(rewards.feeEpochStartsAt());
        (uint256 principal, uint256 fee) = _boost(launchToken, 100 ether, 0);
        assertEq(principal, 100 ether);
        assertEq(fee, 0);
        assertEq(rewards.rewardReserve(), 0);
        assertEq(boost.totalBoostPrincipal(), 100 ether);
    }

    function test_tierDurationsWeightsAndPrincipalCustodyRemainExact() public {
        uint40 lockedAt = uint40(block.timestamp);
        uint256 id30 = _lock(alice, 1_000 ether, 0);
        uint256 id90 = _lock(alice, 1_000 ether, 1);
        uint256 id180 = _lock(alice, 1_000 ether, 2);
        HookrLockRewardsV2.Position memory p30 = rewards.position(id30);
        HookrLockRewardsV2.Position memory p90 = rewards.position(id90);
        HookrLockRewardsV2.Position memory p180 = rewards.position(id180);
        assertEq(p30.unlockAt, lockedAt + 30 days);
        assertEq(p90.unlockAt, lockedAt + 90 days);
        assertEq(p180.unlockAt, lockedAt + 180 days);
        assertEq(p30.weight, 1_000 ether);
        assertEq(p90.weight, 1_150 ether);
        assertEq(p180.weight, 1_250 ether);
        assertLe(rewards.epochStart(p30.expiryEpoch), p30.unlockAt);
        assertGt(rewards.epochStart(p30.expiryEpoch + 1), p30.unlockAt);

        vm.warp(p30.unlockAt - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HookrLockRewardsV2.PositionStillLocked.selector, p30.unlockAt));
        rewards.withdraw(id30, alice);
        vm.warp(p30.unlockAt);
        uint256 before = hookr.balanceOf(alice);
        vm.prank(alice);
        (uint256 principal,) = rewards.withdraw(id30, alice);
        assertEq(principal, 1_000 ether);
        assertEq(hookr.balanceOf(alice) - before, principal);
        assertEq(rewards.totalLockedPrincipal(), 2_000 ether);
        _assertSolvent();
    }

    function test_boundedCheckpointStillRequiresPermissionlessCatchup() public {
        uint32 target = 130;
        vm.warp(rewards.epochStart(target));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HookrLockRewardsV2.CheckpointRequired.selector, 64, target));
        rewards.lock(1 ether, 0, type(uint32).max, type(uint40).max, block.timestamp + 1 hours);
        assertEq(rewards.checkpointEpoch(), 0);
        assertEq(rewards.checkpoint(64), 64);
        assertEq(rewards.checkpoint(64), 128);
        assertEq(rewards.checkpoint(64), target);
        assertTrue(rewards.checkpointCurrent());
    }

    function test_rewardSourceIsOneShotAndNonSourceCannotNotify() public {
        MockHookrUtilityToken localToken = new MockHookrUtilityToken();
        HookrLockRewardsV2 fresh = new HookrLockRewardsV2(localToken, address(this));
        fresh.setRewardSourceOnce(address(boost));
        assertEq(fresh.rewardSource(), address(boost));
        assertEq(fresh.configurator(), address(0));
        vm.expectRevert(HookrLockRewardsV2.NotConfigurator.selector);
        fresh.setRewardSourceOnce(address(boost));
        vm.prank(outsider);
        vm.expectRevert(HookrLockRewardsV2.NotRewardSource.selector);
        rewards.notifyBoostFee(1);
    }

    function test_capacityFailureCannotMutateRewardOrCustodyState() public {
        vm.warp(rewards.feeEpochStartsAt());
        _approve(creator, address(boost), type(uint256).max);
        for (uint256 i; i < boost.MAX_ACTIVE_BOOSTS(); ++i) {
            address token = address(uint160(0x700000 + i));
            launchpad.setLaunch(token, creator);
            vm.prank(creator);
            boost.boost(token, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
        }
        assertEq(boost.boostedTokensCount(), 512);

        address overflowToken = address(0xDECAFBAD);
        launchpad.setLaunch(overflowToken, creator);
        uint256 creatorBalance = hookr.balanceOf(creator);
        uint256 boostBalance = hookr.balanceOf(address(boost));
        uint256 gross = boost.cumulativeGrossBoosted();
        uint256 reserve = rewards.rewardReserve();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV2.CapacityFull.selector, 512));
        boost.boost(overflowToken, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
        assertEq(hookr.balanceOf(creator), creatorBalance);
        assertEq(hookr.balanceOf(address(boost)), boostBalance);
        assertEq(boost.cumulativeGrossBoosted(), gross);
        assertEq(rewards.rewardReserve(), reserve);
    }

    function test_prunePreservesCustodyAndCreatorCanWithdraw() public {
        vm.warp(rewards.feeEpochStartsAt());
        (uint256 principal,) = _boost(launchToken, 100 ether, 0);
        HookrLaunchBoostV2.BoostPosition memory beforePosition = boost.boostOf(launchToken);
        vm.warp(beforePosition.unlockAt);
        vm.prank(outsider);
        boost.pruneExpired(launchToken);
        HookrLaunchBoostV2.BoostPosition memory afterPrune = boost.boostOf(launchToken);
        assertEq(afterPrune.creator, beforePosition.creator);
        assertEq(afterPrune.principal, beforePosition.principal);
        assertEq(boost.totalBoostPrincipal(), principal);
        assertFalse(boost.isBoostRegistered(launchToken));
        uint256 before = hookr.balanceOf(creator);
        vm.prank(creator);
        assertEq(boost.withdraw(launchToken, creator), principal);
        assertEq(hookr.balanceOf(creator) - before, principal);
        assertEq(boost.totalBoostPrincipal(), 0);
    }

    function test_hostileTokenBehaviorAndCallbacksRemainAtomic() public {
        AdversarialHookrUtilityToken token = new AdversarialHookrUtilityToken();
        MockHookrLaunchpad pad = new MockHookrLaunchpad();
        HookrLockRewardsV2 localRewards = new HookrLockRewardsV2(token, address(this));
        HookrLaunchBoostV2 localBoost = new HookrLaunchBoostV2(
            token, HookrLaunchpad(payable(address(pad))), IHookrLockRewardsV2(address(localRewards))
        );
        localRewards.setRewardSourceOnce(address(localBoost));
        pad.setLaunch(launchToken, creator);
        token.mint(alice, 10_000 ether);
        token.mint(creator, 10_000 ether);

        vm.prank(alice);
        token.approve(address(localRewards), 1_000 ether);
        token.setTaxModes(true, false);
        vm.prank(alice);
        vm.expectRevert(HookrTokenTransfer.UnsupportedTokenBehavior.selector);
        localRewards.lock(1_000 ether, 0, type(uint32).max, type(uint40).max, block.timestamp + 1 hours);
        assertEq(localRewards.totalLockedPrincipal(), 0);

        token.setTaxModes(false, false);
        token.setCallback(
            address(localRewards),
            abi.encodeCall(
                HookrLockRewardsV2.lock, (100 ether, 0, type(uint32).max, type(uint40).max, block.timestamp + 1 hours)
            )
        );
        vm.prank(alice);
        localRewards.lock(1_000 ether, 0, type(uint32).max, type(uint40).max, block.timestamp + 1 hours);
        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackRevertSelector(), HookrLockRewardsV2.ReentrantCall.selector);

        vm.warp(localRewards.feeEpochStartsAt());
        token.setCallback(address(0), bytes(""));
        vm.prank(creator);
        token.approve(address(localBoost), 1_000 ether);
        token.setTaxModes(false, true);
        uint256 boostDeadline = uint256(localRewards.feeEpochStartsAt()) + 1 hours;
        vm.prank(creator);
        vm.expectRevert(HookrLockRewardsV2.AccountingInvariant.selector);
        localBoost.boost(launchToken, 1_000 ether, 0, type(uint256).max, 0, boostDeadline);
        assertEq(localBoost.totalBoostPrincipal(), 0);
        assertEq(localRewards.rewardReserve(), 0);
    }

    function testFuzz_ceilFeeRemainsSplitProof(uint96 firstRaw, uint96 secondRaw) public {
        _lock(alice, 1_000 ether, 0);
        vm.warp(rewards.feeEpochStartsAt());
        rewards.checkpoint(64);
        uint256 first = bound(uint256(firstRaw), 100 ether, type(uint96).max);
        uint256 second = bound(uint256(secondRaw), 100 ether, type(uint96).max);
        (uint256 firstFee,,,,,,) = boost.previewBoost(first, 0);
        (uint256 secondFee,,,,,,) = boost.previewBoost(second, 0);
        (uint256 combinedFee,,,,,,) = boost.previewBoost(first + second, 0);
        assertEq(firstFee, first / 100 + (first % 100 == 0 ? 0 : 1));
        assertEq(secondFee, second / 100 + (second % 100 == 0 ? 0 : 1));
        assertGe(firstFee + secondFee, combinedFee);
    }

    function testFuzz_solvencyTracksRewardAndBoostLiabilities(uint96 lockRaw, uint96 boostRaw) public {
        uint256 lockAmount = bound(uint256(lockRaw), 1 ether, 1_000_000 ether);
        uint256 boostAmount = bound(uint256(boostRaw), 100 ether, 1_000_000 ether);
        _lock(alice, lockAmount, 1);
        vm.warp(rewards.feeEpochStartsAt());
        _boost(launchToken, boostAmount, 2);
        _assertSolvent();
        vm.warp(rewards.claimEpochStartsAt());
        vm.prank(alice);
        rewards.claim(1, alice);
        _assertSolvent();
    }
}
