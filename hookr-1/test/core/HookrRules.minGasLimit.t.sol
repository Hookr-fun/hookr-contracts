// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {EconomicsSecurityBase, BandLp} from "../utils/EconomicsSecurityBase.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {DustRangeSwapper} from "../utils/DustRangeSwapper.sol";

/// @notice F-004: a 64-step dynamic-fee walk cost up to about 780k gas, so a Rules admission below that turned dust
///         ticks into a cap on single-swap size (a 5e21 buy reverted `ModuleCallFailed` at a 500k admission).
/// @dev Rules admissions require `RULES_MIN_GAS_LIMIT = 2_000_000`, the admission maximum. The dynamic fee is priced on a
///      swap the root simulates in its own frame, so the Rules call no longer grows with the pool's ticks; the dust
///      layouts that once filled the walk fill a large buy in full.
contract HookrRulesMinGasLimitTest is EconomicsSecurityBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _admission(HookrRules r, uint32 limit) internal view returns (IHookrRegistry.Admission memory) {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: address(r),
            codeHash: address(r).codehash,
            schemaHash: r.configSchemaHash(),
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: limit,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
    }

    function testSubFloorRulesAdmissionsRefused() public {
        assertEq(registry.RULES_MIN_GAS_LIMIT(), 2_000_000);
        HookrRules r = new HookrRules(manager, registry, protocol, address(root), 0);
        bytes32 admitKind = registry.ADMIT();
        uint32[6] memory limits = [uint32(500_000), 700_000, 750_000, 999_999, 1_000_000, 1_999_999];
        for (uint256 i; i < limits.length; ++i) {
            IHookrRegistry.Admission memory a = _admission(r, limits[i]);
            // Old: queued and admitted.
            vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
            registry.queue(admitKind, abi.encode(address(root), a));
            vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
            registry.admit(address(root), a);
        }
    }

    function testAdvisoryFloorUnchanged() public {
        HookrRules r = new HookrRules(manager, registry, protocol, address(root), 0);
        IHookrRegistry.Admission memory a = _admission(r, 250_000);
        a.kind = IHookrRegistry.Kind.ADVISORY;
        a.phaseMask = 1;
        a.caps = HookrTypes.Caps(0, 0, 0);
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        assertEq(registry.admission(address(root), address(r)).gasLimit, 250_000);
    }

    function testWordEdgeDustFillsAtTheFloor() public {
        uint32 limit = registry.RULES_MIN_GAS_LIMIT();
        HookrRules r = new HookrRules(manager, registry, protocol, address(root), 0);
        IHookrRegistry.Admission memory a = _admission(r, limit);
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);

        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        // The densest tick spacing.
        int24 sp = 1;
        m.tickSpacing = sp;
        m.config.rules = address(r);
        m.config.rulesGasLimit = limit;
        (PoolKey memory key,,) = _launchMember(m, true);
        BandLp band = new BandLp(manager);
        tokenA.transfer(address(band), 1e22);
        tokenB.transfer(address(band), 1e22);
        vm.roll(vm.getBlockNumber() + 1);
        // One dust band per bitmap word, then every spacing from 1 to 70 on top.
        for (uint256 i; i < 66; ++i) {
            int24 lower = (int24(int256(i)) * 256 + 255) * sp;
            band.modify(key, lower, lower + 256 * sp, 1);
        }
        for (uint256 i; i < 70; ++i) {
            band.modify(key, (int24(int256(i)) + 1) * sp, (int24(int256(i)) + 2) * sp, 1);
        }
        vm.roll(vm.getBlockNumber() + 1);
        (uint256 inAmt, uint256 outAmt) = _buyAs(trader, key, 5e24);
        assertEq(inAmt, 5e24, "full fill at the floor");
        assertGt(outAmt, 0);
    }

    /// @dev A sens-10 dynamic fee pool at spacing 16 with all liquidity below tick 0. The price is parked at the top edge by
    ///      a free 1-wei sell, then 70 dust bands go just above tick 0: the layout that made the walk cross ~216 empty
    ///      bitmap words and then its step limit.
    function _deepestWalk() internal returns (PoolKey memory key, HookrRules r) {
        uint32 limit = registry.RULES_MIN_GAS_LIMIT();
        r = new HookrRules(manager, registry, protocol, address(root), 0);
        IHookrRegistry.Admission memory a = _admission(r, limit);
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.rules.dynamicFeeSens = 10;
        // The widest span the reach bound admits at sensitivity 10 (HookrDynamicFee.MAX_REACH / 100 = 72,000).
        m.rules.maxFeePips = 75_000;
        m.tickSpacing = 16;
        m.tickLower = -60_000;
        m.tickUpper = 0;
        m.config.rules = address(r);
        m.config.rulesGasLimit = limit;
        (key,,) = _launchMember(m, false);
        vm.roll(vm.getBlockNumber() + 1);
        new DustRangeSwapper(manager).swap(key, false, -1, TickMath.MAX_SQRT_PRICE - 1);
        BandLp band = new BandLp(manager);
        tokenA.transfer(address(band), 1e22);
        tokenB.transfer(address(band), 1e22);
        for (int24 i; i < 70; ++i) {
            band.modify(key, 16 * i, 16 * (i + 1), 1);
        }
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// The walk's deepest layout: the buy fills, and Rules price its dynamic fee within 100k gas whatever the layout.
    function testDeepestWalkLayoutFills() public {
        assertEq(registry.RULES_MIN_GAS_LIMIT(), 2_000_000);
        (PoolKey memory key, HookrRules r) = _deepestWalk();
        HookrTypes.SwapContext memory x = HookrTypes.SwapContext({
            id: key.toId(),
            sender: trader,
            payer: trader,
            beneficiary: trader,
            subject: key.currency1,
            quote: key.currency0,
            authenticated: false,
            isBuy: true,
            exactInput: true,
            zeroForOne: true,
            amountSpecified: -1e21,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
            baseLpFeePips: 3000
        });
        (uint160 edge, int24 edgeTick,,) = manager.getSlot0(key.toId());
        HookrTypes.SwapSimulation memory sim =
            HookrTypes.SwapSimulation(edge, edgeTick, TickMath.getSqrtPriceAtTick(-2000), -2000);
        bytes memory call = abi.encodeCall(HookrRules.quoteSimulatedSwap, (x, sim));
        uint256 snap = vm.snapshotState();
        vm.prank(address(root));
        (bool ok,) = address(r).call{gas: 100_000}(call);
        assertTrue(ok, "Rules price the dynamic fee within 100k gas");
        vm.revertToState(snap);
        (uint256 inAmt, uint256 outAmt) = _buyAs(trader, key, 1e21);
        assertEq(inAmt, 1e21, "full fill at the floor");
        assertGt(outAmt, 0);
    }
}
