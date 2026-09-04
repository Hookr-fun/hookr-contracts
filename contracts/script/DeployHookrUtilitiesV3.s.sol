// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {IHookrLaunchBoostV3Canary, IHookrLockRewardsV3Canary} from "./HookrUtilityV3CanaryBase.s.sol";

/// @dev Deployment-only reward-source surface, deliberately separated from the canary read surface.
///      One-shot, exactly as V2: a single call that points the sink and burns the authority.
interface IHookrLockRewardsV3Wiring {
    function setRewardSourceOnce(address source) external;
}

/// @notice Independent three-transaction deployment for the bootstrap-enabled V3 $HOOKR utility rail.
/// @dev This script never imports or calls DeployRobinhood and cannot alter the promoted
///      generation-4 core. It mirrors DeployHookrUtilitiesV2 receipt-for-receipt.
///
///      The two CREATEs go through `deployCode` against the reviewed Foundry artifact rather than
///      `new HookrLockRewardsV3(...)`, because HookrLockRewardsV3/HookrLaunchBoostV3 are still
///      being hardened in a separate worktree and are not in this tree. This is NOT a weakening:
///      `deployCode` concatenates the artifact's exact initcode with ABI-encoded constructor args,
///      so the broadcast entry is byte-identical to the `new` form — verified empirically:
///      transactionType "CREATE" and a populated `contractName`, which is exactly what
///      scripts/verify-utility-v3-canary-evidence.mjs re-derives with `encodeDeployData`. It also
///      fails closed: a missing or unbuilt artifact aborts before any broadcast.
contract DeployHookrUtilitiesV3 is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant MAX_RUNTIME_SIZE = 24_576;
    uint256 internal constant MIN_STAGE_REMAINING = 45 minutes;
    /// @dev The bootstrap epoch length the release was reviewed against. The boundary checks below
    ///      derive from the live `BOOTSTRAP_EPOCH_LENGTH()`, so this is the only literal.
    uint40 internal constant EXPECTED_BOOTSTRAP_EPOCH_LENGTH = 2 hours;

    address internal constant EXPECTED_DEPLOYER = 0x5a52D4B820Ae7F02880d270562950918ACb14aA2;
    address internal constant HOOKR_TOKEN = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;
    bytes32 internal constant REVIEWED_HOOKR_RUNTIME_CODEHASH =
        0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d;
    bytes32 internal constant CORE_CANARY_INTENT = keccak256("hookr.v4.canary.instant.all-five.1");
    uint256 internal constant CORE_CANARY_DEPOSIT_WEI = 0.01 ether;
    uint16 internal constant CORE_CANARY_POOL_SUPPLY_BPS = 5000;

    string internal constant LOCK_REWARDS_ARTIFACT = "HookrLockRewardsV3.sol:HookrLockRewardsV3";
    string internal constant LAUNCH_BOOST_ARTIFACT = "HookrLaunchBoostV3.sol:HookrLaunchBoostV3";

    /*//////////////////////////////////////////////////////////////////////////
                            THE IMMUTABLE LAUNCHPAD SET
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev V3's only divergence from V2: the Boost rail binds a set of launchpad generations
    ///      instead of exactly one, so tokens launched by generation 3 and by generation 4 are both
    ///      boostable on one rail.
    ///
    ///      ORDER IS LOAD-BEARING AND IS OLDEST GENERATION FIRST. HookrLaunchBoostV3 fixes these
    ///      into immutable slots and scans them from slot 0 upward when resolving a token or an
    ///      intent, so reordering this array produces a different deployment with different
    ///      resolution behaviour. It is never a cosmetic edit.
    ///
    ///      These are reviewed mainnet constants rather than environment input on purpose: this
    ///      script refuses to run off chain 4663, the two addresses are immutable facts of the
    ///      promoted cores, and taking the ORDER from the environment would put a silent,
    ///      unreviewable behaviour change one shell variable away. The operator still supplies both
    ///      runtime codehashes, which is the part that must be confirmed at deploy time.
    address internal constant LAUNCHPAD_GENERATION_3 = 0xaAed6fab06D53311220F35421Dda5cc6D6e9d6C3;
    address internal constant LAUNCHPAD_GENERATION_4 = 0x5Ce779D23D2e99D322004F203813389B6a426e3B;

    function run() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "wrong chain");
        require(HOOKR_TOKEN.codehash == REVIEWED_HOOKR_RUNTIME_CODEHASH, "HOOKR runtime wrong");
        _assertProspectiveBootstrapWindow();

        // The promoted generation-4 core. Still environment-supplied, because it is what the
        // separate core-prerequisite verifier and the staged canary transact against, but it must
        // agree with the reviewed constant — the env cannot silently redirect the deployment.
        address launchpadAddress = vm.envAddress("HOOKR_UTILITY_V3_LAUNCHPAD_ADDRESS");
        require(launchpadAddress == LAUNCHPAD_GENERATION_4, "launchpad env is not the reviewed generation-4 core");

        HookrLaunchpad[] memory launchpads = new HookrLaunchpad[](2);
        launchpads[0] = HookrLaunchpad(payable(LAUNCHPAD_GENERATION_3));
        launchpads[1] = HookrLaunchpad(payable(LAUNCHPAD_GENERATION_4));

        bytes32[] memory launchpadRuntimeCodehashes = new bytes32[](2);
        launchpadRuntimeCodehashes[0] = vm.envBytes32("HOOKR_UTILITY_V3_LAUNCHPAD_GEN3_RUNTIME_CODEHASH");
        launchpadRuntimeCodehashes[1] = vm.envBytes32("HOOKR_UTILITY_V3_LAUNCHPAD_RUNTIME_CODEHASH");

        for (uint256 i; i < launchpads.length; ++i) {
            address pad = address(launchpads[i]);
            require(pad != address(0) && pad.code.length != 0, "launchpad missing");
            require(launchpadRuntimeCodehashes[i] != bytes32(0), "launchpad runtime hash missing");
            require(pad.codehash == launchpadRuntimeCodehashes[i], "launchpad runtime wrong");
            require(
                keccak256(bytes(launchpads[i].contractName())) == keccak256(bytes("HookrLaunchpad")),
                "launchpad identity wrong"
            );
            require(
                keccak256(bytes(launchpads[i].contractVersion())) == keccak256(bytes("1.0.0")),
                "launchpad version wrong"
            );
            for (uint256 j; j < i; ++j) {
                require(address(launchpads[j]) != pad, "launchpad set has a duplicate");
            }
        }

        // Only the newest generation is required to be a generation-4 core: that is the one the
        // canary launches and boosts through. Older generations are boostable, not canary targets.
        HookrLaunchpad launchpad = launchpads[launchpads.length - 1];
        require(address(launchpad) == launchpadAddress, "newest launchpad is not the promoted core");
        _assertGeneration4Core(launchpad);

        console2.log("utility V3 deployer", EXPECTED_DEPLOYER);
        console2.log("launchpad set, oldest first:");
        for (uint256 i; i < launchpads.length; ++i) {
            console2.log("  launchpad", i, address(launchpads[i]));
        }
        console2.log("deployer balance", EXPECTED_DEPLOYER.balance);

        // Address-based broadcast keeps the no-broadcast simulation secret-free. A real broadcast
        // must still select the separately reviewed signer for EXPECTED_DEPLOYER explicitly.
        vm.startBroadcast(EXPECTED_DEPLOYER);

        // Unchanged from V2: (token, configurator). Constructor arg 2 is the one-shot deployment
        // authority, burned by `setRewardSourceOnce` below. This encoding and the matching
        // `expectedRewardsInit` in scripts/verify-utility-v3-canary-evidence.mjs change together.
        IHookrLockRewardsV3Canary rewards =
            IHookrLockRewardsV3Canary(deployCode(LOCK_REWARDS_ARTIFACT, abi.encode(HOOKR_TOKEN, EXPECTED_DEPLOYER)));

        // V3's one divergence: arg 2 is the launchpad SET, oldest generation first, not a single
        // address. The matching `expectedBoostInit` in the two JS verifiers encodes the same array
        // in the same order and must change with it.
        IHookrLaunchBoostV3Canary boost = IHookrLaunchBoostV3Canary(
            deployCode(LAUNCH_BOOST_ARTIFACT, abi.encode(HOOKR_TOKEN, launchpads, address(rewards)))
        );

        _wireRewardSource(address(rewards), address(boost));
        vm.stopBroadcast();

        _assertReadbacks(rewards, boost, launchpads);

        console2.log("HookrLockRewardsV3", address(rewards));
        console2.log("HookrLaunchBoostV3", address(boost));
        console2.log("bootstrap started", rewards.bootstrapStartedAt());
        console2.log("fee epoch starts", rewards.feeEpochStartsAt());
        console2.log("claim epoch starts", rewards.claimEpochStartsAt());
        console2.log("weekly epochs start", rewards.weeklyEpochsStartAt());
        console2.log("HookrLockRewardsV3 runtime bytes", address(rewards).code.length);
        console2.log("HookrLaunchBoostV3 runtime bytes", address(boost).code.length);
        console2.log("HookrLockRewardsV3 runtime codehash");
        console2.logBytes32(address(rewards).codehash);
        console2.log("HookrLaunchBoostV3 runtime codehash");
        console2.logBytes32(address(boost).codehash);
    }

    /// @dev THE THIRD AND FINAL DEPLOY RECEIPT, unchanged from V2.
    ///
    ///      One call. `setRewardSourceOnce` points the fee sink at LaunchBoost and burns
    ///      `configurator` to address(0) in the same transaction, so the sink can never be
    ///      re-pointed and the contracts stay non-upgradeable by construction.
    ///
    ///      This keeps the deployment at 3 receipts and the pipeline at 3+2+2+1 = 8. The exact-count
    ///      gate in the verifier, UTILITY_V3_RECEIPT_LABELS, UtilityV3DeploymentReceipts,
    ///      `allV3Receipts` and the candidate's eight-unique-hash check all encode 8 deliberately.
    ///      Changing that is a reviewed spec change, never a relaxation.
    function _wireRewardSource(address rewards, address boost) internal {
        IHookrLockRewardsV3Wiring(rewards).setRewardSourceOnce(boost);
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

    function _assertReadbacks(
        IHookrLockRewardsV3Canary rewards,
        IHookrLaunchBoostV3Canary boost,
        HookrLaunchpad[] memory launchpads
    ) internal view {
        require(address(rewards).code.length <= MAX_RUNTIME_SIZE, "LockRewards exceeds EIP-170");
        require(address(boost).code.length <= MAX_RUNTIME_SIZE, "LaunchBoost exceeds EIP-170");
        require(
            keccak256(bytes(rewards.contractName())) == keccak256(bytes("HookrLockRewards")),
            "LockRewards identity wrong"
        );
        require(keccak256(bytes(rewards.contractVersion())) == keccak256(bytes("3")), "LockRewards version wrong");
        require(
            keccak256(bytes(boost.contractName())) == keccak256(bytes("HookrLaunchBoost")), "LaunchBoost identity wrong"
        );
        require(keccak256(bytes(boost.contractVersion())) == keccak256(bytes("3")), "LaunchBoost version wrong");

        require(rewards.hookrToken() == HOOKR_TOKEN, "LockRewards token wrong");
        require(boost.hookrToken() == HOOKR_TOKEN, "LaunchBoost token wrong");
        _assertDeployedLaunchpadSet(boost, launchpads);
        require(boost.lockRewards() == address(rewards), "LaunchBoost rewards wrong");
        require(rewards.rewardSource() == address(boost), "reward source wrong");
        // Mirrors _assertRewardSourceAuthorityBurned in the canary base: the one-shot authority is
        // gone in the same transaction that set the sink, so no account can ever re-point it.
        require(rewards.configurator() == address(0), "configurator not burned");

        require(rewards.BOOTSTRAP_EPOCH_LENGTH() == EXPECTED_BOOTSTRAP_EPOCH_LENGTH, "bootstrap epoch length wrong");
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

    /// @dev Read the deployed launchpad set back slot by slot and require it to be exactly the set
    ///      that was passed to the constructor, in the same order, with a zero tail above
    ///      `launchpadCount`. The zero tail matters: it is what proves no extra generation became
    ///      boostable, which a membership-only check would miss.
    function _assertDeployedLaunchpadSet(IHookrLaunchBoostV3Canary boost, HookrLaunchpad[] memory launchpads)
        internal
        view
    {
        uint8 maxLaunchpads = boost.MAX_LAUNCHPADS();
        require(maxLaunchpads == 4, "LaunchBoost MAX_LAUNCHPADS wrong");
        require(launchpads.length != 0 && launchpads.length <= maxLaunchpads, "launchpad set size wrong");
        require(boost.launchpadCount() == launchpads.length, "LaunchBoost launchpad count wrong");

        for (uint256 i; i < maxLaunchpads; ++i) {
            address slot = _deployedLaunchpadSlot(boost, i);
            if (i >= launchpads.length) {
                require(slot == address(0), "LaunchBoost launchpad tail not empty");
            } else {
                require(slot == address(launchpads[i]), "LaunchBoost launchpad slot wrong");
            }
        }
    }

    function _deployedLaunchpadSlot(IHookrLaunchBoostV3Canary boost, uint256 slot) internal view returns (address) {
        if (slot == 0) return boost.launchpad0();
        if (slot == 1) return boost.launchpad1();
        if (slot == 2) return boost.launchpad2();
        return boost.launchpad3();
    }

    function _assertBootstrapBoundaries(IHookrLockRewardsV3Canary rewards) internal view {
        uint40 bootstrapLength = rewards.BOOTSTRAP_EPOCH_LENGTH();
        uint40 startedAt = rewards.bootstrapStartedAt();
        uint40 feeStart = rewards.feeEpochStartsAt();
        uint40 claimStart = rewards.claimEpochStartsAt();
        uint40 weeklyStart = rewards.weeklyEpochsStartAt();
        require(feeStart == startedAt + bootstrapLength, "fee boundary wrong");
        require(claimStart == feeStart + bootstrapLength, "claim boundary wrong");
        uint256 weeklyNumber = (uint256(claimStart) - 4 days) / 7 days + 1;
        require(weeklyStart == 4 days + weeklyNumber * 7 days, "weekly boundary wrong");
        require(uint256(weeklyStart) >= uint256(claimStart) + MIN_STAGE_REMAINING, "claim bridge below 45 minutes");
        require(rewards.epochStart(0) == startedAt, "epoch zero boundary wrong");
        require(rewards.epochStart(1) == feeStart, "epoch one boundary wrong");
        require(rewards.epochStart(2) == claimStart, "epoch two boundary wrong");
        require(rewards.epochStart(3) == weeklyStart, "epoch three boundary wrong");
    }
}
