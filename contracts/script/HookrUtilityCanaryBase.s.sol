// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";

import {HookrLaunchBoostV1} from "../src/HookrLaunchBoostV1.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLockRewardsV1} from "../src/HookrLockRewardsV1.sol";
import {IHookrUtilityToken} from "../src/libraries/HookrTokenTransfer.sol";

interface IHookrCanaryToken is IHookrUtilityToken {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Shared fail-closed identity and linkage checks for the three separately broadcast stages.
///      A local rehearsal is allowed only on chain 31337 with an explicit opt-in and exact runtime
///      hashes. Production always requires chain 4663 and the reviewed HOOKR runtime.
abstract contract HookrUtilityCanaryBase is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant LOCAL_REHEARSAL_CHAIN_ID = 31337;
    uint256 internal constant CANARY_LOCK_GROSS = 1 ether;
    uint256 internal constant CANARY_BOOST_GROSS = 100 ether;
    uint256 internal constant CANARY_FEE = 1 ether;
    uint256 internal constant CANARY_PRINCIPAL = 99 ether;
    uint256 internal constant CANARY_DEADLINE_WINDOW = 10 minutes;
    uint256 internal constant CANARY_MIN_EPOCH_WINDOW = 15 minutes;
    uint8 internal constant CANARY_TIER = 0;
    bytes32 internal constant CORE_CANARY_INTENT = keccak256("hookr.v4.canary.instant.all-five.1");

    address internal constant EXPECTED_DEPLOYER = 0x5a52D4B820Ae7F02880d270562950918ACb14aA2;
    address internal constant HOOKR_TOKEN = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;
    bytes32 internal constant REVIEWED_HOOKR_RUNTIME_CODEHASH =
        0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d;

    struct UtilityContracts {
        IHookrCanaryToken token;
        HookrLockRewardsV1 rewards;
        HookrLaunchBoostV1 boost;
        HookrLaunchpad launchpad;
    }

    function _loadUtilityContracts() internal view returns (UtilityContracts memory u) {
        bool rehearsal = block.chainid == LOCAL_REHEARSAL_CHAIN_ID && vm.envOr("HOOKR_UTILITY_REHEARSAL", false);
        require(block.chainid == ROBINHOOD_CHAIN_ID || rehearsal, "wrong chain or rehearsal mode");

        u.token = IHookrCanaryToken(HOOKR_TOKEN);
        u.rewards = HookrLockRewardsV1(vm.envAddress("HOOKR_UTILITY_LOCK_REWARDS_ADDRESS"));
        u.boost = HookrLaunchBoostV1(vm.envAddress("HOOKR_UTILITY_LAUNCH_BOOST_ADDRESS"));
        u.launchpad = HookrLaunchpad(payable(vm.envAddress("HOOKR_UTILITY_LAUNCHPAD_ADDRESS")));

        bytes32 expectedRewardsHash = vm.envBytes32("HOOKR_UTILITY_LOCK_REWARDS_RUNTIME_CODEHASH");
        bytes32 expectedBoostHash = vm.envBytes32("HOOKR_UTILITY_LAUNCH_BOOST_RUNTIME_CODEHASH");
        bytes32 expectedLaunchpadHash = vm.envBytes32("HOOKR_UTILITY_LAUNCHPAD_RUNTIME_CODEHASH");
        require(
            expectedRewardsHash != bytes32(0) && expectedBoostHash != bytes32(0) && expectedLaunchpadHash != bytes32(0),
            "runtime hash missing"
        );
        require(address(u.rewards).codehash == expectedRewardsHash, "LockRewards runtime wrong");
        require(address(u.boost).codehash == expectedBoostHash, "LaunchBoost runtime wrong");
        require(address(u.launchpad).codehash == expectedLaunchpadHash, "launchpad runtime wrong");

        if (rehearsal) {
            bytes32 rehearsalTokenHash = vm.envBytes32("HOOKR_UTILITY_TOKEN_RUNTIME_CODEHASH");
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
        require(keccak256(bytes(u.rewards.contractVersion())) == keccak256(bytes("1")), "LockRewards version wrong");
        require(
            keccak256(bytes(u.boost.contractName())) == keccak256(bytes("HookrLaunchBoost")),
            "LaunchBoost identity wrong"
        );
        require(keccak256(bytes(u.boost.contractVersion())) == keccak256(bytes("1")), "LaunchBoost version wrong");
        require(address(u.rewards.hookrToken()) == HOOKR_TOKEN, "LockRewards token wrong");
        require(address(u.boost.hookrToken()) == HOOKR_TOKEN, "LaunchBoost token wrong");
        require(address(u.boost.lockRewards()) == address(u.rewards), "LaunchBoost rewards wrong");
        require(address(u.boost.launchpad()) == address(u.launchpad), "LaunchBoost launchpad wrong");
        require(u.boost.MIN_GROSS_BOOST() == CANARY_BOOST_GROSS, "LaunchBoost minimum wrong");
        require(u.boost.MAX_ACTIVE_BOOSTS() == 512, "LaunchBoost capacity wrong");
        require(u.rewards.rewardSource() == address(u.boost), "reward source wrong");
        require(u.rewards.configurator() == address(0), "configurator not burned");
    }

    function _canaryPosition(HookrLockRewardsV1 rewards)
        internal
        view
        returns (uint256 positionId, HookrLockRewardsV1.Position memory p)
    {
        require(rewards.positionsOfCount(EXPECTED_DEPLOYER) == 1, "canary owner position missing");
        uint256[] memory ids = rewards.positionsOf(EXPECTED_DEPLOYER, 0, 2);
        require(ids.length == 1 && ids[0] != 0, "canary position id wrong");
        positionId = ids[0];
        p = rewards.position(positionId);
        require(p.owner == EXPECTED_DEPLOYER, "canary position owner wrong");
        require(p.principal == CANARY_LOCK_GROSS && p.weight == CANARY_LOCK_GROSS, "canary lock amount wrong");
        require(p.tier == CANARY_TIER && !p.withdrawn, "canary lock state wrong");
    }

    function _requireCanaryEpochWindow(HookrLockRewardsV1 rewards) internal view {
        uint40 nextEpochStart = rewards.epochStart(rewards.currentEpoch() + 1);
        require(block.timestamp + CANARY_MIN_EPOCH_WINDOW < nextEpochStart, "too close to epoch boundary");
    }

    function _canonicalLaunchToken(HookrLaunchpad launchpad) internal view returns (address token) {
        token = launchpad.launchedByIntent(EXPECTED_DEPLOYER, CORE_CANARY_INTENT);
        require(token != address(0), "core canary token missing");
        HookrLaunchpad.Launch memory launch = launchpad.getLaunch(token);
        require(launch.token == token, "core canary launch mismatch");
        require(launch.creator == EXPECTED_DEPLOYER, "core canary creator wrong");
    }
}
