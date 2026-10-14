// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrCompliance} from "../../src/compliance/HookrCompliance.sol";
import {ComplianceTestBase} from "./ComplianceTestBase.sol";

/// @dev A valid sanctions source that needs `use` gas (a proxied or multi-list oracle), within SOURCE_GAS (30,000).
contract HeavySource {
    uint256 public immutable use;

    constructor(uint256 u) {
        use = u;
    }

    function isSanctioned(address) external view returns (bool) {
        uint256 start = gasleft();
        while (start - gasleft() < use) {}
        return true;
    }
}

/// @notice F-036: `_source` checked its gas floor before the staticcall paid the cold-account charge (2,600), so a
///         source needing 29,000-29,700 gas returned (false, true) for a LISTED wallet at some caller gas limits.
/// @dev Adapted from the audit PoC SourceGasGap, which needed --isolate for a cold source. Here every source and its
///      registry are set up in setUp, and each probe runs inside a call that always reverts, which rolls the source
///      back to cold. On the old code this scan finds flips; now every probe is either the true answer or a
///      SourceGasTooLow revert.
contract HookrComplianceSourceGasFloorTest is ComplianceTestBase {
    error Probe(bool listed, bool failed);

    HookrCompliance[] internal registries;
    address internal wallet = makeAddr("listed");

    function setUp() public override {
        super.setUp();
        for (uint256 use = 28_600; use <= 29_900; use += 100) {
            HeavySource h = new HeavySource(use);
            // Only sources that answer within their full SOURCE_GAS budget are valid.
            try h.isSanctioned{gas: 30_000}(address(0)) returns (bool) {}
            catch {
                continue;
            }
            HookrCompliance c = new HookrCompliance(owner, DELAY);
            bytes32 kind = c.SET_SANCTIONS_SOURCE();
            vm.prank(owner);
            c.queue(kind, abi.encode(address(h)));
            vm.warp(vm.getBlockTimestamp() + DELAY);
            vm.prank(owner);
            c.setSanctionsSource(address(h));
            registries.push(c);
        }
    }

    /// @dev Always reverts, so the source stays cold for the next probe.
    function probe(HookrCompliance c, uint256 gas) external view {
        (bool listed, bool failed) = c.sanctionStatus{gas: gas}(wallet);
        revert Probe(listed, failed);
    }

    function test_heavySourceCannotBeStarvedIntoFailure() public {
        uint256 flips;
        uint256 listedOk;
        assertGt(registries.length, 8);
        for (uint256 i; i < registries.length; ++i) {
            for (uint256 g = 30_000; g <= 60_000; g += 100) {
                try this.probe(registries[i], g) {}
                catch (bytes memory reason) {
                    if (reason.length != 68 || bytes4(reason) != Probe.selector) continue;
                    bytes memory args = new bytes(64);
                    for (uint256 j; j < 64; ++j) {
                        args[j] = reason[4 + j];
                    }
                    (bool listed, bool failed) = abi.decode(args, (bool, bool));
                    if (!listed && failed) ++flips;
                    else if (listed) ++listedOk;
                }
            }
        }
        assertEq(flips, 0, "a caller gas limit turned a listed answer into sourceFailed");
        assertGt(listedOk, 0);
    }
}
