// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrRules} from "hookr/interfaces/IHookrRules.sol";
import {HookrForward} from "./HookrForward.sol";

/// @title Hookr revenue Rules admission
/// @notice Whether the registry currently admits Rules for revenue token launches, markets and RULES doors.
/// @dev Uses the same code and schema checks as HookrLane._admitted, and the same trusted-root check as the root's
///      bind makes beside it. Internal functions only; nothing is linked. Admission is read on every call. Existing
///      pools, doors and tokens do not read it again.
library HookrRevenueRulesAdmission {
    /// @dev The cap on each read of the Rules.
    uint256 internal constant READ_GAS = 50_000;

    /// @notice Checks a live RULES admission, its code and schema, and its trusted root.
    /// @param registry The registry that holds the admission.
    /// @param root The root on which the Rules must be admitted.
    /// @param rules The Rules implementation to check.
    /// @return Whether the admission and both bounded Rules reads match.
    function admitted(address registry, address root, address rules) internal view returns (bool) {
        if (rules.code.length == 0) return false;
        IHookrRegistry.Admission memory a = IHookrRegistry(registry).admission(root, rules);
        if (a.implementation != rules || a.kind != IHookrRegistry.Kind.RULES || a.codeHash != rules.codehash) {
            return false;
        }
        (bool ok, uint256 word) = HookrForward.read(rules, abi.encodeCall(IHookrRules.configSchemaHash, ()), READ_GAS);
        if (!ok || bytes32(word) != a.schemaHash) return false;
        (ok, word) = HookrForward.read(rules, abi.encodeCall(IHookrRules.trustedRoot, ()), READ_GAS);
        return ok && word == uint256(uint160(root));
    }
}
