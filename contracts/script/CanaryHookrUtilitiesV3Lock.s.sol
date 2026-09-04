// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";

import {HookrUtilityV3CanaryBase, IHookrLockRewardsV3Canary} from "./HookrUtilityV3CanaryBase.s.sol";

/// @notice Stage 1/3: exactly one 100-HOOKR approval and one tier-0 lock in bootstrap epoch zero.
/// @dev Any completed lock or partially mined approval makes the preconditions fail on rerun.
contract CanaryHookrUtilitiesV3Lock is HookrUtilityV3CanaryBase {
    function run() external {
        UtilityContracts memory u = _loadUtilityContracts();
        require(u.rewards.currentEpoch() == 0, "not bootstrap lock epoch");
        _requireStageRemaining(u.rewards.feeEpochStartsAt());
        require(!u.boost.boostingOpen(), "boosting already open");
        require(u.rewards.positionsOfCount(EXPECTED_DEPLOYER) == 0, "lock stage already started");
        require(u.token.allowance(EXPECTED_DEPLOYER, address(u.rewards)) == 0, "prior lock approval exists");
        require(u.token.balanceOf(EXPECTED_DEPLOYER) >= CANARY_LOCK_GROSS, "insufficient HOOKR");

        uint32 depositEpoch = u.rewards.currentEpoch();
        (, uint32 maxActivationEpoch,, uint40 previewUnlockAt,) = u.rewards.previewLock(CANARY_LOCK_GROSS, CANARY_TIER);
        require(maxActivationEpoch == 1, "preview activation epoch wrong");
        uint256 rawMaxUnlockAt = uint256(previewUnlockAt) + CANARY_DEADLINE_WINDOW;
        require(rawMaxUnlockAt <= type(uint40).max, "canary unlock bound overflow");
        // Safe after the explicit uint40 upper bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 maxUnlockAt = uint40(rawMaxUnlockAt);
        uint256 deadline = block.timestamp + CANARY_DEADLINE_WINDOW;

        vm.startBroadcast(EXPECTED_DEPLOYER);
        require(u.token.approve(address(u.rewards), CANARY_LOCK_GROSS), "HOOKR approval failed");
        // V3 has no minimum lock principal. CANARY_LOCK_GROSS is a deliberate canary size; changing
        // it means changing HookrUtilityV3CanaryBase.s.sol and `lockGross` in
        // scripts/lib/utility-v3-canary-evidence.mjs together.
        uint256 positionId = u.rewards.lock(CANARY_LOCK_GROSS, CANARY_TIER, maxActivationEpoch, maxUnlockAt, deadline);
        vm.stopBroadcast();

        require(positionId != 0, "canary position id missing");
        (uint256 derivedPositionId, IHookrLockRewardsV3Canary.Position memory p) = _canaryPosition(u.rewards);
        require(derivedPositionId == positionId, "canary position receipt mismatch");
        require(depositEpoch == 0 && p.activationEpoch == 1, "activation epoch wrong");
        require(u.rewards.epochStart(p.activationEpoch) == u.rewards.feeEpochStartsAt(), "activation boundary wrong");
        require(p.expiryEpoch == u.rewards.epochAt(p.unlockAt), "expiry epoch wrong");
        require(p.lastClaimEpoch == p.activationEpoch, "claim cursor wrong");
        require(u.rewards.scheduledWeightAdds(1) >= CANARY_LOCK_GROSS, "scheduled weight below canary");
        require(u.rewards.totalLockedPrincipal() >= CANARY_LOCK_GROSS, "lock liability below canary");
        require(u.token.allowance(EXPECTED_DEPLOYER, address(u.rewards)) == 0, "lock allowance not consumed");

        console2.log("utility V3 canary stage 1 position", positionId);
        console2.log("utility V3 fee epoch", p.activationEpoch);
        console2.log("utility V3 fee epoch starts", u.rewards.feeEpochStartsAt());
    }
}
