// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {RootSecurityBase, MockRules} from "../utils/RootSecurityBase.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";

/// Root side of M-04: exact-output buys reserve X = ceil(S*b/(BPS-b)) subject, burn it and net the caller S.
contract ExactOutputBurnTest is RootSecurityBase {
    using CurrencyLibrary for Currency;

    function setUp() public {
        _setUpRootSecurity();
    }

    function _wrapped(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(root),
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function testExactOutputBuyBurnsGrossUpAndNetsRequested() public {
        PoolKey memory key = _open(_config(address(mock)), bytes("m"), 60);
        _addLiquidity(key, -6000, 6000, 1e23);
        uint256 b = 75;
        mock.setQuotes(HookrTypes.FeeQuote(0, 10_000, uint16(b)), HookrTypes.FeeQuote(0, 0, 0));
        uint256 s = 1e18;
        uint256 x = (s * b + (10_000 - b) - 1) / (10_000 - b);
        uint256 subjectBefore = tokenA.balanceOf(address(this));
        uint256 deadBefore = tokenA.balanceOf(root.DEAD());
        uint256 quoteBefore = manager.balanceOf(address(mock), Currency.wrap(address(tokenB)).toId());
        _genericSwap(key, true, int256(s), 0);
        assertEq(tokenA.balanceOf(address(this)) - subjectBefore, s);
        assertEq(tokenA.balanceOf(root.DEAD()) - deadBefore, x);
        assertGe(x * 10_000, b * (s + x));
        assertLe(x * 10_000, b * (s + x) + 10_000);
        assertGt(manager.balanceOf(address(mock), Currency.wrap(address(tokenB)).toId()), quoteBefore);
        assertEq(manager.balanceOf(address(root), Currency.wrap(address(tokenA)).toId()), 0);
        assertEq(manager.balanceOf(address(root), Currency.wrap(address(tokenB)).toId()), 0);
    }

    function testFuzzReservationBounds(uint256 s, uint16 bSeed) public pure {
        s = bound(s, 1, 1e30);
        uint256 b = bound(bSeed, 1, 1000);
        uint256 x = (s * b + (10_000 - b) - 1) / (10_000 - b);
        assertGe(x * 10_000, b * (s + x));
        assertLe(x * 10_000, b * (s + x) + 10_000);
    }

    function testExactOutputPartialFillWithBurnReverts() public {
        PoolKey memory key = _open(_config(address(mock)), bytes("m"), 60);
        _addLiquidity(key, -600, 600, 1e21);
        mock.setQuotes(HookrTypes.FeeQuote(0, 0, 75), HookrTypes.FeeQuote(0, 0, 0));
        bool zeroForOne = _isBuyZeroForOne(key);
        uint160 limit =
            zeroForOne ? uint160(uint256(SQRT_ONE) * 9990 / 10_000) : uint160(uint256(SQRT_ONE) * 10_010 / 10_000);
        vm.expectRevert();
        _genericSwap(key, true, 1e22, limit);
    }

    function testExactOutputPartialFillWithoutBurnStillWorks() public {
        PoolKey memory key = _open(_config(address(mock)), bytes("m"), 60);
        _addLiquidity(key, -600, 600, 1e21);
        mock.setQuotes(HookrTypes.FeeQuote(0, 10_000, 0), HookrTypes.FeeQuote(0, 0, 0));
        bool zeroForOne = _isBuyZeroForOne(key);
        uint160 limit =
            zeroForOne ? uint160(uint256(SQRT_ONE) * 9990 / 10_000) : uint160(uint256(SQRT_ONE) * 10_010 / 10_000);
        _genericSwap(key, true, 1e22, limit);
    }
}
