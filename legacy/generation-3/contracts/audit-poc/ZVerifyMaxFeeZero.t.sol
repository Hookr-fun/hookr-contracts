// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Independent verification of the "maxFeePips == 0 bricks graduation" claim.
contract ZVerifyMaxFeeZeroTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 3));
    uint96 constant TARGET = 0.01 ether;

    HookrLaunchpad pad;
    HookrHook hook;

    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork("robinhood");
        pad = new HookrLaunchpad(PM);
        bytes memory creation =
            abi.encodePacked(type(HookrHook).creationCode, abi.encode(PM, address(pad)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(PM, address(pad));
        assertEq(address(hook), predicted);
        pad.setHook(hook);
        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
    }

    /// @dev Exactly what the UI compiles for a default builder stack ["snipe","pot"]:
    ///      baseFeePips = DEFAULT_BASE_FEE_PIPS (3000), maxFeePips = 0 (no `fee` block stacked).
    function _uiDefaultParams() internal pure returns (HookrLaunchpad.HookParams memory p) {
        p = HookrLaunchpad.HookParams({
            guardBlocks: 10, // snipe block
            maxBuyBps: 100, // snipe block
            snipeTaxPips: 400_000, // snipe block
            baseFeePips: 3000, // DEFAULT_BASE_FEE_PIPS, always set
            maxFeePips: 0, // <-- never set unless a `fee` block is stacked
            surgeSens: 0,
            burnBps: 0,
            burnTriggerWei: 0,
            lpBps: 0,
            potBps: 50, // pot block
            potOdds: 2,
            potMinBuyWei: 1e12
        });
    }

    function _launch(HookrLaunchpad.HookParams memory p) internal returns (address token) {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Stuck";
        a.symbol = "STUCK";
        a.targetRaiseWei = TARGET;
        a.blueprintId = 0;
        a.custom = p;
        vm.prank(creator);
        token = pad.launch{value: pad.creationFeeWei()}(a);
    }

    // ------------------------------------------------------------------ POC

    function test_maxFeeZero_launchAccepted_graduationReverts() public {
        address token = _launch(_uiDefaultParams());

        // The launch is accepted with exactly the params the UI compiles.
        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        assertEq(l.hookParams.baseFeePips, 3000);
        assertEq(l.hookParams.maxFeePips, 0);

        // Buying out the curve must revert inside hook.configurePool.
        vm.prank(alice);
        vm.expectRevert(HookrHook.BadConfig.selector);
        pad.buy{value: 0.02 ether}(token, 0);
    }

    function test_control_maxFeeEqualBase_graduatesFine() public {
        HookrLaunchpad.HookParams memory p = _uiDefaultParams();
        p.maxFeePips = p.baseFeePips; // the ONLY difference
        address token = _launch(p);

        vm.prank(alice);
        pad.buy{value: 0.02 ether}(token, 0);
        assertTrue(pad.getLaunch(token).graduated, "control graduates");
    }

    /// @dev Is the curve permanently stuck, or merely un-graduatable by one big buy?
    ///      Walk it up with many partial buys and show every buy that would complete it reverts.
    function test_maxFeeZero_curveIsPermanentlyStuck() public {
        address token = _launch(_uiDefaultParams());

        // Fill the curve with repeated partial buys until any further buy reverts.
        uint256 reverts;
        for (uint256 i = 0; i < 60; i++) {
            vm.prank(alice);
            try pad.buy{value: 0.002 ether}(token, 0) {
                // succeeded
            } catch {
                reverts++;
                break;
            }
        }
        assertGt(reverts, 0, "expected the curve to jam before selling out");

        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        emit log_named_uint("soldTokens", l.soldTokens);
        emit log_named_uint("CURVE_SUPPLY", pad.CURVE_SUPPLY());
        emit log_named_uint("reserveWei", l.reserveWei);
        emit log_named_uint("targetWei", l.targetWei);
        assertFalse(l.graduated, "never graduates");

        // A 1-wei buy reverts with SlippageExceeded (it buys 0 tokens) — expected, not the bug.
        vm.prank(alice);
        vm.expectRevert(HookrLaunchpad.SlippageExceeded.selector);
        pad.buy{value: 1 wei}(token, 0);

        // Any buy large enough to complete the curve reverts inside configurePool, forever.
        vm.prank(alice);
        vm.expectRevert(HookrHook.BadConfig.selector);
        pad.buy{value: 5 ether}(token, 0);

        // Sells still work (holders can bleed out at 1% each way) but no pool ever exists.
        uint256 bal = HookrLaunchpad(pad).getLaunch(token).soldTokens;
        assertGt(bal, 0);
    }

    /// @dev Divergence sweep: the launchpad accepts what the hook rejects.
    function testFuzz_validationDivergence(uint24 baseFeePips) public {
        baseFeePips = uint24(bound(baseFeePips, 1, 100_000));
        HookrLaunchpad.HookParams memory p = _uiDefaultParams();
        p.baseFeePips = baseFeePips;
        p.snipeTaxPips = 0;
        p.maxFeePips = 0;

        address token = _launch(p); // launchpad ALWAYS accepts

        vm.prank(alice);
        vm.expectRevert(HookrHook.BadConfig.selector);
        pad.buy{value: 0.02 ether}(token, 0); // hook ALWAYS rejects
    }
}
