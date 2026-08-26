// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {LeverageHook} from "../src/LeverageHook.sol";
import {LeverageFactory} from "../src/LeverageFactory.sol";
import {LeverageMarket} from "../src/LeverageMarket.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {LeverageBookLib} from "../src/libraries/LeverageBookLib.sol";
import {LeverageOracleLib} from "../src/libraries/LeverageOracleLib.sol";
import {ILeverage} from "../src/interfaces/ILeverage.sol";
import {HookMiner} from "./utils/HookMiner.sol";

interface IERC20T {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @notice The queue must take a position the incoming sell genuinely reaches, even when a
///         co-located position it does NOT reach is ahead of it in the same bucket.
///
///         The book buckets positions by liquidation price to within ~one sixteenth of an
///         octave, and order WITHIN a bucket is arbitrary — `LeverageMarket._link` head-inserts
///         and its own comment says "Order within a bucket carries no meaning." So two positions
///         a couple of percent apart in liquidation price can share a bucket, and which of them
///         the walk reads first is decided by nothing an incoming trade can see.
///
///         `_drainQueue`'s descending walk is monotone in health BETWEEN buckets but not within
///         one. A bucket-head that this trade does not reach (healthy at the average, or not
///         crossed by the projected price) must therefore NOT hide a co-located sibling that
///         the trade does reach: the head's refusal is about the head, not about the members
///         behind it. This test stages exactly that co-location and asserts the reachable
///         position is taken.
contract LeverageQueueIntraBucketTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_LIMIT = 4295128739 + 1;
    uint160 constant MAX_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;
    uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    uint256 constant WAD = 1e18;
    uint256 constant BPS = 10_000;
    uint24 constant BASE_FEE_PIPS = 3000;
    uint24 constant MAX_FEE_PIPS = 30_000;

    IPoolManager manager;
    LeverageHook hook;
    LeverageFactory factory;
    LeverageRouter router;
    LeverageMarket market;
    IERC20T token;
    PoolKey key;
    PoolId id;

    address lp = address(0x11);
    address arb = address(0x44);
    address keeper = address(0x33);
    address victim = address(0x77);
    address blocker = address(0x88);
    address seller = address(0x55);

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        router = new LeverageRouter(manager);

        uint160 flags = uint160((1 << 13) | (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6));
        bytes memory creation = abi.encodePacked(type(LeverageHook).creationCode, abi.encode(manager, address(this)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), flags, creation);
        hook = new LeverageHook{salt: salt}(manager, address(this));
        assertEq(address(hook), predicted, "hook address");

        factory = new LeverageFactory(manager, hook);
        hook.setFactory(address(factory));

        ILeverage.MarketConfig memory cfg = ILeverage.MarketConfig({
            ltvBps: 6_000,
            liqThresholdBps: 8_000,
            liqBonusBps: 500,
            reserveFactorBps: 1_000,
            kinkWad: uint64(WAD * 8 / 10),
            maxUtilisationWad: uint64(WAD * 9 / 10),
            protocolCapWei: 1_000 ether,
            minPoolQuoteWei: 0
        });

        vm.deal(address(this), 100_000 ether);
        (address tokenAddr, address marketAddr) = factory.createMarket{value: 500 ether}(
            "Node", "NODE", "", "", 1_000_000 ether, SQRT_PRICE_1_1, 300 ether, cfg
        );
        token = IERC20T(tokenAddr);
        market = LeverageMarket(payable(marketAddr));
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(tokenAddr),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();

        vm.deal(lp, 100_000 ether);
        vm.deal(arb, 100_000 ether);
        vm.deal(keeper, 10 ether);
        vm.deal(victim, 1_000 ether);
        vm.deal(blocker, 1_000 ether);
        vm.deal(seller, 100_000 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _buy(address who, uint256 amountIn) internal {
        vm.prank(who);
        router.swap{value: amountIn}(
            LeverageRouter.SwapArgs({
                key: key,
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: MIN_LIMIT,
                amountBound: 0,
                recipient: who,
                deadline: type(uint256).max
            })
        );
    }

    function _sell(address who, uint256 tokensIn) internal {
        vm.prank(who);
        token.approve(address(router), type(uint256).max);
        vm.prank(who);
        router.swap(
            LeverageRouter.SwapArgs({
                key: key,
                zeroForOne: false,
                amountSpecified: -int256(tokensIn),
                sqrtPriceLimitX96: MAX_LIMIT,
                amountBound: 0,
                recipient: who,
                deadline: type(uint256).max
            })
        );
    }

    function _warmOracle() internal {
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < LeverageOracleLib.MAX_WALK + 3; i++) {
            t += LeverageOracleLib.MIN_SPACING_SEC + 1;
            vm.warp(t);
            _buy(arb, 0.05 ether);
            vm.deal(arb, 100_000 ether);
        }
    }

    function _q(address trader) internal view returns (uint256 idx, uint256 q) {
        (uint128 coll, uint128 scaled) = market.positions(trader);
        if (scaled == 0) return (type(uint256).max, 0);
        (, uint16 thr,,,,,,) = market.config();
        uint256 k = uint256(coll) * uint256(thr) / BPS;
        q = _mulUp(uint256(scaled), WAD, k);
        idx = LeverageBookLib.key(q);
    }

