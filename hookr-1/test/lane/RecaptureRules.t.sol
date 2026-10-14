// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrRecapture} from "../../src/core/HookrRecapture.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {Actor} from "./mocks/Actors.sol";
import {RulesData} from "../utils/RulesData.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

contract ReentrantClaimer {
    HookrRules internal immutable rulesModule;
    bytes4 public nestedError;

    constructor(HookrRules _rules) {
        rulesModule = _rules;
    }

    function claim() external {
        rulesModule.claim(Currency.wrap(address(0)));
    }

    receive() external payable {
        try rulesModule.claim(Currency.wrap(address(0))) {}
        catch (bytes memory reason) {
            nestedError = bytes4(reason);
        }
    }
}

/// @notice HookrRules' recapture split and King of the Pool (HookrRecapture, reached by DELEGATECALL): the creator
///         knobs and their bounds, access control, leader rules, rollover, the split with the protocol share first,
///         and the LP leg's accrual to the launch position.
contract RecaptureRulesTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ScriptedExecutor internal exec;
    PoolKey internal key;
    PoolId internal id;
    Currency internal tb;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e30);
        tokenB.transfer(address(exec), 1e27);
        exec.setRoot(address(root));
        _openLane(address(exec));
        tb = Currency.wrap(address(tokenB));
        key = _openKoth(ETH);
        id = key.toId();
    }

    /// @dev Launching a pool with these rules and recapture config reverts with the Rules' bind refusal `reason`,
    ///      which the root carries in ModuleCallReverted.
    function _bindReverts(HookrTypes.RulesConfig memory r, HookrTypes.RecaptureConfig memory rc, bytes memory reason)
        internal
    {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(tb, r, rc);
        HookrToken s = _newSubject();
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector, address(rules), IHookrRules.bind.selector, reason
            )
        );
        vm.prank(creator);
        launcher.launch(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    /// @dev The same, refused with InvalidConfig.
    function _bindReverts(HookrTypes.RulesConfig memory r, HookrTypes.RecaptureConfig memory rc) internal {
        _bindReverts(r, rc, abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector));
    }

    function _bindReverts(HookrTypes.RecaptureConfig memory rc) internal {
        _bindReverts(_laneRules(true), rc);
    }

    function _prizeAboveBound(uint256 maxPrizeBps, uint256 bound) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHookrRecaptureEvents.PrizeAboveBound.selector, maxPrizeBps, bound);
    }

    // ---------------------------------------------------------------- creator knobs: bounds and defaults

    function test_knobs_boundsAndDefaultsAreServedByTheRules() public view {
        IHookrRecaptureRules r = _recap();
        assertEq(r.MIN_TRADER_BPS(), 0);
        assertEq(r.MAX_TRADER_BPS(), 5_000);
        assertEq(r.DEFAULT_TRADER_BPS(), 2_500);
        assertEq(r.DEFAULT_LP_BPS(), 7_500);
        assertEq(r.MAX_POT_BPS(), 5_000);
        assertEq(r.DEFAULT_POT_BPS(), 2_500);
        assertEq(r.MIN_PERIOD(), 1 hours);
        assertEq(r.MAX_PERIOD(), 30 days);
        assertEq(r.DEFAULT_PERIOD(), 1 days);
        assertEq(r.MIN_POT_RELEASE_BPS(), 2_500);
        assertEq(r.MAX_POT_RELEASE_BPS(), 10_000);
        assertEq(r.DEFAULT_POT_RELEASE_BPS(), 5_000);
        assertEq(r.MIN_PRIZE_BPS(), 1);
        assertEq(r.FULL_RELEASE_EPOCHS(), 256);
        (HookrTypes.RecaptureConfig memory d, uint16 potBps) = r.recaptureDefaults();
        assertTrue(d.on, "arb recaptures on by default");
        assertEq(potBps, 0, "King of the Pool off by default");
        assertEq(d.traderBps, 2_500);
        assertEq(d.lpBps, 7_500);
        assertEq(d.period, 0);
        assertEq(d.maxPrizeBps, 0);
        assertEq(d.potReleaseBps, 0);
        assertEq(d.minBuyQuote, 0);
        // The protocol's 25% of 4% LP Rewards is one percent of every buy; half of it is the widest prize ceiling.
        assertEq(r.prizeBound(KOTH_LP_REWARDS, 0, SHARE), 50);
        assertEq(r.prizeBound(400, 400, 2000), 80);
        assertEq(r.prizeBound(0, 0, 5000), 0);
        assertEq(r.PRIZE_SHARE_OF_FEE_BPS(), 5_000);
        assertEq(r.RECAPTURE_PROTOCOL_BPS(), 2_500);
        (address module, bytes32 codeHash) = r.recaptureModule();
        assertGt(module.code.length, 0);
        assertEq(codeHash, module.codehash);
    }

    /// The defaults the wizard pre-fills launch as they are: arb recaptures on, King of the Pool off.
    function test_knobs_defaultsLaunch() public {
        (HookrTypes.RecaptureConfig memory d,) = _recap().recaptureDefaults();
        PoolKey memory k = _openPool(ETH, _laneRules(false), d);
        assertEq(_recap().recaptureMode(k.toId()), 1);
        (address executor,,,) = _laneOf(k);
        assertEq(executor, address(exec));
        (HookrTypes.RecaptureConfig memory frozen, uint16 potBps, uint16 share) = _recap().recaptureConfig(k.toId());
        assertEq(keccak256(abi.encode(frozen)), keccak256(abi.encode(d)));
        assertEq(potBps, 0);
        assertEq(share, SHARE);
    }

    function test_bind_rejectsSplitNotSummingToTheWhole() public {
        HookrTypes.RecaptureConfig memory c = _kothRc();
        c.lpBps += 1;
        _bindReverts(c);
        c.lpBps -= 2;
        _bindReverts(c);
        c = _recaptureOnlyRc();
        c.lpBps = 7_999;
        _bindReverts(_laneRules(false), c);
    }

    function test_bind_enforcesKnobBounds() public {
        HookrTypes.RecaptureConfig memory c = _recaptureOnlyRc();
        (c.traderBps, c.lpBps) = (5_001, 4_999); // trader ceiling 5,000
        _bindReverts(_laneRules(false), c);
        (c.traderBps, c.lpBps) = (5_000, 5_000);
        _openPool(tb, _laneRules(false), c);
        (c.traderBps, c.lpBps) = (0, 10_000); // no trader leg: the whole remainder to the LP accrual
        _openPool(tb, _laneRules(false), c);
        HookrTypes.RulesConfig memory r = _laneRules(true);
        c = _kothRc();
        (r.potBps, c.lpBps) = (5_001, 2_999); // pot ceiling 5,000
        _bindReverts(r, c);
        (r.potBps, c.lpBps) = (5_000, 3_000);
        _openPool(tb, r, c);
    }

    function test_bind_kothFieldBounds() public {
        HookrTypes.RecaptureConfig memory c = _kothRc();
        c.period = 1 hours - 1;
        _bindReverts(c);
        c.period = 30 days + 1;
        _bindReverts(c);
        c = _kothRc();
        c.maxPrizeBps = 0;
        _bindReverts(c);
        c.maxPrizeBps = 51; // above half the protocol's 1% of each buy
        _bindReverts(_laneRules(true), c, _prizeAboveBound(51, 50));
        c = _kothRc();
        c.minBuyQuote = 0;
        _bindReverts(c);
        c = _kothRc();
        c.period = 1 hours;
        _openPool(tb, _laneRules(true), c);
        c.period = 30 days;
        _openPool(tb, _laneRules(true), c);
    }

    /// REVIEW M-1 fix, tightened for the in-band wash: a prize ceiling above half the protocol's share of the pool's
    /// LP Rewards and Auto Burn cannot bind, so a pool whose rules take nothing for the protocol on a buy cannot turn
    /// King of the Pool on at all.
    function test_bind_prizeCeilingIsCoveredByTheProtocolFee() public {
        HookrTypes.RulesConfig memory r = _laneRules(true);
        HookrTypes.RecaptureConfig memory c = _kothRc();
        r.lpBps = 399; // 399 * 25% = 99 bps, half of it 49
        _bindReverts(r, c, _prizeAboveBound(50, 49));
        c.maxPrizeBps = 49;
        _openPool(tb, r, c);
        // No LP Rewards and no burn: nothing covers a prize.
        r.lpBps = 0;
        c.maxPrizeBps = 1;
        _bindReverts(r, c, _prizeAboveBound(1, 0));
        // Auto Burn's protocol slice covers it too: 25% of 4% burn, half of it 50.
        r.burnBps = 400;
        c.maxPrizeBps = 50;
        _openPool(tb, r, c);
        c.maxPrizeBps = 51;
        _bindReverts(r, c, _prizeAboveBound(51, 50));
        // One bps of protocol fee leaves no room for a one bps prize.
        (r.lpBps, r.burnBps) = (4, 0);
        c.maxPrizeBps = 1;
        _bindReverts(r, c, _prizeAboveBound(1, 0));
    }

    /// KOTH-R23-I1: a prize ceiling above the bound its native rules admit is refused with PrizeAboveBound
    /// (maxPrizeBps, bound). Through the root the refusal arrives inside ModuleCallReverted (the tests above); called
    /// as the root binds, the Rules revert with the typed error itself. The other King of the Pool bounds keep
    /// InvalidConfig, also on a config whose prize is above its bound too.
    function test_bind_prizeAboveBoundIsTyped() public {
        HookrTypes.RulesConfig memory r = _laneRules(true);
        HookrTypes.RecaptureConfig memory c = _kothRc();
        c.maxPrizeBps = 51;
        _bindDirectReverts(r, c, abi.encodeWithSelector(IHookrRecaptureEvents.PrizeAboveBound.selector, 51, 50));
        // No LP Rewards and no burn: nothing covers a prize, so the bound is zero.
        r.lpBps = 0;
        c.maxPrizeBps = 1;
        _bindDirectReverts(r, c, abi.encodeWithSelector(IHookrRecaptureEvents.PrizeAboveBound.selector, 1, 0));
        // Auto Burn's slice: 25% of 4% burn, half of it 50.
        r.burnBps = 400;
        c.maxPrizeBps = 51;
        _bindDirectReverts(r, c, abi.encodeWithSelector(IHookrRecaptureEvents.PrizeAboveBound.selector, 51, 50));
        r = _laneRules(true);
        c = _kothRc();
        c.period = 1 hours - 1;
        _bindDirectReverts(r, c, abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector));
        c.maxPrizeBps = 51;
        _bindDirectReverts(r, c, abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector));
        c = _kothRc();
        c.maxPrizeBps = 0;
        _bindDirectReverts(r, c, abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector));
        c.maxPrizeBps = 50;
        PoolKey memory k = _bindDirect(r, c);
        (HookrTypes.RecaptureConfig memory frozen,,) = _recap().recaptureConfig(k.toId());
        assertEq(frozen.maxPrizeBps, 50, "at the bound it binds");
    }

    /// The typed refusal partitions the King of the Pool bind as the combined check did: a config whose other King of
    /// the Pool bounds hold binds exactly when its prize is within prizeBound and is refused with PrizeAboveBound
    /// otherwise, and a config with any other bound failing is InvalidConfig whatever its prize.
    function testFuzz_bind_kothBoundsPartition(
        uint32 period,
        uint16 maxPrizeBps,
        uint16 potReleaseBps,
        uint128 minBuyQuote,
        uint16 lpBps,
        uint16 burnBps,
        uint16 share
    ) public {
        HookrTypes.RulesConfig memory r = _laneRules(true);
        r.lpBps = uint16(bound(lpBps, 1, 1_000));
        r.burnBps = uint16(bound(burnBps, 0, 1_000 - r.lpBps));
        r.protocolShareBps = uint16(bound(share, 2_000, 5_000));
        HookrTypes.RecaptureConfig memory c = _kothRc();
        c.period = uint32(bound(period, 1 hours - 10, 30 days + 10));
        c.maxPrizeBps = uint16(bound(maxPrizeBps, 0, 300));
        c.potReleaseBps = uint16(bound(potReleaseBps, 2_490, 10_010));
        c.minBuyQuote = uint128(bound(minBuyQuote, 0, 3));
        bool others = c.period >= 1 hours && c.period <= 30 days && c.maxPrizeBps >= 1 && c.potReleaseBps >= 2_500
            && c.potReleaseBps <= 10_000 && c.minBuyQuote != 0;
        uint256 ceiling = _recap().prizeBound(r.lpBps, r.burnBps, r.protocolShareBps);
        if (!others) {
            _bindDirectReverts(r, c, abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector));
        } else if (c.maxPrizeBps > ceiling) {
            _bindDirectReverts(
                r, c, abi.encodeWithSelector(IHookrRecaptureEvents.PrizeAboveBound.selector, c.maxPrizeBps, ceiling)
            );
        } else {
            _bindDirect(r, c);
        }
    }

    /// @dev Binds a native-quoted pool of a fresh subject on the Rules as the root does during initialization.
    function _bindDirect(HookrTypes.RulesConfig memory r, HookrTypes.RecaptureConfig memory c)
        internal
        returns (PoolKey memory k)
    {
        HookrTypes.PoolConfig memory pc;
        (k, pc) = _directPool();
        vm.mockCall(address(root), abi.encodeWithSignature("bindingPool()"), abi.encode(k.toId()));
        vm.prank(address(root));
        rules.bind(k, pc, RulesData.lane(r, 0, c));
        vm.clearMockedCalls();
    }

    function _bindDirectReverts(HookrTypes.RulesConfig memory r, HookrTypes.RecaptureConfig memory c, bytes memory err)
        internal
    {
        (PoolKey memory k, HookrTypes.PoolConfig memory pc) = _directPool();
        vm.mockCall(address(root), abi.encodeWithSignature("bindingPool()"), abi.encode(k.toId()));
        vm.prank(address(root));
        vm.expectRevert(err);
        rules.bind(k, pc, RulesData.lane(r, 0, c));
        vm.clearMockedCalls();
    }

    function _directPool() internal returns (PoolKey memory k, HookrTypes.PoolConfig memory pc) {
        HookrToken s = _newSubject();
        k = PoolKey(ETH, Currency.wrap(address(s)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
        pc = _laneMember(ETH, _laneRules(true), _kothRc()).config;
        (pc.subject, pc.quote, pc.liquidityOwner) = (Currency.wrap(address(s)), ETH, address(this));
    }

    /// potReleaseBps binds from 2,500 to 10,000 on a King of the Pool pool and nowhere else.
    function test_bind_potReleaseBounds() public {
        HookrTypes.RecaptureConfig memory c = _kothRc();
        uint16[4] memory refused = [uint16(0), 2_499, 10_001, type(uint16).max];
        for (uint256 i; i < refused.length; ++i) {
            c.potReleaseBps = refused[i];
            _bindReverts(c);
        }
        uint16[4] memory accepted = [uint16(2_500), 2_501, 9_999, 10_000];
        for (uint256 i; i < accepted.length; ++i) {
            c.potReleaseBps = accepted[i];
            PoolKey memory k = _openPool(tb, _laneRules(true), c);
            (HookrTypes.RecaptureConfig memory frozen,,) = _recap().recaptureConfig(k.toId());
            assertEq(frozen.potReleaseBps, accepted[i]);
        }
    }

    function test_bind_toggleOffMustZeroKothFields() public {
        HookrTypes.RulesConfig memory r = _laneRules(false);
        HookrTypes.RecaptureConfig memory c = _recaptureOnlyRc();
        c.period = PERIOD;
        _bindReverts(r, c);
        c = _recaptureOnlyRc();
        c.minBuyQuote = 1;
        _bindReverts(r, c);
        c = _recaptureOnlyRc();
        c.maxPrizeBps = 1;
        _bindReverts(r, c);
        c = _recaptureOnlyRc();
        c.potReleaseBps = 5_000;
        _bindReverts(r, c);
    }

    /// Without recapture the pool has no lane and never calls an executor; a pot share needs recapture.
    function test_bind_recaptureOffOpensPoolWithoutLane() public {
        HookrTypes.RecaptureConfig memory off;
        PoolKey memory k = _openPool(tb, _laneRules(false), off);
        (address executor,,,) = _laneOf(k);
        assertEq(executor, address(0));
        assertEq(_recap().recaptureMode(k.toId()), 0);
        exec.set(ScriptedExecutor.Mode.REVERT, 0);
        _buy(k, tb, whale, 1e21);
        assertEq(exec.calls(), 0, "no lane call on a pool without the lane");
        HookrTypes.RulesConfig memory r = _laneRules(true);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(tb, r, off);
        HookrToken s = _newSubject();
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector,
                address(rules),
                IHookrRules.bind.selector,
                abi.encodeWithSelector(IHookrRulesState.PotUnavailable.selector, r.potBps)
            )
        );
        vm.prank(creator);
        launcher.launch(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    /// A recapture launch needs an open lane on the root: a closed one refuses it, whatever the knobs.
    function test_bind_recaptureRequiresALane() public {
        registry.closeLaneOf(address(root));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(ETH, _laneRules(true), _kothRc());
        HookrToken s = _newSubject();
        vm.expectRevert(IHookrRootEvents.InvalidConfig.selector);
        vm.prank(creator);
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    /// Only canonical Rules data binds: an appended word, a non-bool toggle, recapture data with the toggle off, and a
    /// pot share on a pool without recapture are refused. The test contract is an admitted launcher here.
    function test_bind_rejectsNonCanonicalData() public {
        registry.queue(registry.SET_LAUNCHER(), abi.encode(address(this), true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setLauncher(address(this), true);
        HookrToken s = _newSubject();
        PoolKey memory k =
            PoolKey(ETH, Currency.wrap(address(s)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
        HookrTypes.PoolConfig memory pc = _laneMember(ETH, _laneRules(true), _kothRc()).config;
        pc.subject = Currency.wrap(address(s));
        pc.quote = ETH;
        pc.liquidityOwner = address(this);
        bytes memory good = RulesData.lane(_laneRules(true), 0, _kothRc());
        bytes memory bindFailed = abi.encodeWithSelector(
            IHookrRootEvents.ModuleCallReverted.selector,
            address(rules),
            IHookrRules.bind.selector,
            abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector)
        );
        vm.expectRevert(bindFailed);
        root.initializePool(k, pc, abi.encodePacked(good, uint256(0)), "", SQRT_ONE);
        bytes memory bad = RulesData.lane(_laneRules(true), 0, _kothRc());
        assembly ("memory-safe") {
            mstore(add(bad, add(32, sub(mload(bad), 256))), 2) // RecaptureConfig.on (last 8 words) = 2: not a bool
        }
        // The ABI decoder refuses a non-bool word without revert data, so the root reports the reasonless error.
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallFailed.selector, address(rules), IHookrRules.bind.selector
            )
        );
        root.initializePool(k, pc, bad, "", SQRT_ONE);
        HookrTypes.RecaptureConfig memory off = _kothRc();
        off.on = false;
        vm.expectRevert(bindFailed);
        root.initializePool(k, pc, RulesData.lane(_laneRules(true), 0, off), "", SQRT_ONE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector,
                address(rules),
                IHookrRules.bind.selector,
                abi.encodeWithSelector(IHookrRulesState.PotUnavailable.selector, _laneRules(true).potBps)
            )
        );
        root.initializePool(k, pc, abi.encode(_laneRules(true)), "", SQRT_ONE);
        // The canonical data opens.
        root.initializePool(k, pc, good, "", SQRT_ONE);
        assertEq(_recap().recaptureMode(k.toId()), 2);
    }

    // ---------------------------------------------------------------- access control

    function test_access_onlyTheRootSettles_onlyTheLiquidityOwnerClaims_andTheModuleOnlyByDelegation() public {
        vm.startPrank(attacker);
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        _recap().settleRecapture(key, ETH, attacker, 1e18, 1e18, 1e18);
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        _recap().claimPool(id, attacker);
        vm.stopPrank();
        PoolKey memory unbound = PoolKey(ETH, Currency.wrap(address(0xdead)), key.fee, key.tickSpacing, key.hooks);
        vm.prank(address(root));
        vm.expectRevert(IHookrRulesEvents.UnknownPool.selector);
        _recap().settleRecapture(unbound, ETH, attacker, 1, 1, 1);
        vm.prank(address(root));
        vm.expectRevert(IHookrRulesEvents.UnknownPool.selector);
        _recap().flushRecapture(unbound);
        vm.startPrank(attacker);
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        _recap().flushRecapture(key);
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        _recap().creditSweep(ETH, 1);
        vm.stopPrank();
        vm.prank(address(root));
        vm.expectRevert(IHookrRulesEvents.InvalidSettlement.selector);
        _recap().settleRecapture(key, ETH, attacker, 0, 0, 0);
        // The launcher is the liquidity owner, but not to the Rules themselves.
        vm.prank(address(launcher));
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        _recap().claimPool(id, address(rules));
        (address module,) = _recap().recaptureModule();
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        HookrRecapture(module).settleEpoch(id);
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        HookrRecapture(module).claimPool(id, attacker);
        HookrTypes.SwapContext memory x;
        HookrTypes.Settlement memory z;
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        HookrRecapture(module).settleSwap(x, z);
    }

    function test_settleEpoch_refusals() public {
        vm.expectRevert(IHookrRecaptureEvents.EpochOpen.selector);
        _recap().settleEpoch(id);
        vm.expectRevert(IHookrRulesEvents.UnknownPool.selector);
        _recap().settleEpoch(PoolId.wrap(bytes32(uint256(7))));
        PoolKey memory k = _openRecapture(tb);
        vm.expectRevert(IHookrRecaptureEvents.NotKoth.selector);
        _recap().settleEpoch(k.toId());
    }

    /// @dev The whale leads with a 2e18 buy on the King of the Pool pool the scripted pushes fill, and the closed
    ///      epoch pays it the prize: a claim in the Rules.
    function _prizeClaim(address who) internal {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        IHookrRouter.Swap memory p = _swapParams(key, ETH, true, true, 2e18, who);
        vm.deal(who, who.balance + 2e18);
        vm.prank(who);
        router.swap{value: 2e18}(p, address(0), new uint256[](0));
        (uint64 start,,,) = _hill(key);
        vm.warp(uint256(start) + PERIOD);
        _recap().settleEpoch(id);
    }

    function test_claim_refusals() public {
        vm.prank(attacker);
        vm.expectRevert(IHookrRulesState.NothingToClaim.selector);
        rules.claim(ETH);
        _prizeClaim(whale);
        vm.startPrank(whale);
        vm.expectRevert(IHookrRulesEvents.InvalidConfig.selector);
        rules.claimTo(ETH, address(0));
        vm.expectRevert(IHookrRulesEvents.InvalidConfig.selector);
        rules.claimTo(ETH, address(manager));
        vm.expectRevert(IHookrRulesEvents.InvalidConfig.selector);
        rules.claimTo(ETH, address(rules));
        uint256 owed = rules.claimable(ETH, whale);
        assertGt(owed, 0);
        uint256 before = minnow.balance;
        rules.claimTo(ETH, minnow);
        vm.stopPrank();
        assertEq(minnow.balance - before, owed);
        assertEq(rules.claimable(ETH, whale), 0);
    }

    function test_claim_reentrancyRefused() public {
        ReentrantClaimer c = new ReentrantClaimer(rules);
        _prizeClaim(address(c));
        uint256 owed = rules.claimable(ETH, address(c));
        assertGt(owed, 0);
        c.claim();
        assertEq(c.nestedError(), IHookrRulesState.ReentrantClaim.selector);
        assertEq(rules.claimable(ETH, address(c)), 0);
        assertTrue(rules.accountingInvariant(ETH));
    }

    // ---------------------------------------------------------------- leader rules

    function test_leader_unauthenticatedCannotLead() public {
        Actor a = _newActor(key);
        a.directSwap(key, true, -5e21, MIN_PRICE);
        (, address leader,,) = _hill(key);
        assertEq(leader, address(0));
    }

    function test_leader_belowMinimumCannotLead() public {
        _buy(key, ETH, whale, MIN_BUY - 1);
        (, address leader,,) = _hill(key);
        assertEq(leader, address(0));
        _buy(key, ETH, whale, MIN_BUY);
        (, leader,,) = _hill(key);
        assertEq(leader, whale);
    }

    function test_leader_exactOutputBuyCountsGrossSpend() public {
        IHookrRouter.Swap memory p = _swapParams(key, ETH, true, false, 3e21, whale);
        p.amountBound = 1e22;
        vm.prank(whale);
        (uint256 amountIn,) = router.swap{value: 1e22}(p, address(0), new uint256[](0));
        (, address leader, uint128 amount,) = _hill(key);
        assertEq(leader, whale);
        assertEq(amount, amountIn, "gross quote spend of the exact-output buy");
    }

    function test_leader_sellInSameTransactionVoidsCrown() public {
        _buy(key, ETH, minnow, 2e21);
        Actor a = _newActor(key);
        IHookrRouter.Swap memory b = _swapParams(key, ETH, true, true, 5e22, address(a));
        IHookrRouter.Swap memory s = _swapParams(key, ETH, false, true, 1e18, address(a));
        vm.expectEmit(true, true, true, true, address(rules));
        emit IHookrRecaptureEvents.CrownVoided(id, address(a), minnow, uint64(vm.getBlockTimestamp()));
        a.routerPair(b, 5e22, s, 0);
        (, address leader, uint128 amount,) = _hill(key);
        assertEq(leader, minnow, "the transaction-start leader is restored");
        assertEq(amount, 2e21);
    }

    function test_leader_buyAfterSellInSameTransactionCannotLead() public {
        Actor a = _newActor(key);
        IHookrRouter.Swap memory s = _swapParams(key, ETH, false, true, 1e18, address(a));
        IHookrRouter.Swap memory b = _swapParams(key, ETH, true, true, 5e22, address(a));
        a.routerPair(s, 0, b, 5e22);
        (, address leader,,) = _hill(key);
        assertEq(leader, address(0));
    }

    function test_leader_buyInTransactionThatAddedLiquidityCannotLead() public {
        Actor a = _newActor(key);
        IHookrRouter.Swap memory b = _swapParams(key, ETH, true, true, 5e22, address(a));
        a.jitRouterSwap(b, 5e22, -600, 600, 1e24);
        (, address leader,,) = _hill(key);
        assertEq(leader, address(0));
        // The same buy in a clean transaction leads.
        a.routerSwap(b, 5e22);
        (, leader,,) = _hill(key);
        assertEq(leader, address(a));
    }

    function test_leader_sellInLaterTransactionKeepsCrown() public {
        _buy(key, ETH, whale, 5e21);
        _sell(key, ETH, whale, 1e21);
        (, address leader,,) = _hill(key);
        assertEq(leader, whale, "the two-transaction round trip is priced by the prize cap, not voided");
    }

    // ---------------------------------------------------------------- rollover

    /// An epoch without a leader carries half of the pot and releases the rest to the pool's LP accrual.
    function test_rollover_noLeaderReleasesHalfToLps() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        _newActor(key).directSwap(key, true, -1e18, MIN_PRICE); // unauthenticated: funds the pot, cannot lead
        (uint64 start,,, uint128 pot) = _hill(key);
        assertGt(pot, 0);
        uint256 lpBefore = _accrued(key);
        vm.warp(uint256(start) + PERIOD);
        vm.recordLogs();
        _recap().settleEpoch(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IHookrRecaptureEvents.KingCrowned.selector, "no king without a leader");
        }
        (uint64 next,,, uint128 carried) = _hill(key);
        assertEq(next, start + PERIOD);
        assertEq(carried, pot / 2);
        assertEq(_accrued(key) - lpBefore, pot - pot / 2, "the released half joined the LP accrual");
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// With no leader, one closed epoch carries floor(pot * (10,000 - potReleaseBps) / 10,000) at both ends of the
    /// range and releases the rest to the LP accrual; pendingPrize predicts it.
    function test_rollover_releaseAtRangeEnds() public {
        uint16[3] memory releases = [uint16(2_500), 5_000, 10_000];
        for (uint256 i; i < releases.length; ++i) {
            HookrTypes.RecaptureConfig memory c = _kothRc();
            c.potReleaseBps = releases[i];
            PoolKey memory k = _openKoth(c, ETH);
            exec.set(ScriptedExecutor.Mode.PUSH, 9e18 + i);
            _newActor(k).directSwap(k, true, -1e18, MIN_PRICE);
            (uint64 start,,, uint128 pot) = _hill(k);
            assertGt(pot, 0);
            (,, uint256 predicted) = _recap().pendingPrize(k.toId());
            uint256 lpBefore = _accrued(k);
            vm.warp(uint256(start) + PERIOD);
            _recap().settleEpoch(k.toId());
            (,,, uint128 carried) = _hill(k);
            uint256 expected = uint256(pot) * (10_000 - releases[i]) / 10_000;
            assertEq(carried, expected, "one epoch keeps 1 - potReleaseBps of the pot");
            assertEq(predicted, carried, "pendingPrize predicts the carry");
            assertEq(_accrued(k) - lpBefore, pot - carried, "the release joined the LP accrual");
            assertTrue(rules.accountingInvariant(ETH));
        }
    }

    /// At the top of the range the whole pot leaves at the first rollover, prize first.
    function test_rollover_fullReleaseEmptiesPotAfterPrize() public {
        HookrTypes.RecaptureConfig memory c = _kothRc();
        c.potReleaseBps = 10_000;
        PoolKey memory k = _openKoth(c, ETH);
        exec.set(ScriptedExecutor.Mode.PUSH, 900e18);
        _buy(k, ETH, whale, 10e18);
        (uint64 start,,, uint128 pot) = _hill(k);
        assertGt(pot, uint256(10e18) / 100, "the pot exceeds the prize");
        uint256 lpBefore = _accrued(k);
        uint256 whaleBefore = rules.claimable(ETH, whale);
        vm.warp(uint256(start) + PERIOD);
        _recap().settleEpoch(k.toId());
        (,,, uint128 carried) = _hill(k);
        assertEq(carried, 0);
        uint256 prize = uint256(10e18) * 50 / 10_000;
        assertEq(rules.claimable(ETH, whale) - whaleBefore, prize, "the prize is paid first");
        assertEq(_accrued(k) - lpBefore, pot - prize, "the rest of the pot joined the LP accrual");
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// The prize is capped at maxPrizeBps of the winning buy, at most half the protocol fee that same buy paid.
    function test_rollover_prizeCappedAtTheProtocolFeeOfTheWinningBuy() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 900e18);
        uint256 protocolBefore = rules.claimable(ETH, protocol);
        vm.recordLogs();
        _buy(key, ETH, whale, 10e18);
        Splits memory t = _splits(vm.getRecordedLogs());
        uint256 feeProtocol = rules.claimable(ETH, protocol) - protocolBefore - t.protocol;
        (uint64 start,, uint128 amount, uint128 pot) = _hill(key);
        uint256 cap = uint256(amount) * 50 / 10_000; // 0.5% of the winning buy
        assertGt(pot, cap, "pot exceeds the cap");
        assertEq(feeProtocol, 2 * cap, "the protocol took twice the prize ceiling from the buy itself");
        uint256 before = rules.claimable(ETH, whale);
        vm.warp(uint256(start) + PERIOD);
        _recap().settleEpoch(id);
        assertEq(rules.claimable(ETH, whale) - before, cap);
        (,,, uint128 carried) = _hill(key);
        assertEq(carried, (pot - cap) / 2);
    }

    function test_rollover_inflowAfterCloseBelongsToNextEpoch() public {
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        _buy(key, ETH, whale, 10e18);
        (uint64 start,,,) = _hill(key);
        vm.warp(uint256(start) + PERIOD);
        exec.set(ScriptedExecutor.Mode.PUSH, 900e18);
        vm.recordLogs();
        _buy(key, ETH, minnow, 2e18);
        Splits memory t = _splits(vm.getRecordedLogs());
        // The rollover ran in the before-phase's split, ahead of both pushes: the whale's pot was empty.
        assertEq(rules.claimable(ETH, whale), 0);
        (, address leader,, uint128 pot) = _hill(key);
        assertEq(leader, minnow);
        assertEq(pot, t.pot);
        (,, uint256 potLeg,) = _split(900e18, false, POT_BPS, TRADER_BPS);
        assertEq(pot, 2 * potLeg);
    }

    function test_rollover_pendingPrizeView() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        _buy(key, ETH, whale, 100e18);
        (address leader, uint256 prize, uint256 carried) = _recap().pendingPrize(id);
        (,,, uint128 pot) = _hill(key);
        assertEq(leader, whale);
        assertEq(carried, (pot - prize) / 2);
        assertEq(prize, pot < 5e17 ? pot : 5e17);
    }

    // ---------------------------------------------------------------- the split

    /// Protocol share first, then pot and LP; the after-phase names the payer, but a push that undid nothing of its
    /// move (the scripted executor legs nowhere) credits it nothing, and its trader share joins the LP leg. The legs
    /// sum to the push.
    function test_split_protocolFirstThenTraderPotAndLp() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        uint256 lpBefore = _accrued(key);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        Splits memory t = _splits(vm.getRecordedLogs());
        assertEq(t.count, 2);
        (uint256 pro0,, uint256 pot0, uint256 lp0) = _split(9e18, false, POT_BPS, TRADER_BPS);
        assertEq(t.protocol, 2 * pro0, "the pool's protocol share of each push, first");
        assertEq(t.trader, 0, "no trader leg for a push that did not undo the trader's move");
        assertEq(t.lastTrader, whale, "the after-phase names the payer");
        assertEq(t.pot, 2 * pot0);
        assertEq(t.lp, 2 * lp0, "the LP leg with the trader share");
        assertEq(t.trader + t.pot + t.lp + t.protocol, 18e18);
        assertEq(rules.claimable(ETH, whale), 0);
        assertEq(_accrued(key) - lpBefore, t.lp);
        (,,, uint128 potNow) = _hill(key);
        assertEq(potNow, t.pot);
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// The protocol's cut of a push is 25% of the profit it stands for on every pool: a pool's protocolShareBps (its
    /// share of the rule fees, here 50%) does not reach it.
    function test_split_protocolCutIgnoresThePoolsProtocolShare() public {
        HookrTypes.RulesConfig memory r = _laneRules(false);
        r.protocolShareBps = 5_000;
        PoolKey memory k = _openPool(ETH, r, _recaptureOnlyRc());
        exec.set(ScriptedExecutor.Mode.PUSH, 1e18);
        vm.recordLogs();
        _buy(k, ETH, whale, 1e18);
        Splits memory t = _splits(vm.getRecordedLogs());
        uint256 pro = _cut(_profitOf(1e18), 1e18);
        assertEq(t.protocol, 2 * pro, "25% of each push's profit at a 50% rule share");
        assertEq(t.trader, 0, "a push that undid nothing of the trader's move credits it nothing");
        assertEq(t.lp, 2 * (1e18 - pro));
    }

    /// The trader leg is paid on the part of the push the trader's own swap accounts for (the root's basis): all of it
    /// when the basis covers the push, a share of it below, nothing at zero or without a named trader. The rest of
    /// the trader share joins the LP leg; the protocol and pot legs never change.
    function test_split_traderLegFollowsItsBasis() public {
        uint256 amount = 9e18;
        uint256[5] memory bases = [uint256(0), 1, 1e18, 9e18, 1e30];
        for (uint256 i; i < 2 * bases.length; ++i) {
            address trader = i < bases.length ? whale : address(0);
            uint256 basis = bases[i % bases.length];
            uint256 snap = vm.snapshotState();
            uint256 lpBefore = _accrued(key);
            (,,, uint128 potBefore) = _hill(key);
            uint256 proBefore = rules.claimable(ETH, protocol);
            vm.recordLogs();
            vm.prank(address(root));
            assertEq(_recap().settleRecapture(key, ETH, trader, amount, basis, amount), amount);
            Splits memory t = _splits(vm.getRecordedLogs());
            uint256 part = basis < amount ? basis : amount;
            (uint256 pro,, uint256 pot,) = _split(amount, amount, false, POT_BPS, TRADER_BPS);
            uint256 tr = trader == address(0) ? 0 : part * (amount - pro) / amount * TRADER_BPS / 10_000;
            assertEq(t.trader, tr, "the trader leg on min(push, basis)");
            assertEq(rules.claimable(ETH, whale), tr);
            assertEq(rules.claimable(ETH, protocol) - proBefore, pro, "the protocol leg never changes");
            (,,, uint128 potNow) = _hill(key);
            assertEq(potNow - potBefore, pot, "nor the pot leg");
            assertEq(_accrued(key) - lpBefore, amount - pro - pot - tr, "the LP leg takes the rest");
            assertEq(t.lastTrader, trader);
            vm.revertToState(snap);
        }
        // A basis that covers the push pays the trader exactly what the uncapped split paid.
        (, uint256 full,,) = _split(amount, amount, true, POT_BPS, TRADER_BPS);
        vm.prank(address(root));
        _recap().settleRecapture(key, ETH, whale, amount, amount, amount);
        assertEq(rules.claimable(ETH, whale), full);
    }

    // ---------------------------------------------------------------- LP leg accrual

    /// Nothing is donated: liquidity added in the same transaction neither receives the LP leg nor diverts it into
    /// the pot. The pot takes only its own leg; the LP leg (with the trader leg of an unauthenticated swap) accrues to
    /// the pool's liquidity owner.
    function test_lpShare_accruesToPoolDespiteSameTransactionLiquidity() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        Actor a = _newActor(key);
        (,,, uint128 potBefore) = _hill(key);
        uint256 lpBefore = _accrued(key);
        a.jitSwap(key, true, -1e18, MIN_PRICE, -600, 600, 1e26);
        (,,, uint128 pot) = _hill(key);
        (,, uint256 potLeg, uint256 lpLeg) = _split(9e18, false, POT_BPS, TRADER_BPS);
        assertEq(pot - potBefore, 2 * potLeg, "the pot takes only its leg");
        assertEq(_accrued(key) - lpBefore, 2 * lpLeg, "LP and trader legs accrue");
    }

    /// With no in-range liquidity the LP leg still accrues to the pool's liquidity owner.
    function test_lpShare_accruesWithoutInRangeLiquidity() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(tb, _laneRules(false), _recaptureOnlyRc());
        HookrToken s = _newSubject();
        // The creator's range sits on one side of the launch price.
        bool subjectIs0 = address(s) < address(tokenB);
        // A sell moves the price toward the range: down when the subject is currency0, up when it is currency1.
        (members[0].tickLower, members[0].tickUpper) =
            subjectIs0 ? (int24(-6000), int24(-600)) : (int24(600), int24(6000));
        (, PoolKey[] memory keys) = _launchAs(creator, s, members);
        PoolKey memory k = keys[0];
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        uint256 before = rules.claimable(tb, protocol);
        vm.recordLogs();
        // The sell crosses the empty band into the creator's range; the before-phase push finds no in-range liquidity.
        _sell(k, tb, whale, 1e20);
        Splits memory t = _splits(vm.getRecordedLogs());
        (uint256 pro,,, uint256 lpLeg) = _split(9e18, false, 0, TRADER_BPS);
        assertEq(t.count, 2);
        assertEq(rules.claimable(tb, protocol) - before, 2 * pro, "protocol leg only");
        assertEq(_accrued(k), 2 * lpLeg, "LP leg accrued to the pool");
        assertEq(rules.claimable(tb, whale), 0, "the scripted push undid nothing of the sell");
        assertTrue(rules.accountingInvariant(tb));
    }
}
