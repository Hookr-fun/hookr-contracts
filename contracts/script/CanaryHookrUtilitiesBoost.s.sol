// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";

import {HookrLaunchBoostV1} from "../src/HookrLaunchBoostV1.sol";
import {HookrLockRewardsV1} from "../src/HookrLockRewardsV1.sol";
import {HookrUtilityCanaryBase} from "./HookrUtilityCanaryBase.s.sol";

/// @notice Stage 2/3: after the next Monday, approve and boost the canonical core canary launch.
/// @dev The canonical launch position and deployer allowance prevent replay. Global ledgers may
///      already contain unrelated locks and boosts, so this stage proves only its exact deltas.
contract CanaryHookrUtilitiesBoost is HookrUtilityCanaryBase {
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
        (, HookrLockRewardsV1.Position memory lockPosition) = _canaryPosition(u.rewards);
        require(u.rewards.currentEpoch() == lockPosition.activationEpoch, "not the activation epoch");
        require(lockPosition.lastClaimEpoch == lockPosition.activationEpoch, "lock claim cursor changed");
        require(u.rewards.totalLockedPrincipal() >= CANARY_LOCK_GROSS, "lock liability below canary");
        _requireCanaryEpochWindow(u.rewards);

        uint32 checkpointed = u.rewards.checkpointEpoch();
        require(
            checkpointed == lockPosition.activationEpoch - 1 || checkpointed == lockPosition.activationEpoch,
            "unexpected checkpoint cursor"
        );
        if (checkpointed == lockPosition.activationEpoch) {
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
        require(u.boost.boostedTokensCount() == beforeState.boostedTokensCount + 1, "boost registry count delta wrong");
        uint256 tokenIndexPlusOne = u.boost.boostedTokenIndexPlusOne(token);
        require(
            tokenIndexPlusOne != 0 && tokenIndexPlusOne <= u.boost.boostedTokensCount(), "boost registry index wrong"
        );
        require(u.boost.isBoostRegistered(token), "boost registry membership missing");
        require(u.token.allowance(EXPECTED_DEPLOYER, address(u.boost)) == 0, "boost allowance not consumed");

        HookrLaunchBoostV1.BoostPosition memory p = u.boost.boostOf(token);
        require(p.creator == EXPECTED_DEPLOYER, "boost creator wrong");
        require(p.principal == CANARY_PRINCIPAL && p.tier == CANARY_TIER, "boost position wrong");
        require(p.startedAt == block.timestamp && p.unlockAt == block.timestamp + 30 days, "boost timestamps wrong");
        require(p.startedAtBlock == block.number, "boost block clock wrong");
        require(u.boost.scoreOf(token) == CANARY_PRINCIPAL, "boost score wrong");

        console2.log("utility canary stage 2 token", token);
        console2.log("utility canary reward fee", fee);
        console2.log("utility canary claim epoch", lockPosition.activationEpoch + 1);
        console2.log("utility canary claim timestamp", u.rewards.epochStart(lockPosition.activationEpoch + 1));
    }
}
