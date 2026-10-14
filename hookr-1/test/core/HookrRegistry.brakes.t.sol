// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrRootFactory} from "../../src/factory/HookrRootFactory.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {IHookrFactoryRegistry} from "../../src/interfaces/IHookrRootFactory.sol";
import {PairTestRouter} from "../factory/PairRootFixture.sol";
import {mineSalt} from "../../script/HookrPairRootSalt.s.sol";

/// @notice AG-02 / NM-02: the launcher and root-factory brakes cannot be lifted by an operation queued ahead of them.
///         AG-03: pauseNewMarkets stops factory pools. AG-04 / NM-01: the Router refuses factory pair roots.
contract HookrRegistryBrakesTest is PeripheryFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal guardianAccount = address(0x6A7D);
    address internal stranger = address(0x5757);
    HookrRootFactory internal factory;

    function setUp() public {
        _setUpPeriphery();
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardianAccount));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardianAccount);
        factory = new HookrRootFactory(manager, IHookrFactoryRegistry(address(registry)));
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), address(factory).codehash, true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setRootFactory(address(factory), address(factory).codehash, true);
    }

    function _params(uint24 base) internal view returns (IHookrPairRoot.Params memory p) {
        (address c0, address c1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        p.currency0 = Currency.wrap(c0);
        p.currency1 = Currency.wrap(c1);
        p.tickSpacing = 60;
        p.baseLpFeePips = base;
        p.maxLpFeePips = base;
    }

    function _strangerDeploys(uint24 base) internal returns (address pair) {
        IHookrPairRoot.Params memory p = _params(base);
        bytes32 salt = mineSalt(address(factory), stranger, factory.initCodeHash(p), 0);
        vm.prank(stranger);
        (pair,) = factory.deploy(salt, p, SQRT_ONE, "");
    }

    function test_launcherReadmissionCannotBePreArmed() public {
        assertTrue(registry.isLauncher(address(launcher)));
        bytes32 kind = registry.SET_LAUNCHER();
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.AlreadyActive.selector, address(launcher)));
        registry.queue(kind, abi.encode(address(launcher), true));

        vm.prank(guardianAccount);
        registry.deactivateLauncher(address(launcher));
        assertFalse(registry.isLauncher(address(launcher)));
        // Readmission is queued after the brake and waits a full delay.
        bytes32 op = registry.queue(kind, abi.encode(address(launcher), true));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.setLauncher(address(launcher), true);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setLauncher(address(launcher), true);
        assertTrue(registry.isLauncher(address(launcher)));
    }

    function test_launcherAdmissionExecutesOnlyWhileInactive() public {
        // Queued while inactive, then the launcher is readmitted by an earlier operation: the later one is refused.
        vm.prank(guardianAccount);
        registry.deactivateLauncher(address(launcher));
        bytes32 kind = registry.SET_LAUNCHER();
        registry.queue(kind, abi.encode(address(launcher), true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setLauncher(address(launcher), true);
        registry.queue(kind, abi.encode(address(launcher), false));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setLauncher(address(launcher), false);
        registry.queue(kind, abi.encode(address(launcher), true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setLauncher(address(launcher), true);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.AlreadyActive.selector, address(launcher)));
        registry.setLauncher(address(launcher), true);
    }

    function test_factoryReactivationCannotBePreArmed() public {
        bytes32 codeHash = address(factory).codehash;
        bytes32 kind = registry.SET_ROOT_FACTORY();
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.AlreadyActive.selector, address(factory)));
        registry.queue(kind, abi.encode(address(factory), codeHash, true));

        vm.prank(guardianAccount);
        registry.deactivateRootFactory(address(factory));
        bytes32 op = registry.queue(kind, abi.encode(address(factory), codeHash, true));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.setRootFactory(address(factory), codeHash, true);
        IHookrPairRoot.Params memory p = _params(3000);
        bytes32 salt = mineSalt(address(factory), stranger, factory.initCodeHash(p), 0);
        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        factory.deploy(salt, p, SQRT_ONE, "");
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setRootFactory(address(factory), codeHash, true);
        address pair = _strangerDeploys(3000);
        assertTrue(registry.isRoot(pair));
    }

    function test_pauseNewMarketsStopsFactoryPools() public {
        vm.prank(guardianAccount);
        registry.pauseNewMarkets();
        IHookrPairRoot.Params memory p = _params(3000);
        bytes32 salt = mineSalt(address(factory), stranger, factory.initCodeHash(p), 0);
        address predicted = factory.computeAddress(stranger, salt, p);
        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.MarketsPaused.selector);
        factory.deploy(salt, p, SQRT_ONE, "");
        assertFalse(registry.isRoot(predicted));
        assertEq(predicted.code.length, 0);
        PoolKey memory key = PoolKey(p.currency0, p.currency1, 0x800000, p.tickSpacing, IHooks(predicted));
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, 0, "no pool initialized during the pause");
    }

    function test_routerRefusesPairRoot() public {
        address pair = _strangerDeploys(3000);
        PoolKey memory key = IHookrPairRoot(pair).poolKey();
        PairTestRouter lpRouter = new PairTestRouter(manager);
        tokenA.approve(address(lpRouter), type(uint256).max);
        tokenB.approve(address(lpRouter), type(uint256).max);
        lpRouter.modify(key, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: 0}));
        IHookrRouter.Swap memory s =
            IHookrRouter.Swap(key, true, -1e18, 1, MIN_PRICE, trader, vm.getBlockTimestamp() + 600);
        vm.prank(trader);
        vm.expectRevert(IHookrRouter.InvalidPool.selector);
        router.swap(s, address(0), new uint256[](0));
    }
}
