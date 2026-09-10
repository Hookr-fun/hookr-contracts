// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HookrLaunchpadLib} from "../../src/libraries/HookrLaunchpadLib.sol";

import {HookrBlueprints} from "../../src/HookrBlueprints.sol";

/// @dev Test-only owner seeding for suites that exercise permissionless blueprint authors.
library BlueprintSeeds {
    function seed(HookrBlueprints blueprints) internal {
        HookrLaunchpadLib.HookParams memory params;
        params.baseFeePips = 3000;
        blueprints.saveBlueprint("house-1", params, 0);
        blueprints.saveBlueprint("house-2", params, 0);
        blueprints.saveBlueprint("house-3", params, 0);
        blueprints.saveBlueprint("house-4", params, 0);
        blueprints.saveBlueprint("house-5", params, 0);
    }
}
