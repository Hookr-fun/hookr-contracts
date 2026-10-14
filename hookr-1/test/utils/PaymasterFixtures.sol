// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {HookrPaymaster} from "../../src/gasless/HookrPaymaster.sol";
import {IHookrPaymaster} from "../../src/interfaces/IHookrPaymaster.sol";
import {GaslessToken} from "../gasless/GaslessMocks.sol";

abstract contract PaymasterFixtures is Test {
    address internal constant OWNER = address(0xA0);
    address internal constant TREASURY = address(0x7E);
    address internal constant KEEPER = address(0x4E);
    address internal constant SPENDER = address(0x5E);
    uint48 internal constant DELAY = 1 days;
    uint128 internal constant USD_PER_ETH = 3_000e18;

    HookrPaymaster internal pm;
    GaslessToken internal usd;

    function _gov(bytes32 kind, bytes memory args) internal {
        vm.prank(OWNER);
        pm.queue(kind, args);
        vm.warp(block.timestamp + DELAY);
    }

    function _policy(bool screen, uint128 maxCost) internal pure returns (IHookrPaymaster.Policy memory) {
        return IHookrPaymaster.Policy({
            rebateBps: 5_000,
            perOpRebateCapWei: 0.01 ether,
            perAccountDailyRebateCapWei: 0.05 ether,
            screenSanctions: screen,
            dailyRebateCapWei: 1 ether,
            maxCostWei: maxCost,
            maxFeePerGasWei: 100 gwei
        });
    }

    function _setPolicy(IHookrPaymaster.Policy memory p) internal {
        _gov(keccak256("SET_POLICY"), abi.encode(p));
        vm.prank(OWNER);
        pm.setPolicy(p);
    }

    function _allowCall(address target, bytes4 selector) internal {
        _gov(keccak256("ALLOW_CALL"), abi.encode(target, selector, false));
        vm.prank(OWNER);
        pm.allowCall(target, selector, false);
    }

    function _addRules(address r) internal {
        _gov(keccak256("ADD_REBATE_RULES"), abi.encode(r));
        vm.prank(OWNER);
        pm.addRebateRules(r);
    }

    function _setQuotes(address[] memory q) internal {
        _gov(keccak256("SET_REBATE_QUOTES"), abi.encode(q));
        vm.prank(OWNER);
        pm.setRebateQuotes(q);
    }

    function _setToken(address token, IHookrPaymaster.TokenConfig memory cfg, uint128 rate) internal {
        _gov(keccak256("SET_TOKEN"), abi.encode(token, cfg, rate));
        vm.prank(OWNER);
        pm.setToken(token, cfg, rate);
    }

    function _usdConfig() internal pure returns (IHookrPaymaster.TokenConfig memory) {
        return IHookrPaymaster.TokenConfig({
            enabled: true, peg: false, markupBps: 1_100, maxRateStepBps: 500, maxRateTtl: 3_600
        });
    }

    function _fundRebates(uint256 amount) internal {
        vm.deal(OWNER, OWNER.balance + amount);
        vm.prank(OWNER);
        pm.fundRebates{value: amount}();
    }
}
