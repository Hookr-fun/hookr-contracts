// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {Actor} from "./mocks/Actors.sol";
import {ScriptedLaneFixture} from "./utils/ScriptedLaneFixture.sol";

/// @notice One transaction carrying a third party's liquidity changes and an honest buy.
contract LiquidityBundler {
    struct Change {
        Actor lp;
        int24 lower;
        int24 upper;
        int256 liquidity;
    }

    function run(Change[] memory changes, Actor buyer, IHookrRouter.Swap memory buy, uint256 value) external {
        for (uint256 i; i < changes.length; ++i) {
            changes[i].lp.modify(buy.key, changes[i].lower, changes[i].upper, changes[i].liquidity);
        }
        buyer.routerSwap(buy, value);
    }
}

/// @notice The King of the Pool ledger on HookrRoot's lane: the per-position liquidity ledger that keeps a crown
///         from being voided by dust or off-path liquidity (audit finding F-011) and the pot release rule (review
///         finding M-2).
contract KothLedgerTest is ScriptedLaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    function _change(Actor lp, int24 lower, int24 upper, int256 liquidity)
        internal
        pure
        returns (LiquidityBundler.Change memory)
    {
        return LiquidityBundler.Change(lp, lower, upper, liquidity);
    }

    /// @dev Minnow leads with 5e20; a bundle applies `changes`, then an honest actor buys 2e21. Returns the leader.
    function _bundledCrown(LiquidityBundler.Change[] memory changes) internal returns (address leader, address honest) {
        _buy(key, ETH, minnow, 5e20);
        Actor h = _newActor(key);
        honest = address(h);
        new LiquidityBundler().run(changes, h, _swapParams(key, ETH, true, true, 2e21, honest), 2e21);
        (, leader,,) = _hill(key);
    }

    /// F-011. A third party's dust add and remove of the same position in the buyer's transaction nets to zero and
    /// does not void the honest crown.
    function test_dustAddRemoveDoesNotVoidCrown() public {
        Actor griefer = _newActor(key);
        LiquidityBundler.Change[] memory c = new LiquidityBundler.Change[](2);
        c[0] = _change(griefer, -60_000, 60_000, 1);
        c[1] = _change(griefer, -60_000, 60_000, -1);
        (address leader, address honest) = _bundledCrown(c);
        assertEq(leader, honest);
    }

    /// F-011. Dust left in place is below the tolerance.
    function test_dustLeftInPlaceDoesNotVoidCrown() public {
        Actor griefer = _newActor(key);
        LiquidityBundler.Change[] memory c = new LiquidityBundler.Change[](1);
        c[0] = _change(griefer, -60_000, 60_000, 1e18);
        (address leader, address honest) = _bundledCrown(c);
        assertEq(leader, honest);
    }

    /// F-011. Liquidity added off the swap's tick path does not void the crown.
    function test_offPathLiquidityDoesNotVoidCrown() public {
        Actor lp = _newActor(key);
        LiquidityBundler.Change[] memory c = new LiquidityBundler.Change[](1);
        c[0] = _change(lp, 30_000, 36_000, 1e24);
        (address leader, address honest) = _bundledCrown(c);
        assertEq(leader, honest);
    }

    /// F-011. Liquidity on the path above the tolerance still blocks the crown, and removing a different position
    /// (standing from an earlier transaction) does not offset it.
    function test_onPathLiquidityBlocksAndOtherRemovalsDoNotOffset() public {
        Actor lp = _newActor(key);
        lp.modify(key, -60_000, 60_000, 1e24);
        LiquidityBundler.Change[] memory c = new LiquidityBundler.Change[](2);
        c[0] = _change(lp, -600, 600, 1e24);
        c[1] = _change(lp, -60_000, 60_000, -1e24);
        (address leader,) = _bundledCrown(c);
        assertEq(leader, minnow, "JIT liquidity on the path blocks the crown");
    }

    /// F-011. More distinct same-transaction positions than the root tracks block the crown (fail closed).
    function test_trackedPositionLimitFailsClosed() public {
        Actor lp = _newActor(key);
        uint256 n = MAX_TRACKED_POSITIONS + 1;
        LiquidityBundler.Change[] memory c = new LiquidityBundler.Change[](n);
        for (uint256 i; i < n; ++i) {
            c[i] = _change(lp, int24(int256(30_000 + 600 * i)), int24(int256(30_600 + 600 * i)), 1e18);
        }
        (address leader,) = _bundledCrown(c);
        assertEq(leader, minnow);
    }

    /// LN-8. In one transaction an LP adds a little to a position it already holds and then removes all of it, standing
    /// liquidity included: the ledger's net for the position is what the transaction added, so the removal clears it to
    /// zero, never below, and the honest crown stands. (A net that underflowed reverted the removal.)
    function test_removingMoreThanTheTransactionAddedClearsTheLedger() public {
        Actor lp = _newActor(key);
        lp.modify(key, -60_000, 60_000, 1e24);
        LiquidityBundler.Change[] memory c = new LiquidityBundler.Change[](2);
        c[0] = _change(lp, -60_000, 60_000, 1e18);
        c[1] = _change(lp, -60_000, 60_000, -int256(1e24 + 1e18));
        (address leader, address honest) = _bundledCrown(c);
        assertEq(leader, honest, "nothing of the removed position is left on the path");
    }

    /// LN-10. Same-transaction liquidity on the path blocks the crown only above 0.1% of the pool's active liquidity
    /// (10 bps, counting itself): at exactly that share the honest buy still takes the crown, one unit more and it does
    /// not.
    function test_liquidityAtExactlyTheToleranceDoesNotBlockTheCrown() public {
        _buy(key, ETH, minnow, 5e20);
        // Standing liquidity that makes the pool's active liquidity a multiple of 999: with the added s, 0.1% of
        // (L + s) is s exactly when L = 999 s.
        uint256 l0 = StateLibrary.getLiquidity(IPoolManager(address(manager)), id);
        if (l0 % 999 != 0) _newActor(key).modify(key, -60_000, 60_000, int256(999 - l0 % 999));
        l0 = StateLibrary.getLiquidity(IPoolManager(address(manager)), id);
        assertEq(l0 % 999, 0);
        uint256 s = l0 / 999;
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            Actor jit = _newActor(key);
            LiquidityBundler.Change[] memory c = new LiquidityBundler.Change[](1);
            c[0] = _change(jit, -60_000, 60_000, int256(s + i));
            Actor h = _newActor(key);
            new LiquidityBundler().run(c, h, _swapParams(key, ETH, true, true, 2e21, address(h)), 2e21);
            (, address leader,,) = _hill(key);
            assertEq(leader, i == 0 ? address(h) : minnow, i == 0 ? "at the tolerance: the crown" : "above it: blocked");
            vm.revertToState(snap);
        }
    }

    /// M-2. The pot exit rule: each closed epoch carries half of what the prize leaves and releases the rest to the
    /// LP accrual; elapsed epochs compound, so an idle pot empties.
    function test_potReleaseRule() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        _newActor(key).directSwap(key, true, -1e18, MIN_PRICE);
        (uint64 start,,, uint128 pot) = _hill(key);
        uint256 lp0 = _accrued(key);
        vm.warp(uint256(start) + 3 * PERIOD);
        _recap().settleEpoch(id);
        (,,, uint128 carried) = _hill(key);
        assertEq(carried, pot >> 3, "three closed epochs halve it three times");
        assertEq(_accrued(key) - lp0, pot - carried);
        assertTrue(rules.accountingInvariant(ETH));
    }
}
