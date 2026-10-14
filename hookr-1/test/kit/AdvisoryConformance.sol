// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrRootFactory} from "../../src/factory/HookrRootFactory.sol";
import {HookrPairRoot} from "../../src/factory/HookrPairRoot.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {IHookrPairAdvisory} from "../../src/interfaces/IHookrPairAdvisory.sol";
import {IHookrFactoryRegistry} from "../../src/interfaces/IHookrRootFactory.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {PairTestRouter} from "../factory/PairRootFixture.sol";
import {mineSalt} from "../../script/HookrPairRootSalt.s.sol";
import {ExecutorAdmission} from "./ExecutorAdmission.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @title AdvisoryConformance
/// @notice Conformance suite for a third-party fee advisory, run against a real HookrRoot (with HookrRules, the
///         launcher, router and quoter) and a real HookrPairRoot deployed through HookrRootFactory, on one
///         PoolManager and one HookrRegistry.
/// @dev Inherit it, implement `_kitDeploy`, `_kitRootData`, `_kitPairData` and `_kitArtifact`, and override the
///      other `_kit*` hooks where the defaults do not fit. Every check is a `test_kit_*` or `testFuzz_kit_*`
///      function of this contract; an advisory that serves only one root kind returns false from
///      `_kitSupportsRoot` or `_kitSupportsPair`, and that kind's checks are skipped.
///
///      The suite admits the advisory on the HookrRoot as a fee-only, fail-open-capable ADVISORY with the cap, gas
///      limit and phases the hooks return, launches one fail-closed and one fail-open pool on it, admits it for the
///      kit's root factory with the pair roots' cap and gas limit, as the registry requires before the factory deploys
///      a pair root naming it, and deploys one fail-closed and one fail-open pair root bound to it. It then checks,
///      per root kind:
///      - bind: the advisory accepts the pool once, from the real root, and refuses a second bind of it.
///      - return sizes: every function a root calls returns exactly the words the root requires (surchargeForSwap
///        exactly 32 bytes, beforeSwap and afterSwap exactly 128), each word in range.
///      - cap: over fuzzed swaps and times, the surcharge never exceeds the cap the advisory was given.
///      - gas: in the author's worst-case state, with the advisory's account and storage cold, the call succeeds
///        with exactly the pool's gas limit, and a swap on the fail-closed pool fills.
///      - fail-open: when the advisory reverts, a fail-open pool charges the cap and a fail-closed pool reverts.
///      - declarations: the build artifact exposes every selector of the interface the root calls, the declared
///        phases are the admitted ones, an after-phase advice never moves the LP fee, and the runtime holds no
///        DELEGATECALL, CALLCODE or SELFDESTRUCT and no EIP-7702 delegation designator.
///      - launch buy: a new-token launch's dev buy, an unauthenticated buy sent by the launcher, gets advice within
///        the cap and fills on a fail-closed pool.
abstract contract AdvisoryConformance is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 internal constant KIT_SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    /// @notice Base LP fee of the kit's pair roots, in pips.
    uint24 internal constant KIT_PAIR_BASE = 3_000;
    /// @notice The selector the pair root calls on every swap.
    bytes4 internal constant KIT_SURCHARGE_SELECTOR = 0x00014e05;

    /// @notice The advisory under test.
    address internal kitAdvisory;
    /// @notice A fail-closed and a fail-open HookrRoot pool bound to the advisory.
    PoolKey internal kitRootKey;
    PoolKey internal kitRootOpenKey;
    /// @notice The kit's root factory, its pair-pool router and the fail-closed and fail-open pair roots.
    HookrRootFactory internal kitFactory;
    PairTestRouter internal kitPairRouter;
    HookrPairRoot internal kitPair;
    HookrPairRoot internal kitPairOpen;
    PoolKey internal kitPairKey;
    PoolKey internal kitPairOpenKey;
    HookrToken internal kitSubject2;

    // ------------------------------------------------------------------------------------------------------------
    // Author hooks
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Deploys the advisory and runs any setup it needs (keepers, calendars, clocks). `registry`, `root`
    ///         and `manager` already exist.
    function _kitDeploy() internal virtual returns (address advisory);

    /// @notice The bind data of a HookrRoot pool, under an admitted LP-fee cap of `_kitRootCapPips()`.
    function _kitRootData() internal virtual returns (bytes memory);

    /// @notice The bind data of a pair root whose immutable advisory cap is `capPips`.
    function _kitPairData(uint24 capPips) internal virtual returns (bytes memory);

    /// @notice Path of the advisory's build artifact under the project root, such as
    ///         `out/MyAdvisory.sol/MyAdvisory.json`.
    function _kitArtifact() internal view virtual returns (string memory);

    /// @notice Whether the advisory serves HookrRoot pools.
    function _kitSupportsRoot() internal view virtual returns (bool) {
        return true;
    }

    /// @notice Whether the advisory serves pair roots.
    function _kitSupportsPair() internal view virtual returns (bool) {
        return true;
    }

    /// @notice The LP-fee cap the advisory is admitted with on the HookrRoot, in pips.
    function _kitRootCapPips() internal view virtual returns (uint24) {
        return 50_000;
    }

    /// @notice The gas limit the advisory is admitted and bound with on the HookrRoot. The root forwards it to
    ///         `bind` as well as to every swap-path call, so it must cover the bind's storage writes.
    function _kitRootGasLimit() internal view virtual returns (uint32);

    /// @notice The phases the advisory declares on the HookrRoot: HookrTypes.BEFORE_SWAP, AFTER_SWAP or both.
    function _kitRootPhases() internal view virtual returns (uint8) {
        return HookrTypes.BEFORE_SWAP;
    }

    /// @notice The pair roots' immutable advisory cap, in pips.
    function _kitPairCapPips() internal view virtual returns (uint24) {
        return 2_000;
    }

    /// @notice The pair roots' advisory gas limit. Use the advisory's own floor.
    function _kitPairGasLimit() internal view virtual returns (uint32);

    /// @notice Moves the advisory into its most expensive and highest-surcharge state for the pool `id` bound by
    ///         `binder`, such as a keeper target at the cap or the heaviest calendar branch.
    function _kitWorstCase(address binder, PoolId id) internal virtual {}

    /// @notice Marks every account the advisory reads on a swap cold before a gas check. The default cools the
    ///         advisory; override it to also cool what the advisory calls, such as a shared calendar.
    function _kitCold() internal virtual {
        vm.cool(kitAdvisory);
    }

    /// @notice Moves the advisory to a state picked by `seed` for the pool `id` bound by `binder`. The default
    ///         advances the clock by up to 8 days.
    function _kitStress(address binder, PoolId id, uint256 seed) internal virtual {
        binder;
        id;
        vm.warp(vm.getBlockTimestamp() + seed % 8 days);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------------------------

    function setUp() public virtual {
        _setUpPeriphery();
        kitAdvisory = _kitDeploy();
        if (_kitSupportsRoot()) _kitSetUpRoot();
        if (_kitSupportsPair()) _kitSetUpPair();
    }

    function _kitSetUpRoot() private {
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: kitAdvisory,
            codeHash: kitAdvisory.codehash,
            schemaHash: IHookrAdvisory(kitAdvisory).configSchemaHash(),
            caps: HookrTypes.Caps(_kitRootCapPips(), 0, 0),
            gasLimit: _kitRootGasLimit(),
            phaseMask: _kitRootPhases(),
            feeOnly: true,
            failOpen: true
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        kitSubject2 = new HookrToken("Kit Subject", "KS", 1e30, address(this));
        kitSubject2.approve(address(launcher), type(uint256).max);
        kitRootKey = _kitLaunch(tokenA, false);
        kitRootOpenKey = _kitLaunch(kitSubject2, true);
    }

    function _kitLaunch(HookrToken subject, bool failOpen) private returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[0].config.advisory = kitAdvisory;
        members[0].config.advisoryGasLimit = _kitRootGasLimit();
        members[0].config.advisoryPhases = _kitRootPhases();
        members[0].config.advisoryFailOpen = failOpen;
        bytes[] memory configs = new bytes[](1);
        configs[0] = _kitRootData();
        (bytes32 family,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function _kitSetUpPair() private {
        kitFactory = new HookrRootFactory(manager, IHookrFactoryRegistry(address(registry)));
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(address(kitFactory), address(kitFactory).codehash, true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setRootFactory(address(kitFactory), address(kitFactory).codehash, true);
        IHookrRegistry.Admission memory a = _kitPairAdmission();
        registry.queue(registry.ADMIT(), abi.encode(address(kitFactory), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(kitFactory), a);
        kitPairRouter = new PairTestRouter(manager);
        tokenA.approve(address(kitPairRouter), type(uint256).max);
        tokenB.approve(address(kitPairRouter), type(uint256).max);
        vm.startPrank(trader);
        tokenA.approve(address(kitPairRouter), type(uint256).max);
        tokenB.approve(address(kitPairRouter), type(uint256).max);
        vm.stopPrank();
        (kitPair, kitPairKey) = _kitDeployPair(false);
        (kitPairOpen, kitPairOpenKey) = _kitDeployPair(true);
    }

    /// @notice The advisory's admission for the kit's root factory: kind ADVISORY pinned to its runtime codehash, the
    ///         pair roots' cap, their gas limit or the registry's 25,000 floor, whichever is higher, and fee-only and
    ///         fail-open, which the factory requires for the kit's fail-open pair root.
    function _kitPairAdmission() internal view returns (IHookrRegistry.Admission memory) {
        uint32 gasLimit = _kitPairGasLimit();
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: kitAdvisory,
            codeHash: kitAdvisory.codehash,
            schemaHash: keccak256("hookr.pair.advisory"),
            caps: HookrTypes.Caps(_kitPairCapPips(), 0, 0),
            gasLimit: gasLimit < 25_000 ? 25_000 : gasLimit,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: true
        });
    }

    function _kitPairParams(bool failOpen) internal view returns (IHookrPairRoot.Params memory p) {
        (address a, address b) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        p.currency0 = Currency.wrap(a);
        p.currency1 = Currency.wrap(b);
        p.tickSpacing = failOpen ? int24(120) : int24(60);
        p.baseLpFeePips = KIT_PAIR_BASE;
        p.maxLpFeePips = KIT_PAIR_BASE + _kitPairCapPips();
        p.advisory = kitAdvisory;
        p.advisoryCapPips = _kitPairCapPips();
        p.advisoryGasLimit = _kitPairGasLimit();
        p.advisoryFailOpen = failOpen;
    }

    function _kitDeployPair(bool failOpen) private returns (HookrPairRoot pair, PoolKey memory key) {
        IHookrPairRoot.Params memory p = _kitPairParams(failOpen);
        bytes32 salt = mineSalt(address(kitFactory), address(this), kitFactory.initCodeHash(p), 0);
        (address r,) = kitFactory.deploy(salt, p, SQRT_ONE, _kitPairData(p.advisoryCapPips));
        pair = HookrPairRoot(r);
        key = pair.poolKey();
        kitPairRouter.modify(
            key, ModifyLiquidityParams({tickLower: -6_000, tickUpper: 6_000, liquidityDelta: 1e21, salt: 0})
        );
    }

    // ------------------------------------------------------------------------------------------------------------
    // HookrRoot
    // ------------------------------------------------------------------------------------------------------------

    /// @notice The real root bound both pools, with the declared phases, and the advisory refuses a second bind.
    function test_kit_root_bindsOnce() public {
        if (_kitSkip(_kitSupportsRoot())) return;
        PoolKey[2] memory keys = [kitRootKey, kitRootOpenKey];
        for (uint256 i; i < keys.length; ++i) {
            HookrTypes.PoolConfig memory pc = root.poolConfig(keys[i].toId());
            assertEq(pc.advisory, kitAdvisory, "advisory");
            assertEq(pc.advisoryPhases, _kitRootPhases(), "phases");
            assertEq(pc.advisoryFailOpen, i == 1, "fail mode");
            (uint160 price,,,) = manager.getSlot0(keys[i].toId());
            assertGt(price, 0, "pool open");
            vm.prank(address(root));
            (bool ok,) = kitAdvisory.call(abi.encodeCall(IHookrAdvisory.bind, (keys[i], pc, _kitRootData())));
            assertFalse(ok, "second bind accepted");
        }
    }

    /// @notice Every function the root calls returns exactly the size the root requires, each word in range.
    function test_kit_root_returnSizes() public {
        if (_kitSkip(_kitSupportsRoot())) return;
        IHookrRegistry.Admission memory a = registry.admission(address(root), kitAdvisory);
        bytes memory out = _kitStatic(address(this), abi.encodeCall(IHookrAdvisory.configSchemaHash, ()), 32, 0);
        assertEq(abi.decode(out, (bytes32)), a.schemaHash, "schema");
        out = _kitStatic(
            address(root), abi.encodeCall(IHookrAdvisory.beforeAddLiquidity, (kitRootKey.toId(), trader)), 32, 0
        );
        assertLe(uint256(bytes32(out)), 1, "bool");
        for (uint256 i; i < 4; ++i) {
            HookrTypes.SwapContext memory x = _kitContext(kitRootKey, i & 1 == 0, i & 2 == 0, 1e18);
            _kitAdviceWords(_kitStatic(address(root), abi.encodeCall(IHookrAdvisory.beforeSwap, (x)), 128, 0));
            if (_kitRootPhases() & HookrTypes.AFTER_SWAP != 0) {
                _kitAdviceWords(
                    _kitStatic(address(root), abi.encodeCall(IHookrAdvisory.afterSwap, (x, -1e18, 1e18)), 128, 0)
                );
            }
        }
    }

    /// @notice Over fuzzed swaps and states, advice stays within the admitted caps, never rejects and never takes
    ///         quote, and the root quotes the swap within the pool cap.
    function testFuzz_kit_root_surchargeWithinCap(uint256 seed, bool isBuy, bool exactInput, uint64 amount) public {
        if (_kitSkip(_kitSupportsRoot())) return;
        uint128 size = uint128(bound(amount, 1e9, 1e18));
        _kitStress(address(root), kitRootKey.toId(), seed);
        HookrTypes.SwapContext memory x = _kitContext(kitRootKey, isBuy, exactInput, size);
        vm.prank(address(root));
        HookrTypes.Advice memory advice = IHookrAdvisory(kitAdvisory).beforeSwap(x);
        assertLe(advice.lpFeeSurchargePips, _kitRootCapPips(), "surcharge above cap");
        assertEq(advice.quoteTakePips, 0, "quote take");
        assertFalse(advice.reject, "reject");
        if (_kitRootPhases() & HookrTypes.AFTER_SWAP != 0) {
            vm.prank(address(root));
            advice = IHookrAdvisory(kitAdvisory).afterSwap(x, -int128(size), int128(size));
            assertEq(advice.lpFeeSurchargePips, 0, "after-phase LP fee");
            assertEq(advice.quoteTakePips, 0, "after-phase quote take");
            assertFalse(advice.reject, "after-phase reject");
        }
        uint256 lpFee = quoter.quote(_swap(kitRootKey, isBuy, exactInput, size), trader).lpFeePips;
        assertLe(lpFee, root.poolConfig(kitRootKey.toId()).caps.maxLpFeePips, "pool cap");
    }

    /// @notice In the worst-case state, cold, the advisory answers within the pool's gas limit, and the fail-closed
    ///         pool trades both ways.
    function test_kit_root_gasAtCap() public {
        if (_kitSkip(_kitSupportsRoot())) return;
        _kitWorstCase(address(root), kitRootKey.toId());
        uint256 limit = _kitRootGasLimit();
        for (uint256 i; i < 2; ++i) {
            HookrTypes.SwapContext memory x = _kitContext(kitRootKey, i == 0, true, 1e18);
            _kitCold();
            uint256 used = _kitGas(address(root), abi.encodeCall(IHookrAdvisory.beforeSwap, (x)), 128, limit);
            console2.log("kit root beforeSwap cold gas", used);
        }
        vm.startPrank(trader);
        router.swap(_swap(kitRootKey, true, true, 1e18), address(0), new uint256[](0));
        router.swap(_swap(kitRootKey, false, true, 1e18), address(0), new uint256[](0));
        vm.stopPrank();
    }

    /// @notice When the advisory reverts, the fail-open pool charges the admitted cap within the pool's room and
    ///         the fail-closed pool reverts the swap with the advisory's reason inside ModuleCallReverted.
    function test_kit_root_failOpen() public {
        if (_kitSkip(_kitSupportsRoot())) return;
        IHookrRouter.Swap memory p = _swap(kitRootOpenKey, true, true, 1e18);
        vm.mockCall(
            kitAdvisory,
            abi.encodeWithSelector(IHookrAdvisory.beforeSwap.selector),
            abi.encode(HookrTypes.Advice(0, 0, address(0), false))
        );
        uint256 native = quoter.quote(p, trader).lpFeePips;
        vm.clearMockedCalls();
        vm.mockCallRevert(kitAdvisory, abi.encodeWithSelector(IHookrAdvisory.beforeSwap.selector), "down");
        uint256 capLp = root.poolConfig(kitRootOpenKey.toId()).caps.maxLpFeePips;
        uint256 room = capLp - native;
        uint256 expected = native + (_kitRootCapPips() < room ? _kitRootCapPips() : room);
        assertEq(quoter.quote(p, trader).lpFeePips, expected, "fail-open charge");
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
        IHookrRouter.Swap memory closed = _swap(kitRootKey, true, true, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(root),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(
                    IHookrRootEvents.ModuleCallReverted.selector,
                    kitAdvisory,
                    IHookrAdvisory.beforeSwap.selector,
                    bytes("down")
                ),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(trader);
        router.swap(closed, address(0), new uint256[](0));
    }

    /// @notice A launch's dev buy reaches the advisory as an unauthenticated exact-input buy sent by the launcher, with
    ///         payer and beneficiary the launcher. Its advice stays within the cap without a reject or a quote take, and
    ///         HookrLauncher.launchWithBuy fills on a fail-closed pool bound to the advisory.
    function test_kit_root_launchBuy() public {
        if (_kitSkip(_kitSupportsRoot())) return;
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Kit Dev", "KDEV", 1e24, keccak256("kit.dev"));
        address subject = launcher.predictToken(address(this), t);
        bool subjectIs0 = subject < address(tokenB);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[0].tickLower = subjectIs0 ? int24(0) : int24(-60_000);
        members[0].tickUpper = subjectIs0 ? int24(60_000) : int24(0);
        uint160 lower = TickMath.getSqrtPriceAtTick(members[0].tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(members[0].tickUpper);
        uint128 liquidity = subjectIs0
            ? LiquidityAmounts.getLiquidityForAmount0(lower, upper, 1e24)
            : LiquidityAmounts.getLiquidityForAmount1(lower, upper, 1e24);
        members[0].liquidity = liquidity / 1000 * 999;
        members[0].amount0Max = subjectIs0 ? uint128(1e24) : 0;
        members[0].amount1Max = subjectIs0 ? 0 : uint128(1e24);
        members[0].rules.guardEndBlock = uint40(vm.getBlockNumber() + 100);
        members[0].rules.snipeTaxPips = 100_000;
        members[0].rules.maxBuyQuoteAmount = 1e22;
        members[0].config.advisory = kitAdvisory;
        members[0].config.advisoryGasLimit = _kitRootGasLimit();
        members[0].config.advisoryPhases = _kitRootPhases();
        bytes[] memory configs = new bytes[](1);
        configs[0] = _kitRootData();
        (bytes32 family,, uint256 out) = launcher.launchWithBuy(
            t, address(root), members, configs, IHookrLauncher.DevBuy(0, 1e21, 1, 0), vm.getBlockTimestamp()
        );
        assertGt(out, 0, "the dev buy filled");
        PoolKey memory key = launcher.position(family, 0).key;
        HookrTypes.SwapContext memory x = _kitContext(key, true, true, 1e21);
        x.sender = address(launcher);
        x.payer = address(launcher);
        x.beneficiary = address(launcher);
        x.authenticated = false;
        vm.prank(address(root));
        HookrTypes.Advice memory advice = IHookrAdvisory(kitAdvisory).beforeSwap(x);
        assertLe(advice.lpFeeSurchargePips, _kitRootCapPips(), "surcharge above cap");
        assertEq(advice.quoteTakePips, 0, "quote take");
        assertFalse(advice.reject, "reject");
    }

    /// @notice The artifact exposes every IHookrAdvisory selector, the declared phases are admissible and admitted,
    ///         and the runtime is plain code the registry can pin.
    function test_kit_root_declarations() public {
        if (_kitSkip(_kitSupportsRoot())) return;
        bytes4[5] memory required = [
            IHookrAdvisory.configSchemaHash.selector,
            IHookrAdvisory.bind.selector,
            IHookrAdvisory.beforeAddLiquidity.selector,
            IHookrAdvisory.beforeSwap.selector,
            IHookrAdvisory.afterSwap.selector
        ];
        bytes4[] memory exposed = _kitSelectors();
        for (uint256 i; i < required.length; ++i) {
            assertTrue(_kitHas(exposed, required[i]), "IHookrAdvisory selector missing");
        }
        uint8 phases = _kitRootPhases();
        assertTrue(phases & HookrTypes.BEFORE_SWAP != 0, "fee advisories declare BEFORE_SWAP");
        assertEq(phases & ~uint8(3), 0, "unknown phase");
        IHookrRegistry.Admission memory a = registry.admission(address(root), kitAdvisory);
        assertEq(a.phaseMask, phases, "admitted phases");
        assertEq(a.codeHash, kitAdvisory.codehash, "code hash");
        _kitPlainCode();
    }

    // ------------------------------------------------------------------------------------------------------------
    // HookrPairRoot
    // ------------------------------------------------------------------------------------------------------------

    /// @notice The real pair roots bound and opened their pools, and the advisory refuses a second bind.
    function test_kit_pair_bindsOnce() public {
        if (_kitSkip(_kitSupportsPair())) return;
        HookrPairRoot[2] memory pairs = [kitPair, kitPairOpen];
        for (uint256 i; i < pairs.length; ++i) {
            PoolId id = pairs[i].poolId();
            (uint160 price,,,) = manager.getSlot0(id);
            assertGt(price, 0, "pool open");
            IHookrPairRoot.Params memory p = pairs[i].params();
            vm.prank(address(pairs[i]));
            (bool ok, bytes memory out) = kitAdvisory.call(
                abi.encodeCall(
                    IHookrPairAdvisory.bindPair,
                    (id, p.advisoryCapPips, p.advisoryGasLimit, _kitPairData(p.advisoryCapPips))
                )
            );
            assertFalse(
                ok && out.length >= 32 && bytes4(out) == IHookrPairAdvisory.bindPair.selector, "second bind accepted"
            );
        }
    }

    /// @notice The registry records each pair root's advisory and reports it verified: admitted for the factory with
    ///         an unchanged runtime codehash.
    function test_kit_pair_admitted() public {
        if (_kitSkip(_kitSupportsPair())) return;
        HookrPairRoot[2] memory pairs = [kitPair, kitPairOpen];
        for (uint256 i; i < pairs.length; ++i) {
            (address recorded, bool verified) = registry.rootStatus(address(pairs[i]));
            assertEq(recorded, kitAdvisory, "recorded advisory");
            assertTrue(verified, "verified");
            assertEq(registry.rootFactoryOf(address(pairs[i])), address(kitFactory), "factory");
        }
        IHookrRegistry.Admission memory a = registry.admission(address(kitFactory), kitAdvisory);
        assertEq(a.codeHash, kitAdvisory.codehash, "code hash");
        assertGe(a.caps.maxLpFeePips, _kitPairCapPips(), "admitted cap");
        assertGe(a.gasLimit, _kitPairGasLimit(), "admitted gas");
    }

    /// @notice surchargeForSwap returns exactly 32 bytes holding a uint24, with and without hook data.
    function test_kit_pair_returnSize() public {
        if (_kitSkip(_kitSupportsPair())) return;
        PoolId id = kitPair.poolId();
        for (uint256 i; i < 4; ++i) {
            bytes memory hookData = i < 2 ? bytes("") : new bytes(1_024);
            bytes memory out = _kitStatic(
                address(kitPair),
                abi.encodeCall(
                    IHookrPairAdvisory.surchargeForSwap,
                    (id, i & 1 == 0, -1e15, TickMath.MIN_SQRT_PRICE + 1, hookData, address(kitPairRouter))
                ),
                32,
                0
            );
            assertLe(uint256(bytes32(out)), type(uint24).max, "uint24");
        }
    }

    /// @notice Over fuzzed swaps and states, the surcharge never exceeds the cap the root gave at bind, and the
    ///         fail-closed pool charges exactly base plus the surcharge.
    function testFuzz_kit_pair_surchargeWithinCap(
        uint256 seed,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit,
        bytes calldata hookData
    ) public {
        if (_kitSkip(_kitSupportsPair())) return;
        vm.assume(hookData.length <= 4_096);
        PoolId id = kitPair.poolId();
        _kitStress(address(kitPair), id, seed);
        vm.prank(address(kitPair));
        uint24 surcharge = IHookrPairAdvisory(kitAdvisory)
            .surchargeForSwap(id, zeroForOne, amountSpecified, limit, hookData, address(kitPairRouter));
        assertLe(surcharge, _kitPairCapPips(), "surcharge above cap");
        vm.prank(address(kitPair));
        surcharge = IHookrPairAdvisory(kitAdvisory)
            .surchargeForSwap(
                id,
                zeroForOne,
                -1e15,
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                hookData,
                address(kitPairRouter)
            );
        assertEq(_kitPairSwapFee(kitPairKey, zeroForOne, hookData), KIT_PAIR_BASE + surcharge, "executed fee");
    }

    /// @notice In the worst-case state, cold, with 8 KiB of hook data, the advisory answers within the pair root's
    ///         gas limit, and the fail-closed pool trades both ways.
    function test_kit_pair_gasAtCap() public {
        if (_kitSkip(_kitSupportsPair())) return;
        PoolId id = kitPair.poolId();
        _kitWorstCase(address(kitPair), id);
        bytes memory big = new bytes(8_192);
        for (uint256 i; i < 2; ++i) {
            _kitCold();
            uint256 used = _kitGas(
                address(kitPair),
                abi.encodeCall(
                    IHookrPairAdvisory.surchargeForSwap,
                    (id, i == 0, -1e15, TickMath.MIN_SQRT_PRICE + 1, big, address(kitPairRouter))
                ),
                32,
                _kitPairGasLimit()
            );
            console2.log("kit pair surchargeForSwap cold gas", used);
        }
        uint24 cap = _kitPairCapPips();
        assertLe(_kitPairSwapFee(kitPairKey, true, big), KIT_PAIR_BASE + cap, "0->1");
        assertLe(_kitPairSwapFee(kitPairKey, false, big), KIT_PAIR_BASE + cap, "1->0");
    }

    /// @notice surchargeForSwap reverts for a caller that bound nothing and for a pool the caller did not bind.
    function test_kit_pair_unboundReverts() public {
        if (_kitSkip(_kitSupportsPair())) return;
        bytes memory call = abi.encodeCall(
            IHookrPairAdvisory.surchargeForSwap,
            (kitPair.poolId(), true, -1e15, TickMath.MIN_SQRT_PRICE + 1, bytes(""), address(kitPairRouter))
        );
        vm.prank(address(0xBAD));
        (bool ok,) = kitAdvisory.staticcall(call);
        assertFalse(ok, "stranger read a binding");
        call = abi.encodeCall(
            IHookrPairAdvisory.surchargeForSwap,
            (PoolId.wrap(bytes32(uint256(1))), true, -1e15, TickMath.MIN_SQRT_PRICE + 1, bytes(""), address(0))
        );
        vm.prank(address(kitPair));
        (ok,) = kitAdvisory.staticcall(call);
        assertFalse(ok, "unbound pool answered");
    }

    /// @notice When the advisory reverts, the fail-open pair root charges base plus its cap and the fail-closed one
    ///         reverts the swap; once the advisory recovers, the fail-closed pool trades again.
    function test_kit_pair_failOpen() public {
        if (_kitSkip(_kitSupportsPair())) return;
        vm.mockCallRevert(kitAdvisory, abi.encodeWithSelector(IHookrPairAdvisory.surchargeForSwap.selector), "down");
        assertEq(_kitPairSwapFee(kitPairOpenKey, true, ""), KIT_PAIR_BASE + _kitPairCapPips(), "fail-open charge");
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(kitPair),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IHookrPairRoot.AdvisoryFailed.selector, kitAdvisory),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(trader);
        kitPairRouter.swap(kitPairKey, true, -1e15, "");
        vm.clearMockedCalls();
        assertLe(_kitPairSwapFee(kitPairKey, true, ""), KIT_PAIR_BASE + _kitPairCapPips(), "recovered");
    }

    /// @notice The artifact exposes both IHookrPairAdvisory selectors, surchargeForSwap keeps its fixed selector,
    ///         and the runtime is plain code.
    function test_kit_pair_declarations() public {
        if (_kitSkip(_kitSupportsPair())) return;
        assertEq(IHookrPairAdvisory.surchargeForSwap.selector, KIT_SURCHARGE_SELECTOR, "selector");
        bytes4[] memory exposed = _kitSelectors();
        assertTrue(_kitHas(exposed, IHookrPairAdvisory.bindPair.selector), "bindPair missing");
        assertTrue(_kitHas(exposed, KIT_SURCHARGE_SELECTOR), "surchargeForSwap missing");
        _kitPlainCode();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Skips the calling test when its root kind is unsupported.
    function _kitSkip(bool supported) internal returns (bool) {
        if (!supported) vm.skip(true);
        return !supported;
    }

    /// @dev The context the root passes for a swap on `key` from the router, payer and beneficiary the trader.
    function _kitContext(PoolKey memory key, bool isBuy, bool exactInput, uint128 amount)
        internal
        view
        returns (HookrTypes.SwapContext memory x)
    {
        HookrTypes.PoolConfig memory pc = root.poolConfig(key.toId());
        bool zeroForOne = isBuy == (pc.quote == key.currency0);
        x = HookrTypes.SwapContext({
            id: key.toId(),
            sender: address(router),
            payer: trader,
            beneficiary: trader,
            subject: pc.subject,
            quote: pc.quote,
            authenticated: true,
            isBuy: isBuy,
            exactInput: exactInput,
            zeroForOne: zeroForOne,
            amountSpecified: exactInput ? -int256(uint256(amount)) : int256(uint256(amount)),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE : MAX_PRICE,
            baseLpFeePips: pc.baseLpFeePips
        });
    }

    /// @dev Static call from `caller`, with `gasLimit` gas or all gas when zero, that must return exactly `size`.
    function _kitStatic(address caller, bytes memory input, uint256 size, uint256 gasLimit)
        internal
        returns (bytes memory out)
    {
        bool ok;
        vm.prank(caller);
        if (gasLimit == 0) (ok, out) = kitAdvisory.staticcall(input);
        else (ok, out) = kitAdvisory.staticcall{gas: gasLimit}(input);
        assertTrue(ok, "call failed");
        assertEq(out.length, size, "return size");
    }

    /// @dev `_kitStatic` with exactly `gasLimit` gas; returns the gas the caller spent on it.
    function _kitGas(address caller, bytes memory input, uint256 size, uint256 gasLimit) internal returns (uint256) {
        vm.prank(caller);
        uint256 before = gasleft();
        (bool ok, bytes memory out) = kitAdvisory.staticcall{gas: gasLimit}(input);
        uint256 used = before - gasleft();
        assertTrue(ok, "out of gas at the limit");
        assertEq(out.length, size, "return size");
        return used;
    }

    /// @dev Asserts the four Advice words are in the ranges the root accepts.
    function _kitAdviceWords(bytes memory out) internal pure {
        uint256 lp;
        uint256 take;
        uint256 recipient;
        uint256 reject;
        assembly ("memory-safe") {
            lp := mload(add(out, 32))
            take := mload(add(out, 64))
            recipient := mload(add(out, 96))
            reject := mload(add(out, 128))
        }
        require(lp <= type(uint24).max && take <= type(uint24).max, "advice pips out of range");
        require(recipient <= type(uint160).max && reject <= 1, "advice words out of range");
    }

    /// @dev Swaps 1e15 exact input on a kit pair pool and returns the LP fee from the PoolManager's Swap event.
    function _kitPairSwapFee(PoolKey memory key, bool zeroForOne, bytes memory hookData) internal returns (uint24 fee) {
        vm.recordLogs();
        vm.prank(trader);
        kitPairRouter.swap(key, zeroForOne, -1e15, hookData);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == KIT_SWAP_TOPIC) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "no Swap event");
    }

    /// @dev The selectors the advisory's build artifact exposes.
    function _kitSelectors() internal view returns (bytes4[] memory selectors) {
        string[] memory sigs = vm.parseJsonKeys(vm.readFile(_kitArtifact()), ".methodIdentifiers");
        selectors = new bytes4[](sigs.length);
        for (uint256 i; i < sigs.length; ++i) {
            selectors[i] = bytes4(keccak256(bytes(sigs[i])));
        }
    }

    function _kitHas(bytes4[] memory set, bytes4 selector) internal pure returns (bool) {
        for (uint256 i; i < set.length; ++i) {
            if (set[i] == selector) return true;
        }
        return false;
    }

    /// @dev Asserts the runtime passes ExecutorAdmission's scan: it is not an EIP-7702 designator, and no instruction
    ///      of its linear decoding that can run is DELEGATECALL, CALLCODE or SELFDESTRUCT. The trailing CBOR length is
    ///      never trusted: only a tail of solc's exact metadata layout after an instruction that cannot fall through is
    ///      left out, and only up to its first JUMPDEST (see ExecutorAdmission). A suite whose advisory this build
    ///      deployed from `_kitArtifact()` (`_kitOwnBuild()`) has that advisory's own metadata tail left out whole
    ///      (`ExecutorAdmission.scanOwnBuild`), so a digest byte cannot fail it; every other suite gets the strict scan.
    function _kitPlainCode() internal view {
        bytes memory code = kitAdvisory.code;
        if (!_kitOwnBuild()) {
            _kitPlainCode(code);
            return;
        }
        assertGt(code.length, 2, "no code");
        (uint256 offset, uint8 opcode) = ExecutorAdmission.scanOwnBuild(code, vm.getDeployedCode(_kitArtifact()));
        _kitAssertPlain(offset, opcode);
    }

    /// @dev Whether `kitAdvisory` was deployed from this build's own artifact, `_kitArtifact()`. The suites of the
    ///      advisories this repository builds return true; an advisory author's suite keeps the default, the strict scan.
    function _kitOwnBuild() internal view virtual returns (bool) {
        return false;
    }

    function _kitPlainCode(bytes memory code) internal pure {
        assertGt(code.length, 2, "no code");
        (uint256 offset, uint8 opcode) = ExecutorAdmission.scan(code);
        _kitAssertPlain(offset, opcode);
    }

    function _kitAssertPlain(uint256 offset, uint8 opcode) internal pure {
        assertTrue(opcode != ExecutorAdmission.DELEGATED, "EIP-7702 designator");
        assertTrue(opcode != ExecutorAdmission.DELEGATECALL, string.concat("DELEGATECALL at ", vm.toString(offset)));
        assertTrue(opcode != ExecutorAdmission.CALLCODE, string.concat("CALLCODE at ", vm.toString(offset)));
        assertTrue(opcode != ExecutorAdmission.SELFDESTRUCT, string.concat("SELFDESTRUCT at ", vm.toString(offset)));
    }

    /// @dev The kit's code check on `code`, for the kit's own test of it.
    function kitPlainCode(bytes memory code) external pure {
        _kitPlainCode(code);
    }

    /// @notice The kit's code check never trusts the trailing CBOR length: a runtime whose last two bytes claim that
    ///         the bytes before them are metadata still has those bytes read, so a DELEGATECALL after a JUMPDEST there
    ///         is refused, as is a DELEGATECALL anywhere in a solc-shaped tail after an instruction that falls through.
    function test_kit_plainCodeIgnoresTheTrailingLength() public {
        // JUMPDEST, DELEGATECALL, STOP, STOP, then a length of 3 that claims bytes 1 to 3 are metadata.
        vm.expectRevert();
        this.kitPlainCode(hex"5bf400000003");
        vm.expectRevert();
        this.kitPlainCode(hex"5bf2000003");
        // CALLER, then solc's exact tail layout with a DELEGATECALL byte in its digest: CALLER falls through into it.
        bytes memory tail = bytes.concat(
            hex"33a2646970667358221220", bytes32(uint256(0xf4) << 248), hex"64736f6c6343080025", hex"0033"
        );
        vm.expectRevert();
        this.kitPlainCode(tail);
        // The advisory's own runtime passes.
        _kitPlainCode();
    }
}
