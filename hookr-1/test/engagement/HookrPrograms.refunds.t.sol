// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {IHookrMilestoneNFTFactory} from "../../src/interfaces/IHookrMilestoneNFTFactory.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {MockRestrictedToken} from "../mocks/MockRestrictedToken.sol";

/// @notice F-040: refunds paid only `p.creator`, so an issuer blocklist on the creator held unused cash back.
///         F-062: one unclaimable leaf pinned a finalized day's whole cash and Bux remainder.
///         F-064: the milestone collection factory was permissionless.
contract HookrProgramsRefundsTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    HookrPrograms internal programs;
    HookrReferralRegistry internal refs;
    MockRestrictedToken internal usd;
    PoolKey internal key;
    bytes32 internal constant COVERAGE = keccak256("complete pinned daily coverage");
    bytes32 internal constant EVIDENCE = keccak256("evidence");
    address internal creator = address(0xC0FFEE);
    address internal attestor = address(0xA77E);
    address internal reviewer = address(0xBEEF);
    address internal vault = address(0x5AFE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        _setUpPeriphery();
        (, key,,) = _launch(true, false);
        refs = new HookrReferralRegistry();
        // An issuer dollar whose block list reverts "restricted".
        usd = new MockRestrictedToken("Regulated USD", "RUSD", 1e30, "restricted");
        usd.transfer(creator, 1e24);
        programs = new HookrPrograms(manager, address(router), address(this), 1_000_000e18, address(refs));
        vm.prank(creator);
        usd.approve(address(programs), type(uint256).max);
    }

    function _terms(uint256 numDays, uint128 dailyPts, uint128 dailyCash) internal view returns (P.Terms memory t) {
        t.mode = P.Mode.DailySwap;
        t.globalBux = true;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + uint64(numDays * 1 days);
        t.pointBudget = uint128(dailyPts * numDays);
        t.walletPointCap = t.pointBudget;
        t.dailyPointBudget = dailyPts;
        t.rewardToken = address(usd);
        t.cashBudget = uint128(dailyCash * numDays);
        t.walletCashCap = t.cashBudget;
        t.dailyCashBudget = dailyCash;
        t.attestor = attestor;
        t.reviewer = reviewer;
        t.reviewDelay = 6 days;
        t.sourcePolicyHash = keccak256("explicit normalized scope units");
        t.name = "Daily";
        t.metadataURI = "ipfs://terms";
        t.pointDecimals = 18;
    }

    /// @dev Proposes a Bux program's approval and executes it once BUX_APPROVAL_DELAY has passed.
    function _approveBux(uint256 id) internal {
        programs.proposeBuxProgram(id);
        vm.warp(vm.getBlockTimestamp() + programs.BUX_APPROVAL_DELAY());
        programs.approveBuxProgram(id);
    }

    function _create(P.Terms memory t) internal returns (uint256 id) {
        P.Scope[] memory sources = new P.Scope[](1);
        HookrTypes.PoolConfig memory c = root.poolConfig(key.toId());
        sources[0] = P.Scope(
            address(root),
            PoolId.unwrap(key.toId()),
            root.policyHash(key.toId()),
            Currency.unwrap(c.quote),
            1,
            1e15,
            0,
            0
        );
        P.NFTMetadata memory metadata;
        vm.prank(creator);
        id = programs.createProgram(t, sources, new P.Milestone[](0), metadata);
    }

    function _leaf(uint256 id, uint256 day, address user, uint128 weight) internal view returns (bytes32) {
        uint64 end = programs.dayEnd(id, day);
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid,
                        address(programs),
                        id,
                        programs.program(id).termsHash,
                        day,
                        uint64(end - 1 days),
                        end,
                        COVERAGE,
                        user,
                        weight
                    )
                )
            )
        );
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proposeAndFinalize(uint256 id, uint256 day, bytes32 root_, uint256 total) internal {
        vm.prank(attestor);
        programs.proposeDay(id, day, root_, total, COVERAGE, EVIDENCE);
        vm.warp(vm.getBlockTimestamp() + 6 days);
        programs.finalizeDay(id, day);
    }

    // ------------------------------------------------------------ F-040

    function test_blocklistedCreatorRedirectsRefunds() public {
        P.Terms memory t = _terms(1, 1_000e18, 100e18);
        uint256 id = _create(t);
        _approveBux(id);
        vm.warp(t.end);
        _proposeAndFinalize(id, 0, bytes32(0), 0);
        usd.setBlocked(creator, true);
        vm.expectRevert();
        programs.releaseUnusedCash(id, 0);
        // Only the creator names the recipient.
        vm.prank(vault);
        vm.expectRevert(IHookrPrograms.Unauthorized.selector);
        programs.setRefundRecipient(id, vault);
        vm.prank(creator);
        vm.expectRevert(IHookrPrograms.Unauthorized.selector);
        programs.setRefundRecipient(id, address(programs));
        vm.prank(creator);
        programs.setRefundRecipient(id, vault);
        assertEq(programs.refundRecipient(id), vault);
        assertEq(programs.releaseUnusedCash(id, 0), 100e18); // anyone may trigger
        assertEq(usd.balanceOf(vault), 100e18);
        assertEq(programs.reservedCash(address(usd)), 0);
    }

    /// Zero restores the creator; unapproved-Bux refunds follow the same recipient.
    function test_refundUnapprovedBuxFollowsRecipient() public {
        P.Terms memory t = _terms(1, 1_000e18, 100e18);
        uint256 id = _create(t);
        vm.prank(creator);
        programs.setRefundRecipient(id, vault);
        vm.prank(creator);
        programs.setRefundRecipient(id, address(0));
        vm.prank(creator);
        programs.setRefundRecipient(id, vault);
        usd.setBlocked(creator, true);
        vm.warp(t.start);
        programs.refundUnapprovedBux(id);
        assertEq(usd.balanceOf(vault), 100e18);
    }

    // ------------------------------------------------------------ F-062

    /// Only a finalized day that is still open can release early; a closed day uses releaseUnusedCash.
    function test_releaseRemainderOnlyForFinalizedOpenDays() public {
        P.Terms memory t = _terms(2, 1_000e18, 100e18);
        uint256 id = _create(t);
        _approveBux(id);
        vm.warp(t.end);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.releaseRemainder(id, 0);
        _proposeAndFinalize(id, 1, bytes32(0), 0); // zero weight closes at finalization
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.releaseRemainder(id, 1);
        assertEq(programs.releaseUnusedCash(id, 1), 100e18);
    }

    function test_releaseRemainderReturnsUnowedCashAndBux() public {
        P.Terms memory t = _terms(1, 1_000e18, 100e18);
        uint256 id = _create(t);
        _approveBux(id);
        vm.warp(t.end);
        bytes32 a = _leaf(id, 0, alice, 3);
        bytes32 b = _leaf(id, 0, bob, 1);
        _proposeAndFinalize(id, 0, _pair(a, b), 4);
        bytes32[] memory proof = new bytes32[](1);
        vm.expectRevert(IHookrPrograms.NothingToClaim.selector);
        programs.releaseRemainder(id, 0);
        // alice claims 3/4; the creator's refund does not wait for bob.
        proof[0] = b;
        programs.claimDay(id, 0, alice, 3, proof);
        assertEq(programs.claimableCash(id, alice), 75e18);
        vm.expectRevert(IHookrPrograms.NothingToClaim.selector); // bob's 1/4 is exactly the rest
        programs.releaseRemainder(id, 0);
        // With bob's leaf never claimed, a per-wallet cap that clipped alice's award used to pin the whole
        // remainder; now only bob's maximum stays.
        P.Terms memory c = _terms(1, 1_000e18, 100e18);
        c.walletCashCap = 10e18;
        c.walletPointCap = 100e18;
        uint256 capped = _create(c);
        _approveBux(capped);
        vm.warp(c.end);
        a = _leaf(capped, 0, alice, 3);
        b = _leaf(capped, 0, bob, 1);
        _proposeAndFinalize(capped, 0, _pair(a, b), 4);
        proof[0] = b;
        programs.claimDay(capped, 0, alice, 3, proof);
        assertEq(programs.claimableCash(capped, alice), 10e18);
        uint256 reservedBefore = programs.buxReserved();
        uint256 creatorBefore = usd.balanceOf(creator);
        (uint256 cash, uint256 bux) = programs.releaseRemainder(capped, 0);
        // 100 - 10 claimed - 25 owable to bob = 65 cash; 1000 - 100 - 250 = 650 Bux.
        assertEq(cash, 65e18);
        assertEq(bux, 650e18);
        assertEq(usd.balanceOf(creator) - creatorBefore, 65e18);
        assertEq(reservedBefore - programs.buxReserved(), 650e18);
        (uint256 rc, uint256 rb) = programs.released(capped, 0);
        assertEq(rc, 65e18);
        assertEq(rb, 650e18);
        // bob still claims his capped share; closing returns exactly the rest, and nothing twice.
        proof[0] = a;
        programs.claimDay(capped, 0, bob, 1, proof);
        assertEq(programs.claimableCash(capped, bob), 10e18);
        assertEq(programs.releaseUnusedCash(capped, 0), 100e18 - 10e18 - 10e18 - 65e18);
        assertEq(programs.program(capped).cashRefunded, 80e18);
        assertEq(programs.buxReserved(), programs.buxIssued() + 250e18); // only bob's share of the first program
        assertEq(
            programs.reservedCash(address(usd)),
            programs.claimableCash(id, alice) + 25e18 + programs.claimableCash(capped, alice)
                + programs.claimableCash(capped, bob)
        );
    }

    // ------------------------------------------------------------ F-064

    function test_milestoneFactoryOnlyServesPrograms() public {
        IHookrMilestoneNFTFactory factory = programs.nftFactory();
        assertEq(factory.deployer(), address(programs));
        vm.expectRevert(IHookrMilestoneNFTFactory.OnlyDeployer.selector);
        factory.create(10, "Fake", "FAKE", "", false);
    }
}
