// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {LeverageHook} from "../src/LeverageHook.sol";
import {LeverageFactory} from "../src/LeverageFactory.sol";
import {LeverageMarket} from "../src/LeverageMarket.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {LeverageOracleLib} from "../src/libraries/LeverageOracleLib.sol";
import {ILeverage} from "../src/interfaces/ILeverage.sol";
import {HookMiner} from "./utils/HookMiner.sol";

interface IERC20T {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @notice The whole loop, through real contracts: a market is opened, an LP funds it, a
///         trader borrows the market's own liquidity to go long, and the position is closed
///         or liquidated back through the same pool.
contract LeverageEndToEndTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_LIMIT = 4295128739 + 1;
    uint160 constant MAX_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;
    uint256 constant WAD = 1e18;

    IPoolManager manager;
    LeverageHook hook;
    LeverageFactory factory;
    LeverageRouter router;
    LeverageMarket market;
    IERC20T token;
    PoolKey key;
    PoolId id;

    address lp = address(0x11);
    address trader = address(0x22);
    address keeper = address(0x33);
    address arb = address(0x44);

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

        vm.deal(address(this), 10_000 ether);
        (address tokenAddr, address marketAddr) = factory.createMarket{value: 100 ether}(
            "Node", "NODE", "", "", 1_000_000 ether, SQRT_PRICE_1_1, 50 ether, cfg
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

        vm.deal(lp, 1_000 ether);
        vm.deal(trader, 1_000 ether);
        vm.deal(keeper, 10 ether);
        vm.deal(arb, 10_000 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _swapEthForToken(address who, uint256 amountIn) internal {
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

    /// Warms the observation ring until the market trusts its own price.
    function _warmOracle() internal {
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < LeverageOracleLib.MAX_WALK + 3; i++) {
            t += LeverageOracleLib.MIN_SPACING_SEC + 1;
            vm.warp(t);
            _swapEthForToken(arb, 0.05 ether);
            vm.deal(arb, 10_000 ether);
        }
    }

    // ------------------------------------------------------------------ the pool exists

    function test_factoryOpensAMarketWithLiquidity() public view {
        assertGt(manager.getLiquidity(id), 0, "pool has liquidity");
        assertEq(factory.marketOf(address(token)), address(market), "market registered");
        assertEq(hook.marketOf(id), address(market), "hook knows the market");
        // Unsold supply goes back to the creator; the market keeps its value in the pool
        // position rather than as loose inventory it could not sell at the marked price.
        assertEq(token.balanceOf(address(market)), 0, "no loose inventory on the balance sheet");
        assertGt(token.balanceOf(address(this)), 0, "creator keeps the unsold supply");
    }

    /// F5: without a route the pool cannot be arbitraged, and every risk term rests on a
    /// price nothing keeps honest. The route ships with the market.
    function test_theLeveragePoolIsActuallyTradable() public {
        uint256 before = token.balanceOf(arb);
        _swapEthForToken(arb, 1 ether);
        assertGt(token.balanceOf(arb), before, "spot swap through the leverage pool");
    }

    // ------------------------------------------------------------------ the LP side

    function test_lpDepositsAndHoldsAShareOfTheMarket() public {
        _warmOracle();
        vm.prank(lp);
        uint256 shares = market.deposit{value: 10 ether}();
        assertGt(shares, 0, "shares minted");
        assertEq(market.balanceOf(lp), shares, "lp holds them");
        assertGe(market.idleQuote(), 10 ether, "quote is in the market");
    }

    function test_redeemReturnsQuoteAndBurnsShares() public {
        _warmOracle();
        vm.prank(lp);
        uint256 shares = market.deposit{value: 10 ether}();
        uint256 balBefore = lp.balance;

        vm.prank(lp);
        uint256 paid = market.redeem(shares);

        assertGt(paid, 0, "paid something");
        assertEq(lp.balance, balBefore + paid, "lp received it");
        assertLt(market.balanceOf(lp), shares, "shares burned");
    }

    /// F4: minting and redeeming against the SAME bound is a one-way ratchet. Marking up on
    /// the way in and down on the way out makes the spread a cost to whoever crosses it.
    function test_navIsQuotedTwoSided() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 10 ether}();
        _warmOracle();
        // The two marks must actually differ, or "up >= down" is satisfied by a one-way
        // ratchet that quotes the same number both ways — which is the regression this test
        // is named for. assertGe accepted exactly that.
        ILeverage.PriceView memory p = hook.priceView(id);
        assertTrue(p.spotWad != p.twapWad, "setup: the marks must diverge for this to prove anything");

        uint256 up = market.navQuote(true);
        uint256 down = market.navQuote(false);
        assertGt(up, down, "issuance mark must be strictly above the redemption mark");
    }

