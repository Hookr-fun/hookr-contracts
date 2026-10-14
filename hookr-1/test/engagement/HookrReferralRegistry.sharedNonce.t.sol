// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrReferralRegistry} from "../../src/interfaces/IHookrReferralRegistry.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

/// @notice I-19: one ordered nonce per payer across every program, and one InvalidSignature error for expiry,
///         wrong nonce and bad signatures. Unfixed (ReferralRepro.t.sol at 877cfb9): program B at nonce 0
///         reverted after A; an authorization that could not land (nonce 1, unregistered code) blocked nonce 2
///         until the payer sent invalidateNonce; expiry returned the same InvalidSignature selector.
///         Now nonces at or above nonces(payer) are single-use in any order, and each failure has its own error.
contract HookrReferralRegistrySharedNonceTest is ReferralSecurityFixture {
    uint256 private constant PK = 0xA11CE;
    address private payer;

    function setUp() public override {
        super.setUp();
        payer = vm.addr(PK);
    }

    function _sign(bytes32 program, bytes32 code, uint256 nonce, uint256 deadline) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(PK, referrals.authorizationDigest(payer, referrer, program, code, nonce, deadline));
        return abi.encodePacked(r, s, v);
    }

    function testParallelAuthorizationsLandInAnyOrder() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory a = _sign(keccak256("A"), bytes32(0), 0, deadline);
        bytes memory b = _sign(keccak256("B"), bytes32(0), 1, deadline);
        bytes memory c = _sign(keccak256("C"), bytes32(0), 2, deadline);
        referrals.registerSigned(payer, referrer, keccak256("C"), bytes32(0), 2, deadline, c);
        assertEq(referrals.nonces(payer), 0); // floor waits for nonce 0
        referrals.registerSigned(payer, referrer, keccak256("A"), bytes32(0), 0, deadline, a);
        assertEq(referrals.nonces(payer), 1);
        referrals.registerSigned(payer, referrer, keccak256("B"), bytes32(0), 1, deadline, b);
        assertEq(referrals.nonces(payer), 3); // advanced past the already-used nonce 2
        assertTrue(referrals.nonceUsed(payer, 2));
        assertFalse(referrals.nonceUsed(payer, 3));
    }

    function testAnAuthorizationThatFailedNoLongerBlocksTheNext() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 unregistered = keccak256("not-yet");
        bytes memory b1 = _sign(keccak256("B"), unregistered, 1, deadline);
        bytes memory c2 = _sign(keccak256("C"), bytes32(0), 2, deadline);
        vm.expectRevert(IHookrReferralRegistry.InvalidReferral.selector);
        referrals.registerSigned(payer, referrer, keccak256("B"), unregistered, 1, deadline, b1);
        assertFalse(referrals.nonceUsed(payer, 1));
        // Unfixed: InvalidSignature until the payer itself sent invalidateNonce(2).
        referrals.registerSigned(payer, referrer, keccak256("C"), bytes32(0), 2, deadline, c2);
        (address bound,,) = referrals.binding(keccak256("C"), payer);
        assertEq(bound, referrer);
        // Once the referrer registers the code, the earlier authorization still lands.
        vm.prank(referrer);
        referrals.registerCode(unregistered);
        referrals.registerSigned(payer, referrer, keccak256("B"), unregistered, 1, deadline, b1);
    }

    function testEachFailureHasItsOwnError() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory a = _sign(keccak256("A"), bytes32(0), 0, deadline);
        vm.expectRevert(IHookrReferralRegistry.InvalidSignature.selector);
        referrals.registerSigned(payer, address(0x3333), keccak256("A"), bytes32(0), 0, deadline, a);
        referrals.registerSigned(payer, referrer, keccak256("A"), bytes32(0), 0, deadline, a);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralRegistry.NonceUnavailable.selector, payer, 0));
        referrals.registerSigned(payer, referrer, keccak256("A"), bytes32(0), 0, deadline, a);
        bytes memory late = _sign(keccak256("L"), bytes32(0), 5, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrReferralRegistry.SignatureExpired.selector, deadline, deadline + 1)
        );
        referrals.registerSigned(payer, referrer, keccak256("L"), bytes32(0), 5, deadline, late);
    }

    function testInvalidateNonceStillCancelsEverythingBelow() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory a = _sign(keccak256("A"), bytes32(0), 7, deadline);
        vm.prank(payer);
        referrals.invalidateNonce(8);
        assertTrue(referrals.nonceUsed(payer, 7));
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralRegistry.NonceUnavailable.selector, payer, 7));
        referrals.registerSigned(payer, referrer, keccak256("A"), bytes32(0), 7, deadline, a);
    }

    /// @dev Independent review (testNonceFloorCanStickOnUsedNonce): invalidateNonce(5) after nonce 5 was used out
    ///      of order left nonces() = 5 with nonceUsed(5) = true, so a sequential signer signed an unusable nonce.
    function testInvalidateSkipsNoncesAlreadyUsed() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        for (uint256 n = 5; n < 8; ++n) {
            bytes32 program = keccak256(abi.encode("P", n));
            referrals.registerSigned(
                payer, referrer, program, bytes32(0), n, deadline, _sign(program, bytes32(0), n, deadline)
            );
        }
        vm.prank(payer);
        referrals.invalidateNonce(5);
        uint256 floor = referrals.nonces(payer);
        assertEq(floor, 8, "1b61b81: 5, a used nonce");
        assertFalse(referrals.nonceUsed(payer, floor));
        referrals.registerSigned(
            payer,
            referrer,
            keccak256("Q"),
            bytes32(0),
            floor,
            deadline,
            _sign(keccak256("Q"), bytes32(0), floor, deadline)
        );
        assertEq(referrals.nonces(payer), 9);
    }

    /// @dev Independent review (testNonceFloorAdvanceGas): after 299 out-of-order uses, using nonce 0 stopped the
    ///      floor at 256, itself used, for 146,619 gas. The word scan reaches 300 across two words.
    function testFloorAdvancesAcrossWordsToAnUnusedNonce() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        for (uint256 i = 1; i < 300; ++i) {
            bytes32 program = keccak256(abi.encode(i));
            referrals.registerSigned(
                payer, referrer, program, bytes32(0), i, deadline, _sign(program, bytes32(0), i, deadline)
            );
        }
        bytes memory s0 = _sign(keccak256("zero"), bytes32(0), 0, deadline);
        uint256 g = gasleft();
        referrals.registerSigned(payer, referrer, keccak256("zero"), bytes32(0), 0, deadline, s0);
        emit log_named_uint(
            "registerSigned gas with a 300-nonce floor advance (1b61b81: 146,619 stopping at 256)", g - gasleft()
        );
        assertEq(referrals.nonces(payer), 300);
        assertFalse(referrals.nonceUsed(payer, 300));
    }

    /// @dev The scan is bounded: past MAX_NONCE_SCAN_WORDS full words it stops at a word boundary (documented),
    ///      and invalidateNonce moves the floor on. Words are filled by storage writes (slot 5 = _usedNonceWords,
    ///      forge inspect storageLayout), checked through nonceUsed.
    function testFloorScanIsBoundedAndInvalidateMovesOn() public {
        uint256 words = referrals.MAX_NONCE_SCAN_WORDS();
        assertEq(words, 16);
        for (uint256 w; w <= words; ++w) {
            // Every nonce of words 0..16 used, except nonce 0 which is signed below.
            vm.store(
                address(referrals), _wordSlot(payer, w), bytes32(w == 0 ? type(uint256).max - 1 : type(uint256).max)
            );
        }
        assertTrue(referrals.nonceUsed(payer, 1));
        assertTrue(referrals.nonceUsed(payer, (words + 1) * 256 - 1));
        assertFalse(referrals.nonceUsed(payer, 0));
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        referrals.registerSigned(
            payer,
            referrer,
            keccak256("zero"),
            bytes32(0),
            0,
            deadline,
            _sign(keccak256("zero"), bytes32(0), 0, deadline)
        );
        // 16 words scanned: the floor stops at the start of word 16, which is itself used.
        assertEq(referrals.nonces(payer), words * 256);
        assertTrue(referrals.nonceUsed(payer, words * 256));
        vm.prank(payer);
        referrals.invalidateNonce(words * 256 + 1);
        assertEq(referrals.nonces(payer), (words + 1) * 256);
        assertFalse(referrals.nonceUsed(payer, (words + 1) * 256));
    }

    function testLastNonceHasNoSuccessor() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 program = keccak256("edge");
        uint256 top = type(uint256).max;
        referrals.registerSigned(
            payer, referrer, program, bytes32(0), top, deadline, _sign(program, bytes32(0), top, deadline)
        );
        vm.prank(payer);
        referrals.invalidateNonce(top);
        // The last nonce of the last word is used and has no successor: the floor stays on it without overflow.
        assertEq(referrals.nonces(payer), top);
        assertTrue(referrals.nonceUsed(payer, top));
    }

    function _wordSlot(address who, uint256 word) private pure returns (bytes32) {
        return keccak256(abi.encode(word, keccak256(abi.encode(who, uint256(5)))));
    }

    function testFuzz_floorIsAlwaysUnusedAfterSequentialAndShuffledUse(uint256 seed) public {
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        uint256 n = 40;
        uint256[] memory order = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            order[i] = i;
        }
        for (uint256 i = n - 1; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }
        for (uint256 i; i < n; ++i) {
            bytes32 program = keccak256(abi.encode("S", order[i]));
            referrals.registerSigned(
                payer, referrer, program, bytes32(0), order[i], deadline, _sign(program, bytes32(0), order[i], deadline)
            );
            uint256 floor = referrals.nonces(payer);
            assertFalse(referrals.nonceUsed(payer, floor));
            for (uint256 k; k < floor; ++k) {
                assertTrue(referrals.nonceUsed(payer, k));
            }
        }
        assertEq(referrals.nonces(payer), n);
    }

    function testFuzz_everyNonceIsSingleUse(uint256 nonce) public {
        nonce = bound(nonce, 0, type(uint256).max);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory a = _sign(keccak256("A"), bytes32(0), nonce, deadline);
        referrals.registerSigned(payer, referrer, keccak256("A"), bytes32(0), nonce, deadline, a);
        assertTrue(referrals.nonceUsed(payer, nonce));
        bytes memory b = _sign(keccak256("B"), bytes32(0), nonce, deadline);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralRegistry.NonceUnavailable.selector, payer, nonce));
        referrals.registerSigned(payer, referrer, keccak256("B"), bytes32(0), nonce, deadline, b);
    }
}
