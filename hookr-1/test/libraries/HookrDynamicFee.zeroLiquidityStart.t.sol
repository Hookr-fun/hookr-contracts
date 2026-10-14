// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

// L-05 old numbers: 3,000 pips at open (dynamic fee 0 because spot liquidity was 0 at the range boundary);
// -0.246 / -0.985 ETH protocol at 5 / 10 ETH. Fixed: the simulated swap crosses into the range and moves through it.

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {EconomicsSecurityBase} from "../utils/EconomicsSecurityBase.sol";

/// @notice Audit finding L-05.
contract HookrDynamicFeeZeroLiquidityStartTest is EconomicsSecurityBase {
    function _open(int24 upper, uint128 amount) internal returns (HookrTypes.ExecutionReceipt memory r) {
        uint256 snap = vm.snapshotState();
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickLower = -60_000;
        m.tickUpper = upper;
        // Quote is currency0: a buy is zeroForOne and moves the price down into [-60000, upper).
        (PoolKey memory key,,) = _launchMember(m, false);
        r = _quoteBuy(key, amount);
        vm.revertToState(snap);
    }

    function testBoundaryOpenPaysInRangeDynamicFee() public {
        uint128[2] memory amounts = [uint128(5e21), 1e22];
        for (uint256 i; i < 2; ++i) {
            HookrTypes.ExecutionReceipt memory boundary = _open(0, amounts[i]);
            HookrTypes.ExecutionReceipt memory control = _open(60, amounts[i]);
            assertGt(boundary.lpFeePips, 3000, "dynamic fee charged at the boundary");
            assertGe(uint256(boundary.lpFeePips) * 100, uint256(control.lpFeePips) * 95, "LP fee");
            assertGe(boundary.quoteFee * 100, control.quoteFee * 95, "protocol");
        }
    }
}
