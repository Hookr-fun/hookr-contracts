// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IHookrRecaptureRules} from "hookr/interfaces/IHookrRecaptureRules.sol";
import {BenchToken} from "../src/BenchToken.sol";
import {Pools} from "./Pools.sol";

/// @notice The arb recapture lane and King of the Pool on the whole-pot Rules, each against the same pool without it.
///         On a lane pool every swap runs the live executor twice, before the swap and after it, inside the trader's
///         own transaction, and asks it once whether the swap closes a v3 arbitrage. A fresh token trades on one venue
///         only, so the executor finds nothing to recapture and the lane is measured idle. King of the Pool is
///         measured on top of the lane in its steady state: the buy does not take the lead, so the pot's ledger is read
///         and not written.
contract LaneTest is Pools {
    uint16 internal constant POT_BPS = 2_500;
    /// @dev The buy that holds the lead, ahead of the measured buys.
    uint128 internal constant LEADER_BUY = 3 * SWAP_AMOUNT;

    /// @notice A buy and a sell on a fee-only pool, an idle lane pool and a lane pool with King of the Pool.
    function test_lane() public {
        Costs memory feeOnly = _costs(_pool(false, false));
        Costs memory idleLane = _costs(_pool(true, false));
        Costs memory king = _costs(_pool(true, true));

        _report("arb-recapture", "Arb recapture lane with an idle executor", idleLane, feeOnly);
        _report("king-of-the-pool", "King of the Pool, over the same lane pool without the pot", king, idleLane);
    }

    /// @dev The buy and the sell figure of `piece`: the pool with it on, less the pool without.
    function _report(string memory piece, string memory label, Costs memory on, Costs memory off) private {
        _record(_figure(piece, label, "buy", _extra(on.buy, off.buy)));
        _record(_figure(piece, label, "sell", _extra(on.sell, off.sell)));
    }

    /// @dev One side of a lane figure.
    function _figure(string memory piece, string memory label, string memory action, int256 gas)
        private
        pure
        returns (Figure memory)
    {
        return Figure({
            id: string.concat(piece, ".", action),
            piece: piece,
            label: string.concat(label, ": a ", action),
            action: action,
            gas: gas,
            baseline: SAME_POOL_WITHOUT_PIECE,
            router: UR_CURATED,
            test: "bench/test/Lane.t.sol:test_lane"
        });
    }

    /// @dev A warmed pool on the whole-pot Rules for a fresh token; `lane` turns on the arb recapture lane and `pot`
    ///      King of the Pool, with a leader already ahead of the measured buy.
    function _pool(bool lane, bool pot) private returns (PoolKey memory key) {
        BenchToken token = _newToken();
        IHookrLauncher.Member memory m = _member(RULES_WHOLE_POT);
        if (lane) {
            (HookrTypes.RecaptureConfig memory rc,) = IHookrRecaptureRules(RULES_WHOLE_POT).recaptureDefaults();
            if (pot) {
                m.rules.potBps = POT_BPS;
                rc.lpBps = 5_000;
                rc.traderBps = 2_500;
                rc.period = 1 days;
                rc.maxPrizeBps = 10_000;
                rc.potReleaseBps = 5_000;
                rc.minBuyQuote = 1e15;
            }
            m.recapture = rc;
        }
        (, key) = _launch(token, m, "");
        _nextBlock();
        _warm(key);
        _swapThenNextBlock(ROUTER_CURATED, _wallet("leader", token), key, true, LEADER_BUY);
    }
}
