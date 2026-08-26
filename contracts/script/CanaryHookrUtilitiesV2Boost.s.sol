// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";

import {HookrLaunchBoostV2} from "../src/HookrLaunchBoostV2.sol";
import {HookrLockRewardsV2} from "../src/HookrLockRewardsV2.sol";
import {HookrUtilityV2CanaryBase} from "./HookrUtilityV2CanaryBase.s.sol";

/// @notice Stage 2/3: exactly one 100-HOOKR approval and one fee-bearing Boost in bootstrap epoch one.
/// @dev The exact canonical position and deployer allowance reject replay or a partially mined prior stage.
contract CanaryHookrUtilitiesV2Boost is HookrUtilityV2CanaryBase {
    struct AmbientLedgers {
        uint256 rewardReserve;
        uint256 feesNotified;
        uint256 boostPrincipal;
        uint256 grossBoosted;
        uint256 principalAdded;
        uint256 feesForwarded;
        uint256 boostedTokensCount;
    }

    function run() external {
        UtilityContracts memory u = _loadUtilityContracts();
        (, HookrLockRewardsV2.Position memory lockPosition) = _canaryPosition(u.rewards);
        require(u.rewards.currentEpoch() == 1, "not bootstrap fee epoch");
        require(u.rewards.currentEpoch() == lockPosition.activationEpoch, "not the activation epoch");
        require(block.timestamp >= u.rewards.feeEpochStartsAt(), "fee epoch not started");
        _requireStageRemaining(u.rewards.claimEpochStartsAt());
        require(u.boost.boostingOpen(), "boosting not open");
        require(u.boost.boostingOpensAt() == u.rewards.feeEpochStartsAt(), "boost opening boundary wrong");
        require(lockPosition.lastClaimEpoch == lockPosition.activationEpoch, "lock claim cursor changed");
        require(u.rewards.totalLockedPrincipal() >= CANARY_LOCK_GROSS, "lock liability below canary");

        uint32 checkpointed = u.rewards.checkpointEpoch();
        require(checkpointed == 0 || checkpointed == 1, "unexpected checkpoint cursor");
        if (checkpointed == 1) {
            require(u.rewards.currentEligibleWeight() >= CANARY_LOCK_GROSS, "activated weight below canary");
        }

        address token = _canonicalLaunchToken(u.launchpad);
        require(u.boost.boostOf(token).principal == 0, "canonical launch already boosted");
        require(u.token.allowance(EXPECTED_DEPLOYER, address(u.boost)) == 0, "prior boost approval exists");
        require(u.token.balanceOf(EXPECTED_DEPLOYER) >= CANARY_BOOST_GROSS, "insufficient HOOKR");

        AmbientLedgers memory beforeState = AmbientLedgers({
            rewardReserve: u.rewards.rewardReserve(),
            feesNotified: u.rewards.cumulativeBoostFeesNotified(),
            boostPrincipal: u.boost.totalBoostPrincipal(),
            grossBoosted: u.boost.cumulativeGrossBoosted(),
            principalAdded: u.boost.cumulativePrincipalAdded(),
            feesForwarded: u.boost.cumulativeFeesForwarded(),
            boostedTokensCount: u.boost.boostedTokensCount()
        });
        require(beforeState.boostedTokensCount < u.boost.MAX_ACTIVE_BOOSTS(), "boost registry full");

        uint256 deadline = block.timestamp + CANARY_DEADLINE_WINDOW;
        vm.startBroadcast(EXPECTED_DEPLOYER);
        require(u.token.approve(address(u.boost), CANARY_BOOST_GROSS), "HOOKR approval failed");
        (address resolved, uint256 principal, uint256 fee) = u.boost
            .boostByIntent(CORE_CANARY_INTENT, CANARY_BOOST_GROSS, CANARY_TIER, CANARY_FEE, CANARY_PRINCIPAL, deadline);
        vm.stopBroadcast();

        require(resolved == token, "boost intent resolved wrong token");
        require(principal == CANARY_PRINCIPAL && fee == CANARY_FEE, "boost split wrong");
        require(u.rewards.checkpointCurrent(), "checkpoint not current");
        require(u.rewards.currentEligibleWeight() >= CANARY_LOCK_GROSS, "eligible weight below canary");
        require(u.rewards.rewardReserve() == beforeState.rewardReserve + CANARY_FEE, "reward reserve delta wrong");
        require(
            u.rewards.cumulativeBoostFeesNotified() == beforeState.feesNotified + CANARY_FEE, "notified fee delta wrong"
        );
        require(
            u.boost.cumulativeGrossBoosted() == beforeState.grossBoosted + CANARY_BOOST_GROSS, "gross boost delta wrong"
        );
        require(
            u.boost.cumulativePrincipalAdded() == beforeState.principalAdded + CANARY_PRINCIPAL,
            "boost principal delta wrong"
        );
        require(
            u.boost.cumulativeFeesForwarded() == beforeState.feesForwarded + CANARY_FEE, "forwarded fee delta wrong"
        );
        require(
            u.boost.totalBoostPrincipal() == beforeState.boostPrincipal + CANARY_PRINCIPAL,
            "boost liability delta wrong"
        );
        require(u.boost.boostedTokensCount() == beforeState.boostedTokensCount + 1, "registry count delta wrong");
        uint256 tokenIndexPlusOne = u.boost.boostedTokenIndexPlusOne(token);
        require(
            tokenIndexPlusOne != 0 && tokenIndexPlusOne <= u.boost.boostedTokensCount(), "boost registry index wrong"
        );
        require(u.boost.isBoostRegistered(token), "boost registry membership missing");
        require(u.token.allowance(EXPECTED_DEPLOYER, address(u.boost)) == 0, "boost allowance not consumed");

        HookrLaunchBoostV2.BoostPosition memory p = u.boost.boostOf(token);
        require(p.creator == EXPECTED_DEPLOYER, "boost creator wrong");
        require(p.principal == CANARY_PRINCIPAL && p.tier == CANARY_TIER, "boost position wrong");
        require(p.startedAt >= u.rewards.feeEpochStartsAt(), "boost started before fee epoch");
        require(p.startedAt < u.rewards.claimEpochStartsAt(), "boost started after fee epoch");
        require(p.unlockAt == p.startedAt + 30 days, "boost unlock wrong");
        require(p.startedAtBlock != 0, "boost block clock missing");
        require(u.boost.scoreOf(token) == CANARY_PRINCIPAL, "boost score wrong");

        console2.log("utility V2 canary stage 2 token", token);
        console2.log("utility V2 canary reward fee", fee);
        console2.log("utility V2 claim epoch starts", u.rewards.claimEpochStartsAt());
    }
}
