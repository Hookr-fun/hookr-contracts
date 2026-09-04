// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLaunchBoostV1} from "../src/HookrLaunchBoostV1.sol";
import {HookrLockRewardsV1} from "../src/HookrLockRewardsV1.sol";
import {IHookrLockRewardsV1} from "../src/interfaces/IHookrLockRewardsV1.sol";
import {HookrTokenTransfer, IHookrUtilityToken} from "../src/libraries/HookrTokenTransfer.sol";

contract MockHookrUtilityToken is IHookrUtilityToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8, bytes32, bytes32)
        public
        virtual
    {
        require(block.timestamp <= deadline, "permit expired");
        nonces[owner] += 1;
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }
}

contract AdversarialHookrUtilityToken is MockHookrUtilityToken {
    bool public taxTransferFrom;
    bool public taxTransfer;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes4 public callbackRevertSelector;

    bool internal callbackActive;

    function setTaxModes(bool transferFromTaxed, bool transferTaxed) external {
        taxTransferFrom = transferFromTaxed;
        taxTransfer = transferTaxed;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        callbackAttempted = false;
        callbackSucceeded = false;
        callbackRevertSelector = bytes4(0);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 received = taxTransfer && amount != 0 ? amount - 1 : amount;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += received;
        emit Transfer(msg.sender, to, received);
        if (received != amount) emit Transfer(msg.sender, address(0xdead), amount - received);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (callbackTarget != address(0) && !callbackActive) {
            callbackActive = true;
            callbackAttempted = true;
            bytes memory returnData;
            (callbackSucceeded, returnData) = callbackTarget.call(callbackData);
            if (!callbackSucceeded && returnData.length >= 4) {
                bytes4 selector;
                assembly ("memory-safe") {
                    selector := mload(add(returnData, 0x20))
                }
                callbackRevertSelector = selector;
            }
            callbackActive = false;
        }

        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        uint256 received = taxTransferFrom && amount != 0 ? amount - 1 : amount;
        balanceOf[from] -= amount;
        balanceOf[to] += received;
        emit Transfer(from, to, received);
        if (received != amount) emit Transfer(from, address(0xdead), amount - received);
        return true;
    }
}

contract MockHookrLaunchpad {
    mapping(address => HookrLaunchpad.Launch) internal launches;
    mapping(address creator => mapping(bytes32 intentId => address token)) public launchedByIntent;

    function setLaunch(address token, address creator) external {
        HookrLaunchpad.Launch storage launch = launches[token];
        launch.token = token;
        launch.creator = creator;
        launch.launchBlock = uint40(block.number);
        launch.poolId = PoolId.wrap(bytes32(uint256(uint160(token))));
    }

    function setIntent(address creator, bytes32 intentId, address token) external {
        launchedByIntent[creator][intentId] = token;
    }

    function getLaunch(address token) external view returns (HookrLaunchpad.Launch memory) {
        return launches[token];
    }
}

