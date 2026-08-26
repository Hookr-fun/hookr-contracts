// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {
    HookrUtilityV3CanaryBase,
    IHookrLaunchBoostV3Canary,
    IHookrLockRewardsV3Canary
} from "./HookrUtilityV3CanaryBase.s.sol";

/// @notice Stage 3/3: exactly one reward claim during bootstrap bridge epoch two.
/// @dev The bridge remains usable until the weekly boundary guard leaves fewer than 45 minutes.
contract CanaryHookrUtilitiesV3Claim is HookrUtilityV3CanaryBase {
    function run() external {
        UtilityContracts memory u = _loadUtilityContracts();
        (uint256 positionId, IHookrLockRewardsV3Canary.Position memory lockPosition) = _canaryPosition(u.rewards);
        require(u.rewards.currentEpoch() == 2, "not bootstrap claim epoch");
        require(block.timestamp >= u.rewards.claimEpochStartsAt(), "claim epoch not started");
        _requireStageRemaining(u.rewards.weeklyEpochsStartAt());
        require(lockPosition.lastClaimEpoch == lockPosition.activationEpoch, "claim stage already started");
        require(u.rewards.totalLockedPrincipal() >= CANARY_LOCK_GROSS, "lock liability below canary");
        require(u.rewards.cumulativeBoostFeesNotified() >= CANARY_FEE, "notified fees below canary");

        address token = _canonicalLaunchToken(u.launchpad);
        // One position per token, creator-only: the position is keyed by token and carries the
        // creator, exactly as V2.
        IHookrLaunchBoostV3Canary.BoostPosition memory boostPosition = u.boost.boostOf(token);
        require(boostPosition.creator == EXPECTED_DEPLOYER, "boost creator wrong");
        require(boostPosition.principal == CANARY_PRINCIPAL && boostPosition.tier == CANARY_TIER, "boost state wrong");
        require(boostPosition.startedAt >= u.rewards.feeEpochStartsAt(), "boost started before fee epoch");
        require(boostPosition.startedAt < u.rewards.claimEpochStartsAt(), "boost started after fee epoch");
        require(u.boost.totalBoostPrincipal() >= CANARY_PRINCIPAL, "boost liability below canary");
        require(u.boost.cumulativeGrossBoosted() >= CANARY_BOOST_GROSS, "gross boosts below canary");
        require(u.boost.cumulativePrincipalAdded() >= CANARY_PRINCIPAL, "boost additions below canary");
        require(u.boost.cumulativeFeesForwarded() >= CANARY_FEE, "forwarded fees below canary");
        uint256 boostedTokensCount = u.boost.boostedTokensCount();
        uint256 tokenIndexPlusOne = u.boost.boostedTokenIndexPlusOne(token);
        require(tokenIndexPlusOne != 0 && tokenIndexPlusOne <= boostedTokensCount, "boost registry index wrong");
        require(u.boost.isBoostRegistered(token), "boost registry membership missing");

        uint256 balanceBefore = u.token.balanceOf(EXPECTED_DEPLOYER);
        uint256 reserveBefore = u.rewards.rewardReserve();
        uint256 claimedBefore = u.rewards.cumulativeRewardsClaimed();
        uint256 startIndex = u.rewards.rewardIndexAtEpoch(lockPosition.activationEpoch);
        vm.startBroadcast(EXPECTED_DEPLOYER);
        uint256 reward = u.rewards.claim(positionId, EXPECTED_DEPLOYER);
        vm.stopBroadcast();

        uint32 claimEpoch = 2;
        uint256 endIndex = u.rewards.rewardIndexAtEpoch(claimEpoch);
        require(endIndex >= startIndex, "reward index regressed");
        uint256 expectedReward = FullMath.mulDiv(uint256(lockPosition.weight), endIndex - startIndex, 1 << 128);
        require(expectedReward != 0 && reward == expectedReward, "claimed pro-rata reward wrong");
        require(u.token.balanceOf(EXPECTED_DEPLOYER) == balanceBefore + reward, "claim transfer wrong");
        IHookrLockRewardsV3Canary.Position memory settled = u.rewards.position(positionId);
        require(settled.lastClaimEpoch == claimEpoch, "settled claim cursor wrong");
        require(u.rewards.checkpointCurrent(), "checkpoint not current");
        require(u.rewards.cumulativeRewardsClaimed() == claimedBefore + reward, "claimed ledger delta wrong");
        require(u.rewards.rewardReserve() + reward == reserveBefore, "reward reserve delta wrong");

        console2.log("utility V3 canary stage 3 claimed", reward);
        console2.log("utility V3 canary post-claim reserve", u.rewards.rewardReserve());
    }
}
