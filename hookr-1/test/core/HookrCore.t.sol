// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {FixedAdvice} from "../utils/FixedAdvice.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

contract PretendRoot {
    IPoolManager public immutable poolManager;
    IHookrRegistry public immutable registry;
    PoolId public bindingPool;

    constructor(IPoolManager manager, IHookrRegistry registry_) {
        poolManager = manager;
        registry = registry_;
    }

    function PERMISSION_FLAGS() external view returns (uint160) {
        return uint160(address(this)) & 0x3fff;
    }

    function bindOtherRules(
        HookrRules rules,
        PoolKey memory key,
        HookrTypes.PoolConfig memory config_,
        bytes memory data
    ) external {
        bindingPool = PoolId.wrap(keccak256(abi.encode(key)));
        rules.bind(key, config_, data);
    }
}

contract HookrCoreTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    function setUp() public {
        _setUpPeriphery();
    }

    function testTimelockCannotExecuteEarlyOrWithoutQueue() public {
        bytes32 op = registry.operationHash(registry.SET_LAUNCHER(), abi.encode(address(this), true));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.setLauncher(address(this), true);
        registry.queue(registry.SET_LAUNCHER(), abi.encode(address(this), true));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.setLauncher(address(this), true);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setLauncher(address(this), true);
        assertTrue(registry.isLauncher(address(this)));
        // An admission of an active launcher is refused before the queue is read.
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.AlreadyActive.selector, address(this)));
        registry.setLauncher(address(this), true);
    }

    function testOnlyOwnerCanQueueAndFreeze() public {
        bytes32 kind = registry.SET_LAUNCHER();
        vm.prank(trader);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.queue(kind, abi.encode(address(this), true));
        vm.prank(trader);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.freezeRoot(address(root));
    }

    function testFreezeRejectsNewAdmissionButExistingPoolsTrade() public {
        (, PoolKey memory key,,) = _launch(true, false);
        HookrRules next = new HookrRules(manager, registry, protocol, address(root), 0);
        IHookrRegistry.Admission memory a = _admission(address(next), IHookrRegistry.Kind.RULES);
        a.schemaHash = next.configSchemaHash();
        // Queued before the freeze: the freeze still refuses it at execution.
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        registry.freezeRoot(address(root));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(IHookrRegistry.RootFrozen.selector);
        registry.admit(address(root), a);
        vm.startPrank(trader);
        (, uint256 amountOut) = router.swap(_swap(key, true, true, 1e18), address(0), new uint256[](0));
        vm.stopPrank();
        assertGt(amountOut, 0);
    }

    function testRetirementPreservesOldTradingAndClosesNewPoolCreation() public {
        (, PoolKey memory key,,) = _launch(true, false);
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.retireRoot(address(root));
        assertTrue(registry.isRoot(address(root)));
        assertFalse(registry.rootOpen(address(root)));
        vm.startPrank(trader);
        router.swap(_swap(key, true, true, 1e18), address(0), new uint256[](0));
        vm.stopPrank();
        vm.expectRevert();
        _launch(false, true);
    }

    function testRulesCannotBeFirstBoundByAnOutsider() public {
        (, PoolKey memory key,,) = _launch(true, false);
        HookrTypes.PoolConfig memory config_ = root.poolConfig(key.toId());
        bytes memory data = abi.encode(_member(key.currency1).rules);
        vm.prank(trader);
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        rules.bind(key, config_, data);
    }

    function testNewRegistryApprovedRootCannotReachExistingRulesLedger() public {
        (, PoolKey memory key,, Currency quote) = _launch(true, false);
        IHookrRouter.Swap memory params = _swap(key, true, true, 1e18);
        vm.prank(trader);
        router.swap(params, address(0), new uint256[](0));
        uint256 backing = manager.balanceOf(address(rules), quote.toId());
        uint256 liability = rules.totalLiability(quote);
        PretendRoot attacker = new PretendRoot(manager, registry);
        registry.queue(registry.REGISTER_ROOT(), abi.encode(address(attacker), address(attacker).codehash));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.registerRoot(address(attacker), address(attacker).codehash);
        HookrTypes.PoolConfig memory config_ = root.poolConfig(key.toId());
        bytes memory data = abi.encode(rules.config(key.toId()));
        key.hooks = IHooks(address(attacker));
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        attacker.bindOtherRules(rules, key, config_, data);
        assertEq(rules.totalLiability(quote), liability);
        assertEq(manager.balanceOf(address(rules), quote.toId()), backing);
        assertEq(rules.trustedRoot(), address(root));
    }

    function testDirectInitializationAndReceiptTheftRefused() public {
        (, PoolKey memory key,,) = _launch(true, false);
        key.tickSpacing = 120;
        vm.expectRevert();
        manager.initialize(key, SQRT_ONE);
        vm.prank(trader);
        vm.expectRevert(IHookrRootEvents.Unauthorized.selector);
        root.takeReceipt(key.toId());
    }

    function testKnownRuleCapsRejectedAtBind() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[0].config.caps.maxQuoteTakePips = 1;
        vm.expectRevert();
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    function testKnownDynamicFeeCapsRejectedAtBind() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[0].rules.maxFeePips = 100_000;
        members[0].rules.dynamicFeeSens = 5;
        members[0].tickSpacing = 200;
        members[0].config.caps.maxLpFeePips = 50_000;
        vm.expectRevert();
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        members[0].config.caps.maxLpFeePips = 100_000;
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    function testClippedDynamicFeeAndSnipeCapsIncludeSplitRounding() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[0].rules = HookrTypes.RulesConfig({
            guardEndBlock: uint40(block.number + 100),
            // The widest span the reach bound admits at sensitivity 1 and a 33.33% share, clipped by the Snipe.
            maxFeePips: 72_167,
            snipeTaxPips: 597_000,
            snipeFloorPips: 0,
            snipeDecaySeconds: 0,
            dynamicFeeSens: 1,
            burnBps: 0,
            lpBps: 0,
            potBps: 0,
            royaltyBps: 0,
            protocolShareBps: 3333,
            potEveryNBuys: 0,
            maxBuyQuoteAmount: 0,
            potMinBuyQuote: 0,
            royaltyTo: address(0),
            integrator: address(0)
        });
        members[0].tickSpacing = 200;
        // The endpoint's two floors sum to 198,979; other clipped splits can require 198,980.
        members[0].config.caps.maxQuoteTakePips = 198_979;
        vm.expectRevert();
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        members[0].config.caps.maxQuoteTakePips = 198_980;
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    function testPartialFillRefundIsBackedAndClaimable() public {
        (, PoolKey memory key,, Currency quote) = _launch(true, false);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e23);
        p.sqrtPriceLimitX96 =
            p.zeroForOne ? uint160(uint256(SQRT_ONE) * 9999 / 10_000) : uint160(uint256(SQRT_ONE) * 10_001 / 10_000);
        vm.prank(trader);
        (uint256 input,) = router.swap(p, address(0), new uint256[](0));
        assertLt(input, 1e23);
        uint256 refund = rules.claimable(quote, trader);
        assertGt(refund, 0);
        assertTrue(rules.accountingInvariant(quote));
        uint256 beforeBalance = quote.balanceOf(trader);
        vm.prank(trader);
        uint256 paid = rules.claim(quote);
        assertEq(paid, refund);
        assertEq(quote.balanceOf(trader), beforeBalance + refund);
        assertEq(rules.claimable(quote, trader), 0);
        assertTrue(rules.accountingInvariant(quote));
    }

    function testClaimCannotRedirectAnotherBeneficiary() public {
        (, PoolKey memory key,, Currency quote) = _launch(true, false);
        vm.startPrank(trader);
        router.swap(_swap(key, true, true, 1e18), address(0), new uint256[](0));
        vm.stopPrank();
        uint256 protocolClaim = rules.claimable(quote, protocol);
        assertGt(protocolClaim, 0);
        vm.prank(address(0x9876));
        vm.expectRevert(IHookrRulesState.NothingToClaim.selector);
        rules.claimTo(quote, address(0x9876));
        assertEq(rules.claimable(quote, protocol), protocolClaim);
    }

    function testPotConfigurationRefused() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[0].rules.potBps = 200;
        members[0].rules.potEveryNBuys = 2;
        members[0].rules.potMinBuyQuote = 1e15;
        vm.expectRevert();
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    function testAdvisoryAfterTakeComposesAndHasBacking() public {
        address beneficiary = address(0x2001);
        FixedAdvice a = new FixedAdvice(
            HookrTypes.Advice(500, 5000, beneficiary, false),
            HookrTypes.Advice(0, 5000, beneficiary, false),
            false,
            false
        );
        PoolKey memory key = _withAdvice(a, false, 600_000);
        vm.startPrank(trader);
        router.swap(_swap(key, false, true, 1e18), address(0), new uint256[](0));
        vm.stopPrank();
        Currency quote = root.poolConfig(key.toId()).quote;
        assertGt(rules.claimable(quote, beneficiary), 0);
        assertTrue(rules.accountingInvariant(quote));
    }

    function testAfterAdvisoryCannotRetuneCompletedLpFee() public {
        FixedAdvice a = new FixedAdvice(
            HookrTypes.Advice(0, 0, address(0), false), HookrTypes.Advice(1, 0, address(0), false), false, false
        );
        PoolKey memory key = _withAdvice(a, false, 600_000);
        IHookrRouter.Swap memory params = _swap(key, false, true, 1e18);
        vm.prank(trader);
        vm.expectRevert();
        router.swap(params, address(0), new uint256[](0));
    }

    function testMalformedFeeOnlyAdviceUsesExplicitCeiling() public {
        FixedAdvice a = new FixedAdvice(
            HookrTypes.Advice(0, 0, address(0), false), HookrTypes.Advice(0, 0, address(0), false), false, true
        );
        // The pool cap must cover Rules' maximum LP fee (base 3,000 + LP Rewards 20,000) plus the advisory's admitted
        // 10,000, so the malformed fee-only advice charges exactly that ceiling.
        PoolKey memory key = _withAdvice(a, true, 33_000);
        vm.startPrank(trader);
        (, uint256 amountOut) = router.swap(_swap(key, false, true, 1e18), address(0), new uint256[](0));
        vm.stopPrank();
        assertGt(amountOut, 0);
    }

    function testERC7201NamespacesMatchActualStorage() public {
        (, PoolKey memory key,,) = _launch(true, false);
        bytes32 registrySlot = _erc7201("hookr.registry");
        assertEq(address(uint160(uint256(vm.load(address(registry), registrySlot)))), address(this));
        bytes32 rulesPool = keccak256(abi.encode(key.toId(), _erc7201("hookr.rules")));
        uint256 rulesWord = uint256(vm.load(address(rules), rulesPool));
        assertEq(uint24(rulesWord), root.poolConfig(key.toId()).baseLpFeePips, "base fee");
        assertEq(int16(uint16(rulesWord >> 24)), key.tickSpacing, "tick spacing, 16 bits");
        assertEq((rulesWord >> 40) & 0xff, 1, "bound flag");
        assertEq((rulesWord >> 56) & 0xff, 0, "no integrator");
        bytes32 rootPool = keccak256(abi.encode(key.toId(), _erc7201("hookr.root")));
        assertEq(address(uint160(uint256(vm.load(address(root), rootPool)))), root.poolConfig(key.toId()).rules);
    }

    function testFuzzTinyActualFeeRounding(uint128 amount, bool subjectFirst) public {
        amount = uint128(bound(amount, 10, 100_000));
        (, PoolKey memory key,, Currency quote) = _launch(subjectFirst, false);
        vm.startPrank(trader);
        router.swap(_swap(key, true, true, amount), address(0), new uint256[](0));
        vm.stopPrank();
        assertEq(manager.balanceOf(address(rules), quote.toId()), rules.totalLiability(quote));
    }

    function _withAdvice(FixedAdvice a, bool fallback_, uint24 poolFeeCap) private returns (PoolKey memory key) {
        IHookrRegistry.Admission memory admission_ = _admission(address(a), IHookrRegistry.Kind.ADVISORY);
        admission_.schemaHash = a.configSchemaHash();
        admission_.caps = HookrTypes.Caps(10_000, fallback_ ? 0 : 20_000, 0);
        admission_.feeOnly = fallback_;
        admission_.failOpen = fallback_;
        registry.queue(registry.ADMIT(), abi.encode(address(root), admission_));
        registry.queue(registry.SET_LAUNCHER(), abi.encode(address(this), true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), admission_);
        registry.setLauncher(address(this), true);
        IHookrLauncher.Member memory m = _member(Currency.wrap(address(tokenB)));
        m.config.subject = Currency.wrap(address(tokenA));
        m.config.quote = m.quote;
        m.config.liquidityOwner = address(this);
        m.config.caps.maxLpFeePips = poolFeeCap;
        m.config.advisory = address(a);
        m.config.advisoryGasLimit = 2_000_000;
        m.config.advisoryPhases = 3;
        m.config.advisoryFailOpen = fallback_;
        bool aFirst = address(tokenA) < address(tokenB);
        key = PoolKey(
            Currency.wrap(aFirst ? address(tokenA) : address(tokenB)),
            Currency.wrap(aFirst ? address(tokenB) : address(tokenA)),
            0x800000,
            60,
            IHooks(address(root))
        );
        root.initializePool(key, m.config, abi.encode(m.rules), bytes(""), SQRT_ONE);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        tokenA.approve(address(lp), type(uint256).max);
        tokenB.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-60_000, 60_000, 1e24, bytes32(0)), bytes(""));
    }

    function _admission(address implementation, IHookrRegistry.Kind kind)
        private
        view
        returns (IHookrRegistry.Admission memory a)
    {
        a = IHookrRegistry.Admission(
            kind,
            implementation,
            implementation.codehash,
            bytes32(0),
            HookrTypes.Caps(600_000, 200_000, 1000),
            2_000_000,
            3,
            false,
            false
        );
    }

    function _erc7201(string memory namespace) private pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(namespace))) - 1)) & ~bytes32(uint256(255));
    }
}
