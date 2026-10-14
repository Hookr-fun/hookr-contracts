// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {IHookrRulesConfig} from "../../src/interfaces/IHookrRulesConfig.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";

/// @notice Audit finding NM-03.
contract HookrFeeAdvisoryTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant ADMISSION_CAP = 50_000;
    uint32 internal constant ADVISORY_GAS = 200_000;
    // Fixture Rules: base 3000, no dynamic fee, LP Rewards 14,250 pips on buys (lpBps 200, share 25%, royalty 5%).
    uint256 internal constant BASE = 3000;
    uint256 internal constant BUY_NATIVE = 17_250;
    uint256 internal constant SELL_NATIVE = 3000;

    HookrFeeAdvisory internal fee;
    HookrFeeAdvisory internal closedFee;
    address internal keeper = address(0xBEEF);
    address internal keeper2 = address(0xBEE2);
    int24 internal spacing = 60;

    function setUp() public {
        _setUpPeriphery();
        fee = _deployAdmitted(true);
        closedFee = _deployAdmitted(false);
        fee.queue(fee.ADD_KEEPER(), abi.encode(keeper));
        closedFee.queue(closedFee.ADD_KEEPER(), abi.encode(keeper));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        fee.addKeeper(keeper);
        closedFee.addKeeper(keeper);
    }

    // ---------------------------------------------------------------- helpers

    function _deployAdmitted(bool failOpen) internal returns (HookrFeeAdvisory m) {
        m = new HookrFeeAdvisory(address(this), 1 days, registry, address(0));
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(m),
            codeHash: address(m).codehash,
            schemaHash: m.configSchemaHash(),
            caps: HookrTypes.Caps(ADMISSION_CAP, 0, 0),
            gasLimit: ADVISORY_GAS,
            phaseMask: 3,
            feeOnly: true,
            failOpen: failOpen
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    function _cfg(uint24 cap, uint24 surcharge) internal pure returns (IHookrFeeAdvisory.Config memory c) {
        c = IHookrFeeAdvisory.Config({
            cap: cap, surcharge: surcharge, premium0: 0, premium1: 0, maxStep: 5000, minInterval: 60, maxTtl: 1 hours
        });
    }

    function _advisedMember(HookrFeeAdvisory m) internal view returns (IHookrLauncher.Member memory member) {
        member = _member(Currency.wrap(address(tokenB)));
        member.tickSpacing = spacing;
        member.config.advisory = address(m);
        member.config.advisoryGasLimit = ADVISORY_GAS;
        member.config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        member.config.advisoryFailOpen = address(m) == address(fee);
    }

    function _launchWith(IHookrLauncher.Member memory member, bytes memory data) internal returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = member;
        bytes[] memory configs = new bytes[](1);
        configs[0] = data;
        (bytes32 family,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function _launchFee(IHookrFeeAdvisory.Config memory c) internal returns (PoolKey memory) {
        return _launchWith(_advisedMember(fee), abi.encode(c));
    }

    function _lpFee(PoolKey memory key, bool buy) internal returns (uint256) {
        return quoter.quote(_swap(key, buy, true, 1e18), trader).lpFeePips;
    }

    function _trade(PoolKey memory key, bool buy, uint128 amount) internal returns (uint256 lpFee) {
        IHookrRouter.Swap memory p = _swap(key, buy, true, amount);
        lpFee = quoter.quote(p, trader).lpFeePips;
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
    }

    /// @dev The advisory's bind refuses with InvalidConfig, which the root carries in ModuleCallReverted.
    function _expectBindRefused() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector,
                address(fee),
                IHookrAdvisory.bind.selector,
                abi.encodeWithSelector(IHookrFeeAdvisory.InvalidConfig.selector)
            )
        );
    }

    /// @dev The Rules' bind refuses with InvalidConfig, which the root carries in ModuleCallReverted.
    function _expectRulesBindRefused() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector,
                address(rules),
                IHookrAdvisory.bind.selector,
                abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector)
            )
        );
    }

    function _reprice(PoolKey memory key, uint24 target, uint24 p0, uint24 p1, uint32 ttl) internal {
        vm.prank(keeper);
        fee.reprice(key.toId(), target, p0, p1, ttl);
    }

    // ------------------------------------------------------------ bind + default

    function testDefaultSurchargeAppliesThroughRoot() public {
        PoolKey memory key = _launchFee(_cfg(20_000, 1000));
        assertEq(_lpFee(key, true), BUY_NATIVE + 1000);
        assertEq(_lpFee(key, false), SELL_NATIVE + 1000);
        _trade(key, true, 1e20);
        _trade(key, false, 1e20);
        assertTrue(rules.accountingInvariant(Currency.wrap(address(tokenB))));
    }

    function testNativeConstantsMatchPlainPool() public {
        (, PoolKey memory key,,) = _launch(true, false);
        assertEq(_lpFee(key, true), BUY_NATIVE);
        assertEq(_lpFee(key, false), SELL_NATIVE);
    }

    function testBindRecordsBounds() public {
        IHookrFeeAdvisory.Config memory c = _cfg(20_000, 1000);
        c.premium0 = 700;
        c.premium1 = 300;
        PoolKey memory key = _launchFee(c);
        IHookrFeeAdvisory.Bounds memory b = fee.poolBounds(key.toId());
        assertEq(b.cap, 20_000);
        assertEq(b.maxStep, 5000);
        assertEq(b.minInterval, 60);
        assertEq(b.maxTtl, 1 hours);
        assertTrue(b.bound);
        IHookrFeeAdvisory.State memory s = fee.poolState(key.toId());
        assertEq(s.default0, 1700);
        assertEq(s.default1, 1300);
        assertEq(s.guardEnd, 0);
        assertEq(s.expiry, 0);
    }

    /// The bind sizes the pool's room from its frozen Rules configuration, read through IHookrRulesConfig, which
    /// HookrRules implements with the selector and answer of its own `config`.
    function testBindReadsTheRulesConfigThroughIHookrRulesConfig() public {
        assertEq(IHookrRulesConfig.config.selector, rules.config.selector);
        assertEq(IHookrRulesConfig.config.selector, bytes4(keccak256("config(bytes32)")));
        bool aFirst = address(tokenA) < address(tokenB);
        PoolKey memory predicted = PoolKey(
            Currency.wrap(aFirst ? address(tokenA) : address(tokenB)),
            Currency.wrap(aFirst ? address(tokenB) : address(tokenA)),
            0x800000,
            spacing,
            IHooks(address(root))
        );
        vm.expectCall(address(rules), abi.encodeCall(IHookrRulesConfig.config, (predicted.toId())));
        PoolKey memory key = _launchFee(_cfg(20_000, 1000));
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(predicted.toId()));
        HookrTypes.RulesConfig memory viaInterface = IHookrRulesConfig(address(rules)).config(key.toId());
        assertEq(keccak256(abi.encode(viaInterface)), keccak256(abi.encode(rules.config(key.toId()))));
        assertEq(viaInterface.lpBps, 200, "the fixture's frozen rules");
    }

    // --------------------------------------------------------------- repricing

    function testRepriceUpAndDownBetweenFloorAndCap() public {
        PoolKey memory key = _launchFee(_cfg(20_000, 0));
        assertEq(_lpFee(key, true), BUY_NATIVE);
        for (uint24 t = 5000; t <= 20_000; t += 5000) {
            vm.warp(vm.getBlockTimestamp() + 60);
            _reprice(key, t, 0, 0, 1 hours);
            assertEq(_lpFee(key, true), BUY_NATIVE + t);
            assertEq(_lpFee(key, false), SELL_NATIVE + t);
            _trade(key, true, 1e19);
        }
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.AboveCap.selector, 20_001, 20_000));
        fee.reprice(key.toId(), 20_001, 0, 0, 1 hours);
        for (uint24 t = 15_000;; t -= 5000) {
            _reprice(key, t, 0, 0, 1 hours);
            assertEq(_lpFee(key, true), BUY_NATIVE + t);
            _trade(key, false, 1e19);
            vm.warp(vm.getBlockTimestamp() + 60);
            if (t == 0) break;
        }
        // Surcharge zero: the pool charges its floor, the frozen base plus native Rules only.
        assertEq(_lpFee(key, false), BASE);
    }

    function testTargetExpiresBackToDefault() public {
        PoolKey memory key = _launchFee(_cfg(20_000, 2000));
        _reprice(key, 7000, 0, 0, 1 hours);
        uint256 expiry = vm.getBlockTimestamp() + 1 hours;
        assertEq(fee.poolState(key.toId()).expiry, expiry);
        vm.warp(expiry - 1);
        assertEq(_lpFee(key, true), BUY_NATIVE + 7000);
        vm.warp(expiry);
        assertEq(_lpFee(key, true), BUY_NATIVE + 2000);
        assertEq(fee.surcharge(key.toId(), true), 2000);
        // After expiry the step is measured from the default again.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.StepTooLarge.selector, 2000, 7001, 5000));
        fee.reprice(key.toId(), 7001, 0, 0, 1 hours);
    }

    function testDirectionPremium() public {
        IHookrFeeAdvisory.Config memory c = _cfg(20_000, 1000);
        c.premium0 = 2000;
        PoolKey memory key = _launchFee(c);
        bool buyIs0 = Currency.unwrap(key.currency0) == address(tokenB);
        // Default premium follows zeroForOne.
        assertEq(_lpFee(key, true), BUY_NATIVE + 1000 + (buyIs0 ? 2000 : 0));
        assertEq(_lpFee(key, false), SELL_NATIVE + 1000 + (buyIs0 ? 0 : 2000));
        _reprice(key, 4000, 3000, 500, 1 hours);
        assertEq(fee.surcharge(key.toId(), true), 7000);
        assertEq(fee.surcharge(key.toId(), false), 4500);
        assertEq(_lpFee(key, true), BUY_NATIVE + (buyIs0 ? 7000 : 4500));
        assertEq(_lpFee(key, false), SELL_NATIVE + (buyIs0 ? 4500 : 7000));
        _trade(key, true, 1e19);
        _trade(key, false, 1e19);
        // A premium cannot carry a direction over the cap.
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.AboveCap.selector, 20_001, 20_000));
        fee.reprice(key.toId(), 16_000, 4001, 0, 1 hours);
    }

    // ------------------------------------------------------------ keeper limits

    function testKeeperLimits() public {
        PoolKey memory key = _launchFee(_cfg(20_000, 0));
        PoolId id = key.toId();
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.NotKeeper.selector, address(this)));
        fee.reprice(id, 1000, 0, 0, 1 hours);
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.InvalidTtl.selector, 0));
        fee.reprice(id, 1000, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.InvalidTtl.selector, 1 hours + 1));
        fee.reprice(id, 1000, 0, 0, 1 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.StepTooLarge.selector, 0, 5001, 5000));
        fee.reprice(id, 5001, 0, 0, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.StepTooLarge.selector, 0, 5001, 5000));
        fee.reprice(id, 0, 0, 5001, 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrFeeAdvisory.UnknownPool.selector, PoolId.wrap(bytes32(uint256(1))))
        );
        fee.reprice(PoolId.wrap(bytes32(uint256(1))), 1000, 0, 0, 1 hours);
        fee.reprice(id, 5000, 0, 0, 1 hours);
        uint256 ready = vm.getBlockTimestamp() + 60;
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.TooSoon.selector, ready));
        fee.reprice(id, 5000, 0, 0, 1 hours);
        vm.warp(ready - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.TooSoon.selector, ready));
        fee.reprice(id, 5000, 0, 0, 1 hours);
        vm.warp(ready);
        fee.reprice(id, 10_000, 0, 0, 1 hours);
        vm.stopPrank();
        assertEq(fee.surcharge(id, true), 10_000);
    }

    /// NM-03: a removal voids a readmission of the same keeper queued before it, and nothing else.
    function testRemoveKeeperVoidsItsQueuedReadmission() public {
        fee.queue(fee.ADD_KEEPER(), abi.encode(keeper));
        fee.queue(fee.ADD_KEEPER(), abi.encode(keeper2));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        fee.removeKeeper(keeper);
        vm.expectPartialRevert(IHookrGoverned.NotReady.selector);
        fee.addKeeper(keeper);
        assertFalse(fee.isKeeper(keeper));
        fee.addKeeper(keeper2);
        assertTrue(fee.isKeeper(keeper2));
        // A readmission queued after the removal waits a full delay.
        fee.queue(fee.ADD_KEEPER(), abi.encode(keeper));
        vm.expectPartialRevert(IHookrGoverned.NotReady.selector);
        fee.addKeeper(keeper);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        fee.addKeeper(keeper);
        assertTrue(fee.isKeeper(keeper));
    }

    function testKeeperAddIsTimelockedAndRemovalIsInstant() public {
        PoolKey memory key = _launchFee(_cfg(20_000, 0));
        PoolId id = key.toId();
        bytes32 op = fee.operationHash(fee.ADD_KEEPER(), abi.encode(keeper2));
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, 0));
        fee.addKeeper(keeper2);
        fee.queue(fee.ADD_KEEPER(), abi.encode(keeper2));
        uint48 ready = uint48(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, ready));
        fee.addKeeper(keeper2);
        vm.prank(keeper2);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.NotKeeper.selector, keeper2));
        fee.reprice(id, 1000, 0, 0, 1 hours);
        vm.warp(ready);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, keeper));
        fee.addKeeper(keeper2);
        fee.addKeeper(keeper2);
        assertTrue(fee.isKeeper(keeper2));
        vm.prank(keeper2);
        fee.reprice(id, 1000, 0, 0, 1 hours);
        // Removal is immediate and needs no queue.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, keeper));
        fee.removeKeeper(keeper2);
        fee.removeKeeper(keeper2);
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.prank(keeper2);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.NotKeeper.selector, keeper2));
        fee.reprice(id, 2000, 0, 0, 1 hours);
        vm.prank(keeper);
        fee.resign();
        assertFalse(fee.isKeeper(keeper));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.NotKeeper.selector, keeper));
        fee.reprice(id, 2000, 0, 0, 1 hours);
        // The removed keeper's target lapses at its own expiry.
        assertEq(fee.surcharge(id, true), 1000);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(fee.surcharge(id, true), 0);
    }

    /// A hostile keeper cannot move either direction outside [0, cap], faster than maxStep per minInterval,
    /// or make a swap revert.
    function testFuzzHostileKeeperStaysInBounds(uint256 seed) public {
        IHookrFeeAdvisory.Config memory c = _cfg(20_000, 3000);
        c.premium1 = 1000;
        PoolKey memory key = _launchFee(c);
        PoolId id = key.toId();
        for (uint256 i; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint24 target = uint24(seed % 40_000);
            uint24 p0 = uint24((seed >> 32) % 25_000);
            uint24 p1 = uint24((seed >> 64) % 25_000);
            uint32 ttl = uint32((seed >> 96) % (2 hours));
            vm.warp(vm.getBlockTimestamp() + (seed >> 128) % 120);
            uint256 before0 = fee.surcharge(id, true);
            uint256 before1 = fee.surcharge(id, false);
            uint256 last = fee.poolState(id).updatedAt;
            vm.prank(keeper);
            try fee.reprice(id, target, p0, p1, ttl) {
                assertLe(uint256(target) + p0, 20_000);
                assertLe(uint256(target) + p1, 20_000);
                assertGt(ttl, 0);
                assertLe(ttl, 1 hours);
                assertTrue(last == 0 || vm.getBlockTimestamp() >= last + 60);
                assertLe(_diff(fee.surcharge(id, true), before0), 5000);
                assertLe(_diff(fee.surcharge(id, false), before1), 5000);
            } catch {}
            assertLe(fee.surcharge(id, true), 20_000);
            assertLe(fee.surcharge(id, false), 20_000);
            assertLe(_trade(key, (seed & 1) == 0, 1e18), 600_000);
        }
    }

    function _diff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    // ------------------------------------------------------ fail-open / closed

    function testBrokenFailOpenAdvisoryChargesCeiling() public {
        PoolKey memory key = _launchFee(_cfg(20_000, 1000));
        vm.mockCallRevert(address(fee), abi.encodeWithSelector(IHookrAdvisory.beforeSwap.selector), bytes(""));
        // The root charges min(admission cap, pool room) when a fail-open advisory fails outright.
        assertEq(_lpFee(key, true), BUY_NATIVE + ADMISSION_CAP);
        assertEq(_trade(key, true, 1e19), BUY_NATIVE + ADMISSION_CAP);
        vm.clearMockedCalls();
        assertEq(_lpFee(key, true), BUY_NATIVE + 1000);
    }

    function testBrokenFailClosedAdvisoryRevertsSwap() public {
        PoolKey memory key = _launchWith(_advisedMember(closedFee), abi.encode(_cfg(20_000, 1000)));
        assertEq(_lpFee(key, true), BUY_NATIVE + 1000);
        vm.mockCallRevert(address(closedFee), abi.encodeWithSelector(IHookrAdvisory.beforeSwap.selector), bytes(""));
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e18);
        vm.prank(trader);
        vm.expectRevert();
        router.swap(p, address(0), new uint256[](0));
    }

    // ------------------------------------------------- composition with Rules

    /// Pool cap = Rules worst case + advisory cap. With the dynamic fee pumped in one parent block and the keeper at the
    /// cap, every swap still clears the aggregate cap.
    function testDynamicFeeSaturatedWithSurchargeAtCapNeverReverts() public {
        IHookrLauncher.Member memory m = _advisedMember(fee);
        m.rules.maxFeePips = 100_000;
        // The most sensitive pool the reach bound admits at a 10% span.
        m.rules.dynamicFeeSens = 8;
        // Worst native fee: max(base + LP Rewards + span - share of span, maxFeePips) = max(90,000, 100,000). The
        // Root reserves the 50,000 admission maximum beside it, so the pool cap is 150,000.
        m.config.caps.maxLpFeePips = 150_000;
        IHookrFeeAdvisory.Config memory c = _cfg(20_000, 20_000);
        c.maxStep = 20_000;
        PoolKey memory key = _launchWith(m, abi.encode(c));
        uint256 highest;
        for (uint256 i; i < 8; ++i) {
            uint256 lp = _trade(key, true, 3e22);
            assertLe(lp, 120_000);
            if (lp > highest) highest = lp;
        }
        for (uint256 i; i < 8; ++i) {
            IHookrRouter.Swap memory p = _swap(key, false, false, 2e22);
            uint256 lp = quoter.quote(p, trader).lpFeePips;
            vm.prank(trader);
            router.swap(p, address(0), new uint256[](0));
            assertLe(lp, 120_000);
            if (lp > highest) highest = lp;
        }
        // Pumped buys reach the 90,000 native buy ceiling and still carry the full 20,000 surcharge.
        assertEq(highest, 110_000);
    }

    /// Any Rules configuration the advisory accepts at its cap leaves every pumped swap inside the pool cap.
    /// forge-config: default.fuzz.runs = 64
    function testFuzzBoundRoomHoldsUnderPumping(
        uint24 maxFee,
        uint24 snipe,
        uint16 share,
        uint16 lp,
        uint16 royaltyBps,
        uint24 poolCap,
        uint24 cap,
        bool guarded
    ) public {
        IHookrLauncher.Member memory m = _advisedMember(closedFee);
        m.rules.maxFeePips = uint24(bound(maxFee, BASE, 300_000));
        m.rules.dynamicFeeSens = m.rules.maxFeePips == BASE ? 0 : 10;
        m.rules.protocolShareBps = uint16(bound(share, 0, 5000));
        m.rules.lpBps = uint16(bound(lp, 1, 900));
        m.rules.burnBps = 0;
        m.rules.royaltyBps = uint16(bound(royaltyBps, 0, 1000));
        m.rules.royaltyTo = m.rules.royaltyBps == 0 ? address(0) : royalty;
        if (guarded) {
            m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 50);
            m.rules.snipeTaxPips = uint24(bound(snipe, 1, 300_000));
        }
        m.config.caps.maxLpFeePips = uint24(bound(poolCap, m.rules.maxFeePips, 600_000));
        m.config.caps.maxQuoteTakePips = 200_000;
        IHookrFeeAdvisory.Config memory c = _cfg(uint24(bound(cap, 1, ADMISSION_CAP)), 0);
        c.surcharge = c.cap;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        bytes[] memory configs = new bytes[](1);
        configs[0] = abi.encode(c);
        try launcher.launchAdvised(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        ) returns (
            bytes32 family, address
        ) {
            PoolKey memory key = launcher.position(family, 0).key;
            for (uint256 i; i < 4; ++i) {
                assertLe(_trade(key, true, 3e22), m.config.caps.maxLpFeePips);
            }
            for (uint256 i; i < 4; ++i) {
                IHookrRouter.Swap memory p = _swap(key, false, i % 2 == 0, 2e22);
                vm.prank(trader);
                router.swap(p, address(0), new uint256[](0));
            }
        } catch {}
    }

    function testCapBeyondRulesRoomIsRefusedAtBind() public {
        IHookrLauncher.Member memory m = _advisedMember(fee);
        m.rules.maxFeePips = 100_000;
        m.rules.dynamicFeeSens = 8;
        // 120,000 leaves 20,000 beside the Rules' 100,000, less than the 50,000 admission maximum: the Root binds
        // Rules against 70,000 and Rules refuse.
        m.config.caps.maxLpFeePips = 120_000;
        _expectRulesBindRefused();
        _launchWith(m, abi.encode(_cfg(20_000, 0)));
        // With room for the admission maximum, a per-pool cap above it is refused by the advisory.
        m.config.caps.maxLpFeePips = 150_000;
        _expectBindRefused();
        _launchWith(m, abi.encode(_cfg(ADMISSION_CAP + 1, 0)));
        _launchWith(m, abi.encode(_cfg(ADMISSION_CAP, 0)));
    }

    /// RR-A1 mirror: LP Rewards at `lpBps` 4 and a 2,000 share are 320 pips, the protocol's share taken in pips and
    /// rounded up, as the Rules take them. With the pool cap exactly the Rules' 3,320 plus the admission maximum the
    /// advisory binds a cap of that maximum; with the old whole-bps share its ceiling read 3,400, its room 49,920, and
    /// it refused the bind.
    function testNativeCeilingTakesTheProtocolShareInPips() public {
        IHookrLauncher.Member memory m = _advisedMember(closedFee);
        m.rules.lpBps = 4;
        m.rules.burnBps = 0;
        m.rules.royaltyBps = 0;
        m.rules.royaltyTo = address(0);
        m.rules.protocolShareBps = 2000;
        m.config.caps.maxLpFeePips = uint24(BASE + 320 + ADMISSION_CAP - 1);
        _expectRulesBindRefused();
        _launchWith(m, abi.encode(_cfg(ADMISSION_CAP, 0)));
        m.config.caps.maxLpFeePips = uint24(BASE + 320 + ADMISSION_CAP);
        PoolKey memory key = _launchWith(m, abi.encode(_cfg(ADMISSION_CAP, 0)));
        assertEq(closedFee.poolBounds(key.toId()).cap, ADMISSION_CAP);
    }

    function testAntiSnipeGuardClampsBuysOnly() public {
        IHookrLauncher.Member memory m = _advisedMember(fee);
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 100);
        m.rules.snipeTaxPips = 50_000;
        // Guard native buy: 3000 + 14,250 + 50,000 - 12,500 = 54,750. The Root keeps the 50,000 admission maximum
        // beside it, so the guard ceiling is exactly the admission cap and a guarded buy reaches the pool cap.
        m.config.caps.maxLpFeePips = 104_750;
        IHookrFeeAdvisory.Config memory c = _cfg(ADMISSION_CAP, ADMISSION_CAP);
        PoolKey memory key = _launchWith(m, abi.encode(c));
        IHookrFeeAdvisory.State memory s = fee.poolState(key.toId());
        assertEq(s.guardCeiling, ADMISSION_CAP);
        assertEq(s.guardEnd, vm.getBlockNumber() + 100);
        assertEq(_trade(key, true, 1e18), 104_750);
        assertEq(_trade(key, false, 1e18), SELL_NATIVE + ADMISSION_CAP);
        vm.roll(vm.getBlockNumber() + 100);
        assertEq(_trade(key, true, 1e18), BUY_NATIVE + ADMISSION_CAP);
    }

    // ------------------------------------------------------------ bind refusals

    function testBindRefusesOutOfBoundConfigs() public {
        IHookrFeeAdvisory.Config[8] memory bad;
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = _cfg(20_000, 1000);
        }
        bad[0].cap = 0;
        bad[1].cap = ADMISSION_CAP + 1;
        bad[2].surcharge = 20_001;
        bad[3].premium1 = 19_001;
        bad[4].maxStep = 0;
        bad[5].minInterval = 0;
        bad[6].maxTtl = 0;
        bad[7].maxTtl = 72 hours + 1;
        for (uint256 i; i < bad.length; ++i) {
            _expectBindRefused();
            _launchFee(bad[i]);
        }
        // Non-canonical bytes are refused.
        _expectBindRefused();
        _launchWith(_advisedMember(fee), bytes.concat(abi.encode(_cfg(20_000, 1000)), bytes1(0)));
        // An AFTER_SWAP-only binding is refused.
        IHookrLauncher.Member memory m = _advisedMember(fee);
        m.config.advisoryPhases = HookrTypes.AFTER_SWAP;
        _expectBindRefused();
        _launchWith(m, abi.encode(_cfg(20_000, 1000)));
        // The 72-hour maximum binds.
        IHookrFeeAdvisory.Config memory ok = _cfg(20_000, 1000);
        ok.maxTtl = 72 hours;
        _launchFee(ok);
    }

    /// minInterval binds from 1 second to MAX_MIN_INTERVAL (1 day) and nothing outside it.
    function testBindMinIntervalBounds() public {
        assertEq(fee.MAX_MIN_INTERVAL(), 1 days);
        uint32[2] memory refused = [uint32(0), 1 days + 1];
        for (uint256 i; i < refused.length; ++i) {
            IHookrFeeAdvisory.Config memory c = _cfg(20_000, 1000);
            c.minInterval = refused[i];
            _expectBindRefused();
            _launchFee(c);
        }
        uint32[4] memory accepted = [uint32(1), 2, 1 days - 1, 1 days];
        int24[4] memory spacings = [int24(120), 200, 300, 600]; // a distinct pool per launch
        for (uint256 i; i < accepted.length; ++i) {
            spacing = spacings[i];
            IHookrFeeAdvisory.Config memory c = _cfg(20_000, 1000);
            c.minInterval = accepted[i];
            PoolKey memory key = _launchFee(c);
            assertEq(fee.poolBounds(key.toId()).minInterval, accepted[i]);
        }
    }

    /// At the 1-day maximum a keeper update waits the full day, and one second earlier is refused.
    function testMaxMinIntervalSpacesUpdates() public {
        IHookrFeeAdvisory.Config memory c = _cfg(20_000, 0);
        c.minInterval = 1 days;
        PoolKey memory key = _launchFee(c);
        PoolId id = key.toId();
        vm.startPrank(keeper);
        fee.reprice(id, 1000, 0, 0, 1 hours);
        uint256 ready = vm.getBlockTimestamp() + 1 days;
        vm.warp(ready - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.TooSoon.selector, ready));
        fee.reprice(id, 2000, 0, 0, 1 hours);
        vm.warp(ready);
        fee.reprice(id, 2000, 0, 0, 1 hours);
        vm.stopPrank();
        assertEq(fee.surcharge(id, true), 2000);
    }

    function testOnlyBindingRootCanBind() public {
        PoolKey memory key = _launchFee(_cfg(20_000, 1000));
        HookrTypes.PoolConfig memory pc = root.poolConfig(key.toId());
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.NotRoot.selector, address(this)));
        fee.bind(key, pc, abi.encode(_cfg(20_000, 1000)));
        // The registered root outside initialization is refused too.
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.NotRoot.selector, address(root)));
        fee.bind(key, pc, abi.encode(_cfg(20_000, 1000)));
    }

    // --------------------------------------------------------------------- gas

    function testGasPerSwapWithAndWithoutAdvisory() public {
        spacing = 120;
        PoolKey memory advised = _launchFee(_cfg(20_000, 1000));
        (, PoolKey memory plain,,) = _launch(address(tokenA) < address(tokenB), false);
        assertEq(Currency.unwrap(plain.currency0), Currency.unwrap(advised.currency0));
        IHookrRouter.Swap memory pp = _swap(plain, true, true, 1e18);
        IHookrRouter.Swap memory pa = _swap(advised, true, true, 1e18);
        // Warm-up swaps create the claim and balance slots both measured swaps then update.
        _trade(plain, true, 1e18);
        _trade(advised, true, 1e18);
        _cool();
        vm.prank(trader);
        uint256 g = gasleft();
        router.swap(pp, address(0), new uint256[](0));
        uint256 plainGas = g - gasleft();
        _cool();
        vm.prank(trader);
        g = gasleft();
        router.swap(pa, address(0), new uint256[](0));
        uint256 advisedGas = g - gasleft();
        console2.log("swap gas, no advisory", plainGas);
        console2.log("swap gas, fee advisory", advisedGas);
        console2.log("advisory overhead", advisedGas - plainGas);
        HookrTypes.SwapContext memory x;
        x.id = advised.toId();
        x.isBuy = true;
        x.zeroForOne = pa.zeroForOne;
        vm.cool(address(fee));
        g = gasleft();
        fee.beforeSwap(x);
        console2.log("module beforeSwap, cold", g - gasleft());
        assertLt(advisedGas - plainGas, 15_000);
    }

    function _cool() internal {
        vm.cool(address(manager));
        vm.cool(address(root));
        vm.cool(address(rules));
        vm.cool(address(router));
        vm.cool(address(tokenA));
        vm.cool(address(tokenB));
        vm.cool(address(fee));
        vm.cool(address(registry));
    }
}
