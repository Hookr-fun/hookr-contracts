// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";

import {HookrLockRewardsV1} from "../src/HookrLockRewardsV1.sol";
import {HookrUtilityCanaryBase} from "./HookrUtilityCanaryBase.s.sol";

/// @notice Stage 1/3: exactly one 1-HOOKR approval and one 30-day lock.
/// @dev Any completed lock or partially mined approval makes the preconditions fail on rerun.
contract CanaryHookrUtilitiesLock is HookrUtilityCanaryBase {
    function run() external {
        UtilityContracts memory u = _loadUtilityContracts();
        require(u.rewards.positionsOfCount(EXPECTED_DEPLOYER) == 0, "lock stage already started");
        require(u.token.allowance(EXPECTED_DEPLOYER, address(u.rewards)) == 0, "prior lock approval exists");
        require(u.token.balanceOf(EXPECTED_DEPLOYER) >= CANARY_LOCK_GROSS, "insufficient HOOKR");
        _requireCanaryEpochWindow(u.rewards);

        uint32 depositEpoch = u.rewards.currentEpoch();
        (, uint32 maxActivationEpoch,, uint40 previewUnlockAt,) = u.rewards.previewLock(CANARY_LOCK_GROSS, CANARY_TIER);
        uint256 rawMaxUnlockAt = uint256(previewUnlockAt) + CANARY_DEADLINE_WINDOW;
        require(rawMaxUnlockAt <= type(uint40).max, "canary unlock bound overflow");
        // Safe after the explicit uint40 upper bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 maxUnlockAt = uint40(rawMaxUnlockAt);
        uint256 deadline = block.timestamp + CANARY_DEADLINE_WINDOW;
        vm.startBroadcast(EXPECTED_DEPLOYER);
        require(u.token.approve(address(u.rewards), CANARY_LOCK_GROSS), "HOOKR approval failed");
        uint256 positionId = u.rewards.lock(CANARY_LOCK_GROSS, CANARY_TIER, maxActivationEpoch, maxUnlockAt, deadline);
        vm.stopBroadcast();

        require(positionId != 0, "canary position id missing");
        (uint256 derivedPositionId, HookrLockRewardsV1.Position memory p) = _canaryPosition(u.rewards);
        require(derivedPositionId == positionId, "canary position receipt mismatch");
        require(p.activationEpoch == depositEpoch + 1, "activation epoch wrong");
        require(p.expiryEpoch == u.rewards.epochAt(p.unlockAt), "expiry epoch wrong");
        require(p.lastClaimEpoch == p.activationEpoch, "claim cursor wrong");
        require(u.rewards.totalLockedPrincipal() >= CANARY_LOCK_GROSS, "lock liability below canary");
        require(u.token.allowance(EXPECTED_DEPLOYER, address(u.rewards)) == 0, "lock allowance not consumed");

        console2.log("utility canary stage 1 position", positionId);
        console2.log("utility canary activation epoch", p.activationEpoch);
        console2.log("utility canary activation timestamp", u.rewards.epochStart(p.activationEpoch));
    }
}
