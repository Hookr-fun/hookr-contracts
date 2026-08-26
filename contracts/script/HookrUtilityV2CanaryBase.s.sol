// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";

import {HookrLaunchBoostV2} from "../src/HookrLaunchBoostV2.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLockRewardsV2} from "../src/HookrLockRewardsV2.sol";
import {IHookrUtilityToken} from "../src/libraries/HookrTokenTransfer.sol";

interface IHookrV2CanaryToken is IHookrUtilityToken {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Shared fail-closed identity, bootstrap-boundary and promoted-core linkage checks for the
///      three separately broadcast V2 canary stages.
abstract contract HookrUtilityV2CanaryBase is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant LOCAL_REHEARSAL_CHAIN_ID = 31337;
    uint256 internal constant CANARY_LOCK_GROSS = 1 ether;
    uint256 internal constant CANARY_BOOST_GROSS = 100 ether;
    uint256 internal constant CANARY_FEE = 1 ether;
    uint256 internal constant CANARY_PRINCIPAL = 99 ether;
    uint256 internal constant CANARY_DEADLINE_WINDOW = 10 minutes;
    uint256 internal constant CANARY_MIN_STAGE_REMAINING = 45 minutes;
    uint8 internal constant CANARY_TIER = 0;
    bytes32 internal constant CORE_CANARY_INTENT = keccak256("hookr.v4.canary.instant.all-five.1");

    address internal constant EXPECTED_DEPLOYER = 0x5a52D4B820Ae7F02880d270562950918ACb14aA2;
    address internal constant HOOKR_TOKEN = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;
    bytes32 internal constant REVIEWED_HOOKR_RUNTIME_CODEHASH =
        0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d;

    struct UtilityContracts {
        IHookrV2CanaryToken token;
        HookrLockRewardsV2 rewards;
        HookrLaunchBoostV2 boost;
        HookrLaunchpad launchpad;
    }

    function _loadUtilityContracts() internal view returns (UtilityContracts memory u) {
        bool rehearsal = block.chainid == LOCAL_REHEARSAL_CHAIN_ID && vm.envOr("HOOKR_UTILITY_V2_REHEARSAL", false);
        require(block.chainid == ROBINHOOD_CHAIN_ID || rehearsal, "wrong chain or rehearsal mode");

        u.token = IHookrV2CanaryToken(HOOKR_TOKEN);
        u.rewards = HookrLockRewardsV2(vm.envAddress("HOOKR_UTILITY_V2_LOCK_REWARDS_ADDRESS"));
        u.boost = HookrLaunchBoostV2(vm.envAddress("HOOKR_UTILITY_V2_LAUNCH_BOOST_ADDRESS"));
        u.launchpad = HookrLaunchpad(payable(vm.envAddress("HOOKR_UTILITY_V2_LAUNCHPAD_ADDRESS")));

        bytes32 expectedRewardsHash = vm.envBytes32("HOOKR_UTILITY_V2_LOCK_REWARDS_RUNTIME_CODEHASH");
        bytes32 expectedBoostHash = vm.envBytes32("HOOKR_UTILITY_V2_LAUNCH_BOOST_RUNTIME_CODEHASH");
        bytes32 expectedLaunchpadHash = vm.envBytes32("HOOKR_UTILITY_V2_LAUNCHPAD_RUNTIME_CODEHASH");
        require(
            expectedRewardsHash != bytes32(0) && expectedBoostHash != bytes32(0) && expectedLaunchpadHash != bytes32(0),
            "runtime hash missing"
        );
        require(address(u.rewards).codehash == expectedRewardsHash, "LockRewards runtime wrong");
        require(address(u.boost).codehash == expectedBoostHash, "LaunchBoost runtime wrong");
        require(address(u.launchpad).codehash == expectedLaunchpadHash, "launchpad runtime wrong");

        if (rehearsal) {
            bytes32 rehearsalTokenHash = vm.envBytes32("HOOKR_UTILITY_V2_TOKEN_RUNTIME_CODEHASH");
            require(
                rehearsalTokenHash != bytes32(0) && HOOKR_TOKEN.codehash == rehearsalTokenHash, "token runtime wrong"
            );
        } else {
            require(HOOKR_TOKEN.codehash == REVIEWED_HOOKR_RUNTIME_CODEHASH, "HOOKR runtime wrong");
            require(
                keccak256(bytes(u.launchpad.contractName())) == keccak256(bytes("HookrLaunchpad")),
                "launchpad identity wrong"
            );
            require(
                keccak256(bytes(u.launchpad.contractVersion())) == keccak256(bytes("1.0.0")), "launchpad version wrong"
            );
        }

        require(
            keccak256(bytes(u.rewards.contractName())) == keccak256(bytes("HookrLockRewards")),
            "LockRewards identity wrong"
        );
        require(keccak256(bytes(u.rewards.contractVersion())) == keccak256(bytes("2")), "LockRewards version wrong");
        require(
            keccak256(bytes(u.boost.contractName())) == keccak256(bytes("HookrLaunchBoost")),
            "LaunchBoost identity wrong"
        );
        require(keccak256(bytes(u.boost.contractVersion())) == keccak256(bytes("2")), "LaunchBoost version wrong");
        require(address(u.rewards.hookrToken()) == HOOKR_TOKEN, "LockRewards token wrong");
        require(address(u.boost.hookrToken()) == HOOKR_TOKEN, "LaunchBoost token wrong");
        require(address(u.boost.lockRewards()) == address(u.rewards), "LaunchBoost rewards wrong");
        require(address(u.boost.launchpad()) == address(u.launchpad), "LaunchBoost launchpad wrong");
        require(u.boost.MIN_GROSS_BOOST() == CANARY_BOOST_GROSS, "LaunchBoost minimum wrong");
        require(u.boost.MAX_ACTIVE_BOOSTS() == 512, "LaunchBoost capacity wrong");
        require(u.rewards.rewardSource() == address(u.boost), "reward source wrong");
        require(u.rewards.configurator() == address(0), "configurator not burned");
        require(u.rewards.BOOTSTRAP_EPOCH_LENGTH() == 2 hours, "bootstrap epoch length wrong");
        require(u.rewards.FIRST_WEEKLY_EPOCH() == 3, "first weekly epoch wrong");
        _assertBootstrapBoundaries(u.rewards);
        require(u.boost.boostingOpensAt() == u.rewards.feeEpochStartsAt(), "boost opening boundary wrong");
        require(
            u.boost.boostingOpen() == (block.timestamp >= u.rewards.feeEpochStartsAt()), "boost opening state wrong"
        );
    }

