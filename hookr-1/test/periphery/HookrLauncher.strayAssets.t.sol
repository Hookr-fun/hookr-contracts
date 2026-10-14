// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrSettlement} from "../../src/libraries/HookrSettlement.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";
import {DevBuyFixture} from "./DevBuyFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockFeeOnTransferToken} from "../mocks/MockFeeOnTransferToken.sol";

/// @dev Sends ETH without executing the recipient's code (SELFDESTRUCT in the creation transaction).
contract LauncherForceSend {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

/// @dev Native recipient that tries to sweep the Launcher while its own exit is being paid.
contract LauncherReentrantRecipient {
    HookrLauncher internal immutable launcher;
    bool public attempted;
    bytes public reason;

    constructor(HookrLauncher l) {
        launcher = l;
    }

    receive() external payable {
        if (attempted) return;
        attempted = true;
        try launcher.sweep(Currency.wrap(address(0)), address(this)) {}
        catch (bytes memory r) {
            reason = r;
        }
    }
}

/// @notice N-03 (HookrLauncher part) regression. Original static-lane test
/// (SlitherAderynTriage.testForcedEtherCannotBrickLauncherNativeFamily, unfixed source): 1 ETH force-sent to the
/// Launcher could not brick families but stayed in the Launcher forever ("forced ETH untouched and
/// unrecoverable"); stray ERC20 transfers were equally unrecoverable. Fixed: the Launcher holds nothing between
/// calls, so sweep() lets anyone move an idle balance out; it cannot run inside a Launcher call.
/// Review follow-up: a zero balance reverts (no zero-amount Swept spam); a fee-on-transfer stray cannot be swept
/// (exact delivery) and PoolManager ERC-6909 claims held by the Launcher are out of sweep's reach (documented).
contract HookrLauncherStrayAssetsTest is PeripheryFixture {
    function setUp() public {
        _setUpPeriphery();
    }

    function testForcedEtherAndStrayTokensAreSweepable() public {
        new LauncherForceSend{value: 1 ether}(payable(address(launcher)));
        tokenA.transfer(address(launcher), 7);
        (bytes32 family,,,) = _launch(false, true);
        (uint256 amount0, uint256 amount1) =
            launcher.withdraw(family, 0, 1e20, 0, 0, address(this), vm.getBlockTimestamp());
        assertGt(amount0 + amount1, 0);
        assertEq(address(launcher).balance, 1 ether, "families never touch the stray balance");
        assertEq(tokenA.balanceOf(address(launcher)), 7);

        address rescuer = address(0xAE5C);
        vm.prank(trader); // anyone
        assertEq(launcher.sweep(Currency.wrap(address(0)), rescuer), 1 ether);
        vm.prank(trader);
        assertEq(launcher.sweep(Currency.wrap(address(tokenA)), rescuer), 7);
        assertEq(rescuer.balance, 1 ether);
        assertEq(tokenA.balanceOf(rescuer), 7);
        assertEq(address(launcher).balance, 0);
        assertEq(tokenA.balanceOf(address(launcher)), 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidAmount.selector, uint256(0)));
        launcher.sweep(Currency.wrap(address(tokenA)), rescuer);
    }

    function testZeroSweepRevertsWithoutEvent() public {
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidAmount.selector, uint256(0)));
        launcher.sweep(Currency.wrap(address(tokenB)), address(0xAE5C));
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidAmount.selector, uint256(0)));
        launcher.sweep(Currency.wrap(address(0)), address(0xAE5C));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
    }

    function testFeeOnTransferStrayIsNotSweepable() public {
        // 1% transfer fee to the zero-address sink (burned).
        MockFeeOnTransferToken fee = new MockFeeOnTransferToken("Fee", "FEE", 1e24, 100, address(0));
        fee.transfer(address(launcher), 1e18);
        uint256 held = fee.balanceOf(address(launcher));
        vm.expectRevert(HookrSettlement.BalanceMismatch.selector);
        launcher.sweep(Currency.wrap(address(fee)), address(0xAE5C));
        assertEq(fee.balanceOf(address(launcher)), held, "documented limit: exact delivery refuses the fee");
    }

    function testClaimsHeldByLauncherAreOutOfReach() public {
        // A mistaken ERC-6909 claim credited to the Launcher is not an ERC20 balance; sweep sees nothing.
        (bytes32 family,,,) = _launch(false, true);
        launcher.withdrawWithClaims(family, 0, 1e20, 0, 0, address(this), 3, vm.getBlockTimestamp());
        uint256 id = uint256(uint160(address(tokenA)));
        uint256 claim = manager.balanceOf(address(this), id);
        assertGt(claim, 0);
        manager.transfer(address(launcher), id, claim);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidAmount.selector, uint256(0)));
        launcher.sweep(Currency.wrap(address(tokenA)), address(0xAE5C));
        assertEq(manager.balanceOf(address(launcher), id), claim, "documented limit: claims are not swept");
    }

    function testPlainEtherTransferIsRefused() public {
        (bool ok,) = address(launcher).call{value: 1}("");
        assertFalse(ok);
    }

    function testSweepRejectsBadRecipients() public {
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidRecipient.selector, address(0)));
        launcher.sweep(Currency.wrap(address(0)), address(0));
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidRecipient.selector, address(launcher)));
        launcher.sweep(Currency.wrap(address(0)), address(launcher));
    }

    function testSweepCannotRunInsideAnExit() public {
        new LauncherForceSend{value: 1 ether}(payable(address(launcher)));
        (bytes32 family,,,) = _launch(false, true);
        LauncherReentrantRecipient recipient = new LauncherReentrantRecipient(launcher);
        launcher.withdraw(family, 0, 1e20, 0, 0, address(recipient), vm.getBlockTimestamp());
        assertTrue(recipient.attempted());
        assertEq(bytes4(recipient.reason()), IHookrLauncher.Reentered.selector);
        assertEq(address(launcher).balance, 1 ether);
    }
}

/// @notice N-03 with a dev buy: stray ETH and tokens held by the Launcher before launchWithBuy are neither spent nor
///         moved by it, on a native and on an ERC-20 dev buy, and stay sweepable afterwards.
contract HookrLauncherStrayAssetsDevBuyTest is DevBuyFixture {
    function setUp() public {
        _setUpPeriphery();
    }

    function testStraysUntouchedByLaunchWithBuy() public {
        new LauncherForceSend{value: 1 ether}(payable(address(launcher)));
        tokenB.transfer(address(launcher), 7);
        Currency eth = Currency.wrap(address(0));
        (IHookrLauncher.Token memory t, address subject) = _newToken(eth, false);
        _launchWithBuy(t, _one(subject, eth), IHookrLauncher.DevBuy(0, 2e22, 1, 0));
        Currency quote = Currency.wrap(address(tokenB));
        (t, subject) = _newToken(quote, true);
        _launchWithBuy(t, _one(subject, quote), IHookrLauncher.DevBuy(0, 2e22, 1, 0));
        assertEq(address(launcher).balance, 1 ether, "the stray ETH was not spent on the dev buy");
        assertEq(tokenB.balanceOf(address(launcher)), 7, "the stray quote was not spent on the dev buy");
        assertEq(IERC20(subject).balanceOf(address(launcher)), 0, "no subject at rest");
        address rescuer = address(0xAE5C);
        vm.prank(trader);
        assertEq(launcher.sweep(eth, rescuer), 1 ether);
        vm.prank(trader);
        assertEq(launcher.sweep(quote, rescuer), 7);
    }
}
