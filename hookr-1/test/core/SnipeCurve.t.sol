// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {RulesKnobsBase} from "./RulesKnobs.t.sol";

/// @notice The Snipe curve knob (RulesKnobs.snipeCurve): a decaying Snipe falls from snipeTaxPips at launch to
///         snipeFloorPips at snipeDecaySeconds along the linear curve (the default, as before the knob), the
///         front-loaded one, which halves what is left to fall every eighth of the decay, in a straight line between
///         the halvings, or the step one, which holds the tax in eight equal steps. Each is checked against a reference
///         written here, at its key points and over random configs and times: never above the start, never below the
///         floor, never rising, the front-loaded curve never above the linear one but for rounding and the step curve
///         never below it. The per-parent-block buy cap follows the curve. A decay may run up to an hour on any guard
///         and up to the guard's whole length on a longer one.
contract SnipeCurveTest is RulesKnobsBase {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant START = 500_000;
    uint24 internal constant FLOOR = 10_000;
    uint16 internal constant DECAY = 800;
    uint16 internal constant SHARE = 2500;
    uint256 internal constant GUARD = 1_000;

    /// @dev Reference curves, written independently of HookrRules: the linear one; the front-loaded one as the
    ///      halvings at each eighth of the decay joined by straight lines (the last eighth falling to the floor); the
    ///      step one as the linear curve's value at the start of the eighth e falls in.
    function _reference(uint8 curve, uint256 start, uint256 floor, uint256 duration, uint256 e)
        internal
        pure
        returns (uint256)
    {
        if (e >= duration) return floor;
        uint256 x = start - floor;
        if (curve == HookrTypes.SNIPE_CURVE_LINEAR) return floor + x * (duration - e) / duration;
        // The eighth e falls in.
        uint256 eighth = e * 8 / duration;
        if (curve == HookrTypes.SNIPE_CURVE_STEP) return floor + x * (8 - eighth) / 8;
        // The halving values at the eighth's two ends.
        uint256 hi = x / (2 ** eighth);
        uint256 lo = eighth == 7 ? 0 : x / (2 ** (eighth + 1));
        // The straight line from hi at the eighth's start to lo at its end, rounded down.
        uint256 into = e * 8 - eighth * duration;
        return floor + lo + (hi - lo) * (duration - into) / duration;
    }

    /// @dev A native-quote member with only Anti-Snipe and the protocol share.
    function _snipeMember(uint24 start, uint24 floor, uint16 decay, uint128 cap)
        internal
        view
        returns (IHookrLauncher.Member memory m)
    {
        m = _member(Currency.wrap(address(0)));
        m.rules.burnBps = 0;
        m.rules.lpBps = 0;
        m.rules.royaltyBps = 0;
        m.rules.royaltyTo = address(0);
        m.rules.protocolShareBps = SHARE;
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + GUARD);
        m.rules.snipeTaxPips = start;
        m.rules.snipeFloorPips = floor;
        m.rules.snipeDecaySeconds = decay;
        m.rules.maxBuyQuoteAmount = cap;
    }

    /// @dev launchFamily's params for one member on a native quote (tokenA the subject), with a Snipe curve.
    function _curveParams(IHookrLauncher.Member memory m, uint8 curve)
        internal
        view
        returns (IHookrLauncher.LaunchParams memory p)
    {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        p.token = IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0));
        p.root = address(root);
        p.members = members;
        p.knobs = new IHookrLauncher.MemberKnobs[](1);
        p.knobs[0].snipeCurve = curve;
        p.advisoryConfigs = new bytes[](1);
        p.buys = new IHookrLauncher.DevBuy[](0);
        p.maxRetainedBps = 10_000;
        p.opening.references = new PoolKey[](0);
        p.deadline = vm.getBlockTimestamp();
    }

    /// @dev A Snipe pool on the curve, launched through launchFamily on a native quote (tokenA the subject).
    function _launchCurve(uint8 curve, uint24 start, uint24 floor, uint16 decay, uint128 cap, int24 spacing)
        internal
        returns (PoolKey memory key)
    {
        IHookrLauncher.Member memory m = _snipeMember(start, floor, decay, cap);
        m.tickSpacing = spacing;
        (bytes32 family,,) = launcher.launchFamily{value: 1e24}(_curveParams(m, curve));
        key = launcher.position(family, 0).key;
    }

    function _context(PoolKey memory key) internal view returns (HookrTypes.SwapContext memory x) {
        x.id = key.toId();
        x.sender = trader;
        x.payer = trader;
        x.beneficiary = trader;
        x.subject = Currency.wrap(address(tokenA));
        x.quote = Currency.wrap(address(0));
        x.authenticated = true;
        x.isBuy = true;
        x.exactInput = true;
        x.zeroForOne = true;
        x.amountSpecified = -1e18;
        x.sqrtPriceLimitX96 = MIN_PRICE;
        x.baseLpFeePips = 3000;
    }

    /// @dev The Snipe the Rules charge a guarded buy now: its LP part plus its protocol part.
    function _snipeNow(PoolKey memory key) internal returns (uint256 snipe) {
        vm.prank(address(root));
        HookrTypes.FeeQuote memory q = rules.beforeSwap(_context(key));
        snipe = q.lpFeeSurchargePips + q.quoteTakePips;
        // The protocol's part is its share of the Snipe, rounded down.
        assertEq(q.quoteTakePips, snipe * SHARE / 10_000, "the protocol's share of it");
    }

    /// The curve ids are the SDK's snipeCurve values: 0 linear (its default), 1 front-loaded, 2 step.
    function test_curveIds() public pure {
        assertEq(HookrTypes.SNIPE_CURVE_LINEAR, 0, "linear");
        assertEq(HookrTypes.SNIPE_CURVE_FRONT_LOADED, 1, "front-loaded");
        assertEq(HookrTypes.SNIPE_CURVE_STEP, 2, "step");
    }

    function test_frontLoaded_keyPoints() public {
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey memory key = _launchCurve(HookrTypes.SNIPE_CURVE_FRONT_LOADED, START, FLOOR, DECAY, 0, 60);
        uint256 x = START - FLOOR;
        // At e = 0 the start; at each eighth the floor plus x halved that many times; at d the floor.
        for (uint256 n; n < 8; ++n) {
            vm.warp(t0 + n * DECAY / 8);
            assertEq(_snipeNow(key), FLOOR + (x >> n), "the halving at each eighth");
        }
        vm.warp(t0 + DECAY / 2);
        assertEq(_snipeNow(key), FLOOR + x / 16, "d/2: four halvings");
        vm.warp(t0 + DECAY - 1);
        assertEq(_snipeNow(key), _reference(1, START, FLOOR, DECAY, DECAY - 1), "the last second");
        assertLt(_snipeNow(key), FLOOR + (x >> 7), "below the last halving");
        vm.warp(t0 + DECAY);
        assertEq(_snipeNow(key), FLOOR, "the floor at d");
        vm.warp(t0 + 10 * DECAY);
        assertEq(_snipeNow(key), FLOOR, "the floor after d");
    }

    function test_step_keyPoints() public {
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey memory key = _launchCurve(HookrTypes.SNIPE_CURVE_STEP, START, FLOOR, DECAY, 0, 60);
        uint256 x = START - FLOOR;
        // The first eighth holds the start; each later eighth starts an eighth of the way lower and holds to its end.
        for (uint256 n; n < 8; ++n) {
            vm.warp(t0 + n * DECAY / 8);
            assertEq(_snipeNow(key), FLOOR + x * (8 - n) / 8, "each step from the start of its eighth");
            vm.warp(t0 + (n + 1) * DECAY / 8 - 1);
            assertEq(_snipeNow(key), FLOOR + x * (8 - n) / 8, "held to the end of its eighth");
        }
        vm.warp(t0 + DECAY / 2);
        assertEq(_snipeNow(key), FLOOR + x / 2, "d/2: half way");
        vm.warp(t0 + DECAY - 1);
        assertEq(_snipeNow(key), FLOOR + x / 8, "the last step");
        vm.warp(t0 + DECAY);
        assertEq(_snipeNow(key), FLOOR, "the floor at d");
        vm.warp(t0 + 10 * DECAY);
        assertEq(_snipeNow(key), FLOOR, "the floor after d");
    }

    function test_linear_keyPointsAsBeforeTheKnob() public {
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey memory key = _launchCurve(HookrTypes.SNIPE_CURVE_LINEAR, START, FLOOR, DECAY, 0, 60);
        vm.warp(t0);
        assertEq(_snipeNow(key), START, "the start");
        vm.warp(t0 + DECAY / 2);
        assertEq(_snipeNow(key), FLOOR + (START - FLOOR) / 2, "half way");
        vm.warp(t0 + DECAY);
        assertEq(_snipeNow(key), FLOOR, "the floor");
        // The plain launch binds the same linear curve.
        uint256 t1 = vm.getBlockTimestamp();
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _snipeMember(START, FLOOR, DECAY, 0);
        members[0].tickSpacing = 120;
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, t1
        );
        PoolKey memory plain = launcher.position(family, 0).key;
        for (uint256 e; e <= DECAY; e += 37) {
            vm.warp(t1 + e);
            assertEq(_snipeNow(plain), _reference(0, START, FLOOR, DECAY, e), "the plain launch's curve");
        }
    }

    /// Over random Snipes and times every curve matches the reference, stays in [floor, start] and never rises; the
    /// front-loaded curve stays at or below the linear one but for a pip of rounding, and the step curve at or above it.
    function testFuzz_curves(uint24 start, uint24 floor, uint16 decay, uint32 e1, uint32 e2) public {
        start = uint24(bound(start, 2, 500_000));
        floor = uint24(bound(floor, 0, start - 1));
        decay = uint16(bound(decay, 1, 3600));
        e1 = uint32(bound(e1, 0, 2 * uint256(decay)));
        e2 = uint32(bound(e2, e1, 2 * uint256(decay) + 1));
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey memory front = _launchCurve(HookrTypes.SNIPE_CURVE_FRONT_LOADED, start, floor, decay, 0, 60);
        PoolKey memory linear = _launchCurve(HookrTypes.SNIPE_CURVE_LINEAR, start, floor, decay, 0, 120);
        PoolKey memory step = _launchCurve(HookrTypes.SNIPE_CURVE_STEP, start, floor, decay, 0, 200);
        vm.warp(t0 + e1);
        uint256 f1 = _snipeNow(front);
        uint256 l1 = _snipeNow(linear);
        uint256 s1 = _snipeNow(step);
        assertEq(f1, _reference(1, start, floor, decay, e1), "front-loaded reference");
        assertEq(l1, _reference(0, start, floor, decay, e1), "linear reference");
        assertEq(s1, _reference(2, start, floor, decay, e1), "step reference");
        assertLe(f1, start, "front-loaded at most the start");
        assertGe(f1, floor, "front-loaded at least the floor");
        assertLe(s1, start, "step at most the start");
        assertGe(s1, floor, "step at least the floor");
        assertLe(f1, l1 + 1, "front-loaded at or below linear");
        assertGe(s1, l1, "step at or above linear");
        vm.warp(t0 + e2);
        assertLe(_snipeNow(front), f1, "front-loaded never rises");
        assertLe(_snipeNow(linear), l1, "linear never rises");
        assertLe(_snipeNow(step), s1, "step never rises");
    }

    function _tryBuy(PoolKey memory key, uint128 amount) internal returns (bool ok) {
        vm.prank(trader);
        (ok,) = address(router).call{value: amount}(
            abi.encodeCall(HookrRouter.swap, (_swap(key, true, true, amount), address(0), new uint256[](0)))
        );
    }

    /// @dev The per-parent-block buy cap is maxBuyQuoteAmount x start / the curve's tax at each point: the exact limit
    ///      passes and one more buy in the same parent block is refused.
    function _capFollows(uint8 curve, int24 spacing) internal {
        uint256 t0 = vm.getBlockTimestamp();
        uint128 cap = 1e16;
        PoolKey memory key = _launchCurve(curve, START, FLOOR, DECAY, cap, spacing);
        uint256[6] memory times = [uint256(0), 1, 100, 200, 399, 799];
        for (uint256 i; i < times.length; ++i) {
            vm.warp(t0 + times[i]);
            vm.roll(vm.getBlockNumber() + 1);
            uint128 limit = uint128(uint256(cap) * START / _reference(curve, START, FLOOR, DECAY, times[i]));
            assertTrue(_tryBuy(key, limit), "the scaled limit");
            assertFalse(_tryBuy(key, 1e9), "one more buy in the same parent block");
        }
    }

    function test_frontLoaded_capFollowsTheCurve() public {
        _capFollows(HookrTypes.SNIPE_CURVE_FRONT_LOADED, 60);
    }

    function test_step_capFollowsTheCurve() public {
        _capFollows(HookrTypes.SNIPE_CURVE_STEP, 120);
    }

    /// @dev Expects launchFamily to refuse `m` on `curve`: the root reports the Rules' InvalidConfig refusal of the bind.
    function _expectRefused(IHookrLauncher.Member memory m, uint8 curve) internal {
        IHookrLauncher.LaunchParams memory p = _curveParams(m, curve);
        vm.expectRevert(_bindRefusal());
        launcher.launchFamily{value: 1e24}(p);
    }

    /// A decay may run up to an hour on any guard, and on a longer guard up to its whole length at 12 seconds a parent
    /// block (MAX_SNIPE_DECAY_SECONDS, PARENT_BLOCK_SECONDS), each end on every curve; one second more is refused.
    function test_decayLength_upToTheGuard() public {
        assertEq(HookrTypes.MAX_SNIPE_DECAY_SECONDS, 3_600);
        assertEq(HookrTypes.PARENT_BLOCK_SECONDS, 12);
        int24[3] memory shortSpacings = [int24(60), 120, 200];
        int24[3] memory longSpacings = [int24(240), 400, 500];
        for (uint8 curve; curve <= HookrTypes.SNIPE_CURVE_STEP; ++curve) {
            // A 100-block guard (1,200 seconds) still takes the hour, and not a second more.
            IHookrLauncher.Member memory m = _snipeMember(START, FLOOR, 3_601, 0);
            m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 100);
            m.tickSpacing = shortSpacings[curve];
            _expectRefused(m, curve);
            m.rules.snipeDecaySeconds = 3_600;
            (bytes32 family,,) = launcher.launchFamily{value: 1e24}(_curveParams(m, curve));
            assertEq(rules.config(launcher.position(family, 0).key.toId()).snipeDecaySeconds, 3_600);
            // A 2,000-block guard (24,000 seconds) takes a decay of its whole length, and not a second more.
            m = _snipeMember(START, FLOOR, 24_001, 0);
            m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 2_000);
            m.tickSpacing = longSpacings[curve];
            _expectRefused(m, curve);
            m.rules.snipeDecaySeconds = 24_000;
            (family,,) = launcher.launchFamily{value: 1e24}(_curveParams(m, curve));
            assertEq(rules.config(launcher.position(family, 0).key.toId()).snipeDecaySeconds, 24_000);
        }
        // The longest decay the type holds, 65,535 seconds, needs a guard of 5,462 parent blocks (65,544 seconds).
        IHookrLauncher.Member memory w = _snipeMember(START, FLOOR, type(uint16).max, 0);
        w.tickSpacing = 600;
        w.rules.guardEndBlock = uint40(vm.getBlockNumber() + 5_461);
        _expectRefused(w, HookrTypes.SNIPE_CURVE_LINEAR);
        w.rules.guardEndBlock = uint40(vm.getBlockNumber() + 5_462);
        launcher.launchFamily{value: 1e24}(_curveParams(w, HookrTypes.SNIPE_CURVE_LINEAR));
    }

    /// A decay over a long guard's whole length: every curve reaches the floor as the guard ends, charging the
    /// reference value at each eighth, the guard's parent blocks rolled at 12 seconds each.
    function test_decayLength_wholeGuard() public {
        uint256 blocks = 3_000;
        uint16 decay = uint16(blocks * 12);
        uint256 t0 = vm.getBlockTimestamp();
        uint256 b0 = vm.getBlockNumber();
        PoolKey[3] memory keys;
        int24[3] memory spacings = [int24(60), 120, 200];
        for (uint8 curve; curve <= HookrTypes.SNIPE_CURVE_STEP; ++curve) {
            IHookrLauncher.Member memory m = _snipeMember(START, FLOOR, decay, 0);
            m.rules.guardEndBlock = uint40(b0 + blocks);
            m.tickSpacing = spacings[curve];
            (bytes32 family,,) = launcher.launchFamily{value: 1e24}(_curveParams(m, curve));
            keys[curve] = launcher.position(family, 0).key;
        }
        for (uint256 n; n <= 8; ++n) {
            uint256 e = n * decay / 8;
            vm.warp(t0 + e);
            vm.roll(b0 + e / 12);
            for (uint8 curve; curve <= HookrTypes.SNIPE_CURVE_STEP; ++curve) {
                if (n == 8) {
                    // The guard ends with the decay: no Snipe at all from the guard's last parent block on.
                    vm.prank(address(root));
                    HookrTypes.FeeQuote memory q = rules.beforeSwap(_context(keys[curve]));
                    assertEq(q.lpFeeSurchargePips + q.quoteTakePips, 0, "no Snipe once the guard ends");
                } else {
                    assertEq(_snipeNow(keys[curve]), _reference(curve, START, FLOOR, decay, e), "the curve");
                }
            }
        }
    }
}
