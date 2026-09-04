// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {BlueprintSeeds} from "./utils/BlueprintSeeds.sol";

/// @notice Regression tests for the audit findings that live entirely in the launchpad and need
///         no PoolManager: parameter validation (#1, #5), the creator payout escape hatch (#7)
///         and two-step ownership (#8). Pool-side findings are in Regression.t.sol.
contract RegressionLaunchpadTest is Test {
    HookrLaunchpad pad;
    address constant PM = address(0xDEAD001);

    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint96 constant TARGET = 1 ether;

    function setUp() public {
        pad = new HookrLaunchpad(IPoolManager(PM));
        BlueprintSeeds.seed(pad);
        RegStubHook impl = new RegStubHook();
        uint160 flags = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
        address target;
        for (uint256 i = 1; i < 200_000; i++) {
            target = address(uint160(uint256(keccak256(abi.encode(i)))));
            if (uint160(target) & 0x3FFF == flags && target.code.length == 0) break;
        }
        vm.etch(target, address(impl).code);
        RegStubHook(payable(target)).setLaunchpad(address(pad));
        RegStubHook(payable(target)).setPoolManager(PM);
        pad.setHook(HookrHook(payable(target)));

        vm.deal(address(this), 1000 ether);
        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ------------------------------------------------------------ helpers

    function _params() internal pure returns (HookrLaunchpad.HookParams memory p) {
        p = HookrLaunchpad.HookParams({
            guardBlocks: 20,
            maxBuyBps: 50,
            snipeTaxPips: 400_000,
            baseFeePips: 3000,
            maxFeePips: 30_000,
            surgeSens: 5,
            burnBps: 100,
            burnTriggerWei: 0,
            lpBps: 25,
            potBps: 50,
            potEveryNBuys: 500,
            potMinBuyWei: 0.001 ether
        });
    }

    function _args(HookrLaunchpad.HookParams memory p) internal view returns (HookrLaunchpad.LaunchArgs memory a) {
        a.name = "Kraken Klub";
        a.symbol = "KRKN";
        a.tagline = "release the kraken";
        a.logoURI = "";
        a.expectedCreator = creator;
        a.targetRaiseWei = TARGET;
        a.blueprintId = 0;
        a.custom = p;
    }

    function _launch(HookrLaunchpad.HookParams memory p) internal returns (address token) {
        // NOTE: read the fee first. An external call inside the argument list would consume the
        // pending vm.prank / vm.expectRevert instead of the launch itself.
        uint256 fee = pad.creationFeeWei();
        HookrLaunchpad.LaunchArgs memory a = _args(p);
        vm.prank(creator);
        token = pad.launch{value: fee}(a);
    }

    function _expectLaunchRejected(HookrLaunchpad.HookParams memory p) internal {
        uint256 fee = pad.creationFeeWei();
        HookrLaunchpad.LaunchArgs memory a = _args(p);
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        pad.launch{value: fee}(a);
    }

    // ------------------------------------------------------------ #1 maxFeePips == 0

    /// @dev The builder emits maxFeePips == 0 when no surge block is stacked. The launchpad must
    ///      accept it AND hand the hook a normalized ceiling equal to baseFeePips, otherwise the
    ///      launch sells out its curve and then reverts forever at graduation.
    function test_fix1_maxFeeZero_normalizesToBaseFee_inTheConfigTheHookWillSee() public view {
        HookrLaunchpad.HookParams memory p = _params();
        p.maxFeePips = 0;
        p.surgeSens = 0;

        HookrHook.PoolConfig memory cfg = pad.previewPoolConfig(p, 0, 1e9, pad.SUPPLY());
        assertEq(cfg.baseFeePips, 3000);
        assertEq(cfg.maxFeePips, 3000, "maxFee must be normalized up to baseFee, not left at 0");
        // The hook's own rule is `maxFeePips < baseFeePips => BadConfig`.
        assertGe(cfg.maxFeePips, cfg.baseFeePips);
    }

    /// @dev The UI no longer relies on the launchpad's normalization: `compileStack` in
    ///      src/lib/hooks-model.ts raises maxFeePips to baseFeePips itself, so an empty builder
    ///      stack now submits {base 3000, max 3000, potEveryNBuys 0} instead of a literal 0
    ///      ceiling. Pin that exact struct — it must launch, and it must build a surge-free config
    ///      the hook accepts. If the frontend default drifts, this is what catches it.
    function test_uiDefaultStack_maxFeeEqualsBase_launchesAndIsSurgeFree() public {
        HookrLaunchpad.HookParams memory p = HookrLaunchpad.HookParams({
            guardBlocks: 0,
            maxBuyBps: 0,
            snipeTaxPips: 0,
            baseFeePips: 3000, // hooks-model DEFAULT_BASE_FEE_PIPS
            maxFeePips: 3000, // == base means "no surge block stacked", never 0
            surgeSens: 0,
            burnBps: 0,
            burnTriggerWei: 0,
            lpBps: 0,
            potBps: 0,
            potEveryNBuys: 0,
            potMinBuyWei: 0
        });

        address token = _launch(p);
        assertTrue(token != address(0), "the UI's default stack must be launchable");

        HookrHook.PoolConfig memory cfg = pad.previewPoolConfig(p, 0, 1e9, pad.SUPPLY());
        assertEq(cfg.baseFeePips, 3000);
        assertEq(cfg.maxFeePips, cfg.baseFeePips, "no surge block must mean max == base");
        assertEq(cfg.potEveryNBuys, 0);
    }

    /// @dev Both ends of the builder's "pot pays every N buys" slider must sit inside the range
    ///      the contracts enforce (2..100,000), so no reachable slider position can be rejected.
    function test_uiPotSliderRange_isInsideTheContractBounds() public view {
        HookrLaunchpad.HookParams memory p = _params();
        p.potEveryNBuys = 100; // slider min
        assertEq(pad.previewPoolConfig(p, 0, 1e9, pad.SUPPLY()).potEveryNBuys, 100);
        p.potEveryNBuys = 5000; // slider max
        assertEq(pad.previewPoolConfig(p, 0, 1e9, pad.SUPPLY()).potEveryNBuys, 5000);
    }

    /// @dev A genuinely inverted ceiling is still rejected — normalization must not weaken this.
    function test_fix1_maxFeeBelowBase_stillRejected() public {
        HookrLaunchpad.HookParams memory p = _params();
        p.baseFeePips = 3000;
        p.maxFeePips = 1000;
        _expectLaunchRejected(p);
    }

    /// @dev The two validators must agree on the SAME value. Fuzz the whole param space: anything
    ///      the launchpad accepts must be a config the hook accepts, or graduation can brick.
    function testFuzz_fix1_launchpadAcceptance_impliesHookAcceptance(
        uint24 baseFeePips,
        uint24 maxFeePips,
        uint24 snipeTaxPips,
        uint16 burnBps,
        uint16 lpBps,
        uint16 potBps,
        uint32 potEveryNBuys,
        uint96,
        uint16 surgeSens
    ) public {
        HookrLaunchpad.HookParams memory p = HookrLaunchpad.HookParams({
            guardBlocks: 10,
            maxBuyBps: 100,
            snipeTaxPips: uint24(bound(snipeTaxPips, 0, 600_000)),
            baseFeePips: uint24(bound(baseFeePips, 0, 600_000)),
            maxFeePips: uint24(bound(maxFeePips, 0, 600_000)),
            surgeSens: uint16(bound(surgeSens, 0, 12)),
            burnBps: uint16(bound(burnBps, 0, 600)),
            burnTriggerWei: 0,
            lpBps: uint16(bound(lpBps, 0, 600)),
            potBps: uint16(bound(potBps, 0, 600)),
            potEveryNBuys: uint32(bound(potEveryNBuys, 0, 200_000)),
            potMinBuyWei: 0.001 ether
        });

        // Did the launchpad accept this stack?
        (bool accepted,) = address(pad).call(abi.encodeCall(HookrLaunchpad.saveBlueprint, ("fuzz", p, 0)));
        if (!accepted) return; // rejected up front: nothing to prove

        // Then the hook must accept the config graduation would build from it.
        HookrHook.PoolConfig memory cfg = pad.previewPoolConfig(p, 0, 1e9, pad.SUPPLY());
        assertLe(cfg.baseFeePips, 500_000);
        assertLe(cfg.maxFeePips, 500_000);
        assertGe(cfg.maxFeePips, cfg.baseFeePips, "hook would revert BadConfig on maxFee<base");
        assertLe(uint256(cfg.baseFeePips) + cfg.snipeTaxPips, 500_000);
        assertLe(uint256(cfg.burnBps) + cfg.lpBps + cfg.potBps, 1000);
        assertLe(cfg.royaltyBps, 1000);
        if (cfg.potBps > 0) {
            assertGe(cfg.potEveryNBuys, 2);
            assertLe(cfg.potEveryNBuys, 100_000);
            assertGe(cfg.potMinBuyWei, pad.MIN_POT_BUY_WEI());
        }
        assertLe(cfg.surgeSens, 10);
    }

    // ------------------------------------------------------------ #5 output auto-burn / pot floor

    function test_fix5_deprecatedBurnTriggerZero_isRequiredWhenBurnEnabled() public {
        HookrLaunchpad.HookParams memory p = _params();
        p.burnBps = 100;
        p.burnTriggerWei = 0;
        _launch(p);
    }

    /// @dev Compatibility-only fields must not be silently ignored: a nonzero legacy trigger would
    ///      imply behavior that v3 does not provide, so both launch and blueprint creation reject.
    function test_fix5_nonzeroDeprecatedBurnTrigger_isRejected() public {
        HookrLaunchpad.HookParams memory p = _params();
        p.burnBps = 100;
        p.burnTriggerWei = type(uint96).max;
        _expectLaunchRejected(p);

        vm.prank(bob);
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        pad.saveBlueprint("Misleading legacy trigger", p, 0);
    }

    /// @dev The compatibility-only field must be zero even when burn is disabled.
    function test_fix5_burnDisabled_nonzeroTriggerStillRejected() public {
        HookrLaunchpad.HookParams memory p = _params();
        p.burnBps = 0;
        p.burnTriggerWei = 1;
        _expectLaunchRejected(p);
    }

    function test_fix2_potMinBelowProtocolFloor_rejectedForLaunchAndBlueprint() public {
        HookrLaunchpad.HookParams memory p = _params();
        p.potMinBuyWei = uint96(pad.MIN_POT_BUY_WEI() - 1);
        _expectLaunchRejected(p);

        vm.prank(bob);
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        pad.saveBlueprint("Dust slots", p, 0);
    }

    /// @dev V3 royalties are funded only by the native LP/pot cuts. Anti-snipe, surge, and
    ///      Auto Burn may still be saved as blueprints, but they cannot advertise a royalty that
    ///      has no revenue source.
    function test_fix9_nonRevenueBlueprint_rejectsPhantomRoyaltyButAllowsZero() public {
        HookrLaunchpad.HookParams memory p = _params();
        p.lpBps = 0;
        p.potBps = 0;
        p.potEveryNBuys = 0;
        p.potMinBuyWei = 0;

        vm.prank(bob);
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        pad.saveBlueprint("Auto Burn royalty", p, 1);

        vm.prank(bob);
        uint32 id = pad.saveBlueprint("Auto Burn", p, 0);
        assertEq(pad.getBlueprint(id).royaltyBps, 0);
    }

    // ------------------------------------------------------------ #7 creator payout

    function test_fix7_nonReceivingCreator_canNominateAPayoutAddress() public {
        RejectsEth deadbeatCreator = new RejectsEth();
        vm.deal(address(deadbeatCreator), 1 ether); // it can SEND ETH, it just cannot receive any
        HookrLaunchpad.HookParams memory p = _params();

        uint256 fee = pad.creationFeeWei();
        HookrLaunchpad.LaunchArgs memory a = _args(p);
        a.expectedCreator = address(deadbeatCreator);
        vm.prank(address(deadbeatCreator));
        address token = pad.launch{value: fee}(a);

        vm.prank(alice);
        pad.buy{value: 0.1 ether}(token, 0);
        uint256 fees = pad.creatorFeesWei(token);
        assertGt(fees, 0);

        // Default payout is the creator, which cannot receive ETH: the fees are stuck.
        assertEq(pad.creatorPayoutOf(token), address(deadbeatCreator));
        vm.expectRevert(HookrLaunchpad.EthTransferFailed.selector);
        pad.claimCreatorFees(token);

        // Only the creator may redirect them.
        vm.prank(bob);
        vm.expectRevert(HookrLaunchpad.NotCreator.selector);
        pad.setCreatorPayout(token, bob);

        vm.prank(address(deadbeatCreator));
        pad.setCreatorPayout(token, alice);
        assertEq(pad.creatorPayoutOf(token), alice);

        uint256 before = alice.balance;
        pad.claimCreatorFees(token);
        assertEq(alice.balance, before + fees, "fees delivered to the nominated address");
        assertEq(pad.creatorFeesWei(token), 0);
    }

    function test_fix7_payoutResetsToCreator_onZero() public {
        HookrLaunchpad.HookParams memory p = _params();
        address token = _launch(p);
        vm.prank(creator);
        pad.setCreatorPayout(token, alice);
        assertEq(pad.creatorPayoutOf(token), alice);
        vm.prank(creator);
        pad.setCreatorPayout(token, address(0));
        assertEq(pad.creatorPayoutOf(token), creator, "zero restores the default");
    }

    // ------------------------------------------------------------ #8 two-step ownership

    function test_fix8_ownershipIsTwoStep_andRejectsZero() public {
        assertEq(pad.owner(), address(this));

        vm.expectRevert(HookrLaunchpad.ZeroAddress.selector);
        pad.proposeOwner(address(0));

        vm.prank(bob);
        vm.expectRevert(HookrLaunchpad.NotOwner.selector);
        pad.proposeOwner(bob);

        pad.proposeOwner(alice);
        assertEq(pad.pendingOwner(), alice);
        assertEq(pad.owner(), address(this), "proposing must not hand over anything yet");

        vm.prank(bob);
        vm.expectRevert(HookrLaunchpad.NotOwner.selector);
        pad.acceptOwnership();

        vm.prank(alice);
        pad.acceptOwnership();
        assertEq(pad.owner(), alice);
        assertEq(pad.pendingOwner(), address(0));

        // The old owner is really out.
        vm.expectRevert(HookrLaunchpad.NotOwner.selector);
        pad.setCreationFee(0.01 ether);
        vm.prank(alice);
        pad.setCreationFee(0.01 ether);
        assertEq(pad.creationFeeWei(), 0.01 ether);
    }

    function test_fix8_protocolFeeWithdrawalRejectsZeroWithoutBurningAccounting() public {
        _launch(_params());
        uint256 accrued = pad.protocolFeesWei();
        uint256 balanceBefore = address(pad).balance;
        assertGt(accrued, 0);

        vm.expectRevert(HookrLaunchpad.ZeroAddress.selector);
        pad.withdrawProtocolFees(address(0));

        assertEq(pad.protocolFeesWei(), accrued);
        assertEq(address(pad).balance, balanceBefore);
    }

    function test_fix8_setHookRejectsMismatchedPoolManagerBeforeOneShotWrite() public {
        HookrLaunchpad freshPad = new HookrLaunchpad(IPoolManager(PM));
        RegStubHook impl = new RegStubHook();
        uint160 flags = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
        address target;
        for (uint256 i = 200_001; i < 500_000; i++) {
            target = address(uint160(uint256(keccak256(abi.encode(i)))));
            if (uint160(target) & 0x3FFF == flags && target.code.length == 0) break;
        }
        vm.etch(target, address(impl).code);
        RegStubHook(payable(target)).setLaunchpad(address(freshPad));
        RegStubHook(payable(target)).setPoolManager(address(0xBAD0));

        vm.expectRevert(HookrLaunchpad.HookFlagsInvalid.selector);
        freshPad.setHook(HookrHook(payable(target)));
        assertEq(address(freshPad.hook()), address(0), "failed wiring consumed the one-shot slot");
    }
}

/// @dev A creator with no payable fallback: plain ETH transfers to it revert.
contract RejectsEth {}

contract RegStubHook {
    address public launchpad;
    address public poolManager;

    function setLaunchpad(address pad) external {
        launchpad = pad;
    }

    function setPoolManager(address pm) external {
        poolManager = pm;
    }

    function REQUIRED_FLAGS() external pure returns (uint160) {
        return uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    }
}