    function _mulUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        uint256 x = a * b;
        return x == 0 ? 0 : (x - 1) / d + 1;
    }

    /// Mirror of LeverageHook._projectedPriceWad, normalised into bucket space.
    function _projectedNorm(uint256 amountIn) internal view returns (uint256 pNorm) {
        (uint160 sqrtP,,,) = manager.getSlot0(id);
        uint128 L = manager.getLiquidity(id);
        if (sqrtP == 0 || L == 0) return 0;
        uint256 ratioBps = FullMath.mulDiv(amountIn, BPS, uint256(L));
        uint256 extra = ratioBps * BASE_FEE_PIPS / BPS;
        uint256 total = uint256(BASE_FEE_PIPS) + extra;
        uint24 fee = total > MAX_FEE_PIPS ? MAX_FEE_PIPS : uint24(total);
        uint256 net = amountIn - FullMath.mulDiv(amountIn, fee, 1_000_000);
        uint256 next = uint256(sqrtP) + FullMath.mulDiv(net, 1 << 96, uint256(L));
        if (next >= MAX_SQRT_PRICE) next = MAX_SQRT_PRICE - 1;
        uint256 pp = FullMath.mulDiv(next, next, 1 << 96);
        uint256 priceWad = pp == 0 ? 0 : FullMath.mulDiv(WAD, 1 << 96, pp);
        pNorm = FullMath.mulDiv(priceWad, WAD, market.borrowIndex());
    }

    /// Dump `d` tokens from arb, then warm so the TWAP catches up.
    function _strandTrial(uint256 d) internal returns (uint256 hv, uint256 hb) {
        token.transfer(arb, d);
        _sell(arb, d);
        _warmOracle();
        hv = market.liquidationHealthOf(victim);
        hb = market.liquidationHealthOf(blocker);
    }

    /// @dev Strands both positions so the TWAP lands in the ~1.5% liquidation-price gap between
    ///      them: the higher-liquidation-price VICTIM is unhealthy at the average, while the
    ///      lower one (the BLOCKER at the bucket head) is still healthy. Bisects the dump on the
    ///      blocker's health boundary — the largest dump that keeps the blocker healthy is one
    ///      that already has the victim under, which is the state the test needs.
    function _strandIntoGap() internal {
        uint256 lo = 150 ether; // both healthy
        uint256 hi = 200 ether; // both unhealthy
        uint256 chosen = 0;
        for (uint256 i = 0; i < 60; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (uint256 hv, uint256 hb) = _strandTrial(mid);
            if (hb > WAD) {
                if (hv <= WAD) chosen = mid;
                lo = mid;
            } else {
                hi = mid;
            }
            vm.revertToState(snap);
        }
        require(chosen != 0, "setup: no strand lands the TWAP in the gap");
        _strandTrial(chosen);
    }

    // ------------------------------------------------------------------ the test

    /// The blocker (bucket head, lower liquidation price) is healthy at the average and refuses;
    /// the victim behind it in the SAME bucket is unhealthy and genuinely reached by the sell.
    /// The queue must still take the victim.
    function test_aRefusingBucketHeadDoesNotHideAReachablePosition() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 2_000 ether}();
        _warmOracle();

        // victim first (higher q), blocker last => bucket head (lower q). Co-located.
        vm.prank(victim);
        market.openPosition{value: 0.5 ether}(15000 * WAD / BPS, 0);
        vm.prank(blocker);
        market.openPosition{value: 0.5 ether}(14850 * WAD / BPS, 0);

        (uint256 iv, uint256 qv) = _q(victim);
        (uint256 ib, uint256 qb) = _q(blocker);
        require(iv == ib, "setup: positions must share a bucket");
        require(market.bucketHead(ib) == blocker, "setup: blocker must be the bucket head");
        require(qb < qv, "setup: blocker's liquidation price must be below the victim's");

        _strandIntoGap();
        // The precondition that makes this a real skip and not merely a healthy book:
        assertLe(market.liquidationHealthOf(victim), WAD, "victim must be liquidatable at the average");
        assertGt(market.liquidationHealthOf(blocker), WAD, "blocker must be healthy at the average");

        uint256 sellAmt = 60_000 ether;
        // The sell's projected price is below BOTH liquidation prices, so the victim is genuinely
        // crossed by it — the queue's own condition for taking a position is met.
        assertLe(_projectedNorm(sellAmt), qb, "the sell must cross the whole bucket");

        (uint128 vColl0,) = market.positions(victim);
        (uint128 bColl0,) = market.positions(blocker);

        // The victim is takeable right now: a keeper's liquidate() succeeds on it.
        uint256 s = vm.snapshotState();
        vm.prank(keeper);
        market.liquidate(victim, 0);
        (uint128 vCollByKeeper,) = market.positions(victim);
        assertLt(vCollByKeeper, vColl0, "sanity: the victim is liquidatable this very block");
        vm.revertToState(s);

        // The real trigger: the queue runs inside this sell.
        token.transfer(seller, sellAmt);
        _sell(seller, sellAmt);

        (uint128 vColl1,) = market.positions(victim);
        (uint128 bColl1,) = market.positions(blocker);

        // The blocker is healthy, so it is correctly left alone.
        assertEq(bColl1, bColl0, "the healthy bucket-head is not seized");
        // The victim is reachable and liquidatable, so the queue must have taken it — even though
        // the refusing blocker sits ahead of it in the same bucket. On the buggy implementation
        // the blocker's refusal ends the pass and this fails.
        assertLt(vColl1, vColl0, "the queue must take the reachable position behind a refusing head");
    }
}
