// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Part 2: cross-token solvency, tranche boundary math, graduation edges.
contract AuditVL2 is Test {
    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 3));
    IPoolManager constant pm = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    HookrLaunchpad pad;
    HookrHook hook;

    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.createSelectFork("robinhood");
        pad = new HookrLaunchpad(pm);
        bytes memory creation = abi.encodePacked(type(HookrHook).creationCode, abi.encode(address(pm), address(pad)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(pm, address(pad));
        require(address(hook) == predicted, "mine");
        pad.setHook(hook);
        vm.deal(creator, 100_000 ether);
        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
    }

    function _args(uint96 target, string memory sym) internal pure returns (HookrLaunchpad.LaunchArgs memory a) {
        a.name = "Audit";
        a.symbol = sym;
        a.targetRaiseWei = target;
        a.custom.baseFeePips = 3000;
        a.custom.maxFeePips = 3000;
    }

    function _launch(uint96 target, string memory sym) internal returns (address token) {
        uint256 f = pad.creationFeeWei();
        vm.prank(creator);
        token = pad.launch{value: f}(_args(target, sym));
    }

    // ---------------------------------------------------------- cross-token solvency

    /// @dev Graduating token A must not consume a single wei belonging to token B's reserve.
    function test_graduationDoesNotTouchOtherReserves() public {
        address a = _launch(0.01 ether, "AAA");
        address b = _launch(1 ether, "BBB");

        // fund B's curve heavily
        vm.prank(bob);
        pad.buy{value: 0.5 ether}(b, 0);
        uint256 bReserve = pad.getLaunch(b).reserveWei;
        assertGt(bReserve, 0);

        // graduate A
        vm.prank(alice);
        pad.buy{value: 0.05 ether}(a, 0);
        assertTrue(pad.getLaunch(a).graduated, "A graduated");

        // B's reserve untouched and fully redeemable
        assertEq(pad.getLaunch(b).reserveWei, bReserve, "B reserve mutated");
        uint256 accounted = uint256(pad.getLaunch(b).reserveWei) + pad.protocolFeesWei() + pad.creatorFeesWei(a)
            + pad.creatorFeesWei(b);
        assertGe(address(pad).balance, accounted, "pad insolvent after A graduation");

        // B's holder can exit fully
        uint256 bal = HookrToken(b).balanceOf(bob);
        vm.startPrank(bob);
        HookrToken(b).approve(address(pad), bal);
        pad.sell(b, bal, 0);
        vm.stopPrank();

        // and protocol + creator can still be paid in full
        uint256 proto = pad.protocolFeesWei();
        pad.withdrawProtocolFees(address(0xFEE));
        assertEq(address(0xFEE).balance, proto);
        pad.claimCreatorFees(a);
        pad.claimCreatorFees(b);
        assertGe(address(pad).balance, uint256(pad.getLaunch(b).reserveWei), "cannot honour residual reserve");
    }

    // ---------------------------------------------------------- tranche boundaries

    function test_trancheBoundary_pricingIsConsistent() public {
        uint96 target = 1 ether;
        address t = _launch(target, "TRN");
        uint256 p0 = pad.currentCurvePrice(t);
        uint256 TT = pad.TRANCHE_TOKENS();

        // walk exactly to the end of tranche 0
        uint256 costForTranche0 = (TT * p0) / 1e18;
        // send a hair more than needed (with fee headroom); refund returns the rest
        vm.prank(alice);
        pad.buy{value: (costForTranche0 * 10_300) / 10_000}(t, 0);

        HookrLaunchpad.Launch memory l = pad.getLaunch(t);
        console2.log("sold after tranche0 buy", l.soldTokens);
        console2.log("TRANCHE_TOKENS        ", TT);
        assertGe(uint256(l.soldTokens), TT, "should have crossed tranche 0");

        uint256 p1 = pad.currentCurvePrice(t);
        assertEq(p1, (p0 * 17) / 10, "tranche 1 price");

        // Selling back down across the boundary must be priced at p0 for the tranche-0 portion.
        uint256 sellAmt = uint256(l.soldTokens) - TT + 1e18; // 1 token past the boundary + the sliver
        uint256 quoted = pad.quoteSell(t, sellAmt);
        // gross must be < sliver*p1 + 1e18*p0 (never the higher price for the lower tokens)
        uint256 maxFair = ((uint256(l.soldTokens) - TT) * p1) / 1e18 + (1e18 * p0) / 1e18;
        assertLe(quoted, maxFair, "sell overpaid across boundary");
    }

    /// @dev Buying up to an exact tranche boundary and selling straight back must lose money.
    function testFuzz_boundaryRoundTrip(uint96 target, uint8 tranche, uint16 frac) public {
        target = uint96(bound(target, 0.0001 ether, 1000 ether));
        tranche = uint8(bound(tranche, 0, 9));
        frac = uint16(bound(frac, 1, 10_000));
        address t = _launch(target, "BND");

        // walk to just inside `tranche`, then a fractional step
        uint256 spend = (uint256(target) * (uint256(tranche) * 1000 + frac)) / 10_000;
        if (spend == 0) return;
        (uint256 q,) = pad.quoteBuy(t, spend);
        if (q == 0) return;

        uint256 before = alice.balance;
        vm.prank(alice);
        pad.buy{value: spend}(t, 0);
        if (pad.getLaunch(t).graduated) return;

        uint256 bal = HookrToken(t).balanceOf(alice);
        if (pad.quoteSell(t, bal) == 0) return;
        vm.startPrank(alice);
        HookrToken(t).approve(address(pad), bal);
        pad.sell(t, bal, 0);
        vm.stopPrank();
        assertLe(alice.balance, before, "boundary round trip printed ETH");

        HookrLaunchpad.Launch memory l = pad.getLaunch(t);
        assertEq(
            address(pad).balance,
            uint256(l.reserveWei) + pad.protocolFeesWei() + pad.creatorFeesWei(t),
            "unaccounted wei"
        );
    }

    // ---------------------------------------------------------- graduation edges

    /// @dev The reserve must always fund the pool seed: reserve >= ETH actually settled.
    function test_graduation_ethSettledNeverExceedsReserve() public {
        uint96[5] memory targets =
            [uint96(0.0001 ether), uint96(0.0137 ether), uint96(3.7 ether), uint96(137 ether), uint96(1000 ether)];
        for (uint256 i = 0; i < targets.length; i++) {
            uint256 snap = vm.snapshotState();
            address t = _launch(targets[i], "GRD");
            // fill the curve in many uneven steps to maximise rounding drift
            for (uint256 j = 0; j < 30 && !pad.getLaunch(t).graduated; j++) {
                uint256 v = (uint256(targets[i]) * (3 + (j % 7))) / 100;
                if (v == 0) v = 1;
                vm.deal(alice, v + 1 ether);
                vm.prank(alice);
                pad.buy{value: v}(t, 0);
            }
            if (!pad.getLaunch(t).graduated) {
                vm.deal(alice, uint256(targets[i]) * 2 + 1 ether);
                vm.prank(alice);
                pad.buy{value: uint256(targets[i]) * 2}(t, 0);
            }
            assertTrue(pad.getLaunch(t).graduated, "must graduate after uneven fills");
            assertGe(
                address(pad).balance,
                pad.protocolFeesWei() + pad.creatorFeesWei(t),
                "insolvent after uneven-fill graduation"
            );
            assertEq(HookrToken(t).balanceOf(address(pad)), 0, "stranded tokens");
            vm.revertToState(snap);
        }
    }

    /// @dev Sells right before the final buy must not leave the curve unable to graduate.
    function test_sellHeavyThenGraduate() public {
        uint96 target = 0.5 ether;
        address t = _launch(target, "SEL");
        for (uint256 i = 0; i < 6; i++) {
            vm.prank(alice);
            pad.buy{value: 0.07 ether}(t, 0);
            uint256 bal = HookrToken(t).balanceOf(alice);
            vm.startPrank(alice);
            HookrToken(t).approve(address(pad), bal / 3);
            pad.sell(t, bal / 3, 0);
            vm.stopPrank();
        }
        vm.prank(bob);
        pad.buy{value: 2 ether}(t, 0);
        assertTrue(pad.getLaunch(t).graduated, "graduation blocked after churn");
        assertGe(address(pad).balance, pad.protocolFeesWei() + pad.creatorFeesWei(t), "insolvent");
    }

    /// @dev The locked LP position must be unremovable: no code path decreases liquidity.
    function test_lpPositionIsLocked() public {
        address t = _launch(0.01 ether, "LCK");
        vm.prank(alice);
        pad.buy{value: 0.05 ether}(t, 0);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(t),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        uint128 liq = pm.getLiquidity(key.toId());
        assertGt(liq, 0);
        // collecting fees must never reduce liquidity
        pad.collectPoolFees(t);
        assertEq(pm.getLiquidity(key.toId()), liq, "collect changed liquidity");
    }
}
