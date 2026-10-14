// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {BenchToken} from "../src/BenchToken.sol";
import {Pools} from "./Pools.sol";

/// @notice Buy/Sell Block (the live advisory at 0xffef...626f) on the round-trip Rules (0x3d7e...cb34), against a
///         fee-only Hookr pool. It refuses a sell after a buy by the same trader in one block, and a buy after a sell.
///         These are a trader's first trade of a block, which the Rules record, so the block costs the Rules' two
///         calls and the advisory's one.
contract BuySellBlockTest is Pools {
    /// @dev The advisory's config words: round trips refused both ways, no buy pause, no sell lock.
    uint256 internal constant ROUND_TRIP_BOTH = 2;

    /// @notice A buy and a sell on the blocked pool and on a fee-only pool.
    function test_buySellBlock() public {
        BenchToken blockedToken = _newToken();
        BenchToken feeOnlyToken = _newToken();
        IHookrLauncher.Member memory m = _member(RULES_ROUND_TRIP);
        m.config.advisory = BUY_SELL_BLOCK;
        m.config.advisoryGasLimit = 60_000;
        m.config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        (, PoolKey memory blocked) = _launch(blockedToken, m, abi.encode(ROUND_TRIP_BOTH, uint256(0), uint256(0)));
        (, PoolKey memory feeOnly) = _launch(feeOnlyToken, _member(RULES), "");
        _nextBlock();
        _warm(blocked);
        _warm(feeOnly);

        uint256 blockedBuy = _swapUniversal(ROUTER_CURATED, trader, blocked, true, SWAP_AMOUNT);
        _nextBlock();
        uint256 blockedSell = _swapUniversal(ROUTER_CURATED, trader, blocked, false, SWAP_AMOUNT);
        _nextBlock();
        uint256 feeOnlyBuy = _swapUniversal(ROUTER_CURATED, trader, feeOnly, true, SWAP_AMOUNT);
        _nextBlock();
        uint256 feeOnlySell = _swapUniversal(ROUTER_CURATED, trader, feeOnly, false, SWAP_AMOUNT);

        _report("buy", _extra(blockedBuy, feeOnlyBuy));
        _report("sell", _extra(blockedSell, feeOnlySell));
    }

    /// @dev Records a Buy/Sell Block figure of `action`.
    function _report(string memory action, int256 gas) private {
        _record(
            Figure({
                id: string.concat("buy-sell-block.", action),
                piece: "buy-sell-block",
                label: string.concat(
                    "Buy/Sell Block, refusing a round trip in a block: a trader's first ", action, " of the block"
                ),
                action: action,
                gas: gas,
                baseline: SAME_POOL_WITHOUT_PIECE,
                router: UR_CURATED,
                test: "bench/test/BuySellBlock.t.sol:test_buySellBlock"
            })
        );
    }
}
