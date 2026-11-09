// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookrModuleTypesV1} from "hookr/libraries/HookrModuleTypesV1.sol";

import {TollLaunchCheckModule, ILaunchObservationsReader} from "../src/TollLaunchCheckModule.sol";
import {KernelCallHarness} from "./KernelCallHarness.sol";

/// @dev Mirrors the read side of the ERC-8470 registry: findings are keyed by chain id, token,
///      detector, kind and param; a token the detector never observed returns observation 0 and
///      NOT_READ; a finding the latest observation does not carry returns NOT_READ.
contract MockLaunchObservations is ILaunchObservationsReader {
    uint256 internal constant NOT_READ = type(uint256).max;

    mapping(bytes32 => uint256) internal _latest;
    mapping(bytes32 => mapping(bytes32 => bool)) internal _has;
    mapping(bytes32 => mapping(bytes32 => uint256)) internal _value;

    function _key(uint256 chainId, address token, address detector) internal pure returns (bytes32) {
        return keccak256(abi.encode(chainId, token, detector));
    }

    function observe(address token, address detector, uint256 observationId) external {
        _latest[_key(block.chainid, token, detector)] = observationId;
    }

    function setFinding(address token, address detector, bytes32 kind, uint64 param, uint256 value) external {
        bytes32 k = _key(block.chainid, token, detector);
        bytes32 f = keccak256(abi.encode(kind, param));
        _has[k][f] = true;
        _value[k][f] = value;
    }

    function latestFinding(uint256 chainId, address token, address detector, bytes32 kind, uint64 param)
        external
        view
        returns (uint256 observationId, uint64 observedBlock, uint64 recordedAt, uint256 value, Lean lean)
    {
        bytes32 k = _key(chainId, token, detector);
        observationId = _latest[k];
        if (observationId == 0) return (0, 0, 0, NOT_READ, Lean.None);
        bytes32 f = keccak256(abi.encode(kind, param));
        value = _has[k][f] ? _value[k][f] : NOT_READ;
        return (observationId, 1, 1, value, Lean.None);
    }
}

contract RevertingRegistry {
    fallback() external {
        revert("registry down");
    }
}

