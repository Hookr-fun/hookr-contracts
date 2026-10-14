// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {HookrLiquidityVault} from "../../src/extensions/HookrLiquidityVault.sol";
import {IHookrLiquidityVault} from "../../src/interfaces/IHookrLiquidityVault.sol";
import {ReferenceLP} from "../utils/ReferenceLP.sol";
import {LiquidityVaultSecurityBase} from "../utils/LiquidityVaultSecurityBase.sol";

/// @notice LV-02: the owner's only power is the skim on realised fees, bounded by maxSkimBps (at most
///         SKIM_CEILING_BPS, 20%), raised only through a queued SET_SKIM and lowered at once. Fixed here: `queue`
///         accepted any kind and any argument bytes, so a watcher could be shown a queued raise that no `setSkim` can
///         ever execute (above the bound, at or below the current skim, dirty or extra words, an unknown kind). The
///         vault now admits SET_SKIM with one canonical uint16 above the current skim and within the bound, and
///         TRANSFER_OWNER, like HookrCompliance (F-049).
contract HookrLiquidityVaultSkimGovernanceTest is LiquidityVaultSecurityBase {
    using PoolIdLibrary for PoolKey;

    bytes32 internal setSkimKind;

    function setUp() public {
        _setUpVault();
        setSkimKind = vault.SET_SKIM();
    }

    /// @notice Regression for the queue-time admission.
    function test_queueAdmitsOnlyExecutableSkimRaises() public {
        vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.InvalidSkim.selector, uint16(2_001)));
        vault.queue(setSkimKind, abi.encode(uint16(2_001)));

        bytes32 bogus = keccak256("SWEEP");
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.UnknownOperation.selector, bogus));
        vault.queue(bogus, abi.encode(uint16(1)));

        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NonCanonicalArguments.selector, setSkimKind));
        vault.queue(setSkimKind, abi.encodePacked(abi.encode(uint16(1_000)), uint256(1)));

        // A word whose high bits are dirty would read as 1,000 to a decoder that truncates; it never decodes here.
        vm.expectRevert();
        vault.queue(setSkimKind, abi.encode(uint256(1_000) | (uint256(1) << 16)));

        vm.expectRevert();
        vault.queue(setSkimKind, abi.encodePacked(uint16(1_000)));

        // A vault with a lower bound refuses a raise above it at queue time.
        HookrLiquidityVault low = new HookrLiquidityVault(manager, address(treasury), address(this), 1 days, 500);
        bytes32 kind = low.SET_SKIM();
        vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.InvalidSkim.selector, uint16(501)));
        low.queue(kind, abi.encode(uint16(501)));

        // A value that is not a raise is refused: setSkim applies it at once and would never consume it.
        vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.InvalidSkim.selector, uint16(0)));
        vault.queue(setSkimKind, abi.encode(uint16(0)));

        // The executable forms still queue, and a nomination still goes through the base check.
        bytes32 op = vault.queue(setSkimKind, abi.encode(uint16(2_000)));
        assertEq(vault.readyAt(op), vm.getBlockTimestamp() + vault.delay());
        vault.queue(vault.TRANSFER_OWNER(), abi.encode(address(treasury)));
    }

    /// @notice Regression: after a raise, a SET_SKIM at or below the current skim was admitted and announced although
    ///         setSkim applies such a value at once and never consumes it. It is now refused at queue time, and the
    ///         first value above the current skim is the lowest one admitted.
    function test_nonRaisingSkimRefusedAtQueue() public {
        _raiseSkim(1_000);
        for (uint16 bps = 0; bps <= 1_000; bps += 250) {
            vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.InvalidSkim.selector, bps));
            vault.queue(setSkimKind, abi.encode(bps));
            assertEq(vault.readyAt(vault.operationHash(setSkimKind, abi.encode(bps))), 0, "announced");
        }
        bytes32 next = vault.queue(setSkimKind, abi.encode(uint16(1_001)));
        assertEq(vault.readyAt(next), vm.getBlockTimestamp() + vault.delay());

        // A lowering applies at once without any queue, and the bar follows the skim down.
        vault.setSkim(500);
        assertEq(vault.skimBps(), 500);
        vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.InvalidSkim.selector, uint16(500)));
        vault.queue(setSkimKind, abi.encode(uint16(500)));
        bytes32 raise = vault.queue(setSkimKind, abi.encode(uint16(501)));
        vm.warp(vault.readyAt(raise));
        vault.setSkim(501);
        assertEq(vault.readyAt(raise), 0, "consumed");
        assertEq(vault.skimBps(), 501);

        // At the bound nothing more is admitted.
        _raiseSkim(vault.maxSkimBps());
        uint16 top = vault.maxSkimBps();
        vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.InvalidSkim.selector, top));
        vault.queue(setSkimKind, abi.encode(top));
    }

    /// @notice No path takes more than maxSkimBps of a realised fee, and none touches principal.
    function testFuzz_skimNeverAboveBound(uint16 bps, uint96 amount) public {
        bps = uint16(bound(bps, 0, 4_000));
        uint256 a = bound(amount, 1e18, 1e21);
        if (bps > vault.maxSkimBps()) {
            vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.InvalidSkim.selector, bps));
            vault.queue(setSkimKind, abi.encode(bps));
            vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.InvalidSkim.selector, bps));
            vault.setSkim(bps);
            bps = vault.maxSkimBps();
        }
        if (bps != 0) _raiseSkim(bps);
        PoolKey memory k = _plainPool(10_000);
        ReferenceLP ref = _ref();
        (, uint128 liquidity, uint256 paid0, uint256 paid1) = _deposit(alice, k, a, a);
        (int256 p0, int256 p1,,) = ref.modify(k, LO, HI, int256(uint256(liquidity)));
        assertEq(paid0, uint256(-p0));
        assertEq(paid1, uint256(-p1));
        _churn(k, 2, a / 2);
        (uint256 out0, uint256 out1, uint256 f0, uint256 f1) = _withdraw(alice, k, liquidity);
        (int256 r0, int256 r1, uint256 rf0, uint256 rf1) = ref.modify(k, LO, HI, -int256(uint256(liquidity)));
        assertEq(out0, uint256(r0), "principal0");
        assertEq(out1, uint256(r1), "principal1");
        uint256 s0 = vault.protocolFees(k.currency0);
        uint256 s1 = vault.protocolFees(k.currency1);
        assertLe(s0, rf0 * vault.maxSkimBps() / 10_000);
        assertLe(s1, rf1 * vault.maxSkimBps() / 10_000);
        assertEq(s0, rf0 * bps / 10_000);
        assertEq(s1, rf1 * bps / 10_000);
        assertApproxEqAbs(f0 + s0, rf0, 2);
        assertApproxEqAbs(f1 + s1, rf1, 2);
    }

    /// @notice A raise waits the full delay, expires after GRACE, dies with any lowering, and needs the owner.
    function test_timelockAndBrakes() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, mallory));
        vault.queue(setSkimKind, abi.encode(uint16(2_000)));

        bytes32 op = vault.queue(setSkimKind, abi.encode(uint16(2_000)));
        uint48 ready = vault.readyAt(op);
        vm.warp(uint256(ready) - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, ready));
        vault.setSkim(2_000);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, mallory));
        vault.setSkim(2_000);

        // Past readyAt + GRACE the raise is dead and must be queued again.
        vm.warp(uint256(ready) + vault.GRACE() + 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Expired.selector, op, ready + vault.GRACE()));
        vault.setSkim(2_000);

        // A lowering voids every raise queued before it, so the brake holds for at least one full delay.
        _raiseSkim(1_000);
        bytes32 again = vault.queue(setSkimKind, abi.encode(uint16(2_000)));
        vm.warp(vault.readyAt(again));
        vault.setSkim(0);
        vm.expectPartialRevert(IHookrGoverned.NotReady.selector);
        vault.setSkim(2_000);
        assertEq(vault.skimBps(), 0);
        bytes32 fresh = vault.queue(setSkimKind, abi.encode(uint16(2_000)));
        assertEq(vault.readyAt(fresh), vm.getBlockTimestamp() + vault.delay());

        // Cancelling removes a queued raise.
        vault.cancel(fresh);
        vm.warp(vm.getBlockTimestamp() + vault.delay());
        vm.expectPartialRevert(IHookrGoverned.NotReady.selector);
        vault.setSkim(2_000);
    }

    /// @notice The owner, its nominee and the accepting account are never EIP-7702 delegated accounts.
    function test_delegatedOwnersRefused() public {
        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(0xde1e)));
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, delegated));
        new HookrLiquidityVault(manager, address(treasury), delegated, 1 days, 2_000);

        bytes32 transfer = vault.TRANSFER_OWNER();
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, delegated));
        vault.queue(transfer, abi.encode(delegated));

        // A nominee that turns into a delegated account after its nomination cannot accept.
        address nominee = makeAddr("nominee");
        vault.queue(transfer, abi.encode(nominee));
        vm.warp(vm.getBlockTimestamp() + vault.delay());
        vault.transferOwnership(nominee);
        vm.etch(nominee, abi.encodePacked(hex"ef0100", address(0xde1e)));
        vm.prank(nominee);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, nominee));
        vault.acceptOwnership();
        assertEq(vault.owner(), address(this));
    }

    /// @notice Known limit, pinned: a raise applies to fees realised after it, including fees the pool accrued before
    ///         it that nobody realised. Anyone can poke the range during the delay to realise them at the old rate.
    function test_pinned_raiseAppliesToUnrealisedFees() public {
        PoolKey memory k = _plainPool(3000);
        _deposit(alice, k, 1e20, 1e20);
        _churn(k, 3, 5e19);
        uint256 snap = vm.snapshotState();

        // Nobody pokes: the fees earned at a zero skim are skimmed at the new rate.
        _raiseSkim(2_000);
        vault.poke(k, LO, HI);
        uint256 skimmedLate = vault.protocolFees(k.currency0) + vault.protocolFees(k.currency1);
        assertGt(skimmedLate, 0);

        // A poke during the delay realises them first, at zero.
        vm.revertToState(snap);
        bytes32 op = vault.queue(setSkimKind, abi.encode(uint16(2_000)));
        vm.prank(alice);
        vault.poke(k, LO, HI);
        vm.warp(vault.readyAt(op));
        vault.setSkim(2_000);
        vault.poke(k, LO, HI);
        (uint256 f0, uint256 f1) = _claim(alice, k);
        assertEq(vault.protocolFees(k.currency0) + vault.protocolFees(k.currency1), 0);
        assertApproxEqAbs(f0 + f1, skimmedLate * 5, 12);
    }
}
