// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrLaneRules} from "../../src/interfaces/IHookrLaneRules.sol";
import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

/// @notice The referral rebate on a pool whose King of the Pool is on. A prize is at most half the protocol fee its
///         winning buy left with the protocol recipient, so a Protocol-fee rebate above the other half let a washer
///         who owns the pool's liquidity farm the crown at a profit (break-even 6,250 bps on the release stack). The
///         Protocol fee of such a pool is now capped at MAX_KING_OF_THE_POOL_STACKED_BPS across every campaign; every
///         other key keeps MAX_STACKED_BPS. The pool's mode is the Rules' recaptureMode, mocked here on the fixture's
///         pool; the release-stack suite (test/lane/KothReferralRebate.t.sol) reads it from real King of the Pool pools
///         and measures the wash.
contract HookrReferralDistributorKingOfThePoolCapTest is ReferralSecurityFixture {
    using PoolIdLibrary for PoolKey;

    address private alt = address(0xA17);
    address private funder2 = address(0xF00D);
    address private reviewer2 = address(0x4E71);
    uint128 private constant FEES = 1e14;

    /// @dev Makes the fixture pool's Rules answer recaptureMode with `mode`: 2 is King of the Pool.
    function _setMode(uint256 mode) private {
        vm.mockCall(address(rules), abi.encodeCall(IHookrLaneRules.recaptureMode, (key.toId())), abi.encode(mode));
    }

    function _campaignTerms(IHookrReferralDistributor.FeeSource source, uint16 referrerBps, uint16 cashbackBps)
        private
        view
        returns (IHookrReferralDistributor.Terms memory t)
    {
        t = _terms();
        t.dailyBudget = 1e18;
        t.walletFeeCap = type(uint128).max;
        t.feeSource = source;
        t.referrerBps = referrerBps;
        t.cashbackBps = cashbackBps;
    }

    /// @dev Binds `trader` to `alt` under every campaign (all starting the same day), proposes `fees` for each and
    ///      finalizes them. Returns the trader's first activity block.
    function _readyToCredit(uint256[] memory ids, uint128 fees) private returns (uint64 first) {
        vm.startPrank(trader);
        for (uint256 i; i < ids.length; ++i) {
            referrals.register(distributor.campaign(ids[i]).programKey, alt, bytes32(0));
        }
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        first = uint64(vm.getBlockNumber());
        vm.warp(distributor.dayEnd(ids[0], 0));
        for (uint256 i; i < ids.length; ++i) {
            _proposeAs(address(this), ids[i], 0, _leaf(ids[i], 0, trader, alt, first, fees), fees);
        }
        vm.warp(distributor.epoch(ids[0], 0).finalizeAfter);
        for (uint256 i; i < ids.length; ++i) {
            distributor.finalizeDay(ids[i], 0);
        }
    }

    /// @dev Credits `fees` of `trader` on every campaign in order; returns each credit's commission plus cashback.
    function _creditAll(uint256[] memory ids, uint128 fees) private returns (uint256[] memory paid) {
        uint64 first = _readyToCredit(ids, fees);
        paid = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            distributor.creditDay(ids[i], 0, trader, alt, first, fees, _noProof());
            paid[i] = distributor.epoch(ids[i], 0).allocated;
        }
    }

    function _one(uint256 id) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _creditOne(uint256 id, uint128 fees) private returns (uint256) {
        return _creditAll(_one(id), fees)[0];
    }

    function _nominal(uint128 fees, uint16 referrerBps, uint16 cashbackBps) private pure returns (uint256) {
        return uint256(fees) * referrerBps / 10_000 + uint256(fees) * cashbackBps / 10_000;
    }

    function test_creditDay_kingOfThePoolProtocolRebateStopsAtHalf() public {
        assertEq(distributor.MAX_KING_OF_THE_POOL_STACKED_BPS(), 5_000);
        _setMode(2);
        IHookrReferralDistributor.Terms memory t =
            _campaignTerms(IHookrReferralDistributor.FeeSource.Protocol, 6_000, 3_999);
        uint256 id = distributor.createCampaign(t);
        uint256 room = uint256(FEES) * 5_000 / 10_000;
        uint256 commission = room * 6_000 / 9_999;
        uint256 cashback = room * 3_999 / 9_999;
        uint64 first = _readyToCredit(_one(id), FEES);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit IHookrReferralDistributor.StackingCapApplied(
            id, 0, trader, _nominal(FEES, 6_000, 3_999), commission + cashback
        );
        distributor.creditDay(id, 0, trader, alt, first, FEES, _noProof());
        assertEq(distributor.epoch(id, 0).allocated, commission + cashback);
        assertEq(distributor.claimable(t.currency, alt), commission);
        assertEq(distributor.claimable(t.currency, trader), cashback);
        assertLe((commission + cashback) * 10_000, uint256(FEES) * distributor.MAX_KING_OF_THE_POOL_STACKED_BPS());
        (uint256 basis, uint256 paid) =
            distributor.stackedRebate(t.poolId, t.feeSource, uint256(t.start) / 1 days, trader);
        assertEq(basis, FEES);
        assertEq(paid, commission + cashback);
        // The capped share returns to the creator with the rest of the day's budget.
        assertEq(distributor.releaseRemainder(id, 0, address(this)), t.dailyBudget - commission - cashback);
        assertTrue(distributor.epoch(id, 0).released);
    }

    /// @dev The same campaign on a pool without King of the Pool: recapture only (mode 1), or no recapture (mode 0,
    ///      the fixture pool's real answer).
    function test_creditDay_otherPoolsKeepTheFullRebate() public {
        uint256 nominal = _nominal(FEES, 6_000, 3_999);
        for (uint256 mode; mode < 2; ++mode) {
            uint256 snap = vm.snapshotState();
            if (mode == 1) _setMode(1);
            assertEq(IHookrLaneRules(address(rules)).recaptureMode(key.toId()), mode);
            uint256 id =
                distributor.createCampaign(_campaignTerms(IHookrReferralDistributor.FeeSource.Protocol, 6_000, 3_999));
            assertEq(_creditOne(id, FEES), nominal);
            vm.revertToState(snap);
        }
    }

    /// @dev A royalty campaign returns its own creator's royalty, which no prize bound counts: unchanged.
    function test_creditDay_kingOfThePoolRoyaltyRebateUnchanged() public {
        _setMode(2);
        uint256 id = distributor.createCampaign(
            _campaignTerms(IHookrReferralDistributor.FeeSource.CreatorRoyalty, 6_000, 3_999)
        );
        assertEq(_creditOne(id, FEES), _nominal(FEES, 6_000, 3_999));
    }

    /// @dev Two campaigns on the same payer's fees share the half: the second pays only what the first left.
    function test_creditDay_kingOfThePoolCapIsSharedAcrossCampaigns() public {
        _setMode(2);
        IHookrReferralDistributor.Terms memory t =
            _campaignTerms(IHookrReferralDistributor.FeeSource.Protocol, 3_000, 0);
        uint256[] memory ids = new uint256[](2);
        ids[0] = distributor.createCampaign(t);
        t.referrerBps = 6_000;
        t.cashbackBps = 3_999;
        t.reviewer = reviewer2;
        ids[1] = _createAs(funder2, t);
        uint256[] memory paid = _creditAll(ids, FEES);
        uint256 room = uint256(FEES) * 5_000 / 10_000 - uint256(FEES) * 3_000 / 10_000;
        assertEq(paid[0], uint256(FEES) * 3_000 / 10_000);
        assertEq(paid[1], room * 6_000 / 9_999 + room * 3_999 / 9_999);
        assertLe((paid[0] + paid[1]) * 10_000, uint256(FEES) * 5_000);
    }

    /// @dev Rules that cannot answer recaptureMode, or answer it in another shape, run no King of the Pool (the root
    ///      opened no lane for them), so their campaigns keep the full cap, as before.
    function test_creditDay_unreadableModeKeepsTheFullCap() public {
        uint256 nominal = _nominal(FEES, 6_000, 3_999);
        bytes memory read = abi.encodeCall(IHookrLaneRules.recaptureMode, (key.toId()));
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            if (i == 0) vm.mockCallRevert(address(rules), read, "");
            else vm.mockCall(address(rules), read, abi.encodePacked(uint8(2)));
            uint256 id =
                distributor.createCampaign(_campaignTerms(IHookrReferralDistributor.FeeSource.Protocol, 6_000, 3_999));
            assertEq(_creditOne(id, FEES), nominal);
            vm.revertToState(snap);
        }
    }

    function testFuzz_creditDay_kingOfThePoolRebateNeverAboveHalf(uint16 referrerBps, uint16 cashbackBps, uint128 fees)
        public
    {
        referrerBps = uint16(bound(referrerBps, 1, 9_998));
        cashbackBps = uint16(bound(cashbackBps, 0, 9_999 - referrerBps));
        fees = uint128(bound(fees, 1, 1e18));
        _setMode(2);
        uint256 id = distributor.createCampaign(
            _campaignTerms(IHookrReferralDistributor.FeeSource.Protocol, referrerBps, cashbackBps)
        );
        uint256 paid = _creditOne(id, fees);
        uint256 nominal = _nominal(fees, referrerBps, cashbackBps);
        assertLe(paid * 10_000, uint256(fees) * 5_000);
        if (nominal * 10_000 <= uint256(fees) * 5_000) assertEq(paid, nominal);
    }
}
