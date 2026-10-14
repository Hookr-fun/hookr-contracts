// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHookrFamilyLock} from "hookr/interfaces/IHookrFamilyLock.sol";
import {BenchToken} from "../src/BenchToken.sol";
import {Pools} from "./Pools.sol";

/// @notice HookrFamilyLock (the live lock at 0xfAFE...e00b): a family's liquidity locked for good, with its LP fees
///         collected by a beneficiary. The lock sits outside the swap path, so a swap on a locked pool runs the same
///         code as on an unlocked one. Collecting is measured at its steady state: the beneficiary has collected
///         before, and a buy and a sell have earned fees since.
contract FamilyLockTest is Pools {
    IHookrFamilyLock internal lock = IHookrFamilyLock(FAMILY_LOCK);

    BenchToken internal token;
    PoolKey internal key;
    bytes32 internal family;
    address internal beneficiary = makeAddr("beneficiary");

    /// @dev A warmed Hookr pool whose family this contract owns.
    function setUp() public override {
        super.setUp();
        token = _newToken();
        (family, key) = _launch(token, _member(RULES), "");
        _nextBlock();
        _warm(key);
    }

    /// @notice The beneficiary's second collect from a locked family, after fees have accrued again.
    function test_collect() public {
        _lockForGood();
        _earnFees();
        vm.prank(beneficiary, beneficiary);
        lock.collect(family, 0, 0);
        _earnFees();
        vm.prank(beneficiary, beneficiary);
        lock.collect(family, 0, 0);
        _record(
            Figure({
                id: "liquidity-lock.collect",
                piece: "liquidity-lock",
                label: "Liquidity lock: the beneficiary collects the LP fees",
                action: "collect",
                gas: _lastCallGas(),
                baseline: ABSOLUTE,
                router: DIRECT,
                test: "bench/test/FamilyLock.t.sol:test_collect"
            })
        );
    }

    /// @notice A buy on the pool before the family is locked, and the same buy from the same state after.
    function test_otherSwaps() public {
        uint256 snapshot = vm.snapshotState();
        uint256 unlocked = _swapUniversal(ROUTER_CURATED, trader, key, true, SWAP_AMOUNT);
        vm.revertToState(snapshot);
        _lockForGood();
        _nextBlock();
        uint256 locked = _swapUniversal(ROUTER_CURATED, trader, key, true, SWAP_AMOUNT);
        _record(
            Figure({
                id: "liquidity-lock.per-swap",
                piece: "liquidity-lock",
                label: "Liquidity lock: a buy on a locked pool",
                action: "per-swap",
                gas: _extra(locked, unlocked),
                baseline: SAME_POOL_WITHOUT_PIECE,
                router: UR_CURATED,
                test: "bench/test/FamilyLock.t.sol:test_otherSwaps"
            })
        );
    }

    /// @dev Hands the family to the lock, which holds its liquidity for good and pays its fees to `beneficiary`.
    function _lockForGood() private {
        LAUNCHER.transferFamily(family, FAMILY_LOCK, 0);
        lock.lock(family, beneficiary, type(uint64).max);
    }

    /// @dev A buy and a sell, so the position has fees to collect.
    function _earnFees() private {
        _nextBlock();
        _swapUniversal(ROUTER_CURATED, trader, key, true, SWAP_AMOUNT);
        _nextBlock();
        _swapUniversal(ROUTER_CURATED, trader, key, false, SWAP_AMOUNT / 2);
        _nextBlock();
    }
}
