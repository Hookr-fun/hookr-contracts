// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {EconomicsSecurityBase} from "../utils/EconomicsSecurityBase.sol";
import {RulesData} from "../utils/RulesData.sol";

/// @notice SA-01: an exact-output sell is simulated on at least the pool's gross output, the seller's quote plus the
///         reserved quote take, so its dynamic fee never falls below the movement the pool makes.
contract HookrRulesExactOutSellSimulationTest is EconomicsSecurityBase {
    function _dynamicFeePips(uint24 maxFee, uint16 share, uint128 q)
        internal
        returns (uint256 dynamicFee, uint256 take, uint256 actualQuote)
    {
        uint256 snap = vm.snapshotState();
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.rules.maxFeePips = maxFee;
        m.rules.protocolShareBps = share;
        m.rules.dynamicFeeSens = 5;
        (PoolKey memory key,,) = _launchMember(m, true);
        vm.roll(vm.getBlockNumber() + 1);
        HookrTypes.ExecutionReceipt memory r = quoter.quote(_swap(key, false, false, q), trader);
        // lpFeePips = base + dynamicFee - protocolPips; the quote take rate is protocolPips of actualQuote.
        uint256 protocolPips = (r.quoteFee * 1e6 + r.actualQuote - 1) / r.actualQuote;
        dynamicFee = r.lpFeePips - 3000 + protocolPips;
        take = r.quoteFee;
        actualQuote = r.actualQuote;
        vm.revertToState(snap);
    }

    function _check(uint24 maxFee, uint128 q) internal {
        (uint256 charged, uint256 take, uint256 actualQuote) = _dynamicFeePips(maxFee, 3000, q);
        assertGt(take, 0);
        assertEq(actualQuote, q + take, "the pool delivers Q plus the reserved take");
        // A share of zero reserves nothing, so its simulation of Q + take is exactly the pool's movement.
        (uint256 gross,,) = _dynamicFeePips(maxFee, 0, q + uint128(take));
        assertGe(charged, gross, "exact-output sell dynamic fee covers the pool's gross output");
    }

    /// At the widest span the reach bound admits at sensitivity 5 and the 30% share, and at a 5% span.
    function test_exactOutSellSimulatesGrossOutput() public {
        uint24 widest = uint24(3000 + RulesData.maxDynamicFeeSpan(5, 3000, 3000));
        _check(widest, 5e22);
        _check(widest, 1e23);
        _check(widest, 2e23);
        _check(53_000, 5e22);
        _check(53_000, 2e23);
    }
}
