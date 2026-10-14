// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {HookrRootFactory} from "../../src/factory/HookrRootFactory.sol";
import {HookrPairRoot} from "../../src/factory/HookrPairRoot.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {IHookrRootFactory} from "../../src/interfaces/IHookrRootFactory.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRelease} from "../../src/libraries/HookrRelease.sol";
import {Vm} from "forge-std/Test.sol";
import {PairRootFixture} from "./PairRootFixture.sol";
import {IHookrFactoryRegistry} from "../../src/interfaces/IHookrRootFactory.sol";
import {HookrPairRootSalt} from "../../script/HookrPairRootSalt.s.sol";

contract HookrPairRootTest is PairRootFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpFactory();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------------------------------------------------

    function test_deploy_initializesRegistersAndPinsEverything() public {
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _plain(c0, c1, 3_000);
        bytes32 salt = _mine(deployer, p);
        address predicted = factory.computeAddress(deployer, salt, p);
        PoolKey memory expectedKey = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(predicted));

        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrRegistry.RootRegistered(predicted);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrRegistry.FactoryRootRegistered(address(factory), predicted);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IHookrRootFactory.PairRootDeployed(predicted, expectedKey.toId(), deployer, salt);
        vm.prank(deployer);
        (address r, PoolId id) = factory.deploy(salt, p, SQRT_ONE, "");

        assertEq(r, predicted);
        assertEq(uint160(r) & 0x3fff, 0x2080);
        assertEq(PoolId.unwrap(id), PoolId.unwrap(expectedKey.toId()));
        HookrPairRoot root = HookrPairRoot(r);
        assertEq(address(root.poolManager()), address(manager));
        assertEq(address(root.registry()), address(registry));
        assertEq(root.factory(), address(factory));
        assertEq(root.PERMISSION_FLAGS(), 0x2080);
        assertEq(root.ROLE(), keccak256("hookr.root.pair"));
        assertEq(root.releaseId(), HookrRelease.ID);
        assertEq(PoolId.unwrap(root.poolId()), PoolId.unwrap(id));
        assertTrue(root.knownPool(id));
        assertFalse(root.knownPool(PoolId.wrap(bytes32(uint256(1)))));
        assertEq(keccak256(abi.encode(root.poolKey())), keccak256(abi.encode(expectedKey)));
        assertEq(keccak256(abi.encode(root.params())), keccak256(abi.encode(p)));
        assertTrue(registry.isRoot(r));
        assertTrue(registry.rootOpen(r));
        (uint160 price,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(id);
        assertEq(price, SQRT_ONE);
        assertEq(protocolFee, 0);
        assertEq(lpFee, 3_000);
        assertEq(factory.pairRootCreationCodeHash(), keccak256(type(HookrPairRoot).creationCode));
        assertEq(factory.PERMISSION_FLAGS(), root.PERMISSION_FLAGS());
        assertEq(factory.releaseId(), HookrRelease.ID);
        assertEq(factory.deploySalt(deployer, salt), keccak256(abi.encode(deployer, salt)));
    }

    function test_saltScript_minesDeployableSalt() public {
        (Currency c0, Currency c1) = _eth();
        IHookrPairRoot.Params memory p = _advised(c0, c1, 500, 1_500, true);
        (bytes32 salt, address predicted) = new HookrPairRootSalt().run(address(factory), deployer, p, 7);
        assertGe(uint256(salt), 7);
        assertEq(uint160(predicted) & 0x3fff, 0x2080);
        vm.prank(deployer);
        (address r,) = factory.deploy(salt, p, SQRT_ONE, "");
        assertEq(r, predicted);
    }

    function test_deploy_zeroBaseFeeLeavesSlot0Zero() public {
        (Currency c0, Currency c1) = _eth();
        (, PoolKey memory key) = _deploy(_plain(c0, c1, 0));
        (,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, 0);
        _fund(key);
        assertEq(_swapFee(key, true, -1 ether, ""), 0);
    }

    function test_deploy_refusedWhileFactoryInactive() public {
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _plain(c0, c1, 3_000);
        bytes32 salt = _mine(deployer, p);
        registry.deactivateRootFactory(address(factory));
        assertFalse(registry.isRootFactory(address(factory)));
        vm.prank(deployer);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        factory.deploy(salt, p, SQRT_ONE, "");
    }

    function test_factory_refusesMissingWiring() public {
        vm.expectRevert(IHookrRootFactory.InvalidWiring.selector);
        new HookrRootFactory(IPoolManager(address(0xdead)), IHookrFactoryRegistry(address(registry)));
        vm.expectRevert(IHookrRootFactory.InvalidWiring.selector);
        new HookrRootFactory(manager, IHookrFactoryRegistry(address(0xdead)));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Salt binding and flags
    // ------------------------------------------------------------------------------------------------------------

    /// A salt mined by the deployer is useless to anyone else: the same salt from another sender maps to a different
    /// address, and the attacker's own root does not take the victim's address or pool.
    function test_frontRun_minedSaltCannotBeTaken() public {
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _plain(c0, c1, 3_000);
        bytes32 salt = _mine(deployer, p);
        address victim = factory.computeAddress(deployer, salt, p);
        address attacker = address(0xBAD);
        address stolen = factory.computeAddress(attacker, salt, p);
        assertTrue(stolen != victim);

        vm.prank(attacker);
        if (uint160(stolen) & 0x3fff != 0x2080) {
            vm.expectRevert(abi.encodeWithSelector(IHookrRootFactory.InvalidHookAddress.selector, stolen));
            factory.deploy(salt, p, SQRT_ONE, "");
        } else {
            factory.deploy(salt, p, SQRT_ONE, "");
        }

        // The attacker mines a salt of their own and front-runs with identical parameters: a separate root and pool.
        bytes32 own = _mine(attacker, p);
        vm.prank(attacker);
        (address attackerRoot, PoolId attackerId) = factory.deploy(own, p, SQRT_ONE, "");
        assertTrue(attackerRoot != victim);

        vm.prank(deployer);
        (address r, PoolId id) = factory.deploy(salt, p, SQRT_ONE, "");
        assertEq(r, victim);
        assertTrue(PoolId.unwrap(id) != PoolId.unwrap(attackerId));
        assertEq(HookrPairRoot(r).factory(), address(factory));
    }

    function test_flags_wrongAddressRefusedByFactory() public {
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _plain(c0, c1, 3_000);
        bytes32 h = factory.initCodeHash(p);
        bytes32 salt;
        address a;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            a = factory.computeAddress(deployer, salt, p);
            if (uint160(a) & 0x3fff != 0x2080) break;
        }
        assertEq(h, keccak256(abi.encodePacked(type(HookrPairRoot).creationCode, abi.encode(manager, registry, p))));
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IHookrRootFactory.InvalidHookAddress.selector, a));
        factory.deploy(salt, p, SQRT_ONE, "");
    }

    /// Extra permission bits are refused as well: the low 14 bits must equal the flags, not merely contain them.
    function test_flags_supersetRefusedByFactory() public {
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _plain(c0, c1, 3_000);
        bytes32 salt;
        address a;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            a = factory.computeAddress(deployer, salt, p);
            uint160 low = uint160(a) & 0x3fff;
            if (low & 0x2080 == 0x2080 && low != 0x2080) break;
        }
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IHookrRootFactory.InvalidHookAddress.selector, a));
        factory.deploy(salt, p, SQRT_ONE, "");
    }

    function test_flags_wrongAddressRefusedByConstructor() public {
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _plain(c0, c1, 3_000);
        bytes32 h = keccak256(abi.encodePacked(type(HookrPairRoot).creationCode, abi.encode(manager, registry, p)));
        bytes32 salt;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, h)))));
            if (uint160(a) & 0x3fff != 0x2080) break;
        }
        vm.expectRevert(IHookrPairRoot.InvalidHookAddress.selector);
        new HookrPairRoot{salt: salt}(manager, IHookrRegistry(address(registry)), p);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Initialization is one-shot and only the factory's
    // ------------------------------------------------------------------------------------------------------------

    function test_initialize_secondInitializeRefused() public {
        (Currency c0, Currency c1) = _erc();
        (HookrPairRoot root, PoolKey memory key) = _deploy(_plain(c0, c1, 3_000));

        // Anyone re-initializing the root's own key: the hook refuses before the PoolManager's own check.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(root),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(IHookrPairRoot.Unauthorized.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(key, SQRT_ONE);

        // Only the factory can open, and the PoolManager refuses a second initialization of the same pool.
        vm.expectRevert(IHookrPairRoot.Unauthorized.selector);
        root.open(SQRT_ONE, "");
        vm.prank(address(factory));
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        root.open(SQRT_ONE, "");

        // The same deployer, salt and parameters cannot deploy twice.
        IHookrPairRoot.Params memory p = root.params();
        bytes32 salt = _mine(deployer, p);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IHookrRootFactory.RootExists.selector, address(root)));
        factory.deploy(salt, p, SQRT_ONE, "");
    }

    /// No other pool can name the root as its hook: other fee, other spacing, or a static fee.
    function test_initialize_otherKeysRefused() public {
        (Currency c0, Currency c1) = _erc();
        (HookrPairRoot root, PoolKey memory key) = _deploy(_plain(c0, c1, 3_000));
        PoolKey[3] memory others;
        others[0] = PoolKey(c0, c1, 3_000, 60, IHooks(address(root)));
        others[1] = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(root)));
        (Currency e0, Currency e1) = _eth();
        others[2] = PoolKey(e0, e1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(root),
                    IHooks.beforeInitialize.selector,
                    abi.encodeWithSelector(IHookrPairRoot.Unauthorized.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            manager.initialize(others[i], SQRT_ONE);
        }
        assertTrue(PoolId.unwrap(key.toId()) != PoolId.unwrap(others[0].toId()));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Swaps through the real PoolManager
    // ------------------------------------------------------------------------------------------------------------

    function test_swap_erc20_bothDirections_baseFee() public {
        (Currency c0, Currency c1) = _erc();
        (, PoolKey memory key) = _deploy(_plain(c0, c1, 3_000));
        _fund(key);
        _checkSwaps(key, 3_000);
    }

    function test_swap_native_bothDirections_baseFee() public {
        (Currency c0, Currency c1) = _eth();
        (, PoolKey memory key) = _deploy(_plain(c0, c1, 3_000));
        _fund(key);
        _checkSwaps(key, 3_000);
    }

    function _checkSwaps(PoolKey memory key, uint24 expected) internal {
        uint256 before0 = _bal(key.currency0, trader);
        uint256 before1 = _bal(key.currency1, trader);
        assertEq(_swapFee(key, true, -1e18, ""), expected, "0->1 exact in");
        assertEq(_swapFee(key, false, -1e18, ""), expected, "1->0 exact in");
        assertEq(_swapFee(key, true, 5e17, ""), expected, "0->1 exact out");
        assertEq(_swapFee(key, false, 5e17, ""), expected, "1->0 exact out");
        // Round trips pay fees: the trader ends with less of both.
        assertLt(_bal(key.currency0, trader), before0);
        assertLt(_bal(key.currency1, trader), before1);
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return c.isAddressZero() ? who.balance : c.balanceOf(who);
    }

    /// The pair root output matches a hookless static-fee pool of the same fee, liquidity and price exactly.
    function test_swap_matchesHooklessPool() public {
        (Currency c0, Currency c1) = _erc();
        (, PoolKey memory key) = _deploy(_plain(c0, c1, 3_000));
        _fund(key);
        PoolKey memory plain = PoolKey(c0, c1, 3_000, 60, IHooks(address(0)));
        manager.initialize(plain, SQRT_ONE);
        _fund(plain);
        BalanceDelta a = _swap(key, true, -3e18, "");
        BalanceDelta b = _swap(plain, true, -3e18, "");
        assertEq(BalanceDelta.unwrap(a), BalanceDelta.unwrap(b));
        a = _swap(key, false, 2e18, "");
        b = _swap(plain, false, 2e18, "");
        assertEq(BalanceDelta.unwrap(a), BalanceDelta.unwrap(b));
    }

    function test_swap_noStorageWrites() public {
        (Currency c0, Currency c1) = _eth();
        (HookrPairRoot plain, PoolKey memory k1) = _deploy(_plain(c0, c1, 3_000));
        (HookrPairRoot advised, PoolKey memory k2) = _deploy(_advised(c0, c1, 3_000, 2_000, true));
        _fund(k1);
        _fund(k2);
        advisory.set(0, 700);
        vm.record();
        _swap(k1, true, -1e18, "");
        _swap(k2, false, -1e18, "");
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(plain));
        assertEq(reads.length, 0);
        assertEq(writes.length, 0);
        (reads, writes) = vm.accesses(address(advised));
        assertEq(reads.length, 0);
        assertEq(writes.length, 0);
        (, writes) = vm.accesses(address(advisory));
        assertEq(writes.length, 0);
    }

    function test_beforeSwap_onlyManager() public {
        (Currency c0, Currency c1) = _erc();
        (HookrPairRoot root, PoolKey memory key) = _deploy(_plain(c0, c1, 3_000));
        SwapParams memory sp = SwapParams(true, -1, 1);
        vm.expectRevert(IHookrPairRoot.Unauthorized.selector);
        root.beforeSwap(address(this), key, sp, "");
        vm.prank(address(manager));
        (bytes4 sel, BeforeSwapDelta delta, uint24 fee) = root.beforeSwap(address(this), key, sp, "");
        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Advisory
    // ------------------------------------------------------------------------------------------------------------

    function test_advisory_on_addsSurcharge_erc20() public {
        (Currency c0, Currency c1) = _erc();
        (, PoolKey memory key) = _deploy(_advised(c0, c1, 3_000, 2_000, false));
        _fund(key);
        advisory.set(0, 700);
        _checkSwaps(key, 3_700);
    }

    function test_advisory_on_addsSurcharge_native() public {
        (Currency c0, Currency c1) = _eth();
        (, PoolKey memory key) = _deploy(_advised(c0, c1, 3_000, 2_000, true));
        _fund(key);
        advisory.set(0, 1_999);
        _checkSwaps(key, 4_999);
    }

    function test_advisory_off_zeroSurcharge() public {
        (Currency c0, Currency c1) = _erc();
        (, PoolKey memory key) = _deploy(_advised(c0, c1, 3_000, 2_000, false));
        _fund(key);
        advisory.set(0, 0);
        _checkSwaps(key, 3_000);
    }

    function test_advisory_clampedToCap() public {
        (Currency c0, Currency c1) = _erc();
        (, PoolKey memory key) = _deploy(_advised(c0, c1, 3_000, 2_000, false));
        _fund(key);
        advisory.set(0, 2_001);
        assertEq(_swapFee(key, true, -1e18, ""), 5_000);
        advisory.set(0, type(uint24).max);
        assertEq(_swapFee(key, false, -1e18, ""), 5_000);
    }

    function test_advisory_receivesSwapArguments() public {
        (Currency c0, Currency c1) = _eth();
        (HookrPairRoot root, PoolKey memory key) = _deploy(_advised(c0, c1, 3_000, 5_000, false));
        _fund(key);
        advisory.set(5, 0);
        advisory.expect(PoolId.unwrap(root.poolId()));
        assertEq(_swapFee(key, true, -1e18, ""), 4_000);
        assertEq(_swapFee(key, false, -1e18, hex"aabbcc"), 5_003);
    }

    function test_advisory_failOpen_chargesCap() public {
        (Currency c0, Currency c1) = _erc();
        (, PoolKey memory key) = _deploy(_advised(c0, c1, 3_000, 2_000, true));
        _fund(key);
        uint256[4] memory modes = [uint256(1), 2, 3, 4];
        for (uint256 i; i < modes.length; ++i) {
            advisory.set(modes[i], 100);
            assertEq(_swapFee(key, i % 2 == 0, -1e18, ""), 5_000);
        }
        advisory.set(0, uint256(type(uint24).max) + 1);
        assertEq(_swapFee(key, true, -1e18, ""), 5_000);
    }

    function test_advisory_failClosed_reverts() public {
        (Currency c0, Currency c1) = _eth();
        (HookrPairRoot root, PoolKey memory key) = _deploy(_advised(c0, c1, 3_000, 2_000, false));
        _fund(key);
        uint256[5] memory modes = [uint256(1), 2, 3, 4, 0];
        for (uint256 i; i < modes.length; ++i) {
            advisory.set(modes[i], modes[i] == 0 ? uint256(type(uint24).max) + 1 : 100);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(root),
                    IHooks.beforeSwap.selector,
                    abi.encodeWithSelector(IHookrPairRoot.AdvisoryFailed.selector, address(advisory)),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            _swap(key, i % 2 == 0, -1e18, "");
        }
    }

    /// A caller cannot starve the advisory into its failure path: too little gas reverts instead of charging the cap.
    function test_advisory_starvedCallReverts() public {
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _advised(c0, c1, 3_000, 2_000, true);
        p.advisoryGasLimit = 400_000;
        (HookrPairRoot root, PoolKey memory key) = _deploy(p);
        _fund(key);
        advisory.set(2, 0);
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(root),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IHookrPairRoot.InsufficientAdvisoryGas.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap{gas: 300_000}(key, true, -1e18, "");
        // With enough gas the gas-burning advisory fails inside its own limit and the fail-open cap applies.
        assertEq(_swapFee(key, true, -1e18, ""), 5_000);
    }

    /// Whatever gas the caller supplies, the swap either reverts or the advisory ran with its full limit: starving
    /// the call never yields the fail-open cap.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_advisory_starvationNeverSelectsCap(uint256 gas) public {
        gas = bound(gas, 60_000, 400_000);
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _advised(c0, c1, 3_000, 2_000, true);
        p.advisoryGasLimit = 100_000;
        (, PoolKey memory key) = _deploy(p);
        _fund(key);
        advisory.set(6, 90_000);
        vm.recordLogs();
        vm.prank(trader);
        (bool ok,) = address(router).call{gas: gas}(abi.encodeCall(router.swap, (key, true, -1e18, "")));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; ok && i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(fee, 3_100);
            }
        }
    }

    /// Fee never exceeds maxLpFeePips, whatever the advisory returns or how it fails.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_fee_neverAboveCap(uint256 mode, uint256 value, uint24 base, uint24 cap, bool zeroForOne) public {
        mode = bound(mode, 0, 4);
        base = uint24(bound(base, 0, 300_000));
        cap = uint24(bound(cap, 1, 300_000));
        (Currency c0, Currency c1) = _eth();
        IHookrPairRoot.Params memory p = _advised(c0, c1, base, cap, true);
        (, PoolKey memory key) = _deploy(p);
        _fund(key);
        advisory.set(mode, value);
        uint24 fee = _swapFee(key, zeroForOne, -1e15, "");
        assertLe(fee, p.maxLpFeePips);
        uint256 expected = mode == 0 && value <= type(uint24).max ? (value < cap ? value : cap) : cap;
        assertEq(fee, base + expected);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Parameter validation
    // ------------------------------------------------------------------------------------------------------------

    function test_params_invalidRefused() public {
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params[] memory bad = new IHookrPairRoot.Params[](12);
        bad[0] = _plain(c1, c0, 3_000); // unsorted
        bad[1] = _plain(c0, c0, 3_000); // equal
        bad[2] = _plain(c0, c1, 3_000);
        bad[2].tickSpacing = 0;
        bad[3] = _plain(c0, c1, 3_000);
        bad[3].tickSpacing = int24(type(int16).max) + 1;
        bad[4] = _plain(c0, c1, 600_001); // above the ceiling
        bad[5] = _plain(c0, c1, 3_000);
        bad[5].maxLpFeePips = 2_999; // base above max
        bad[6] = _advised(c0, c1, 3_000, 2_000, false);
        bad[6].maxLpFeePips = 4_999; // base + cap above max
        bad[7] = _plain(c0, c1, 3_000);
        bad[7].advisoryCapPips = 1; // cap without advisory
        bad[7].maxLpFeePips = 3_001;
        bad[8] = _plain(c0, c1, 3_000);
        bad[8].advisoryFailOpen = true; // fail-open without advisory
        bad[9] = _advised(c0, c1, 3_000, 2_000, false);
        bad[9].advisory = address(0xC0DE); // no code, so never admitted: the factory refuses it first
        bad[10] = _advised(c0, c1, 3_000, 2_000, false);
        bad[10].advisoryGasLimit = 500_001;
        bad[11] = _advised(c0, c1, 3_000, 0, false); // advisory without cap
        for (uint256 i; i < bad.length; ++i) {
            bytes32 salt = _mine(deployer, bad[i]);
            vm.prank(deployer);
            if (i == 9) {
                vm.expectRevert(abi.encodeWithSelector(IHookrRootFactory.AdvisoryNotAdmitted.selector, address(0xC0DE)));
            } else {
                vm.expectRevert(IHookrPairRoot.InvalidParams.selector);
            }
            factory.deploy(salt, bad[i], SQRT_ONE, "");
        }
    }

    /// The root's own constructor refuses an advisory without code, whoever deploys it.
    function test_params_advisoryWithoutCodeRefusedByConstructor() public {
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _advised(c0, c1, 3_000, 2_000, false);
        p.advisory = address(0xC0DE);
        // The creation code runs at an address carrying the pair root flags, as CREATE2 would place it.
        address target = address(uint160(0xA11CE) << 14 | 0x2080);
        vm.etch(target, abi.encodePacked(type(HookrPairRoot).creationCode, abi.encode(manager, registry, p)));
        (bool ok, bytes memory reason) = target.call("");
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(IHookrPairRoot.InvalidParams.selector));
        p.advisory = address(advisory);
        vm.etch(target, abi.encodePacked(type(HookrPairRoot).creationCode, abi.encode(manager, registry, p)));
        (ok,) = target.call("");
        assertTrue(ok, "the same params with an advisory that has code construct");
    }
}
