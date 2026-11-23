// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {HookrTypes} from "hookr-1/src/types/HookrTypes.sol";
import {IHookrAdvisory} from "hookr-1/src/interfaces/IHookrAdvisory.sol";
import {IHookrRoot} from "hookr-1/src/interfaces/IHookrRoot.sol";
import {IHookrRootState} from "hookr-1/src/interfaces/IHookrRootState.sol";
import {IHookrRouter} from "hookr-1/src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "hookr-1/src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "hookr-1/src/support/HookrToken.sol";
import {AdvisoryConformance} from "hookr-1/test/kit/AdvisoryConformance.sol";

import {TollLaunchCheckAdvisory, ILaunchObservationsReader} from "../src/TollLaunchCheckAdvisory.sol";
import {MockLaunchObservations} from "./MockLaunchObservations.sol";

/// @notice Hookr's advisory conformance kit against TollLaunchCheckAdvisory on a real HookrRoot, then this advisory's
///         own behaviour on the same root: buys rejected over a limit, sells never, unread and failed reads, the
///         window's end, and bind refusals.
/// @dev The kit's pools bind `_kitRootData()` (limits 2,500 / 2,000 bps, `blockUnread` false, 1,000 blocks) and the
///      kit's tokens have no observation, so the kit's checks that a fee advisory never rejects see the unread
///      branch. The advisory serves HookrRoot pools only: a pair root takes a surcharge from its advisory and has no
///      way to reject, so the pair checks are skipped. It charges nothing, so it is admitted with an LP-fee cap of 0.
contract TollLaunchCheckAdvisoryTest is AdvisoryConformance {
    using PoolIdLibrary for PoolKey;

    address internal constant DETECTOR = address(0xD7EC);
    address internal constant OTHER_DETECTOR = address(0xBAD);
    uint32 internal constant ACTIVE = 1_000;

    MockLaunchObservations internal obs;
    TollLaunchCheckAdvisory internal advisory;

    // ------------------------------------------------------------------------------------------------------------
    // Kit hooks
    // ------------------------------------------------------------------------------------------------------------

    function _kitDeploy() internal override returns (address) {
        obs = new MockLaunchObservations();
        advisory = new TollLaunchCheckAdvisory(ILaunchObservationsReader(address(obs)), DETECTOR);
        return address(advisory);
    }

    function _kitRootData() internal pure override returns (bytes memory) {
        return _data(2500, 2000, false, ACTIVE);
    }

    function _kitPairData(uint24) internal pure override returns (bytes memory) {
        return "";
    }

    function _kitArtifact() internal pure override returns (string memory) {
        return "out/TollLaunchCheckAdvisory.sol/TollLaunchCheckAdvisory.json";
    }

    function _kitOwnBuild() internal pure override returns (bool) {
        return true;
    }

    function _kitSupportsPair() internal pure override returns (bool) {
        return false;
    }

    function _kitRootCapPips() internal pure override returns (uint24) {
        return 0;
    }

    function _kitRootGasLimit() internal pure override returns (uint32) {
        return 250_000;
    }

    function _kitPairGasLimit() internal pure override returns (uint32) {
        return 25_000;
    }

    /// @dev The most expensive buy that still fills: the subject's latest observation carries the registry's maximum
    ///      of 32 findings, 30 funding-linked shares under other params, then the first-block share, then the
    ///      funding-linked share under param 1, both under the limits (the fork test measures the same shape on the
    ///      live registry).
    function _kitWorstCase(address, PoolId id) internal override {
        _recordWorstCase(Currency.unwrap(root.poolConfig(id).subject), 2000);
    }

    function _kitCold() internal override {
        vm.cool(kitAdvisory);
        vm.cool(address(obs));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _data(uint16 maxFirst, uint16 maxLinked, bool blockUnread, uint32 active)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(TollLaunchCheckAdvisory.Config(maxFirst, maxLinked, blockUnread, active));
    }

    function _recordWithFiller(address token, address detector, uint256 filler, uint256 firstBlock, uint256 linked)
        internal
    {
        MockLaunchObservations.Finding[] memory f = new MockLaunchObservations.Finding[](filler + 2);
        for (uint256 i; i < filler; ++i) {
            f[i] = MockLaunchObservations.Finding(keccak256(abi.encode("filler", i)), i, 0, 0);
        }
        f[filler] = MockLaunchObservations.Finding(advisory.FIRST_BLOCK_SHARE(), firstBlock, 0, 0);
        f[filler + 1] = MockLaunchObservations.Finding(advisory.FUNDING_LINKED_SHARE(), linked, 1, 0);
        obs.record(token, detector, f);
    }

    function _recordWorstCase(address token, uint256 linked) internal {
        MockLaunchObservations.Finding[] memory f = new MockLaunchObservations.Finding[](32);
        for (uint256 i; i < 30; ++i) {
            f[i] = MockLaunchObservations.Finding(advisory.FUNDING_LINKED_SHARE(), 0, uint64(i + 2), 0);
        }
        f[30] = MockLaunchObservations.Finding(advisory.FIRST_BLOCK_SHARE(), 2500, 0, 0);
        f[31] = MockLaunchObservations.Finding(advisory.FUNDING_LINKED_SHARE(), linked, 1, 0);
        obs.record(token, DETECTOR, f);
    }

    function _observe(address token, uint256 firstBlock, uint256 linked) internal {
        _recordWithFiller(token, DETECTOR, 0, firstBlock, linked);
    }

    function _subject(PoolKey memory key) internal view returns (address) {
        return Currency.unwrap(root.poolConfig(key.toId()).subject);
    }

    /// @dev The advice the root gets for a 1e18 swap on `key`.
    function _advice(PoolKey memory key, bool isBuy, bool exactInput) internal returns (HookrTypes.Advice memory a) {
        HookrTypes.SwapContext memory x = _kitContext(key, isBuy, exactInput, 1e18);
        vm.prank(address(root));
        a = advisory.beforeSwap(x);
    }

    function _assertNoCharge(HookrTypes.Advice memory a) internal pure {
        assertEq(a.lpFeeSurchargePips, 0, "surcharge");
        assertEq(a.quoteTakePips, 0, "take");
        assertEq(a.recipient, address(0), "recipient");
    }

    function _assertPass(HookrTypes.Advice memory a) internal pure {
        _assertNoCharge(a);
        assertFalse(a.reject, "rejected");
    }

    function _assertReject(HookrTypes.Advice memory a) internal pure {
        _assertNoCharge(a);
        assertTrue(a.reject, "not rejected");
    }

    function _trade(PoolKey memory key, bool isBuy, bool exactInput) internal {
        IHookrRouter.Swap memory p = _swap(key, isBuy, exactInput, 1e18);
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
    }

    function _expectRejected(PoolKey memory key, bool exactInput) internal {
        IHookrRouter.Swap memory p = _swap(key, true, exactInput, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(root),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IHookrRootState.SwapRejected.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
    }

    /// @dev Launches a fail-closed pool of a new subject against tokenB, bound with `data`; the trader holds the
    ///      subject and has approved the router.
    function _launchWith(bytes memory data) internal returns (PoolKey memory key) {
        HookrToken subject = new HookrToken("Launch Check Subject", "LCS", 1e30, address(this));
        subject.approve(address(launcher), type(uint256).max);
        subject.transfer(trader, 1e27);
        vm.prank(trader);
        subject.approve(address(router), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[0].config.advisory = kitAdvisory;
        members[0].config.advisoryGasLimit = _kitRootGasLimit();
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        bytes[] memory configs = new bytes[](1);
        configs[0] = data;
        (bytes32 family,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    /// @dev The root's call: a static call with exactly the pool's advisory gas limit that must answer 128 bytes.
    function _rootCall(PoolKey memory key, bool isBuy) internal returns (HookrTypes.Advice memory a, uint256 used) {
        bytes memory out = new bytes(128);
        HookrTypes.SwapContext memory x = _kitContext(key, isBuy, true, 1e18);
        bytes memory input = abi.encodeCall(IHookrAdvisory.beforeSwap, (x));
        uint256 limit = _kitRootGasLimit();
        address target = kitAdvisory;
        bool ok;
        vm.prank(address(root));
        uint256 before = gasleft();
        assembly ("memory-safe") {
            ok := staticcall(limit, target, add(input, 32), mload(input), add(out, 32), 128)
            ok := and(ok, eq(returndatasize(), 128))
        }
        used = before - gasleft();
        assertTrue(ok, "the root's call failed");
        a = abi.decode(out, (HookrTypes.Advice));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Identity
    // ------------------------------------------------------------------------------------------------------------

    function test_identity() public view {
        assertEq(address(advisory.registry()), address(obs));
        assertEq(advisory.detector(), DETECTOR);
        assertEq(advisory.configSchemaHash(), advisory.CONFIG_SCHEMA());
        assertEq(advisory.MIN_ADVISORY_GAS(), _kitRootGasLimit());
    }

    function test_constructorRejectsAZeroRegistryOrDetector() public {
        vm.expectRevert(TollLaunchCheckAdvisory.InvalidDeployment.selector);
        new TollLaunchCheckAdvisory(ILaunchObservationsReader(address(0)), DETECTOR);
        vm.expectRevert(TollLaunchCheckAdvisory.InvalidDeployment.selector);
        new TollLaunchCheckAdvisory(ILaunchObservationsReader(address(obs)), address(0));
    }

    function test_theKitPoolsAreBoundWithTheirWindow() public view {
        TollLaunchCheckAdvisory.Binding memory b = advisory.binding(address(root), kitRootKey.toId());
        assertTrue(b.bound);
        assertFalse(b.failOpen);
        assertEq(b.maxFirstBlockBps, 2500);
        assertEq(b.maxFundingLinkedBps, 2000);
        assertFalse(b.blockUnread);
        assertEq(b.activeUntilBlock, vm.getBlockNumber() + ACTIVE);
        assertTrue(advisory.binding(address(root), kitRootOpenKey.toId()).failOpen);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Buys
    // ------------------------------------------------------------------------------------------------------------

    function test_buyOverTheFirstBlockLimitIsRejected() public {
        _observe(_subject(kitRootKey), 3356, 0);
        _assertReject(_advice(kitRootKey, true, true));
        _assertReject(_advice(kitRootKey, true, false));
        _expectRejected(kitRootKey, true);
        _expectRejected(kitRootKey, false);
        (bool allowed, bytes32 reason, uint256 value) =
            advisory.check(address(root), kitRootKey.toId(), _subject(kitRootKey));
        assertFalse(allowed);
        assertEq(reason, advisory.FIRST_BLOCK());
        assertEq(value, 3356);
    }

    function test_buyOverTheFundingLinkedLimitIsRejected() public {
        _observe(_subject(kitRootKey), 100, 2001);
        _assertReject(_advice(kitRootKey, true, true));
        _expectRejected(kitRootKey, true);
        (, bytes32 reason, uint256 value) = advisory.check(address(root), kitRootKey.toId(), _subject(kitRootKey));
        assertEq(reason, advisory.FUNDING_LINKED());
        assertEq(value, 2001);
    }

    function test_buyAtOrUnderTheLimitsFills() public {
        _observe(_subject(kitRootKey), 2500, 2000);
        _assertPass(_advice(kitRootKey, true, true));
        _assertPass(_advice(kitRootKey, true, false));
        _trade(kitRootKey, true, true);
        _trade(kitRootKey, true, false);
    }

    function test_aFindingTheObservationDoesNotCarryCountsNeitherWay() public {
        obs.record(_subject(kitRootKey), DETECTOR, new MockLaunchObservations.Finding[](0));
        _assertPass(_advice(kitRootKey, true, true));
        _observe(_subject(kitRootKey), type(uint256).max, type(uint256).max);
        _assertPass(_advice(kitRootKey, true, true));
    }

    function test_anotherDetectorsFindingsAreIgnored() public {
        _recordWithFiller(_subject(kitRootKey), OTHER_DETECTOR, 0, 9000, 9000);
        _assertPass(_advice(kitRootKey, true, true));
        _trade(kitRootKey, true, true);
    }

    /// @dev Over any shares and limits, a buy in the window is rejected exactly when a limit that is on is exceeded.
    function testFuzz_buyDecisionFollowsTheLimits(uint256 firstBlock, uint256 linked) public {
        firstBlock = bound(firstBlock, 0, 10_000);
        linked = bound(linked, 0, 10_000);
        _observe(_subject(kitRootKey), firstBlock, linked);
        HookrTypes.Advice memory a = _advice(kitRootKey, true, true);
        _assertNoCharge(a);
        assertEq(a.reject, firstBlock > 2500 || linked > 2000);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Sells
    // ------------------------------------------------------------------------------------------------------------

    function test_sellOverTheLimitsFills() public {
        PoolKey memory strict = _launchWith(_data(2500, 2000, true, ACTIVE));
        _observe(_subject(kitRootKey), 9000, 9000);
        _observe(_subject(strict), 9000, 9000);
        _assertPass(_advice(kitRootKey, false, true));
        _assertPass(_advice(strict, false, false));
        _trade(kitRootKey, false, true);
        _trade(strict, false, true);
        _trade(strict, false, false);
    }

    /// @dev Any registry state, either pool, a registry that reverts: a sell is never rejected and never charged.
    function testFuzz_sellsAreNeverRejected(uint256 firstBlock, uint256 linked, bool observed, bool down) public {
        PoolKey memory strict = _launchWith(_data(1, 1, true, ACTIVE));
        if (observed) {
            _observe(_subject(kitRootKey), firstBlock, linked);
            _observe(_subject(strict), firstBlock, linked);
        }
        if (down) vm.mockCallRevert(address(obs), ILaunchObservationsReader.latestFinding.selector, "down");
        _assertPass(_advice(kitRootKey, false, true));
        _assertPass(_advice(kitRootKey, false, false));
        _assertPass(_advice(strict, false, true));
        _assertPass(_advice(strict, false, false));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Unread coins and failed reads
    // ------------------------------------------------------------------------------------------------------------

    function test_unreadCoinFailsOpenUnlessBlockUnread() public {
        _assertPass(_advice(kitRootKey, true, true));
        _trade(kitRootKey, true, true);
        PoolKey memory strict = _launchWith(_data(2500, 2000, true, ACTIVE));
        _assertReject(_advice(strict, true, true));
        _expectRejected(strict, true);
        (, bytes32 reason,) = advisory.check(address(root), strict.toId(), _subject(strict));
        assertEq(reason, advisory.NOT_OBSERVED());
    }

    function test_aRevertingRegistryCountsAsUnread() public {
        PoolKey memory strict = _launchWith(_data(2500, 2000, true, ACTIVE));
        _observe(_subject(kitRootKey), 9000, 9000);
        vm.mockCallRevert(address(obs), ILaunchObservationsReader.latestFinding.selector, "down");
        _assertPass(_advice(kitRootKey, true, true));
        _trade(kitRootKey, true, true);
        _assertReject(_advice(strict, true, true));
    }

    /// @dev A registry that burns all the gas it is given: the advisory keeps READ_RESERVE back, answers 128 bytes
    ///      within the pool's gas limit, and the fail-closed pool's buy fills.
    function test_aRegistryThatRunsOutOfGasCountsAsUnread() public {
        PoolKey memory strict = _launchWith(_data(2500, 2000, true, ACTIVE));
        vm.etch(address(obs), hex"5b5f56"); // JUMPDEST PUSH0 JUMP: loops until out of gas
        (HookrTypes.Advice memory a, uint256 used) = _rootCall(kitRootKey, true);
        _assertPass(a);
        console2.log("buy, registry out of gas, root-style call gas", used);
        _trade(kitRootKey, true, true);
        (a,) = _rootCall(strict, true);
        _assertReject(a);
    }

    function test_aRegistryThatAnswersShortCountsAsUnread() public {
        PoolKey memory strict = _launchWith(_data(2500, 2000, true, ACTIVE));
        vm.etch(address(obs), hex"60206000f3"); // RETURN 32 bytes
        _assertPass(_advice(kitRootKey, true, true));
        _trade(kitRootKey, true, true);
        _assertReject(_advice(strict, true, true));
    }

    // ------------------------------------------------------------------------------------------------------------
    // The window
    // ------------------------------------------------------------------------------------------------------------

    function test_theCheckEndsAtTheWindowsEnd() public {
        _observe(_subject(kitRootKey), 3356, 9000);
        uint64 until = advisory.binding(address(root), kitRootKey.toId()).activeUntilBlock;
        vm.roll(until - 1);
        _assertReject(_advice(kitRootKey, true, true));
        _expectRejected(kitRootKey, true);

        vm.roll(until);
        _assertPass(_advice(kitRootKey, true, true));
        _assertPass(_advice(kitRootKey, false, true));
        _trade(kitRootKey, true, true);
        (bool allowed, bytes32 reason,) = advisory.check(address(root), kitRootKey.toId(), _subject(kitRootKey));
        assertTrue(allowed);
        assertEq(reason, advisory.EXPIRED());

        vm.roll(uint256(until) + 50_000_000);
        _assertPass(_advice(kitRootKey, true, true));
    }

    function test_blockUnreadEndsWithTheWindow() public {
        PoolKey memory strict = _launchWith(_data(0, 0, true, 10));
        _assertReject(_advice(strict, true, true));
        vm.roll(vm.getBlockNumber() + 10);
        _assertPass(_advice(strict, true, true));
        _trade(strict, true, true);
    }

    function testFuzz_theWindowDecides(uint32 active, uint256 elapsed) public {
        active = uint32(bound(active, 1, type(uint32).max));
        PoolKey memory key = _launchWith(_data(2500, 0, false, active));
        uint256 start = vm.getBlockNumber();
        elapsed = bound(elapsed, 0, uint256(active) + 1_000);
        _observe(_subject(key), 3356, 0);
        vm.roll(start + elapsed);
        assertEq(_advice(key, true, true).reject, elapsed < active);
        assertFalse(_advice(key, false, true).reject);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Fail-open binding, unbound callers, other phases
    // ------------------------------------------------------------------------------------------------------------

    /// @dev HookrRoot reverts InvalidModuleResult when a fail-open advisory returns `reject`, so on a fail-open
    ///      binding the advisory answers zero advice and the buy fills.
    function test_aFailOpenBindingNeverRejects() public {
        _observe(_subject(kitRootOpenKey), 9000, 9000);
        _assertPass(_advice(kitRootOpenKey, true, true));
        _trade(kitRootOpenKey, true, true);
        (bool allowed, bytes32 reason,) = advisory.check(address(root), kitRootOpenKey.toId(), _subject(kitRootOpenKey));
        assertTrue(allowed);
        assertEq(reason, advisory.FAIL_OPEN());
    }

    function test_aCallerThatBoundNothingGetsZeroAdvice() public {
        address subject = _subject(kitRootKey);
        _observe(subject, 9000, 9000);
        HookrTypes.SwapContext memory x = _kitContext(kitRootKey, true, true, 1e18);
        vm.prank(address(0xBEEF));
        _assertPass(advisory.beforeSwap(x));
        vm.expectRevert(
            abi.encodeWithSelector(TollLaunchCheckAdvisory.UnknownPool.selector, address(0xBEEF), kitRootKey.toId())
        );
        advisory.check(address(0xBEEF), kitRootKey.toId(), subject);
    }

    function test_liquidityIsAlwaysAllowedAndAfterSwapIsZero() public {
        _observe(_subject(kitRootKey), 9000, 9000);
        assertTrue(advisory.beforeAddLiquidity(kitRootKey.toId(), trader));
        HookrTypes.SwapContext memory x = _kitContext(kitRootKey, true, true, 1e18);
        vm.prank(address(root));
        _assertPass(advisory.afterSwap(x, -1e18, 1e18));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Bind
    // ------------------------------------------------------------------------------------------------------------

    /// @dev A valid bind of a pool the root has not bound yet, with one change applied by the caller.
    function _freshKey() internal view returns (PoolKey memory key) {
        key = kitRootKey;
        key.fee = key.fee + 1;
    }

    function test_aSecondBindIsAlreadyBound() public {
        HookrTypes.PoolConfig memory pc = root.poolConfig(kitRootKey.toId());
        vm.prank(address(root));
        vm.expectRevert(
            abi.encodeWithSelector(TollLaunchCheckAdvisory.AlreadyBound.selector, address(root), kitRootKey.toId())
        );
        advisory.bind(kitRootKey, pc, _kitRootData());
    }

    function test_bindAcceptsTheRootWithValidSettings() public {
        PoolKey memory key = _freshKey();
        HookrTypes.PoolConfig memory pc = root.poolConfig(kitRootKey.toId());
        vm.prank(address(root));
        assertEq(advisory.bind(key, pc, _kitRootData()), keccak256(_kitRootData()));
        assertTrue(advisory.binding(address(root), key.toId()).bound);
    }

    function test_bindRejectsACallerThatIsNotThePoolsHook() public {
        PoolKey memory key = _freshKey();
        HookrTypes.PoolConfig memory pc = root.poolConfig(kitRootKey.toId());
        vm.prank(address(0xBEEF));
        vm.expectRevert(TollLaunchCheckAdvisory.InvalidConfig.selector);
        advisory.bind(key, pc, _kitRootData());
    }

    /// @dev A contract that is its pool's hook but holds no ADVISORY admission of this advisory in the registry.
    function test_bindRejectsARootWithoutAnAdmission() public {
        address fake = address(0xF00D);
        vm.etch(fake, hex"00");
        vm.mockCall(fake, abi.encodeWithSelector(IHookrRoot.registry.selector), abi.encode(address(registry)));
        PoolKey memory key = _freshKey();
        key.hooks = IHooks(fake);
        HookrTypes.PoolConfig memory pc = root.poolConfig(kitRootKey.toId());
        vm.prank(fake);
        vm.expectRevert(TollLaunchCheckAdvisory.InvalidConfig.selector);
        advisory.bind(key, pc, _kitRootData());
    }

    function test_bindRejectsWrongPoolSettings() public {
        PoolKey memory key = _freshKey();
        HookrTypes.PoolConfig memory good = root.poolConfig(kitRootKey.toId());
        HookrTypes.PoolConfig memory pc = good;

        pc.advisory = address(0xBEEF);
        vm.prank(address(root));
        vm.expectRevert(TollLaunchCheckAdvisory.InvalidConfig.selector);
        advisory.bind(key, pc, _kitRootData());

        pc = root.poolConfig(kitRootKey.toId());
        pc.advisoryPhases = HookrTypes.BEFORE_SWAP | HookrTypes.AFTER_SWAP;
        vm.prank(address(root));
        vm.expectRevert(TollLaunchCheckAdvisory.InvalidConfig.selector);
        advisory.bind(key, pc, _kitRootData());

        pc = root.poolConfig(kitRootKey.toId());
        pc.advisoryPhases = HookrTypes.AFTER_SWAP;
        vm.prank(address(root));
        vm.expectRevert(TollLaunchCheckAdvisory.InvalidConfig.selector);
        advisory.bind(key, pc, _kitRootData());

        pc = root.poolConfig(kitRootKey.toId());
        pc.advisoryGasLimit = advisory.MIN_ADVISORY_GAS() - 1;
        vm.prank(address(root));
        vm.expectRevert(TollLaunchCheckAdvisory.InvalidConfig.selector);
        advisory.bind(key, pc, _kitRootData());
    }

    function test_bindRejectsInvalidData() public {
        PoolKey memory key = _freshKey();
        HookrTypes.PoolConfig memory pc = root.poolConfig(kitRootKey.toId());
        bytes[6] memory bad = [
            _data(2500, 2000, false, 0), // a window of 0 blocks
            _data(10_000, 0, false, ACTIVE), // a first-block limit that can never trip
            _data(0, 10_000, false, ACTIVE), // a funding-linked limit that can never trip
            _data(0, 0, false, ACTIVE), // can never reject anything
            bytes.concat(_kitRootData(), hex"00"), // not four words
            abi.encode(uint256(2500), uint256(2000), uint256(0)) // three words
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(address(root));
            vm.expectRevert(TollLaunchCheckAdvisory.InvalidConfig.selector);
            advisory.bind(key, pc, bad[i]);
        }
        // A word out of its type's range does not decode.
        vm.prank(address(root));
        vm.expectRevert();
        advisory.bind(key, pc, abi.encode(uint256(2500), uint256(2000), uint256(2), uint256(ACTIVE)));
        // The edges of the range bind.
        vm.prank(address(root));
        advisory.bind(key, pc, _data(9_999, 9_999, false, type(uint32).max));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Gas against the mock registry (the fork test measures the live one)
    // ------------------------------------------------------------------------------------------------------------

    function test_gas_rootStyleCalls() public {
        address subject = _subject(kitRootKey);
        _recordWorstCase(subject, 2001);
        _kitCold();
        (HookrTypes.Advice memory a, uint256 used) = _rootCall(kitRootKey, true);
        _assertReject(a);
        console2.log("buy, worst case, refused on the second read, cold (mock registry)", used);
        _recordWithFiller(subject, DETECTOR, 30, 3356, 0);
        _kitCold();
        (a, used) = _rootCall(kitRootKey, true);
        _assertReject(a);
        console2.log("buy refused, one read over 31 findings, cold (mock registry)", used);
        _kitCold();
        (a, used) = _rootCall(kitRootKey, false);
        _assertPass(a);
        console2.log("sell, cold", used);
    }
}
