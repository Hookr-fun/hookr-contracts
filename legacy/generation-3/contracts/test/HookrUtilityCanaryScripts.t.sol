// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {CanaryHookrUtilitiesBoost} from "../script/CanaryHookrUtilitiesBoost.s.sol";
import {CanaryHookrUtilitiesClaim} from "../script/CanaryHookrUtilitiesClaim.s.sol";
import {CanaryHookrUtilitiesLock} from "../script/CanaryHookrUtilitiesLock.s.sol";
import {DeployHookrUtilities} from "../script/DeployHookrUtilities.s.sol";
import {HookrLaunchBoostV1} from "../src/HookrLaunchBoostV1.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLaunchpadLib} from "../src/libraries/HookrLaunchpadLib.sol";
import {HookrLockRewardsV1} from "../src/HookrLockRewardsV1.sol";
import {IHookrLockRewardsV1} from "../src/interfaces/IHookrLockRewardsV1.sol";
import {IHookrUtilityToken} from "../src/libraries/HookrTokenTransfer.sol";
import {MockHookrLaunchpad, MockHookrUtilityToken} from "./HookrLockRewardsV1.t.sol";

contract DeployHookrUtilitiesHarness is DeployHookrUtilities {
    function assertGeneration4Core(address launchpad_) external view {
        _assertGeneration4Core(HookrLaunchpad(payable(launchpad_)));
    }
}

contract V3IdentityLaunchpadMock {
    function contractName() external pure returns (string memory) {
        return "HookrLaunchpad";
    }

    function contractVersion() external pure returns (string memory) {
        return "1.0.0";
    }
}