/// @dev The catalog's registration maxima for the live native block, from
///      deployments/robinhood-4663.v2.json `registrationCaps`, as in the module template.
contract TollLaunchCheckModuleTest is Test {
    uint24 internal constant CATALOG_MAX_LP_FEE_SURCHARGE_PIPS = 500_000;
    uint16 internal constant CATALOG_MAX_SPECIFIED_QUOTE_TAKE_BPS = 4_000;
    uint16 internal constant CATALOG_MAX_UNSPECIFIED_QUOTE_TAKE_BPS = 2_500;
    uint16 internal constant CATALOG_MAX_SUBJECT_TAKE_BPS = 1_000;
    uint32 internal constant CATALOG_MAX_CALLBACK_GAS = 2_000_000;
    /// @dev HookrModuleCatalogV1.MIN_CALLBACK_GAS.
    uint32 internal constant CATALOG_MIN_CALLBACK_GAS = 25_000;
    /// @dev The `callbackGasLimit` this module's registration would ask for. The fork test measures
    ///      the real registry read under it.
    uint32 internal constant PROPOSED_CALLBACK_GAS = 150_000;

    MockLaunchObservations internal registry;
    TollLaunchCheckModule internal module;
    KernelCallHarness internal harness;

    bytes32 internal constant POOL_ID = keccak256("pool");
    address internal constant KERNEL = address(0xB3CA);
    address internal constant SUBJECT = address(0x5AB1);
    address internal constant QUOTE = address(0);
    address internal constant DETECTOR = address(0xD7EC);
    address internal constant OTHER_DETECTOR = address(0xBAD);

    bytes32 internal FIRST_BLOCK_SHARE;
    bytes32 internal FUNDING_LINKED_SHARE;

    function setUp() public {
        registry = new MockLaunchObservations();
        module = new TollLaunchCheckModule(registry, DETECTOR);
        harness = new KernelCallHarness();
        FIRST_BLOCK_SHARE = module.FIRST_BLOCK_SHARE();
        FUNDING_LINKED_SHARE = module.FUNDING_LINKED_SHARE();
    }

    function _cfg(uint16 maxFirstBlockBps, uint16 maxFundingLinkedBps, bool blockUnread)
        internal
        pure
        returns (TollLaunchCheckModule.Config memory)
    {
        return TollLaunchCheckModule.Config({
            poolId: POOL_ID,
            kernel: KERNEL,
            subject: SUBJECT,
            quote: QUOTE,
            maxFirstBlockBps: maxFirstBlockBps,
            maxFundingLinkedBps: maxFundingLinkedBps,
            blockUnread: blockUnread
        });
    }

    function _config(uint16 maxFirstBlockBps, uint16 maxFundingLinkedBps, bool blockUnread)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_cfg(maxFirstBlockBps, maxFundingLinkedBps, blockUnread));
    }

    function _swap(bool isBuy, bool exactInput) internal pure returns (HookrModuleTypesV1.SwapContext memory c) {
        c.poolId = POOL_ID;
        c.subject = SUBJECT;
        c.quote = QUOTE;
        c.isBuy = isBuy;
        c.exactInput = exactInput;
        c.amountSpecified = exactInput ? -int256(1 ether) : int256(1 ether);
    }

    function _observe(uint256 firstBlockBps, uint256 fundingLinkedBps) internal {
        registry.observe(SUBJECT, DETECTOR, 1);
        registry.setFinding(SUBJECT, DETECTOR, FIRST_BLOCK_SHARE, 0, firstBlockBps);
        registry.setFinding(SUBJECT, DETECTOR, FUNDING_LINKED_SHARE, 1, fundingLinkedBps);
    }

    function _assertZero(HookrModuleTypesV1.ModuleResult memory r) internal pure {
        assertEq(r.lpFeeSurchargePips, 0);
        assertEq(r.quoteTakeBps, 0);
        assertEq(r.claimRecipient, address(0));
        assertEq(r.attributionKey, bytes32(0));
    }

    function _refusal(bytes32 reason, uint256 value) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(TollLaunchCheckModule.LaunchCheckRefused.selector, SUBJECT, reason, value);
    }

    // --- identity and caps ---------------------------------------------------------------------

    function test_identity() public view {
        assertEq(module.moduleKey(), keccak256("LABS_TOLL_LAUNCH_CHECK"));
        assertEq(module.moduleVersion(), 1);
        assertEq(module.configSchemaHash(), module.CONFIG_SCHEMA_HASH());
        assertEq(address(module.registry()), address(registry));
        assertEq(module.detector(), DETECTOR);
    }

    function test_constructorRejectsAZeroRegistryOrDetector() public {
        vm.expectRevert(TollLaunchCheckModule.InvalidDeployment.selector);
        new TollLaunchCheckModule(ILaunchObservationsReader(address(0)), DETECTOR);
        vm.expectRevert(TollLaunchCheckModule.InvalidDeployment.selector);
        new TollLaunchCheckModule(registry, address(0));
    }

    function test_validateStackAsksForNothing() public view {
        bytes memory config = _config(2500, 2000, false);
        HookrModuleTypesV1.ModuleConfigCaps memory caps = module.validateStack(POOL_ID, KERNEL, SUBJECT, QUOTE, config);
        assertEq(caps.configHash, keccak256(config));
        assertEq(caps.maxLpFeeSurchargePips, 0);
        assertEq(caps.maxSpecifiedQuoteTakeBps, 0);
        assertEq(caps.maxUnspecifiedQuoteTakeBps, 0);
        assertEq(caps.maxSubjectTakeBps, 0);
        assertLe(caps.maxLpFeeSurchargePips, CATALOG_MAX_LP_FEE_SURCHARGE_PIPS);
        assertLe(caps.maxSpecifiedQuoteTakeBps, CATALOG_MAX_SPECIFIED_QUOTE_TAKE_BPS);
        assertLe(caps.maxUnspecifiedQuoteTakeBps, CATALOG_MAX_UNSPECIFIED_QUOTE_TAKE_BPS);
        assertLe(caps.maxSubjectTakeBps, CATALOG_MAX_SUBJECT_TAKE_BPS);
    }

    function test_proposedCallbackGasFitsTheCatalog() public pure {
        assertGe(PROPOSED_CALLBACK_GAS, CATALOG_MIN_CALLBACK_GAS);
        assertLe(PROPOSED_CALLBACK_GAS, CATALOG_MAX_CALLBACK_GAS);
    }

    // --- config validation at admission -----------------------------------------------------------

    function test_validateConfigCommitsToTheExactBytes() public view {
        bytes memory config = _config(2500, 2000, false);
        assertEq(module.validateConfig(config), keccak256(config));
    }

    function test_validateConfigAcceptsTheEdgesOfTheRange() public view {
        module.validateConfig(_config(1, 0, false));
        module.validateConfig(_config(0, 9_999, false));
        module.validateConfig(_config(0, 0, true));
    }

    function test_validateConfigRejectsAFirstBlockLimitThatCanNeverTrip() public {
        vm.expectRevert(TollLaunchCheckModule.InvalidConfig.selector);
        module.validateConfig(_config(10_000, 2000, false));
    }

    function test_validateConfigRejectsAFundingLinkedLimitThatCanNeverTrip() public {
        vm.expectRevert(TollLaunchCheckModule.InvalidConfig.selector);
        module.validateConfig(_config(2500, 10_000, false));
    }

    function testFuzz_validateConfigRejectsOutOfRangeBps(uint16 firstBlock, uint16 linked) public {
        firstBlock = uint16(bound(firstBlock, 10_000, type(uint16).max));
        vm.expectRevert(TollLaunchCheckModule.InvalidConfig.selector);
        module.validateConfig(_config(firstBlock, 0, true));
        linked = uint16(bound(linked, 10_000, type(uint16).max));
        vm.expectRevert(TollLaunchCheckModule.InvalidConfig.selector);
        module.validateConfig(_config(0, linked, true));
    }

    function test_validateConfigRejectsAConfigThatCanNeverRefuse() public {
        vm.expectRevert(TollLaunchCheckModule.InvalidConfig.selector);
        module.validateConfig(_config(0, 0, false));
    }

    function test_validateConfigRejectsANonCanonicalEncoding() public {
        bytes memory config = bytes.concat(_config(2500, 2000, false), hex"00");
        vm.expectRevert(TollLaunchCheckModule.InvalidConfig.selector);
        module.validateConfig(config);
    }

    function test_validateConfigRejectsZeroBindingsAndASubjectEqualToTheQuote() public {
        TollLaunchCheckModule.Config memory c = _cfg(2500, 2000, false);
        c.poolId = bytes32(0);
        vm.expectRevert(TollLaunchCheckModule.InvalidConfig.selector);
        module.validateConfig(abi.encode(c));
        c = _cfg(2500, 2000, false);
        c.kernel = address(0);
        vm.expectRevert(TollLaunchCheckModule.InvalidConfig.selector);
        module.validateConfig(abi.encode(c));
        c = _cfg(2500, 2000, false);
        c.subject = address(0);
        vm.expectRevert(TollLaunchCheckModule.InvalidConfig.selector);
        module.validateConfig(abi.encode(c));
        c = _cfg(2500, 2000, false);
        c.quote = SUBJECT;
        vm.expectRevert(TollLaunchCheckModule.InvalidConfig.selector);
        module.validateConfig(abi.encode(c));
    }

    function test_validateStackRejectsAConfigForAnotherStack() public {
        bytes memory config = _config(2500, 2000, false);
        vm.expectRevert(TollLaunchCheckModule.ConfigNotForThisStack.selector);
        module.validateStack(keccak256("other"), KERNEL, SUBJECT, QUOTE, config);
        vm.expectRevert(TollLaunchCheckModule.ConfigNotForThisStack.selector);
        module.validateStack(POOL_ID, address(0xBEEF), SUBJECT, QUOTE, config);
        vm.expectRevert(TollLaunchCheckModule.ConfigNotForThisStack.selector);
        module.validateStack(POOL_ID, KERNEL, address(0xBEEF), QUOTE, config);
        vm.expectRevert(TollLaunchCheckModule.ConfigNotForThisStack.selector);
        module.validateStack(POOL_ID, KERNEL, SUBJECT, address(0xBEEF), config);
    }

    // --- buys --------------------------------------------------------------------------------------

    function test_buyUnderTheLimitsPassesAndTakesNothing() public {
        _observe(209, 0);
        _assertZero(module.beforeSwap(_swap(true, true), _config(2500, 2000, false)));
        _assertZero(module.beforeSwap(_swap(true, false), _config(2500, 2000, false)));
    }

    function test_firstBlockShareOverTheLimitRefusesTheBuy() public {
        _observe(3356, 0);
        vm.expectRevert(_refusal(module.FIRST_BLOCK(), 3356));
        module.beforeSwap(_swap(true, true), _config(2500, 2000, false));
    }

    function test_firstBlockShareAtTheLimitPasses() public {
        _observe(2500, 0);
        _assertZero(module.beforeSwap(_swap(true, true), _config(2500, 2000, false)));
    }

    function test_fundingLinkedShareOverTheLimitRefusesTheBuy() public {
        _observe(100, 2001);
        vm.expectRevert(_refusal(module.FUNDING_LINKED(), 2001));
        module.beforeSwap(_swap(true, true), _config(2500, 2000, false));
    }

    function test_firstBlockIsReportedBeforeFundingLinked() public {
        _observe(3356, 5000);
        vm.expectRevert(_refusal(module.FIRST_BLOCK(), 3356));
        module.beforeSwap(_swap(true, true), _config(2500, 2000, false));
    }

    function test_aZeroLimitIsOff() public {
        _observe(9000, 100);
        _assertZero(module.beforeSwap(_swap(true, true), _config(0, 2000, false)));
        _observe(100, 9000);
        _assertZero(module.beforeSwap(_swap(true, true), _config(2500, 0, false)));
    }

    function test_unreadTokenFollowsThePolicy() public {
        _assertZero(module.beforeSwap(_swap(true, true), _config(2500, 2000, false)));
        vm.expectRevert(_refusal(module.NOT_OBSERVED(), 0));
        module.beforeSwap(_swap(true, true), _config(2500, 2000, true));
    }

    function test_anotherDetectorsFindingsAreIgnored() public {
        registry.observe(SUBJECT, OTHER_DETECTOR, 1);
        registry.setFinding(SUBJECT, OTHER_DETECTOR, FIRST_BLOCK_SHARE, 0, 9000);
        _assertZero(module.beforeSwap(_swap(true, true), _config(2500, 2000, false)));
        vm.expectRevert(_refusal(module.NOT_OBSERVED(), 0));
        module.beforeSwap(_swap(true, true), _config(2500, 2000, true));
    }

    function test_aFindingTheObservationDoesNotCarryCountsNeitherWay() public {
        registry.observe(SUBJECT, DETECTOR, 1);
        _assertZero(module.beforeSwap(_swap(true, true), _config(2500, 2000, true)));
        registry.setFinding(SUBJECT, DETECTOR, FIRST_BLOCK_SHARE, 0, type(uint256).max);
        registry.setFinding(SUBJECT, DETECTOR, FUNDING_LINKED_SHARE, 1, type(uint256).max);
        _assertZero(module.beforeSwap(_swap(true, true), _config(2500, 2000, true)));
    }

    function test_checkMatchesBeforeSwap() public {
        _observe(3356, 0);
        (bool allowed, bytes32 reason, uint256 value) = module.check(SUBJECT, _cfg(2500, 2000, false));
        assertFalse(allowed);
        assertEq(reason, module.FIRST_BLOCK());
        assertEq(value, 3356);
        (allowed,,) = module.check(SUBJECT, _cfg(4000, 2000, false));
        assertTrue(allowed);
    }

    function test_aRegistryThatRevertsRefusesBuys() public {
        TollLaunchCheckModule m =
            new TollLaunchCheckModule(ILaunchObservationsReader(address(new RevertingRegistry())), DETECTOR);
        vm.expectRevert();
        m.beforeSwap(_swap(true, true), _config(2500, 2000, false));
    }

    // --- sells -------------------------------------------------------------------------------------

    function test_sellOfATokenOverTheLimitsPasses() public {
        _observe(3356, 9000);
        _assertZero(module.beforeSwap(_swap(false, true), _config(2500, 2000, true)));
        _assertZero(module.beforeSwap(_swap(false, false), _config(2500, 2000, true)));
    }

    /// @dev Any registry state, any config bytes (valid or not), a registry that reverts: a sell never
    ///      reverts and never asks for anything.
    function testFuzz_sellsAreNeverRefused(uint256 firstBlock, uint256 linked, bool observed, bytes calldata junk)
        public
    {
        if (observed) _observe(firstBlock, linked);
        _assertZero(module.beforeSwap(_swap(false, true), junk));
        _assertZero(module.beforeSwap(_swap(false, false), _config(1, 1, true)));
        TollLaunchCheckModule down =
            new TollLaunchCheckModule(ILaunchObservationsReader(address(new RevertingRegistry())), DETECTOR);
        _assertZero(down.beforeSwap(_swap(false, true), junk));
    }

    /// @dev Whatever the registry holds, a buy either reverts with `LaunchCheckRefused` or passes with
    ///      an all-zero result, and it refuses exactly when a configured limit is exceeded.
    function testFuzz_buyDecisionFollowsTheLimits(uint16 maxFirst, uint16 maxLinked, uint256 firstBlock, uint256 linked)
        public
    {
        maxFirst = uint16(bound(maxFirst, 1, 9_999));
        maxLinked = uint16(bound(maxLinked, 0, 9_999));
        firstBlock = bound(firstBlock, 0, 10_000);
        linked = bound(linked, 0, 10_000);
        _observe(firstBlock, linked);
        bytes memory config = _config(maxFirst, maxLinked, false);
        if (firstBlock > maxFirst) {
            vm.expectRevert(_refusal(module.FIRST_BLOCK(), firstBlock));
            module.beforeSwap(_swap(true, true), config);
        } else if (maxLinked != 0 && linked > maxLinked) {
            vm.expectRevert(_refusal(module.FUNDING_LINKED(), linked));
            module.beforeSwap(_swap(true, true), config);
        } else {
            _assertZero(module.beforeSwap(_swap(true, true), config));
        }
    }

    // --- the kernel's call ---------------------------------------------------------------------------

    function test_kernelStyleCallSeesAZeroResultOrTheRefusalData() public {
        _observe(209, 0);
        (bool ok, bytes memory out,) = harness.callBeforeSwap(
            address(module), PROPOSED_CALLBACK_GAS, _swap(true, true), _config(2500, 2000, false)
        );
        assertTrue(ok);
        assertEq(out.length, 128);
        assertEq(keccak256(out), keccak256(new bytes(128)));

        _observe(3356, 0);
        (ok, out,) = harness.callBeforeSwap(
            address(module), PROPOSED_CALLBACK_GAS, _swap(true, true), _config(2500, 2000, false)
        );
        assertFalse(ok);
        // 100 bytes of revert data: under the 128-byte buffer, so the kernel hashes all of it.
        assertEq(out.length, 100);
        assertEq(keccak256(out), keccak256(_refusal(module.FIRST_BLOCK(), 3356)));
    }

    // --- other phases ------------------------------------------------------------------------------

    function test_liquidityAndAfterSwapAreNoOps() public {
        _observe(3356, 9000);
        HookrModuleTypesV1.LiquidityContext memory liq;
        assertTrue(module.beforeAddLiquidity(liq, _config(2500, 2000, true)));
        HookrModuleTypesV1.AfterSwapContext memory after_;
        after_.isBuy = true;
        _assertZero(module.afterSwap(after_, _config(2500, 2000, true)));
    }
}
