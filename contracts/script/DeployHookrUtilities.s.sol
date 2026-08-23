// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HookrLaunchBoostV1} from "../src/HookrLaunchBoostV1.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLaunchpadLib} from "../src/libraries/HookrLaunchpadLib.sol";
import {HookrLockRewardsV1} from "../src/HookrLockRewardsV1.sol";
import {IHookrLockRewardsV1} from "../src/interfaces/IHookrLockRewardsV1.sol";
import {IHookrUtilityToken} from "../src/libraries/HookrTokenTransfer.sol";

/// @notice Independent three-transaction deployment for the optional $HOOKR utility rail.
/// @dev This script deliberately does not import or call DeployRobinhood. It cannot change the
///      generation-4 ten-receipt core sequence. The supported launchpad address and runtime hash
///      must come from the promoted core release, never from an unverified candidate artifact.
contract DeployHookrUtilities is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant MAX_RUNTIME_SIZE = 24_576;

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

        address launchpadAddress = vm.envAddress("HOOKR_UTILITY_LAUNCHPAD_ADDRESS");
        bytes32 launchpadRuntimeCodehash = vm.envBytes32("HOOKR_UTILITY_LAUNCHPAD_RUNTIME_CODEHASH");
        require(launchpadAddress != address(0) && launchpadAddress.code.length != 0, "launchpad missing");
        require(launchpadRuntimeCodehash != bytes32(0), "launchpad runtime hash missing");
        require(launchpadAddress.codehash == launchpadRuntimeCodehash, "launchpad runtime wrong");

        HookrLaunchpad launchpad = HookrLaunchpad(payable(launchpadAddress));
        require(
            keccak256(bytes(launchpad.contractName())) == keccak256(bytes("HookrLaunchpad")), "launchpad identity wrong"
        );
        require(keccak256(bytes(launchpad.contractVersion())) == keccak256(bytes("1.0.0")), "launchpad version wrong");
        _assertGeneration4Core(launchpad);

        address deployer = EXPECTED_DEPLOYER;
        console2.log("utility deployer", deployer);
        console2.log("supported launchpad", launchpadAddress);
        console2.log("deployer balance", deployer.balance);

        // Address-based broadcast keeps the no-broadcast simulation secret-free. A real broadcast
        // must still select a reviewed signer for EXPECTED_DEPLOYER explicitly.
        vm.startBroadcast(deployer);
        HookrLockRewardsV1 rewards = new HookrLockRewardsV1(IHookrUtilityToken(HOOKR_TOKEN), deployer);
        HookrLaunchBoostV1 boost =
            new HookrLaunchBoostV1(IHookrUtilityToken(HOOKR_TOKEN), launchpad, IHookrLockRewardsV1(address(rewards)));
        rewards.setRewardSourceOnce(address(boost));
        vm.stopBroadcast();

        _assertReadbacks(rewards, boost, launchpadAddress);

        console2.log("HookrLockRewardsV1", address(rewards));
        console2.log("HookrLaunchBoostV1", address(boost));
        console2.log("HookrLockRewardsV1 runtime bytes", address(rewards).code.length);
        console2.log("HookrLaunchBoostV1 runtime bytes", address(boost).code.length);
        console2.log("HookrLockRewardsV1 runtime codehash");
        console2.logBytes32(address(rewards).codehash);
        console2.log("HookrLaunchBoostV1 runtime codehash");
        console2.logBytes32(address(boost).codehash);
    }

    /// @dev A generation-3 launchpad has the same name/version but no instant-launch selector.
    ///      Bind utility deployment to the exact promoted v4 preview and its all-five canary before
    ///      `startBroadcast`, so a stale manifest/runtime cannot receive utility immutables.
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

        HookrLaunchpadLib.HookParams memory params = launch.hookParams;
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

    function _assertReadbacks(HookrLockRewardsV1 rewards, HookrLaunchBoostV1 boost, address launchpadAddress)
        internal
        view
    {
        require(address(rewards).code.length <= MAX_RUNTIME_SIZE, "LockRewards exceeds EIP-170");
        require(address(boost).code.length <= MAX_RUNTIME_SIZE, "LaunchBoost exceeds EIP-170");
        require(
            keccak256(bytes(rewards.contractName())) == keccak256(bytes("HookrLockRewards")),
            "LockRewards identity wrong"
        );
        require(keccak256(bytes(rewards.contractVersion())) == keccak256(bytes("1")), "LockRewards version wrong");
        require(
            keccak256(bytes(boost.contractName())) == keccak256(bytes("HookrLaunchBoost")), "LaunchBoost identity wrong"
        );
        require(keccak256(bytes(boost.contractVersion())) == keccak256(bytes("1")), "LaunchBoost version wrong");

        require(address(rewards.hookrToken()) == HOOKR_TOKEN, "LockRewards token wrong");
        require(address(boost.hookrToken()) == HOOKR_TOKEN, "LaunchBoost token wrong");
        require(address(boost.launchpad()) == launchpadAddress, "LaunchBoost launchpad wrong");
        require(address(boost.lockRewards()) == address(rewards), "LaunchBoost rewards wrong");
        require(rewards.rewardSource() == address(boost), "reward source wrong");
        require(rewards.configurator() == address(0), "configurator not burned");

        require(rewards.EPOCH_LENGTH() == 7 days, "epoch length wrong");
        require(rewards.MONDAY_EPOCH_OFFSET() == 4 days, "epoch offset wrong");
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
}
