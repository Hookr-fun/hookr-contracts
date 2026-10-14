// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRootFactory} from "../../src/factory/HookrRootFactory.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {IHookrFactoryRegistry} from "../../src/interfaces/IHookrRootFactory.sol";
import {PairTestRouter} from "./PairRootFixture.sol";
import {mineSalt} from "../../script/HookrPairRootSalt.s.sol";

/// @notice A per-pair root registered through the release registry's root factory beside the standard root.
/// @dev Registration makes the pair root `isRoot` and `rootOpen`. Launcher, Router and Quoter read functions only a
///      standard root has (the Router requires `router()` to report itself), so every one of them refuses a pair
///      root: pair pools trade through plain v4 routers.
contract PairRootOnHookrStackTest is PeripheryFixture {
    HookrRootFactory internal factory;
    address internal pair;
    PoolKey internal pairKey;

    function setUp() public {
        _setUpPeriphery();
        factory = new HookrRootFactory(manager, IHookrFactoryRegistry(address(registry)));
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), address(factory).codehash, true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setRootFactory(address(factory), address(factory).codehash, true);
        (address c0, address c1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        IHookrPairRoot.Params memory p;
        p.currency0 = Currency.wrap(c0);
        p.currency1 = Currency.wrap(c1);
        p.tickSpacing = 60;
        p.baseLpFeePips = 3000;
        p.maxLpFeePips = 3000;
        bytes32 salt = mineSalt(address(factory), address(this), factory.initCodeHash(p), 0);
        (pair,) = factory.deploy(salt, p, SQRT_ONE, "");
        pairKey = IHookrPairRoot(pair).poolKey();
    }

    function testFactoryRootIsRegisteredAndOpen() public view {
        assertTrue(registry.isRootFactory(address(factory)));
        assertTrue(registry.isRoot(pair));
        assertTrue(registry.rootOpen(pair));
        assertEq(address(IHookrPairRoot(pair).registry()), address(registry));
    }

    function testLauncherRefusesPairRoot() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0));
        uint256 snap = vm.snapshotState();
        launcher.launch(t, address(root), members, vm.getBlockTimestamp());
        vm.revertToState(snap);
        vm.expectRevert();
        launcher.launch(t, pair, members, vm.getBlockTimestamp());
    }

    /// AG-04 / NM-01: a funded pair pool with a valid bound; the Router refuses it as InvalidPool.
    function testRouterAndQuoterRefusePairPool() public {
        PairTestRouter lp = new PairTestRouter(manager);
        tokenA.approve(address(lp), type(uint256).max);
        tokenB.approve(address(lp), type(uint256).max);
        lp.modify(pairKey, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: 0}));
        IHookrRouter.Swap memory s =
            IHookrRouter.Swap(pairKey, true, -1e18, 1, MIN_PRICE, trader, vm.getBlockTimestamp() + 600);
        vm.expectRevert();
        quoter.quote(s, trader);
        vm.prank(trader);
        vm.expectRevert(IHookrRouter.InvalidPool.selector);
        router.swap(s, address(0), new uint256[](0));
        // The same pool trades through a plain v4 router.
        vm.prank(trader);
        tokenA.approve(address(lp), type(uint256).max);
        vm.prank(trader);
        tokenB.approve(address(lp), type(uint256).max);
        vm.prank(trader);
        lp.swap(pairKey, true, -1e18, "");
    }

    /// The instant brake stops new pair roots; existing pair roots keep their registration.
    function testDeactivatedFactoryStopsNewRoots() public {
        registry.deactivateRootFactory(address(factory));
        assertFalse(registry.isRootFactory(address(factory)));
        assertTrue(registry.isRoot(pair));
        IHookrPairRoot.Params memory p = IHookrPairRoot(pair).params();
        p.baseLpFeePips = 500;
        p.maxLpFeePips = 500;
        bytes32 salt = mineSalt(address(factory), address(this), factory.initCodeHash(p), 0);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        factory.deploy(salt, p, SQRT_ONE, "");
    }
}
