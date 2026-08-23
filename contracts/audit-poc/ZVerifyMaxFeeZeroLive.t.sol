// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";

/// @notice Drives the ACTUAL DEPLOYED launchpad/hook on forked Robinhood Chain 4663.
contract ZVerifyMaxFeeZeroLiveTest is Test {
    HookrLaunchpad constant PAD = HookrLaunchpad(payable(0x27Cca38E94E3e77BFde2284325DcDb0Da7323579));
    address constant LIVE_HOOK = 0xDaf937d3B7C363e0feC29F5584ce08B0894fe088;

    address alice = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork("robinhood");
        assertEq(block.chainid, 4663);
        assertGt(address(PAD).code.length, 0, "live launchpad has code");
        assertGt(LIVE_HOOK.code.length, 0, "live hook has code");
        assertEq(address(PAD.hook()), LIVE_HOOK, "wired hook matches");
        vm.deal(alice, 100 ether);
    }

    function _p() internal pure returns (HookrLaunchpad.HookParams memory p) {
        p = HookrLaunchpad.HookParams({
            guardBlocks: 10,
            maxBuyBps: 100,
            snipeTaxPips: 400_000,
            baseFeePips: 3000, // UI default
            maxFeePips: 0, // UI default when no `fee` block is stacked
            surgeSens: 0,
            burnBps: 0,
            burnTriggerWei: 0,
            lpBps: 0,
            potBps: 50,
            potOdds: 2,
            potMinBuyWei: 1e12
        });
    }

    function _launch(HookrLaunchpad.HookParams memory p) internal returns (address token) {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "LiveStuck";
        a.symbol = "LSTK";
        a.targetRaiseWei = 0.01 ether;
        a.blueprintId = 0;
        a.custom = p;
        vm.prank(alice);
        token = PAD.launch{value: PAD.creationFeeWei()}(a);
    }

    function test_LIVE_deployment_acceptsMaxFeeZero_thenBricks() public {
        address token = _launch(_p());
        assertEq(PAD.getLaunch(token).hookParams.maxFeePips, 0, "live pad accepted maxFeePips=0");

        vm.prank(alice);
        vm.expectRevert(HookrHook.BadConfig.selector);
        PAD.buy{value: 0.02 ether}(token, 0);
    }

    function test_LIVE_control_maxFeeEqualBase_graduates() public {
        HookrLaunchpad.HookParams memory p = _p();
        p.maxFeePips = p.baseFeePips;
        address token = _launch(p);

        vm.prank(alice);
        PAD.buy{value: 0.02 ether}(token, 0);
        assertTrue(PAD.getLaunch(token).graduated, "live control graduates");
    }

    /// @dev How much value can get stranded before the jam, and is every later buy dead?
    function test_LIVE_strandedReserve_andDeadCurve() public {
        address token = _launch(_p());

        // Push the curve as far up as it will go with geometrically shrinking buys.
        uint256 size = 0.02 ether;
        while (size > 0) {
            vm.prank(alice);
            try PAD.buy{value: size}(token, 0) {
                // absorbed; keep going at the same size
            } catch {
                size /= 2; // too big (would complete the curve, or buys 0 tokens)
            }
            if (PAD.getLaunch(token).soldTokens >= PAD.CURVE_SUPPLY()) break;
            if (size < 1e6) break;
        }

        HookrLaunchpad.Launch memory l = PAD.getLaunch(token);
        emit log_named_uint("soldTokens ", l.soldTokens);
        emit log_named_uint("CURVE_SUPPLY", PAD.CURVE_SUPPLY());
        emit log_named_uint("reserveWei  ", l.reserveWei);
        emit log_named_uint("targetWei   ", l.targetWei);
        assertFalse(l.graduated, "cannot graduate, ever");

        // Any buy big enough to move the curve now reverts in configurePool.
        vm.prank(alice);
        vm.expectRevert(HookrHook.BadConfig.selector);
        PAD.buy{value: 1 ether}(token, 0);
    }

    /// @dev Can holders still exit the jammed curve?
    function test_LIVE_holdersCanStillSellOutOfJammedCurve() public {
        address token = _launch(_p());
        vm.prank(alice);
        PAD.buy{value: 0.005 ether}(token, 0);

        uint256 bal = HookrTokenLike(token).balanceOf(alice);
        assertGt(bal, 0);
        uint256 ethBefore = alice.balance;

        vm.startPrank(alice);
        HookrTokenLike(token).approve(address(PAD), bal);
        PAD.sell(token, bal, 0);
        vm.stopPrank();

        emit log_named_uint("eth spent  ", 0.005 ether);
        emit log_named_uint("eth back   ", alice.balance - ethBefore);
        assertGt(alice.balance - ethBefore, 0, "sell path still works");
    }
}

interface HookrTokenLike {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}
