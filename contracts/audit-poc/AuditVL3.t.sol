// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice PoC: launch-time hook-param validation is looser than the hook's own graduation-time
///         validation. A config the launchpad accepts can make _graduate() revert forever.
contract AuditVL3 is Test {
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
        vm.deal(creator, 1000 ether);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    /// @dev base fee set, surge disabled by leaving maxFeePips at 0 — accepted at launch.
    function _flatFeeParams() internal pure returns (HookrLaunchpad.HookParams memory p) {
        p.baseFeePips = 3000; // 0.3% flat LP fee
        p.maxFeePips = 0; // "no surge"
    }

    function test_POC_maxFeeZero_bricksGraduationForever() public {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Flat Fee";
        a.symbol = "FLAT";
        a.targetRaiseWei = 0.01 ether;
        a.custom = _flatFeeParams();

        // 1. the launchpad ACCEPTS this config
        uint256 f = pad.creationFeeWei();
        vm.prank(creator);
        address token = pad.launch{value: f}(a);
        console2.log("launch accepted, token", token);

        // 2. real ETH flows onto the curve
        vm.prank(alice);
        pad.buy{value: 0.005 ether}(token, 0);
        vm.prank(bob);
        pad.buy{value: 0.004 ether}(token, 0);
        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        console2.log("reserve now (wei)", l.reserveWei);
        console2.log("sold / CURVE_SUPPLY", l.soldTokens, pad.CURVE_SUPPLY());
        assertGt(l.reserveWei, 0);

        // 3. ANY buy that completes the curve reverts inside hook.configurePool
        vm.prank(alice);
        vm.expectRevert(HookrHook.BadConfig.selector);
        pad.buy{value: 1 ether}(token, 0);

        // 4. it is not a one-off: every sellout attempt reverts, at any size
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bob);
            vm.expectRevert(HookrHook.BadConfig.selector);
            pad.buy{value: 0.02 ether * (i + 1)}(token, 0);
        }
        assertFalse(pad.getLaunch(token).graduated, "can never graduate");

        // 5. the curve can only be filled to just short of sellout; the reserve is stranded
        //    in a token that can never get a pool.
        uint256 lo = 0;
        uint256 hi = 1 ether;
        for (uint256 i = 0; i < 60; i++) {
            uint256 mid = (lo + hi) / 2;
            if (mid == lo) break;
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            (bool ok,) = address(pad).call{value: mid}(abi.encodeCall(pad.buy, (token, 0)));
            vm.revertToState(snap);
            if (ok) lo = mid;
            else hi = mid;
        }
        vm.prank(alice);
        pad.buy{value: lo}(token, 0);
        HookrLaunchpad.Launch memory l2 = pad.getLaunch(token);
        console2.log("max reachable sold", l2.soldTokens);
        console2.log("CURVE_SUPPLY      ", pad.CURVE_SUPPLY());
        console2.log("stranded reserve  ", l2.reserveWei);
        assertLt(uint256(l2.soldTokens), pad.CURVE_SUPPLY(), "curve permanently short of sellout");
        assertGt(uint256(l2.reserveWei), 0, "ETH stranded on a dead curve");
        assertFalse(l2.graduated);
    }

    /// @dev A saved blueprint carrying the same config bricks every launch that uses it.
    function test_POC_badBlueprint_bricksEveryLaunchThatUsesIt() public {
        vm.prank(bob);
        uint32 id = pad.saveBlueprint("Flat Fee, No Surge", _flatFeeParams(), 500);

        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Uses Blueprint";
        a.symbol = "UBP";
        a.targetRaiseWei = 0.01 ether;
        a.blueprintId = id;

        uint256 f = pad.creationFeeWei();
        vm.prank(creator);
        address token = pad.launch{value: f}(a);

        vm.prank(alice);
        vm.expectRevert(HookrHook.BadConfig.selector);
        pad.buy{value: 0.05 ether}(token, 0);
        assertFalse(pad.getLaunch(token).graduated);
    }

    /// @dev Control: the identical launch with maxFeePips == baseFeePips graduates fine,
    ///      isolating maxFeePips == 0 as the sole cause.
    function test_control_maxFeeEqualBase_graduates() public {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Control";
        a.symbol = "CTL";
        a.targetRaiseWei = 0.01 ether;
        a.custom.baseFeePips = 3000;
        a.custom.maxFeePips = 3000;

        uint256 f = pad.creationFeeWei();
        vm.prank(creator);
        address token = pad.launch{value: f}(a);
        vm.prank(alice);
        pad.buy{value: 0.05 ether}(token, 0);
        assertTrue(pad.getLaunch(token).graduated, "control must graduate");
    }

    /// @dev Enumerate the exact accepted-then-rejected window.
    function testFuzz_validationDivergence(uint24 baseFee) public {
        baseFee = uint24(bound(baseFee, 0, 500_000));
        HookrLaunchpad.HookParams memory p;
        p.baseFeePips = baseFee;
        p.maxFeePips = 0;

        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Fuzz";
        a.symbol = "FZ";
        a.targetRaiseWei = 0.01 ether;
        a.custom = p;

        uint256 f = pad.creationFeeWei();
        vm.prank(creator);
        address token = pad.launch{value: f}(a); // always accepted

        vm.prank(alice);
        if (baseFee == 0) {
            pad.buy{value: 0.05 ether}(token, 0);
            assertTrue(pad.getLaunch(token).graduated);
        } else {
            vm.expectRevert(HookrHook.BadConfig.selector);
            pad.buy{value: 0.05 ether}(token, 0);
        }
    }
}
