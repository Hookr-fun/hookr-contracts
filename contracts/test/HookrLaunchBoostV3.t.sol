// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLaunchBoostV3} from "../src/HookrLaunchBoostV3.sol";
import {HookrLockRewardsV3} from "../src/HookrLockRewardsV3.sol";
import {IHookrLockRewardsV2} from "../src/interfaces/IHookrLockRewardsV2.sol";
import {MockHookrLaunchpad, MockHookrUtilityToken} from "./HookrLockRewardsV1.t.sol";

/// @notice A generation that owns a token namespace but predates `launchedByIntent`.
/// @dev It has no intent getter and no fallback, so an intent probe against it reverts at the EVM
///      level. The V3 fan-out must read that as "no claim" rather than failing the whole call.
contract MockLegacyLaunchpad {
    mapping(address => HookrLaunchpad.Launch) internal launches;

    function setLaunch(address token, address creator) external {
        HookrLaunchpad.Launch storage launch = launches[token];
        launch.token = token;
        launch.creator = creator;
        launch.launchBlock = uint40(block.number);
    }

    function getLaunch(address token) external view returns (HookrLaunchpad.Launch memory) {
        return launches[token];
    }
}

/// @notice The one capability V3 adds to V2 — an immutable set of up to four launchpad
///         generations — plus the V2 economics that must survive it unchanged.
/// @dev Every case here runs against a two-generation set, so the preserved behaviour is proven in
///      the multi-generation configuration and not only in the V2-shaped one. The full V2 boost
///      suite is ported verbatim in HookrLockRewardsV3.t.sol.
contract HookrLaunchBoostV3Test is Test {
    MockHookrUtilityToken internal hookr;
    MockHookrLaunchpad internal padA;
    MockHookrLaunchpad internal padB;
    HookrLockRewardsV3 internal rewards;
    HookrLaunchBoostV3 internal boost;

    address internal creator = address(0xC0FFEE);
    address internal outsider = address(0xBAD);
    address internal tokenOnA = address(0xA0A0);
    address internal tokenOnB = address(0xB0B0);
    address internal tokenOnNeither = address(0x0FF);
    bytes32 internal intentId = keccak256("hookr.utility.v3.set.intent");

    function setUp() public {
        vm.warp(1_800_000_000);
        hookr = new MockHookrUtilityToken();
        padA = new MockHookrLaunchpad();
        padB = new MockHookrLaunchpad();
        rewards = new HookrLockRewardsV3(hookr, address(this));
        boost = new HookrLaunchBoostV3(hookr, _set(address(padA), address(padB)), IHookrLockRewardsV2(address(rewards)));
        rewards.setRewardSourceOnce(address(boost));

        padA.setLaunch(tokenOnA, creator);
        padB.setLaunch(tokenOnB, creator);
        hookr.mint(creator, 100_000_000 ether);
        hookr.mint(outsider, 100_000_000 ether);

        // Open boosting. No locker exists, so the fee is waived and principal equals gross; the
        // ported V2 suite already proves the fee path, which this file does not re-litigate.
        vm.warp(rewards.feeEpochStartsAt());
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _set(address pad) internal pure returns (HookrLaunchpad[] memory set) {
        set = new HookrLaunchpad[](1);
        set[0] = HookrLaunchpad(payable(pad));
    }

    function _set(address first, address second) internal pure returns (HookrLaunchpad[] memory set) {
        set = new HookrLaunchpad[](2);
        set[0] = HookrLaunchpad(payable(first));
        set[1] = HookrLaunchpad(payable(second));
    }

    function _deploy(HookrLaunchpad[] memory set) internal returns (HookrLaunchBoostV3) {
        return new HookrLaunchBoostV3(hookr, set, IHookrLockRewardsV2(address(rewards)));
    }

    function _boostAs(address funder, address token) internal returns (uint256 principal) {
        vm.prank(funder);
        hookr.approve(address(boost), 100 ether);
        vm.prank(funder);
        (principal,) = boost.boost(token, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
    }

    function _boostByIntentAs(address funder) internal returns (address token) {
        vm.prank(funder);
        hookr.approve(address(boost), 100 ether);
        vm.prank(funder);
        (token,,) = boost.boostByIntent(intentId, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_setIsStoredOldestFirstAndUnusedSlotsStayZero() public view {
        assertEq(boost.MAX_LAUNCHPADS(), 4);
        assertEq(boost.launchpadCount(), 2);
        assertEq(address(boost.launchpad0()), address(padA));
        assertEq(address(boost.launchpad1()), address(padB));
        assertEq(address(boost.launchpad2()), address(0));
        assertEq(address(boost.launchpad3()), address(0));
    }

    function test_fullFourGenerationSetIsAccepted() public {
        HookrLaunchpad[] memory set = new HookrLaunchpad[](4);
        set[0] = HookrLaunchpad(payable(address(padA)));
        set[1] = HookrLaunchpad(payable(address(padB)));
        set[2] = HookrLaunchpad(payable(address(new MockHookrLaunchpad())));
        set[3] = HookrLaunchpad(payable(address(new MockHookrLaunchpad())));

        HookrLaunchBoostV3 four = _deploy(set);
        assertEq(four.launchpadCount(), 4);
        assertEq(address(four.launchpad0()), address(set[0]));
        assertEq(address(four.launchpad1()), address(set[1]));
        assertEq(address(four.launchpad2()), address(set[2]));
        assertEq(address(four.launchpad3()), address(set[3]));
    }

    function test_emptySetIsRejected() public {
        HookrLaunchpad[] memory set = new HookrLaunchpad[](0);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV3.InvalidLaunchpadCount.selector, 0));
        _deploy(set);
    }

    function test_moreThanFourLaunchpadsIsRejected() public {
        HookrLaunchpad[] memory set = new HookrLaunchpad[](5);
        for (uint256 i; i < 5; ++i) {
            set[i] = HookrLaunchpad(payable(address(new MockHookrLaunchpad())));
        }
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV3.InvalidLaunchpadCount.selector, 5));
        _deploy(set);
    }

    function test_zeroAddressEntryIsRejected() public {
        vm.expectRevert(HookrLaunchBoostV3.ZeroAddress.selector);
        _deploy(_set(address(padA), address(0)));
    }

    function test_codelessEntryIsRejected() public {
        address noCode = address(0xDEAD);
        assertEq(noCode.code.length, 0);
        vm.expectRevert(HookrLaunchBoostV3.ZeroAddress.selector);
        _deploy(_set(address(padA), noCode));
    }

    function test_duplicateEntryIsRejected() public {
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV3.DuplicateLaunchpad.selector, address(padA)));
        _deploy(_set(address(padA), address(padA)));
    }

    function test_tokenAndVaultChecksSurviveTheSetChange() public {
        vm.expectRevert(HookrLaunchBoostV3.ZeroAddress.selector);
        new HookrLaunchBoostV3(
            MockHookrUtilityToken(address(0)), _set(address(padA)), IHookrLockRewardsV2(address(rewards))
        );

        vm.expectRevert(HookrLaunchBoostV3.ZeroAddress.selector);
        new HookrLaunchBoostV3(hookr, _set(address(padA)), IHookrLockRewardsV2(address(0)));
    }

    /*//////////////////////////////////////////////////////////////
                        RESOLUTION BY TOKEN ADDRESS
    //////////////////////////////////////////////////////////////*/

    function test_eitherGenerationInTheSetCanBeFunded() public {
        assertEq(_boostAs(creator, tokenOnA), 100 ether);
        assertEq(_boostAs(creator, tokenOnB), 100 ether);
        assertEq(boost.boostedTokensCount(), 2);
        assertEq(boost.boostOf(tokenOnA).creator, creator);
        assertEq(boost.boostOf(tokenOnB).creator, creator);
        assertEq(boost.totalBoostPrincipal(), 200 ether);
    }

    function test_aTokenNoGenerationClaimsRevertsUnknownLaunch() public {
        vm.prank(creator);
        hookr.approve(address(boost), 100 ether);
        vm.prank(creator);
        vm.expectRevert(HookrLaunchBoostV3.UnknownLaunch.selector);
        boost.boost(tokenOnNeither, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
        assertEq(boost.boostedTokensCount(), 0);
    }

    function test_aTokenClaimedByTwoGenerationsRevertsInsteadOfPickingAWinner() public {
        // The same token address now resolves on both generations.
        padB.setLaunch(tokenOnA, creator);

        vm.prank(creator);
        hookr.approve(address(boost), 100 ether);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV3.AmbiguousLaunch.selector, tokenOnA));
        boost.boost(tokenOnA, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
        assertEq(boost.boostedTokensCount(), 0);
        assertEq(hookr.balanceOf(address(boost)), 0);
    }

    /// @dev An ambiguity that appears after funding must not strand principal: withdrawal is
    ///      creator-and-clock gated only, exactly as in V2, and never re-resolves the launchpad.
    function test_ambiguityAppearingAfterFundingStillRefundsPrincipal() public {
        assertEq(_boostAs(creator, tokenOnA), 100 ether);
        padB.setLaunch(tokenOnA, creator);

        HookrLaunchBoostV3.BoostPosition memory position = boost.boostOf(tokenOnA);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV3.AmbiguousLaunch.selector, tokenOnA));
        boost.extend(tokenOnA, 1, type(uint40).max, block.timestamp + 1 hours);

        vm.warp(position.unlockAt);
        uint256 before = hookr.balanceOf(creator);
        vm.prank(creator);
        assertEq(boost.withdraw(tokenOnA, creator), 100 ether);
        assertEq(hookr.balanceOf(creator) - before, 100 ether);
        assertEq(boost.totalBoostPrincipal(), 0);
    }

    function test_creatorEqualityStillHoldsOnEveryGeneration() public {
        vm.prank(outsider);
        hookr.approve(address(boost), 100 ether);
        vm.prank(outsider);
        vm.expectRevert(HookrLaunchBoostV3.NotLaunchCreator.selector);
        boost.boost(tokenOnB, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);

        vm.prank(outsider);
        vm.expectRevert(HookrLaunchBoostV3.NotLaunchCreator.selector);
        boost.boost(tokenOnA, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
        assertEq(boost.boostedTokensCount(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                           RESOLUTION BY INTENT
    //////////////////////////////////////////////////////////////*/

    function test_intentResolvesOnTheClaimingGeneration() public {
        padB.setIntent(creator, intentId, tokenOnB);

        (address previewToken, uint256 index, uint256 matches, bool ambiguous) = _resolveAs(creator);
        assertEq(previewToken, tokenOnB);
        assertEq(index, 1);
        assertEq(matches, 1);
        assertFalse(ambiguous);

        assertEq(_boostByIntentAs(creator), tokenOnB);
        assertEq(boost.boostOf(tokenOnB).principal, 100 ether);
    }

    /// @dev The point of the staticcall probe: a generation without `launchedByIntent` must report
    ///      "no claim", not revert the fan-out and take the other generations down with it.
    function test_generationWithoutLaunchedByIntentReportsNoClaim() public {
        MockLegacyLaunchpad legacy = new MockLegacyLaunchpad();
        boost =
            new HookrLaunchBoostV3(hookr, _set(address(legacy), address(padB)), IHookrLockRewardsV2(address(rewards)));
        legacy.setLaunch(tokenOnA, creator);
        padB.setIntent(creator, intentId, tokenOnB);

        (address previewToken, uint256 index, uint256 matches,) = _resolveAs(creator);
        assertEq(previewToken, tokenOnB);
        assertEq(index, 1);
        assertEq(matches, 1);

        // The legacy generation is still fully usable by address, and the intent still resolves.
        vm.prank(creator);
        hookr.approve(address(boost), 200 ether);
        vm.prank(creator);
        (address funded,,) = boost.boostByIntent(intentId, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1);
        assertEq(funded, tokenOnB);
        vm.prank(creator);
        boost.boost(tokenOnA, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
        assertEq(boost.boostedTokensCount(), 2);
    }

    function test_unclaimedIntentRevertsUnknownLaunch() public {
        (address previewToken,, uint256 matches, bool ambiguous) = _resolveAs(creator);
        assertEq(previewToken, address(0));
        assertEq(matches, 0);
        assertFalse(ambiguous);

        vm.prank(creator);
        hookr.approve(address(boost), 100 ether);
        vm.prank(creator);
        vm.expectRevert(HookrLaunchBoostV3.UnknownLaunch.selector);
        boost.boostByIntent(intentId, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
    }

    function test_intentClaimedByTwoGenerationsRevertsAndStaysFundableByAddress() public {
        padA.setIntent(creator, intentId, tokenOnA);
        padB.setIntent(creator, intentId, tokenOnB);

        (address previewToken, uint256 index, uint256 matches, bool ambiguous) = _resolveAs(creator);
        assertEq(previewToken, address(0));
        assertEq(index, 0);
        assertEq(matches, 2);
        assertTrue(ambiguous);

        vm.prank(creator);
        hookr.approve(address(boost), 100 ether);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV3.AmbiguousLaunch.selector, address(0)));
        boost.boostByIntent(intentId, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);

        // Neither token is stranded: each address is claimed by exactly one generation.
        assertEq(_boostAs(creator, tokenOnA), 100 ether);
        assertEq(_boostAs(creator, tokenOnB), 100 ether);
        assertEq(boost.boostedTokensCount(), 2);
    }

    function test_ambiguousIntentAlsoRevertsThroughThePermitPathWithoutMovingFunds() public {
        padA.setIntent(creator, intentId, tokenOnA);
        padB.setIntent(creator, intentId, tokenOnB);
        uint256 balanceBefore = hookr.balanceOf(creator);
        uint256 nonceBefore = hookr.nonces(creator);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV3.AmbiguousLaunch.selector, address(0)));
        boost.boostByIntentWithPermit(
            intentId,
            100 ether,
            0,
            type(uint256).max,
            0,
            block.timestamp + 1 hours,
            27,
            bytes32(uint256(1)),
            bytes32(uint256(2))
        );

        assertEq(hookr.balanceOf(creator), balanceBefore);
        assertEq(hookr.nonces(creator), nonceBefore);
        assertEq(hookr.allowance(creator, address(boost)), 0);
        assertEq(boost.boostedTokensCount(), 0);
    }

    function test_resolveIntentIsNamespacedByTheCaller() public {
        padA.setIntent(creator, intentId, tokenOnA);

        (address forCreator,, uint256 creatorMatches,) = _resolveAs(creator);
        assertEq(forCreator, tokenOnA);
        assertEq(creatorMatches, 1);

        (address forOutsider,, uint256 outsiderMatches,) = _resolveAs(outsider);
        assertEq(forOutsider, address(0));
        assertEq(outsiderMatches, 0);

        vm.prank(outsider);
        hookr.approve(address(boost), 100 ether);
        vm.prank(outsider);
        vm.expectRevert(HookrLaunchBoostV3.UnknownLaunch.selector);
        boost.boostByIntent(intentId, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
    }

    /// @dev The view must never disagree with the funding path it exists to preview.
    function testFuzz_resolveIntentAgreesWithBoostByIntent(bool claimedByA, bool claimedByB) public {
        if (claimedByA) padA.setIntent(creator, intentId, tokenOnA);
        if (claimedByB) padB.setIntent(creator, intentId, tokenOnB);

        (address previewToken, uint256 index, uint256 matches, bool ambiguous) = _resolveAs(creator);
        uint256 expectedMatches = (claimedByA ? 1 : 0) + (claimedByB ? 1 : 0);
        assertEq(matches, expectedMatches);
        assertEq(ambiguous, expectedMatches > 1);

        vm.prank(creator);
        hookr.approve(address(boost), 100 ether);
        if (expectedMatches == 1) {
            address expectedToken = claimedByA ? tokenOnA : tokenOnB;
            assertEq(previewToken, expectedToken);
            assertEq(index, claimedByA ? 0 : 1);
            vm.prank(creator);
            (address funded,,) =
                boost.boostByIntent(intentId, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
            assertEq(funded, previewToken);
            return;
        }

        assertEq(previewToken, address(0));
        assertEq(index, 0);
        vm.prank(creator);
        if (expectedMatches == 0) {
            vm.expectRevert(HookrLaunchBoostV3.UnknownLaunch.selector);
        } else {
            vm.expectRevert(abi.encodeWithSelector(HookrLaunchBoostV3.AmbiguousLaunch.selector, address(0)));
        }
        boost.boostByIntent(intentId, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
    }

    function _resolveAs(address caller)
        internal
        returns (address token, uint256 launchpadIndex, uint256 matches, bool ambiguous)
    {
        vm.prank(caller);
        return boost.resolveIntent(intentId);
    }

    /// @dev The walk must index every slot correctly, not just the first two.
    function test_everySlotOfAFullSetResolves() public {
        MockHookrLaunchpad padC = new MockHookrLaunchpad();
        MockHookrLaunchpad padD = new MockHookrLaunchpad();
        HookrLaunchpad[] memory set = new HookrLaunchpad[](4);
        set[0] = HookrLaunchpad(payable(address(padA)));
        set[1] = HookrLaunchpad(payable(address(padB)));
        set[2] = HookrLaunchpad(payable(address(padC)));
        set[3] = HookrLaunchpad(payable(address(padD)));
        boost = _deploy(set);

        address tokenOnC = address(0xC0C0);
        address tokenOnD = address(0xD0D0);
        padC.setLaunch(tokenOnC, creator);
        padD.setLaunch(tokenOnD, creator);
        padD.setIntent(creator, intentId, tokenOnD);

        assertEq(_boostAs(creator, tokenOnA), 100 ether);
        assertEq(_boostAs(creator, tokenOnB), 100 ether);
        assertEq(_boostAs(creator, tokenOnC), 100 ether);

        (address previewToken, uint256 index, uint256 matches,) = _resolveAs(creator);
        assertEq(previewToken, tokenOnD);
        assertEq(index, 3);
        assertEq(matches, 1);
        assertEq(_boostByIntentAs(creator), tokenOnD);
        assertEq(boost.boostedTokensCount(), 4);
    }

    /*//////////////////////////////////////////////////////////////
                       PRESERVED V2 ECONOMICS AND SHAPE
    //////////////////////////////////////////////////////////////*/

    function test_publishedConstantsAreUnchanged() public view {
        assertEq(boost.BOOST_FEE_BPS(), 100);
        assertEq(boost.MIN_GROSS_BOOST(), 100 ether);
        assertEq(boost.MAX_ACTIVE_BOOSTS(), 512);
        assertEq(boost.contractName(), "HookrLaunchBoost");
        assertEq(boost.contractVersion(), "3");
        assertEq(rewards.contractVersion(), "3");
    }

    function test_minimumGrossBoostStillBinds() public {
        vm.prank(creator);
        hookr.approve(address(boost), 100 ether);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(HookrLaunchBoostV3.GrossAmountBelowMinimum.selector, 99 ether, 100 ether)
        );
        boost.boost(tokenOnA, 99 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);
        assertEq(boost.boostedTokensCount(), 0);
    }

    function test_tierDurationsAndMultipliersAreUnchanged() public view {
        (,, uint256 score0, uint40 duration0, uint16 multiplier0,,) = boost.previewBoost(100 ether, 0);
        (,, uint256 score1, uint40 duration1, uint16 multiplier1,,) = boost.previewBoost(100 ether, 1);
        (,, uint256 score2, uint40 duration2, uint16 multiplier2,,) = boost.previewBoost(100 ether, 2);
        assertEq(duration0, 30 days);
        assertEq(duration1, 90 days);
        assertEq(duration2, 180 days);
        assertEq(multiplier0, 10_000);
        assertEq(multiplier1, 11_500);
        assertEq(multiplier2, 12_500);
        assertEq(score0, 100 ether);
        assertEq(score1, 115 ether);
        assertEq(score2, 125 ether);
    }

    function test_extendIsFeeFreeAndOnlyMovesTheClock() public {
        _boostAs(creator, tokenOnA);
        uint256 creatorBalance = hookr.balanceOf(creator);
        uint256 boostBalance = hookr.balanceOf(address(boost));
        uint256 gross = boost.cumulativeGrossBoosted();

        vm.prank(creator);
        uint40 unlockAt = boost.extend(tokenOnA, 1, type(uint40).max, block.timestamp + 1 hours);

        assertEq(unlockAt, uint40(block.timestamp + 90 days));
        assertEq(boost.boostOf(tokenOnA).tier, 1);
        assertEq(boost.boostOf(tokenOnA).principal, 100 ether);
        assertEq(hookr.balanceOf(creator), creatorBalance);
        assertEq(hookr.balanceOf(address(boost)), boostBalance);
        assertEq(boost.cumulativeGrossBoosted(), gross);
        assertEq(boost.cumulativeFeesForwarded(), 0);
        assertEq(boost.scoreOf(tokenOnA), 115 ether);
    }

    /// @dev One position per token: a second deposit tops the creator's own position up, and no
    ///      third party can take, displace or evict it.
    function test_onePositionPerTokenSurvivesTheSetChange() public {
        _boostAs(creator, tokenOnA);
        _boostAs(creator, tokenOnA);
        assertEq(boost.boostedTokensCount(), 1);
        assertEq(boost.boostOf(tokenOnA).principal, 200 ether);
        assertEq(boost.boostOf(tokenOnA).creator, creator);

        vm.prank(outsider);
        hookr.approve(address(boost), 100 ether);
        vm.prank(outsider);
        vm.expectRevert(HookrLaunchBoostV3.NotLaunchCreator.selector);
        boost.boost(tokenOnA, 100 ether, 0, type(uint256).max, 0, block.timestamp + 1 hours);

        vm.prank(outsider);
        vm.expectRevert(HookrLaunchBoostV3.NotLaunchCreator.selector);
        boost.withdraw(tokenOnA, outsider);
        assertEq(boost.boostOf(tokenOnA).principal, 200 ether);
        assertEq(boost.boostedTokensCount(), 1);
    }
}