    function _assertBootstrapBoundaries(HookrLockRewardsV2 rewards) internal view {
        uint40 startedAt = rewards.bootstrapStartedAt();
        uint40 feeStart = rewards.feeEpochStartsAt();
        uint40 claimStart = rewards.claimEpochStartsAt();
        uint40 weeklyStart = rewards.weeklyEpochsStartAt();
        require(feeStart == startedAt + 2 hours, "fee boundary wrong");
        require(claimStart == feeStart + 2 hours, "claim boundary wrong");
        uint256 weeklyNumber = (uint256(claimStart) - 4 days) / 7 days + 1;
        require(weeklyStart == 4 days + weeklyNumber * 7 days, "weekly boundary wrong");
        require(rewards.epochStart(0) == startedAt, "epoch zero boundary wrong");
        require(rewards.epochStart(1) == feeStart, "epoch one boundary wrong");
        require(rewards.epochStart(2) == claimStart, "epoch two boundary wrong");
        require(rewards.epochStart(3) == weeklyStart, "epoch three boundary wrong");
    }

    function _requireStageRemaining(uint40 boundary) internal view {
        require(uint256(boundary) >= block.timestamp + CANARY_MIN_STAGE_REMAINING, "less than 45 minutes remain");
    }

    function _canaryPosition(HookrLockRewardsV2 rewards)
        internal
        view
        returns (uint256 positionId, HookrLockRewardsV2.Position memory p)
    {
        require(rewards.positionsOfCount(EXPECTED_DEPLOYER) == 1, "canary owner position missing");
        uint256[] memory ids = rewards.positionsOf(EXPECTED_DEPLOYER, 0, 2);
        require(ids.length == 1 && ids[0] != 0, "canary position id wrong");
        positionId = ids[0];
        p = rewards.position(positionId);
        require(p.owner == EXPECTED_DEPLOYER, "canary position owner wrong");
        require(p.principal == CANARY_LOCK_GROSS && p.weight == CANARY_LOCK_GROSS, "canary lock amount wrong");
        require(p.activationEpoch == 1, "canary activation epoch wrong");
        require(p.tier == CANARY_TIER && !p.withdrawn, "canary lock state wrong");
    }

    function _canonicalLaunchToken(HookrLaunchpad launchpad) internal view returns (address token) {
        token = launchpad.launchedByIntent(EXPECTED_DEPLOYER, CORE_CANARY_INTENT);
        require(token != address(0), "core canary token missing");
        HookrLaunchpad.Launch memory launch = launchpad.getLaunch(token);
        require(launch.token == token, "core canary launch mismatch");
        require(launch.creator == EXPECTED_DEPLOYER, "core canary creator wrong");
        require(launch.graduated && launch.graduatedAtBlock == launch.launchBlock, "core canary not instant");
    }
}
