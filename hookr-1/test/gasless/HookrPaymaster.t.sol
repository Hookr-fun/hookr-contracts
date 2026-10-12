// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {HookrPaymaster} from "../../src/gasless/HookrPaymaster.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {IHookrPaymaster} from "../../src/interfaces/IHookrPaymaster.sol";
import {IPaymaster} from "../../src/interfaces/external/IPaymaster.sol";
import {PackedUserOperation} from "../../src/interfaces/external/PackedUserOperation.sol";
import {MockEntryPoint, MockRulesLedger} from "./GaslessMocks.sol";

contract HookrPaymasterTest is Test {
    MockEntryPoint ep = new MockEntryPoint();
    MockRulesLedger rules = new MockRulesLedger();
    HookrPaymaster pm;
    uint256 internal now_ = 1_000_000;
    address constant OWNER = address(0x0A);
    address constant TREASURY = address(0x7E);
    address constant ACCOUNT = address(0xACC);
    address constant ROUTER = address(0x4001);

    function setUp() public {
        vm.warp(1_000_000);
        pm = new HookrPaymaster(address(ep), address(0), OWNER, 1 days, TREASURY);
        IHookrPaymaster.Policy memory p =
            IHookrPaymaster.Policy(5_000, 1 ether, 1 ether, false, 10 ether, 1 ether, 100 gwei);
        _timelocked(keccak256("SET_POLICY"), abi.encode(p));
        vm.prank(OWNER);
        pm.setPolicy(p);
        _timelocked(keccak256("ALLOW_CALL"), abi.encode(ROUTER, bytes4(0x19b36adf), true));
        vm.prank(OWNER);
        pm.allowCall(ROUTER, 0x19b36adf, true);
        _timelocked(keccak256("ADD_REBATE_RULES"), abi.encode(address(rules)));
        vm.prank(OWNER);
        pm.addRebateRules(address(rules));
        address[] memory q = new address[](1);
        _timelocked(keccak256("SET_REBATE_QUOTES"), abi.encode(q));
        vm.prank(OWNER);
        pm.setRebateQuotes(q);
        vm.deal(address(this), 10 ether);
        vm.deal(OWNER, 1 ether);
        vm.prank(OWNER);
        pm.fundRebates{value: 1 ether}();
        pm.depositCredit{value: 1 ether}(ACCOUNT);
    }

    function _timelocked(bytes32 kind, bytes memory args) internal {
        vm.prank(OWNER);
        pm.queue(kind, args);
        now_ += 1 days;
        vm.warp(now_);
    }

    function _op(uint8 mode, address token, uint128 maxCharge) internal pure returns (PackedUserOperation memory op) {
        op.sender = ACCOUNT;
        op.callData = abi.encodeWithSelector(0xb61d27f6, ROUTER, 0, abi.encodeWithSelector(0x19b36adf));
        op.accountGasLimits = bytes32(uint256(200_000));
        op.paymasterAndData = abi.encodePacked(
            address(0x1234), uint128(100_000), uint128(240_000), mode, token, maxCharge, uint48(2_000_000_000)
        );
    }

    function test_credit_validate_postOp_rebate() public {
        uint256 maxCost = 0.01 ether;
        vm.prank(address(ep));
        (bytes memory ctx, uint256 vd) =
            pm.validatePaymasterUserOp(_op(0, address(0), uint128(maxCost)), bytes32("h"), maxCost);
        assertEq(vd, uint256(2_000_000_000) << 160);
        assertEq(pm.credit(ACCOUNT, address(0)), 1 ether - maxCost);
        rules.set(ACCOUNT, address(0), 0.004 ether); // protocol fee paid this tx
        vm.prank(address(ep));
        pm.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.001 ether, 0);
        // cost 0.001, fee 0.004 * 50% = 0.002 → rebate = cost → charged 0
        assertEq(pm.revenue(address(0)), 0);
        assertEq(pm.credit(ACCOUNT, address(0)), 1 ether);
        assertEq(pm.rebateBudget(), 1 ether - 0.001 ether);
    }

    function test_reverted_fullCharge_noRebate() public {
        uint256 maxCost = 0.01 ether;
        vm.prank(address(ep));
        (bytes memory ctx,) = pm.validatePaymasterUserOp(_op(0, address(0), uint128(maxCost)), bytes32("h"), maxCost);
        rules.set(ACCOUNT, address(0), 1 ether);
        vm.prank(address(ep));
        pm.postOp(IPaymaster.PostOpMode.opReverted, ctx, 0.001 ether, 0);
        assertEq(pm.revenue(address(0)), 0.001 ether);
        assertEq(pm.rebateBudget(), 1 ether);
    }

    function test_validation_errors() public {
        vm.startPrank(address(ep));
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.CostAboveCap.selector, 2 ether, 1 ether));
        pm.validatePaymasterUserOp(_op(0, address(0), 2 ether), bytes32(0), 2 ether);
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.ChargeAboveLimit.selector, 0.01 ether, 1));
        pm.validatePaymasterUserOp(_op(0, address(0), 1), bytes32(0), 0.01 ether);
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.UnsupportedToken.selector, address(0x70)));
        pm.validatePaymasterUserOp(_op(1, address(0x70), 1 ether), bytes32(0), 0.01 ether);
        PackedUserOperation memory op = _op(0, address(0), 1 ether);
        op.callData = abi.encodeWithSelector(0xb61d27f6, address(0x999), 0, abi.encodeWithSelector(0x19b36adf));
        vm.expectRevert(
            abi.encodeWithSelector(IHookrPaymaster.CallNotAllowed.selector, address(0x999), bytes4(0x19b36adf))
        );
        pm.validatePaymasterUserOp(op, bytes32(0), 0.01 ether);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.NotEntryPoint.selector, address(this)));
        pm.validatePaymasterUserOp(_op(0, address(0), 1 ether), bytes32(0), 0.01 ether);
    }

    function test_pause_timelock_and_withdrawWhilePaused() public {
        vm.prank(OWNER);
        pm.pause();
        vm.prank(address(ep));
        vm.expectRevert(IHookrPaymaster.SponsorshipPaused.selector);
        pm.validatePaymasterUserOp(_op(0, address(0), 1 ether), bytes32(0), 0.01 ether);
        vm.prank(ACCOUNT);
        pm.withdrawCredit(address(0), ACCOUNT, 0.5 ether);
        assertEq(ACCOUNT.balance, 0.5 ether);
        bytes32 op = pm.operationHash(keccak256("UNPAUSE"), "");
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, uint48(0)));
        pm.unpause();
        assertEq(pm.releaseId(), 1);
    }
}
