// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrCompliance} from "../../src/interfaces/IHookrCompliance.sol";
import {ComplianceTestBase} from "./ComplianceTestBase.sol";

/// @notice F-065: any attester on a list could revoke or overwrite every other attester's credentials, so one
///         attester key could halt a list's trading. An attester now revokes only its own credentials (or an empty
///         slot) and cannot overwrite another active issuer's live credential.
contract HookrComplianceAttesterScopeTest is ComplianceTestBase {
    uint256 internal rivalKey = 0xB0B;
    address internal rival;
    address internal alice = makeAddr("alice");

    function setUp() public override {
        super.setUp();
        rival = vm.addr(rivalKey);
        _grantAttester(LIST, rival);
        _attest(alice, 1);
    }

    function _one(address wallet) internal pure returns (address[] memory w) {
        w = new address[](1);
        w[0] = wallet;
    }

    function test_attesterCannotRevokeAnothersCredential() public {
        vm.prank(rival);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.NotIssuer.selector, LIST, alice, attester));
        compliance.revokeCredential(LIST, _one(alice));
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.ALLOW));
        // The issuer can revoke its own; an empty slot can be revoked by any attester.
        vm.prank(attester);
        compliance.revokeCredential(LIST, _one(alice));
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.NO_CREDENTIAL));
        vm.prank(rival);
        compliance.revokeCredential(LIST, _one(makeAddr("fresh")));
    }

    function test_attesterCannotOverwriteAnothersLiveCredential() public {
        vm.prank(rival);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.CredentialHeld.selector, LIST, alice, attester));
        compliance.attest(LIST, alice, 0, uint32(vm.getBlockTimestamp() + 1));
        vm.warp(vm.getBlockTimestamp() + 1);
        IHookrCompliance.Attestation memory a = IHookrCompliance.Attestation({
            listId: LIST,
            wallet: alice,
            tiers: 0,
            expiresAt: uint32(vm.getBlockTimestamp() + 1 days),
            issuedAt: uint32(vm.getBlockTimestamp()),
            deadline: uint32(vm.getBlockTimestamp() + 1 hours)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(rivalKey, compliance.attestationDigest(a));
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.CredentialHeld.selector, LIST, alice, attester));
        compliance.attestBySig(a, rival, abi.encodePacked(r, s, v));
        // Once the credential lapses (expiry or a revoked issuer), another attester may issue one.
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(rival);
        compliance.attest(LIST, alice, 1, uint32(vm.getBlockTimestamp() + 30 days));
        assertEq(compliance.credential(LIST, alice).issuer, rival);
    }
}
