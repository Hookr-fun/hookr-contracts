// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {KothWashFixture} from "./utils/KothWashFixture.sol";

/// @notice The King of the Pool pot release (review finding M-2, flipped): every closed epoch releases half of the
///         remainder to the pool's LP accrual, so the carried pot is bounded by the epoch's inflow, and an idle
///         pot drains to the liquidity owner.
contract KothPotReleaseTest is KothWashFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// REVIEW M-2, flipped. Ordinary two-way traffic fills the pot faster than one capped prize per epoch drains it.
    /// Every closed epoch now releases half of the remainder to the pool's LP accrual, so the carried pot is bounded
    /// by the epoch's inflow instead of growing without bound.
    function test_carriedPotReleasesHalfEachEpoch() public {
        for (uint256 epoch; epoch < 3; ++epoch) {
            _tradeAndCloseEpoch();
        }
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// @dev Ten two-way round trips, then the rollover. Checks the carry and the release.
    function _tradeAndCloseEpoch() internal {
        (uint64 start,,, uint128 carriedIn) = _hill(key);
        for (uint256 i; i < 10; ++i) {
            address t = i % 2 == 0 ? whale : minnow;
            _sell(key, ETH, t, _buy(key, ETH, t, 2e22));
        }
        (,, uint128 lead, uint128 pot) = _hill(key);
        uint256 lpBefore = _accrued(key);
        vm.warp(uint256(start) + PERIOD);
        _recap().settleEpoch(key.toId());
        (,,, uint128 afterPot) = _hill(key);
        uint256 lpAfter = _accrued(key);
        uint256 prize = uint256(lead) * 50 / 10_000;
        if (prize > pot) prize = pot;
        assertEq(afterPot, (pot - prize) / 2, "half the remainder carries");
        assertEq(lpAfter - lpBefore, pot - prize - afterPot, "the other half joins the LP accrual");
        assertLe(afterPot, uint256(pot) - carriedIn, "the carried pot never exceeds the epoch's inflow");
    }

    /// REVIEW M-2, the idle case, flipped. Once a pool stops trading, every later epoch halves the pot into the LP
    /// accrual; after a year the pot is empty and the family owner claims all of it through the launcher.
    function test_idlePotDrainsToLiquidityOwner() public {
        _fillPotWithUnauthenticatedTraffic(2);
        (uint64 start,,, uint128 pot) = _hill(key);
        assertGt(pot, 0);
        uint256 lpBefore = _accrued(key);
        uint256 held = manager.balanceOf(address(rules), ETH.toId());
        vm.warp(uint256(start) + 365 days);
        _recap().settleEpoch(key.toId());
        (uint64 later, address leader,, uint128 potLater) = _hill(key);
        assertGt(later, start + 364 days);
        assertEq(leader, address(0));
        assertEq(potLater, 0, "a year of idle epochs empties the pot");
        uint256 lp = _accrued(key);
        assertEq(lp - lpBefore, pot, "into the LP share, pending");
        assertEq(rules.totalLiability(ETH), held, "backing unchanged until donated");
        // The swap fees so far, then the next block's first add donates the LP share to the in-range liquidity (all
        // the creator's) before it lands; the family owner collects it as fees through the launcher.
        vm.prank(creator);
        launcher.withdraw(family, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        _nextBlock();
        _newActor(key).modify(key, 60_000, 60_060, 1e18);
        _flushAll(key);
        assertEq(_accrued(key), 0, "donated");
        assertEq(rules.totalLiability(ETH), held - lp, "the donation burned its backing");
        uint256 before = creator.balance;
        vm.prank(creator);
        launcher.withdraw(family, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        assertApproxEqAbs(creator.balance - before, lp, 2, "the family owner collects it as fees");
        assertTrue(rules.accountingInvariant(ETH));
    }
}
