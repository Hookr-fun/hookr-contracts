// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IHookrQuoter} from "../../src/interfaces/IHookrQuoter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {GasBenchFixture} from "../utils/GasBenchFixture.sol";
import {HookrQuoter} from "../../src/lens/HookrQuoter.sol";

/// @notice The quoter applies the router's own swap preflight (HookrSwapPreflight) before simulating, so it never
///         quotes a swap the router refuses on recipient, amount or deadline grounds, and it keeps its request state
///         in transient storage: no persistent slot is read or written, and several quotes run in one transaction.
contract QuoterPreflightTest is GasBenchFixture {
    function _refusedByBoth(IHookrRouter.Swap memory p) internal {
        vm.expectRevert(IHookrQuoter.InvalidQuote.selector);
        quoter.quote(p, trader);
        vm.prank(trader);
        vm.expectRevert(IHookrRouter.InvalidSwap.selector);
        router.swap(p, address(0), new uint256[](0));
    }

    function test_quoteRefusesEveryRecipientTheRouterRefuses() public {
        address[4] memory refused = [address(0), address(router), address(manager), address(fwd)];
        for (uint256 i; i < refused.length; ++i) {
            IHookrRouter.Swap memory p = _params(feeKey, true, 1e18);
            p.recipient = refused[i];
            _refusedByBoth(p);
        }
    }

    function test_quoteRefusesTheRoutersAmountAndDeadlineCases() public {
        IHookrRouter.Swap memory p = _params(fullKey, false, 1e18);
        p.amountSpecified = 0;
        _refusedByBoth(p);
        p = _params(fullKey, false, 1e18);
        p.amountSpecified = type(int128).min;
        _refusedByBoth(p);
        p = _params(fullKey, false, 1e18);
        p.amountBound = 0;
        _refusedByBoth(p);
        p = _params(fullKey, false, 1e18);
        p.deadline = vm.getBlockTimestamp() - 1;
        _refusedByBoth(p);
    }

    function test_quoteRefusesZeroPayer() public {
        vm.expectRevert(IHookrQuoter.InvalidQuote.selector);
        quoter.quote(_params(feeKey, true, 1e18), address(0));
    }

    /// What the preflight admits, the router executes for exactly the quoted amounts.
    function test_quoteMatchesTheRoutersExecution() public {
        _warm(fullKey);
        IHookrRouter.Swap memory p = _params(fullKey, true, 1e19);
        HookrTypes.ExecutionReceipt memory q = quoter.quote(p, trader);
        vm.prank(trader);
        (uint256 amountIn, uint256 amountOut) = router.swap(p, address(0), new uint256[](0));
        assertEq(q.inputAmount, amountIn);
        assertEq(q.outputAmount, amountOut);
    }

    function test_quoteTouchesNoPersistentStorage() public {
        _warm(feeKey);
        vm.record();
        quoter.quote(_params(feeKey, true, 1e18), trader);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(quoter));
        assertEq(reads.length, 0, "no persistent read");
        assertEq(writes.length, 0, "no persistent write");
    }

    /// The state resets explicitly after every quote, including one that fails in simulation, so later quotes in the
    /// same transaction run.
    function test_severalQuotesInOneTransaction() public {
        _warm(fullKey);
        IHookrRouter.Swap memory p = _params(fullKey, true, 1e18);
        HookrTypes.ExecutionReceipt memory first = quoter.quote(p, trader);
        IHookrRouter.Swap memory unfillable = _params(fullKey, true, 1e18);
        unfillable.amountBound = type(uint128).max;
        try quoter.quote(unfillable, trader) {
            revert("an unfillable bound must not quote");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), IHookrQuoter.SimulationFailed.selector);
        }
        HookrTypes.ExecutionReceipt memory second = quoter.quote(p, trader);
        assertEq(second.outputAmount, first.outputAmount);
        assertGt(quoter.quote(_params(feeKey, false, 1e18), trader).outputAmount, 0);
    }

    function test_helpersStillRejectCallsOutsideTheQuote() public {
        HookrQuoter.Request memory request;
        vm.expectRevert(IHookrQuoter.InvalidCallback.selector);
        quoter.simulate(request);
        vm.prank(address(manager));
        vm.expectRevert(IHookrQuoter.InvalidCallback.selector);
        quoter.unlockCallback("");
    }
}
