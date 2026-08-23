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
import {ILeverage} from "../src/interfaces/ILeverage.sol";
import {HookMiner} from "./utils/HookMiner.sol";

interface IERC20D {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Regressions for defects found by reading the code after the invariant suite came
///         back clean. Invariants prove the ledger agrees with itself; these three were about
///         it agreeing with reality, and none of them moved a single invariant.
contract LeverageDefectsTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant WAD = 1e18;

    IPoolManager manager;
    LeverageHook hook;
    LeverageFactory factory;
    LeverageMarket market;
    LeverageRouter router;
    IERC20D token;
    PoolKey key;
    PoolId id;

    receive() external payable {}

    /// Walks the observation ring forward with spaced trades until the market trusts itself.
    function _warmRing(address arb) internal {
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 26; i++) {
            t += 46;
            vm.warp(t);
            vm.deal(arb, 5_000 ether);
            vm.prank(arb);
            router.swap{value: 0.05 ether}(
                LeverageRouter.SwapArgs({
                    key: key,
                    zeroForOne: true,
                    amountSpecified: -0.05 ether,
                    sqrtPriceLimitX96: 4295128739 + 1,
                    amountBound: 0,
                    recipient: arb,
                    deadline: type(uint256).max
                })
            );
        }
    }

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        router = new LeverageRouter(manager);
        uint160 flags = uint160((1 << 13) | (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6));
        bytes memory creation = abi.encodePacked(type(LeverageHook).creationCode, abi.encode(manager, address(this)));
        (, bytes32 salt) = HookMiner.find(address(this), flags, creation);
        hook = new LeverageHook{salt: salt}(manager, address(this));
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
        (address t, address m) = factory.createMarket{value: 100 ether}(
            "Node", "NODE", "", "", 1_000_000 ether, SQRT_PRICE_1_1, 50 ether, cfg
        );
        token = IERC20D(t);
        market = LeverageMarket(payable(m));
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(t),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();
    }

    /// D1: NAV once counted only the idle balance and the receivable, omitting the market's
    /// own v4 position — its largest single asset — so every share price it quoted was
    /// against a market that looked empty.
    function test_D1_navIncludesThePoolPosition() public view {
        assertGt(manager.getLiquidity(id), 0, "pool holds the seeded liquidity");
        uint256 idle = market.idleQuote();
        (uint256 poolQuote, uint256 poolTokens) = market.positionValue();
        assertGt(poolQuote, 0, "the position holds quote");
        assertGt(poolTokens, 0, "and tokens");
        // The old bound was `nav >= idle + poolQuote`, measured at 100 ETH against 50 — 100%
        // slack, so dropping the position's ENTIRE token leg from NAV would still have passed
        // the test named for NAV seeing the position. Count both legs.
        assertGt(market.navQuote(false), idle, "NAV must see the pool position");
        uint256 price = hook.priceView(id).twapWad;
        assertGe(
            market.navQuote(false) + 1,
            idle + poolQuote + (poolTokens * price) / 1e18,
            "NAV must see BOTH legs, not just the quote side"
        );
    }

    /// D2: the term meant to be "executable liquidation depth" was raw v4 liquidity (L),
    /// which is not an ETH amount. Putting it in a minimum against ETH terms was a category
    /// error rather than a conservative estimate.
    function test_D2_depthTermIsQuoteDenominated() public {
        // Raw liquidity L is not an ETH amount and must never meet ETH terms in a minimum.
        // At a 1:1 seed L and the quote side agree to seventeen significant figures, so the
        // old assertion `L != poolQuote` passed by three wei and proved nothing. Move the
        // price first, so the two are genuinely different numbers.
        _warmRing(address(0x44));

        (uint256 realQuote,) = market.positionReserves();
        uint256 liq = uint256(manager.getLiquidity(id));
        assertGt(realQuote, 0, "the position has a quote side");
        assertGt(
            liq > realQuote ? liq - realQuote : realQuote - liq,
            realQuote / 100,
            "setup: L and the quote side must differ materially, or this proves nothing"
        );

        // The old test never called the thing it was named for, so reverting the depth term
        // to raw L was invisible to it. Pin it to the quote side.
        assertEq(market.creditCapacity(), realQuote / 2, "depth is half the QUOTE side, not L");
    }

    /// D3: a position could only be closed, never rescued — the UI offered "add collateral"
    /// and "repay" against a contract that had neither, so the only exit from a position
    /// drifting toward liquidation was to realise the loss.
    function test_D3_aPositionCanBeRescued() public {
        address lp = address(0x6666);
        address trader = address(0x7777);
        address arb = address(0x8888);
        vm.deal(lp, 500 ether);
        vm.deal(trader, 500 ether);
        vm.deal(arb, 5_000 ether);

        // The ring has to cover its window before the market will move any value.
        _warmRing(arb);

        vm.prank(lp);
        market.deposit{value: 100 ether}();

        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);

        (uint128 c0, uint128 d0) = market.positions(trader);
        assertGt(c0, 0, "position opened");
        assertGt(d0, 0, "with debt");
        uint256 health0 = market.healthFactorOf(trader);

        // Rescue 1: more collateral raises health without closing anything.
        vm.prank(trader);
        market.addCollateral{value: 1 ether}(0);
        (uint128 c1,) = market.positions(trader);
        assertGt(c1, c0, "collateral grew");
        assertGt(market.healthFactorOf(trader), health0, "health improved");

        // Rescue 2: repaying reduces the debt rather than the position.
        uint256 owed = market.debtOf(trader);
        vm.prank(trader);
        market.repay{value: owed / 2}();
        assertLt(market.debtOf(trader), owed, "debt fell");
        (uint128 c2, uint128 d2) = market.positions(trader);
        assertEq(c2, c1, "collateral untouched by a repayment");
        assertGt(d2, 0, "partial repayment leaves the position open");

        // Repaying more than is owed refunds the excess rather than keeping it.
        uint256 before = trader.balance;
        uint256 remaining = market.debtOf(trader);
        vm.prank(trader);
        market.repay{value: remaining + 5 ether}();
        assertEq(market.debtOf(trader), 0, "fully repaid");
        assertGe(trader.balance, before - remaining - 1, "excess refunded");
    }
}
