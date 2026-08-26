// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HookrLaunchBoostV2} from "../src/HookrLaunchBoostV2.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLockRewardsV2} from "../src/HookrLockRewardsV2.sol";
import {IHookrLockRewardsV2} from "../src/interfaces/IHookrLockRewardsV2.sol";
import {IHookrUtilityToken} from "../src/libraries/HookrTokenTransfer.sol";

/// @notice Independent three-transaction deployment for the bootstrap-enabled V2 $HOOKR utility rail.
/// @dev This script never imports or calls DeployRobinhood and cannot alter the promoted generation-4 core.
contract DeployHookrUtilitiesV2 is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant MAX_RUNTIME_SIZE = 24_576;
    uint256 internal constant MIN_STAGE_REMAINING = 45 minutes;

    address internal constant EXPECTED_DEPLOYER = 0x5a52D4B820Ae7F02880d270562950918ACb14aA2;
    address internal constant HOOKR_TOKEN = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;
    bytes32 internal constant REVIEWED_HOOKR_RUNTIME_CODEHASH =
        0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d;
    bytes32 internal constant CORE_CANARY_INTENT = keccak256("hookr.v4.canary.instant.all-five.1");
    uint256 internal constant CORE_CANARY_DEPOSIT_WEI = 0.01 ether;
    uint16 internal constant CORE_CANARY_POOL_SUPPLY_BPS = 5000;

    function run() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "wrong chain");
        require(HOOKR_TOKEN.codehash == REVIEWED_HOOKR_RUNTIME_CODEHASH, "HOOKR runtime wrong");
        _assertProspectiveBootstrapWindow();

        address launchpadAddress = vm.envAddress("HOOKR_UTILITY_V2_LAUNCHPAD_ADDRESS");
        bytes32 launchpadRuntimeCodehash = vm.envBytes32("HOOKR_UTILITY_V2_LAUNCHPAD_RUNTIME_CODEHASH");
        require(launchpadAddress != address(0) && launchpadAddress.code.length != 0, "launchpad missing");
        require(launchpadRuntimeCodehash != bytes32(0), "launchpad runtime hash missing");
        require(launchpadAddress.codehash == launchpadRuntimeCodehash, "launchpad runtime wrong");

        HookrLaunchpad launchpad = HookrLaunchpad(payable(launchpadAddress));
        require(
            keccak256(bytes(launchpad.contractName())) == keccak256(bytes("HookrLaunchpad")), "launchpad identity wrong"
        );
        require(keccak256(bytes(launchpad.contractVersion())) == keccak256(bytes("1.0.0")), "launchpad version wrong");
        _assertGeneration4Core(launchpad);

        console2.log("utility V2 deployer", EXPECTED_DEPLOYER);
        console2.log("supported launchpad", launchpadAddress);
        console2.log("deployer balance", EXPECTED_DEPLOYER.balance);

        // Address-based broadcast keeps the no-broadcast simulation secret-free. A real broadcast
        // must still select the separately reviewed signer for EXPECTED_DEPLOYER explicitly.
        vm.startBroadcast(EXPECTED_DEPLOYER);
        HookrLockRewardsV2 rewards = new HookrLockRewardsV2(IHookrUtilityToken(HOOKR_TOKEN), EXPECTED_DEPLOYER);
        HookrLaunchBoostV2 boost =
            new HookrLaunchBoostV2(IHookrUtilityToken(HOOKR_TOKEN), launchpad, IHookrLockRewardsV2(address(rewards)));
        rewards.setRewardSourceOnce(address(boost));
        vm.stopBroadcast();

        _assertReadbacks(rewards, boost, launchpadAddress);

        console2.log("HookrLockRewardsV2", address(rewards));
        console2.log("HookrLaunchBoostV2", address(boost));
        console2.log("bootstrap started", rewards.bootstrapStartedAt());
        console2.log("fee epoch starts", rewards.feeEpochStartsAt());
        console2.log("claim epoch starts", rewards.claimEpochStartsAt());
        console2.log("weekly epochs start", rewards.weeklyEpochsStartAt());
        console2.log("HookrLockRewardsV2 runtime bytes", address(rewards).code.length);
        console2.log("HookrLaunchBoostV2 runtime bytes", address(boost).code.length);
        console2.log("HookrLockRewardsV2 runtime codehash");
        console2.logBytes32(address(rewards).codehash);
        console2.log("HookrLaunchBoostV2 runtime codehash");
        console2.logBytes32(address(boost).codehash);
    }

    /// @dev Refuse a deployment timestamp whose four-hour claim boundary would leave less than the
    ///      minimum operational window before the first weekly Monday. The post-deploy readback
    ///      repeats this against the actual first CREATE timestamp.
    function _assertProspectiveBootstrapWindow() internal view {
        uint256 claimStart = block.timestamp + 4 hours;
        uint256 weeklyNumber = (claimStart - 4 days) / 7 days + 1;
        uint256 weeklyStart = 4 days + weeklyNumber * 7 days;
        require(weeklyStart >= claimStart + MIN_STAGE_REMAINING, "claim bridge below 45 minutes");
    }

    /// @dev A generation-3 launchpad has the same name/version but no instant-launch selector.
    function _assertGeneration4Core(HookrLaunchpad launchpad) internal view {
        (uint256 tokensInPool, uint96 openPriceWei, uint160 sqrtPriceX96, uint256 openFdvWei, uint8 err) =
            launchpad.previewInstantLaunch(CORE_CANARY_DEPOSIT_WEI, CORE_CANARY_POOL_SUPPLY_BPS);
        require(err == 0, "v4 instant preview rejected");
        require(tokensInPool == 500_000_000 ether, "v4 instant pool supply wrong");
        require(openPriceWei == 20_000_000, "v4 instant price wrong");
        require(sqrtPriceX96 != 0, "v4 instant sqrt price missing");
        require(openFdvWei == 0.02 ether, "v4 instant FDV wrong");

        address token = launchpad.launchedByIntent(EXPECTED_DEPLOYER, CORE_CANARY_INTENT);
        require(token != address(0), "v4 core canary missing");
        HookrLaunchpad.Launch memory launch = launchpad.getLaunch(token);
        require(launch.token == token, "v4 core canary token wrong");
        require(launch.creator == EXPECTED_DEPLOYER, "v4 core canary creator wrong");
        require(launch.launchBlock != 0, "v4 core canary launch block missing");
        require(launch.blueprintId == 0, "v4 core canary blueprint wrong");
        require(launch.graduated, "v4 core canary not live");
        require(launch.graduatedAtBlock == launch.launchBlock, "v4 core canary not instant");
        require(launch.soldTokens == 0 && launch.reserveWei == 0, "v4 core canary touched curve state");
        require(launch.targetWei == CORE_CANARY_DEPOSIT_WEI, "v4 core canary deposit wrong");
        require(launch.basePriceWei == openPriceWei, "v4 core canary opening price wrong");
        require(launch.sqrtPriceX96AtGraduation == sqrtPriceX96, "v4 core canary sqrt price wrong");
        require(PoolId.unwrap(launch.poolId) != bytes32(0), "v4 core canary pool missing");

        HookrLaunchpad.HookParams memory params = launch.hookParams;
        require(params.guardBlocks == 200 && params.maxBuyBps == 1000, "v4 core guard block wrong");
        require(params.snipeTaxPips == 200_000, "v4 core snipe block wrong");
        require(
            params.baseFeePips == 3000 && params.maxFeePips == 30_000 && params.surgeSens == 5,
            "v4 core surge block wrong"
        );
        require(params.burnBps == 100 && params.burnTriggerWei == 0, "v4 core burn block wrong");
        require(params.lpBps == 25, "v4 core LP block wrong");
        require(
            params.potBps == 50 && params.potEveryNBuys == 10 && params.potMinBuyWei == 0.001 ether,
            "v4 core pot block wrong"
        );
    }

    function _assertReadbacks(HookrLockRewardsV2 rewards, HookrLaunchBoostV2 boost, address launchpadAddress)
        internal
        view
    {
        require(address(rewards).code.length <= MAX_RUNTIME_SIZE, "LockRewards exceeds EIP-170");
        require(address(boost).code.length <= MAX_RUNTIME_SIZE, "LaunchBoost exceeds EIP-170");
        require(
            keccak256(bytes(rewards.contractName())) == keccak256(bytes("HookrLockRewards")),
            "LockRewards identity wrong"
        );
        require(keccak256(bytes(rewards.contractVersion())) == keccak256(bytes("2")), "LockRewards version wrong");
        require(
            keccak256(bytes(boost.contractName())) == keccak256(bytes("HookrLaunchBoost")), "LaunchBoost identity wrong"
        );
        require(keccak256(bytes(boost.contractVersion())) == keccak256(bytes("2")), "LaunchBoost version wrong");

        require(address(rewards.hookrToken()) == HOOKR_TOKEN, "LockRewards token wrong");
        require(address(boost.hookrToken()) == HOOKR_TOKEN, "LaunchBoost token wrong");
        require(address(boost.launchpad()) == launchpadAddress, "LaunchBoost launchpad wrong");
        require(address(boost.lockRewards()) == address(rewards), "LaunchBoost rewards wrong");
        require(rewards.rewardSource() == address(boost), "reward source wrong");
        require(rewards.configurator() == address(0), "configurator not burned");

        require(rewards.BOOTSTRAP_EPOCH_LENGTH() == 2 hours, "bootstrap epoch length wrong");
        require(rewards.EPOCH_LENGTH() == 7 days, "weekly epoch length wrong");
        require(rewards.MONDAY_EPOCH_OFFSET() == 4 days, "weekly epoch offset wrong");
        require(rewards.FIRST_WEEKLY_EPOCH() == 3, "first weekly epoch wrong");
        _assertBootstrapBoundaries(rewards);
        require(rewards.currentEpoch() == 0 && rewards.checkpointEpoch() == 0, "bootstrap epoch not current");
        require(rewards.checkpointCurrent(), "initial checkpoint stale");
        require(boost.boostingOpensAt() == rewards.feeEpochStartsAt(), "boost opening boundary wrong");
        require(!boost.boostingOpen(), "boosting opened during lock epoch");

        (uint40 tier0Duration, uint16 tier0Multiplier) = rewards.tierConfig(0);
        (uint40 tier1Duration, uint16 tier1Multiplier) = rewards.tierConfig(1);
        (uint40 tier2Duration, uint16 tier2Multiplier) = rewards.tierConfig(2);
        require(tier0Duration == 30 days && tier0Multiplier == 10_000, "tier 0 wrong");
        require(tier1Duration == 90 days && tier1Multiplier == 11_500, "tier 1 wrong");
        require(tier2Duration == 180 days && tier2Multiplier == 12_500, "tier 2 wrong");
        require(boost.BOOST_FEE_BPS() == 100, "boost fee wrong");
        require(boost.MIN_GROSS_BOOST() == 100 ether, "minimum boost wrong");
        require(boost.MAX_ACTIVE_BOOSTS() == 512, "active boost capacity wrong");

        require(rewards.totalLockedPrincipal() == 0, "initial lock principal nonzero");
        require(rewards.rewardReserve() == 0, "initial reward reserve nonzero");
        require(rewards.cumulativeBoostFeesNotified() == 0, "initial reward fees nonzero");
        require(rewards.cumulativeRewardsClaimed() == 0, "initial claimed rewards nonzero");
        require(boost.totalBoostPrincipal() == 0, "initial boost principal nonzero");
        require(boost.cumulativeGrossBoosted() == 0, "initial gross boosts nonzero");
        require(boost.cumulativePrincipalAdded() == 0, "initial boost additions nonzero");
        require(boost.cumulativeFeesForwarded() == 0, "initial forwarded fees nonzero");
        require(boost.boostedTokensCount() == 0, "initial boost registry nonzero");

        (
            uint256 rewardsBalance,
            uint256 lockLiability,
            uint256 rewardLiability,
            uint256 rewardsSurplus,
            bool rewardsOk
        ) = rewards.solvency();
        require(rewardsOk && rewardsBalance == lockLiability + rewardLiability + rewardsSurplus, "rewards insolvent");
        (uint256 boostBalance, uint256 boostLiability, uint256 boostSurplus, bool boostOk) = boost.solvency();
        require(boostOk && boostBalance == boostLiability + boostSurplus, "boost insolvent");
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
        require(uint256(weeklyStart) >= uint256(claimStart) + MIN_STAGE_REMAINING, "claim bridge below 45 minutes");
        require(rewards.epochStart(0) == startedAt, "epoch zero boundary wrong");
        require(rewards.epochStart(1) == feeStart, "epoch one boundary wrong");
        require(rewards.epochStart(2) == claimStart, "epoch two boundary wrong");
        require(rewards.epochStart(3) == weeklyStart, "epoch three boundary wrong");
    }
}
