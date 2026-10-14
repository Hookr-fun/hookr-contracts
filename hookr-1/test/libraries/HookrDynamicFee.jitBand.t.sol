// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

// M-01 old numbers: LP fee 75,750 -> 3,070 / 3,000 pips with a [0,60) edge band; protocol -7,623 bps;
// founder fees -7,996 bps; subject +965 bps. The dynamic fee read spot liquidity, so a band the swap leaves after
// 1 wei counted as full depth. Fixed: the dynamic fee is priced on the move the simulated swap makes.

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {EconomicsSecurityBase, BandLp} from "../utils/EconomicsSecurityBase.sol";

/// @notice Audit finding M-01.
contract HookrDynamicFeeJitBandTest is EconomicsSecurityBase {
    BandLp internal band;

    function _parkedPool() internal returns (PoolKey memory key, Currency quote) {
        HookrToken subject;
        (key, subject, quote) = _launchMember(_dynamicFeeMember(Currency.wrap(address(0))), true);
        // Park the price just below tick 60 (buy = oneForZero, price up).
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e23);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(60) - 1;
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
        band = new BandLp(manager);
        tokenA.transfer(address(band), 1e28);
        tokenB.transfer(address(band), 1e28);
    }

    function testEdgeBandDoesNotCutDynamicFee() public {
        (PoolKey memory key,) = _parkedPool();
        HookrTypes.ExecutionReceipt memory baseline = _quoteBuy(key, 1e22);
        band.modify(key, 0, 60, 1e27);
        HookrTypes.ExecutionReceipt memory banded = _quoteBuy(key, 1e22);
        assertGe(uint256(banded.lpFeePips) * 100, uint256(baseline.lpFeePips) * 95, "LP fee");
        assertGe(banded.quoteFee * 100, baseline.quoteFee * 95, "protocol");
        assertLe(banded.outputAmount * 10_000, baseline.outputAmount * 10_010, "subject");
        band.modify(key, 0, 60, -1e27);
    }

    function testCrossBlockEdgeBandDoesNotCutDynamicFee() public {
        (PoolKey memory key,) = _parkedPool();
        // Both sides are measured in a later block, after the parking buy.
        vm.roll(vm.getBlockNumber() + 1);
        HookrTypes.ExecutionReceipt memory baseline = _quoteBuy(key, 1e22);
        band.modify(key, 0, 60, 1e27);
        vm.roll(vm.getBlockNumber() + 1);
        HookrTypes.ExecutionReceipt memory banded = _quoteBuy(key, 1e22);
        assertGe(uint256(banded.lpFeePips) * 100, uint256(baseline.lpFeePips) * 95, "LP fee");
        assertGe(banded.quoteFee * 100, baseline.quoteFee * 95, "protocol");
    }

    function testBandSpanningPathIsRealDepth() public {
        (PoolKey memory key,) = _parkedPool();
        // A band across the whole path is the counterparty: the swap trades through it, so it is real depth
        // and the swap moves price less. The dynamic fee follows the smaller move; LP fee never goes below base.
        band.modify(key, 0, 6000, 1e26);
        HookrTypes.ExecutionReceipt memory banded = _quoteBuy(key, 1e22);
        assertGe(banded.lpFeePips, 3000);
        assertLe(banded.lpFeePips, 100_000);
    }
}
