// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {AuditTest} from "./Audit.t.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrToken} from "../src/HookrToken.sol";

/// Independent verification of the reported "Hook Card says the guard cannot tax a sell" finding.
contract VerifySellTaxTest is AuditTest {
    function _sellMeasured(address who, PoolKey memory key, address token, uint256 amt)
        internal
        returns (uint256 ethOut)
    {
        vm.startPrank(who);
        HookrToken(token).approve(address(router), amt);
        uint256 before = who.balance;
        router.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        ethOut = who.balance - before;
    }

    /// Builder-default Anti-Snipe params: 100-block guard, 40% snipe tax.
    function test_VERIFY_sellIsTaxedInsideGuard() public {
        HookrLaunchpad.HookParams memory p = _baseParams();
        p.guardBlocks = 100; // hooks-model.ts guard def
        p.snipeTaxPips = 400_000; // hooks-model.ts tax def = 40%
        p.maxFeePips = p.baseFeePips; // disable surge so the ONLY difference is the snipe tax
        p.burnBps = 0;
        p.lpBps = 0;
        p.potBps = 0;
        p.potOdds = 0;
        p.potMinBuyWei = 0;

        (address token, PoolKey memory key) = _launchAndGraduate(p, "SELL");

        uint256 held = HookrToken(token).balanceOf(alice);
        assertGt(held, 0, "curve buyer holds tokens after graduation");
        uint256 sellAmt = held / 4;

        // --- sell INSIDE the guard window
        uint256 snap = vm.snapshotState();
        uint256 inGuard = _sellMeasured(alice, key, token, sellAmt);
        vm.revertToState(snap);

        // --- identical sell AFTER the guard expires (same pool state)
        vm.roll(block.number + 101);
        uint256 afterGuard = _sellMeasured(alice, key, token, sellAmt);

        console2.log("sell inside guard  (wei out):", inGuard);
        console2.log("sell after guard   (wei out):", afterGuard);
        console2.log("kept share of post-guard proceeds (bps):", (inGuard * 10_000) / afterGuard);

        assertLt(inGuard, afterGuard, "guard taxes the sell");
    }

    /// Control: with snipeTaxPips == 0 the two sells must match, proving the delta above is the tax.
    function test_VERIFY_control_noSnipeTax_sellIdenticalInsideAndOutsideGuard() public {
        HookrLaunchpad.HookParams memory p = _baseParams();
        p.guardBlocks = 100;
        p.snipeTaxPips = 0;
        p.maxFeePips = p.baseFeePips;
        p.burnBps = 0;
        p.lpBps = 0;
        p.potBps = 0;
        p.potOdds = 0;
        p.potMinBuyWei = 0;

        (address token, PoolKey memory key) = _launchAndGraduate(p, "CTL2");
        uint256 sellAmt = HookrToken(token).balanceOf(alice) / 4;

        uint256 snap = vm.snapshotState();
        uint256 inGuard = _sellMeasured(alice, key, token, sellAmt);
        vm.revertToState(snap);
        vm.roll(block.number + 101);
        uint256 afterGuard = _sellMeasured(alice, key, token, sellAmt);

        console2.log("control inside :", inGuard);
        console2.log("control after  :", afterGuard);
        assertEq(inGuard, afterGuard, "without a snipe tax the guard costs a seller nothing");
    }

    /// Does the guard also REFUSE a sell? (the Hook Card's "block my sell" claim)
    function test_VERIFY_sellIsNotReverted_insideGuard() public {
        HookrLaunchpad.HookParams memory p = _baseParams();
        p.guardBlocks = 100;
        p.snipeTaxPips = 400_000;
        p.maxFeePips = p.baseFeePips;
        p.burnBps = 0;
        p.lpBps = 0;
        p.potBps = 0;
        p.potOdds = 0;
        p.potMinBuyWei = 0;

        (address token, PoolKey memory key) = _launchAndGraduate(p, "SEL3");
        uint256 out = _sellMeasured(alice, key, token, HookrToken(token).balanceOf(alice) / 4);
        assertGt(out, 0, "sell goes through, it is not refused");
    }
}
