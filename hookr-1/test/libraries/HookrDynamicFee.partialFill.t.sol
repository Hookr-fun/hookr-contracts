// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

// L-25 old numbers: 476 bps and 3,134 bps shortfall for oversized price-limited buys (the dynamic fee used the
// requested size, not the fill). Fixed: the simulation stops at the limit and charges the move it makes. The limits
// are 120 and 488 ticks: at 20 ticks the quadratic rate charges about 3 pips, whose protocol share rounds to zero, so
// no quote take is reserved and there is no refund to observe.

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {EconomicsSecurityBase} from "../utils/EconomicsSecurityBase.sol";
import {RulesData} from "../utils/RulesData.sol";

/// @notice Audit finding L-25.
contract HookrDynamicFeePartialFillTest is EconomicsSecurityBase {
    function _case(uint24 maxFee, uint16 share, int24 limitTick) internal {
        uint256 snap = vm.snapshotState();
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.rules.maxFeePips = maxFee;
        m.rules.protocolShareBps = share;
        (PoolKey memory key,,) = _launchMember(m, true);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e24);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(limitTick);
        HookrTypes.ExecutionReceipt memory partialFill = quoter.quote(p, trader);
        assertGt(partialFill.quoteRefund, 0, "partial fill");
        // Same movement: an exact-output buy of the same net subject ends at the same price, and its simulation does
        // not depend on the fee. The partial fill must pay that dynamic fee (old: 476 / 3,134 bps short).
        HookrTypes.ExecutionReceipt memory sameMove =
            quoter.quote(_swap(key, true, false, uint128(partialFill.outputAmount)), trader);
        assertApproxEqRel(partialFill.lpFeePips, sameMove.lpFeePips, 0.0025e18, "LP fee vs same movement");
        // Versus a right-sized exact-INPUT buy the gap is not the partial fill's: the exact-input simulation runs at
        // base + LP Rewards (+ Snipe LP) without the dynamic fee itself, so it overestimates its own move and charges
        // more than it moves. Bounded, not equal.
        uint256 spent = partialFill.actualQuote + partialFill.quoteFee;
        HookrTypes.ExecutionReceipt memory right = _quoteBuy(key, uint128(spent));
        assertLe(partialFill.lpFeePips, right.lpFeePips, "exact-input simulation is conservative");
        assertGe(uint256(partialFill.lpFeePips) * 10_000, uint256(right.lpFeePips) * 9_000, "LP fee vs exact input");
        vm.revertToState(snap);
    }

    /// A 10% span at the 25% share, and the widest span the reach bound admits at sensitivity 5 and a 5% share.
    function testPartialFillPaysMeasuredDynamicFee() public {
        _case(100_000, 2_500, 120);
        _case(100_000, 2_500, 488);
        uint24 widest = uint24(3000 + RulesData.maxDynamicFeeSpan(5, 500, 3000));
        _case(widest, 500, 120);
        _case(widest, 500, 488);
    }
}
