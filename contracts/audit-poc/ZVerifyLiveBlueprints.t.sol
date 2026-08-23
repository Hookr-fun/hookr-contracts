// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";

/// @notice Launch from each REAL on-chain blueprint on the LIVE launchpad and see which graduate.
contract ZVerifyLiveBlueprintsTest is Test {
    HookrLaunchpad constant PAD = HookrLaunchpad(payable(0x27Cca38E94E3e77BFde2284325DcDb0Da7323579));
    address alice = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork("robinhood");
        vm.deal(alice, 1000 ether);
    }

    function _launchFromBlueprint(uint32 id) internal returns (address token) {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "BpTest";
        a.symbol = "BPT";
        a.targetRaiseWei = 0.01 ether;
        a.blueprintId = id;
        vm.prank(alice);
        token = PAD.launch{value: PAD.creationFeeWei()}(a);
    }

    function test_LIVE_everyBlueprint_graduationOutcome() public {
        uint256 n = PAD.blueprintsCount();
        uint256 bricked;
        for (uint32 id = 1; id < uint32(n); id++) {
            HookrLaunchpad.Blueprint memory bp = PAD.getBlueprint(id);
            uint256 snap = vm.snapshotState();
            address token = _launchFromBlueprint(id);

            vm.prank(alice);
            try PAD.buy{value: 0.02 ether}(token, 0) {
                assertTrue(PAD.getLaunch(token).graduated);
                emit log_named_string("GRADUATES", bp.name);
            } catch (bytes memory err) {
                assertEq(bytes4(err), HookrHook.BadConfig.selector, "must be the BadConfig path");
                bricked++;
                emit log_named_string("BRICKED  ", bp.name);
                emit log_named_uint("  baseFeePips", bp.params.baseFeePips);
                emit log_named_uint("  maxFeePips ", bp.params.maxFeePips);
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("bricked blueprints", bricked);
        emit log_named_uint("total blueprints  ", n - 1);
        assertGt(bricked, 0);
    }
}
