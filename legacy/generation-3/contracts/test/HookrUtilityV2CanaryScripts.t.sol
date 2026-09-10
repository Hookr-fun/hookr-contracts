// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {CanaryHookrUtilitiesV2Boost} from "../script/CanaryHookrUtilitiesV2Boost.s.sol";
import {CanaryHookrUtilitiesV2Claim} from "../script/CanaryHookrUtilitiesV2Claim.s.sol";
import {CanaryHookrUtilitiesV2Lock} from "../script/CanaryHookrUtilitiesV2Lock.s.sol";
import {DeployHookrUtilitiesV2} from "../script/DeployHookrUtilitiesV2.s.sol";
import {HookrLaunchBoostV2} from "../src/HookrLaunchBoostV2.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLaunchpadLib} from "../src/libraries/HookrLaunchpadLib.sol";
import {HookrLockRewardsV2} from "../src/HookrLockRewardsV2.sol";
import {IHookrLockRewardsV2} from "../src/interfaces/IHookrLockRewardsV2.sol";
import {IHookrUtilityToken} from "../src/libraries/HookrTokenTransfer.sol";
import {MockHookrLaunchpad, MockHookrUtilityToken} from "./HookrLockRewardsV1.t.sol";

contract DeployHookrUtilitiesV2Harness is DeployHookrUtilitiesV2 {
    function assertGeneration4Core(address launchpad_) external view {
        _assertGeneration4Core(HookrLaunchpad(payable(launchpad_)));
    }

    function assertProspectiveBootstrapWindow() external view {
        _assertProspectiveBootstrapWindow();
    }
}

contract V3IdentityLaunchpadV2Mock {
    function contractName() external pure returns (string memory) {
        return "HookrLaunchpad";
    }

    function contractVersion() external pure returns (string memory) {
        return "1.0.0";
    }
}

contract CanonicalV4CoreV2Mock {
    address internal constant EXPECTED_DEPLOYER = 0x5a52D4B820Ae7F02880d270562950918ACb14aA2;
    bytes32 internal constant CORE_CANARY_INTENT = keccak256("hookr.v4.canary.instant.all-five.1");
    address internal constant LAUNCH_TOKEN = address(0xF15);
    uint160 internal constant OPEN_SQRT_PRICE_X96 = 123456789;

    bool internal malformed;
    bool internal badPreview;

    function setMalformed(bool value) external {
        malformed = value;
    }

    function setBadPreview(bool value) external {
        badPreview = value;
    }

    function contractName() external pure returns (string memory) {
        return "HookrLaunchpad";
    }

    function contractVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function previewInstantLaunch(uint256, uint16) external view returns (uint256, uint96, uint160, uint256, uint8) {
        uint256 tokensInPool = badPreview ? 499_999_999 ether : 500_000_000 ether;
        return (tokensInPool, 20_000_000, OPEN_SQRT_PRICE_X96, 0.02 ether, 0);
    }

    function launchedByIntent(address creator, bytes32 intentId) external pure returns (address) {
        if (creator == EXPECTED_DEPLOYER && intentId == CORE_CANARY_INTENT) return LAUNCH_TOKEN;
        return address(0);
    }

    function getLaunch(address token) external view returns (HookrLaunchpad.Launch memory launch) {
        launch.token = token;
        launch.creator = EXPECTED_DEPLOYER;
        launch.launchBlock = 123;
        launch.blueprintId = 0;
        launch.graduated = !malformed;
        launch.basePriceWei = 20_000_000;
        launch.targetWei = 0.01 ether;
        launch.graduatedAtBlock = 123;
        launch.sqrtPriceX96AtGraduation = OPEN_SQRT_PRICE_X96;
        launch.poolId = PoolId.wrap(bytes32(uint256(1)));
        launch.hookParams = HookrLaunchpadLib.HookParams({
            guardBlocks: 200,
            maxBuyBps: 1000,
            snipeTaxPips: 200_000,
            baseFeePips: 3000,
            maxFeePips: 30_000,
            surgeSens: 5,
            burnBps: 100,
            burnTriggerWei: 0,
            lpBps: 25,
            potBps: 50,
            potEveryNBuys: 10,
            potMinBuyWei: 0.001 ether,
            buybackBps: 0,
            buybackDrawdownBps: 0,
            buybackCooldownBlocks: 0,
            buybackMinSpendWei: 0,
            buybackMaxSpendWei: 0
        });
    }
}