    /// A round trip cannot mint value out of the market.
    function test_depositRedeemRoundTripIsNotProfitable() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 50 ether}();

        _warmOracle();

        vm.prank(trader);
        uint256 shares = market.deposit{value: 10 ether}();
        vm.prank(trader);
        uint256 out = market.redeem(shares);
        assertLe(out, 10 ether, "round trip must not profit");
    }

    // ------------------------------------------------------------------ the trader side

    function test_protectedUntilTheOracleIsWarm() public {
        // A market whose ring cannot cover its window does not move value in either
        // direction: it will not mint shares against a mark it does not trust, and it will
        // not write credit.
        assertTrue(hook.isProtected(id), "fresh market is protected");

        vm.prank(lp);
        vm.expectRevert(ILeverage.Protected.selector);
        market.deposit{value: 50 ether}();

        vm.prank(trader);
        vm.expectRevert(ILeverage.Protected.selector);
        market.openPosition{value: 1 ether}(2 * WAD, 0);
    }

    function test_openTwoTimesLongBorrowsFromTheMarketItself() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 50 ether}();
        _warmOracle();

        uint256 idleBefore = market.idleQuote();

        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);

        (uint128 collateral, uint128 scaledDebt) = market.positions(trader);
        assertGt(collateral, 0, "collateral locked");
        assertGt(scaledDebt, 0, "debt booked");
        assertApproxEqAbs(market.debtOf(trader), 2 ether, 1e12, "2x on 2 ETH borrows 2 ETH");

        // The market financed it out of its own liquidity: idle fell by the borrowed amount
        // even though the trader added 2 ETH of equity.
        //
        // The old bound was `idle < idleBefore + 2 ether`, which any spend at all satisfies —
        // including one that spent only the trader's own equity and lent nothing. The point of
        // the test is that the market's OWN capital left, so assert the size of the fall.
        assertApproxEqAbs(
            market.idleQuote(),
            idleBefore - 2 ether,
            1e12,
            "the market must have lent 2 ETH of its own, not just recycled the equity"
        );
        assertGt(market.healthFactorOf(trader), WAD, "opens on the safe side");
    }

    function test_openRefusedPastCapacity() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 1 ether}();
        _warmOracle();
        vm.prank(trader);
        // Named, not bare. A bare expectRevert passes on ANY revert — including Unhealthy or
        // Protected — so it could not tell the capacity ceiling from an unrelated refusal.
        vm.expectRevert(LeverageMarket.OverCapacity.selector);
        market.openPosition{value: 500 ether}(2 * WAD, 0);
    }

    function test_closeAtProfitRepaysTheMarketAndPaysTheTrader() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 50 ether}();
        _warmOracle();

        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);

        // Someone else buys, pushing the token up.
        _swapEthForToken(arb, 40 ether);

        uint256 before = trader.balance;
        vm.prank(trader);
        market.closePosition(0);

        (uint128 collateral, uint128 debt) = market.positions(trader);
        assertEq(collateral, 0, "position cleared");
        assertEq(debt, 0, "debt cleared");
        assertGt(trader.balance, before, "trader took proceeds");
        assertEq(market.totalScaledDebt(), 0, "market's book is flat");
    }

    function test_interestAccruesToTheMarket() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 50 ether}();
        _warmOracle();
        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);

        uint256 owedBefore = market.debtOf(trader);
        vm.warp(block.timestamp + 30 days);
        market.accrue();
        assertGt(market.debtOf(trader), owedBefore, "debt grew with time");
        assertGt(market.reserveQuote(), 0, "reserve took its cut of the interest");
    }

    // ------------------------------------------------------------------ liquidation

    function test_liquidationUnwindsAndPaysABoundedBonus() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 100 ether}();
        _warmOracle();

        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);

        // Sell the token down hard, then let the average catch up so the market is not
        // merely refusing to act because it distrusts its own price.
        // The creator's unsold supply is the only bag big enough to move this pool; arb's own
        // holdings come from the warming buys and barely dent it.
        token.transfer(arb, token.balanceOf(address(this)) / 2);
        uint256 bal = token.balanceOf(arb);
        vm.prank(arb);
        token.approve(address(router), type(uint256).max);
        vm.prank(arb);
        router.swap(
            LeverageRouter.SwapArgs({
                key: key,
                zeroForOne: false,
                amountSpecified: -int256(bal),
                sqrtPriceLimitX96: MAX_LIMIT,
                amountBound: 0,
                recipient: arb,
                deadline: type(uint256).max
            })
        );
        _warmOracle();
        vm.warp(block.timestamp + 200 days);
        market.accrue();
        _warmOracle();

        // A hard precondition, not a silent skip. This used to read
        //     if (market.healthFactorOf(trader) > WAD) return;
        // and the position measured 1.609, so the test returned before calling liquidate and
        // executed no assertions at all — the most dangerous path in the system was covered
        // by nothing. It also could not have passed if reached: `_seizeCap` bounds a seize at
        // a twenty-fifth of the token side, so `assertEq(collateral, 0)` was asserting the
        // opposite of the shipped design.
        assertLe(market.liquidationHealthOf(trader), WAD, "setup: the position must be liquidatable");

        (uint128 collateralBefore,) = market.positions(trader);
        uint256 debtBefore = market.debtOf(trader);

        vm.prank(keeper);
        market.liquidate(trader, 0);

        (uint128 collateralAfter,) = market.positions(trader);
        assertLt(collateralAfter, collateralBefore, "collateral was seized");
        assertLt(market.debtOf(trader), debtBefore, "the seize repaid debt");

        // The incentive is a PULL payment. The old assertion watched `keeper.balance`, which
        // liquidate never touches, so it could not have failed either way.
        uint256 bonus = market.claimable(keeper);
        assertGt(bonus, 0, "keeper earned the incentive");
        assertLe(
            bonus,
            (debtBefore - market.debtOf(trader)) * config_liqBonusBps() / 10_000 + 1,
            "and it stayed inside the configured bonus"
        );
    }

    /// The bonus rate the market was configured with, read back rather than hard-coded so this
    /// bound moves with the config instead of quietly going stale.
    function config_liqBonusBps() internal view returns (uint256) {
        (,, uint16 liqBonusBps,,,,,) = market.config();
        return uint256(liqBonusBps);
    }

    function test_healthyPositionCannotBeLiquidated() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 50 ether}();
        _warmOracle();
        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);

        vm.prank(keeper);
        vm.expectRevert(LeverageMarket.Healthy.selector);
        market.liquidate(trader, 0);
    }

    // ------------------------------------------------------------------ the balance sheet

    /// The double count the design exists to rule out: a borrower's collateral is theirs, and
    /// the receivable it secures is already counted. NAV must not move when a position opens.
    function test_openingAPositionDoesNotInflateNav() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 50 ether}();
        _warmOracle();

        uint256 navBefore = market.navQuote(false);
        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);
        uint256 navAfter = market.navQuote(false);

        // The trader's equity and collateral are not LP value. The old bound was 5% relative,
        // but the double count this test exists to catch is worth ~2.3% of NAV here — the bug
        // fitted inside its own tolerance. Measured, the two are identical to the wei, so an
        // absolute bound that merely covers the swap fee is the honest one.
        assertApproxEqAbs(navAfter, navBefore, 0.01 ether, "opening must not mint LP value");
    }

    function test_ownedTokensExcludesBorrowerCollateral() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 50 ether}();
        _warmOracle();

        uint256 ownedBefore = market.ownedTokens();
        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);

        (uint128 collateral,) = market.positions(trader);
        assertGt(collateral, 0, "collateral exists");
        // Every token the position holds is excluded from what the market owns.
        assertApproxEqAbs(market.ownedTokens(), ownedBefore, 1, "collateral is not market inventory");
    }

    // ------------------------------------------------- the observation accumulator

    address internal attacker = address(0x99);

    function _sellTokens(address who, uint256 tokens) internal {
        vm.prank(who);
        token.approve(address(router), type(uint256).max);
        vm.prank(who);
        router.swap(
            LeverageRouter.SwapArgs({
                key: key,
                zeroForOne: false,
                amountSpecified: -int256(tokens),
                sqrtPriceLimitX96: MAX_LIMIT,
                amountBound: 0,
                recipient: who,
                deadline: type(uint256).max
            })
        );
    }

    // ------------------------------------------------------------------ (1) oracle capture

    /// The rate limiter used to hide a dump instead of merely spacing the ring.
    ///
    /// `write` returned early below MIN_SPACING_SEC and threw the interval away, and the tick it
    /// eventually stored then described the NEXT 45 seconds as well as the 45 before it. So a
    /// trader dumped at lastWrite+44 (never recorded), bought back at lastWrite+45 (the dumped
    /// pre-swap tick was stamped into the head, and the buy restored spot in the same
    /// transaction). One second of real displacement bought 45 seconds of window weight.
    ///
    /// Unfixed this drives the reported average to under 1% of a spot the attacker has handed
    /// back intact, with `stale` false the whole way. Fixed, a round trip that lasts one second
    /// weighs one second.
    function test_aRateLimitedRoundTripCannotBuyTheAveragingWindow() public {
        _warmOracle();

        token.transfer(attacker, token.balanceOf(address(this)) / 2);
        vm.deal(attacker, 10_000 ether);

        ILeverage.PriceView memory before_ = hook.priceView(id);
        assertFalse(before_.stale, "setup: the ring must already cover its window");

        uint256 dump = token.balanceOf(attacker) / 800;
        uint256 t = block.timestamp;

        // 24 cycles. block.timestamp is hoisted out of loops under via_ir, so the clock is
        // tracked explicitly and every warp is to an absolute value.
        for (uint256 i = 0; i < 24; i++) {
            t += LeverageOracleLib.MIN_SPACING_SEC - 1; // lastWrite + 44: the write is skipped
            vm.warp(t);
            uint256 ethBefore = attacker.balance;
            _sellTokens(attacker, dump);
            uint256 proceeds = attacker.balance - ethBefore;

            t += 1; // lastWrite + 45: the write lands, carrying the dumped tick
            vm.warp(t);
            // Buy back with EXACTLY the dump's proceeds, so the cycle is ETH-neutral and spot
            // is handed back where it was found. A cycle that net-bought would move the average
            // legitimately and prove nothing.
            _swapEthForToken(attacker, proceeds);
        }

        ILeverage.PriceView memory p = hook.priceView(id);
        assertFalse(p.stale, "the capture ran with the ring reporting itself covered");

        // The invariant is that the reported average cannot be separated from the price that is
        // actually standing — that separation is the whole exploit, since it is what makes a
        // solvent position read as liquidatable.
        //
        // Measured on this exact scenario: unfixed the average comes back at 7/1000 of spot, a
        // 99.3% dislocation bought with nothing but timing. Fixed it comes back at 995/1000,
        // the half-percent being the 24 seconds the attacker genuinely did hold the price down.
        //
        // Deliberately NOT asserted against the pre-attack average: 24 round trips of this size
        // pay real LP fees into the pool, so spot itself legitimately drifts about 20% over the
        // run. That drift is the attacker's money going to the LPs, not a defect.
        assertGt(p.twapWad * 100 / p.spotWad, 90, "the average was dragged away from a restored spot");
        assertFalse(p.deviated, "spot and the average must still agree");
    }

    /// Isolates the second half of the fix: the trailing stub between the newest stored
    /// observation and now.
    ///
    /// One rate-limited cycle stamps the DUMPED tick into the head, then spot is handed back
    /// and the market goes quiet. Extrapolating the stub from that stored tick meant every idle
    /// second after the attack kept re-pricing the pool at the tick the attacker had left
    /// behind, so simply waiting deepened the lie. Extrapolating from the live tick means the
    /// idle seconds report the price that is actually standing.
    function test_theTrailingStubFollowsLiveSpotNotTheStoredHead() public {
        _warmOracle();

        token.transfer(attacker, token.balanceOf(address(this)) / 2);
        vm.deal(attacker, 10_000 ether);

        uint256 t = block.timestamp + LeverageOracleLib.MIN_SPACING_SEC - 1;
        vm.warp(t);
        uint256 ethBefore = attacker.balance;
        _sellTokens(attacker, token.balanceOf(attacker) / 800); // rate-limited: nothing stored
        uint256 proceeds = attacker.balance - ethBefore;

        t += 1; // the write lands here, carrying the dumped pre-swap tick into the head
        vm.warp(t);
        _swapEthForToken(attacker, proceeds); // and spot is restored in the same second

        // Now nobody trades. Every second of this stub is priced by whatever the stub is
        // extrapolated from.
        t += 30;
        vm.warp(t);

        ILeverage.PriceView memory p = hook.priceView(id);
        assertGt(p.twapWad * 100 / p.spotWad, 90, "idle seconds were priced at the attacker's tick");
    }

    // ------------------------------------------------------------------ (1b) oracle liveness

    /// A market nobody has traded since it was created used to wedge shut permanently.
    ///
    /// The walk broke on the unwritten slot behind the seed before it could compare the seed
    /// itself against the window, so `covered` was false forever, `isProtected` was true
    /// forever, and `deposit` and `openPosition` reverted with no way to reopen them except a
    /// swap from someone with no reason to make one. An observation older than the window is
    /// the strongest history there is: nothing has moved the price since.
    function test_aPoolQuieterThanItsWindowDoesNotWedgeShut() public {
        vm.warp(block.timestamp + LeverageOracleLib.WINDOW_SEC * 3);

        assertFalse(hook.isProtected(id), "a quiet market reported itself unusable");

        ILeverage.PriceView memory p = hook.priceView(id);
        assertFalse(p.stale, "a single observation older than the window covers the window");
        assertEq(p.twapWad, p.spotWad, "with nothing traded, the average is the price");

        // And the paths the wedge closed are actually open.
        vm.prank(lp);
        market.deposit{value: 1 ether}();
    }

    // ------------------------------------------------------------------ (2) redemption sandwich
}
