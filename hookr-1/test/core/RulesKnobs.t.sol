// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrDynamicFee} from "../../src/libraries/HookrDynamicFee.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrRulesKnobs} from "../../src/interfaces/IHookrRulesKnobs.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {EconomicsSecurityBase, BandLp} from "../utils/EconomicsSecurityBase.sol";
import {DustRangeSwapper} from "../utils/DustRangeSwapper.sol";
import {RulesData} from "../utils/RulesData.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";

/// @notice Helpers for the Rules knobs suites: binds as the root binds, launchFamily launches with MemberKnobs, the
///         raw storage a pool's knobs live in, and the knobs' bounds as the contracts state them.
abstract contract RulesKnobsBase is EconomicsSecurityBase {
    using PoolIdLibrary for PoolKey;

    /// @dev HookrRules' storage root (erc7201:hookr.rules); `pools` is its field 0 and `knobs` its field 12.
    bytes32 internal constant RULES_SLOT = 0x762913e4bc0f59f7b08c82f07586fa48932548ab5fab99e6db0b09765b4ff900;
    uint256 internal constant KNOBS_FIELD = 12;

    /// @dev A pure dynamic fee config (EconomicsSecurityBase's): base 3,000, maxFee 100,000, sens 5, share 2,500.
    function _dynamicRules() internal view returns (HookrTypes.RulesConfig memory c) {
        c = _dynamicFeeMember(Currency.wrap(address(0))).rules;
    }

    /// @dev The same config without dynamic fees.
    function _plainRules() internal view returns (HookrTypes.RulesConfig memory c) {
        c = _dynamicRules();
        c.maxFeePips = 3000;
        c.dynamicFeeSens = 0;
    }

    /// @dev `c` (changed in place and returned) with a guard of 100 parent blocks and a Snipe from 100,000 pips
    ///      decaying over `decay` seconds.
    function _withSnipe(HookrTypes.RulesConfig memory c, uint16 decay)
        internal
        view
        returns (HookrTypes.RulesConfig memory)
    {
        c.guardEndBlock = uint40(vm.getBlockNumber() + 100);
        c.snipeTaxPips = 100_000;
        c.snipeDecaySeconds = decay;
        return c;
    }

    /// @dev Knobs with the given tempo and curve.
    function _knobs(uint96 minLiquidity, uint16 window, uint16 reset, uint16 carryBps, uint24 moveTicks, uint8 curve)
        internal
        pure
        returns (HookrTypes.RulesKnobs memory k)
    {
        k.minDynamicFeeLiquidity = minLiquidity;
        k.windowSeconds = window;
        k.resetSeconds = reset;
        k.carryBps = carryBps;
        k.moveTicks = moveTicks;
        k.snipeCurve = curve;
    }

    /// @dev A pool key on the root for a fresh subject against tokenB, and a pool config the Rules' caps admit.
    function _freshKey() internal returns (PoolKey memory key, HookrTypes.PoolConfig memory pc) {
        HookrToken s = new HookrToken("Knob", "KNB", 1e30, address(this));
        Currency subject = Currency.wrap(address(s));
        Currency quote = Currency.wrap(address(tokenB));
        (Currency c0, Currency c1) = address(s) < address(tokenB) ? (subject, quote) : (quote, subject);
        key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
        pc = _member(quote).config;
        pc.subject = subject;
        pc.quote = quote;
        pc.liquidityOwner = address(this);
    }

    /// @dev Binds `data` on the Rules for a fresh pool as the root does during initialization.
    function _bind(bytes memory data) internal returns (PoolKey memory key) {
        HookrTypes.PoolConfig memory pc;
        (key, pc) = _freshKey();
        vm.mockCall(address(root), abi.encodeWithSignature("bindingPool()"), abi.encode(key.toId()));
        vm.prank(address(root));
        rules.bind(key, pc, data);
        vm.clearMockedCalls();
    }

    /// @dev Expects the Rules to refuse `data` with `err` for a fresh pool (empty `err`: any revert).
    function _refuse(bytes memory data, bytes memory err) internal {
        (PoolKey memory key, HookrTypes.PoolConfig memory pc) = _freshKey();
        vm.mockCall(address(root), abi.encodeWithSignature("bindingPool()"), abi.encode(key.toId()));
        vm.prank(address(root));
        if (err.length == 0) vm.expectRevert();
        else vm.expectRevert(err);
        rules.bind(key, pc, data);
        vm.clearMockedCalls();
    }

    function _refuse(bytes memory data) internal {
        _refuse(data, abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector));
    }

    /// @dev What a launch reverts with when the Rules refuse its bind with InvalidConfig: the root's
    ///      ModuleCallReverted carrying that reason.
    function _bindRefusal() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            IHookrRootEvents.ModuleCallReverted.selector,
            address(rules),
            IHookrRules.bind.selector,
            abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector)
        );
    }

    /// @dev The pool's Bound.terms byte, read from storage.
    function _terms(PoolKey memory key) internal view returns (uint8) {
        return uint8(uint256(vm.load(address(rules), keccak256(abi.encode(key.toId(), RULES_SLOT)))) >> 56);
    }

    /// @dev The pool's raw Knobs word.
    function _knobWord(PoolKey memory key) internal view returns (uint256) {
        bytes32 slot = keccak256(abi.encode(key.toId(), uint256(RULES_SLOT) + KNOBS_FIELD));
        return uint256(vm.load(address(rules), slot));
    }

    function _views(PoolKey memory key) internal view returns (HookrTypes.RulesKnobs memory) {
        return IHookrRulesKnobs(address(rules)).rulesKnobs(key.toId());
    }

    /// @dev `m` launched alone through launchFamily with knobs `k`, on tick spacing `spacing`, one parent block later.
    function _launchKnobbed(
        IHookrLauncher.Member memory m,
        bool subjectFirst,
        int24 spacing,
        IHookrLauncher.MemberKnobs memory k
    ) internal returns (PoolKey memory key) {
        (bytes32 family,,) = launcher.launchFamily(_knobbedParams(m, subjectFirst, spacing, k));
        key = launcher.position(family, 0).key;
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev launchFamily's parameters for `m` alone with knobs `k` on tick spacing `spacing`.
    function _knobbedParams(
        IHookrLauncher.Member memory m,
        bool subjectFirst,
        int24 spacing,
        IHookrLauncher.MemberKnobs memory k
    ) internal view returns (IHookrLauncher.LaunchParams memory p) {
        (HookrToken subject, Currency quote) = _pair(subjectFirst);
        m.quote = quote;
        m.tickSpacing = spacing;
        m.tickLower = m.tickLower / spacing * spacing;
        m.tickUpper = m.tickUpper / spacing * spacing;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        p.token = IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0));
        p.root = address(root);
        p.members = members;
        p.knobs = new IHookrLauncher.MemberKnobs[](1);
        p.knobs[0] = k;
        p.advisoryConfigs = new bytes[](1);
        p.buys = new IHookrLauncher.DevBuy[](0);
        p.maxRetainedBps = 10_000;
        p.opening.references = new PoolKey[](0);
        p.deadline = vm.getBlockTimestamp();
    }

    /// @dev MemberKnobs carrying a tempo and a curve, nothing else.
    function _memberKnobs(uint16 window, uint16 reset, uint16 carryBps, uint24 moveTicks, uint8 curve)
        internal
        pure
        returns (IHookrLauncher.MemberKnobs memory k)
    {
        k.windowSeconds = window;
        k.resetSeconds = reset;
        k.carryBps = carryBps;
        k.moveTicks = moveTicks;
        k.snipeCurve = curve;
    }

    /// @dev Whether a dynamic fee pool's tempo is inside HookrTypes' bounds, written independently of HookrRules.
    function _tempoAdmitted(uint256 window, uint256 reset, uint256 carryBps, uint256 moveTicks)
        internal
        pure
        returns (bool)
    {
        uint256 least = 2 * window > 30 ? 2 * window : 30;
        return window >= 12 && window <= 300 && reset >= least && reset <= 1_800 && reset % 15 == 0 && carryBps <= 9_500
            && carryBps % 125 == 0 && moveTicks >= 50 && moveTicks <= 2_000;
    }
}

