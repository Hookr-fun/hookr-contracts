// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {HookrRootFactory} from "../../src/factory/HookrRootFactory.sol";
import {HookrPairRoot} from "../../src/factory/HookrPairRoot.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {IHookrPairAdvisory} from "../../src/interfaces/IHookrPairAdvisory.sol";
import {IHookrFactoryRegistry} from "../../src/interfaces/IHookrRootFactory.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {IHookrSessionAdvisory} from "../../src/interfaces/IHookrSessionAdvisory.sol";
import {HookrMarketCalendar} from "../../src/libraries/HookrMarketCalendar.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PairRootFixture} from "./PairRootFixture.sol";
import {mineSalt} from "../../script/HookrPairRootSalt.s.sol";

/// @dev A contract the registry owner registers as a root through REGISTER_ROOT, claiming a pair root's poolId().
contract GovernedPairImpostor {
    IPoolManager public immutable poolManager;
    IHookrRegistry public immutable registry;
    PoolId public poolId;

    constructor(IPoolManager manager, IHookrRegistry registry_, PoolId id) {
        poolManager = manager;
        registry = registry_;
        poolId = id;
    }

    function PERMISSION_FLAGS() external view returns (uint160) {
        return uint160(address(this)) & 0x3fff;
    }

    function bind(IHookrPairAdvisory module, uint24 capPips, uint32 gasLimit, bytes calldata data) external {
        module.bindPair(poolId, capPips, gasLimit, data);
    }
}

