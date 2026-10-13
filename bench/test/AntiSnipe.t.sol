// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {BenchToken} from "../src/BenchToken.sol";
import {Pools} from "./Pools.sol";

/// @notice Anti-Snipe on the release Rules: a pool with the shared launch guard against the same pool with nothing on
///         but its base LP fee. While the guard lasts every swap runs the Rules; after it the root's fee-only path
///         takes over and the guard costs nothing.
contract AntiSnipeTest is Pools {
    BenchToken internal guardedToken;
    BenchToken internal feeOnlyToken;
    PoolKey internal guarded;
    PoolKey internal feeOnly;

    /// @dev A guarded pool and a fee-only pool, both warmed.
    function setUp() public override {
        super.setUp();
        guardedToken = _newToken();
        feeOnlyToken = _newToken();
        IHookrLauncher.Member memory m = _member(RULES);
        _guard(m, 0);
        (, guarded) = _launch(guardedToken, m, "");
        (, feeOnly) = _launch(feeOnlyToken, _member(RULES), "");
        _nextBlock();
        _warm(guarded);
        _warm(feeOnly);
    }

    /// @notice A fresh wallet's first buy, its second buy and a sell, inside the guard's window.
    function test_inWindow() public {
        address buyer = _fresh("buyer", guardedToken, feeOnlyToken);
        int256 first = _difference(buyer, true, SWAP_AMOUNT);
        int256 repeat = _difference(buyer, true, SWAP_AMOUNT);
        int256 sell = _difference(buyer, false, SWAP_AMOUNT / 2);
        _report("first-buy", "Anti-Snipe in the window: a wallet's first buy", "first-buy", first, "test_inWindow");
        _report(
            "repeat-buy", "Anti-Snipe in the window: the same wallet buys again", "repeat-buy", repeat, "test_inWindow"
        );
        _report("sell", "Anti-Snipe in the window: a sell", "sell", sell, "test_inWindow");
    }

    /// @notice A fresh wallet's buy after the window has ended.
    function test_afterWindow() public {
        _advance(GUARD_BLOCKS + 1, 200);
        int256 buy = _difference(_fresh("late buyer", guardedToken, feeOnlyToken), true, SWAP_AMOUNT);
        _report("after-window", "Anti-Snipe after the window: a buy", "after-window", buy, "test_afterWindow");
    }

    /// @dev Records an Anti-Snipe figure; `fn` names the test that measured it.
    function _report(string memory id, string memory label, string memory action, int256 gas, string memory fn)
        private
    {
        _record(
            Figure({
                id: string.concat("anti-snipe.", id),
                piece: "anti-snipe",
                label: label,
                action: action,
                gas: gas,
                baseline: SAME_POOL_WITHOUT_PIECE,
                router: UR_CURATED,
                test: string.concat("bench/test/AntiSnipe.t.sol:", fn)
            })
        );
    }

    /// @dev The same swap on the guarded pool and on the fee-only pool, in consecutive blocks: the guarded pool's gas
    ///      less the fee-only pool's.
    function _difference(address who, bool buy, uint128 amount) private returns (int256) {
        uint256 on = _swapThenNextBlock(ROUTER_CURATED, who, guarded, buy, amount);
        uint256 off = _swapThenNextBlock(ROUTER_CURATED, who, feeOnly, buy, amount);
        return _extra(on, off);
    }
}