/// @notice N10: per-pool Rules knobs (HookrTypes.RulesKnobs) ride in the Rules data with today's values as defaults.
///         The data takes exactly three forms: the config alone (no dynamic fees, no arb recapture, default knobs),
///         the config with its knobs, and the config with its knobs and its RecaptureConfig; every other form, the
///         17- and 25-word forms of the release before the knobs included, is refused. The knobs are checked at bind,
///         stored only when one is off its default (one word, flagged in Bound.terms), and served per pool from the
///         fallback (IHookrRulesKnobs).
contract RulesKnobsTest is RulesKnobsBase {
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------------------------------------------ forms

    function test_forms_plainPoolBindsItsConfigAlone() public {
        PoolKey memory key = _bind(abi.encode(_plainRules()));
        assertEq(_terms(key) & 4, 0, "no knobs flag");
        assertEq(_knobWord(key), 0, "nothing stored");
        // The same pool with its knobs spelled out at their defaults is not canonical.
        _refuse(abi.encode(_plainRules(), RulesData.defaults(0)));
    }

    function test_forms_dynamicFeePoolNeedsItsKnobs() public {
        HookrTypes.RulesConfig memory c = _dynamicRules();
        _refuse(abi.encode(c));
        // The release before the knobs: the config and a bare minimum dynamic fee liquidity word.
        _refuse(abi.encode(c, uint256(1e22)));
        PoolKey memory key = _bind(abi.encode(c, RulesData.defaults(1e22)));
        assertEq(_terms(key) & 4, 0, "the default tempo stores nothing");
        assertEq(_knobWord(key), 0, "nothing stored");
        (uint256 minLiquidity,,,,,) = rules.referenceState(key.toId());
        assertEq(minLiquidity, 1e22, "the minimum dynamic fee liquidity");
    }

    function test_forms_recapturePoolCarriesKnobsAndItsConfig() public {
        HookrTypes.RecaptureConfig memory rc;
        rc.on = true;
        rc.traderBps = 2_500;
        rc.lpBps = 7_500;
        rc.releaseBlocks = 36_000;
        HookrTypes.RulesConfig memory plain = _plainRules();
        // The release before the knobs: 25 words, a zero minimum word between the config and the RecaptureConfig.
        _refuse(abi.encode(plain, uint256(0), rc));
        PoolKey memory key = _bind(RulesData.lane(plain, 0, rc));
        assertEq(_knobWord(key), 0, "zero knobs, nothing stored");
        key = _bind(RulesData.lane(_dynamicRules(), 1e22, rc));
        assertEq(_knobWord(key), 0, "default knobs, nothing stored");
        HookrTypes.RulesKnobs memory k = _knobs(1e22, 60, 300, 5_000, 100, 0);
        key = _bind(abi.encode(_dynamicRules(), k, rc));
        assertEq(_terms(key) & 4, 4, "custom knobs flagged");
        assertEq(abi.encode(_views(key)), abi.encode(k), "the knobs as bound");
    }

    function test_forms_anythingElseIsRefused() public {
        HookrTypes.RulesConfig memory c = _dynamicRules();
        bytes memory good = abi.encode(c, RulesData.defaults(1e22));
        _refuse(abi.encodePacked(good, uint256(0)));
        _refuse(abi.encodePacked(abi.encode(_plainRules()), uint256(0)));
        bytes memory short = new bytes(good.length - 32);
        for (uint256 i; i < short.length; ++i) {
            short[i] = good[i];
        }
        _refuse(short);
        // A knob word with bits above its type is not canonical: the decoder refuses it.
        bytes memory dirty = abi.encode(c, RulesData.defaults(1e22));
        assembly ("memory-safe") {
            mstore(add(dirty, add(32, mul(17, 32))), shl(16, 1)) // windowSeconds = 65,536
        }
        _refuse(dirty, "");
    }

    // ------------------------------------------------------------------------------------------------ bounds

    /// Every tempo binds exactly when it is inside the stated bounds, and the knobs it binds are the ones it named.
    /// Each knob is drawn on its grid around its bounds, then nudged off the grid one time in four.
    function testFuzz_tempoBounds(uint16 window, uint16 reset, uint16 carryBps, uint24 moveTicks, uint8 nudge) public {
        window = uint16(bound(window, 0, 320));
        reset = uint16(bound(reset, 0, 125) * 15);
        carryBps = uint16(bound(carryBps, 0, 78) * 125);
        moveTicks = uint24(bound(moveTicks, 0, 2_100));
        if (nudge % 4 == 1) reset += 1 + nudge % 14;
        if (nudge % 4 == 2) carryBps += 1 + nudge % 124;
        HookrTypes.RulesKnobs memory k = _knobs(1e22, window, reset, carryBps, moveTicks, 0);
        bytes memory data = abi.encode(_dynamicRules(), k);
        if (_tempoAdmitted(window, reset, carryBps, moveTicks)) {
            PoolKey memory key = _bind(data);
            assertEq(abi.encode(_views(key)), abi.encode(k), "bound as named");
            (uint256 w, uint256 r, uint256 cb, uint256 mt) =
                IHookrRulesKnobs(address(rules)).dynamicFeeParameters(key.toId());
            assertEq(abi.encode(w, r, cb, mt), abi.encode(window, reset, carryBps, moveTicks), "the pool's tempo");
        } else {
            _refuse(data);
        }
    }

    function test_bounds_eachEnd() public {
        HookrTypes.RulesConfig memory c = _dynamicRules();
        // window
        _bind(abi.encode(c, _knobs(1e22, 12, 30, 7_500, 200, 0)));
        _bind(abi.encode(c, _knobs(1e22, 300, 600, 7_500, 200, 0)));
        _refuse(abi.encode(c, _knobs(1e22, 11, 30, 7_500, 200, 0)));
        _refuse(abi.encode(c, _knobs(1e22, 301, 615, 7_500, 200, 0)));
        // reset: at least twice the window and 30, at most 1,800, on a 15-second grid
        _bind(abi.encode(c, _knobs(1e22, 30, 60, 7_500, 200, 0)));
        _bind(abi.encode(c, _knobs(1e22, 30, 1_800, 7_500, 200, 0)));
        _refuse(abi.encode(c, _knobs(1e22, 30, 45, 7_500, 200, 0)));
        _refuse(abi.encode(c, _knobs(1e22, 12, 15, 7_500, 200, 0)));
        _refuse(abi.encode(c, _knobs(1e22, 30, 1_815, 7_500, 200, 0)));
        _refuse(abi.encode(c, _knobs(1e22, 30, 121, 7_500, 200, 0)));
        _refuse(abi.encode(c, _knobs(1e22, 37, 74, 7_500, 200, 0)));
        _bind(abi.encode(c, _knobs(1e22, 37, 75, 7_500, 200, 0)));
        // carry: 0 to 9,500 on a 125-bps grid
        _bind(abi.encode(c, _knobs(1e22, 30, 120, 0, 200, 0)));
        _bind(abi.encode(c, _knobs(1e22, 30, 120, 9_500, 200, 0)));
        _refuse(abi.encode(c, _knobs(1e22, 30, 120, 9_625, 200, 0)));
        _refuse(abi.encode(c, _knobs(1e22, 30, 120, 7_501, 200, 0)));
        // move ticks: 50 to 2,000
        _bind(abi.encode(c, _knobs(1e22, 30, 120, 7_500, 50, 0)));
        _bind(abi.encode(c, _knobs(1e22, 30, 120, 7_500, 2_000, 0)));
        _refuse(abi.encode(c, _knobs(1e22, 30, 120, 7_500, 49, 0)));
        _refuse(abi.encode(c, _knobs(1e22, 30, 120, 7_500, 2_001, 0)));
        // A dynamic fee pool's minimum dynamic fee liquidity is nonzero; its type bounds it at 2^96 - 1.
        _refuse(abi.encode(c, _knobs(0, 30, 120, 7_500, 200, 0)));
        _bind(abi.encode(c, _knobs(type(uint96).max, 30, 120, 7_500, 200, 0)));
    }

    /// A pool without dynamic fees takes no dynamic fee knob, each one refused alone.
    function test_bounds_noDynamicFeeKnobsWithoutDynamicFees() public {
        HookrTypes.RulesConfig memory c = _withSnipe(_plainRules(), 600);
        _bind(abi.encode(c, _knobs(0, 0, 0, 0, 0, 1)));
        _refuse(abi.encode(c, _knobs(1, 0, 0, 0, 0, 1)));
        _refuse(abi.encode(c, _knobs(0, 30, 0, 0, 0, 1)));
        _refuse(abi.encode(c, _knobs(0, 0, 120, 0, 0, 1)));
        _refuse(abi.encode(c, _knobs(0, 0, 0, 7_500, 0, 1)));
        _refuse(abi.encode(c, _knobs(0, 0, 0, 0, 200, 1)));
    }

    /// The Snipe curve: the linear default, front-loaded or step, a curve other than linear only on a decaying Snipe.
    function test_bounds_snipeCurve() public {
        HookrTypes.RulesConfig memory decaying = _withSnipe(_plainRules(), 600);
        PoolKey memory key = _bind(abi.encode(decaying, _knobs(0, 0, 0, 0, 0, HookrTypes.SNIPE_CURVE_FRONT_LOADED)));
        assertEq(_terms(key) & 4, 4, "flagged");
        assertEq(_views(key).snipeCurve, HookrTypes.SNIPE_CURVE_FRONT_LOADED);
        key = _bind(abi.encode(decaying, _knobs(0, 0, 0, 0, 0, HookrTypes.SNIPE_CURVE_STEP)));
        assertEq(_views(key).snipeCurve, HookrTypes.SNIPE_CURVE_STEP);
        _refuse(abi.encode(decaying, _knobs(0, 0, 0, 0, 0, 3)));
        _refuse(abi.encode(decaying, _knobs(0, 0, 0, 0, 0, type(uint8).max)));
        HookrTypes.RulesConfig memory flat = _withSnipe(_plainRules(), 0);
        _refuse(abi.encode(flat, _knobs(0, 0, 0, 0, 0, HookrTypes.SNIPE_CURVE_FRONT_LOADED)));
        _refuse(abi.encode(flat, _knobs(0, 0, 0, 0, 0, HookrTypes.SNIPE_CURVE_STEP)));
        // A dynamic fee pool takes a curve beside its tempo.
        key = _bind(abi.encode(_withSnipe(_dynamicRules(), 600), _knobs(1e22, 30, 120, 7_500, 200, 1)));
        assertEq(abi.encode(_views(key)), abi.encode(_knobs(1e22, 30, 120, 7_500, 200, 1)));
    }

    // ------------------------------------------------------------------------------------------------ storage, views

    /// Defaults are never stored; a pool with a knob off them stores one word, packed as the Knobs struct lays it out.
    function test_storage_oneWordOnlyOffTheDefaults() public {
        PoolKey memory key = _bind(abi.encode(_dynamicRules(), _knobs(1e22, 60, 300, 5_000, 100, 0)));
        uint256 word = _knobWord(key);
        assertEq(word & 0xffff, 60, "window");
        assertEq((word >> 16) & 0xffff, 300, "reset");
        assertEq((word >> 32) & 0xffff, 5_000, "carry");
        assertEq((word >> 48) & 0xffffff, 100, "move ticks");
        assertEq((word >> 72) & 0xff, 0, "curve");
        assertEq(word >> 80, 0, "nothing above");
        // One knob off its default stores the whole tempo, the defaults beside it.
        key = _bind(abi.encode(_dynamicRules(), _knobs(1e22, 30, 120, 7_500, 300, 0)));
        word = _knobWord(key);
        assertEq(word & 0xffff, 30);
        assertEq((word >> 16) & 0xffff, 120);
        assertEq((word >> 32) & 0xffff, 7_500);
        assertEq((word >> 48) & 0xffffff, 300);
    }

    function test_views() public {
        (uint256 w, uint256 r, uint256 cb, uint256 mt) = rules.dynamicFeeParameters();
        assertEq(abi.encode(w, r, cb, mt), abi.encode(uint256(30), uint256(120), uint256(7_500), uint256(200)));
        IHookrRulesKnobs knobs = IHookrRulesKnobs(address(rules));
        // An unbound pool and a pool without dynamic fees: zeros.
        HookrTypes.RulesKnobs memory none;
        assertEq(abi.encode(knobs.rulesKnobs(PoolId.wrap(bytes32(uint256(1))))), abi.encode(none));
        PoolKey memory plain = _bind(abi.encode(_plainRules()));
        assertEq(abi.encode(knobs.rulesKnobs(plain.toId())), abi.encode(none));
        (w, r, cb, mt) = knobs.dynamicFeeParameters(plain.toId());
        assertEq(w | r | cb | mt, 0, "no tempo without dynamic fees");
        // A dynamic fee pool with the defaults: the defaults.
        PoolKey memory dflt = _bind(RulesData.encode(_dynamicRules(), 7e21));
        assertEq(abi.encode(knobs.rulesKnobs(dflt.toId())), abi.encode(RulesData.defaults(7e21)));
        (w, r, cb, mt) = knobs.dynamicFeeParameters(dflt.toId());
        assertEq(abi.encode(w, r, cb, mt), abi.encode(uint256(30), uint256(120), uint256(7_500), uint256(200)));
        // The module answers only through the Rules.
        (address module,) =
            abi.decode(_call(address(rules), abi.encodeWithSignature("recaptureModule()")), (address, bytes32));
        vm.expectRevert();
        IHookrRulesKnobs(module).rulesKnobs(dflt.toId());
    }

    function _call(address to, bytes memory data) internal view returns (bytes memory out) {
        bool ok;
        (ok, out) = to.staticcall(data);
        assertTrue(ok);
    }

    // ------------------------------------------------------------------------------------------------ launcher

    /// launch, launchAdvised and launchWithBuy bind the default knobs; launchFamily binds each member's.
    function test_launcher_familyPassesTheKnobs() public {
        PoolKey memory key = _launchKnobbed(
            _dynamicFeeMember(Currency.wrap(address(0))), false, 60, _memberKnobs(60, 300, 5_000, 100, 0)
        );
        assertEq(abi.encode(_views(key)), abi.encode(_knobs(1e22, 60, 300, 5_000, 100, 0)));
        // Four zero tempo knobs on a dynamic fee member: the default tempo, stored nowhere.
        key = _launchKnobbed(_dynamicFeeMember(Currency.wrap(address(0))), false, 10, _memberKnobs(0, 0, 0, 0, 0));
        assertEq(abi.encode(_views(key)), abi.encode(RulesData.defaults(1e22)));
        assertEq(_knobWord(key), 0);
        // A curve on a decaying Snipe, the default tempo beside it.
        IHookrLauncher.Member memory s = _dynamicFeeMember(Currency.wrap(address(0)));
        _withSnipe(s.rules, 600);
        key = _launchKnobbed(s, false, 200, _memberKnobs(0, 0, 0, 0, 1));
        assertEq(abi.encode(_views(key)), abi.encode(_knobs(1e22, 30, 120, 7_500, 200, 1)));
        // The plain launch binds the default knobs.
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickSpacing = 120;
        (key,,) = _launchMember(m, true);
        assertEq(abi.encode(_views(key)), abi.encode(RulesData.defaults(1e22)));
    }

    /// A member without dynamic fees passes its knobs as given, so a tempo on it is the Rules' refusal; a plain member
    /// with no knobs binds its config alone, the RulesBound data the plain launch gives it.
    function test_launcher_knobsTheRulesRefuse() public {
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.rules = _plainRules();
        (HookrToken subject, Currency quote) = _pair(false);
        m.quote = quote;
        IHookrLauncher.LaunchParams memory p;
        p.token = IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0));
        p.root = address(root);
        p.members = new IHookrLauncher.Member[](1);
        p.members[0] = m;
        p.knobs = new IHookrLauncher.MemberKnobs[](1);
        p.knobs[0] = _memberKnobs(30, 120, 7_500, 200, 0);
        p.advisoryConfigs = new bytes[](1);
        p.buys = new IHookrLauncher.DevBuy[](0);
        p.maxRetainedBps = 10_000;
        p.opening.references = new PoolKey[](0);
        p.deadline = vm.getBlockTimestamp();
        // The root reports the Rules' refusal of the bind with its reason, InvalidConfig as in the direct binds above.
        vm.expectRevert(_bindRefusal());
        launcher.launchFamily(p);
        // A front-loaded curve on a flat Snipe is refused the same way.
        p.knobs[0] = _memberKnobs(0, 0, 0, 0, 1);
        p.members[0].rules = _withSnipe(_plainRules(), 0);
        vm.expectRevert(_bindRefusal());
        launcher.launchFamily(p);
        p.knobs[0] = _memberKnobs(0, 0, 0, 0, 0);
        p.members[0].rules = _plainRules();
        vm.recordLogs();
        launcher.launchFamily(p);
        assertEq(_boundData(), abi.encode(_plainRules()), "the config alone");
    }

    /// @dev A one-family launch of `members` (their quotes set) with `knobs`, on the existing token `subject`.
    function _familyParams(
        address subject,
        IHookrLauncher.Member[] memory members,
        IHookrLauncher.MemberKnobs[] memory knobs
    ) internal view returns (IHookrLauncher.LaunchParams memory p) {
        p.token = IHookrLauncher.Token(subject, "", "", 0, bytes32(0));
        p.root = address(root);
        p.members = members;
        p.knobs = knobs;
        p.advisoryConfigs = new bytes[](members.length);
        p.buys = new IHookrLauncher.DevBuy[](0);
        p.maxRetainedBps = 10_000;
        p.opening.references = new PoolKey[](0);
        p.deadline = vm.getBlockTimestamp();
    }

    /// launchFamily reads each member's own MemberKnobs: three members with three different sets bind three different
    /// Rules data, in member order, and each pool serves its own knobs.
    function test_launcher_eachMemberItsOwnKnobs() public {
        // A fresh subject against three catalog quotes: a family's members take distinct quotes.
        HookrToken subject = new HookrToken("Family", "FAM", 1e30, address(this));
        subject.approve(address(launcher), type(uint256).max);
        HookrToken third = new HookrToken("Quote C", "QC", 1e30, address(this));
        third.approve(address(launcher), type(uint256).max);
        _catalogQuote(address(third));
        address[3] memory quotes = [address(tokenA), address(tokenB), address(third)];
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](3);
        int24[3] memory spacings = [int24(60), 120, 200];
        for (uint256 i; i < 3; ++i) {
            members[i] = _dynamicFeeMember(Currency.wrap(quotes[i]));
            members[i].tickSpacing = spacings[i];
            members[i].tickLower = members[i].tickLower / spacings[i] * spacings[i];
            members[i].tickUpper = members[i].tickUpper / spacings[i] * spacings[i];
        }
        members[1].rules = _withSnipe(_plainRules(), 600);
        members[2].rules = _withSnipe(_dynamicRules(), 900);
        IHookrLauncher.MemberKnobs[] memory knobs = new IHookrLauncher.MemberKnobs[](3);
        knobs[0] = _memberKnobs(60, 300, 5_000, 100, 0);
        knobs[1] = _memberKnobs(0, 0, 0, 0, HookrTypes.SNIPE_CURVE_FRONT_LOADED);
        knobs[2] = _memberKnobs(12, 30, 0, 2_000, HookrTypes.SNIPE_CURVE_STEP);
        vm.recordLogs();
        (bytes32 family,,) = launcher.launchFamily(_familyParams(address(subject), members, knobs));
        bytes[] memory bound = _allBoundData();
        assertEq(bound.length, 3, "three binds");
        HookrTypes.RulesKnobs[3] memory expected = [
            _knobs(1e22, 60, 300, 5_000, 100, 0),
            _knobs(0, 0, 0, 0, 0, HookrTypes.SNIPE_CURVE_FRONT_LOADED),
            _knobs(1e22, 12, 30, 0, 2_000, HookrTypes.SNIPE_CURVE_STEP)
        ];
        for (uint8 i; i < 3; ++i) {
            PoolKey memory key = launcher.position(family, i).key;
            assertEq(key.tickSpacing, spacings[i], "member order");
            assertEq(abi.encode(_views(key)), abi.encode(expected[i]), "the member's own knobs");
            assertEq(bound[i], abi.encode(members[i].rules, expected[i]), "the member's own Rules data");
        }
    }

    /// The launcher copies MemberKnobs' five Rules knob words into the Rules data unread, so a word wider than its type
    /// reaches the Rules, whose decoder refuses it: the launch reverts. The same calldata with clean words launches.
    function test_launcher_dirtyKnobWordIsRefused() public {
        (HookrToken subject, Currency quote) = _pair(false);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _withSnipeMember();
        members[0].quote = quote;
        IHookrLauncher.MemberKnobs[] memory knobs = new IHookrLauncher.MemberKnobs[](1);
        knobs[0] = _memberKnobs(299, 1_785, 9_375, 1_999, HookrTypes.SNIPE_CURVE_FRONT_LOADED);
        bytes memory data =
            abi.encodeCall(HookrLauncher.launchFamily, (_familyParams(address(subject), members, knobs)));
        // The five knob words, found by their values.
        uint256 at = _findWords(data, [uint256(299), 1_785, 9_375, 1_999]);
        for (uint256 w; w < 5; ++w) {
            bytes memory dirty = bytes.concat(data);
            uint256 word = _wordAt(dirty, at + 32 * w);
            _setWord(dirty, at + 32 * w, word | (w == 3 ? uint256(1) << 24 : w == 4 ? uint256(1) << 8 : 1 << 16));
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(launcher).call(dirty);
            assertFalse(ok, "a dirty knob word is refused");
            vm.revertToState(snap);
        }
        (bool clean,) = address(launcher).call(data);
        assertTrue(clean, "the clean words launch");
    }

    /// @dev A dynamic fee member with a decaying Snipe, at the fixture's default spacing.
    function _withSnipeMember() internal view returns (IHookrLauncher.Member memory m) {
        m = _dynamicFeeMember(Currency.wrap(address(0)));
        _withSnipe(m.rules, 900);
    }

    /// @dev The byte offset of the first 32-byte word, after the selector, where `values` start in that order.
    function _findWords(bytes memory data, uint256[4] memory values) internal pure returns (uint256) {
        uint256 found;
        uint256 count;
        for (uint256 at = 4; at + 32 * 4 <= data.length; at += 32) {
            bool all = true;
            for (uint256 j; j < 4 && all; ++j) {
                all = _wordAt(data, at + 32 * j) == values[j];
            }
            if (all) (found, count) = (at, count + 1);
        }
        require(count == 1, "the knob words are not unique");
        return found;
    }

    function _wordAt(bytes memory data, uint256 at) internal pure returns (uint256 word) {
        assembly ("memory-safe") {
            word := mload(add(add(data, 32), at))
        }
    }

    function _setWord(bytes memory data, uint256 at, uint256 word) internal pure {
        assembly ("memory-safe") {
            mstore(add(add(data, 32), at), word)
        }
    }

    /// @dev The Rules data of every RulesBound logged, in order.
    function _allBoundData() internal returns (bytes[] memory all) {
        bytes32 topic = keccak256("RulesBound(bytes32,address,bytes32,bytes)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic && logs[i].emitter == address(rules)) ++n;
        }
        all = new bytes[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic && logs[i].emitter == address(rules)) {
                (, all[n++]) = abi.decode(logs[i].data, (bytes32, bytes));
            }
        }
    }

    /// @dev The Rules data of the last RulesBound logged.
    function _boundData() internal view returns (bytes memory data) {
        bytes32 topic = keccak256("RulesBound(bytes32,address,bytes32,bytes)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] == topic && logs[i - 1].emitter == address(rules)) {
                (, data) = abi.decode(logs[i - 1].data, (bytes32, bytes));
                return data;
            }
        }
        revert("no RulesBound");
    }
}

