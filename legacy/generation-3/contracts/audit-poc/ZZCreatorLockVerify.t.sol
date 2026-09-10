// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @dev A launcher contract with NO payable receive/fallback (e.g. a custom team launcher).
contract NoReceiveLauncher {
    function doLaunch(HookrLaunchpad pad, HookrLaunchpad.LaunchArgs memory a)
        external
        payable
        returns (address)
    {
        return pad.launch{value: msg.value}(a);
    }
}

/// @dev A launcher that CAN receive ETH — control group.
contract PayableLauncher {
    receive() external payable {}

    function doLaunch(HookrLaunchpad pad, HookrLaunchpad.LaunchArgs memory a)
        external
        payable
        returns (address)
    {
        return pad.launch{value: msg.value}(a);
    }
}

contract ZZCreatorLockVerify is Test {
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 3));
    IPoolManager constant pm = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    HookrLaunchpad pad;
    HookrHook hook;

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

    /// PROOF: a contract creator with no receive() permanently locks its creator fees.
    function test_contractCreatorWithoutReceive_locksCreatorFeesForever() public {
        NoReceiveLauncher launcher = new NoReceiveLauncher();
        uint256 fee = pad.creationFeeWei();
        vm.deal(address(launcher), fee);

        // 1. Launching from a non-receiving contract SUCCEEDS (permissionless, no guard).
        address t = launcher.doLaunch{value: fee}(pad, _args(0.01 ether, "LCK"));
        assertEq(pad.getLaunch(t).creator, address(launcher), "creator recorded as the contract");

        // 2. Curve trading accrues creator fees.
        vm.prank(alice);
        pad.buy{value: 0.003 ether}(t, 0);
        uint256 accrued = pad.creatorFeesWei(t);
        assertGt(accrued, 0, "creator fees accrued");
        console2.log("creator fees after buy   ", accrued);

        // 3. claimCreatorFees reverts — from anyone, since it is permissionless and hardcodes l.creator.
        vm.expectRevert(HookrLaunchpad.EthTransferFailed.selector);
        pad.claimCreatorFees(t);

        vm.prank(alice);
        vm.expectRevert(HookrLaunchpad.EthTransferFailed.selector);
        pad.claimCreatorFees(t);

        // even the creator itself calling cannot help
        vm.prank(address(launcher));
        vm.expectRevert(HookrLaunchpad.EthTransferFailed.selector);
        pad.claimCreatorFees(t);

        // 4. Graduate, then LP-fee collection keeps growing the stuck balance.
        vm.prank(bob);
        pad.buy{value: 0.05 ether}(t, 0);
        assertTrue(pad.getLaunch(t).graduated, "graduated");

        // trade on the pool so LP fees exist, then collect (callable by anyone)
        pad.collectPoolFees(t);
        uint256 grown = pad.creatorFeesWei(t);
        assertGt(grown, accrued, "stuck balance grew after graduation");
        console2.log("creator fees after grad  ", grown);

        vm.expectRevert(HookrLaunchpad.EthTransferFailed.selector);
        pad.claimCreatorFees(t);

        // 5. No rescue: the owner can only move protocolFeesWei; the stuck creator ETH stays.
        uint256 padBalBefore = address(pad).balance;
        uint256 proto = pad.protocolFeesWei();
        pad.withdrawProtocolFees(address(0xFEE));
        assertEq(address(pad).balance, padBalBefore - proto, "owner drained only protocol fees");
        assertEq(pad.creatorFeesWei(t), grown, "creator balance untouched by owner");
        assertGe(address(pad).balance, grown, "stuck ETH still sitting in the launchpad");

        // and there is no setter for the creator anywhere
        assertEq(pad.getLaunch(t).creator, address(launcher), "creator immutable");
    }

    /// CONTROL: identical launcher WITH receive() claims fine — isolates the cause.
    function test_control_payableContractCreatorCanClaim() public {
        PayableLauncher launcher = new PayableLauncher();
        uint256 fee = pad.creationFeeWei();
        address t = launcher.doLaunch{value: fee}(pad, _args(0.01 ether, "OKK"));

        vm.prank(alice);
        pad.buy{value: 0.003 ether}(t, 0);
        uint256 accrued = pad.creatorFeesWei(t);
        assertGt(accrued, 0);

        uint256 before = address(launcher).balance;
        pad.claimCreatorFees(t);
        assertEq(address(launcher).balance - before, accrued, "payable contract creator paid");
    }

    /// Does a non-receiving contract get blocked at launch time when it does a creator buy?
    /// (If it were always blocked, the lock would be unreachable — check.)
    function test_nonReceivingLauncher_creatorBuyPathMayOrMayNotRevert() public {
        NoReceiveLauncher launcher = new NoReceiveLauncher();
        uint256 fee = pad.creationFeeWei();
        vm.deal(address(launcher), fee + 1 ether);
        HookrLaunchpad.LaunchArgs memory a = _args(0.01 ether, "BUY");
        a.creatorBuyWei = 0.001 ether;
        // A refund would revert; if it does not, the launch succeeds with a stuck creator anyway.
        try launcher.doLaunch{value: fee + 0.001 ether}(pad, a) returns (address t) {
            console2.log("creator-buy launch succeeded from non-receiving contract");
            assertEq(pad.getLaunch(t).creator, address(launcher));
            vm.expectRevert(HookrLaunchpad.EthTransferFailed.selector);
            pad.claimCreatorFees(t);
        } catch {
            console2.log("creator-buy launch reverted (refund path) - zero-buy launch is still open");
        }
    }
}
