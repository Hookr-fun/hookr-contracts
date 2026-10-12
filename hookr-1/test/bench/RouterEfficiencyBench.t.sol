// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrQuoter} from "../../src/interfaces/IHookrQuoter.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";
import {GasBenchFixture} from "../utils/GasBenchFixture.sol";
import {GasMeasure} from "../utils/GasMeasure.sol";

/// @notice Per-transaction gas for quotes and for a router buy that an Immediate points program records. Same fixture
///         and method as GasBench (real 4663 PoolManager runtime); run it with
///         `forge test --isolate --match-path test/bench/RouterEfficiencyBench.t.sol -vv`. The totals are committed
///         in snapshots/RouterEfficiencyBench.json.
contract RouterEfficiencyBench is GasBenchFixture, GasMeasure {
    using PoolIdLibrary for PoolKey;

    HookrPrograms internal programs;
    uint256 internal programId;

    function setUp() public override {
        super.setUp();
        // An Immediate points program on the fee-only pool, recorded by router buys. Its rates leave a nonzero
        // carry on both levels, as most real rates do.
        programs =
            new HookrPrograms(manager, address(router), address(this), 10_000, address(new HookrReferralRegistry()));
        P.Terms memory t;
        t.mode = P.Mode.Immediate;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 30 days;
        t.pointBudget = type(uint128).max;
        t.walletPointCap = type(uint128).max;
        t.pointNumerator = 1;
        t.pointDenominator = 3;
        t.sourcePolicyHash = keccak256("bench");
        t.name = "Bench";
        t.metadataURI = "ipfs://bench";
        t.pointDecimals = 18;
        P.Scope[] memory sources = new P.Scope[](1);
        PoolId id = feeKey.toId();
        sources[0] =
            P.Scope(address(root), PoolId.unwrap(id), root.policyHash(id), address(quoteFee), 1, 1e15 + 7, 0, 0);
        programId = programs.createProgram(t, sources, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
        vm.warp(t.start);
    }

    // ───────────────────────────── quotes ─────────────────────────────

    function test_gas_quote_fee_buy() public {
        _warm(feeKey);
        quoter.quote(_params(feeKey, true, 1e18), trader);
        _measure("quote.fee.buy");
    }

    function test_gas_quote_full_buy() public {
        _warm(fullKey);
        quoter.quote(_params(fullKey, true, 1e18), trader);
        _measure("quote.full.buy");
    }

    function test_gas_quote_full_sell() public {
        _warm(fullKey);
        quoter.quote(_params(fullKey, false, 1e18), trader);
        _measure("quote.full.sell");
    }

    /// @dev Uniswap IV4Quoter's single-pool shape, quoted by the trader (payer and recipient).
    function _single(PoolKey memory key, bool buy) internal view returns (IHookrQuoter.QuoteExactSingleParams memory) {
        return IHookrQuoter.QuoteExactSingleParams(key, _zeroForOne(key, buy), 1e18, "");
    }

    function test_gas_quote_single_fee_buy() public {
        _warm(feeKey);
        vm.prank(trader);
        quoter.quoteExactInputSingle(_single(feeKey, true));
        _measure("quote.single.fee.buy");
    }

    function test_gas_quote_single_full_buy() public {
        _warm(fullKey);
        vm.prank(trader);
        quoter.quoteExactInputSingle(_single(fullKey, true));
        _measure("quote.single.full.buy");
    }

    function test_gas_quote_detailed_full_buy() public {
        _warm(fullKey);
        quoter.quoteDetailed(_params(fullKey, true, 1e18), trader);
        _measure("quote.detailed.full.buy");
    }

    // ───────────────────────────── recorded router buys ─────────────────────────────

    function _programBuy() internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = programId;
        IHookrRouter.Swap memory p = _params(feeKey, true, 1e18);
        vm.prank(trader);
        router.swap(p, address(programs), ids);
    }

    /// @dev The trader's first credit in the program: its points and both carries start at zero.
    function test_gas_router_immediateProgram_firstBuy() public {
        _warm(feeKey);
        _programBuy();
        _measure("router.immediateProgram.buy.first");
        assertGt(programs.points(programId, trader), 0);
    }

    /// @dev The pool warmed and two recorded buys made: the trader holds points, and both carries are nonzero (the
    ///      first buy's weight is 999, which leaves no point carry; the second's is 1,000, which leaves one).
    function _steady() internal {
        _warm(feeKey);
        _programBuy();
        _nextBlock();
        _programBuy();
        _nextBlock();
    }

    /// @dev Steady state: every slot the credit writes already holds a nonzero value, except the new receipt's
    ///      replay mark.
    function test_gas_router_immediateProgram_buy() public {
        _steady();
        _programBuy();
        _measure("router.immediateProgram.buy");
    }

    /// @dev Reference: the same buy without engagement.
    function test_gas_router_fee_buy_noProgram() public {
        _steady();
        _routerSwap(feeKey, true, 1e18);
        _measure("router.fee.buy.noProgram");
    }

    /// @dev What recording a swap costs in the steady state: the recorded buy less the same buy without engagement,
    ///      each its own transaction on the same pool.
    function test_gas_router_immediateProgram_recordCost() public {
        _steady();
        _routerSwap(feeKey, true, 1e18);
        uint256 plain = _measure("router.fee.buy.steady");
        _nextBlock();
        _programBuy();
        uint256 recorded = _measure("router.immediateProgram.buy.steady");
        _record("router.immediateProgram.recordCost", recorded - plain);
    }
}
