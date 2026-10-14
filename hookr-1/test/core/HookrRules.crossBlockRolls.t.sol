// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {EconomicsSecurityBase} from "../utils/EconomicsSecurityBase.sol";

/// F-066: under via-IR a test may read a cached NUMBER after vm.roll, so `vm.roll(block.number + 1)` twice can
/// land in one block and a "cross-block" test runs in a single parent block. Tests roll from vm.getBlockNumber() and
/// warp from vm.getBlockTimestamp(); the dynamic fee reference window is counted in block.timestamp.
contract HookrRulesCrossBlockRollsTest is EconomicsSecurityBase {
    function testSuccessiveRollsAdvanceAndResetTheDynamicFeeWindow() public {
        (PoolKey memory key,,) = _launchMember(_dynamicFeeMember(Currency.wrap(address(0))), true);
        uint256 start = vm.getBlockNumber();
        vm.roll(vm.getBlockNumber() + 1);
        _buyAs(trader, key, 1e23);
        HookrTypes.ExecutionReceipt memory sameBlock = _quoteBuy(key, 1e22);
        uint256 t = vm.getBlockTimestamp();
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + _dynamicFeeReset());
        assertEq(vm.getBlockNumber(), start + 2, "both rolls advanced");
        assertEq(vm.getBlockTimestamp(), t + _dynamicFeeReset(), "the warp advanced");
        HookrTypes.ExecutionReceipt memory nextBlock = _quoteBuy(key, 1e22);
        assertGt(sameBlock.lpFeePips, nextBlock.lpFeePips, "same-window flow is priced, a quiet reset starts fresh");
    }
}