/// @dev HookrFeeAdvisory and HookrSessionAdvisory behind factory-deployed pair roots, swapped through the real
///      PoolManager: binding at deploy, repricing, TTL expiry, direction premia, session tiers on known dates,
///      rebinding and foreign callers, and the root's fail-open and fail-closed paths.
contract PairRootAdvisoriesTest is PairRootFixture {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant BASE = 3_000;
    uint24 internal constant ROOT_CAP = 2_000;
    uint24 internal constant REGULAR = 1_000;
    uint24 internal constant PRE = 4_000;
    uint24 internal constant AFTER = 6_000;
    uint24 internal constant NIGHT = 10_000;
    uint24 internal constant CLOSED = 20_000;
    uint24 internal constant SESSION_CAP = 25_000;

    HookrFeeAdvisory internal fee;
    HookrSessionAdvisory internal session;
    address internal keeper = address(0xBEEF);

    function setUp() public {
        _setUpFactory();
        session = new HookrSessionAdvisory(address(this), 1 days);
        fee = new HookrFeeAdvisory(address(this), 1 days, IHookrRegistry(address(registry)), address(session));
        _admitPairAdvisory(registry, address(factory), address(fee));
        _admitPairAdvisory(registry, address(factory), address(session));
        fee.queue(fee.ADD_KEEPER(), abi.encode(keeper));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        fee.addKeeper(keeper);
        vm.warp(_ny(2026, 9, 29, 11, 0, 0, true));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _cfg(uint24 cap, uint24 surcharge, uint24 p0, uint24 p1)
        internal
        pure
        returns (IHookrFeeAdvisory.Config memory)
    {
        return IHookrFeeAdvisory.Config({
            cap: cap, surcharge: surcharge, premium0: p0, premium1: p1, maxStep: 500, minInterval: 60, maxTtl: 1 hours
        });
    }

    function _schedule(uint16 openRamp, uint16 closeRamp, uint8 flags)
        internal
        pure
        returns (IHookrSessionAdvisory.Schedule memory)
    {
        return IHookrSessionAdvisory.Schedule(REGULAR, PRE, AFTER, NIGHT, CLOSED, openRamp, closeRamp, flags);
    }

    function _params(address module, uint24 cap, uint32 gasLimit, bool failOpen)
        internal
        view
        returns (IHookrPairRoot.Params memory p)
    {
        (Currency c0, Currency c1) = _erc();
        p = _plain(c0, c1, BASE);
        p.maxLpFeePips = BASE + cap;
        p.advisory = module;
        p.advisoryCapPips = cap;
        p.advisoryGasLimit = gasLimit;
        p.advisoryFailOpen = failOpen;
    }

    function _deployWith(IHookrPairRoot.Params memory p, bytes memory data)
        internal
        returns (HookrPairRoot root, PoolKey memory key)
    {
        bytes32 salt = _mine(deployer, p);
        vm.prank(deployer);
        (address r,) = factory.deploy(salt, p, SQRT_ONE, data);
        root = HookrPairRoot(r);
        key = root.poolKey();
        _fund(key);
    }

    function _deployFee(IHookrFeeAdvisory.Config memory c, bool failOpen)
        internal
        returns (HookrPairRoot root, PoolKey memory key)
    {
        return _deployWith(_params(address(fee), ROOT_CAP, fee.MIN_PAIR_GAS(), failOpen), abi.encode(c));
    }

    function _deploySession(IHookrSessionAdvisory.Schedule memory s, bool failOpen)
        internal
        returns (HookrPairRoot root, PoolKey memory key)
    {
        return _deployWith(_params(address(session), SESSION_CAP, session.MIN_PAIR_GAS(), failOpen), abi.encode(s));
    }

    /// @dev Expects `deploy` to revert with `reason`, bubbled unchanged from the advisory's bindPair.
    function _expectDeployRevert(IHookrPairRoot.Params memory p, bytes memory data, bytes memory reason) internal {
        bytes32 salt = _mine(deployer, p);
        vm.prank(deployer);
        vm.expectRevert(reason);
        factory.deploy(salt, p, SQRT_ONE, data);
    }

    function _reprice(PoolId id, uint24 target, uint24 p0, uint24 p1, uint32 ttl) internal {
        vm.prank(keeper);
        fee.reprice(id, target, p0, p1, ttl);
    }

    /// @dev Asserts the view and executed swaps in both directions charge base plus the given surcharges.
    function _expectFee(PoolKey memory key, uint24 s0, uint24 s1) internal {
        PoolId id = key.toId();
        assertEq(fee.surcharge(id, true), s0, "view 0->1");
        assertEq(fee.surcharge(id, false), s1, "view 1->0");
        assertEq(_swapFee(key, true, -1e15, ""), BASE + s0, "swap 0->1");
        assertEq(_swapFee(key, false, -1e15, ""), BASE + s1, "swap 1->0");
    }

    /// @dev Unix time of a New York wall-clock instant; `dst` states the expected offset independently of the code.
    function _ny(uint256 y, uint256 m, uint256 d, uint256 h, uint256 mi, uint256 sec, bool dst)
        internal
        pure
        returns (uint256)
    {
        return
            HookrMarketCalendar.dayOf(y, m, d) * 1 days + h * 1 hours + mi * 1 minutes + sec + (dst ? 4 : 5) * 1 hours;
    }

    function _expectSession(HookrPairRoot root, PoolKey memory key, uint256 t, uint24 surcharge) internal {
        vm.warp(t);
        assertEq(session.surchargeAt(address(root), key.toId(), t), surcharge, "surchargeAt");
        assertEq(_swapFee(key, t % 2 == 0, -1e15, ""), BASE + surcharge, "executed LP fee");
    }

    function _surchargeForSwap(IHookrPairAdvisory module, address caller, PoolId id, bool zeroForOne, bytes memory data)
        internal
        returns (uint24)
    {
        vm.prank(caller);
        return module.surchargeForSwap(id, zeroForOne, -1e15, 1, data, address(router));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Fee advisory
    // ------------------------------------------------------------------------------------------------------------

    function test_fee_deployBindsOnce() public {
        IHookrFeeAdvisory.Config memory c = _cfg(1_500, 400, 100, 0);
        IHookrPairRoot.Params memory p = _params(address(fee), ROOT_CAP, fee.MIN_PAIR_GAS(), false);
        bytes32 salt = _mine(deployer, p);
        address predicted = factory.computeAddress(deployer, salt, p);
        PoolId id = PoolKey(p.currency0, p.currency1, 0x800000, 60, IHooks(predicted)).toId();
        bytes memory data = abi.encode(c);
        vm.expectEmit(true, true, true, true, address(fee));
        emit IHookrFeeAdvisory.PairBound(id, predicted, keccak256(data), data);
        vm.prank(deployer);
        factory.deploy(salt, p, SQRT_ONE, data);

        assertEq(fee.pairRoot(id), predicted);
        IHookrFeeAdvisory.Bounds memory b = fee.poolBounds(id);
        assertEq(b.cap, 1_500);
        assertEq(b.maxStep, 500);
        assertEq(b.minInterval, 60);
        assertEq(b.maxTtl, 1 hours);
        assertTrue(b.bound);
        assertTrue(b.pair);
        assertFalse(b.buyZeroForOne);
        IHookrFeeAdvisory.State memory s = fee.poolState(id);
        assertEq(s.default0, 500);
        assertEq(s.default1, 400);
        assertEq(s.guardCeiling, 0);
        assertEq(s.guardEnd, 0);
        assertTrue(s.bound);
    }

    /// Default premia, repricing up and down within the bounds, TTL expiry back to the defaults.
    function test_fee_lifecycle() public {
        (, PoolKey memory key) = _deployFee(_cfg(1_500, 400, 100, 0), false);
        PoolId id = key.toId();
        _expectFee(key, 500, 400);

        // Up: each direction moves at most maxStep from the default in force.
        _reprice(id, 800, 100, 50, 10 minutes);
        uint256 expiry = vm.getBlockTimestamp() + 10 minutes;
        assertEq(fee.poolState(id).expiry, expiry);
        _expectFee(key, 900, 850);

        // minInterval between updates.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.TooSoon.selector, vm.getBlockTimestamp() + 60));
        fee.reprice(id, 700, 0, 0, 10 minutes);
        vm.warp(vm.getBlockTimestamp() + 60);

        // Steps above maxStep and targets above the cap are refused.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.StepTooLarge.selector, 900, 1_401, 500));
        fee.reprice(id, 1_301, 100, 0, 10 minutes);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.AboveCap.selector, 1_501, 1_500));
        fee.reprice(id, 1_401, 100, 0, 10 minutes);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.InvalidTtl.selector, 1 hours + 1));
        fee.reprice(id, 900, 0, 0, 1 hours + 1);

        // Up to the cap, then down to the floor, one step at a time.
        _reprice(id, 1_300, 100, 0, 10 minutes);
        _expectFee(key, 1_400, 1_300);
        vm.warp(vm.getBlockTimestamp() + 60);
        _reprice(id, 1_300, 200, 200, 10 minutes);
        _expectFee(key, 1_500, 1_500);
        vm.warp(vm.getBlockTimestamp() + 60);
        _reprice(id, 1_000, 0, 0, 10 minutes);
        _expectFee(key, 1_000, 1_000);
        vm.warp(vm.getBlockTimestamp() + 60);
        _reprice(id, 500, 0, 0, 10 minutes);
        vm.warp(vm.getBlockTimestamp() + 60);
        _reprice(id, 0, 0, 0, 10 minutes);
        _expectFee(key, 0, 0);

        // TTL expiry: the defaults return without a keeper.
        vm.warp(fee.poolState(id).expiry - 1);
        _expectFee(key, 0, 0);
        vm.warp(fee.poolState(id).expiry);
        _expectFee(key, 500, 400);

        // Removing the keeper stops repricing; the defaults stay.
        fee.removeKeeper(keeper);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.NotKeeper.selector, keeper));
        fee.reprice(id, 400, 0, 0, 10 minutes);
        _expectFee(key, 500, 400);
    }

    /// Per-direction premia on the defaults and on a keeper target.
    function test_fee_directionPremium() public {
        IHookrFeeAdvisory.Config memory c = _cfg(2_000, 300, 0, 1_200);
        c.maxStep = 2_000;
        (, PoolKey memory key) = _deployFee(c, true);
        _expectFee(key, 300, 1_500);
        _reprice(key.toId(), 500, 400, 0, 5 minutes);
        _expectFee(key, 900, 500);
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        _expectFee(key, 300, 1_500);
    }

    function test_fee_rebindRefused() public {
        IHookrFeeAdvisory.Config memory c = _cfg(1_500, 400, 0, 0);
        (HookrPairRoot root, PoolKey memory key) = _deployFee(c, false);
        PoolId id = key.toId();

        // The root itself cannot bind its pool again.
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.AlreadyBound.selector, id));
        fee.bindPair(id, ROOT_CAP, 50_000, abi.encode(_cfg(2_000, 2_000, 0, 0)));

        // Nor can the factory open it again: the advisory refuses before the PoolManager does.
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.AlreadyBound.selector, id));
        root.open(SQRT_ONE, abi.encode(_cfg(2_000, 2_000, 0, 0)));

        assertEq(fee.poolBounds(id).cap, 1_500);
        _expectFee(key, 400, 400);
    }

    function test_fee_foreignCallersRefused() public {
        (HookrPairRoot root, PoolKey memory key) = _deployFee(_cfg(1_500, 400, 0, 0), false);
        PoolId id = key.toId();
        (Currency c0, Currency c1) = _erc();
        (HookrPairRoot other, PoolKey memory otherKey) = _deployWith(_advised(c0, c1, BASE, 1_000, false), "");
        bytes memory data = abi.encode(_cfg(1_000, 0, 0, 0));

        // Binding: an unregistered caller, and a registered root for a pool that is not its own.
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.NotRoot.selector, address(this)));
        fee.bindPair(id, ROOT_CAP, 50_000, data);
        vm.prank(address(other));
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.NotRoot.selector, address(other)));
        fee.bindPair(id, ROOT_CAP, 50_000, data);

        // Reading: only the root that bound the pool, and only for that pool.
        assertEq(_surchargeForSwap(fee, address(root), id, true, ""), 400);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.UnknownPool.selector, id));
        _surchargeForSwap(fee, address(other), id, true, "");
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.UnknownPool.selector, id));
        _surchargeForSwap(fee, address(this), id, true, "");
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.UnknownPool.selector, otherKey.toId()));
        _surchargeForSwap(fee, address(root), otherKey.toId(), true, "");

        // A root of a factory on another registry cannot bind: its deployment reverts whole.
        HookrRegistry registry2 = new HookrRegistry(address(this), manager, 1 days);
        HookrRootFactory factory2 = new HookrRootFactory(manager, IHookrFactoryRegistry(address(registry2)));
        _activateFactory(registry2, address(factory2));
        _admitPairAdvisory(registry2, address(factory2), address(fee));
        IHookrPairRoot.Params memory p = _params(address(fee), ROOT_CAP, 50_000, true);
        bytes32 salt = mineSalt(address(factory2), deployer, factory2.initCodeHash(p), 0);
        address predicted = factory2.computeAddress(deployer, salt, p);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.NotRoot.selector, predicted));
        factory2.deploy(salt, p, SQRT_ONE, data);
    }

    function test_fee_governanceRegisteredRootCannotBind() public {
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _params(address(fee), ROOT_CAP, fee.MIN_PAIR_GAS(), false);
        bytes32 salt = _mine(deployer, p);
        HookrPairRoot future = HookrPairRoot(factory.computeAddress(deployer, salt, p));
        PoolKey memory futureKey =
            PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, p.tickSpacing, IHooks(address(future)));
        PoolId id = futureKey.toId();
        GovernedPairImpostor impostor = new GovernedPairImpostor(manager, IHookrRegistry(address(registry)), id);
        registry.queue(registry.REGISTER_ROOT(), abi.encode(address(impostor), address(impostor).codehash));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.registerRoot(address(impostor), address(impostor).codehash);
        assertTrue(registry.isRoot(address(impostor)));

        // A root the owner registered directly is not a factory root, so it cannot claim a pair pool's slot.
        uint32 gasLimit = fee.MIN_PAIR_GAS();
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.NotRoot.selector, address(impostor)));
        impostor.bind(fee, ROOT_CAP, gasLimit, abi.encode(_cfg(1_000, 0, 0, 0)));
        assertEq(fee.pairRoot(id), address(0));

        // The genuine pair root for that pool still deploys and binds.
        vm.prank(deployer);
        factory.deploy(salt, p, SQRT_ONE, abi.encode(_cfg(1_500, 400, 0, 0)));
        assertEq(fee.pairRoot(id), address(future));
    }

    function test_fee_bindValidation() public {
        IHookrPairRoot.Params memory p = _params(address(fee), ROOT_CAP, fee.MIN_PAIR_GAS(), false);
        bytes memory invalid = abi.encodeWithSelector(IHookrFeeAdvisory.InvalidConfig.selector);
        IHookrFeeAdvisory.Config[8] memory bad = [
            _cfg(ROOT_CAP + 1, 0, 0, 0),
            _cfg(0, 0, 0, 0),
            _cfg(1_000, 900, 101, 0),
            _cfg(1_000, 900, 0, 101),
            _cfg(1_000, 0, 0, 0),
            _cfg(1_000, 0, 0, 0),
            _cfg(1_000, 0, 0, 0),
            _cfg(1_000, 0, 0, 0)
        ];
        bad[4].maxStep = 0;
        bad[5].minInterval = 0;
        bad[6].maxTtl = fee.MAX_TTL() + 1;
        bad[7].minInterval = fee.MAX_MIN_INTERVAL() + 1;
        for (uint256 i; i < bad.length; ++i) {
            _expectDeployRevert(p, abi.encode(bad[i]), invalid);
        }
        IHookrFeeAdvisory.Config memory zeroTtl = _cfg(1_000, 0, 0, 0);
        zeroTtl.maxTtl = 0;
        _expectDeployRevert(p, abi.encode(zeroTtl), invalid);
        // Non-canonical encoding and a gas limit below the advisory's minimum.
        _expectDeployRevert(p, abi.encodePacked(abi.encode(_cfg(1_000, 0, 0, 0)), uint256(0)), invalid);
        _expectDeployRevert(p, "", "");
        p.advisoryGasLimit = fee.MIN_PAIR_GAS() - 1;
        _expectDeployRevert(p, abi.encode(_cfg(1_000, 0, 0, 0)), invalid);
        // The cap may equal the root's cap.
        p.advisoryGasLimit = fee.MIN_PAIR_GAS();
        (, PoolKey memory key) = _deployWith(p, abi.encode(_cfg(ROOT_CAP, ROOT_CAP, 0, 0)));
        _expectFee(key, ROOT_CAP, ROOT_CAP);
    }

    /// A pair root binds minInterval from 1 second to MAX_MIN_INTERVAL (1 day) inclusive.
    function test_fee_bindMinIntervalBounds() public {
        bytes memory invalid = abi.encodeWithSelector(IHookrFeeAdvisory.InvalidConfig.selector);
        uint32 max = fee.MAX_MIN_INTERVAL();
        uint32[4] memory accepted = [uint32(1), 2, max - 1, max];
        for (uint256 i; i < accepted.length; ++i) {
            IHookrPairRoot.Params memory p = _params(address(fee), ROOT_CAP, fee.MIN_PAIR_GAS(), false);
            p.baseLpFeePips = BASE + uint24(i) + 1; // a distinct pool per bind
            p.maxLpFeePips = p.baseLpFeePips + ROOT_CAP;
            IHookrFeeAdvisory.Config memory c = _cfg(1_000, 0, 0, 0);
            c.minInterval = accepted[i];
            if (i == 0) {
                c.minInterval = 0;
                _expectDeployRevert(p, abi.encode(c), invalid);
                c.minInterval = max + 1;
                _expectDeployRevert(p, abi.encode(c), invalid);
                c.minInterval = accepted[i];
            }
            (HookrPairRoot root,) = _deployWith(p, abi.encode(c));
            assertEq(fee.poolBounds(root.poolId()).minInterval, accepted[i]);
        }
    }

    /// Whatever the frozen bounds and the keeper's updates, the surcharge stays within the config cap, which is
    /// within the root's cap, and surchargeForSwap does not revert.
    function testFuzz_fee_withinRootCap(uint24 cap, uint24 surcharge, uint24 p0, uint24 p1, uint256 seed) public {
        cap = uint24(bound(cap, 1, ROOT_CAP));
        surcharge = uint24(bound(surcharge, 0, cap));
        p0 = uint24(bound(p0, 0, cap - surcharge));
        p1 = uint24(bound(p1, 0, cap - surcharge));
        IHookrFeeAdvisory.Config memory c = _cfg(cap, surcharge, p0, p1);
        c.maxStep = uint24(bound(seed, 1, cap));
        (HookrPairRoot root, PoolKey memory key) = _deployFee(c, false);
        PoolId id = key.toId();
        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + 60 + (seed % 2 hours));
            vm.prank(keeper);
            try fee.reprice(id, uint24(seed >> 32), uint24(seed >> 64) % 500, uint24(seed >> 96) % 500, 30 minutes) {}
                catch {}
            vm.prank(keeper);
            try fee.reprice(id, uint24((seed >> 128) % (uint256(cap) + 1)), 0, 0, 30 minutes) {} catch {}
            assertLe(_surchargeForSwap(fee, address(root), id, true, ""), cap);
            assertLe(_surchargeForSwap(fee, address(root), id, false, ""), cap);
        }
        assertLe(_swapFee(key, seed % 2 == 0, -1e15, ""), BASE + cap);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Session advisory
    // ------------------------------------------------------------------------------------------------------------

    function test_session_deployBindsUnderRoot() public {
        (HookrPairRoot root, PoolKey memory key) = _deploySession(_schedule(0, 0, 0), false);
        IHookrSessionAdvisory.Bound memory b = session.schedule(address(root), key.toId());
        assertTrue(b.bound);
        assertEq(b.regularPips, REGULAR);
        assertEq(b.closedPips, CLOSED);
        assertEq(b.limit, SESSION_CAP);
        assertEq(b.guardLimit, SESSION_CAP);
        assertEq(b.guardEnd, 0);
        assertFalse(session.schedule(address(factory), key.toId()).bound);
    }

    /// Session tiers on known dates, as executed swaps: a regular Tuesday, Thanksgiving and its early close.
    function test_session_tiersOnKnownDates() public {
        (HookrPairRoot root, PoolKey memory key) = _deploySession(_schedule(0, 0, 0), false);
        // Tuesday 2026-09-29.
        _expectSession(root, key, _ny(2026, 9, 29, 3, 59, 59, true), NIGHT);
        _expectSession(root, key, _ny(2026, 9, 29, 4, 0, 0, true), PRE);
        _expectSession(root, key, _ny(2026, 9, 29, 9, 29, 59, true), PRE);
        _expectSession(root, key, _ny(2026, 9, 29, 9, 30, 0, true), REGULAR);
        _expectSession(root, key, _ny(2026, 9, 29, 15, 59, 59, true), REGULAR);
        _expectSession(root, key, _ny(2026, 9, 29, 16, 0, 0, true), AFTER);
        _expectSession(root, key, _ny(2026, 9, 29, 20, 0, 0, true), NIGHT);
        // Weekend 2026-10-03, and the Friday evening before it.
        _expectSession(root, key, _ny(2026, 10, 2, 20, 0, 0, true), CLOSED);
        _expectSession(root, key, _ny(2026, 10, 3, 12, 0, 0, true), CLOSED);
        // Thanksgiving 2026-11-26 and the 13:00 early close on 2026-11-27.
        _expectSession(root, key, _ny(2026, 11, 25, 19, 59, 59, false), AFTER);
        _expectSession(root, key, _ny(2026, 11, 25, 20, 0, 0, false), CLOSED);
        _expectSession(root, key, _ny(2026, 11, 26, 12, 0, 0, false), CLOSED);
        _expectSession(root, key, _ny(2026, 11, 26, 20, 0, 0, false), NIGHT);
        _expectSession(root, key, _ny(2026, 11, 27, 12, 59, 59, false), REGULAR);
        _expectSession(root, key, _ny(2026, 11, 27, 13, 0, 0, false), AFTER);
        _expectSession(root, key, _ny(2026, 11, 27, 17, 0, 0, false), CLOSED);
    }

    function test_session_ramps() public {
        (HookrPairRoot root, PoolKey memory key) = _deploySession(_schedule(1_800, 1_800, 0), false);
        _expectSession(root, key, _ny(2026, 9, 29, 9, 30, 0, true), PRE);
        _expectSession(root, key, _ny(2026, 9, 29, 9, 45, 0, true), (PRE + REGULAR) / 2);
        _expectSession(root, key, _ny(2026, 9, 29, 10, 0, 0, true), REGULAR);
        _expectSession(root, key, _ny(2026, 9, 29, 15, 45, 0, true), (REGULAR + AFTER) / 2);
    }

    function test_session_rebindRefused() public {
        (HookrPairRoot root, PoolKey memory key) = _deploySession(_schedule(0, 0, 0), false);
        PoolId id = key.toId();
        IHookrSessionAdvisory.Schedule memory zero;
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrSessionAdvisory.AlreadyBound.selector, address(root), id));
        session.bindPair(id, SESSION_CAP, 60_000, abi.encode(zero));
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(IHookrSessionAdvisory.AlreadyBound.selector, address(root), id));
        root.open(SQRT_ONE, abi.encode(zero));
        _expectSession(root, key, _ny(2026, 9, 29, 11, 0, 0, true), REGULAR);
    }

    /// A caller reads and binds only its own entries: a stranger binding the same pool id under its own address
    /// changes nothing for the root, and reads by anyone else revert.
    function test_session_foreignCallersRefused() public {
        (HookrPairRoot root, PoolKey memory key) = _deploySession(_schedule(0, 0, 0), false);
        PoolId id = key.toId();
        IHookrSessionAdvisory.Schedule memory zero;
        address stranger = address(0x5EE);
        vm.prank(stranger);
        session.bindPair(id, SESSION_CAP, 60_000, abi.encode(zero));
        assertEq(_surchargeForSwap(session, stranger, id, true, ""), 0);
        assertEq(_surchargeForSwap(session, address(root), id, true, ""), REGULAR);
        _expectSession(root, key, _ny(2026, 9, 29, 11, 0, 0, true), REGULAR);

        vm.expectRevert(abi.encodeWithSelector(IHookrSessionAdvisory.UnknownPool.selector, address(this), id));
        _surchargeForSwap(session, address(this), id, true, "");
        PoolId otherId = PoolId.wrap(bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(IHookrSessionAdvisory.UnknownPool.selector, address(root), otherId));
        _surchargeForSwap(session, address(root), otherId, true, "");
    }

    function test_session_bindValidation() public {
        IHookrPairRoot.Params memory p = _params(address(session), SESSION_CAP, session.MIN_PAIR_GAS(), false);
        IHookrSessionAdvisory.Schedule memory s = _schedule(0, 0, 0);
        s.closedPips = SESSION_CAP + 1;
        _expectDeployRevert(p, abi.encode(s), abi.encodeWithSelector(IHookrSessionAdvisory.InvalidSchedule.selector, 3));
        _expectDeployRevert(
            p, abi.encode(_schedule(0, 0, 2)), abi.encodeWithSelector(IHookrSessionAdvisory.InvalidSchedule.selector, 1)
        );
        _expectDeployRevert(
            p,
            abi.encode(_schedule(12_600, 1, 0)),
            abi.encodeWithSelector(IHookrSessionAdvisory.InvalidSchedule.selector, 2)
        );
        _expectDeployRevert(p, "", abi.encodeWithSelector(IHookrSessionAdvisory.InvalidSchedule.selector, 0));
        p.advisoryGasLimit = session.MIN_PAIR_GAS() - 1;
        _expectDeployRevert(
            p,
            abi.encode(_schedule(0, 0, 0)),
            abi.encodeWithSelector(IHookrSessionAdvisory.InvalidPoolConfig.selector, 2)
        );
    }

    /// The heaviest calendar path (an appended year, the evening before a closure, ramps, the uncovered flag) runs
    /// inside MIN_PAIR_GAS with a large hookData, on a fail-closed root.
    function test_session_worstCaseFitsMinimumGas() public {
        uint16[] memory closed = new uint16[](2);
        (closed[0], closed[1]) = (uint16(1127), uint16(1225));
        uint16[] memory early = new uint16[](1);
        early[0] = 1128;
        session.queue(session.APPEND_YEAR(), abi.encode(uint16(2031), closed, early));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        session.appendYear(2031, closed, early);
        (HookrPairRoot root, PoolKey memory key) =
            _deploySession(_schedule(1_800, 1_800, session.UNCOVERED_AS_CLOSED()), false);
        bytes memory big = new bytes(8_192);
        uint256[5] memory times = [
            _ny(2031, 11, 26, 21, 0, 0, false),
            _ny(2031, 11, 28, 12, 50, 0, false),
            _ny(2031, 12, 31, 21, 0, 0, false),
            _ny(2032, 3, 3, 11, 0, 0, false),
            _ny(2031, 3, 4, 9, 40, 0, false)
        ];
        uint256 worst;
        for (uint256 i; i < times.length; ++i) {
            vm.warp(times[i]);
            vm.cool(address(session));
            vm.prank(address(root));
            session.surchargeForSwap(key.toId(), true, -1e15, 1, big, address(router));
            uint256 used = vm.lastCallGas().gasTotalUsed;
            if (used > worst) worst = used;
            _swap(key, i % 2 == 0, -1e15, big);
        }
        console2.log("session surchargeForSwap worst cold gas", worst);
        assertLt(worst, session.MIN_PAIR_GAS() / 2);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Dispatch order
    // ------------------------------------------------------------------------------------------------------------

    /// `surchargeForSwap` has the lowest selector of every external function in both modules, so the via-IR
    /// dispatcher, which compares selectors in ascending order, matches it first.
    function test_dispatch_surchargeForSwapSortsFirst() public view {
        bytes4 first = IHookrPairAdvisory.surchargeForSwap.selector;
        assertEq(first, bytes4(0x00014e05));
        string[2] memory artifacts = [
            "out/HookrFeeAdvisory.sol/HookrFeeAdvisory.json", "out/HookrSessionAdvisory.sol/HookrSessionAdvisory.json"
        ];
        for (uint256 a; a < artifacts.length; ++a) {
            string[] memory sigs = vm.parseJsonKeys(vm.readFile(artifacts[a]), ".methodIdentifiers");
            assertGt(sigs.length, 1);
            bool found;
            for (uint256 i; i < sigs.length; ++i) {
                bytes4 s = bytes4(keccak256(bytes(sigs[i])));
                if (s == first) found = true;
                else assertGt(uint32(s), uint32(first), sigs[i]);
            }
            assertTrue(found, artifacts[a]);
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Root behaviour with the real modules
    // ------------------------------------------------------------------------------------------------------------

    /// With a bound pool the root never takes a failure path: fail-open and fail-closed roots at the minimum gas
    /// limit charge the module's value, never the cap and never a revert, whatever the hookData size.
    function test_failModes_boundModuleNeverFails() public {
        bytes memory big = new bytes(8_192);
        for (uint256 failOpen; failOpen < 2; ++failOpen) {
            (HookrPairRoot root, PoolKey memory key) = _deployFee(_cfg(1_500, 250, 0, 50), failOpen == 1);
            vm.cool(address(fee));
            vm.prank(address(root));
            fee.surchargeForSwap(key.toId(), true, -1e15, 1, big, address(router));
            uint256 used = vm.lastCallGas().gasTotalUsed;
            console2.log("fee surchargeForSwap cold gas", used);
            assertLt(used, fee.MIN_PAIR_GAS() / 2);
            assertEq(_swapFee(key, true, -1e15, big), BASE + 250);
            assertEq(_swapFee(key, false, -1e15, big), BASE + 300);
            (root, key) = _deploySession(_schedule(0, 0, 0), failOpen == 1);
            assertEq(_swapFee(key, true, -1e15, big), BASE + REGULAR);
        }
    }

    /// When the module does fail, the root's immutable choice applies: fail-open charges the root's cap, fail-closed
    /// reverts the swap.
    function test_failModes_moduleFailure() public {
        (HookrPairRoot closedRoot, PoolKey memory closedKey) = _deployFee(_cfg(1_500, 250, 0, 0), false);
        (, PoolKey memory openKey) = _deployFee(_cfg(1_500, 250, 0, 0), true);
        vm.mockCallRevert(address(fee), abi.encodeWithSelector(IHookrPairAdvisory.surchargeForSwap.selector), "down");
        assertEq(_swapFee(openKey, true, -1e15, ""), BASE + ROOT_CAP);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(closedRoot),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IHookrPairRoot.AdvisoryFailed.selector, address(fee)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _swap(closedKey, true, -1e15, "");
        vm.clearMockedCalls();
        assertEq(_swapFee(closedKey, true, -1e15, ""), BASE + 250);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Root and factory binding
    // ------------------------------------------------------------------------------------------------------------

    function test_open_bindsAdvisoryWithRootImmutables() public {
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _advised(c0, c1, BASE, 1_000, true);
        (HookrPairRoot root, PoolKey memory key) = _deployWith(p, bytes(hex"c0ffee"));
        assertEq(
            advisory.lastBind(),
            abi.encode(address(root), key.toId(), uint24(1_000), uint32(50_000), bytes(hex"c0ffee"))
        );
        assertTrue(registry.isRoot(address(root)));
    }

    function test_open_refusesUnacknowledgedBinding() public {
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _advised(c0, c1, BASE, 1_000, true);
        advisory.setBindReply(bytes4(0xdeadbeef));
        _expectDeployRevert(p, "", abi.encodeWithSelector(IHookrPairRoot.AdvisoryRefused.selector, address(advisory)));
    }

    function test_open_refusesDataWithoutAdvisory() public {
        (Currency c0, Currency c1) = _erc();
        _expectDeployRevert(
            _plain(c0, c1, BASE), hex"01", abi.encodeWithSelector(IHookrPairRoot.InvalidParams.selector)
        );
    }
}
