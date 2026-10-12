// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrPaymaster} from "../../src/gasless/HookrPaymaster.sol";
import {IHookrPaymaster} from "../../src/interfaces/IHookrPaymaster.sol";
import {GaslessToken, MockEntryPoint} from "./GaslessMocks.sol";
import {PaymasterFixtures} from "../utils/PaymasterFixtures.sol";

/// @notice PERIPH-01: a keeper straddling the rate window boundary moves the rate two full steps within one second.
///         setToken now requires the markup to cover two compounded steps, so the straddle cannot price gas below the
///         anchor.
contract HookrPaymasterRateWindowStraddleTest is PaymasterFixtures {
    MockEntryPoint internal ep;
    uint256 internal windowStart;

    function setUp() public {
        vm.warp(1_000_000);
        ep = new MockEntryPoint();
        usd = new GaslessToken();
        pm = new HookrPaymaster(address(ep), address(0), OWNER, DELAY, TREASURY);
        _setPolicy(_policy(false, 1 ether));
        _gov(keccak256("GRANT_KEEPER"), abi.encode(KEEPER));
        vm.prank(OWNER);
        pm.grantKeeper(KEEPER);
    }

    /// The reviewer's configuration (markup 1_000, step 500) covers one step but not two: refused.
    function test_markupMustCoverTwoSteps() public {
        IHookrPaymaster.TokenConfig memory cfg = _usdConfig();
        cfg.markupBps = 1_000;
        _gov(keccak256("SET_TOKEN"), abi.encode(address(usd), cfg, USD_PER_ETH));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.InvalidTokenConfig.selector, uint8(5)));
        pm.setToken(address(usd), cfg, USD_PER_ETH);
        // (1 - 0.05)^2 * 1.108 >= 1: the smallest whole-bps markup for a 5% step.
        cfg.markupBps = 1_081;
        _setToken(address(usd), cfg, USD_PER_ETH);
        cfg.markupBps = 1_080;
        _gov(keccak256("SET_TOKEN"), abi.encode(address(usd), cfg, USD_PER_ETH));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.InvalidTokenConfig.selector, uint8(5)));
        pm.setToken(address(usd), cfg, USD_PER_ETH);
    }

    /// Two full steps across the boundary still quote 1 ETH of gas at or above the starting anchor.
    function test_straddleStaysAboveAnchorCost() public {
        _setToken(address(usd), _usdConfig(), USD_PER_ETH);
        windowStart = block.timestamp;
        vm.warp(windowStart + 1 hours - 1);
        vm.prank(KEEPER);
        pm.setRate(address(usd), USD_PER_ETH * 95 / 100, 3_600);
        vm.warp(windowStart + 1 hours);
        vm.prank(KEEPER);
        pm.setRate(address(usd), USD_PER_ETH * 95 / 100 * 95 / 100, 3_600);
        (uint256 required,) = pm.quoteCharge(IHookrPaymaster.Mode.TOKEN, address(usd), 1 ether);
        assertGe(required, uint256(USD_PER_ETH), "not below cost against the window anchor");
    }
}
