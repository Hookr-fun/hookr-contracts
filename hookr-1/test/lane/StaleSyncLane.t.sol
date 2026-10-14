// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {TwoVenueExecutor} from "./mocks/TwoVenueExecutor.sol";

/// @dev Leaves `stray` synced on the PoolManager and then swaps through the router, in one call: every top-level call
///      under the lane profile is its own transaction (`isolate`), so the sync must come from the same call to still be
///      open.
contract SyncThenRouterSwap {
    using TransientStateLibrary for IPoolManager;

    function go(IPoolManager manager, IHookrRouter router, Currency stray, IHookrRouter.Swap calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        manager.sync(stray);
        require(Currency.unwrap(manager.getSyncedCurrency()) == Currency.unwrap(stray), "synced");
        (, amountOut) = router.swap{value: msg.value}(p, address(0), new uint256[](0));
    }
}

/// @notice SYS-01 on an arb recapture pool with a working executor. HookrLane refuses to run an arb recapture frame
///         while any currency is synced on the PoolManager (`SyncPending`), and that refusal reverts the swap, so a sync
///         an earlier call in the transaction left on a currency outside the pool used to fail every router swap on a
///         pool whose lane is on. HookrRouter now clears it before it swaps: the swap goes through and its arb
///         recapture runs and pushes. `test/core/HookrRoot.staleSyncBurningBuy.t.sol` has the burning buy, the bundle,
///         the quote and the controls where the refusals still stand.
contract StaleSyncLaneTest is LaneFixture {
    TwoVenueExecutor internal arb;
    PoolKey internal key;
    SyncThenRouterSwap internal helper;

    function setUp() public {
        _setUpLane();
        // A first leg large enough that the before-phase closes a 3% gap in full.
        arb = _twoVenueExecutor(1e24);
        _openLane(address(arb));
        key = _openRecapture(ETH);
        _seedReference(key);
        _buy(key, ETH, minnow, 1e18);
        _nextBlock();
        helper = new SyncThenRouterSwap();
    }

    function test_aStaleSyncOfAnotherCurrencyNoLongerStopsAnArbRecapturedSwap() public {
        _moveReference(key, 1.03e18);
        IHookrRouter.Swap memory p = _swapParams(key, ETH, true, true, 1e18, whale);
        vm.recordLogs();
        uint256 out = helper.go{value: 1e18}(manager, router, Currency.wrap(address(tokenB)), p);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertGt(out, 0, "the buy cleared");
        assertGt(o.succeeded, 0, "the arb recapture ran");
        assertGt(o.pushedBefore, 0, "and the before-phase pushed");
        assertEq(o.failed, 0, "no frame failed");
    }
}