/// @notice N10: a pool's tempo knobs drive its dynamic fee reference exactly as the defaults drive a default pool's:
///         one step per window keeps carryBps of the reference's distance from the anchor, a reset joins the anchor,
///         and a move counts only from moveTicks. A model written here predicts every reference tick. A pool with a
///         knob off the defaults pays one more storage read on a dynamic fee swap.
contract RulesKnobsTempoTest is RulesKnobsBase {
    using PoolIdLibrary for PoolKey;

    /// @dev The reference `steps` steps from `ref` toward `anchor`, each keeping carryBps of the distance, the
    ///      division rounding toward zero; written independently of HookrRules.
    function _stepped(int256 ref, int256 anchor, uint256 steps, uint256 carryBps) internal pure returns (int24) {
        int256 d = ref - anchor;
        for (uint256 i; i < steps; ++i) {
            d = d * int256(carryBps) / 10_000;
        }
        return int24(anchor + d);
    }

    function _reference(PoolKey memory key) internal view returns (int24 ref, int24 anchor) {
        (, ref, anchor,,,) = rules.referenceState(key.toId());
    }

    function _moved(PoolKey memory key) internal view returns (uint40 movedAt, int24 movedTick) {
        (,,, movedAt,, movedTick) = rules.referenceState(key.toId());
    }

    /// Window 60 s, reset 300 s, carry 50%: no step inside the window, one step per window after it, a step per reset
    /// while the anchor keeps moving, and the reference joins the anchor once the reset passes without a counted move.
    function test_tempo_windowCarryAndReset() public {
        PoolKey memory key = _launchKnobbed(
            _dynamicFeeMember(Currency.wrap(address(0))), false, 60, _memberKnobs(60, 300, 5_000, 100, 0)
        );
        uint256 t0 = vm.getBlockTimestamp();
        _buyAs(trader, key, 3e22);
        (int24 ref, int24 anchor) = _reference(key);
        (uint40 movedAt,) = _moved(key);
        assertEq(movedAt, t0, "the buy's move counted");
        assertEq(ref, 0, "the reference starts at the launch price");
        assertLt(anchor, -500, "the anchor followed the buy");
        vm.warp(t0 + 59);
        _buyAs(trader, key, 1e15);
        (int24 r,) = _reference(key);
        assertEq(r, ref, "no step inside the window");
        vm.warp(t0 + 60);
        _buyAs(trader, key, 1e15);
        (r,) = _reference(key);
        int24 expected = _stepped(ref, anchor, 1, 5_000);
        assertEq(r, expected, "one window: one step keeping half");
        vm.warp(t0 + 179);
        _buyAs(trader, key, 1e15);
        (r,) = _reference(key);
        expected = _stepped(expected, anchor, 1, 5_000);
        assertEq(r, expected, "a second window, counted from the first step");
        vm.warp(t0 + 300);
        _buyAs(trader, key, 1e15);
        (int24 joined, int24 a) = _reference(key);
        assertEq(joined, a, "the reset joins the anchor");
    }

    /// The same buys on a default pool step the default way: two 30 s windows in 60 s, each keeping 75%.
    function test_tempo_defaultPoolStepsTheDefaultWay() public {
        PoolKey memory key =
            _launchKnobbed(_dynamicFeeMember(Currency.wrap(address(0))), false, 60, _memberKnobs(0, 0, 0, 0, 0));
        uint256 t0 = vm.getBlockTimestamp();
        _buyAs(trader, key, 3e22);
        (int24 ref, int24 anchor) = _reference(key);
        vm.warp(t0 + 60);
        _buyAs(trader, key, 1e15);
        (int24 r,) = _reference(key);
        assertEq(r, _stepped(ref, anchor, 2, 7_500), "two default windows");
    }

    /// A buy that moves the anchor about 150 ticks counts on a pool whose moveTicks is 100 and not on a default pool
    /// (200): only the first restarts its windows.
    function test_tempo_moveTicksDecidesWhatCounts() public {
        PoolKey memory k100 = _launchKnobbed(
            _dynamicFeeMember(Currency.wrap(address(0))), false, 60, _memberKnobs(30, 120, 7_500, 100, 0)
        );
        PoolKey memory k200 =
            _launchKnobbed(_dynamicFeeMember(Currency.wrap(address(0))), false, 120, _memberKnobs(0, 0, 0, 0, 0));
        uint256 t0 = vm.getBlockTimestamp();
        _buyAs(trader, k100, 1e18);
        _buyAs(trader, k200, 1e18);
        vm.warp(t0 + 10);
        _buyAs(trader, k100, 7.5e21);
        _buyAs(trader, k200, 7.5e21);
        (uint40 at100, int24 tick100) = _moved(k100);
        (uint40 at200, int24 tick200) = _moved(k200);
        (, int24 anchor) = _reference(k100);
        assertLt(anchor, -100, "the anchor moved over 100 ticks");
        assertGt(anchor, -200, "and under 200");
        assertEq(at100, t0 + 10, "counted at 100 ticks");
        assertEq(tick100, anchor, "from where it left the anchor");
        assertEq(at200, t0, "not at the default 200");
        assertEq(tick200, 0, "the default pool's last counted move stays at the start");
    }

    /// A dynamic fee swap on a pool with knobs off the defaults reads its Knobs: one more storage read (cold in a fresh
    /// transaction, 2,100 gas) than the same swap on a default pool, which reads none. Both swaps run from the same
    /// state with the Rules' storage cold, as at the start of a transaction; the numbers are logged for the gas notes.
    function test_gas_knobbedSwapReadsItsKnobs() public {
        PoolKey memory knobbed = _launchKnobbed(
            _dynamicFeeMember(Currency.wrap(address(0))), false, 60, _memberKnobs(30, 120, 7_500, 201, 0)
        );
        PoolKey memory plain =
            _launchKnobbed(_dynamicFeeMember(Currency.wrap(address(0))), false, 120, _memberKnobs(0, 0, 0, 0, 0));
        _buyAs(trader, knobbed, 1e21);
        _buyAs(trader, plain, 1e21);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 snap = vm.snapshotState();
        vm.cool(address(rules));
        uint256 g0 = gasleft();
        _buyAs(trader, knobbed, 1e21);
        uint256 knobbedGas = g0 - gasleft();
        vm.revertToState(snap);
        vm.cool(address(rules));
        g0 = gasleft();
        _buyAs(trader, plain, 1e21);
        uint256 plainGas = g0 - gasleft();
        emit log_named_uint("dynamic fee buy, knobs off the defaults", knobbedGas);
        emit log_named_uint("dynamic fee buy, default knobs", plainGas);
        assertGt(knobbedGas, plainGas + 2_000, "one cold read of the Knobs");
        assertLt(knobbedGas, plainGas + 2_100 + 2 * 100 + 300, "and no more than it, a warm reread and the branches");
    }
}

