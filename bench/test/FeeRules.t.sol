// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {BenchToken} from "../src/BenchToken.sol";
import {Pools} from "./Pools.sol";

/// @notice The release Rules' fee rules, each against the same pool without it. LP Rewards (a 1% slice of every buy,
///         paid to the pool's LPs after Hookr's 20% share of it) and Auto Burn (a 1% slice, burned in tokens after
///         the same share) are measured over the fee-only pool, which never calls the Rules. The creator royalty (10%
///         of the LP Rewards slice, paid to one address) can only sit on LP Rewards, so it is measured over a pool
///         with LP Rewards. The last pair is all three together over the fee-only pool.
contract FeeRulesTest is Pools {
    uint16 internal constant LP_REWARDS_BPS = 100;
    uint16 internal constant ROYALTY_BPS = 1_000;
    uint16 internal constant AUTO_BURN_BPS = 100;

    address internal royaltyTo = makeAddr("royalty recipient");

    /// @notice A buy and a sell on the fee-only pool and on each pool with a fee rule on.
    function test_feeRules() public {
        Costs memory feeOnly = _costs(_pool(0, 0, 0));
        Costs memory lpRewards = _costs(_pool(LP_REWARDS_BPS, 0, 0));
        Costs memory royalty = _costs(_pool(LP_REWARDS_BPS, ROYALTY_BPS, 0));
        Costs memory autoBurn = _costs(_pool(0, 0, AUTO_BURN_BPS));
        Costs memory allThree = _costs(_pool(LP_REWARDS_BPS, ROYALTY_BPS, AUTO_BURN_BPS));

        _report("lp-rewards", "lp-rewards", "LP Rewards, a 1% slice of buys", lpRewards, feeOnly);
        _report(
            "creator-royalty",
            "creator-royalty",
            "Creator royalty, 10% of LP Rewards, over LP Rewards",
            royalty,
            lpRewards
        );
        _report("auto-burn", "auto-burn", "Auto Burn, a 1% slice of buys", autoBurn, feeOnly);
        _report(
            "lp-rewards.with-royalty-and-auto-burn",
            "lp-rewards",
            "LP Rewards, royalty and Auto Burn together",
            allThree,
            feeOnly
        );
    }

    /// @dev The buy and the sell figure of `id`: the pool with the rule(s) on, less the pool without.
    function _report(string memory id, string memory piece, string memory label, Costs memory on, Costs memory off)
        private
    {
        _record(_figure(id, piece, label, "buy", _extra(on.buy, off.buy)));
        _record(_figure(id, piece, label, "sell", _extra(on.sell, off.sell)));
    }

    /// @dev One side of a fee rule's figure.
    function _figure(string memory id, string memory piece, string memory label, string memory action, int256 gas)
        private
        pure
        returns (Figure memory)
    {
        return Figure({
            id: string.concat(id, ".", action),
            piece: piece,
            label: string.concat(label, ": a ", action),
            action: action,
            gas: gas,
            baseline: SAME_POOL_WITHOUT_PIECE,
            router: UR_CURATED,
            test: "bench/test/FeeRules.t.sol:test_feeRules"
        });
    }

    /// @dev A warmed pool for a fresh token with the given rules.
    function _pool(uint16 lpBps, uint16 royaltyBps, uint16 burnBps) private returns (PoolKey memory key) {
        BenchToken token = _newToken();
        IHookrLauncher.Member memory m = _member(RULES);
        m.rules.lpBps = lpBps;
        m.rules.burnBps = burnBps;
        if (royaltyBps != 0) {
            m.rules.royaltyBps = royaltyBps;
            m.rules.royaltyTo = royaltyTo;
        }
        (, key) = _launch(token, m, "");
        _nextBlock();
        _warm(key);
    }
}