contract CanonicalV4CoreMock {
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

contract HookrUtilityCanaryScriptsTest is Test {
    address internal constant EXPECTED_DEPLOYER = 0x5a52D4B820Ae7F02880d270562950918ACb14aA2;
    address internal constant HOOKR_TOKEN = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;
    bytes32 internal constant CORE_CANARY_INTENT = keccak256("hookr.v4.canary.instant.all-five.1");

    MockHookrUtilityToken internal token;
    MockHookrLaunchpad internal launchpad;
    HookrLockRewardsV1 internal rewards;
    HookrLaunchBoostV1 internal boost;
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
        launchpad = new MockHookrLaunchpad();
        rewards = new HookrLockRewardsV1(IHookrUtilityToken(HOOKR_TOKEN), address(this));
        boost = new HookrLaunchBoostV1(
            IHookrUtilityToken(HOOKR_TOKEN),
            HookrLaunchpad(payable(address(launchpad))),
            IHookrLockRewardsV1(address(rewards))
        );
        rewards.setRewardSourceOnce(address(boost));

        launchpad.setLaunch(launchToken, EXPECTED_DEPLOYER);
        launchpad.setIntent(EXPECTED_DEPLOYER, CORE_CANARY_INTENT, launchToken);
        token.mint(EXPECTED_DEPLOYER, 101 ether);

        vm.setEnv("HOOKR_UTILITY_REHEARSAL", "true");
        vm.setEnv("HOOKR_UTILITY_TOKEN_RUNTIME_CODEHASH", vm.toString(HOOKR_TOKEN.codehash));
        vm.setEnv("HOOKR_UTILITY_LOCK_REWARDS_ADDRESS", vm.toString(address(rewards)));
        vm.setEnv("HOOKR_UTILITY_LOCK_REWARDS_RUNTIME_CODEHASH", vm.toString(address(rewards).codehash));
        vm.setEnv("HOOKR_UTILITY_LAUNCH_BOOST_ADDRESS", vm.toString(address(boost)));
        vm.setEnv("HOOKR_UTILITY_LAUNCH_BOOST_RUNTIME_CODEHASH", vm.toString(address(boost).codehash));
        vm.setEnv("HOOKR_UTILITY_LAUNCHPAD_ADDRESS", vm.toString(address(launchpad)));
        vm.setEnv("HOOKR_UTILITY_LAUNCHPAD_RUNTIME_CODEHASH", vm.toString(address(launchpad).codehash));
    }

    function test_stagedScriptsAreExactAndCannotReplay() public {
        CanaryHookrUtilitiesLock lockStage = new CanaryHookrUtilitiesLock();
        lockStage.run();

        uint256 positionId = _deployerPositionId();
        HookrLockRewardsV1.Position memory lockPosition = rewards.position(positionId);
        assertEq(lockPosition.owner, EXPECTED_DEPLOYER);
        assertEq(lockPosition.principal, 1 ether);
        assertEq(token.allowance(EXPECTED_DEPLOYER, address(rewards)), 0);
        vm.expectRevert(bytes("lock stage already started"));
        lockStage.run();

        vm.warp(rewards.epochStart(lockPosition.activationEpoch));
        CanaryHookrUtilitiesBoost boostStage = new CanaryHookrUtilitiesBoost();
        boostStage.run();

        HookrLaunchBoostV1.BoostPosition memory boostPosition = boost.boostOf(launchToken);
        assertEq(boostPosition.creator, EXPECTED_DEPLOYER);
        assertEq(boostPosition.principal, 99 ether);
        assertEq(boost.MAX_ACTIVE_BOOSTS(), 512);
        assertEq(boost.boostedTokensCount(), 1);
        assertEq(boost.boostedTokenIndexPlusOne(launchToken), 1);
        assertTrue(boost.isBoostRegistered(launchToken));
        assertEq(rewards.rewardReserve(), 1 ether);
        assertEq(token.allowance(EXPECTED_DEPLOYER, address(boost)), 0);
        vm.expectRevert();
        boostStage.run();

        vm.warp(rewards.epochStart(lockPosition.activationEpoch + 1));
        CanaryHookrUtilitiesClaim claimStage = new CanaryHookrUtilitiesClaim();
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

        CanaryHookrUtilitiesLock lockStage = new CanaryHookrUtilitiesLock();
        lockStage.run();
        _lockAs(bob, 3 ether);

        uint256 positionId = _deployerPositionId();
        assertGt(positionId, 1, "canary position must not rely on global id one");
        HookrLockRewardsV1.Position memory lockPosition = rewards.position(positionId);

        vm.warp(rewards.epochStart(lockPosition.activationEpoch));
        launchpad.setLaunch(ambientLaunchToken, ambientCreator);
        token.mint(ambientCreator, 100 ether);
        vm.startPrank(ambientCreator);
        token.approve(address(boost), 100 ether);
        boost.boost(ambientLaunchToken, 100 ether, 0, 1 ether, 99 ether, block.timestamp + 10 minutes);
        vm.stopPrank();

        CanaryHookrUtilitiesBoost boostStage = new CanaryHookrUtilitiesBoost();
        boostStage.run();
        assertEq(boost.boostedTokensCount(), 2, "ambient boost must remain registered");
        assertGt(boost.boostedTokenIndexPlusOne(launchToken), 1, "canary boost must not rely on registry index one");
        assertEq(rewards.rewardReserve(), 2 ether, "both receipt-local fees must be retained");

        vm.warp(rewards.epochStart(lockPosition.activationEpoch + 1));
        uint256 alicePositionId = rewards.positionsOf(alice, 0, 1)[0];
        vm.prank(alice);
        uint256 aliceReward = rewards.claim(alicePositionId, alice);
        assertGt(aliceReward, 0, "ambient claimant must consume its pro-rata reward first");
        uint256 claimedBefore = rewards.cumulativeRewardsClaimed();
        uint256 reserveBefore = rewards.rewardReserve();

        uint256 startIndex = rewards.rewardIndexAtEpoch(lockPosition.activationEpoch);
        uint256 endIndex = rewards.rewardIndexAtEpoch(lockPosition.activationEpoch + 1);
        uint256 expectedReward = FullMath.mulDiv(lockPosition.weight, endIndex - startIndex, 1 << 128);
        assertGt(expectedReward, 0, "canary pro-rata reward must be nonzero");
        assertNotEq(expectedReward, 1 ether, "ambient weight must change the canary reward");

        CanaryHookrUtilitiesClaim claimStage = new CanaryHookrUtilitiesClaim();
        uint256 balanceBefore = token.balanceOf(EXPECTED_DEPLOYER);
        claimStage.run();
        assertEq(token.balanceOf(EXPECTED_DEPLOYER) - balanceBefore, expectedReward);
        assertEq(rewards.cumulativeRewardsClaimed(), claimedBefore + expectedReward);
        assertEq(rewards.rewardReserve() + expectedReward, reserveBefore);
    }

    function test_deployCoreProbeAcceptsExactV4AndRejectsV3OrMalformedCanary() public {
        DeployHookrUtilitiesHarness harness = new DeployHookrUtilitiesHarness();
        CanonicalV4CoreMock v4 = new CanonicalV4CoreMock();
        harness.assertGeneration4Core(address(v4));

        V3IdentityLaunchpadMock v3 = new V3IdentityLaunchpadMock();
        vm.expectRevert();
        harness.assertGeneration4Core(address(v3));

        v4.setBadPreview(true);
        vm.expectRevert(bytes("v4 instant pool supply wrong"));
        harness.assertGeneration4Core(address(v4));
        v4.setBadPreview(false);

        v4.setMalformed(true);
        vm.expectRevert(bytes("v4 core canary not live"));
        harness.assertGeneration4Core(address(v4));
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
