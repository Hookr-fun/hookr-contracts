// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {AuditTest} from "./Audit.t.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";

/// Independent verification of the reported "Builder swap-overhead chip omits the base LP fee"
/// finding. Three otherwise-identical pools are graduated and hit with the same buy:
///   A: baseFee 0%,   pot 0%    -> zero-overhead control
///   B: baseFee 0%,   pot 0.5%  -> exactly what the Builder chip claims a jackpot-only stack costs
///   C: baseFee 0.3%, pot 0.5%  -> what compileStack() actually sends on chain
/// maxFeePips == baseFeePips throughout, i.e. surge disabled -- the on-chain shape that
/// activeHookTypes()/hookParamsToStack() decode back into a stack with NO "fee" block.
contract VerifyOverheadChipTest is AuditTest {
    uint256 constant BUY = 0.0002 ether; // small vs pool depth so price impact is near-identical

    function _paramsFor(uint24 baseFeePips, uint16 potBps)
        internal
        pure
        returns (HookrLaunchpad.HookParams memory p)
    {
        p = HookrLaunchpad.HookParams({
            guardBlocks: 0, // isolate the steady-state fee from the snipe tax
            maxBuyBps: 0,
            snipeTaxPips: 0,
            baseFeePips: baseFeePips,
            maxFeePips: baseFeePips, // surge disabled -> decodes as "no Surge Fees block"
            surgeSens: 0,
            burnBps: 0,
            burnTriggerWei: 0,
            lpBps: 0,
            potBps: potBps,
            potOdds: potBps == 0 ? 0 : 500, // hooks-model.ts pot default
            potMinBuyWei: potBps == 0 ? 0 : 1e16 // 0.01 ETH default; our buy is below it
        });
    }

    function _tokensOut(uint24 baseFeePips, uint16 potBps, string memory sym)
        internal
        returns (uint256 out, uint256 potAfter)
    {
        (address token, PoolKey memory key) = _launchAndGraduate(_paramsFor(baseFeePips, potBps), sym);
        // empty hookData -> no jackpot roll, so the pot only accumulates
        BalanceDelta delta = _buy(bob, key, BUY, "");
        out = uint256(uint128(delta.amount1()));
        potAfter = hook.potWei(key.toId());
        token; // silence
    }

    function test_VERIFY_builderChipUnderstatesSwapCost() public {
        uint256 snap = vm.snapshotState();
        (uint256 outA,) = _tokensOut(0, 0, "AAA");
        vm.revertToState(snap);
        (uint256 outB,) = _tokensOut(0, 50, "BBB");
        vm.revertToState(snap);
        (uint256 outC, uint256 potC) = _tokensOut(3000, 50, "CCC");

        uint256 costB = ((outA - outB) * 1_000_000) / outA; // in pips (1e6 = 100%)
        uint256 costC = ((outA - outC) * 1_000_000) / outA;

        console2.log("control tokens out (0% base, 0% pot):", outA);
        console2.log("chip's claim (0% base, 0.5% pot)    :", outB, "cost pips:", costB);
        console2.log("compiled reality (0.3% base, 0.5%)  :", outC, "cost pips:", costC);
        console2.log("pot accrued on the compiled pool (wei):", potC);
        console2.log("buy size (wei):", BUY);

        // The jackpot cut alone is 0.5% of the ETH in.
        assertEq(potC, (BUY * 50) / 10_000, "jackpot cut is 0.5% of the buy");

        // What the Builder chip shows for a jackpot-only stack: ~0.5%.
        assertApproxEqAbs(costB, 5_000, 150, "jackpot-only cost is ~0.50%");

        // What the same stack actually costs once compileStack()'s default 0.3% base LP fee
        // is applied on chain: ~0.8%.
        assertApproxEqAbs(costC, 8_000, 200, "compiled cost is ~0.80%");

        // The gap the chip hides.
        assertApproxEqAbs(costC - costB, 3_000, 100, "hidden base LP fee is ~0.30%");
    }
}