contract HookrLockRewardsV1Test is Test {
    event BoostPruned(
        address indexed token, address indexed creator, address indexed pruner, uint256 principal, uint40 unlockAt
    );

    MockHookrUtilityToken internal hookr;
    MockHookrLaunchpad internal launchpad;
    HookrLockRewardsV1 internal rewards;
    HookrLaunchBoostV1 internal boost;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal creator = address(0xC0FFEE);
    address internal outsider = address(0xBAD);
    address internal launchToken = address(0xF15);
    bytes32 internal intentId = keccak256("hookr.utility.test.intent");

    function setUp() public {
        // Keep the test clock well beyond the fixed Monday epoch offset.
        vm.warp(1_800_000_000);

        hookr = new MockHookrUtilityToken();
        launchpad = new MockHookrLaunchpad();
        rewards = new HookrLockRewardsV1(hookr, address(this));
        boost = new HookrLaunchBoostV1(
            hookr, HookrLaunchpad(payable(address(launchpad))), IHookrLockRewardsV1(address(rewards))
        );
        rewards.setRewardSourceOnce(address(boost));

        launchpad.setLaunch(launchToken, creator);
        launchpad.setIntent(creator, intentId, launchToken);

        hookr.mint(alice, 10_000_000 ether);
        hookr.mint(bob, 10_000_000 ether);
        hookr.mint(creator, 10_000_000 ether);
        hookr.mint(outsider, 10_000_000 ether);
    }

    function _approve(address account, address spender, uint256 amount) internal {
        vm.prank(account);
        hookr.approve(spender, amount);
    }

    function _lock(address account, uint256 amount, uint8 tier) internal returns (uint256 positionId) {
        _approve(account, address(rewards), amount);
        (, uint32 maxActivationEpoch,, uint40 maxUnlockAt,) = rewards.previewLock(amount, tier);
        vm.prank(account);
        positionId = rewards.lock(amount, tier, maxActivationEpoch, maxUnlockAt, block.timestamp + 1 hours);
    }

    function _activateNextEpoch() internal {
        vm.warp(rewards.epochStart(rewards.currentEpoch() + 1));
        rewards.checkpoint(64);
        assertTrue(rewards.checkpointCurrent(), "checkpoint current");
    }

    function _boost(address account, uint256 amount, uint8 tier) internal returns (uint256 principal, uint256 fee) {
        _approve(account, address(boost), amount);
        vm.prank(account);
        return boost.boost(launchToken, amount, tier, type(uint256).max, 0, type(uint256).max);
    }

    function _launchAndBoost(address token, uint256 amount) internal returns (uint256 principal) {
        launchpad.setLaunch(token, creator);
        vm.prank(creator);
        (principal,) = boost.boost(token, amount, 0, type(uint256).max, 0, type(uint256).max);
    }

    function _assertBoostRegistryConsistent() internal view {
        uint256 count = boost.boostedTokensCount();
        address[] memory page = boost.boostedTokensPage(0, count + 1);
        assertEq(page.length, count, "registry count matches page");
        for (uint256 i; i < count; ++i) {
            assertTrue(page[i] != address(0), "registered token is nonzero");
            assertTrue(boost.isBoostRegistered(page[i]), "registered getter agrees");
            assertEq(boost.boostedTokenIndexPlusOne(page[i]), i + 1, "reverse index agrees");
            for (uint256 j; j < i; ++j) {
                assertTrue(page[i] != page[j], "registry tokens are unique");
            }
        }
    }

    function _assertSameBoostPosition(
        HookrLaunchBoostV1.BoostPosition memory actual,
        HookrLaunchBoostV1.BoostPosition memory expected,
        string memory reason
    ) internal pure {
        assertEq(actual.creator, expected.creator, string.concat(reason, ": creator"));
        assertEq(actual.principal, expected.principal, string.concat(reason, ": principal"));
        assertEq(actual.startedAt, expected.startedAt, string.concat(reason, ": startedAt"));
        assertEq(actual.unlockAt, expected.unlockAt, string.concat(reason, ": unlockAt"));
        assertEq(actual.startedAtBlock, expected.startedAtBlock, string.concat(reason, ": startedAtBlock"));
        assertEq(actual.tier, expected.tier, string.concat(reason, ": tier"));
    }

    function _assertExactSolvencyIdentities() internal view {
        (uint256 vaultBalance, uint256 lockedPrincipal, uint256 rewardLiability, uint256 vaultSurplus, bool vaultOk) =
            rewards.solvency();
        assertTrue(vaultOk, "lock vault insolvent");
        assertEq(vaultBalance, lockedPrincipal + rewardLiability + vaultSurplus, "lock vault identity");
        assertEq(
            rewards.cumulativeBoostFeesNotified(),
            rewards.cumulativeRewardsClaimed() + rewards.rewardReserve(),
            "reward reserve identity"
        );
        assertLe(rewards.roundingCarry(), rewards.rewardReserve(), "indexed dust remains fully backed");

        (uint256 boostBalance, uint256 boostPrincipal, uint256 boostSurplus, bool boostOk) = boost.solvency();
        assertTrue(boostOk, "boost vault insolvent");
        assertEq(boostBalance, boostPrincipal + boostSurplus, "boost vault identity");
        assertEq(
            boost.cumulativeGrossBoosted(),
            boost.cumulativePrincipalAdded() + boost.cumulativeFeesForwarded(),
            "gross split identity"
        );
        assertEq(boost.cumulativeFeesForwarded(), rewards.cumulativeBoostFeesNotified(), "cross-vault fee identity");
    }

    function test_lockActivatesAtNextBoundaryAndReceivesRealizedBoostFee() public {
        uint256 positionId = _lock(alice, 100_000 ether, 0);
        assertEq(rewards.currentEligibleWeight(), 0, "deposit epoch is ineligible");

        HookrLockRewardsV1.Position memory position = rewards.position(positionId);
        assertEq(position.principal, 100_000 ether);
        assertEq(position.weight, 100_000 ether);
        assertEq(position.activationEpoch, rewards.currentEpoch() + 1);

        _activateNextEpoch();
        assertEq(rewards.currentEligibleWeight(), 100_000 ether);

        (uint256 principal, uint256 fee) = _boost(creator, 1_000_000 ether, 0);
        assertEq(fee, 10_000 ether);
        assertEq(principal, 990_000 ether);
        assertEq(rewards.rewardReserve(), fee);
        assertEq(boost.totalBoostPrincipal(), principal);

        _activateNextEpoch();
        uint256 claimable = rewards.settledClaimable(positionId);
        assertLe(fee - claimable, 1, "only fixed-point dust may remain");

        uint256 before = hookr.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = rewards.claim(positionId, alice);
        assertEq(hookr.balanceOf(alice) - before, claimed);
        assertEq(claimed, claimable);
        assertEq(rewards.cumulativeRewardsClaimed(), claimed);
    }

    function test_feeIsWaivedWithoutPrecommittedEligibleLockers() public {
        (uint256 principal, uint256 fee) = _boost(creator, 1_000_000 ether, 0);
        assertEq(fee, 0);
        assertEq(principal, 1_000_000 ether);
        assertEq(rewards.rewardReserve(), 0);
        assertEq(boost.cumulativeFeesForwarded(), 0);
        assertEq(boost.scoreOf(launchToken), principal);
    }

    function test_newLockerCannotCaptureFeeFromDepositEpoch() public {
        uint256 aliceId = _lock(alice, 100_000 ether, 0);
        _activateNextEpoch();

        (, uint256 fee) = _boost(creator, 100_000 ether, 0);
        uint256 bobId = _lock(bob, 100_000 ether, 2);

        _activateNextEpoch();
        assertGt(rewards.settledClaimable(aliceId), 0);
        assertEq(rewards.settledClaimable(bobId), 0, "bob was not active for the complete fee epoch");

        HookrLockRewardsV1.Position memory bobPosition = rewards.position(bobId);
        assertEq(bobPosition.weight, 125_000 ether);
        assertEq(rewards.currentEligibleWeight(), 225_000 ether);
        assertLe(fee - rewards.settledClaimable(aliceId), 1);
    }

    function test_rewardWeightUsesConservativeDurationMultipliers() public {
        uint256 aliceId = _lock(alice, 100_000 ether, 0);
        uint256 bobId = _lock(bob, 100_000 ether, 2);

        HookrLockRewardsV1.Position memory a = rewards.position(aliceId);
        HookrLockRewardsV1.Position memory b = rewards.position(bobId);
        assertEq(a.weight, 100_000 ether);
        assertEq(b.weight, 125_000 ether);
        assertEq(b.weight * 4, a.weight * 5, "180d is capped at 1.25x");
    }

    function test_onlyCanonicalCreatorCanBoostAndIntentPathRepeatsValidation() public {
        _approve(outsider, address(boost), 1_000 ether);
        vm.prank(outsider);
        vm.expectRevert(HookrLaunchBoostV1.NotLaunchCreator.selector);
        boost.boost(launchToken, 1_000 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);

        vm.prank(creator);
        hookr.approve(address(boost), 1_000 ether);
        vm.prank(creator);
        (address resolved, uint256 principal, uint256 fee) =
            boost.boostByIntent(intentId, 1_000 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
        assertEq(resolved, launchToken);
        assertEq(principal, 1_000 ether);
        assertEq(fee, 0);

        vm.prank(creator);
        vm.expectRevert(HookrLaunchBoostV1.UnknownLaunch.selector);
        boost.boost(address(0xDEAD), 1_000 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
    }

    function test_boostTopUpChargesOnlyNewTokensAndRelocksWholePrincipal() public {
        _lock(alice, 100_000 ether, 0);
        _activateNextEpoch();

        (uint256 firstPrincipal, uint256 firstFee) = _boost(creator, 10_000 ether, 0);
        HookrLaunchBoostV1.BoostPosition memory first = boost.boostOf(launchToken);

        vm.warp(block.timestamp + 1 days);
        (uint256 secondPrincipal, uint256 secondFee) = _boost(creator, 20_000 ether, 1);
        HookrLaunchBoostV1.BoostPosition memory second = boost.boostOf(launchToken);

        assertEq(firstFee, 100 ether);
        assertEq(secondFee, 200 ether);
        assertEq(second.principal, firstPrincipal + secondPrincipal);
        assertEq(second.tier, 1);
        assertGt(second.unlockAt, first.unlockAt, "whole aggregate relocked to longer term");
        assertEq(boost.scoreOf(launchToken), (uint256(second.principal) * 11_500) / 10_000);
    }

    function test_boostAndLockPrincipalAreFullyWithdrawableAtTheirOwnUnlocks() public {
        uint256 positionId = _lock(alice, 100_000 ether, 0);
        _activateNextEpoch();
        (uint256 boostPrincipal,) = _boost(creator, 10_000 ether, 0);

        HookrLaunchBoostV1.BoostPosition memory bp = boost.boostOf(launchToken);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV1.BoostStillLocked.selector, bp.unlockAt));
        boost.withdraw(launchToken, creator);

        vm.warp(bp.unlockAt);
        uint256 creatorBefore = hookr.balanceOf(creator);
        vm.prank(creator);
        assertEq(boost.withdraw(launchToken, creator), boostPrincipal);
        assertEq(hookr.balanceOf(creator) - creatorBefore, boostPrincipal);
        assertEq(boost.scoreOf(launchToken), 0);

        HookrLockRewardsV1.Position memory lp = rewards.position(positionId);
        if (block.timestamp < lp.unlockAt) vm.warp(lp.unlockAt);
        rewards.checkpoint(64);
        uint256 aliceBefore = hookr.balanceOf(alice);
        vm.prank(alice);
        (uint256 principal,) = rewards.withdraw(positionId, alice);
        assertEq(principal, 100_000 ether);
        assertGe(hookr.balanceOf(alice) - aliceBefore, principal);
    }

    function test_directDonationsAreSurplusNotPrincipalOrRewards() public {
        hookr.mint(address(rewards), 777 ether);
        hookr.mint(address(boost), 333 ether);

        (uint256 vaultBalance, uint256 principal, uint256 reserve, uint256 vaultSurplus, bool vaultSolvent) =
            rewards.solvency();
        assertTrue(vaultSolvent);
        assertEq(vaultBalance, 777 ether);
        assertEq(principal, 0);
        assertEq(reserve, 0);
        assertEq(vaultSurplus, 777 ether);

        (uint256 boostBalance, uint256 boostLiability, uint256 boostSurplus, bool boostSolvent) = boost.solvency();
        assertTrue(boostSolvent);
        assertEq(boostBalance, 333 ether);
        assertEq(boostLiability, 0);
        assertEq(boostSurplus, 333 ether);
    }

    function test_permitPathsRemainBoundToCallerAndExactAction() public {
        vm.prank(alice);
        uint256 positionId = rewards.lockWithPermit(
            1_000 ether,
            0,
            type(uint32).max,
            type(uint40).max,
            block.timestamp + 1 hours,
            27,
            bytes32(uint256(1)),
            bytes32(uint256(2))
        );
        assertEq(rewards.position(positionId).owner, alice);

        vm.prank(creator);
        (uint256 principal,) = boost.boostWithPermit(
            launchToken,
            1_000 ether,
            0,
            type(uint256).max,
            0,
            block.timestamp + 1 hours,
            27,
            bytes32(uint256(3)),
            bytes32(uint256(4))
        );
        assertEq(principal, 1_000 ether);
        assertEq(boost.boostOf(launchToken).creator, creator);

        vm.prank(creator);
        (address resolved, uint256 intentPrincipal, uint256 intentFee) = boost.boostByIntentWithPermit(
            intentId,
            500 ether,
            0,
            0,
            500 ether,
            block.timestamp + 1 hours,
            27,
            bytes32(uint256(5)),
            bytes32(uint256(6))
        );
        assertEq(resolved, launchToken);
        assertEq(intentPrincipal, 500 ether);
        assertEq(intentFee, 0);
    }

    function test_executionBoundsRejectFeeEligibilityFlipBeforeTokenPull() public {
        _lock(alice, 100_000 ether, 0);
        (uint256 previewFee, uint256 previewPrincipal,,,, bool feeWouldApply,) = boost.previewBoost(1_000 ether, 0);
        assertFalse(feeWouldApply);
        assertEq(previewFee, 0);
        assertEq(previewPrincipal, 1_000 ether);

        _approve(creator, address(boost), 1_000 ether);
        vm.warp(rewards.epochStart(rewards.currentEpoch() + 1));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV1.RewardFeeAboveMaximum.selector, 10 ether, 0));
        boost.boost(launchToken, 1_000 ether, 0, 0, 0, block.timestamp + 1 hours);

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(HookrLaunchBoostV1.PrincipalBelowMinimum.selector, 990 ether, 1_000 ether)
        );
        boost.boost(launchToken, 1_000 ether, 0, 10 ether, 1_000 ether, block.timestamp + 1 hours);

        assertEq(hookr.balanceOf(address(boost)), 0, "bounds fail before token pull");
        assertEq(hookr.allowance(creator, address(boost)), 1_000 ether, "failed bounds preserve allowance");
        assertEq(rewards.rewardReserve(), 0, "failed bounds cannot notify rewards");

        vm.prank(creator);
        (uint256 principal, uint256 fee) =
            boost.boost(launchToken, 1_000 ether, 0, 10 ether, 990 ether, block.timestamp + 1 hours);
        assertEq(principal, 990 ether);
        assertEq(fee, 10 ether);
    }

    function test_minimumGrossBoostIs100HookrAndRejectsBeforeTokenPull() public {
        assertEq(boost.MIN_GROSS_BOOST(), 100 ether);
        _approve(creator, address(boost), 99 ether);

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(HookrLaunchBoostV1.GrossAmountBelowMinimum.selector, 99 ether, 100 ether)
        );
        boost.boost(launchToken, 99 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);

        assertEq(hookr.balanceOf(address(boost)), 0, "minimum fails before token pull");
        assertEq(hookr.allowance(creator, address(boost)), 99 ether, "minimum preserves allowance");
        assertEq(boost.boostedTokensCount(), 0, "minimum cannot append registry");
    }

    function test_extendBoundRejectsMiningDriftBeforePositionMutation() public {
        _boost(creator, 1_000 ether, 0);
        HookrLaunchBoostV1.BoostPosition memory beforePosition = boost.boostOf(launchToken);

        uint256 rawPreviewUnlock = block.timestamp + 90 days;
        assertLe(rawPreviewUnlock, type(uint40).max);
        // Safe after the explicit uint40 upper bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 previewUnlock = uint40(rawPreviewUnlock);

        vm.warp(block.timestamp + 61);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(HookrLaunchBoostV1.UnlockAtAboveMaximum.selector, previewUnlock + 61, previewUnlock)
        );
        boost.extend(launchToken, 1, previewUnlock, block.timestamp + 1 hours);

        HookrLaunchBoostV1.BoostPosition memory afterRevert = boost.boostOf(launchToken);
        assertEq(afterRevert.principal, beforePosition.principal, "failed bound changed principal");
        assertEq(afterRevert.tier, beforePosition.tier, "failed bound changed tier");
        assertEq(afterRevert.unlockAt, beforePosition.unlockAt, "failed bound changed unlock");

        vm.prank(creator);
        uint40 extendedUnlock = boost.extend(launchToken, 1, previewUnlock + 120, block.timestamp + 1 hours);
        assertEq(extendedUnlock, previewUnlock + 61, "bounded extension uses mined timestamp");
        HookrLaunchBoostV1.BoostPosition memory extended = boost.boostOf(launchToken);
        assertEq(extended.tier, 1);
        assertEq(extended.unlockAt, extendedUnlock);
    }

    function test_pruneOnlyRemovesEnumerationThenCreatorCanWithdrawAndReboost() public {
        address tokenA = address(0xA001);
        address tokenB = address(0xB002);
        address tokenC = address(0xC003);
        _approve(creator, address(boost), type(uint256).max);
        _launchAndBoost(tokenA, 100 ether);
        _launchAndBoost(tokenB, 200 ether);
        _launchAndBoost(tokenC, 300 ether);
        _assertBoostRegistryConsistent();

        HookrLaunchBoostV1.BoostPosition memory beforePosition = boost.boostOf(tokenB);
        uint256 beforeLiability = boost.totalBoostPrincipal();
        uint256 beforeBalance = hookr.balanceOf(address(boost));
        uint256 beforeGross = boost.cumulativeGrossBoosted();
        uint256 beforePrincipalAdded = boost.cumulativePrincipalAdded();
        uint256 beforeFees = boost.cumulativeFeesForwarded();
        uint256 creatorBeforePrune = hookr.balanceOf(creator);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV1.BoostStillLocked.selector, beforePosition.unlockAt));
        boost.pruneExpired(tokenB);

        vm.warp(beforePosition.unlockAt);
        vm.expectEmit(true, true, true, true, address(boost));
        emit BoostPruned(tokenB, creator, outsider, beforePosition.principal, beforePosition.unlockAt);
        vm.prank(outsider);
        assertTrue(boost.pruneExpired(tokenB));

        assertEq(boost.boostedTokensCount(), 2, "prune removes exactly one registry member");
        assertEq(boost.boostedTokenIndexPlusOne(tokenB), 0, "pruned token has no reverse index");
        assertFalse(boost.isBoostRegistered(tokenB), "pruned token is not enumerated");
        assertEq(boost.boostedTokenIndexPlusOne(tokenC), 2, "last token swapped into removed middle slot");
        address[] memory page = boost.boostedTokensPage(0, 3);
        assertEq(page[0], tokenA);
        assertEq(page[1], tokenC);
        _assertBoostRegistryConsistent();

        _assertSameBoostPosition(boost.boostOf(tokenB), beforePosition, "prune preserves custody state");
        assertEq(boost.totalBoostPrincipal(), beforeLiability, "prune preserves principal liability");
        assertEq(hookr.balanceOf(address(boost)), beforeBalance, "prune cannot transfer principal");
        assertEq(hookr.balanceOf(creator), creatorBeforePrune, "prune cannot pay the creator");
        assertEq(boost.cumulativeGrossBoosted(), beforeGross, "prune preserves gross ledger");
        assertEq(boost.cumulativePrincipalAdded(), beforePrincipalAdded, "prune preserves principal ledger");
        assertEq(boost.cumulativeFeesForwarded(), beforeFees, "prune preserves fee ledger");

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV1.BoostNotRegistered.selector, tokenB));
        boost.pruneExpired(tokenB);

        vm.prank(outsider);
        vm.expectRevert(HookrLaunchBoostV1.NotLaunchCreator.selector);
        boost.withdraw(tokenB, outsider);

        uint256 creatorBeforeWithdraw = hookr.balanceOf(creator);
        vm.prank(creator);
        assertEq(boost.withdraw(tokenB, creator), beforePosition.principal, "withdraw works after prune");
        assertEq(hookr.balanceOf(creator) - creatorBeforeWithdraw, beforePosition.principal);
        assertEq(boost.boostedTokensCount(), 2, "withdraw after prune cannot remove another member");
        assertEq(boost.boostOf(tokenB).principal, 0, "withdraw deletes the settled position");
        _assertBoostRegistryConsistent();

        uint256 reboostedPrincipal = _launchAndBoost(tokenB, 400 ether);
        assertEq(reboostedPrincipal, 400 ether);
        assertEq(boost.boostedTokensCount(), 3, "withdrawn token can rejoin the registry");
        assertEq(boost.boostedTokenIndexPlusOne(tokenB), 3);
        assertTrue(boost.isBoostRegistered(tokenB));
        assertEq(boost.boostOf(tokenB).creator, creator);
        _assertBoostRegistryConsistent();
        _assertExactSolvencyIdentities();
    }

    function test_capacityRejectsReaddedPositionBeforePullOrFeeButAllowsRegisteredTopUp() public {
        assertEq(boost.MAX_ACTIVE_BOOSTS(), 512);
        address readdToken = address(0xBEEF1);
        _approve(creator, address(boost), type(uint256).max);

        _launchAndBoost(readdToken, 100 ether);
        HookrLaunchBoostV1.BoostPosition memory firstPosition = boost.boostOf(readdToken);
        vm.warp(firstPosition.unlockAt);
        vm.prank(creator);
        boost.withdraw(readdToken, creator);
        assertEq(boost.boostedTokensCount(), 0);

        _lock(alice, 1_000 ether, 0);
        _activateNextEpoch();
        address firstRegistered;
        for (uint256 i; i < boost.MAX_ACTIVE_BOOSTS(); ++i) {
            // Safe because i is bounded below 512 and the fixed prefix fits uint160.
            // forge-lint: disable-next-line(unsafe-typecast)
            address token = address(uint160(0x100000 + i));
            if (i == 0) firstRegistered = token;
            _launchAndBoost(token, 100 ether);
        }
        assertEq(boost.boostedTokensCount(), boost.MAX_ACTIVE_BOOSTS());
        _assertBoostRegistryConsistent();

        HookrLaunchBoostV1.BoostPosition memory beforeTopUp = boost.boostOf(firstRegistered);
        _launchAndBoost(firstRegistered, 100 ether);
        assertEq(boost.boostedTokensCount(), boost.MAX_ACTIVE_BOOSTS(), "registered top-up is allowed at capacity");
        assertEq(
            boost.boostOf(firstRegistered).principal,
            uint256(beforeTopUp.principal) + 99 ether,
            "eligible top-up adds 99% principal"
        );

        vm.warp(rewards.epochStart(rewards.currentEpoch() + 1));
        assertFalse(rewards.checkpointCurrent(), "capacity proof starts with a stale reward checkpoint");

        uint256 creatorBalanceBefore = hookr.balanceOf(creator);
        uint256 boostBalanceBefore = hookr.balanceOf(address(boost));
        uint256 rewardBalanceBefore = hookr.balanceOf(address(rewards));
        uint256 liabilityBefore = boost.totalBoostPrincipal();
        uint256 grossBefore = boost.cumulativeGrossBoosted();
        uint256 principalBefore = boost.cumulativePrincipalAdded();
        uint256 feesBefore = boost.cumulativeFeesForwarded();
        uint256 reserveBefore = rewards.rewardReserve();
        uint32 checkpointBefore = rewards.checkpointEpoch();

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV1.CapacityFull.selector, 512));
        boost.boost(readdToken, 100 ether, 0, 1 ether, 99 ether, type(uint256).max);

        assertEq(hookr.balanceOf(creator), creatorBalanceBefore, "capacity fails before token pull");
        assertEq(hookr.balanceOf(address(boost)), boostBalanceBefore, "capacity cannot add principal");
        assertEq(hookr.balanceOf(address(rewards)), rewardBalanceBefore, "capacity cannot forward a fee");
        assertEq(boost.totalBoostPrincipal(), liabilityBefore);
        assertEq(boost.cumulativeGrossBoosted(), grossBefore);
        assertEq(boost.cumulativePrincipalAdded(), principalBefore);
        assertEq(boost.cumulativeFeesForwarded(), feesBefore);
        assertEq(rewards.rewardReserve(), reserveBefore);
        assertEq(rewards.checkpointEpoch(), checkpointBefore, "capacity fails before reward checkpointing");
        assertEq(boost.boostedTokensCount(), 512);
        assertEq(boost.boostedTokenIndexPlusOne(readdToken), 0);
        assertEq(boost.boostOf(readdToken).principal, 0);
        _assertBoostRegistryConsistent();
        _assertExactSolvencyIdentities();
    }

    function test_lockBoundsRejectMondayRolloverAndUnlockDriftBeforeTokenPull() public {
        uint40 monday = rewards.epochStart(rewards.currentEpoch() + 1);
        vm.warp(monday - 1);
        (, uint32 previewActivation,,,) = rewards.previewLock(1_000 ether, 0);
        _approve(alice, address(rewards), 1_000 ether);

        vm.warp(monday);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                HookrLockRewardsV1.ActivationEpochAboveMaximum.selector, previewActivation + 1, previewActivation
            )
        );
        rewards.lock(1_000 ether, 0, previewActivation, type(uint40).max, block.timestamp + 1 hours);
        assertEq(hookr.balanceOf(address(rewards)), 0, "Monday bound fails before pull");
        assertEq(hookr.allowance(alice, address(rewards)), 1_000 ether, "Monday bound preserves allowance");

        vm.warp(monday + 1);
        (, uint32 stableActivation,, uint40 exactUnlock,) = rewards.previewLock(1_000 ether, 0);
        vm.warp(monday + 61);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(HookrLockRewardsV1.UnlockAtAboveMaximum.selector, exactUnlock + 60, exactUnlock)
        );
        rewards.lock(1_000 ether, 0, stableActivation, exactUnlock, block.timestamp + 1 hours);
        assertEq(hookr.balanceOf(address(rewards)), 0, "unlock bound fails before pull");

        vm.prank(alice);
        uint256 positionId =
            rewards.lock(1_000 ether, 0, stableActivation, exactUnlock + 120, block.timestamp + 1 hours);
        HookrLockRewardsV1.Position memory position = rewards.position(positionId);
        assertEq(position.activationEpoch, stableActivation);
        assertEq(position.unlockAt, exactUnlock + 60);
    }

    function test_ceilOnePercentFeeIsExactAndSplittingCannotReduceIt() public {
        _lock(alice, 1_000 ether, 0);
        _activateNextEpoch();

        uint256 firstGross = 100 ether + 1;
        uint256 secondGross = 100 ether + 49;
        uint256 combinedGross = firstGross + secondGross;
        (uint256 unsplitFee, uint256 unsplitPrincipal,,,, bool feeWouldApply,) = boost.previewBoost(combinedGross, 0);
        assertTrue(feeWouldApply);
        assertEq(unsplitFee, 2 ether + 1, "ceil(combined / 100)");
        assertEq(unsplitPrincipal, combinedGross - unsplitFee);

        (uint256 firstPrincipal, uint256 firstFee) = _boost(creator, firstGross, 0);
        (uint256 secondPrincipal, uint256 secondFee) = _boost(creator, secondGross, 0);
        assertEq(firstFee, 1 ether + 1, "ceil(first / 100)");
        assertEq(secondFee, 1 ether + 1, "ceil(second / 100)");
        assertEq(firstPrincipal + firstFee, firstGross, "first exact split");
        assertEq(secondPrincipal + secondFee, secondGross, "second exact split");
        assertGe(firstFee + secondFee, unsplitFee, "splitting must not reduce fee");
        assertEq(boost.cumulativeGrossBoosted(), combinedGross);
        assertEq(boost.cumulativePrincipalAdded(), combinedGross - firstFee - secondFee);
        assertEq(boost.cumulativeFeesForwarded(), firstFee + secondFee);
    }

    function test_multiLockerRewardsAreProportionalToCheckpointedWeight() public {
        uint256 aliceId = _lock(alice, 100_000 ether, 0);
        uint256 bobId = _lock(bob, 200_000 ether, 0);
        _activateNextEpoch();

        (, uint256 fee) = _boost(creator, 30_000 ether, 0);
        _activateNextEpoch();

        uint256 aliceClaimable = rewards.settledClaimable(aliceId);
        uint256 bobClaimable = rewards.settledClaimable(bobId);
        assertApproxEqAbs(bobClaimable, aliceClaimable * 2, 2, "2x weight receives 2x rewards");
        assertLe(fee - aliceClaimable - bobClaimable, 2, "only fixed-point dust remains");
    }

    function test_claimCannotBeRepeatedForTheSameSettledEpochs() public {
        uint256 positionId = _lock(alice, 100_000 ether, 0);
        _activateNextEpoch();
        _boost(creator, 10_000 ether, 0);
        _activateNextEpoch();

        vm.prank(alice);
        uint256 firstClaim = rewards.claim(positionId, alice);
        uint256 reserveAfterFirst = rewards.rewardReserve();
        uint256 claimedAfterFirst = rewards.cumulativeRewardsClaimed();

        vm.prank(alice);
        vm.expectRevert(HookrLockRewardsV1.NothingToClaim.selector);
        rewards.claim(positionId, alice);

        assertGt(firstClaim, 0);
        assertEq(rewards.rewardReserve(), reserveAfterFirst, "reserve unchanged by rejected second claim");
        assertEq(rewards.cumulativeRewardsClaimed(), claimedAfterFirst, "claim counter unchanged");
    }

    function test_expiredPositionWeightIsRemovedBeforeLaterFees() public {
        uint256 aliceId = _lock(alice, 100_000 ether, 0);
        uint256 bobId = _lock(bob, 100_000 ether, 2);
        _activateNextEpoch();
        HookrLockRewardsV1.Position memory alicePosition = rewards.position(aliceId);
        HookrLockRewardsV1.Position memory bobPosition = rewards.position(bobId);

        vm.warp(rewards.epochStart(alicePosition.expiryEpoch));
        rewards.checkpoint(64);
        assertEq(rewards.currentEligibleWeight(), bobPosition.weight, "expired weight removed at boundary");

        (, uint256 fee) = _boost(creator, 10_000 ether, 2);
        _activateNextEpoch();
        assertEq(rewards.settledClaimable(aliceId), 0, "expired lock cannot receive later fee");
        assertGt(rewards.settledClaimable(bobId), 0);
        assertLe(fee - rewards.settledClaimable(bobId), 1);
    }

    function test_rewardSourceConfigurationIsOneShotAndNonSourcesCannotNotify() public {
        HookrLockRewardsV1 fresh = new HookrLockRewardsV1(hookr, address(this));

        vm.prank(outsider);
        vm.expectRevert(HookrLockRewardsV1.NotConfigurator.selector);
        fresh.setRewardSourceOnce(address(boost));

        vm.expectRevert(HookrLockRewardsV1.ZeroAddress.selector);
        fresh.setRewardSourceOnce(outsider);

        fresh.setRewardSourceOnce(address(boost));
        assertEq(fresh.rewardSource(), address(boost));
        assertEq(fresh.configurator(), address(0), "temporary authority burned");

        vm.expectRevert(HookrLockRewardsV1.NotConfigurator.selector);
        fresh.setRewardSourceOnce(address(this));

        vm.prank(outsider);
        vm.expectRevert(HookrLockRewardsV1.NotRewardSource.selector);
        rewards.notifyBoostFee(1);
    }

    function test_backlogBeyondAutoLimitRequiresPersistentPermissionlessCatchUp() public {
        uint32 start = rewards.checkpointEpoch();
        uint32 target = start + 130;
        vm.warp(rewards.epochStart(target));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HookrLockRewardsV1.CheckpointRequired.selector, start + 64, target));
        rewards.lock(1 ether, 0, type(uint32).max, type(uint40).max, block.timestamp + 1 hours);
        assertEq(rewards.checkpointEpoch(), start, "reverting action rolls back its partial checkpoint");

        assertEq(rewards.checkpoint(64), start + 64);
        assertEq(rewards.checkpoint(64), start + 128);
        assertEq(rewards.checkpoint(64), target);
        assertTrue(rewards.checkpointCurrent());

        _approve(alice, address(rewards), 1 ether);
        vm.prank(alice);
        assertEq(
            rewards.lock(1 ether, 0, type(uint32).max, type(uint40).max, block.timestamp + 1 hours),
            1,
            "action works after explicit catch-up"
        );
    }

    function test_feeOnTransferDepositsAndFeeForwardingAreRejectedAtomically() public {
        AdversarialHookrUtilityToken taxed = new AdversarialHookrUtilityToken();
        MockHookrLaunchpad localPad = new MockHookrLaunchpad();
        HookrLockRewardsV1 localRewards = new HookrLockRewardsV1(taxed, address(this));
        HookrLaunchBoostV1 localBoost = new HookrLaunchBoostV1(
            taxed, HookrLaunchpad(payable(address(localPad))), IHookrLockRewardsV1(address(localRewards))
        );
        localRewards.setRewardSourceOnce(address(localBoost));
        localPad.setLaunch(launchToken, creator);
        taxed.mint(alice, 10_000 ether);
        taxed.mint(creator, 10_000 ether);

        vm.prank(alice);
        taxed.approve(address(localRewards), 1_000 ether);
        taxed.setTaxModes(true, false);
        vm.prank(alice);
        vm.expectRevert(HookrTokenTransfer.UnsupportedTokenBehavior.selector);
        localRewards.lock(1_000 ether, 0, type(uint32).max, type(uint40).max, block.timestamp + 1 hours);
        assertEq(localRewards.totalLockedPrincipal(), 0);
        assertEq(taxed.balanceOf(address(localRewards)), 0, "taxed pull fully rolled back");

        taxed.setTaxModes(false, false);
        vm.prank(alice);
        localRewards.lock(1_000 ether, 0, type(uint32).max, type(uint40).max, block.timestamp + 1 hours);
        vm.warp(localRewards.epochStart(localRewards.currentEpoch() + 1));
        localRewards.checkpoint(64);

        vm.prank(creator);
        taxed.approve(address(localBoost), 1_000 ether);
        taxed.setTaxModes(false, true);
        vm.prank(creator);
        vm.expectRevert(HookrLockRewardsV1.AccountingInvariant.selector);
        localBoost.boost(launchToken, 1_000 ether, 0, type(uint256).max, 0, type(uint256).max);
        assertEq(localBoost.totalBoostPrincipal(), 0);
        assertEq(localRewards.rewardReserve(), 0);
        assertEq(taxed.balanceOf(address(localBoost)), 0, "under-delivered fee transaction rolled back");
    }

    function test_tokenCallbacksCannotReenterLockOrBoost() public {
        AdversarialHookrUtilityToken callbackToken = new AdversarialHookrUtilityToken();
        MockHookrLaunchpad localPad = new MockHookrLaunchpad();
        HookrLockRewardsV1 localRewards = new HookrLockRewardsV1(callbackToken, address(this));
        HookrLaunchBoostV1 localBoost = new HookrLaunchBoostV1(
            callbackToken, HookrLaunchpad(payable(address(localPad))), IHookrLockRewardsV1(address(localRewards))
        );
        localRewards.setRewardSourceOnce(address(localBoost));
        localPad.setLaunch(launchToken, creator);
        callbackToken.mint(alice, 10_000 ether);
        callbackToken.mint(creator, 10_000 ether);

        vm.prank(alice);
        callbackToken.approve(address(localRewards), 1_000 ether);
        callbackToken.setCallback(
            address(localRewards),
            abi.encodeCall(
                HookrLockRewardsV1.lock, (100 ether, 0, type(uint32).max, type(uint40).max, block.timestamp + 1 hours)
            )
        );
        vm.prank(alice);
        assertEq(localRewards.lock(1_000 ether, 0, type(uint32).max, type(uint40).max, block.timestamp + 1 hours), 1);
        assertTrue(callbackToken.callbackAttempted());
        assertFalse(callbackToken.callbackSucceeded());
        assertEq(callbackToken.callbackRevertSelector(), HookrLockRewardsV1.ReentrantCall.selector);

        vm.prank(creator);
        callbackToken.approve(address(localBoost), 1_000 ether);
        callbackToken.setCallback(
            address(localBoost),
            abi.encodeCall(
                HookrLaunchBoostV1.boost, (launchToken, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours)
            )
        );
        vm.prank(creator);
        (uint256 principal, uint256 fee) =
            localBoost.boost(launchToken, 1_000 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
        assertEq(principal, 1_000 ether);
        assertEq(fee, 0);
        assertTrue(callbackToken.callbackAttempted());
        assertFalse(callbackToken.callbackSucceeded());
        assertEq(callbackToken.callbackRevertSelector(), HookrLaunchBoostV1.ReentrantCall.selector);
    }

    function test_frontrunPermitConsumptionFallsBackToExistingExactAllowance() public {
        uint256 deadline = block.timestamp + 1 hours;
        hookr.permit(alice, address(rewards), 1_000 ether, deadline, 27, bytes32(uint256(1)), bytes32(uint256(2)));
        assertEq(hookr.nonces(alice), 1, "permit consumed before bounded action");

        vm.prank(alice);
        uint256 positionId = rewards.lockWithPermit(
            1_000 ether,
            0,
            type(uint32).max,
            type(uint40).max,
            deadline,
            28,
            bytes32(uint256(999)),
            bytes32(uint256(999))
        );
        assertEq(rewards.position(positionId).owner, alice);
        assertEq(hookr.nonces(alice), 1, "stale permit skipped because allowance already exists");

        hookr.permit(creator, address(boost), 1_000 ether, deadline, 27, bytes32(uint256(3)), bytes32(uint256(4)));
        vm.prank(creator);
        (uint256 principal,) = boost.boostWithPermit(
            launchToken,
            1_000 ether,
            0,
            type(uint256).max,
            0,
            deadline,
            28,
            bytes32(uint256(999)),
            bytes32(uint256(999))
        );
        assertEq(principal, 1_000 ether);
        assertEq(hookr.nonces(creator), 1, "boost also tolerates a consumed permit");
    }

    function test_canary_localFullUtilityLifecyclePreservesExactSolvency() public {
        uint256 positionId = _lock(alice, 100_000 ether, 0);
        _assertExactSolvencyIdentities();
        _activateNextEpoch();
        _boost(creator, 10_000 ether, 0);
        _assertExactSolvencyIdentities();
        _activateNextEpoch();

        vm.prank(alice);
        rewards.claim(positionId, alice);
        _assertExactSolvencyIdentities();

        HookrLaunchBoostV1.BoostPosition memory bp = boost.boostOf(launchToken);
        vm.warp(bp.unlockAt);
        vm.prank(creator);
        boost.withdraw(launchToken, creator);
        _assertExactSolvencyIdentities();

        HookrLockRewardsV1.Position memory lp = rewards.position(positionId);
        if (block.timestamp < lp.unlockAt) vm.warp(lp.unlockAt);
        rewards.checkpoint(64);
        vm.prank(alice);
        rewards.withdraw(positionId, alice);
        _assertExactSolvencyIdentities();
    }

    function testFuzz_ceilFeeIsSplitProof(uint96 firstRaw, uint96 secondRaw) public {
        _lock(alice, 1_000 ether, 0);
        _activateNextEpoch();
        uint256 first = bound(uint256(firstRaw), 100, type(uint96).max);
        uint256 second = bound(uint256(secondRaw), 100, type(uint96).max);

        (uint256 firstFee,,,,,,) = boost.previewBoost(first, 0);
        (uint256 secondFee,,,,,,) = boost.previewBoost(second, 0);
        (uint256 combinedFee,,,,,,) = boost.previewBoost(first + second, 0);

        assertEq(firstFee, first / 100 + (first % 100 == 0 ? 0 : 1));
        assertEq(secondFee, second / 100 + (second % 100 == 0 ? 0 : 1));
        assertGe(firstFee + secondFee, combinedFee, "split deposits cannot reduce ceil fee");
    }

    function testFuzz_solvencyTracksBothLiabilityDomains(uint96 lockAmountRaw, uint96 boostAmountRaw) public {
        uint256 lockAmount = bound(uint256(lockAmountRaw), 1 ether, 1_000_000 ether);
        uint256 boostAmount = bound(uint256(boostAmountRaw), 100 ether, 1_000_000 ether);
        _lock(alice, lockAmount, 1);
        _activateNextEpoch();
        _boost(creator, boostAmount, 2);

        (uint256 vaultBalance, uint256 principal, uint256 reserve,, bool vaultSolvent) = rewards.solvency();
        assertTrue(vaultSolvent);
        assertGe(vaultBalance, principal + reserve);

        (uint256 boostBalance, uint256 boostLiability,, bool boostSolvent) = boost.solvency();
        assertTrue(boostSolvent);
        assertGe(boostBalance, boostLiability);
        assertEq(boost.cumulativeGrossBoosted(), boost.cumulativePrincipalAdded() + boost.cumulativeFeesForwarded());
        assertEq(boost.cumulativeFeesForwarded(), rewards.cumulativeBoostFeesNotified());
    }

    function testFuzz_registrySwapRemovalPreservesIndicesAndCustody(uint8 countRaw, uint8 removeRaw, bool pruneFirst)
        public
    {
        uint256 count = bound(uint256(countRaw), 2, 24);
        uint256 removeIndex = bound(uint256(removeRaw), 0, count - 1);
        _approve(creator, address(boost), type(uint256).max);

        address removedToken;
        for (uint256 i; i < count; ++i) {
            // Safe because count is bounded to 24 and the fixed prefix fits uint160.
            // forge-lint: disable-next-line(unsafe-typecast)
            address token = address(uint160(0x700000 + i));
            if (i == removeIndex) removedToken = token;
            _launchAndBoost(token, 100 ether + i);
        }
        _assertBoostRegistryConsistent();

        HookrLaunchBoostV1.BoostPosition memory beforePosition = boost.boostOf(removedToken);
        uint256 liabilityBefore = boost.totalBoostPrincipal();
        uint256 balanceBefore = hookr.balanceOf(address(boost));
        vm.warp(beforePosition.unlockAt);

        if (pruneFirst) {
            vm.prank(outsider);
            boost.pruneExpired(removedToken);
            _assertSameBoostPosition(boost.boostOf(removedToken), beforePosition, "fuzz prune preserves position");
            assertEq(boost.totalBoostPrincipal(), liabilityBefore, "fuzz prune preserves liability");
            assertEq(hookr.balanceOf(address(boost)), balanceBefore, "fuzz prune preserves balance");
            assertEq(boost.boostedTokensCount(), count - 1);
            _assertBoostRegistryConsistent();
        }

        vm.prank(creator);
        boost.withdraw(removedToken, creator);
        assertEq(boost.boostedTokensCount(), count - 1, "withdraw removes membership exactly once");
        assertEq(boost.boostedTokenIndexPlusOne(removedToken), 0);
        assertFalse(boost.isBoostRegistered(removedToken));
        assertEq(boost.boostOf(removedToken).principal, 0);
        _assertBoostRegistryConsistent();
        _assertExactSolvencyIdentities();
    }
}
