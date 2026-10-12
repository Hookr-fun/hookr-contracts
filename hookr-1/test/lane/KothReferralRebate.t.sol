// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrReferralDistributor} from "../../src/engagement/HookrReferralDistributor.sol";
import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {IHookrLaneRules} from "../../src/interfaces/IHookrLaneRules.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {ArbSysKit} from "../kit/ArbSysMock.sol";
import {KothWashFixture} from "./utils/KothWashFixture.sol";

/// @notice Sends one call with an exact gas limit and reports whether it succeeded.
contract GasLimitedCaller {
    function send(address target, uint256 gasLimit, bytes calldata data) external returns (bool ok) {
        (ok,) = target.call{gas: gasLimit}(data);
    }
}

/// @notice A Protocol-fee referral campaign on the release stack, against real pools. On a King of the Pool pool it
///         pays at most half the protocol fee a payer's swaps left with the protocol recipient; the same campaign pays
///         in full on a recapture pool without King of the Pool and on a pool without recapture, and a royalty campaign
///         on the King of the Pool pool pays in full. A creator wash (all the liquidity, an honest leader to displace,
///         the exit on the pool in a later block) is paid for by a 9,999 bps rebate and stays behind at the cap. At the
///         cap, denying the honest leader's prize by the least outbid costs the creator about nothing instead of at
///         least that prize. No gas limit lets a credit skip the read of the pool's mode.
contract KothReferralRebateTest is KothWashFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 internal constant COVERAGE = keccak256("pinned complete trade evidence");
    bytes32 internal constant COLLECTIONS = keccak256("actual collected cash reconciled once");
    uint16 internal constant REFERRER_BPS = 6_000;
    uint16 internal constant CASHBACK_BPS = 3_999;
    /// @dev The washer's second wallet, its referrer.
    address internal secondWallet = address(0x2222);

    HookrReferralRegistry internal referrals;
    HookrReferralDistributor internal distributor;

    function setUp() public override {
        super.setUp();
        referrals = new HookrReferralRegistry();
        distributor = new HookrReferralDistributor(address(referrals), address(registry), address(this));
    }

    function test_creditDay_halvesTheProtocolRebateOnlyOnKingOfThePoolPools() public {
        PoolKey memory recaptureOnly = _openRecapture(ETH);
        PoolKey memory noRecapture = _openStd(ETH);
        assertEq(IHookrLaneRules(address(rules)).recaptureMode(key.toId()), 2);
        assertEq(IHookrLaneRules(address(rules)).recaptureMode(recaptureOnly.toId()), 1);
        assertEq(IHookrLaneRules(address(rules)).recaptureMode(noRecapture.toId()), 0);
        vm.recordLogs();
        _buy(key, ETH, minnow, 1e20);
        uint128 fee = _protocolFees(vm.getRecordedLogs(), key);
        assertEq(fee, 1e18, "the protocol keeps 1% of the buy");
        uint256[] memory ids = new uint256[](4);
        ids[0] = _campaign(key, IHookrReferralDistributor.FeeSource.Protocol);
        ids[1] = _campaign(recaptureOnly, IHookrReferralDistributor.FeeSource.Protocol);
        ids[2] = _campaign(noRecapture, IHookrReferralDistributor.FeeSource.Protocol);
        ids[3] = _campaign(key, IHookrReferralDistributor.FeeSource.CreatorRoyalty);
        uint256[] memory paid = _creditAll(ids, minnow, fee);
        uint256 half = uint256(fee) * 5_000 / 10_000;
        assertEq(paid[0], half * REFERRER_BPS / 9_999 + half * CASHBACK_BPS / 9_999, "half, split 6,000:3,999");
        for (uint256 i = 1; i < 4; ++i) {
            assertEq(paid[i], _nominal(fee), "the full 9,999 bps");
        }
    }

    /// A creator who owns all of a King of the Pool pool's liquidity and outbids an honest leader wins a prize of half
    /// the protocol fee its buy paid, so a rebate of more than the other half pays for the crown. Here the creator
    /// outbids a 100 ETH leader with 200 ETH from its own address, sells back on the pool in a later block and collects
    /// the prize, the released pot and its position after the release window, against closing the epoch without the
    /// wash: it nets -1.25 ETH on a 2 ETH protocol fee, a break-even rebate of 6,250 bps.
    function test_creatorWash_staysBehindAtTheCap() public {
        _fillPotWithUnauthenticatedTraffic(14);
        _buy(key, ETH, minnow, 1e20);
        uint256 id = _campaign(key, IHookrReferralDistributor.FeeSource.Protocol);
        (int256 net, uint128 fee, uint256 prize) = _creatorWashNet(2e20);
        uint256 paid = _creditAll(_one(id), creator, fee)[0];
        uint256 nominal = _nominal(fee);
        console.log("protocol fee the wash paid (wei)", fee);
        console.log("prize (wei)", prize);
        console.log("net vs not washing, no rebate (signed wei):");
        console.logInt(net);
        console.log("break-even rebate (bps)", SafeCast.toUint256(-net) * 10_000 / fee);
        console.log("9,999 bps rebate (wei)", nominal);
        console.log("rebate paid at the cap (wei)", paid);
        assertGt(prize, 0, "the crown pays");
        assertLe(prize * 2, fee, "the prize is at most half the protocol fee");
        assertGt(net + SafeCast.toInt256(nominal), 0, "a 9,999 bps rebate pays for the wash");
        assertLe(paid * 10_000, uint256(fee) * distributor.MAX_KING_OF_THE_POOL_STACKED_BPS());
        assertLt(net + SafeCast.toInt256(paid), 0, "the capped rebate leaves the creator behind");
    }

    /// Without a rebate, a creator who owns all the liquidity and takes an honest leader's crown by the least outbid
    /// pays at least the honest prize to deny it. A rebate at the cap, taken through a second wallet, returns half the
    /// protocol fee the crown cost, which is about the creator's own prize, so the denial costs about nothing and the
    /// campaign's funder pays the difference; it still never pays. Here the creator outbids a 100 ETH leader by
    /// 0.01 ETH from its own address and sells back on the pool in the next block.
    function test_creatorDenial_costsAboutNothingAtTheCap() public {
        _fillPotWithUnauthenticatedTraffic(14);
        uint256 honest = 1e20;
        _buy(key, ETH, minnow, honest);
        (address leader, uint256 honestPrize,) = _recap().pendingPrize(key.toId());
        assertEq(leader, minnow, "the honest buyer leads");
        uint256 id = _campaign(key, IHookrReferralDistributor.FeeSource.Protocol);
        (int256 net, uint128 fee, uint256 prize) = _creatorWashNet(honest + 1e16);
        uint256 paid = _creditAll(_one(id), creator, fee)[0];
        int256 rebated = net + SafeCast.toInt256(paid);
        console.log("honest leader's prize (wei)", honestPrize);
        console.log("protocol fee the crown paid (wei)", fee);
        console.log("creator's prize (wei)", prize);
        console.log("rebate paid at the cap (wei)", paid);
        console.log("net vs not washing, without and with the rebate (signed wei):");
        console.logInt(net);
        console.logInt(rebated);
        assertGe(SafeCast.toUint256(-net), honestPrize, "without a rebate the denial costs at least the honest prize");
        assertLt(rebated, 0, "the capped rebate never pays for the denial");
        assertLt(SafeCast.toUint256(-rebated) * 100, honestPrize, "at the cap the denial costs under 1% of the prize");
    }

    /// A caller who sends creditDay with too little gas for the Rules read, hoping it fails and the credit lands under
    /// the full cap, finds no such limit: every limit either reverts or pays at most half.
    function test_creditDay_starvingTheModeReadNeverLiftsTheCap() public {
        uint128 fee = 1e18;
        uint256 id = _campaign(key, IHookrReferralDistributor.FeeSource.Protocol);
        uint64 first = _readyToCredit(_one(id), minnow, fee);
        bytes memory data =
            abi.encodeCall(distributor.creditDay, (id, 0, minnow, secondWallet, first, fee, new bytes32[](0)));
        GasLimitedCaller caller = new GasLimitedCaller();
        uint256 half = uint256(fee) * 5_000 / 10_000;
        uint256 landed;
        for (uint256 limit = 20_000; limit <= 400_000; limit += 500) {
            uint256 snap = vm.snapshotState();
            if (caller.send(address(distributor), limit, data)) {
                ++landed;
                assertLe(distributor.epoch(id, 0).allocated, half, "a starved credit never pays above half");
            }
            vm.revertToState(snap);
        }
        assertGt(landed, 0, "the credit lands with enough gas");
    }

    /// @dev A 6,000 + 3,999 bps campaign on `pool`'s `source` fee, starting the next UTC day, funded in ETH.
    function _campaign(PoolKey memory pool, IHookrReferralDistributor.FeeSource source) internal returns (uint256) {
        IHookrReferralDistributor.Terms memory t;
        t.root = address(root);
        t.rules = address(rules);
        t.poolId = PoolId.unwrap(pool.toId());
        t.configHash = root.policyHash(pool.toId());
        t.currency = Currency.unwrap(root.poolConfig(pool.toId()).quote);
        t.feeSource = source;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 1 days;
        t.referrerBps = REFERRER_BPS;
        t.cashbackBps = CASHBACK_BPS;
        t.dailyBudget = 1e24;
        t.walletFeeCap = type(uint128).max;
        t.attestor = address(this);
        t.reviewer = royalty;
        t.reviewDelay = distributor.MIN_REVIEW_DELAY();
        t.sourcePolicyHash = keccak256("collected protocol cash only; no principal or LP fee subsidy");
        vm.deal(address(this), address(this).balance + t.dailyBudget);
        return distributor.createCampaign{value: t.dailyBudget}(t);
    }

    /// @dev Binds `payer` to its second wallet under every campaign (all starting the same day), then proposes `fees`
    ///      for `payer` on that day and finalizes each. Returns the payer's first activity block.
    function _readyToCredit(uint256[] memory ids, address payer, uint128 fees) internal returns (uint64 first) {
        vm.startPrank(payer);
        for (uint256 i; i < ids.length; ++i) {
            referrals.register(distributor.campaign(ids[i]).programKey, secondWallet, bytes32(0));
        }
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        first = uint64(vm.getBlockNumber());
        uint256 end = distributor.dayEnd(ids[0], 0);
        if (vm.getBlockTimestamp() < end) vm.warp(end);
        for (uint256 i; i < ids.length; ++i) {
            bytes32 leaf = distributor.feeLeafFor(ids[i], 0, COVERAGE, COLLECTIONS, payer, secondWallet, first, fees);
            distributor.proposeDay(ids[i], 0, leaf, fees, COVERAGE, COLLECTIONS);
        }
        vm.warp(distributor.epoch(ids[0], 0).finalizeAfter);
        for (uint256 i; i < ids.length; ++i) {
            distributor.finalizeDay(ids[i], 0);
        }
    }

    /// @dev Credits `fees` of `payer` on every campaign in order; returns each credit's commission plus cashback.
    function _creditAll(uint256[] memory ids, address payer, uint128 fees) internal returns (uint256[] memory paid) {
        uint64 first = _readyToCredit(ids, payer, fees);
        paid = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            distributor.creditDay(ids[i], 0, payer, secondWallet, first, fees, new bytes32[](0));
            paid[i] = distributor.epoch(ids[i], 0).allocated;
        }
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _nominal(uint128 fees) internal pure returns (uint256) {
        return uint256(fees) * REFERRER_BPS / 10_000 + uint256(fees) * CASHBACK_BPS / 10_000;
    }

    /// @dev The protocol's share in every FeesAllocated of `pool` in `logs`: the fee lots a Protocol-fee campaign
    ///      commissions.
    function _protocolFees(Vm.Log[] memory logs, PoolKey memory pool) internal view returns (uint128 sum) {
        bytes32 id = PoolId.unwrap(pool.toId());
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(rules) || l.topics[0] != IHookrRulesEvents.FeesAllocated.selector) continue;
            if (l.topics[1] != id) continue;
            (uint256 protocolFee,,,,) = abi.decode(l.data, (uint256, uint256, uint256, address, uint256));
            sum += SafeCast.toUint128(protocolFee);
        }
    }

    /// @dev From the current state, the creator washes `x` (an authenticated buy from its own address, then a sale of
    ///      everything it bought on the pool in the next block) and closes; the other path only closes. Returns the
    ///      washed path minus the other in ETH, the subject marked at the pool's price before the wash, with the
    ///      protocol fee the wash paid and the creator's prize. Leaves the chain in the other path's state.
    function _creatorWashNet(uint256 x) internal returns (int256 net, uint128 fee, uint256 prize) {
        (uint64 start,,,) = _hill(key);
        uint128 liquidity = launcher.position(family, 0).liquidity;
        (uint160 sqrtMark,,,) = manager.getSlot0(key.toId());
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        uint256 got = _buy(key, ETH, creator, x);
        (, address leader,,) = _hill(key);
        assertEq(leader, creator, "the creator takes the crown");
        _nextBlock();
        _sell(key, ETH, creator, got);
        fee = _protocolFees(vm.getRecordedLogs(), key);
        vm.warp(uint256(start) + PERIOD);
        (, prize,) = _recap().pendingPrize(key.toId());
        _recap().settleEpoch(key.toId());
        int256 washed = _releaseAndValue(liquidity, sqrtMark);
        vm.revertToState(snap);
        vm.warp(uint256(start) + PERIOD);
        _recap().settleEpoch(key.toId());
        net = washed - _releaseAndValue(liquidity, sqrtMark);
    }

    /// @dev Waits out the release window, moves the pool's accrual to the creator's claims, withdraws the launch
    ///      position and returns the creator's ETH, claims and subject, the subject marked at `sqrtMark`.
    function _releaseAndValue(uint128 liquidity, uint160 sqrtMark) internal returns (int256) {
        ArbSysKit.nextParent(vm, 2 * RELEASE_PARENTS);
        if (_accrued(key) != 0) {
            vm.prank(creator);
            launcher.claimRecapture(family, 0, creator);
        }
        vm.prank(creator);
        launcher.withdraw(family, 0, liquidity, 0, 0, creator, vm.getBlockTimestamp());
        uint256 sub = HookrToken(Currency.unwrap(subject)).balanceOf(creator);
        uint256 marked = FullMath.mulDiv(FullMath.mulDiv(sub, 1 << 96, sqrtMark), 1 << 96, sqrtMark);
        return SafeCast.toInt256(creator.balance + rules.claimable(ETH, creator) + marked);
    }
}
