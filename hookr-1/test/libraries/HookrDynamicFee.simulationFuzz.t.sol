// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrDynamicFee} from "../../src/libraries/HookrDynamicFee.sol";
import {EconomicsSecurityBase, BandLp} from "../utils/EconomicsSecurityBase.sol";
import {RulesData} from "../utils/RulesData.sol";

/// DF-02: the dynamic fee a swap is charged against the dynamic fee its executed end price implies, over random
/// pools (sensitivity, span, rules, tick spacing, launch tick, third-party bands from dust to deep) and random swaps
/// (both directions, exact input and output, sizes, price limits). The first swap on a fresh pool, so the reference
/// and the anchor are the launch price. The charge never falls below the executed move; an exact-output buy, whose
/// fill does not depend on its fee, is charged the executed move exactly. (Replaces verify6's walk-versus-reference
/// differential fuzz: there is no walk.)
contract HookrDynamicFeeSimulationFuzzTest is EconomicsSecurityBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    BandLp internal bands;
    address internal victim = address(0xB0B);

    function setUp() public override {
        super.setUp();
        bands = new BandLp(manager);
        tokenA.transfer(address(bands), 1e28);
        tokenB.transfer(address(bands), 1e28);
        tokenA.transfer(victim, 1e28);
        tokenB.transfer(victim, 1e28);
        vm.startPrank(victim);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _pick(uint256 seed, uint256 salt, uint256 n) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt))) % n;
    }

    function _lpFee(IHookrLauncher.Member memory m, bool buy, uint256 dynamicFee) internal pure returns (uint256) {
        uint256 share = m.rules.protocolShareBps;
        uint256 base = m.config.baseLpFeePips;
        uint256 lpReward;
        if (buy) {
            uint256 lpNet = uint256(m.rules.lpBps) * 100 - (uint256(m.rules.lpBps) * share + 99) / 100;
            lpReward = lpNet - lpNet * m.rules.royaltyBps / 10_000;
        }
        uint256 room = 600_000 - base - lpReward;
        if (dynamicFee > room) dynamicFee = room;
        return base + lpReward + dynamicFee - dynamicFee * share / 10_000;
    }

    function _pool(uint256 seed) internal returns (PoolKey memory key, IHookrLauncher.Member memory m, int24 tick) {
        m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.rules.dynamicFeeSens = uint16(1 + _pick(seed, 1, 10));
        uint24[4] memory spans = [uint24(10_000), 50_000, 100_000, 600_000];
        m.rules.maxFeePips = spans[_pick(seed, 2, 4)];
        // At most the widest span the reach bound admits at the pool's sensitivity and share.
        RulesData.clampToReach(m.rules, 3000);
        if (_pick(seed, 3, 2) == 1) {
            m.rules.burnBps = 100;
            m.rules.lpBps = 200;
            m.rules.royaltyBps = 500;
            m.rules.royaltyTo = royalty;
        }
        int24[4] memory spacings = [int24(1), 10, 60, 200];
        int24 spacing = spacings[_pick(seed, 4, 4)];
        m.tickSpacing = spacing;
        tick = int24(int256(_pick(seed, 5, 40_001))) - 20_000;
        m.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        int24 aligned = tick / spacing * spacing;
        m.tickLower = aligned - 30_000 / spacing * spacing;
        m.tickUpper = aligned + 30_000 / spacing * spacing;
        m.amount0Max = 1e27;
        m.amount1Max = 1e27;
        (key,,) = _launchMember(m, _pick(seed, 6, 2) == 1);
        vm.roll(vm.getBlockNumber() + 1);
        int256[4] memory depths = [int256(1), 1e12, 1e20, 1e24];
        uint256 count = _pick(seed, 7, 4);
        for (uint256 i; i < count; ++i) {
            int24 lower = (aligned + int24(int256(_pick(seed, 10 + i, 20_001))) - 10_000) / spacing * spacing;
            int24 width = (1 + int24(int256(_pick(seed, 20 + i, 50)))) * spacing;
            bands.modify(key, lower, lower + width, depths[_pick(seed, 30 + i, 4)]);
        }
    }

    function testFuzz_chargeCoversTheExecutedMove(uint256 seed) public {
        (PoolKey memory key, IHookrLauncher.Member memory m, int24 launchTick) = _pool(seed);
        bool buy = _pick(seed, 40, 2) == 1;
        bool exactInput = _pick(seed, 41, 2) == 1;
        uint128 amount = uint128(10 ** (15 + _pick(seed, 42, 9)) * (1 + _pick(seed, 43, 9)));
        IHookrRouter.Swap memory p = _swap(key, buy, exactInput, amount);
        p.recipient = victim;
        if (_pick(seed, 44, 2) == 1) {
            int24 limit = launchTick + (p.zeroForOne ? -int24(1) : int24(1)) * int24(int256(1 + _pick(seed, 45, 5000)));
            p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(limit);
        }
        HookrTypes.ExecutionReceipt memory r;
        try quoter.quote(p, victim) returns (HookrTypes.ExecutionReceipt memory q) {
            r = q;
        } catch {
            // Shapes the pool cannot fill (an exact output past its liquidity) revert in the real swap as well.
            return;
        }
        vm.prank(victim);
        router.swap(p, address(0), new uint256[](0));
        (uint160 end,,,) = manager.getSlot0(key.toId());
        int256 dist = HookrDynamicFee.distance(TickMath.getSqrtPriceAtTick(launchTick), end, p.zeroForOne);
        uint256 ideal;
        if (dist > 0) {
            ideal = uint256(m.rules.maxFeePips - 3000)
                * HookrDynamicFee.averageRate(0, uint256(dist), m.rules.dynamicFeeSens) / HookrDynamicFee.WAD;
        }
        uint256 floorFee = _lpFee(m, buy, ideal);
        assertGe(uint256(r.lpFeePips) + 1, floorFee, "never below the executed move");
        if (buy && !exactInput) assertApproxEqAbs(r.lpFeePips, floorFee, 1, "an exact-output buy is exact");
        assertTrue(rules.accountingInvariant(key.currency0) && rules.accountingInvariant(key.currency1));
    }
}
