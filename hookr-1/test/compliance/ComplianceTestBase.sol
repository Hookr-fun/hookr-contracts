// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {HookrCompliance} from "../../src/compliance/HookrCompliance.sol";
import {IHookrCompliance} from "../../src/interfaces/IHookrCompliance.sol";
import {MockSanctionsList} from "../fixtures/MockSanctionsList.sol";

/// @notice Shared deployment and timelock helpers for the compliance suites.
abstract contract ComplianceTestBase is Test {
    uint48 internal constant DELAY = 1 days;
    bytes32 internal constant LIST = keccak256("hookr.list.kyc");

    HookrCompliance internal compliance;
    MockSanctionsList internal source;
    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal officer = makeAddr("officer");
    uint256 internal attesterKey = 0xA11CE;
    address internal attester;

    function setUp() public virtual {
        vm.warp(1_000_000);
        attester = vm.addr(attesterKey);
        compliance = new HookrCompliance(owner, DELAY);
        source = new MockSanctionsList();
        _timelocked(compliance.CREATE_LIST(), abi.encode(LIST));
        vm.prank(owner);
        compliance.createList(LIST);
        _grantAttester(LIST, attester);
        _timelocked(compliance.GRANT_OFFICER(), abi.encode(officer));
        vm.prank(owner);
        compliance.grantOfficer(officer);
        _timelocked(compliance.GRANT_GUARDIAN(), abi.encode(guardian));
        vm.prank(owner);
        compliance.grantGuardian(guardian);
    }

    function _timelocked(bytes32 kind, bytes memory arguments) internal {
        vm.prank(owner);
        compliance.queue(kind, arguments);
        vm.warp(vm.getBlockTimestamp() + DELAY);
    }

    function _grantAttester(bytes32 listId, address who) internal {
        _timelocked(compliance.GRANT_ATTESTER(), abi.encode(listId, who));
        vm.prank(owner);
        compliance.grantAttester(listId, who);
    }

    function _setSource(address src) internal {
        _timelocked(compliance.SET_SANCTIONS_SOURCE(), abi.encode(src));
        vm.prank(owner);
        compliance.setSanctionsSource(src);
    }

    function _attest(address wallet, uint32 tiers) internal {
        vm.prank(attester);
        compliance.attest(LIST, wallet, tiers, uint32(block.timestamp + 30 days));
    }

    function _sanction(address wallet, bool listed) internal {
        address[] memory w = new address[](1);
        w[0] = wallet;
        vm.prank(officer);
        compliance.setSanctioned(w, listed);
    }

    function _check(address wallet, uint32 requireAll, uint32 blockAny)
        internal
        view
        returns (IHookrCompliance.Decision)
    {
        return compliance.check(LIST, wallet, requireAll, blockAny);
    }
}
