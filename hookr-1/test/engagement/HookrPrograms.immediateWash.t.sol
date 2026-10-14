// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrProgramValidator} from "../../src/interfaces/IHookrProgramValidator.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";

/// L-04: anyone could take a creator's whole Immediate cash budget and every milestone NFT by wash trading an
/// exact-output buy against a self-owned JIT LP position, because Immediate cash was paid on the raw quote fill.
///
/// Before the fix (base b7aeae64, ImmediateWashPoC; fixture pool 0.3% LP fee, 20 round trips of 1e22):
///   test_C 0.1% cash: +388.1e18 net on 400.04e18 cash (trade+LP cost 11.9e18);
///   test_D 0.02% cash: +68.1e18 net on 80.0e18 cash;
///   test_F five Sybil wallets drained a 1,000e18 budget past a 200e18 wallet cap (+970.2e18 net), took 15/15
///     milestone NFT reservations, and the creator's refund after end was 0.
/// Fix (root cause: an unreviewed raw fill is payer-recoverable): Immediate programs may back creator points only.
/// Cash, global Bux and milestone NFTs require a reviewed daily allocation.
contract HookrProgramsImmediateWashTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    HookrPrograms programs;
    PoolKey key;
    HookrToken subject;
    IERC20 quoteT;
    IERC20 subjT;
    Currency quote;
    PoolModifyLiquidityTest lp;
    address creator = address(0xC0FFEE);
    address lpOwner = address(0x1111);

    function setUp() public {
        _setUpPeriphery();
        (, key, subject, quote) = _launch(true, false);
        quoteT = IERC20(Currency.unwrap(quote));
        subjT = IERC20(address(subject));
        programs =
            new HookrPrograms(manager, address(router), address(this), 1e30, address(new HookrReferralRegistry()));
        lp = new PoolModifyLiquidityTest(manager);
        quoteT.transfer(creator, 1e26);
        tokenA.transfer(lpOwner, 1e27);
        tokenB.transfer(lpOwner, 1e27);
        vm.startPrank(lpOwner);
        tokenA.approve(address(lp), type(uint256).max);
        tokenB.approve(address(lp), type(uint256).max);
        vm.stopPrank();
    }

    function _terms(uint128 cashNum, uint128 cashDen, uint128 budget, uint128 walletCap)
        internal
        view
        returns (P.Terms memory t)
    {
        t.mode = P.Mode.Immediate;
        t.start = uint64(vm.getBlockTimestamp());
        t.end = t.start + 30 days;
        t.pointBudget = 1e30;
        t.walletPointCap = 1e30;
        t.pointNumerator = 1;
        t.pointDenominator = 1;
        if (budget != 0) {
            t.rewardToken = address(quoteT);
            t.cashBudget = budget;
            t.walletCashCap = walletCap;
            t.cashNumerator = cashNum;
            t.cashDenominator = cashDen;
        }
        t.sourcePolicyHash = keccak256("immediate");
        t.name = "Cashback";
        t.pointDecimals = 18;
    }

    function _scopes() internal view returns (P.Scope[] memory s) {
        s = new P.Scope[](1);
        s[0] =
            P.Scope(address(root), PoolId.unwrap(key.toId()), root.policyHash(key.toId()), address(quoteT), 1, 1, 0, 0);
    }

    function _milestones() internal pure returns (P.Milestone[] memory m) {
        m = new P.Milestone[](3);
        m[0] = P.Milestone(1e22, 5);
        m[1] = P.Milestone(1e23, 5);
        m[2] = P.Milestone(2e23, 5);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _fund(address who) internal {
        tokenA.transfer(who, 1e26);
        tokenB.transfer(who, 1e26);
        vm.startPrank(who);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// test_C / test_D terms: the funded Immediate cash program the wash drained cannot be created.
    function testWashedCashProgramCannotBeCreated() public {
        P.Scope[] memory s = _scopes();
        P.Terms memory c = _terms(1, 1000, 1e24, 1e24);
        vm.startPrank(creator);
        quoteT.approve(address(programs), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrProgramValidator.ImmediateValueUnreviewed.selector, 1e24, false, 0)
        );
        programs.createProgram(c, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
        P.Terms memory d = _terms(1, 5000, 1e24, 1e24);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrProgramValidator.ImmediateValueUnreviewed.selector, 1e24, false, 0)
        );
        programs.createProgram(d, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
        vm.stopPrank();
        assertEq(quoteT.balanceOf(address(programs)), 0);
    }

    /// test_F terms: neither the Sybil-drained budget nor its three milestone tiers can back Immediate activity.
    function testSybilDrainProgramCannotBeCreated() public {
        P.Scope[] memory s = _scopes();
        P.Terms memory t = _terms(1, 1000, 1e21, 2e20);
        P.Milestone[] memory m = _milestones();
        vm.startPrank(creator);
        quoteT.approve(address(programs), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrProgramValidator.ImmediateValueUnreviewed.selector, 1e21, false, 3)
        );
        programs.createProgram(t, s, m, P.NFTMetadata("Wash", "W", "ipfs://x/", true));
        t = _terms(0, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrProgramValidator.ImmediateValueUnreviewed.selector, 0, false, 3));
        programs.createProgram(t, s, m, P.NFTMetadata("Wash", "W", "ipfs://x/", true));
        t.globalBux = true;
        vm.expectRevert(abi.encodeWithSelector(IHookrProgramValidator.ImmediateValueUnreviewed.selector, 0, true, 0));
        programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
        vm.stopPrank();
    }

    /// The same Sybil wash against the allowed points-only Immediate program earns creator points and nothing of value.
    function testWashAgainstPointsOnlyProgramEarnsNoValue() public {
        P.Scope[] memory s = _scopes();
        P.Terms memory t = _terms(0, 0, 0, 0);
        vm.prank(creator);
        uint256 id = programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
        vm.prank(lpOwner);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-120, 120, 1e26, bytes32(0)), "");
        bool b0 = Currency.unwrap(key.currency0) == Currency.unwrap(quote);
        for (uint256 i; i < 5; ++i) {
            address w = address(uint160(0xB000 + i));
            _fund(w);
            uint256 subjBefore = subjT.balanceOf(w);
            vm.startPrank(w);
            router.swap(
                IHookrRouter.Swap(
                    key, b0, int128(1e23), uint128(2e23), b0 ? MIN_PRICE : MAX_PRICE, w, vm.getBlockTimestamp()
                ),
                address(programs),
                _ids(id)
            );
            uint256 got = subjT.balanceOf(w) - subjBefore;
            router.swap(
                IHookrRouter.Swap(
                    key, !b0, -int128(uint128(got)), 1, !b0 ? MIN_PRICE : MAX_PRICE, w, vm.getBlockTimestamp()
                ),
                address(programs),
                _ids(id)
            );
            vm.stopPrank();
            assertGt(programs.points(id, w), 0);
            assertEq(programs.claimableCash(id, w), 0);
            assertEq(programs.buxBalance(w), 0);
        }
        assertEq(programs.reservedCash(address(quoteT)), 0);
        assertEq(address(programs.program(id).collection), address(0));
    }
}
