// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrLaunchpad} from "../../src/HookrLaunchpad.sol";

/// @dev Test-only owner seeding for suites that exercise permissionless blueprint authors.
library BlueprintSeeds {
    function seed(HookrLaunchpad pad) internal {
        HookrLaunchpad.HookParams memory params;
        params.baseFeePips = 3000;
        pad.saveBlueprint("house-1", params, 0);
        pad.saveBlueprint("house-2", params, 0);
        pad.saveBlueprint("house-3", params, 0);
        pad.saveBlueprint("house-4", params, 0);
        pad.saveBlueprint("house-5", params, 0);
    }
}