contract MockHookrV2Launchpad is MockHookrLaunchpad {
    function setCanonicalInstantLaunch(address token, address creator) external {
        HookrLaunchpad.Launch storage launch = launches[token];
        launch.token = token;
        launch.creator = creator;
        launch.launchBlock = uint40(block.number);
        launch.graduated = true;
        launch.graduatedAtBlock = uint40(block.number);
        launch.poolId = PoolId.wrap(bytes32(uint256(uint160(token))));
    }
}

contract CapacityHookrLaunchBoostV2 is HookrLaunchBoostV2 {
    constructor(IHookrUtilityToken hookrToken_, HookrLaunchpad launchpad_, IHookrLockRewardsV2 lockRewards_)
        HookrLaunchBoostV2(hookrToken_, launchpad_, lockRewards_)
    {}

    function fillCapacity() external {
        require(boostedTokens.length == 0, "registry already used");
        for (uint256 i; i < MAX_ACTIVE_BOOSTS; ++i) {
            boostedTokens.push(address(1));
        }
    }
}

contract HookrUtilityV2CanaryScriptsTest is Test {
    address internal constant EXPECTED_DEPLOYER = 0x5a52D4B820Ae7F02880d270562950918ACb14aA2;
    address internal constant HOOKR_TOKEN = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;
    bytes32 internal constant CORE_CANARY_INTENT = keccak256("hookr.v4.canary.instant.all-five.1");

    MockHookrUtilityToken internal token;
    MockHookrV2Launchpad internal launchpad;
    HookrLockRewardsV2 internal rewards;
    HookrLaunchBoostV2 internal boost;
    address internal launchToken = address(0xF15);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal ambientCreator = address(0xCAFE);
    address internal ambientLaunchToken = address(0xB0057);

    function setUp() public {
        vm.chainId(31337);
        vm.warp(1_800_000_000);

        MockHookrUtilityToken tokenTemplate = new MockHookrUtilityToken();
        vm.etch(HOOKR_TOKEN, address(tokenTemplate).code);
        token = MockHookrUtilityToken(HOOKR_TOKEN);
        launchpad = new MockHookrV2Launchpad();
        rewards = new HookrLockRewardsV2(IHookrUtilityToken(HOOKR_TOKEN), address(this));
        boost = new CapacityHookrLaunchBoostV2(
            IHookrUtilityToken(HOOKR_TOKEN),
            HookrLaunchpad(payable(address(launchpad))),
            IHookrLockRewardsV2(address(rewards))
        );
        rewards.setRewardSourceOnce(address(boost));

        launchpad.setCanonicalInstantLaunch(launchToken, EXPECTED_DEPLOYER);
        launchpad.setIntent(EXPECTED_DEPLOYER, CORE_CANARY_INTENT, launchToken);
        token.mint(EXPECTED_DEPLOYER, 101 ether);

        vm.setEnv("HOOKR_UTILITY_V2_REHEARSAL", "true");
        vm.setEnv("HOOKR_UTILITY_V2_TOKEN_RUNTIME_CODEHASH", vm.toString(HOOKR_TOKEN.codehash));
        vm.setEnv("HOOKR_UTILITY_V2_LOCK_REWARDS_ADDRESS", vm.toString(address(rewards)));
        vm.setEnv("HOOKR_UTILITY_V2_LOCK_REWARDS_RUNTIME_CODEHASH", vm.toString(address(rewards).codehash));
        vm.setEnv("HOOKR_UTILITY_V2_LAUNCH_BOOST_ADDRESS", vm.toString(address(boost)));
        vm.setEnv("HOOKR_UTILITY_V2_LAUNCH_BOOST_RUNTIME_CODEHASH", vm.toString(address(boost).codehash));
        vm.setEnv("HOOKR_UTILITY_V2_LAUNCHPAD_ADDRESS", vm.toString(address(launchpad)));
        vm.setEnv("HOOKR_UTILITY_V2_LAUNCHPAD_RUNTIME_CODEHASH", vm.toString(address(launchpad).codehash));
    }

    function test_bootstrapBoundariesAreDeterministicAndBoostingCannotOpenEarly() public {
        assertEq(rewards.bootstrapStartedAt(), 1_800_000_000);
        assertEq(rewards.feeEpochStartsAt(), 1_800_000_000 + 2 hours);
        assertEq(rewards.claimEpochStartsAt(), 1_800_000_000 + 4 hours);
        assertEq(rewards.epochStart(0), rewards.bootstrapStartedAt());
        assertEq(rewards.epochStart(1), rewards.feeEpochStartsAt());
        assertEq(rewards.epochStart(2), rewards.claimEpochStartsAt());
        assertEq(rewards.epochStart(3), rewards.weeklyEpochsStartAt());
        assertGt(rewards.weeklyEpochsStartAt(), rewards.claimEpochStartsAt());
        assertEq(boost.boostingOpensAt(), rewards.feeEpochStartsAt());
        assertFalse(boost.boostingOpen());

        token.approve(address(boost), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV2.BoostingNotOpen.selector, rewards.feeEpochStartsAt()));
        boost.boost(launchToken, 100 ether, 0, 1 ether, 99 ether, block.timestamp + 10 minutes);
        assertEq(token.balanceOf(address(boost)), 0, "pre-open rejection must precede token pull");
    }

    function test_stagedScriptsAreExactAndCannotReplay() public {
        CanaryHookrUtilitiesV2Lock lockStage = new CanaryHookrUtilitiesV2Lock();
        lockStage.run();

        uint256 positionId = _deployerPositionId();
        HookrLockRewardsV2.Position memory lockPosition = rewards.position(positionId);
        assertEq(lockPosition.owner, EXPECTED_DEPLOYER);
        assertEq(lockPosition.principal, 1 ether);
        assertEq(lockPosition.activationEpoch, 1);
        assertEq(token.allowance(EXPECTED_DEPLOYER, address(rewards)), 0);
        vm.expectRevert(bytes("lock stage already started"));
        lockStage.run();

        vm.warp(rewards.feeEpochStartsAt());
        CanaryHookrUtilitiesV2Boost boostStage = new CanaryHookrUtilitiesV2Boost();
        boostStage.run();

        HookrLaunchBoostV2.BoostPosition memory boostPosition = boost.boostOf(launchToken);
        assertEq(boostPosition.creator, EXPECTED_DEPLOYER);
        assertEq(boostPosition.principal, 99 ether);
        assertEq(boost.boostedTokensCount(), 1);
        assertEq(boost.boostedTokenIndexPlusOne(launchToken), 1);
        assertTrue(boost.isBoostRegistered(launchToken));
        assertEq(rewards.rewardReserve(), 1 ether);
        assertEq(token.allowance(EXPECTED_DEPLOYER, address(boost)), 0);
        vm.expectRevert();
        boostStage.run();

        vm.warp(rewards.claimEpochStartsAt());
        CanaryHookrUtilitiesV2Claim claimStage = new CanaryHookrUtilitiesV2Claim();
        uint256 before = token.balanceOf(EXPECTED_DEPLOYER);
        claimStage.run();
        assertEq(token.balanceOf(EXPECTED_DEPLOYER) - before, 1 ether);
        assertEq(rewards.rewardReserve(), 0);
        assertEq(rewards.roundingCarry(), 0);
        vm.expectRevert();
        claimStage.run();
    }

    function test_stagedScriptsTolerateAmbientLocksBoostsAndClaims() public {
        _lockAs(alice, 2 ether);

        CanaryHookrUtilitiesV2Lock lockStage = new CanaryHookrUtilitiesV2Lock();
        lockStage.run();
        _lockAs(bob, 3 ether);

        uint256 positionId = _deployerPositionId();
        assertGt(positionId, 1, "canary position must not rely on global id one");
        HookrLockRewardsV2.Position memory lockPosition = rewards.position(positionId);

        vm.warp(rewards.feeEpochStartsAt());
        launchpad.setLaunch(ambientLaunchToken, ambientCreator);
        token.mint(ambientCreator, 100 ether);
        vm.startPrank(ambientCreator);
        token.approve(address(boost), 100 ether);
        boost.boost(ambientLaunchToken, 100 ether, 0, 1 ether, 99 ether, block.timestamp + 10 minutes);
        vm.stopPrank();

        CanaryHookrUtilitiesV2Boost boostStage = new CanaryHookrUtilitiesV2Boost();
        boostStage.run();
        assertEq(boost.boostedTokensCount(), 2, "ambient boost must remain registered");
        assertGt(boost.boostedTokenIndexPlusOne(launchToken), 1, "canary boost must not rely on registry index one");
        assertEq(rewards.rewardReserve(), 2 ether, "both receipt-local fees must be retained");

        vm.warp(rewards.claimEpochStartsAt());
        uint256 alicePositionId = rewards.positionsOf(alice, 0, 1)[0];
        vm.prank(alice);
        uint256 aliceReward = rewards.claim(alicePositionId, alice);
        assertGt(aliceReward, 0, "ambient claimant must consume its pro-rata reward first");
        uint256 claimedBefore = rewards.cumulativeRewardsClaimed();
        uint256 reserveBefore = rewards.rewardReserve();

        uint256 startIndex = rewards.rewardIndexAtEpoch(lockPosition.activationEpoch);
        uint256 endIndex = rewards.rewardIndexAtEpoch(2);
        uint256 expectedReward = FullMath.mulDiv(lockPosition.weight, endIndex - startIndex, 1 << 128);
        assertGt(expectedReward, 0, "canary pro-rata reward must be nonzero");
        assertNotEq(expectedReward, 1 ether, "ambient weight must change the canary reward");

        CanaryHookrUtilitiesV2Claim claimStage = new CanaryHookrUtilitiesV2Claim();
        uint256 balanceBefore = token.balanceOf(EXPECTED_DEPLOYER);
        claimStage.run();
        assertEq(token.balanceOf(EXPECTED_DEPLOYER) - balanceBefore, expectedReward);
        assertEq(rewards.cumulativeRewardsClaimed(), claimedBefore + expectedReward);
        assertEq(rewards.rewardReserve() + expectedReward, reserveBefore);
    }

    function test_stageWindowsRequireFortyFiveMinutesRemaining() public {
        CanaryHookrUtilitiesV2Lock lockStage = new CanaryHookrUtilitiesV2Lock();
        vm.warp(uint256(rewards.feeEpochStartsAt()) - 45 minutes + 1);
        vm.expectRevert(bytes("less than 45 minutes remain"));
        lockStage.run();
        assertEq(rewards.positionsOfCount(EXPECTED_DEPLOYER), 0);

        vm.warp(rewards.bootstrapStartedAt());
        lockStage.run();
        vm.warp(uint256(rewards.claimEpochStartsAt()) - 45 minutes + 1);
        CanaryHookrUtilitiesV2Boost boostStage = new CanaryHookrUtilitiesV2Boost();
        vm.expectRevert(bytes("less than 45 minutes remain"));
        boostStage.run();
        assertEq(boost.boostOf(launchToken).principal, 0);

        vm.warp(rewards.feeEpochStartsAt());
        boostStage.run();
        vm.warp(uint256(rewards.weeklyEpochsStartAt()) - 45 minutes + 1);
        CanaryHookrUtilitiesV2Claim claimStage = new CanaryHookrUtilitiesV2Claim();
        vm.expectRevert(bytes("less than 45 minutes remain"));
        claimStage.run();
    }

    function test_stageTwoRejectsFullRegistryBeforeApproval() public {
        CanaryHookrUtilitiesV2Lock lockStage = new CanaryHookrUtilitiesV2Lock();
        lockStage.run();
        CapacityHookrLaunchBoostV2(address(boost)).fillCapacity();
        vm.warp(rewards.feeEpochStartsAt());

        assertEq(boost.boostedTokensCount(), boost.MAX_ACTIVE_BOOSTS());
        assertEq(token.allowance(EXPECTED_DEPLOYER, address(boost)), 0);
        CanaryHookrUtilitiesV2Boost boostStage = new CanaryHookrUtilitiesV2Boost();
        vm.expectRevert(bytes("boost registry full"));
        boostStage.run();
        assertEq(token.allowance(EXPECTED_DEPLOYER, address(boost)), 0, "capacity guard must precede approval");
        assertEq(token.balanceOf(EXPECTED_DEPLOYER), 100 ether, "capacity guard must precede token pull");
    }

    function test_claimRemainsValidAfterFirstTwoHoursOfBridge() public {
        CanaryHookrUtilitiesV2Lock lockStage = new CanaryHookrUtilitiesV2Lock();
        lockStage.run();
        vm.warp(rewards.feeEpochStartsAt());
        CanaryHookrUtilitiesV2Boost boostStage = new CanaryHookrUtilitiesV2Boost();
        boostStage.run();

        uint256 lateBridgeTimestamp = uint256(rewards.claimEpochStartsAt()) + 3 hours;
        assertLt(lateBridgeTimestamp + 45 minutes, rewards.weeklyEpochsStartAt());
        vm.warp(lateBridgeTimestamp);
        CanaryHookrUtilitiesV2Claim claimStage = new CanaryHookrUtilitiesV2Claim();
        claimStage.run();
        assertEq(rewards.position(_deployerPositionId()).lastClaimEpoch, 2);
    }

    function test_deployCoreProbeAndProspectiveClaimBridgeGuards() public {
        DeployHookrUtilitiesV2Harness harness = new DeployHookrUtilitiesV2Harness();
        CanonicalV4CoreV2Mock v4 = new CanonicalV4CoreV2Mock();
        harness.assertGeneration4Core(address(v4));

        V3IdentityLaunchpadV2Mock v3 = new V3IdentityLaunchpadV2Mock();
        vm.expectRevert();
        harness.assertGeneration4Core(address(v3));

        v4.setBadPreview(true);
        vm.expectRevert(bytes("v4 instant pool supply wrong"));
        harness.assertGeneration4Core(address(v4));
        v4.setBadPreview(false);

        v4.setMalformed(true);
        vm.expectRevert(bytes("v4 core canary not live"));
        harness.assertGeneration4Core(address(v4));

        uint256 nextMonday = 4 days + ((block.timestamp - 4 days) / 7 days + 1) * 7 days;
        vm.warp(nextMonday - 4 hours - 45 minutes);
        harness.assertProspectiveBootstrapWindow();
        vm.warp(nextMonday - 4 hours - 45 minutes + 1);
        vm.expectRevert(bytes("claim bridge below 45 minutes"));
        harness.assertProspectiveBootstrapWindow();
    }

    function _lockAs(address owner, uint256 amount) internal returns (uint256 positionId) {
        token.mint(owner, amount);
        (, uint32 activationEpoch,, uint40 unlockAt,) = rewards.previewLock(amount, 0);
        vm.startPrank(owner);
        token.approve(address(rewards), amount);
        positionId = rewards.lock(amount, 0, activationEpoch, unlockAt, block.timestamp + 10 minutes);
        vm.stopPrank();
    }

    function _deployerPositionId() internal view returns (uint256) {
        uint256[] memory ids = rewards.positionsOf(EXPECTED_DEPLOYER, 0, 2);
        assertEq(ids.length, 1);
        assertGt(ids[0], 0);
        return ids[0];
    }
}
