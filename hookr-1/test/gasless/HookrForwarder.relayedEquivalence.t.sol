// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrForwarder} from "../../src/interfaces/IHookrForwarder.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {GasBenchFixture} from "../utils/GasBenchFixture.sol";

/// @notice F-027: the real Forwarder -> Router.swapFor -> Root path, with real Permit2 and the 4663 PoolManager,
///         fills exactly what a direct Router swap fills from the same state, charges the signer, pays the relayer,
///         and leaves nothing in the Router or Forwarder.
contract HookrForwarderRelayedEquivalenceTest is GasBenchFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _direct(PoolKey memory key, bool buy, int128 amountSpecified, uint128 bound)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        IHookrRouter.Swap memory p = _params(key, buy, 1);
        p.amountSpecified = amountSpecified;
        p.amountBound = bound;
        vm.prank(trader);
        (amountIn, amountOut) = router.swap(p, address(0), new uint256[](0));
    }

    function _relayedShape(PoolKey memory key, bool buy, int128 amountSpecified, uint128 bound, uint256 nonce)
        internal
        returns (uint256 amountIn, uint256 amountOut, uint256 fee)
    {
        IHookrForwarder.HookrSwapIntent memory i = _intent(key, buy, 1, nonce);
        i.amountSpecified = amountSpecified;
        i.amountBound = bound;
        fee = i.relayerFee;
        bytes memory sig = _sign(i);
        vm.prank(RELAYER);
        (amountIn, amountOut) = fwd.execute(i, owner, sig);
    }

    uint256 internal nextNonce = 77;

    function _check(PoolKey memory key, bool buy, int128 amountSpecified, uint128 bound) internal {
        uint256 nonce = nextNonce++;
        HookrToken quote = HookrToken(Currency.unwrap(root.poolConfig(key.toId()).quote));
        uint256 snap = vm.snapshotState();
        (uint256 directIn, uint256 directOut) = _direct(key, buy, amountSpecified, bound);
        vm.revertToState(snap);

        uint256 ownerQuote = quote.balanceOf(owner);
        uint256 ownerSubject = subject.balanceOf(owner);
        uint256 relayerQuote = quote.balanceOf(RELAYER);
        (uint256 amountIn, uint256 amountOut, uint256 fee) = _relayedShape(key, buy, amountSpecified, bound, nonce);
        assertEq(amountIn, directIn, "same input as a direct swap");
        assertEq(amountOut, directOut, "same gross output as a direct swap");
        assertEq(quote.balanceOf(RELAYER), relayerQuote + fee, "relayer fee");
        if (buy) {
            assertEq(quote.balanceOf(owner), ownerQuote - amountIn - fee, "signer paid input and fee");
            assertEq(subject.balanceOf(owner), ownerSubject + amountOut, "signer received output");
        } else {
            assertEq(subject.balanceOf(owner), ownerSubject - amountIn, "signer paid input");
            assertEq(quote.balanceOf(owner), ownerQuote + amountOut - fee, "signer received output less fee");
        }
        assertEq(quote.balanceOf(address(router)), 0);
        assertEq(subject.balanceOf(address(router)), 0);
        assertEq(quote.balanceOf(address(fwd)), 0);
        assertEq(subject.balanceOf(address(fwd)), 0);
        assertEq(quote.allowance(address(fwd), address(router)), 0);
        assertEq(subject.allowance(address(fwd), address(router)), 0);
        assertTrue(rules.accountingInvariant(Currency.wrap(address(quote))));
        assertTrue(fwd.isNonceUsed(owner, nonce));
    }

    function test_exactInputBuy() public {
        _check(feeKey, true, -1e21, 1);
        _check(fullKey, true, -1e21, 1);
    }

    function test_exactInputSell() public {
        _check(feeKey, false, -1e21, 1);
        _check(fullKey, false, -1e21, 1);
    }

    function test_exactOutputBuy() public {
        _check(feeKey, true, 1e20, 1e22);
        _check(fullKey, true, 1e20, 1e22);
    }

    function test_exactOutputSell() public {
        _check(feeKey, false, 1e20, 1e22);
        _check(fullKey, false, 1e20, 1e22);
    }

    /// A relayed partial fill credits its refund to the signer, never the Forwarder, Router or relayer.
    function test_partialFillRefundGoesToSigner() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(fullKey, true, 1e24, 31);
        (uint160 sqrtP,,,) = manager.getSlot0(fullKey.toId());
        i.sqrtPriceLimitX96 = i.zeroForOne ? sqrtP - sqrtP / 1000 : sqrtP + sqrtP / 1000;
        bytes memory sig = _sign(i);
        vm.prank(RELAYER);
        (uint256 amountIn,) = fwd.execute(i, owner, sig);
        Currency q = Currency.wrap(address(quoteFull));
        assertLt(amountIn, 1e24, "partial");
        assertGt(rules.claimable(q, owner), 0, "refund credited to the signer");
        assertEq(rules.claimable(q, address(fwd)), 0);
        assertEq(rules.claimable(q, address(router)), 0);
        assertEq(rules.claimable(q, RELAYER), 0);
        assertEq(quoteFull.balanceOf(address(fwd)), 0, "unused input returned");
    }
}
