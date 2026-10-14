// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {IHookrReferralRegistry} from "../../src/interfaces/IHookrReferralRegistry.sol";
import {HookrReferralDistributor} from "../../src/engagement/HookrReferralDistributor.sol";
import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";

contract Referral1271Wallet {
    address private immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        (bytes32 r, bytes32 s, uint8 v) = abi.decode(signature, (bytes32, bytes32, uint8));
        return ecrecover(digest, v, r, s) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract RejectReferralCash {
    receive() external payable {
        revert();
    }
}

contract HookrReferralsTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    HookrReferralRegistry private referrals;
    HookrReferralDistributor private distributor;
    PoolKey private key;
    address private referrer = address(0x2222);
    bytes32 private constant COVERAGE = keccak256("pinned complete trade evidence");
    bytes32 private constant COLLECTIONS = keccak256("actual collected cash reconciled once");

    function setUp() public {
        _setUpPeriphery();
        (, key,,) = _launch(true, false);
        referrals = new HookrReferralRegistry();
        distributor = new HookrReferralDistributor(address(referrals), address(registry), address(this));
        tokenA.approve(address(distributor), type(uint256).max);
        tokenB.approve(address(distributor), type(uint256).max);
    }

    function testDirectReferralIsOneLevelImmutableAndProspective() public {
        bytes32 programKey = keccak256("program");
        bytes32 code = keccak256("referrer-code");
        vm.prank(referrer);
        referrals.registerCode(code);
        vm.prank(trader);
        referrals.register(programKey, referrer, code);
        assertFalse(referrals.eligible(programKey, trader, referrer, uint64(vm.getBlockNumber())));
        vm.roll(vm.getBlockNumber() + 1);
        assertTrue(referrals.eligible(programKey, trader, referrer, uint64(vm.getBlockNumber())));
        vm.prank(trader);
        vm.expectRevert(IHookrReferralRegistry.InvalidReferral.selector);
        referrals.register(programKey, address(0x3333), bytes32(0));
        vm.prank(trader);
        vm.expectRevert(IHookrReferralRegistry.InvalidReferral.selector);
        referrals.register(keccak256("another"), trader, bytes32(0));
    }

    function testReferralClockRejectsRpcHeightAboveEvmParentClock() public {
        vm.roll(100);
        bytes32 key_ = keccak256("clock-aware program");
        vm.prank(trader);
        referrals.register(key_, referrer, bytes32(0));
        assertEq(referrals.contractBlockNumber(), 100);
        assertFalse(referrals.eligible(key_, trader, referrer, 1_000_000));
        assertFalse(referrals.eligible(key_, trader, referrer, 100));
        vm.roll(101);
        assertTrue(referrals.eligible(key_, trader, referrer, 101));
        assertFalse(referrals.eligible(key_, trader, referrer, 1_000_001));
    }

    function testSignedReferralBindsDomainPayerCodeAndNonce() public {
        uint256 pk = 0x12345;
        address payer = vm.addr(pk);
        bytes32 programKey = keccak256("program");
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = referrals.authorizationDigest(payer, referrer, programKey, bytes32(0), 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        vm.expectRevert(IHookrReferralRegistry.InvalidSignature.selector);
        referrals.registerSigned(payer, address(0x3333), programKey, bytes32(0), 0, deadline, signature);
        referrals.registerSigned(payer, referrer, programKey, bytes32(0), 0, deadline, signature);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralRegistry.NonceUnavailable.selector, payer, 0));
        referrals.registerSigned(payer, referrer, programKey, bytes32(0), 0, deadline, signature);
        assertEq(referrals.nonces(payer), 1);
        assertTrue(referrals.nonceUsed(payer, 0));
    }

    function testReferralSignatureCannotReplayAcrossRegistries() public {
        uint256 pk = 0x12345;
        address payer = vm.addr(pk);
        bytes32 programKey = keccak256("program");
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, referrals.authorizationDigest(payer, referrer, programKey, bytes32(0), 0, deadline));
        HookrReferralRegistry other = new HookrReferralRegistry();
        vm.expectRevert(IHookrReferralRegistry.InvalidSignature.selector);
        other.registerSigned(payer, referrer, programKey, bytes32(0), 0, deadline, abi.encodePacked(r, s, v));
    }

    function testContractWalletSignatureAndNonceInvalidation() public {
        uint256 pk = 0x12345;
        Referral1271Wallet wallet = new Referral1271Wallet(vm.addr(pk));
        bytes32 programKey = keccak256("program");
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, referrals.authorizationDigest(address(wallet), referrer, programKey, bytes32(0), 0, deadline));
        referrals.registerSigned(address(wallet), referrer, programKey, bytes32(0), 0, deadline, abi.encode(r, s, v));
        assertEq(referrals.nonces(address(wallet)), 1);
        vm.prank(trader);
        referrals.invalidateNonce(10);
        assertEq(referrals.nonces(trader), 10);
    }

    function testExactFeesDetermineCommissionAndCashback() public {
        IHookrReferralDistributor.Terms memory t = _terms(key);
        uint256 id = distributor.createCampaign(t);
        uint64 first = _enroll(id, trader, referrer);
        vm.warp(t.end);
        bytes32 leaf = _leaf(id, 0, trader, referrer, first, 1000, COVERAGE, COLLECTIONS);
        distributor.proposeDay(id, 0, leaf, 1000, COVERAGE, COLLECTIONS);
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        distributor.finalizeDay(id, 0);
        distributor.creditDay(id, 0, trader, referrer, first, 1000, new bytes32[](0));
        assertEq(distributor.claimable(t.currency, referrer), 200);
        assertEq(distributor.claimable(t.currency, trader), 100);
        vm.expectRevert(IHookrReferralDistributor.AlreadyClaimed.selector);
        distributor.creditDay(id, 0, trader, referrer, first, 1000, new bytes32[](0));
        uint256 before_ = IERC20(t.currency).balanceOf(referrer);
        distributor.claim(t.currency, referrer, referrer, 0);
        assertEq(IERC20(t.currency).balanceOf(referrer), before_ + 200);
        distributor.releaseRemainder(id, 0, address(this));
        assertEq(distributor.reservedCash(t.currency), 100);
        distributor.claim(t.currency, trader, trader, 0);
        assertEq(distributor.reservedCash(t.currency), 0);
    }

    function testLateEnrollmentCannotAuthorizeHistoricalFeeLeaf() public {
        IHookrReferralDistributor.Terms memory t = _terms(key);
        uint256 id = distributor.createCampaign(t);
        uint64 first = _enroll(id, trader, referrer) - 1;
        vm.warp(t.end);
        distributor.proposeDay(
            id, 0, _leaf(id, 0, trader, referrer, first, 1000, COVERAGE, COLLECTIONS), 1000, COVERAGE, COLLECTIONS
        );
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        distributor.finalizeDay(id, 0);
        vm.expectRevert(IHookrReferralDistributor.InvalidProof.selector);
        distributor.creditDay(id, 0, trader, referrer, first, 1000, new bytes32[](0));
    }

    function testFeeEvidenceDomainCannotBeChangedWithoutChangingProof() public {
        IHookrReferralDistributor.Terms memory t = _terms(key);
        uint256 id = distributor.createCampaign(t);
        uint64 first = _enroll(id, trader, referrer);
        vm.warp(t.end);
        distributor.proposeDay(
            id,
            0,
            _leaf(id, 0, trader, referrer, first, 1000, COVERAGE, COLLECTIONS),
            1000,
            COVERAGE,
            keccak256("different cash")
        );
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        distributor.finalizeDay(id, 0);
        vm.expectRevert(IHookrReferralDistributor.InvalidProof.selector);
        distributor.creditDay(id, 0, trader, referrer, first, 1000, new bytes32[](0));
    }

    function testCombinedRatesCannotRefundAllProtocolFees() public {
        IHookrReferralDistributor.Terms memory t = _terms(key);
        t.referrerBps = 6000;
        t.cashbackBps = 4000;
        vm.expectRevert(IHookrReferralDistributor.InvalidCampaign.selector);
        distributor.createCampaign(t);
    }

    function testInsufficientFundingOrOversizedAllocationFailsClosed() public {
        IHookrReferralDistributor.Terms memory t = _terms(key);
        IERC20(t.currency).approve(address(distributor), 0);
        vm.expectRevert();
        distributor.createCampaign(t);
        IERC20(t.currency).approve(address(distributor), type(uint256).max);
        uint256 id = distributor.createCampaign(t);
        vm.warp(t.end);
        vm.expectRevert(IHookrReferralDistributor.BudgetExceeded.selector);
        distributor.proposeDay(id, 0, keccak256("root"), 10_000, COVERAGE, COLLECTIONS);
    }

    function testWalletFeeCapAndUnclaimedCashCannotBeSwept() public {
        IHookrReferralDistributor.Terms memory t = _terms(key);
        t.walletFeeCap = 500;
        uint256 id = distributor.createCampaign(t);
        uint64 first = _enroll(id, trader, referrer);
        vm.warp(t.end);
        distributor.proposeDay(
            id, 0, _leaf(id, 0, trader, referrer, first, 1000, COVERAGE, COLLECTIONS), 1000, COVERAGE, COLLECTIONS
        );
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        distributor.finalizeDay(id, 0);
        vm.expectRevert(IHookrReferralDistributor.InvalidProof.selector);
        distributor.creditDay(id, 0, trader, referrer, first, 1000, new bytes32[](0));
        // Only cash the uncreditable leaf can never earn is returned; its 300 maximum stays reserved.
        assertEq(distributor.releaseRemainder(id, 0, address(this)), 700);
        assertEq(distributor.reservedCash(t.currency), 300);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.NothingToRelease.selector, id, 0));
        distributor.releaseRemainder(id, 0, address(this));
    }

    function testReviewerVetoIsStickyRestartsDelayAndCannotReplaceFinalizedDay() public {
        IHookrReferralDistributor.Terms memory t = _terms(key);
        uint256 id = distributor.createCampaign(t);
        vm.warp(t.end);
        distributor.proposeDay(id, 0, bytes32(0), 0, COVERAGE, COLLECTIONS);
        vm.prank(royalty);
        distributor.challengeDay(id, 0, keccak256("missing blocks"));
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.finalizeDay(id, 0);
        // Re-proposal restarts the delay but keeps the veto: only reviewer approval of that version finalizes.
        distributor.proposeDay(id, 0, bytes32(0), 0, COVERAGE, COLLECTIONS);
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.finalizeDay(id, 0);
        vm.prank(royalty);
        distributor.approveDay(id, 0, 2);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.proposeDay(id, 0, bytes32(0), 0, COVERAGE, COLLECTIONS);
        distributor.releaseRemainder(id, 0, address(this));
        assertEq(distributor.reservedCash(t.currency), 0);
    }

    function testUnchallengedDayFinalizesAfterDelayOnly() public {
        IHookrReferralDistributor.Terms memory t = _terms(key);
        uint256 id = distributor.createCampaign(t);
        vm.warp(t.end);
        distributor.proposeDay(id, 0, bytes32(0), 0, COVERAGE, COLLECTIONS);
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay - 1);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.finalizeDay(id, 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        distributor.finalizeDay(id, 0);
        assertTrue(distributor.epoch(id, 0).finalized);
    }

    function testNativeFeeCommissionPaysOnlyAuthorizedBeneficiary() public {
        (, PoolKey memory nativeKey,,) = _launch(false, true);
        IHookrReferralDistributor.Terms memory t = _terms(nativeKey);
        uint256 id = distributor.createCampaign{value: t.dailyBudget}(t);
        uint64 first = _enroll(id, trader, referrer);
        vm.warp(t.end);
        distributor.proposeDay(
            id, 0, _leaf(id, 0, trader, referrer, first, 1000, COVERAGE, COLLECTIONS), 1000, COVERAGE, COLLECTIONS
        );
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        distributor.finalizeDay(id, 0);
        distributor.creditDay(id, 0, trader, referrer, first, 1000, new bytes32[](0));
        vm.expectRevert(IHookrReferralDistributor.Unauthorized.selector);
        distributor.claim(address(0), referrer, address(this), 0);
        RejectReferralCash receiver = new RejectReferralCash();
        vm.prank(referrer);
        vm.expectRevert(IHookrReferralDistributor.InexactTransfer.selector);
        distributor.claim(address(0), referrer, address(receiver), 0);
        assertEq(distributor.claimable(address(0), referrer), 200);
        uint256 before_ = referrer.balance;
        distributor.claim(address(0), referrer, referrer, 0);
        assertEq(referrer.balance, before_ + 200);
    }

    function testNativeRemainderRedirectIsCreatorOnlyAndClosesTheDay() public {
        (, PoolKey memory nativeKey,,) = _launch(false, true);
        IHookrReferralDistributor.Terms memory t = _terms(nativeKey);
        uint256 id = distributor.createCampaign{value: t.dailyBudget}(t);
        vm.warp(t.end);
        distributor.proposeDay(id, 0, bytes32(0), 0, COVERAGE, COLLECTIONS);
        vm.prank(royalty);
        distributor.approveDay(id, 0, 1); // reviewer approval finalizes before the window
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.NotCreator.selector, trader));
        distributor.releaseRemainder(id, 0, trader);
        RejectReferralCash receiver = new RejectReferralCash();
        vm.expectRevert(IHookrReferralDistributor.InexactTransfer.selector);
        distributor.releaseRemainder(id, 0, address(receiver));
        uint256 before_ = referrer.balance;
        assertEq(distributor.releaseRemainder(id, 0, referrer), t.dailyBudget);
        assertEq(referrer.balance, before_ + t.dailyBudget);
        assertTrue(distributor.epoch(id, 0).released);
        assertEq(distributor.refunded(id, 0), t.dailyBudget);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.releaseRemainder(id, 0, referrer);
        assertEq(distributor.reservedCash(address(0)), 0);
    }

    function testFuzzExactFeeCommissionHasConservedBacking(uint128 fees) public {
        fees = uint128(bound(fees, 1, 2000));
        IHookrReferralDistributor.Terms memory t = _terms(key);
        uint256 id = distributor.createCampaign(t);
        uint64 first = _enroll(id, trader, referrer);
        vm.warp(t.end);
        distributor.proposeDay(
            id, 0, _leaf(id, 0, trader, referrer, first, fees, COVERAGE, COLLECTIONS), fees, COVERAGE, COLLECTIONS
        );
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        distributor.finalizeDay(id, 0);
        distributor.creditDay(id, 0, trader, referrer, first, fees, new bytes32[](0));
        uint256 awards = distributor.claimable(t.currency, referrer) + distributor.claimable(t.currency, trader);
        assertEq(awards, uint256(fees) * 2000 / 10_000 + uint256(fees) * 1000 / 10_000);
        assertLt(awards, fees);
        distributor.releaseRemainder(id, 0, address(this));
        assertEq(distributor.reservedCash(t.currency), awards);
        assertEq(IERC20(t.currency).balanceOf(address(distributor)), awards);
    }

    function _terms(PoolKey memory pool) private view returns (IHookrReferralDistributor.Terms memory t) {
        HookrTypes.PoolConfig memory c = root.poolConfig(pool.toId());
        t.root = address(root);
        t.rules = address(rules);
        t.poolId = PoolId.unwrap(pool.toId());
        t.configHash = root.policyHash(pool.toId());
        t.currency = Currency.unwrap(c.quote);
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 1 days;
        t.referrerBps = 2000;
        t.cashbackBps = 1000;
        t.dailyBudget = 1000;
        t.walletFeeCap = 2000;
        t.attestor = address(this);
        t.reviewer = royalty;
        t.reviewDelay = distributor.MIN_REVIEW_DELAY();
        t.sourcePolicyHash = keccak256("collected protocol cash only; no principal or LP fee subsidy");
    }

    function _enroll(uint256 id, address payer, address referrer_) private returns (uint64 first) {
        bytes32 programKey = distributor.campaign(id).programKey;
        vm.prank(payer);
        referrals.register(programKey, referrer_, bytes32(0));
        vm.roll(vm.getBlockNumber() + 1);
        first = uint64(vm.getBlockNumber());
    }

    function _leaf(
        uint256 id,
        uint256 day,
        address payer,
        address referrer_,
        uint64 first,
        uint128 fees,
        bytes32 coverage,
        bytes32 collections
    ) private view returns (bytes32) {
        IHookrReferralDistributor.Campaign memory c = distributor.campaign(id);
        uint64 end = distributor.dayEnd(id, day);
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid,
                        address(distributor),
                        id,
                        c.termsHash,
                        day,
                        uint64(end - 1 days),
                        end,
                        coverage,
                        collections,
                        payer,
                        referrer_,
                        first,
                        fees
                    )
                )
            )
        );
    }
}
