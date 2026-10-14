// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ComplianceTestBase} from "./ComplianceTestBase.sol";
import {HookrCompliance} from "../../src/compliance/HookrCompliance.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {IHookrCompliance} from "../../src/interfaces/IHookrCompliance.sol";
import {MockSanctionsList} from "../fixtures/MockSanctionsList.sol";

/// @notice ERC-1271 signer that approves one digest.
contract Mock1271 {
    bytes32 public approved;

    function approve(bytes32 digest) external {
        approved = digest;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return digest == approved ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract HookrComplianceTest is ComplianceTestBase {
    address internal alice = makeAddr("alice");

    // ------------------------------------------------------------ identity

    function test_releaseAndDomain() public {
        assertEq(compliance.releaseId(), 1);
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifying,
            bytes32 salt,
            uint256[] memory ext
        ) = compliance.eip712Domain();
        assertEq(fields, hex"0d");
        assertEq(name, "HookrCompliance");
        assertEq(bytes(version).length, 0);
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(compliance));
        assertEq(salt, bytes32(0));
        assertEq(ext.length, 0);
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                keccak256("HookrCompliance"),
                block.chainid,
                address(compliance)
            )
        );
        assertEq(compliance.DOMAIN_SEPARATOR(), expected);
    }

    function test_domainSeparatorNotCached() public {
        bytes32 codeHash = address(compliance).codehash;
        bytes32 before = compliance.DOMAIN_SEPARATOR();
        vm.chainId(4663);
        assertEq(address(compliance).codehash, codeHash);
        assertTrue(compliance.DOMAIN_SEPARATOR() != before);
        HookrCompliance other = new HookrCompliance(owner, DELAY);
        vm.chainId(1);
        HookrCompliance third = new HookrCompliance(owner, DELAY);
        assertEq(address(other).codehash, address(third).codehash);
    }

    // ------------------------------------------------------------ decision order (§8.5)

    function test_checkDecisionOrder() public {
        uint32 tiers = 0x3;
        // NO_CREDENTIAL
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.NO_CREDENTIAL));
        _attest(alice, tiers);
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.ALLOW));
        // MISSING_TIERS, BLOCKED_TIERS
        assertEq(uint8(_check(alice, 0x4, 0)), uint8(IHookrCompliance.Decision.MISSING_TIERS));
        assertEq(uint8(_check(alice, 0x1, 0x2)), uint8(IHookrCompliance.Decision.BLOCKED_TIERS));
        // UNKNOWN_LIST and sanctions-only mode
        assertEq(uint8(compliance.check(keccak256("nope"), alice, 0, 0)), uint8(IHookrCompliance.Decision.UNKNOWN_LIST));
        assertEq(uint8(compliance.check(bytes32(0), makeAddr("nobody"), 0, 0)), uint8(IHookrCompliance.Decision.ALLOW));
        // LIST_SUSPENDED beats credential checks
        vm.prank(guardian);
        compliance.suspendList(LIST);
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.LIST_SUSPENDED));
        // SANCTIONED beats everything
        _sanction(alice, true);
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.SANCTIONED));
        assertEq(uint8(compliance.check(bytes32(0), alice, 0, 0)), uint8(IHookrCompliance.Decision.SANCTIONED));
    }

    function test_checkExpiredAndRevoked() public {
        _attest(alice, 1);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.EXPIRED));
        _attest(alice, 1);
        address[] memory w = new address[](1);
        w[0] = alice;
        vm.prank(attester);
        compliance.revokeCredential(LIST, w);
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.NO_CREDENTIAL));
    }

    /// A revocation suspends an attester's credentials; a re-grant restores them; only the timelocked
    /// VOID_CREDENTIALS voids them for good.
    function test_attesterRevokeSuspendsAndVoidIsTimelocked() public {
        _attest(alice, 1);
        vm.prank(guardian);
        compliance.revokeAttester(LIST, attester);
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.ISSUER_REVOKED));
        vm.warp(vm.getBlockTimestamp() + 1);
        _grantAttester(LIST, attester);
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.ALLOW));
        _timelocked(compliance.VOID_CREDENTIALS(), abi.encode(LIST, attester));
        vm.prank(owner);
        compliance.voidCredentials(LIST, attester);
        assertEq(compliance.validFrom(LIST, attester), uint32(block.timestamp));
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.ISSUER_REVOKED));
        _attest(alice, 1);
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.ALLOW));
    }

    // ------------------------------------------------------------ external source (§8.5 step 2)

    function test_sourceModes() public {
        _setSource(address(source));
        _attest(alice, 1);
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.ALLOW));
        source.setListed(alice, true);
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.SANCTIONED));
        (bool listed, bool failed) = compliance.sanctionStatus(alice);
        assertTrue(listed && !failed);
        source.setListed(alice, false);
        MockSanctionsList.Mode[4] memory bad = [
            MockSanctionsList.Mode.REVERT,
            MockSanctionsList.Mode.OOG,
            MockSanctionsList.Mode.WIDE,
            MockSanctionsList.Mode.TWO
        ];
        for (uint256 i; i < bad.length; ++i) {
            source.setMode(bad[i]);
            assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.SOURCE_FAILED));
            (listed, failed) = compliance.sanctionStatus(alice);
            assertTrue(!listed && failed);
            assertTrue(compliance.isSanctioned(alice));
            assertFalse(compliance.isSanctionedLocal(alice));
        }
        vm.prank(guardian);
        compliance.clearSanctionsSource();
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.ALLOW));
    }

    function test_sourceRequiresCode() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotAContract.selector, alice));
        compliance.setSanctionsSource(alice);
    }

    function test_sourceStarvationReverts() public {
        _setSource(address(source));
        vm.expectRevert();
        compliance.check{gas: 25_000}(LIST, alice, 0, 0);
    }

    // ------------------------------------------------------------ governance

    function test_grantsAreTimelocked() public {
        address o2 = makeAddr("o2");
        vm.prank(owner);
        vm.expectRevert();
        compliance.grantOfficer(o2);
        bytes32 kind = compliance.GRANT_OFFICER();
        vm.prank(owner);
        bytes32 op = compliance.queue(kind, abi.encode(o2));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, uint48(block.timestamp + DELAY)));
        compliance.grantOfficer(o2);
        vm.warp(vm.getBlockTimestamp() + DELAY + 14 days + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Expired.selector, op, uint48(block.timestamp - 1)));
        compliance.grantOfficer(o2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, alice));
        compliance.queue(bytes32(0), "");
    }

    function test_immediateRevokesAndRoles() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.NotGuardianOrOwner.selector, alice));
        compliance.revokeOfficer(officer);
        vm.prank(guardian);
        compliance.revokeOfficer(officer);
        assertFalse(compliance.isOfficer(officer));
        address[] memory w = new address[](1);
        w[0] = alice;
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.NotOfficer.selector, officer));
        compliance.setSanctioned(w, true);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, guardian));
        compliance.revokeGuardian(guardian);
        vm.prank(owner);
        compliance.revokeGuardian(guardian);
        assertFalse(compliance.isGuardian(guardian));
        vm.prank(attester);
        compliance.renounceAttester(LIST);
        assertEq(compliance.attesterSince(LIST, attester), 0);
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.NotAttester.selector, LIST, attester));
        compliance.attest(LIST, alice, 1, uint32(block.timestamp + 1 days));
    }

    function test_listSuspendResume() public {
        _attest(alice, 1);
        vm.prank(guardian);
        compliance.suspendList(LIST);
        assertTrue(compliance.list(LIST).suspended);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, guardian));
        compliance.resumeList(LIST);
        _timelocked(compliance.RESUME_LIST(), abi.encode(LIST));
        vm.prank(owner);
        compliance.resumeList(LIST);
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.ALLOW));
    }

    function test_createListRules() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.ListExists.selector, bytes32(0)));
        compliance.createList(bytes32(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.ListExists.selector, LIST));
        compliance.createList(LIST);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.AlreadyAttester.selector, LIST, attester));
        compliance.grantAttester(LIST, attester);
    }

    // ------------------------------------------------------------ attest bounds and batches

    function test_attestBounds() public {
        vm.startPrank(attester);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.InvalidCredential.selector, uint8(1)));
        compliance.attest(LIST, address(0), 1, uint32(block.timestamp + 1));
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.InvalidCredential.selector, uint8(2)));
        compliance.attest(LIST, alice, 1, uint32(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.InvalidCredential.selector, uint8(3)));
        compliance.attest(LIST, alice, 1, uint32(block.timestamp + 401 days));
        address[] memory w = new address[](2);
        uint32[] memory t = new uint32[](1);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.InvalidCredential.selector, uint8(4)));
        compliance.attestBatch(LIST, w, t, uint32(block.timestamp + 1));
        address[] memory big = new address[](201);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.BatchTooLarge.selector, uint256(201), uint256(200)));
        compliance.revokeCredential(LIST, big);
        vm.stopPrank();
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.BatchTooLarge.selector, uint256(201), uint256(200)));
        compliance.setSanctioned(big, true);
    }

    // ------------------------------------------------------------ attestBySig (§8.4)

    function _attestation(uint32 issuedAt) internal view returns (IHookrCompliance.Attestation memory a) {
        a = IHookrCompliance.Attestation({
            listId: LIST,
            wallet: alice,
            tiers: 1,
            expiresAt: uint32(block.timestamp + 10 days),
            issuedAt: issuedAt,
            deadline: uint32(block.timestamp + 1 hours)
        });
    }

    function _sign(uint256 key, IHookrCompliance.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, compliance.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function test_attestBySigEoa() public {
        IHookrCompliance.Attestation memory a = _attestation(uint32(block.timestamp));
        bytes memory sig = _sign(attesterKey, a);
        compliance.attestBySig(a, attester, sig);
        assertEq(uint8(_check(alice, 1, 0)), uint8(IHookrCompliance.Decision.ALLOW));
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.StaleAttestation.selector, a.issuedAt, a.issuedAt));
        compliance.attestBySig(a, attester, sig);
    }

    function test_attestBySigRejections() public {
        IHookrCompliance.Attestation memory a = _attestation(uint32(block.timestamp));
        bytes memory sig = _sign(attesterKey, a);
        // wrong signer
        bytes memory wrong = _sign(0xB0B, a);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.InvalidSignature.selector, attester));
        compliance.attestBySig(a, attester, wrong);
        // high-s malleated signature
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, compliance.attestationDigest(a));
        bytes32 highS =
            bytes32(uint256(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141) - uint256(s));
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.InvalidSignature.selector, attester));
        compliance.attestBySig(a, attester, abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27)));
        // wrong chain
        vm.chainId(4663);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.InvalidSignature.selector, attester));
        compliance.attestBySig(a, attester, sig);
        vm.chainId(31337);
        // future issuedAt
        IHookrCompliance.Attestation memory f = _attestation(uint32(block.timestamp + 1));
        bytes memory fsig = _sign(attesterKey, f);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.FutureIssuedAt.selector, f.issuedAt, block.timestamp));
        compliance.attestBySig(f, attester, fsig);
        // expired deadline
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrCompliance.AttestationExpired.selector, a.deadline, block.timestamp)
        );
        compliance.attestBySig(a, attester, sig);
    }

    /// A revoked attester's signatures are refused; after a re-grant its earlier signatures count like its earlier
    /// credentials, and after VOID_CREDENTIALS every signature issued before the void is stale.
    function test_attestBySigRevokedAndPreGrant() public {
        IHookrCompliance.Attestation memory a = _attestation(uint32(block.timestamp));
        bytes memory sig = _sign(attesterKey, a);
        vm.prank(guardian);
        compliance.revokeAttester(LIST, attester);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.NotAttester.selector, LIST, attester));
        compliance.attestBySig(a, attester, sig);
        vm.warp(vm.getBlockTimestamp() + 1);
        _timelocked(compliance.VOID_CREDENTIALS(), abi.encode(LIST, attester));
        vm.prank(owner);
        compliance.voidCredentials(LIST, attester);
        uint32 from = compliance.validFrom(LIST, attester);
        _grantAttester(LIST, attester);
        a.deadline = uint32(vm.getBlockTimestamp() + 1 hours);
        a.expiresAt = uint32(vm.getBlockTimestamp() + 10 days);
        sig = _sign(attesterKey, a);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.StaleAttestation.selector, a.issuedAt, from));
        compliance.attestBySig(a, attester, sig);
        // A signature from before the attester's first grant is stale too.
        uint256 laterKey = 0xB0B;
        address later = vm.addr(laterKey);
        IHookrCompliance.Attestation memory early = _attestation(uint32(vm.getBlockTimestamp()));
        _grantAttester(LIST, later);
        early.deadline = uint32(vm.getBlockTimestamp() + 1 hours);
        early.expiresAt = uint32(vm.getBlockTimestamp() + 10 days);
        bytes memory earlySig = _sign(laterKey, early);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrCompliance.StaleAttestation.selector, early.issuedAt, compliance.validFrom(LIST, later)
            )
        );
        compliance.attestBySig(early, later, earlySig);
    }

    function test_attestBySigCannotRollBackRevocation() public {
        IHookrCompliance.Attestation memory a = _attestation(uint32(block.timestamp));
        bytes memory sig = _sign(attesterKey, a);
        address[] memory w = new address[](1);
        w[0] = alice;
        vm.prank(attester);
        compliance.revokeCredential(LIST, w);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.StaleAttestation.selector, a.issuedAt, a.issuedAt));
        compliance.attestBySig(a, attester, sig);
    }

    function test_attestBySigErc1271() public {
        Mock1271 wallet = new Mock1271();
        _grantAttester(LIST, address(wallet));
        IHookrCompliance.Attestation memory a = _attestation(uint32(block.timestamp));
        wallet.approve(compliance.attestationDigest(a));
        compliance.attestBySig(a, address(wallet), hex"");
        assertEq(compliance.credential(LIST, alice).issuer, address(wallet));
    }
}
