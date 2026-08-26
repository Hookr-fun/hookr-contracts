// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {BlueprintSeeds} from "./utils/BlueprintSeeds.sol";

/// @notice Curve-phase unit tests. No PoolManager interaction happens before graduation, so a
///         dead address stands in for it; graduation paths are covered by the fork suite.
contract CurveTest is Test {
    HookrLaunchpad pad;
    address constant PM = address(0xDEAD001);
    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 launchFee;

    uint96 constant TARGET = 1 ether;

    function setUp() public {
        pad = new HookrLaunchpad(IPoolManager(PM));
        BlueprintSeeds.seed(pad);
        // wire a fake hook? setHook validates flags — skip: launches only need hook != 0.
        // We cheat by writing storage: hook slot must be nonzero for launch().
        // Simpler: deploy real hook is fork-only; here we etch a stub with matching flags.
        _wireStubHook();
        launchFee = pad.creationFeeWei();
        vm.deal(creator, 100 ether);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _wireStubHook() internal {
        // Mine an address with the required flag bits and etch minimal code returning launchpad().
        // setHook() calls REQUIRED_FLAGS() and launchpad() on the hook.
        StubHook impl = new StubHook();
        uint160 flags = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
        address target;
        for (uint256 i = 1; i < 200_000; i++) {
            target = address(uint160(uint256(keccak256(abi.encode(i)))));
            if (uint160(target) & 0x3FFF == flags && target.code.length == 0) break;
        }
        vm.etch(target, address(impl).code);
        StubHook(payable(target)).setLaunchpad(address(pad));
        StubHook(payable(target)).setPoolManager(PM);
        pad.setHook(HookrHook(payable(target)));
    }

    function _launchArgs() internal view returns (HookrLaunchpad.LaunchArgs memory a) {
        a.name = "Kraken Klub";
        a.symbol = "KRKN";
        a.tagline = "release the kraken";
        a.logoURI = "";
        a.expectedCreator = creator;
        a.targetRaiseWei = TARGET;
        a.blueprintId = 0;
        a.custom = HookrLaunchpad.HookParams({
            guardBlocks: 20,
            maxBuyBps: 50, // 0.5% supply
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
        a.creatorBuyWei = 0;
        a.minTokensOut = 0;
    }

    function _launch() internal returns (address token) {
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        token = pad.launch{value: fee}(_launchArgs());
    }

    function _launchWithIntent(HookrLaunchpad.LaunchArgs memory a, bytes32 intentId) internal returns (address token) {
        vm.prank(a.expectedCreator);
        token = pad.launchWithIntent{value: launchFee + a.creatorBuyWei}(a, intentId);
    }

    function _assertLaunchIntentEvent(address expectedCreator, bytes32 expectedIntentId, address expectedToken)
        internal
    {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 signature = keccak256("LaunchIntentConsumed(address,bytes32,address)");
        bytes32 creatorTopic = bytes32(uint256(uint160(expectedCreator)));
        bytes32 tokenTopic = bytes32(uint256(uint160(expectedToken)));
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == address(pad) && entries[i].topics.length == 4 && entries[i].topics[0] == signature
                    && entries[i].topics[1] == creatorTopic && entries[i].topics[2] == expectedIntentId
                    && entries[i].topics[3] == tokenTopic && entries[i].data.length == 0
            ) return;
        }
        fail("LaunchIntentConsumed event missing or malformed");
    }

    // ------------------------------------------------------------ launch

    function test_launch_storesState_andMintsSupplyToPad() public {
        address token = _launch();
        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        assertEq(l.creator, creator);
        assertEq(l.token, token);
        assertFalse(l.graduated);
        assertGt(l.basePriceWei, 0);
        assertGt(l.targetWei, 0);
        // exact target is within rounding of the requested raise
        assertApproxEqRel(uint256(l.targetWei), uint256(TARGET), 1e15); // 0.1%
        assertEq(HookrToken(token).balanceOf(address(pad)), pad.SUPPLY());
        assertEq(HookrToken(token).creator(), creator);
        assertEq(pad.protocolFeesWei(), pad.creationFeeWei());
    }

    function test_launch_revertsOnWrongPayment() public {
        HookrLaunchpad.LaunchArgs memory a = _launchArgs();
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.InsufficientPayment.selector);
        pad.launch{value: 1}(a);
    }

    function test_launch_withCreatorBuy() public {
        HookrLaunchpad.LaunchArgs memory a = _launchArgs();
        a.creatorBuyWei = 0.02 ether; // 2% of 1 ETH target
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        address token = pad.launch{value: fee + 0.02 ether}(a);
        assertGt(HookrToken(token).balanceOf(creator), 0);
        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        assertGt(l.soldTokens, 0);
        assertGt(l.reserveWei, 0);
    }

    function test_launch_expectedCreatorBindsExactCalldata_butMetadataIsNotUnique() public {
        HookrLaunchpad.LaunchArgs memory approved = _launchArgs();
        uint256 fee = pad.creationFeeWei();

        vm.expectRevert(
            abi.encodeWithSelector(HookrLaunchpad.UnexpectedCreator.selector, approved.expectedCreator, bob)
        );
        vm.prank(bob);
        pad.launch{value: fee}(approved);

        HookrLaunchpad.LaunchArgs memory missingCreator = approved;
        missingCreator.expectedCreator = address(0);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchpad.UnexpectedCreator.selector, address(0), creator));
        vm.prank(creator);
        pad.launch{value: fee}(missingCreator);
        approved.expectedCreator = creator;

        vm.prank(creator);
        address creatorToken = pad.launch{value: fee}(approved);
        assertEq(pad.getLaunch(creatorToken).creator, creator);

        // Metadata is intentionally permissionless, not a uniqueness or identity primitive. Bob
        // may submit independently bound calldata with the same display fields.
        HookrLaunchpad.LaunchArgs memory bobIntent = approved;
        bobIntent.expectedCreator = bob;
        vm.prank(bob);
        address bobToken = pad.launch{value: fee}(bobIntent);
        assertTrue(bobToken != creatorToken);
        assertEq(pad.getLaunch(bobToken).creator, bob);
    }

    function test_launchWithIntent_recordsTokenAndRejectsExactReplayAtomically() public {
        HookrLaunchpad.LaunchArgs memory a = _launchArgs();
        bytes32 intentId = keccak256("agent-intent-replay");

        vm.recordLogs();
        address token = _launchWithIntent(a, intentId);
        _assertLaunchIntentEvent(creator, intentId, token);

        assertEq(pad.launchedByIntent(creator, intentId), token, "intent postcondition missing token");
        uint256 tokenCount = pad.tokensCount();
        uint256 protocolFees = pad.protocolFeesWei();

        vm.expectRevert(
            abi.encodeWithSelector(HookrLaunchpad.LaunchIntentAlreadyUsed.selector, creator, intentId, token)
        );
        _launchWithIntent(a, intentId);

        assertEq(pad.tokensCount(), tokenCount, "replay deployed another token");
        assertEq(pad.protocolFeesWei(), protocolFees, "replay accrued another creation fee");
        assertEq(pad.launchedByIntent(creator, intentId), token, "replay changed intent postcondition");
    }

    function test_launchWithIntent_rejectsZeroIntent() public {
        HookrLaunchpad.LaunchArgs memory a = _launchArgs();
        uint256 tokenCount = pad.tokensCount();

        vm.expectRevert(HookrLaunchpad.ZeroLaunchIntent.selector);
        _launchWithIntent(a, bytes32(0));

        assertEq(pad.tokensCount(), tokenCount);
    }

    function test_launchWithIntent_failedCreatorBuyDoesNotConsume_andSameIntentRetries() public {
        HookrLaunchpad.LaunchArgs memory a = _launchArgs();
        bytes32 intentId = keccak256("agent-intent-retry");
        a.creatorBuyWei = 0.02 ether;
        a.minTokensOut = pad.CURVE_SUPPLY() + 1;
        uint256 tokenCount = pad.tokensCount();
        uint256 protocolFees = pad.protocolFeesWei();

        vm.expectRevert(HookrLaunchpad.SlippageExceeded.selector);
        _launchWithIntent(a, intentId);

        assertEq(pad.launchedByIntent(creator, intentId), address(0), "failed launch consumed intent");
        assertEq(pad.tokensCount(), tokenCount, "failed launch retained token state");
        assertEq(pad.protocolFeesWei(), protocolFees, "failed launch retained creation fee");

        a.minTokensOut = 0;
        address token = _launchWithIntent(a, intentId);
        assertEq(pad.launchedByIntent(creator, intentId), token, "retry did not consume intent");
        assertGt(HookrToken(token).balanceOf(creator), 0, "retry did not execute creator buy");
    }

    function test_launchWithIntent_namespacesSameIntentByCreator() public {
        bytes32 intentId = keccak256("shared-agent-intent");
        HookrLaunchpad.LaunchArgs memory creatorArgs = _launchArgs();
        address creatorToken = _launchWithIntent(creatorArgs, intentId);

        HookrLaunchpad.LaunchArgs memory bobArgs = _launchArgs();
        bobArgs.expectedCreator = bob;
        address bobToken = _launchWithIntent(bobArgs, intentId);

        assertTrue(creatorToken != bobToken);
        assertEq(pad.launchedByIntent(creator, intentId), creatorToken);
        assertEq(pad.launchedByIntent(bob, intentId), bobToken);
        assertEq(pad.getLaunch(creatorToken).creator, creator);
        assertEq(pad.getLaunch(bobToken).creator, bob);
    }

    function test_launchWithIntent_distinctIntentsPermitDuplicateMetadata() public {
        HookrLaunchpad.LaunchArgs memory a = _launchArgs();
        bytes32 firstIntent = keccak256("first-agent-intent");
        bytes32 secondIntent = keccak256("second-agent-intent");

        address firstToken = _launchWithIntent(a, firstIntent);
        address secondToken = _launchWithIntent(a, secondIntent);

        assertTrue(firstToken != secondToken);
        assertEq(pad.launchedByIntent(creator, firstIntent), firstToken);
        assertEq(pad.launchedByIntent(creator, secondIntent), secondToken);
    }

    function test_launchWithIntent_wrongSenderCannotConsumeApprovedIntent() public {
        HookrLaunchpad.LaunchArgs memory a = _launchArgs();
        bytes32 intentId = keccak256("sender-bound-agent-intent");
        uint256 fee = pad.creationFeeWei();

        vm.expectRevert(abi.encodeWithSelector(HookrLaunchpad.UnexpectedCreator.selector, creator, bob));
        vm.prank(bob);
        pad.launchWithIntent{value: fee}(a, intentId);
        assertEq(pad.launchedByIntent(bob, intentId), address(0));
        assertEq(pad.launchedByIntent(creator, intentId), address(0));

        address token = _launchWithIntent(a, intentId);
        assertEq(pad.launchedByIntent(creator, intentId), token);
    }

    function test_launch_remainsRepeatable_withoutConsumingIntent() public {
        HookrLaunchpad.LaunchArgs memory a = _launchArgs();
        uint256 fee = pad.creationFeeWei();
        bytes32 unusedIntent = keccak256("ordinary-launch-does-not-consume");

        vm.prank(creator);
        address firstToken = pad.launch{value: fee}(a);
        vm.prank(creator);
        address secondToken = pad.launch{value: fee}(a);

        assertTrue(firstToken != secondToken);
        assertEq(pad.launchedByIntent(creator, unusedIntent), address(0));
    }

    function test_launch_validatesHookParams() public {
        HookrLaunchpad.LaunchArgs memory a = _launchArgs();
        a.custom.burnBps = 900;
        a.custom.lpBps = 200; // total cuts 11.5% > 10%
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        pad.launch{value: fee}(a);
    }

    // ------------------------------------------------------------ buys

    function test_buy_walksTranches_priceRises() public {
        address token = _launch();
        vm.prank(alice);
        pad.buy{value: 0.05 ether}(token, 0);
        uint256 firstTokens = HookrToken(token).balanceOf(alice);
        assertGt(firstTokens, 0);

        uint256 p0 = pad.currentCurvePrice(token);
        vm.prank(bob);
        pad.buy{value: 0.4 ether}(token, 0);
        uint256 p1 = pad.currentCurvePrice(token);
        assertGt(p1, p0, "price must rise across tranches");

        // same ETH buys fewer tokens later
        vm.prank(bob);
        pad.buy{value: 0.05 ether}(token, 0);
        uint256 bobSecond = HookrToken(token).balanceOf(bob);
        vm.prank(alice);
        pad.buy{value: 0.05 ether}(token, 0);
        uint256 aliceSecond = HookrToken(token).balanceOf(alice) - firstTokens;
        assertLt(aliceSecond, firstTokens, "later buys get fewer tokens");
        bobSecond; // silence
    }

    function test_buy_slippageGuard() public {
        address token = _launch();
        (uint256 quoted,) = pad.quoteBuy(token, 0.01 ether);
        vm.prank(alice);
        vm.expectRevert(HookrLaunchpad.SlippageExceeded.selector);
        pad.buy{value: 0.01 ether}(token, quoted + 1e18);
    }

    function test_quoteBuy_matchesActual() public {
        address token = _launch();
        (uint256 quoted, uint256 cost) = pad.quoteBuy(token, 0.037 ether);
        vm.prank(alice);
        pad.buy{value: 0.037 ether}(token, quoted);
        assertEq(HookrToken(token).balanceOf(alice), quoted);
        assertLe(cost, 0.037 ether);
    }

    function test_buy_feeSplitsCreatorProtocol() public {
        address token = _launch();
        uint256 protoBefore = pad.protocolFeesWei();
        vm.prank(alice);
        pad.buy{value: 0.1 ether}(token, 0);
        assertGt(pad.creatorFeesWei(token), 0);
        assertGt(pad.protocolFeesWei(), protoBefore);
        // roughly equal split of ~1% of used ETH
        assertApproxEqAbs(pad.creatorFeesWei(token), pad.protocolFeesWei() - protoBefore, 2);
    }

    // ------------------------------------------------------------ sells

    function test_sell_roundTrip_reserveSolvent() public {
        address token = _launch();
        vm.prank(alice);
        pad.buy{value: 0.2 ether}(token, 0);
        uint256 bal = HookrToken(token).balanceOf(alice);

        vm.startPrank(alice);
        HookrToken(token).approve(address(pad), bal);
        uint256 ethBefore = alice.balance;
        pad.sell(token, bal, 0);
        vm.stopPrank();

        uint256 got = alice.balance - ethBefore;
        // round trip loses ~2% (two 1% fees) plus rounding
        assertGt(got, 0.19 ether);
        assertLt(got, 0.2 ether);

        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        assertEq(l.soldTokens, 0);
        // reserve keeps only rounding dust
        assertLt(l.reserveWei, 1e6);
    }

    function test_sell_quoteMatches() public {
        address token = _launch();
        vm.prank(alice);
        pad.buy{value: 0.15 ether}(token, 0);
        uint256 bal = HookrToken(token).balanceOf(alice);
        uint256 quoted = pad.quoteSell(token, bal / 3);
        vm.startPrank(alice);
        HookrToken(token).approve(address(pad), bal);
        uint256 before = alice.balance;
        pad.sell(token, bal / 3, quoted);
        assertEq(alice.balance - before, quoted);
        vm.stopPrank();
    }

    function test_sell_cannotExceedSold() public {
        address token = _launch();
        vm.prank(alice);
        pad.buy{value: 0.01 ether}(token, 0);
        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        vm.startPrank(alice);
        HookrToken(token).approve(address(pad), type(uint256).max);
        vm.expectRevert(HookrLaunchpad.SlippageExceeded.selector);
        pad.sell(token, uint256(l.soldTokens) + 1e18, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ fuzz

    /// @dev Reserve must always cover the curve integral: buy/sell sequences never drain more
    ///      than was paid in.
    function testFuzz_buySellSequence_reserveSolvent(uint96 a, uint96 b, uint96 c) public {
        a = uint96(bound(a, 0.0001 ether, 0.3 ether));
        b = uint96(bound(b, 0.0001 ether, 0.3 ether));
        c = uint96(bound(c, 0.0001 ether, 0.3 ether));
        address token = _launch();

        vm.prank(alice);
        pad.buy{value: a}(token, 0);
        vm.prank(bob);
        pad.buy{value: b}(token, 0);

        uint256 aliceBal = HookrToken(token).balanceOf(alice);
        vm.startPrank(alice);
        HookrToken(token).approve(address(pad), aliceBal);
        pad.sell(token, aliceBal / 2, 0);
        vm.stopPrank();

        vm.prank(bob);
        pad.buy{value: c}(token, 0);

        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        if (!l.graduated) {
            // pad's ETH = reserve + accrued fees (creation + curve fees), minus nothing else
            uint256 accounted = uint256(l.reserveWei) + pad.protocolFeesWei() + pad.creatorFeesWei(token);
            assertEq(address(pad).balance, accounted, "every wei accounted");
        }
    }

    // ------------------------------------------------------------ blueprints

    function test_blueprint_houseIdsAreOwnerReserved_untilAllFiveAreSeeded() public {
        HookrLaunchpad freshPad = new HookrLaunchpad(IPoolManager(PM));
        HookrLaunchpad.HookParams memory p = _launchArgs().custom;

        vm.prank(bob);
        vm.expectRevert(HookrLaunchpad.HouseBlueprintsPending.selector);
        freshPad.saveBlueprint("front-run", p, 0);

        BlueprintSeeds.seed(freshPad);
        vm.prank(bob);
        uint32 id = freshPad.saveBlueprint("public", p, 0);
        assertEq(id, 6);
        assertEq(freshPad.getBlueprint(id).author, bob);
    }

    function test_blueprint_saveAndLaunch() public {
        HookrLaunchpad.HookParams memory p = _launchArgs().custom;
        vm.prank(bob);
        uint32 id = pad.saveBlueprint("Sniper Slayer", p, 500);
        assertEq(id, 6);

        HookrLaunchpad.LaunchArgs memory a = _launchArgs();
        a.blueprintId = id;
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        address token = pad.launch{value: fee}(a);
        assertEq(pad.getLaunch(token).blueprintId, id);
        assertEq(pad.getBlueprint(id).uses, 1);
        assertEq(pad.getBlueprint(id).author, bob);
    }

    function test_blueprint_royaltyCap() public {
        HookrLaunchpad.HookParams memory p = _launchArgs().custom;
        vm.prank(bob);
        vm.expectRevert(HookrLaunchpad.RoyaltyTooHigh.selector);
        pad.saveBlueprint("Greedy", p, 1001);
    }

    // ------------------------------------------------------------ admin

    function test_admin_creationFeeBounds() public {
        vm.expectRevert(HookrLaunchpad.FeeTooHigh.selector);
        pad.setCreationFee(0.051 ether);
        pad.setCreationFee(0.02 ether);
        assertEq(pad.creationFeeWei(), 0.02 ether);
    }

    function test_admin_withdrawProtocolFees() public {
        _launch();
        uint256 amount = pad.protocolFeesWei();
        address to = address(0xFEE);
        pad.withdrawProtocolFees(to);
        assertEq(to.balance, amount);
        assertEq(pad.protocolFeesWei(), 0);
    }

    function test_views_tokensPage() public {
        address t1 = _launch();
        HookrLaunchpad.LaunchArgs memory a = _launchArgs();
        a.symbol = "TWO";
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        address t2 = pad.launch{value: fee}(a);
        address[] memory page = pad.tokensPage(0, 10);
        assertEq(page.length, 2);
        assertEq(page[0], t2); // newest first
        assertEq(page[1], t1);
    }
}

interface HookrHookLike {
    function REQUIRED_FLAGS() external view returns (uint160);
    function launchpad() external view returns (address);
}

contract StubHook {
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
