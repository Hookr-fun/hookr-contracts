// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IHookrLauncher} from "../../../src/interfaces/IHookrLauncher.sol";
import {CyclingExecutor, HooklessVenue} from "../../fixtures/CyclingExecutor.sol";
import {LaneRootFixture} from "./LaneRootFixture.sol";

/// @notice The lane with an executor shaped like the partner's: at the 3,000,000 gas cap the lane opens at, one
///         `executeArbitrage` call runs several arbitrages against outside venues of the pool's pair and cycles through
///         the token's family (subject bought on one member, sold on another, the quotes joined by a connector), keeps
///         WTH's 25% share fixed in its code (no `partnerBps()` to read) and pushes the rest. The gas floor is funded
///         by the least gas a swap succeeds with, as `eth_estimateGas` finds it.
abstract contract PartnerShapedFixture is LaneRootFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint32 internal constant CAP = 3_000_000;
    uint24 internal constant POOL_FEE = 3_000;
    /// @dev Least gaps worth a chunk: a Hookr leg (0.3%) and a hookless venue (0.3%); a cycle adds a second Hookr leg.
    uint16 internal constant PAIR_GAP = 65;
    uint16 internal constant CYCLE_GAP = 95;

    CyclingExecutor internal ex;
    HooklessVenue internal venue;

    function _setUpPartnerShaped() internal {
        _setUpLane();
        ex = new CyclingExecutor(manager, address(root), partner);
        _openLane(address(ex), CAP);
        venue = new HooklessVenue(manager);
        tokenA.approve(address(venue), type(uint256).max);
        tokenB.approve(address(venue), type(uint256).max);
    }

    /// @dev A lane member at a 0.3% base fee with 2% LP Rewards.
    function _laneMemberAt(Currency quote) internal view returns (IHookrLauncher.Member memory m) {
        m = _member(quote, true, false, 200);
        m.config.baseLpFeePips = POOL_FEE;
        m.rules.maxFeePips = POOL_FEE;
    }

    /// @dev A hookless 0.3% spacing-60 pool of `c0`/`c1` at price 1 with 1e24 liquidity over [-60,000, 60,000].
    function _hookless(Currency c0, Currency c1) internal returns (PoolKey memory k) {
        k = PoolKey(c0, c1, 3000, 60, IHooks(address(0)));
        venue.seed{value: c0.isAddressZero() ? 1e24 : 0}(k, SQRT_ONE, -60_000, 60_000, 1e24);
    }

    /// @dev The subject's price in `key`'s other currency, in WAD.
    function _px(PoolKey memory key, Currency subject) internal view returns (uint256) {
        (uint160 sqrtPrice,,,) = manager.getSlot0(key.toId());
        uint256 p = FullMath.mulDiv(sqrtPrice, sqrtPrice, 1 << 96);
        return subject == key.currency0 ? FullMath.mulDiv(p, 1e18, 1 << 96) : FullMath.mulDiv(1 << 96, 1e18, p);
    }

    /// @dev The gap between two prices, in basis points of the lower.
    function _gapBps(uint256 x, uint256 y) internal pure returns (uint256) {
        (uint256 lo, uint256 hi) = x < y ? (x, y) : (y, x);
        return (hi - lo) * 10_000 / lo;
    }
}