/// @notice N10 bounds, proven at both ends: at every tempo knob's least and largest value (the other three at their
///         defaults) and at the fastest and the slowest tempo, the dynamic fee suites' properties hold. F-003's dust
///         trap and DF-01's near-free pushes and parked gap add nothing to the next buyer's fee, after waits measured
///         in the pool's own window and reset; a buy split into pieces at one timestamp, or less than a window apart
///         with every piece a counted move, pays what one buy pays; a sandwich costs more than without dynamic fees;
///         a pool opening at its band's edge pays the in-range fee (L-05); DF-04's small swaps back and forth leave
///         no price memory and dust swaps do not speed the decay; and over random pools a first swap is charged at
///         least the fee its executed move implies (DF-02). Pure dynamic fee pool: base 3,000, maxFee 100,000, sens
///         5, share 2,500, launch liquidity 1e24 at spacing 60; the quote is currency0, so a buy is zeroForOne.
contract RulesKnobsBoundsTest is RulesKnobsBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    BandLp internal dust;
    DustRangeSwapper internal swapper;
    address internal attacker = address(0xBAD);
    address internal victim = address(0xB0B);

    function setUp() public override {
        super.setUp();
        dust = new BandLp(manager);
        swapper = new DustRangeSwapper(manager);
        tokenA.transfer(address(dust), 1e18);
        tokenB.transfer(address(dust), 1e18);
        tokenA.transfer(address(swapper), 1e21);
        tokenB.transfer(address(swapper), 1e21);
        address[2] memory people = [attacker, victim];
        for (uint256 i; i < 2; ++i) {
            tokenA.transfer(people[i], 1e27);
            tokenB.transfer(people[i], 1e27);
            vm.startPrank(people[i]);
            tokenA.approve(address(router), type(uint256).max);
            tokenB.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev Each tempo knob at both ends, then the fastest and the slowest tempo.
    function _ends() internal pure returns (IHookrLauncher.MemberKnobs[10] memory e) {
        e[0] = _memberKnobs(12, 120, 7_500, 200, 0);
        e[1] = _memberKnobs(300, 600, 7_500, 200, 0);
        e[2] = _memberKnobs(30, 60, 7_500, 200, 0);
        e[3] = _memberKnobs(30, 1_800, 7_500, 200, 0);
        e[4] = _memberKnobs(30, 120, 0, 200, 0);
        e[5] = _memberKnobs(30, 120, 9_500, 200, 0);
        e[6] = _memberKnobs(30, 120, 7_500, 50, 0);
        e[7] = _memberKnobs(30, 120, 7_500, 2_000, 0);
        e[8] = _memberKnobs(12, 30, 0, 2_000, 0);
        e[9] = _memberKnobs(300, 1_800, 9_500, 50, 0);
    }

    function _open(IHookrLauncher.Member memory m, IHookrLauncher.MemberKnobs memory k)
        internal
        returns (PoolKey memory)
    {
        return _launchKnobbed(m, false, 60, k);
    }

    /// @dev The F-003 pool: band [-60,000, 0) under the launch price at tick 0.
    function _edgePool(IHookrLauncher.MemberKnobs memory k) internal returns (PoolKey memory) {
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickUpper = 0;
        return _open(m, k);
    }

    function _swapAs(address who, PoolKey memory key, bool buy, bool exactInput, uint128 amount)
        internal
        returns (HookrTypes.ExecutionReceipt memory r, uint256 output)
    {
        IHookrRouter.Swap memory p = _swap(key, buy, exactInput, amount);
        p.recipient = who;
        r = quoter.quote(p, who);
        vm.prank(who);
        (, output) = router.swap(p, address(0), new uint256[](0));
    }

    // ------------------------------------------------------------------------------------------------ F-003, DF-01

    /// @dev F-003's dust trap: a liquidity-1 range above the price and a near-free push to tick 16,200, then a buyer
    ///      after `blocks` blocks and `wait` seconds pays what it pays with no trap.
    function _trap(IHookrLauncher.MemberKnobs memory k, uint256 blocks, uint256 wait) internal {
        uint256 fresh = vm.snapshotState();
        PoolKey memory key = _edgePool(k);
        uint256 snap = vm.snapshotState();
        vm.warp(vm.getBlockTimestamp() + wait);
        uint256 ctlFee = _quoteBuy(key, 1e21).lpFeePips;
        (, uint256 ctlOut) = _buyAs(trader, key, 1e21);
        vm.revertToState(snap);
        vm.startPrank(attacker);
        dust.modify(key, 60, 16_080, 1);
        swapper.swap(key, false, -1e6, TickMath.getSqrtPriceAtTick(16_200));
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + wait);
        uint256 fee = _quoteBuy(key, 1e21).lpFeePips;
        (, uint256 out) = _buyAs(trader, key, 1e21);
        assertApproxEqAbs(fee, ctlFee, 1, "the trap adds nothing");
        assertGe(out * 1000, ctlOut * 999, "victim output");
        vm.revertToState(fresh);
    }

    function test_dustTrapAtEveryEnd() public {
        IHookrLauncher.MemberKnobs[10] memory e = _ends();
        for (uint256 i; i < e.length; ++i) {
            _trap(e[i], 0, 0);
            _trap(e[i], 1, 12);
            _trap(e[i], 10, e[i].windowSeconds + 1);
            _trap(e[i], 40, e[i].resetSeconds + 1);
        }
    }

    /// @dev DF-01's two near-free pushes through a thin range and back, then five victims, against five victims alone.
    function _roundTrip(IHookrLauncher.MemberKnobs memory k) internal {
        uint256 fresh = vm.snapshotState();
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickUpper = 0;
        PoolKey memory key = _open(m, k);
        uint256 snap = vm.snapshotState();
        uint256[5] memory ctl;
        for (uint256 i; i < 5; ++i) {
            (HookrTypes.ExecutionReceipt memory r,) = _swapAs(victim, key, true, true, 1e21);
            ctl[i] = r.lpFeePips;
        }
        vm.revertToState(snap);
        vm.startPrank(attacker);
        dust.modify(key, 60, 16_080, 1e12);
        swapper.swap(key, false, -1e18, TickMath.getSqrtPriceAtTick(16_200));
        swapper.swap(key, true, 1e18, TickMath.getSqrtPriceAtTick(0));
        dust.modify(key, 60, 16_080, -1e12);
        vm.stopPrank();
        for (uint256 i; i < 5; ++i) {
            (HookrTypes.ExecutionReceipt memory r,) = _swapAs(victim, key, true, true, 1e21);
            assertApproxEqAbs(r.lpFeePips, ctl[i], 1, "the pushes add nothing");
        }
        vm.revertToState(fresh);
    }

    function test_nearFreePushesAtEveryEnd() public {
        IHookrLauncher.MemberKnobs[10] memory e = _ends();
        for (uint256 i; i < e.length; ++i) {
            _roundTrip(e[i]);
        }
    }

    /// DF-01's parked gap: a 1-wei sell parks the price beyond all liquidity, against the buy direction; after no
    /// wait, a window and a reset (the pool's own) the next buy pays what it pays with no park.
    function test_parkedGapAtEveryEnd() public {
        IHookrLauncher.MemberKnobs[10] memory e = _ends();
        for (uint256 i; i < e.length; ++i) {
            uint256[3] memory waits = [uint256(0), uint256(e[i].windowSeconds) + 1, uint256(e[i].resetSeconds) + 1];
            for (uint256 w; w < 3; ++w) {
                uint256 fresh = vm.snapshotState();
                PoolKey memory key = _edgePool(e[i]);
                uint256 snap = vm.snapshotState();
                vm.warp(vm.getBlockTimestamp() + waits[w]);
                HookrTypes.ExecutionReceipt memory ctl = _quoteBuy(key, 1e22);
                vm.revertToState(snap);
                vm.prank(attacker);
                swapper.swap(key, false, -1, TickMath.MAX_SQRT_PRICE - 1);
                vm.warp(vm.getBlockTimestamp() + waits[w]);
                HookrTypes.ExecutionReceipt memory atk = _quoteBuy(key, 1e22);
                assertGt(ctl.lpFeePips, 3000, "control pays a dynamic fee");
                assertApproxEqAbs(atk.lpFeePips, ctl.lpFeePips, 1, "the parked gap adds nothing");
                assertEq(atk.outputAmount, ctl.outputAmount, "same fill");
                vm.revertToState(fresh);
            }
        }
    }

    /// @dev One buy of `total`, or the same buy in `n` pieces `gap` seconds apart, on a fresh pool.
    function _split(IHookrLauncher.MemberKnobs memory k, uint256 total, uint256 n, uint256 gap)
        internal
        returns (uint256 out, uint256 protocolClaim)
    {
        uint256 snap = vm.snapshotState();
        PoolKey memory key = _open(_dynamicFeeMember(Currency.wrap(address(0))), k);
        uint128 piece = uint128(total / n);
        Currency subject = root.poolConfig(key.toId()).subject;
        uint256 before = IERC20(Currency.unwrap(subject)).balanceOf(victim);
        for (uint256 i; i < n; ++i) {
            if (i != 0) vm.warp(vm.getBlockTimestamp() + gap);
            _swapAs(victim, key, true, true, piece);
        }
        out = IERC20(Currency.unwrap(subject)).balanceOf(victim) - before;
        protocolClaim = rules.claimable(root.poolConfig(key.toId()).quote, protocol);
        vm.revertToState(snap);
    }

    /// DF-01's split: a 6e22 buy in 2, 5 or 10 pieces at one timestamp, and in pieces spread over the pool's reset
    /// period with no gap as long as its window where every piece is a counted move (it carries the anchor past the
    /// pool's moveTicks, so each restarts the windows), gets no more subject than the single buy and pays its dynamic
    /// fee less the single buy's simulation lead. Where a piece is no counted move (moveTicks 2,000: no piece of a
    /// 6e22 split moves the anchor that far) pieces spread over windows decay like any patient buyer's, by that knob's
    /// design, and are not asserted here; nor are pieces spread past a reset, which steps the reference by design.
    function test_splitSavesNothingAtEveryEnd() public {
        IHookrLauncher.MemberKnobs[10] memory e = _ends();
        uint256[3] memory ns = [uint256(2), 5, 10];
        for (uint256 i; i < e.length; ++i) {
            (uint256 oneOut, uint256 oneFee) = _split(e[i], 6e22, 1, 0);
            for (uint256 k; k < 3; ++k) {
                // A piece of x = piece / 1e24 moves the anchor 20,000 x ln(1 + x) ticks, at least 20,000 x - 10,000 x^2.
                uint256 piece = 6e22 / ns[k];
                uint256 least = 20_000 * piece / 1e24 - 10_000 * piece * piece / 1e48;
                for (uint256 g; g < 2; ++g) {
                    if (g == 1 && least < e[i].moveTicks) continue;
                    uint256 gap = (uint256(e[i].resetSeconds) - 1) / (ns[k] - 1);
                    if (gap >= e[i].windowSeconds) gap = uint256(e[i].windowSeconds) - 1;
                    if (g == 0) gap = 0;
                    (uint256 out, uint256 fee) = _split(e[i], 6e22, ns[k], gap);
                    assertLe(out * 10_000, oneOut * 10_003, "no more subject than the single buy");
                    assertGe(fee * 10_000, oneFee * 9_700, "the same dynamic fee, less the single buy's lead");
                }
            }
        }
    }

    /// @dev DF-01's sandwich: a 3e22 front-run, the victim's 1e22 buy and the back-run sell; the attacker's quote P&L.
    function _sandwich(IHookrLauncher.Member memory m, IHookrLauncher.MemberKnobs memory k)
        internal
        returns (int256 pnl, uint256 frontFee, uint256 backFee)
    {
        uint256 snap = vm.snapshotState();
        PoolKey memory key = _open(m, k);
        address quote = Currency.unwrap(root.poolConfig(key.toId()).quote);
        uint256 quoteBefore = IERC20(quote).balanceOf(attacker);
        (HookrTypes.ExecutionReceipt memory front, uint256 got) = _swapAs(attacker, key, true, true, 3e22);
        _swapAs(victim, key, true, true, 1e22);
        (HookrTypes.ExecutionReceipt memory back,) = _swapAs(attacker, key, false, true, uint128(got));
        pnl = int256(IERC20(quote).balanceOf(attacker)) - int256(quoteBefore);
        (frontFee, backFee) = (front.lpFeePips, back.lpFeePips);
        vm.revertToState(snap);
    }

    function test_sandwichCostsMoreAtEveryEnd() public {
        IHookrLauncher.Member memory flat = _dynamicFeeMember(Currency.wrap(address(0)));
        flat.rules.maxFeePips = 3000;
        flat.rules.dynamicFeeSens = 0;
        (int256 flatPnl,,) = _sandwich(flat, _memberKnobs(0, 0, 0, 0, 0));
        IHookrLauncher.MemberKnobs[10] memory e = _ends();
        for (uint256 i; i < e.length; ++i) {
            (int256 pnl, uint256 frontFee, uint256 backFee) =
                _sandwich(_dynamicFeeMember(Currency.wrap(address(0))), e[i]);
            assertGt(frontFee, 3000, "the front-run pays for its own move");
            assertEq(backFee, 3000, "the back-run pays the base fee only");
            assertLt(pnl, flatPnl, "dynamic fees make the sandwich cost more");
        }
    }

    // ------------------------------------------------------------------------------------------------ L-05, DF-04

    /// L-05: a pool opening at its band's edge pays the in-range dynamic fee on its first buy.
    function test_boundaryOpenAtEveryEnd() public {
        IHookrLauncher.MemberKnobs[10] memory e = _ends();
        for (uint256 i; i < e.length; ++i) {
            uint256 snap = vm.snapshotState();
            IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
            m.tickUpper = 0;
            HookrTypes.ExecutionReceipt memory boundary = _quoteBuy(_open(m, e[i]), 1e22);
            vm.revertToState(snap);
            m = _dynamicFeeMember(Currency.wrap(address(0)));
            m.tickUpper = 60;
            HookrTypes.ExecutionReceipt memory control = _quoteBuy(_open(m, e[i]), 1e22);
            vm.revertToState(snap);
            assertGt(boundary.lpFeePips, 3000, "dynamic fee charged at the boundary");
            assertGe(uint256(boundary.lpFeePips) * 100, uint256(control.lpFeePips) * 95, "LP fee");
            assertGe(boundary.quoteFee * 100, control.quoteFee * 95, "protocol");
        }
    }

    /// @dev After a 6e22 pump, the attacker alternates `leg` sells and buys every window less a second; the next 1e21
    ///      buyer at `horizon` pays what it pays with no hold.
    function _holdRun(IHookrLauncher.MemberKnobs memory k, uint256 horizon, bool hold, uint128 leg)
        internal
        returns (uint256 fee)
    {
        uint256 fresh = vm.snapshotState();
        PoolKey memory key = _open(_dynamicFeeMember(Currency.wrap(address(0))), k);
        _swapAs(victim, key, true, true, 6e22);
        uint256 t0 = vm.getBlockTimestamp();
        uint256 every = uint256(k.windowSeconds) - 1;
        if (hold) {
            bool sell = true;
            uint256 bought;
            while (vm.getBlockTimestamp() + every < t0 + horizon) {
                vm.warp(vm.getBlockTimestamp() + every);
                vm.roll(vm.getBlockNumber() + 1);
                if (sell) {
                    (, bought) = _swapAs(attacker, key, false, true, leg);
                } else {
                    _swapAs(attacker, key, true, true, uint128(bought));
                }
                sell = !sell;
            }
        }
        vm.warp(t0 + horizon);
        vm.roll(vm.getBlockNumber() + 1);
        fee = _quoteBuy(key, 1e21).lpFeePips;
        vm.revertToState(fresh);
    }

    /// DF-04: small swaps back and forth (each well under the pool's moveTicks) keep no price memory, at a reset and
    /// at two resets.
    function test_smallSwapsDoNotHoldTheReferenceAtEveryEnd() public {
        IHookrLauncher.MemberKnobs[10] memory e = _ends();
        for (uint256 i; i < e.length; ++i) {
            uint256[2] memory horizons = [uint256(e[i].resetSeconds) + 5, 2 * uint256(e[i].resetSeconds) + 5];
            for (uint256 h; h < 2; ++h) {
                uint256 honest = _holdRun(e[i], horizons[h], false, 0);
                uint256 held = _holdRun(e[i], horizons[h], true, 3e20);
                assertLe(held, honest + 30, "the hold keeps no price memory");
            }
        }
    }

    /// @dev A 3e22 buy, then 1-wei exact-output buys at each of the pool's next three windows, then a second 3e22 buy
    ///      a second after the third. DF-04's form, whose default-tempo case pins the fill to the wei.
    function _pokeRun(IHookrLauncher.MemberKnobs memory k, bool poke) internal returns (uint256 fee, uint256 out) {
        uint256 fresh = vm.snapshotState();
        PoolKey memory key = _open(_dynamicFeeMember(Currency.wrap(address(0))), k);
        _swapAs(victim, key, true, true, 3e22);
        uint256 t0 = vm.getBlockTimestamp();
        uint256 window = k.windowSeconds;
        if (poke) {
            for (uint256 j = 1; j <= 3; ++j) {
                vm.warp(t0 + window * j);
                vm.prank(attacker);
                swapper.swap(key, true, 1, TickMath.MIN_SQRT_PRICE + 1);
            }
        }
        vm.warp(t0 + 3 * window + 1);
        HookrTypes.ExecutionReceipt memory r;
        (r, out) = _swapAs(victim, key, true, true, 3e22);
        fee = r.lpFeePips;
        vm.revertToState(fresh);
    }

    function test_dustSwapsDoNotSpeedTheDecayAtEveryEnd() public {
        IHookrLauncher.MemberKnobs[10] memory e = _ends();
        for (uint256 i; i < e.length; ++i) {
            (uint256 plainFee, uint256 plainOut) = _pokeRun(e[i], false);
            (uint256 pokedFee, uint256 pokedOut) = _pokeRun(e[i], true);
            assertEq(pokedFee, plainFee, "same fee");
            // The three 1-wei buys move the price by their own 3 wei of subject, which the fill may round by.
            assertApproxEqAbs(pokedOut, plainOut, 3, "the same fill but the pokes' own 3 wei");
        }
    }

    /// DF-02: over random pools, swaps and tempo knobs at their ends, a fresh pool's first swap is charged at least the
    /// dynamic fee its executed end price implies, and an exact-output buy exactly that.
    function testFuzz_chargeCoversTheMoveAtEveryEnd(uint256 seed) public {
        IHookrLauncher.MemberKnobs memory k = _ends()[seed % 10];
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.rules.dynamicFeeSens = uint16(1 + uint256(keccak256(abi.encode(seed, 1))) % 10);
        uint24[4] memory spans = [uint24(10_000), 50_000, 100_000, 600_000];
        m.rules.maxFeePips = spans[uint256(keccak256(abi.encode(seed, 2))) % 4];
        // At most the widest span the reach bound admits at the pool's sensitivity and share.
        RulesData.clampToReach(m.rules, 3000);
        int24 tick = int24(int256(uint256(keccak256(abi.encode(seed, 5))) % 40_001)) - 20_000;
        m.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        int24 aligned = tick / 60 * 60;
        m.tickLower = aligned - 30_000;
        m.tickUpper = aligned + 30_000;
        m.amount0Max = 1e27;
        m.amount1Max = 1e27;
        PoolKey memory key = _launchKnobbed(m, uint256(keccak256(abi.encode(seed, 6))) % 2 == 1, 60, k);
        bool buy = uint256(keccak256(abi.encode(seed, 40))) % 2 == 1;
        bool exactInput = uint256(keccak256(abi.encode(seed, 41))) % 2 == 1;
        uint128 amount = uint128(10 ** (15 + uint256(keccak256(abi.encode(seed, 42))) % 9));
        IHookrRouter.Swap memory p = _swap(key, buy, exactInput, amount);
        p.recipient = victim;
        HookrTypes.ExecutionReceipt memory r;
        try quoter.quote(p, victim) returns (HookrTypes.ExecutionReceipt memory q) {
            r = q;
        } catch {
            return;
        }
        vm.prank(victim);
        router.swap(p, address(0), new uint256[](0));
        (uint160 end,,,) = manager.getSlot0(key.toId());
        int256 dist = HookrDynamicFee.distance(TickMath.getSqrtPriceAtTick(tick), end, p.zeroForOne);
        uint256 ideal;
        if (dist > 0) {
            ideal = uint256(m.rules.maxFeePips - 3000)
                * HookrDynamicFee.averageRate(0, uint256(dist), m.rules.dynamicFeeSens) / HookrDynamicFee.WAD;
        }
        uint256 room = 600_000 - 3000;
        if (ideal > room) ideal = room;
        uint256 floorFee = 3000 + ideal - ideal * 2500 / 10_000;
        assertGe(uint256(r.lpFeePips) + 1, floorFee, "never below the executed move");
        if (buy && !exactInput) assertApproxEqAbs(r.lpFeePips, floorFee, 1, "an exact-output buy is exact");
    }
}
