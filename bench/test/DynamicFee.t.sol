// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {BenchToken} from "../src/BenchToken.sol";
import {Pools} from "./Pools.sol";

/// @notice Hookr dynamic fees on the release Rules, against the fee-only pool of the same shape. The root prices every
///         swap by simulating it on the PoolManager and reverting, and the Rules charge a fee that grows with how far
///         the trader's own move takes the price from a slow reference. Both pools carry four stacked positions on top
///         of the steady-state one, so a large swap crosses their four initialized ticks and a small one crosses none,
///         and the same seven-swap history, so every fee state has started and every stacked tick has been crossed
///         both ways. A swap is cold: the first of a new block, a whole transaction. The test requires both pools to
///         cross the same ticks, so a figure never mixes a piece's cost with a different swap.
contract DynamicFeeTest is Pools {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant MAX_FEE_PIPS = 50_000;
    uint16 internal constant SENSITIVITY = 5;
    uint128 internal constant STACK_LIQUIDITY = 1e23;
    uint128 internal constant SMALL = 1e20;
    uint128 internal constant LARGE = 5e22;
    /// @dev The stacked positions are [-120, 120], [-240, 240], [-480, 480] and [-720, 720]: eight edges, four on each
    ///      side of the opening price.
    int24[4] internal edges = [int24(120), 240, 480, 720];

    PoolKey internal dynamic;
    PoolKey internal feeOnly;

    /// @notice A small and a large buy and sell, cold, on the dynamic fee pool and on the fee-only pool.
    function test_dynamicFee() public {
        BenchToken dynamicToken = _newToken();
        BenchToken feeOnlyToken = _newToken();
        IHookrLauncher.Member memory m = _member(RULES);
        m.rules.maxFeePips = MAX_FEE_PIPS;
        m.rules.dynamicFeeSens = SENSITIVITY;
        (, dynamic) = _launch(dynamicToken, m, "");
        (, feeOnly) = _launch(feeOnlyToken, _member(RULES), "");
        _stack(dynamic);
        _stack(feeOnly);
        _history(dynamic);
        _history(feeOnly);

        _report("small-buy", "Hookr dynamic fee: a small buy, no tick crossed", "buy", SMALL, 0);
        _report("large-buy", "Hookr dynamic fee: a large buy across four ticks", "buy", LARGE, edges.length);
        _report("small-sell", "Hookr dynamic fee: a small sell, no tick crossed", "sell", SMALL, 0);
        _report("large-sell", "Hookr dynamic fee: a large sell across four ticks", "sell", LARGE, edges.length);
    }

    /// @dev The figure of a swap that is the first of a new block on the dynamic fee pool, less the same swap on the
    ///      fee-only pool, when both cross `crossings` of the stacked ticks.
    function _report(string memory name, string memory label, string memory action, uint128 amount, uint256 crossings)
        private
    {
        bool buy = keccak256(bytes(action)) == keccak256("buy");
        (uint256 on, uint256 crossedOn) = _cold(dynamic, buy, amount);
        (uint256 off, uint256 crossedOff) = _cold(feeOnly, buy, amount);
        require(crossedOn == crossings && crossedOff == crossings, "the pools do not cross the same ticks");
        _record(
            Figure({
                id: string.concat("dynamic-fees.", name),
                piece: "dynamic-fees",
                label: label,
                action: action,
                gas: _extra(on, off),
                baseline: SAME_POOL_WITHOUT_PIECE,
                router: UR_CURATED,
                test: "bench/test/DynamicFee.t.sol:test_dynamicFee"
            })
        );
    }

    /// @dev Four more positions around the opening price.
    function _stack(PoolKey memory key) private {
        for (uint256 i; i < edges.length; ++i) {
            adder.add(key, -edges[i], edges[i], STACK_LIQUIDITY, address(this));
        }
    }

    /// @dev A minute apart: two small swaps so fees accrue, then a large buy, a double sell and a large buy that cross
    ///      every stacked tick both ways, then two small swaps.
    function _history(PoolKey memory key) private {
        _trade(key, true, 1e21);
        _trade(key, false, 1e21);
        _trade(key, true, 6e22);
        _trade(key, false, 12e22);
        _trade(key, true, 6e22);
        _trade(key, true, 5e20);
        _trade(key, false, 5e20);
    }

    /// @dev One history swap, a minute after the one before.
    function _trade(PoolKey memory key, bool buy, uint128 amount) private {
        _advance(5, 60);
        _swapUniversal(ROUTER_CURATED, trader, key, buy, amount);
    }

    /// @dev A swap as the first of the next block, from the pool's state after its history, which is then restored:
    ///      its gas, and how many of the stacked ticks it crossed.
    function _cold(PoolKey memory key, bool buy, uint128 amount) private returns (uint256 gas, uint256 crossed) {
        uint256 snapshot = vm.snapshotState();
        _nextBlock();
        int24 from = _tick(key);
        gas = _swapUniversal(ROUTER_CURATED, trader, key, buy, amount);
        crossed = _crossings(from, _tick(key));
        vm.revertToState(snapshot);
    }

    /// @dev The pool's current tick.
    function _tick(PoolKey memory key) private view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(POOL_MANAGER, key.toId());
    }

    /// @dev How many stacked edges lie strictly between two ticks.
    function _crossings(int24 from, int24 to) private view returns (uint256 count) {
        (int24 low, int24 high) = from < to ? (from, to) : (to, from);
        for (uint256 i; i < edges.length; ++i) {
            if (low < -edges[i] && -edges[i] < high) ++count;
            if (low < edges[i] && edges[i] < high) ++count;
        }
    }
}
