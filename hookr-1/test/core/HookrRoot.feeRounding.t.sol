// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {RootSecurityBase} from "../utils/RootSecurityBase.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";

/// @notice The root rounds what it takes from an exact-input swap down, so the trader never pays a wei over the rate:
///         the quote take of an exact-input sell is quote x rate / 1,000,000 and the burn of an exact-input buy is
///         subject x bps / 10,000, each floored. Mutation gate RT-2 (the sell's take rounded up) and RT-8 (the burn
///         rounded up); every other test priced these on round numbers.
contract RootFeeRoundingTest is RootSecurityBase {
    uint256 internal constant PIPS = 1_000_000;

    function setUp() public {
        _setUpRootSecurity();
    }

    function _pool() internal returns (PoolKey memory key) {
        key = _open(_config(address(mock)), bytes("m"), 60);
        _addLiquidity(key, -600, 600, 1e22);
    }

    /// An exact-input sell takes floor(gross quote x rate): the take the seller gives up is the quote out of the pool
    /// less what the seller receives, and it never exceeds the floored share.
    function testFuzz_exactInputSellTakeRoundsDown(uint128 amount, uint16 rateSeed) public {
        amount = uint128(bound(amount, 1e12, 1e20));
        uint24 rate = uint24(bound(rateSeed, 1, 10_000)) * 7 + 3;
        PoolKey memory key = _pool();
        mock.setQuotes(HookrTypes.FeeQuote(0, 0, 0), HookrTypes.FeeQuote(0, rate, 0));
        uint256 id = Currency.wrap(address(tokenB)).toId();
        uint256 claimsBefore = manager.balanceOf(address(mock), id);
        uint256 netBefore = tokenB.balanceOf(address(this));
        _genericSwap(key, false, -int256(uint256(amount)), 0);
        uint256 take = manager.balanceOf(address(mock), id) - claimsBefore;
        uint256 gross = tokenB.balanceOf(address(this)) - netBefore + take;
        assertEq(take, gross * rate / PIPS, "the take is the floored share of the quote out");
    }

    /// An exact-input buy burns floor(subject out x bps / 10,000) of the subject the pool pays out.
    function testFuzz_exactInputBuyBurnRoundsDown(uint128 amount, uint16 bpsSeed) public {
        amount = uint128(bound(amount, 1e12, 1e20));
        uint16 bps = uint16(bound(bpsSeed, 1, 1_000));
        PoolKey memory key = _pool();
        mock.setQuotes(HookrTypes.FeeQuote(0, 0, bps), HookrTypes.FeeQuote(0, 0, 0));
        uint256 netBefore = tokenA.balanceOf(address(this));
        uint256 deadBefore = tokenA.balanceOf(root.DEAD());
        _genericSwap(key, true, -int256(uint256(amount)), 0);
        uint256 burned = tokenA.balanceOf(root.DEAD()) - deadBefore;
        uint256 gross = tokenA.balanceOf(address(this)) - netBefore + burned;
        assertEq(burned, gross * bps / 10_000, "the burn is the floored share of the subject out");
    }
}
