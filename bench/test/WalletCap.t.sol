// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {BenchToken} from "../src/BenchToken.sol";
import {Pools} from "./Pools.sol";

/// @notice Wallet Cap v2 (the live Rules at 0xb67b...e52a) against the whole-pot Rules it is built on, both with the
///         same launch guard: the difference is the cap alone. The cap counts each buy against its wallet while the
///         guard lasts. For a swap through the Universal Router the root curates, the wallet is the payer the root
///         authenticated. A swap through a router the root does not curate is unauthenticated, with the router as its
///         payer: the Rules first ask the root whether the sender is the pool's arb recapture executor, then count the
///         buy against tx.origin.
contract WalletCapTest is Pools {
    /// @dev Tokens one wallet may buy while the guard lasts; no wallet in the bench comes near it.
    uint128 internal constant WALLET_CAP = 1e25;

    /// @dev How a swap reaches the pool, and how the figures it produces are named.
    struct Route {
        address router;
        string name;
        string idSuffix;
        string labelSuffix;
        string test;
    }

    BenchToken internal cappedToken;
    BenchToken internal controlToken;
    PoolKey internal capped;
    PoolKey internal control;

    /// @dev A capped pool and a control pool on the whole-pot Rules, both with the guard, both warmed.
    function setUp() public override {
        super.setUp();
        cappedToken = _newToken();
        controlToken = _newToken();
        IHookrLauncher.Member memory withCap = _member(RULES_WALLET_CAP);
        _guard(withCap, WALLET_CAP);
        IHookrLauncher.Member memory withoutCap = _member(RULES_WHOLE_POT);
        _guard(withoutCap, 0);
        (, capped) = _launch(cappedToken, withCap, "");
        (, control) = _launch(controlToken, withoutCap, "");
        _nextBlock();
        _warm(capped);
        _warm(control);
    }

    /// @notice The four cases through the Universal Router the root curates.
    function test_curatedRouter() public {
        _measure(Route(ROUTER_CURATED, UR_CURATED, "", "", "test_curatedRouter"));
    }

    /// @notice The four cases through a router the root does not curate.
    function test_routerNotCurated() public {
        _measure(
            Route(
                ROUTER_NOT_CURATED,
                UR_NOT_CURATED,
                ".uncurated-router",
                ", through a router the root does not curate",
                "test_routerNotCurated"
            )
        );
    }

    /// @dev In the window a fresh wallet buys, buys again and sells; after it another fresh wallet buys.
    function _measure(Route memory route) private {
        address inWindow = _fresh("in window", cappedToken, controlToken);
        int256 first = _difference(route.router, inWindow, true, SWAP_AMOUNT);
        int256 repeat = _difference(route.router, inWindow, true, SWAP_AMOUNT);
        int256 sell = _difference(route.router, inWindow, false, SWAP_AMOUNT / 2);
        _advance(GUARD_BLOCKS + 1, 200);
        address late = _fresh("after the window", cappedToken, controlToken);
        int256 afterWindow = _difference(route.router, late, true, SWAP_AMOUNT);

        _report(route, "first-buy", "Wallet Cap in the window: a wallet's first buy", first);
        _report(route, "repeat-buy", "Wallet Cap in the window: the same wallet buys again", repeat);
        _report(route, "sell", "Wallet Cap in the window: a sell", sell);
        _report(route, "after-window", "Wallet Cap after the window: a buy", afterWindow);
    }

    /// @dev Records one case of a route.
    function _report(Route memory route, string memory action, string memory label, int256 gas) private {
        _record(
            Figure({
                id: string.concat("wallet-cap.", action, route.idSuffix),
                piece: "wallet-cap",
                label: string.concat(label, route.labelSuffix),
                action: action,
                gas: gas,
                baseline: SAME_POOL_WITHOUT_PIECE,
                router: route.name,
                test: string.concat("bench/test/WalletCap.t.sol:", route.test)
            })
        );
    }

    /// @dev The same swap on the capped pool and on the control pool, in consecutive blocks: the capped pool's gas less
    ///      the control's.
    function _difference(address router, address who, bool buy, uint128 amount) private returns (int256) {
        uint256 on = _swapThenNextBlock(router, who, capped, buy, amount);
        uint256 off = _swapThenNextBlock(router, who, control, buy, amount);
        return _extra(on, off);
    }
}
