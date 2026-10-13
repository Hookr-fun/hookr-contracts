// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BenchToken} from "../src/BenchToken.sol";
import {Pools} from "./Pools.sol";

/// @notice What the root costs a swap before any rule is on: the pool of an existing token with only its base LP fee,
///         against the same pool with no hook. The root answers the PoolManager's two callbacks, reads the pool's
///         record and tells the router whom to charge, and never calls the Rules. A token the launcher mints, with no
///         rule that pays Hookr, binds Hookr's minimum fee instead and is not on this path.
contract BaseTest is Pools {
    /// @notice A buy and a sell on the hookless pool and on the Hookr pool, over the same token.
    function test_base() public {
        BenchToken token = _newToken();
        PoolKey memory hookless = _hookless(token);
        (, PoolKey memory hookr) = _launch(token, _member(RULES), "");
        _warm(hookless);
        _warm(hookr);

        Costs memory plain = _costs(hookless);
        Costs memory hooked = _costs(hookr);

        _report("buy", _extra(hooked.buy, plain.buy));
        _report("sell", _extra(hooked.sell, plain.sell));
    }

    /// @dev Records the base figure of `action`: a Hookr pool with nothing on, over the pool with no hook.
    function _report(string memory action, int256 gas) private {
        _record(
            Figure({
                id: string.concat("base.", action),
                piece: "base",
                label: string.concat(
                    "A Hookr pool of an existing token with nothing on, over a pool with no hook: a ", action
                ),
                action: action,
                gas: gas,
                baseline: HOOKLESS_POOL,
                router: UR_CURATED,
                test: "bench/test/Base.t.sol:test_base"
            })
        );
    }
}
