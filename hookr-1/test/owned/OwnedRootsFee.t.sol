// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";
import {HookrOwnedRootFactory} from "../../src/owned/HookrOwnedRootFactory.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {OwnedFeeTarget} from "./OwnedRootsMocks.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice Decision 2: a bounded per-root deploy fee, a HookrTreasury term from day one, that the factory takes from
///         every deployer and forwards to the treasury's target in the same transaction.
///         Audit finding M-1.
contract OwnedRootsFeeTest is OwnedRootsFixture {
    bytes internal code;
    bytes internal rulesCode;

    function setUp() public {
        _setUpOwned();
        code = type(HookrRoot).creationCode;
        rulesCode = type(HookrRules).creationCode;
    }

    // ───────────────────────────── the treasury term ─────────────────────────────

    /// @dev keccak256(abi.encode(uint256(keccak256("hookr.treasury")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant TREASURY_SLOT = 0xfbe7548a70873d48ea7fddfba1199106377ceedcd42dbef7dc33de62b5287a00;

    /// @notice The term is appended to the treasury's namespaced State: field 13, after every field the treasury had,
    ///         which keep their slots (the owner at 0, the target at 2, the Hookr minimum at 9).
    function test_feeTermIsAppendedToTheTreasuryState() public {
        uint256 base = uint256(TREASURY_SLOT);
        assertEq(address(uint160(uint256(vm.load(address(hookrTreasury), bytes32(base))))), address(this));
        assertEq(address(uint160(uint256(vm.load(address(hookrTreasury), bytes32(base + 2))))), TARGET);
        assertEq(uint16(uint256(vm.load(address(hookrTreasury), bytes32(base + 9)))), 1000, "the minimum's current");
        bytes32 word = vm.load(address(hookrTreasury), bytes32(base + 13));
        assertEq(uint16(uint256(word)), 100, "0.01 in 0.0001 units");
        hookrTreasury.proposeOwnedRootFee(0.25 ether);
        word = vm.load(address(hookrTreasury), bytes32(base + 13));
        assertEq(uint16(uint256(word) >> 16), 2500, "the pending value");
        assertEq(uint64(uint256(word) >> 32), vm.getBlockTimestamp() + hookrTreasury.TERMS_DELAY(), "its readyAt");
    }

    function test_feeIsLiveFromConstructionAtTheDefault() public {
        assertEq(hookrTreasury.ownedRootFee(), 0.01 ether);
        assertEq(hookrTreasury.DEFAULT_OWNED_ROOT_FEE(), 0.01 ether);
        assertEq(hookrTreasury.MAX_OWNED_ROOT_FEE(), 1 ether);
        assertEq(hookrTreasury.OWNED_ROOT_FEE_UNIT(), 0.0001 ether);
        (uint256 pending, uint256 readyAt) = hookrTreasury.pendingOwnedRootFee();
        assertEq(pending, 0);
        assertEq(readyAt, 0);
        assertEq(factory.deployFee(), 0.01 ether);
        // The constructor says so.
        vm.recordLogs();
        HookrTreasury t = new HookrTreasury(address(this), TARGET, manager);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(t) && logs[i].topics[0] == IHookrTreasury.OwnedRootFeeSet.selector) {
                (uint256 previous, uint256 current) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(previous, 0);
                assertEq(current, 0.01 ether);
                seen = true;
            }
        }
        assertTrue(seen);
    }

    /// @notice The fee moves like the other fee terms: proposed by the owner, accepted after TERMS_DELAY and before
    ///         TERMS_GRACE runs out, bounded, in steps of 0.0001.
    function test_feeChangesThroughTheTermsTimelock() public {
        vm.prank(stranger);
        vm.expectRevert(IHookrTreasury.NotOwner.selector);
        hookrTreasury.proposeOwnedRootFee(0.02 ether);
        vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
        hookrTreasury.proposeOwnedRootFee(1 ether + 0.0001 ether);
        vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
        hookrTreasury.proposeOwnedRootFee(0.01 ether + 1);
        vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
        hookrTreasury.proposeOwnedRootFee(0.01 ether);
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        hookrTreasury.acceptOwnedRootFee();

        uint256 readyAt = vm.getBlockTimestamp() + hookrTreasury.TERMS_DELAY();
        vm.expectEmit(false, false, false, true, address(hookrTreasury));
        emit IHookrTreasury.OwnedRootFeeProposed(0.01 ether, 1 ether, readyAt);
        hookrTreasury.proposeOwnedRootFee(1 ether);
        (uint256 pending, uint256 pendingReadyAt) = hookrTreasury.pendingOwnedRootFee();
        assertEq(pending, 1 ether);
        assertEq(pendingReadyAt, readyAt);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.TermsNotReady.selector, readyAt));
        hookrTreasury.acceptOwnedRootFee();
        assertEq(hookrTreasury.ownedRootFee(), 0.01 ether, "nothing moves before the delay");
        vm.warp(readyAt);
        vm.prank(stranger);
        vm.expectRevert(IHookrTreasury.NotOwner.selector);
        hookrTreasury.acceptOwnedRootFee();
        vm.expectEmit(false, false, false, true, address(hookrTreasury));
        emit IHookrTreasury.OwnedRootFeeSet(0.01 ether, 1 ether);
        hookrTreasury.acceptOwnedRootFee();
        assertEq(hookrTreasury.ownedRootFee(), 1 ether);
        assertEq(factory.deployFee(), 1 ether);

        // Zero is allowed: free deployments.
        _setDeployFee(0);
        assertEq(factory.deployFee(), 0);

        // A proposal lapses TERMS_GRACE after it matured.
        uint256 lapsing = vm.getBlockTimestamp() + hookrTreasury.TERMS_DELAY();
        hookrTreasury.proposeOwnedRootFee(0.3 ether);
        vm.warp(lapsing + hookrTreasury.TERMS_GRACE() + 1);
        (pending, pendingReadyAt) = hookrTreasury.pendingOwnedRootFee();
        assertEq(pendingReadyAt, 0, "a lapsed proposal is not pending");
        vm.expectRevert(
            abi.encodeWithSelector(IHookrTreasury.TermsExpired.selector, lapsing + hookrTreasury.TERMS_GRACE())
        );
        hookrTreasury.acceptOwnedRootFee();

        // The owner withdraws a proposal.
        hookrTreasury.proposeOwnedRootFee(0.3 ether);
        vm.expectEmit(false, false, false, true, address(hookrTreasury));
        emit IHookrTreasury.OwnedRootFeeProposalCancelled(0.3 ether);
        hookrTreasury.cancelOwnedRootFee();
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        hookrTreasury.cancelOwnedRootFee();
        assertEq(hookrTreasury.ownedRootFee(), 0);
    }

    /// @notice A change of owner voids the pending fee, as it voids every fee-terms proposal.
    function test_ownerChangeVoidsThePendingFee() public {
        hookrTreasury.proposeOwnedRootFee(0.5 ether);
        address next = address(0x0E7);
        hookrTreasury.proposeOwner(next);
        vm.expectEmit(false, false, false, true, address(hookrTreasury));
        emit IHookrTreasury.OwnedRootFeeProposalCancelled(0.5 ether);
        vm.prank(next);
        hookrTreasury.acceptOwnership();
        (, uint256 readyAt) = hookrTreasury.pendingOwnedRootFee();
        assertEq(readyAt, 0);
        vm.warp(vm.getBlockTimestamp() + hookrTreasury.TERMS_DELAY());
        vm.prank(next);
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        hookrTreasury.acceptOwnedRootFee();
        assertEq(hookrTreasury.ownedRootFee(), 0.01 ether);
    }

    function testFuzz_feeBoundsAndSteps(uint256 fee) public {
        fee = bound(fee, 0, 2 ether);
        bool ok = fee <= 1 ether && fee % 0.0001 ether == 0 && fee != 0.01 ether;
        if (!ok) vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
        hookrTreasury.proposeOwnedRootFee(fee);
        if (!ok) return;
        vm.warp(vm.getBlockTimestamp() + hookrTreasury.TERMS_DELAY());
        hookrTreasury.acceptOwnedRootFee();
        assertEq(hookrTreasury.ownedRootFee(), fee);
    }

    // ───────────────────────────── the factory takes it ─────────────────────────────

    /// @notice Every deployment sends exactly the fee, which reaches the treasury's target in the same transaction;
    ///         nothing stays in the factory or the treasury.
    function test_deploymentPaysTheFeeToTheTarget() public {
        bytes32 salt = _mine(brand);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        uint256 before = TARGET.balance;
        vm.startPrank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.WrongFee.selector, 0, 0.01 ether));
        factory.deploy(code, rulesCode, sel, salt);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.WrongFee.selector, 0.02 ether, 0.01 ether));
        factory.deploy{value: 0.02 ether}(code, rulesCode, sel, salt);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.WrongFee.selector, 0.01 ether - 1, 0.01 ether));
        factory.deploy{value: 0.01 ether - 1}(code, rulesCode, sel, salt);
        address predicted = factory.computeAddress(brand, salt);
        vm.expectEmit(true, true, false, true, address(factory));
        emit IHookrOwnedRootFactory.DeployFeePaid(predicted, TARGET, 0.01 ether);
        address r = factory.deploy{value: 0.01 ether}(code, rulesCode, sel, salt);
        vm.stopPrank();
        assertEq(r, predicted);
        assertEq(TARGET.balance - before, 0.01 ether, "the target received the fee");
        assertEq(address(factory).balance, 0);
        assertEq(address(hookrTreasury).balance, 0);
    }

    /// @notice The fee in force when the deployment executes is the one it pays: a change accepted after a deployer
    ///         read it refuses the stale value.
    function test_feeChangeRefusesAStaleValue() public {
        bytes32 salt = _mine(brand);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        uint256 read = factory.deployFee();
        _setDeployFee(0.25 ether);
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.WrongFee.selector, read, 0.25 ether));
        factory.deploy{value: read}(code, rulesCode, sel, salt);
        _deployWith(factory, brand, sel, salt);
    }

    /// @notice With a zero fee no value is taken and nothing is forwarded.
    function test_zeroFeeTakesNothing() public {
        _setDeployFee(0);
        bytes32 salt = _mine(brand);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        uint256 before = TARGET.balance;
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.WrongFee.selector, 1, 0));
        factory.deploy{value: 1}(code, rulesCode, sel, salt);
        vm.recordLogs();
        vm.prank(brand);
        factory.deploy(code, rulesCode, sel, salt);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IHookrOwnedRootFactory.DeployFeePaid.selector, "no fee paid");
        }
        assertEq(TARGET.balance, before);
    }

    /// @notice A target that refuses the fee, or burns the forward's gas, reverts the whole deployment.
    function test_aFailedForwardRevertsTheDeployment() public {
        OwnedFeeTarget target = new OwnedFeeTarget();
        _moveTarget(address(target));
        bytes32 salt = _mine(brand);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        address predicted = factory.computeAddress(brand, salt);
        target.set(OwnedFeeTarget.Mode.REFUSE, factory);
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.FeeNotForwarded.selector, address(target)));
        factory.deploy{value: 0.01 ether}(code, rulesCode, sel, salt);
        target.set(OwnedFeeTarget.Mode.BURN, factory);
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.FeeNotForwarded.selector, address(target)));
        factory.deploy{value: 0.01 ether}(code, rulesCode, sel, salt);
        assertEq(predicted.code.length, 0, "nothing deployed");
        assertEq(factory.allDeploymentsLength(), 0);
        target.set(OwnedFeeTarget.Mode.ACCEPT, factory);
        _deployWith(factory, brand, sel, salt);
        assertEq(address(target).balance, 0.01 ether);
    }

    /// @notice A target that re-enters the factory with the fee is refused by the factory's lock; the outer
    ///         deployment completes and the target keeps the fee.
    function test_aReenteringTargetIsRefused() public {
        OwnedFeeTarget target = new OwnedFeeTarget();
        _moveTarget(address(target));
        target.set(OwnedFeeTarget.Mode.REENTER, factory);
        (HookrRoot r,) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        assertTrue(address(r).code.length != 0);
        assertFalse(target.reentered());
        assertEq(target.reentryError(), IHookrOwnedRootFactory.Reentrancy.selector);
        assertEq(factory.allDeploymentsLength(), 1);
        assertEq(address(target).balance, 0.01 ether);
    }

    /// @notice M-1, cap exhaustion with the fee: filling the factory's 500 slots now costs 500 fees on top of the gas.
    ///         The brakes stay instant (deactivateRootFactory, pauseNewMarkets) and a fresh factory is one timelocked
    ///         SET_ROOT_FACTORY away. This records the cost at the default fee and the measured deployment gas.
    function test_capExhaustionCostWithTheFee() public {
        HookrOwnedRootFactory small = _newFactory(3);
        _activateFactory(address(small));
        uint256 gasTotal;
        for (uint256 i; i < 3; ++i) {
            address filler = address(uint160(0xF111E0 + i));
            bytes32 salt = _mineFor(address(small), filler, 1);
            IHookrOwnedRootFactory.RootSelections memory sel = _sel(filler, F.ALL_FEATURES);
            vm.deal(filler, 1 ether);
            vm.prank(filler);
            uint256 g = gasleft();
            small.deploy{value: 0.01 ether}(code, rulesCode, sel, salt);
            gasTotal += g - gasleft();
        }
        bytes32 late = _mineFor(address(small), brand, 1);
        IHookrOwnedRootFactory.RootSelections memory brandSel = _sel(brand, F.ALL_FEATURES);
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.FactoryFull.selector, uint256(3)));
        small.deploy{value: 0.01 ether}(code, rulesCode, brandSel, late);
        uint256 perRootGas = gasTotal / 3;
        console2.log("M-1: execution gas per filler deployment", perRootGas);
        console2.log("M-1: fees to fill 500 slots at the default fee (wei)", 500 * hookrTreasury.ownedRootFee());
        console2.log("M-1: execution gas to fill 500 slots", 500 * perRootGas);
        assertEq(500 * hookrTreasury.ownedRootFee(), 5 ether, "5 of the native currency in fees alone");
        // The brake and the replacement.
        registry.deactivateRootFactory(address(small));
        HookrOwnedRootFactory fresh = _newFactory(500);
        _activateFactory(address(fresh));
        _deployWith(fresh, brand, brandSel, _mineFor(address(fresh), brand, 1));
        assertEq(fresh.allDeploymentsLength(), 1);
    }

    /// @dev Moves the treasury's target to `next` through its 30-minute delay.
    function _moveTarget(address next) internal {
        hookrTreasury.proposeTarget(next);
        vm.warp(vm.getBlockTimestamp() + hookrTreasury.TARGET_DELAY());
        hookrTreasury.acceptTarget();
    }
}
