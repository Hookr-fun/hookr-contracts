// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {HookrMarketBand} from "hookr-blocks/market-guard/src/HookrMarketBand.sol";
import {BenchToken} from "../src/BenchToken.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {Pools} from "./Pools.sol";

/// @notice Market Guard (the live advisory at 0xFc5C...93A4) on a pool priced at the ETH / USD feed it is bound to,
///         against a fee-only Hookr pool at the same price. The bench token plays USD: one WETH is worth the feed's
///         answer in tokens. The guard is at its defaults: it refuses a swap that would leave a 10% band around the
///         feed, so these are swaps inside the band. It reads the feed before the swap and again after it.
contract MarketGuardTest is Pools {
    /// @dev A buy of one WETH, and a sell of the 2,000 tokens that are about one WETH at the feed's price.
    uint128 internal constant BUY = 1e18;
    uint128 internal constant SELL = 2_000e18;

    /// @notice A buy and a sell on the guarded pool and on a fee-only pool, both priced at the feed.
    function test_marketGuard() public {
        BenchToken guardedToken = _newToken();
        BenchToken feeOnlyToken = _newToken();
        IHookrLauncher.Member memory guard = _atFeedPrice();
        guard.config.advisory = MARKET_GUARD;
        guard.config.advisoryGasLimit = 350_000;
        guard.config.advisoryPhases = HookrTypes.BEFORE_SWAP | HookrTypes.AFTER_SWAP;
        bytes memory knobs = abi.encode(
            ETH_USD_FEED,
            HookrMarketBand.Knobs(
                HookrMarketBand.REFUSE,
                HookrMarketBand.INVERT,
                HookrMarketBand.DEFAULT_BAND_BPS,
                HookrMarketBand.DEFAULT_RAMP_BPS,
                HookrMarketBand.DEFAULT_STALENESS,
                0,
                HookrMarketBand.DEFAULT_MIN_DEPTH
            )
        );
        (, PoolKey memory guarded) = _launch(guardedToken, guard, knobs);
        (, PoolKey memory feeOnly) = _launch(feeOnlyToken, _atFeedPrice(), "");
        _nextBlock();
        _warmAtFeedPrice(guarded);
        _warmAtFeedPrice(feeOnly);

        uint256 guardedBuy = _swapThenNextBlock(ROUTER_CURATED, trader, guarded, true, BUY);
        uint256 guardedSell = _swapThenNextBlock(ROUTER_CURATED, trader, guarded, false, SELL);
        uint256 feeOnlyBuy = _swapThenNextBlock(ROUTER_CURATED, trader, feeOnly, true, BUY);
        uint256 feeOnlySell = _swapThenNextBlock(ROUTER_CURATED, trader, feeOnly, false, SELL);

        _report("buy", _extra(guardedBuy, feeOnlyBuy));
        _report("sell", _extra(guardedSell, feeOnlySell));
    }

    /// @dev Records a Market Guard figure of `action`.
    function _report(string memory action, int256 gas) private {
        _record(
            Figure({
                id: string.concat("market-guard.", action),
                piece: "market-guard",
                label: string.concat(
                    "Market Guard, refusing outside a 10% band of the feed: a ", action, " inside the band"
                ),
                action: action,
                gas: gas,
                baseline: SAME_POOL_WITHOUT_PIECE,
                router: UR_CURATED,
                test: "bench/test/MarketGuard.t.sol:test_marketGuard"
            })
        );
    }

    /// @dev One buy and one sell of half the measured size, so the pool's ledgers are nonzero.
    function _warmAtFeedPrice(PoolKey memory key) private {
        _swapThenNextBlock(ROUTER_CURATED, trader, key, true, BUY);
        _swapThenNextBlock(ROUTER_CURATED, trader, key, false, SELL / 2);
    }

    /// @dev The steady-state pool re-priced at the feed: one WETH is worth the feed's answer in tokens, with the
    ///      position's width around that price.
    function _atFeedPrice() private view returns (IHookrLauncher.Member memory m) {
        (, int256 answer,,,) = IPriceFeed(ETH_USD_FEED).latestRoundData();
        uint160 sqrtPrice = uint160(Math.sqrt((uint256(answer) << 192) / 1e8));
        int24 middle = (TickMath.getTickAtSqrtPrice(sqrtPrice) / SPACING) * SPACING;
        m = _member(RULES);
        m.sqrtPriceX96 = sqrtPrice;
        m.tickLower = middle - RANGE;
        m.tickUpper = middle + RANGE;
        m.amount0Max = 1e26;
        m.amount1Max = 1e26;
    }
}
