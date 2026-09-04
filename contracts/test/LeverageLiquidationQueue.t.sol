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

import {LeverageHook} from "../src/LeverageHook.sol";
import {LeverageFactory} from "../src/LeverageFactory.sol";
import {LeverageMarket} from "../src/LeverageMarket.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {LeverageBookLib} from "../src/libraries/LeverageBookLib.sol";
import {LeverageOracleLib} from "../src/libraries/LeverageOracleLib.sol";
import {ILeverage, ILeverageQueue} from "../src/interfaces/ILeverage.sol";
import {HookMiner} from "./utils/HookMiner.sol";

interface IERC20T {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @notice The liquidation queue: a sell that crosses somebody's liquidation price waits behind
///         the liquidation it caused, and pays for it in its own fill.
///
///         Two properties are load-bearing here and each has its own test, because they pull in
///         opposite directions and a change that satisfies one by breaking the other would look
///         like an improvement:
///
///         1. A sell that genuinely reaches a liquidatable position executes BEHIND that
///            position's forced sale, and fills worse for it. That is the feature.
///         2. A sell cannot MAKE a position liquidatable by moving spot. The trigger is
///            narrowed by the projected price but authorised by the time-weighted average, so
///            a same-block push liquidates nobody. That is the thing the feature must not cost.
contract LeverageLiquidationQueueTest is Test {
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
    address seller = address(0x55);

    event LiquidatedAhead(
        PoolId indexed id, address indexed swapper, uint256 count, uint256 tokensSold, uint256 projectedPriceWad
    );

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
        vm.deal(seller, 1_000 ether);
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

    /// An exact-input sell of `tokensIn`, returning the quote it actually produced.
    function _sell(address who, uint256 tokensIn) internal returns (uint256 received) {
        vm.prank(who);
        token.approve(address(router), type(uint256).max);
        uint256 before = who.balance;
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
        received = who.balance - before;
    }

    function _warmOracle() internal {
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < LeverageOracleLib.MAX_WALK + 3; i++) {
            t += LeverageOracleLib.MIN_SPACING_SEC + 1;
            vm.warp(t);
            _buy(arb, 0.05 ether);
            vm.deal(arb, 10_000 ether);
        }
    }

    /// @dev Opens a leveraged position and then walks the market down until the AVERAGE — not
    ///      merely spot — calls it liquidatable. That distinction is the whole point of the
    ///      setup: a position that is only unhealthy at spot is the subject of a different test.
    function _openAndStrand() internal {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 100 ether}();
        _warmOracle();

        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);

        // The creator's unsold supply is the only bag big enough to move this pool.
        token.transfer(arb, token.balanceOf(address(this)) / 2);
        _sell(arb, token.balanceOf(arb));

        // Let the average catch up, so the market is not merely refusing to act because it
        // distrusts its own price.
        _warmOracle();
        assertLe(market.liquidationHealthOf(trader), WAD, "setup: the position must be liquidatable");
    }

    /// Enough of the creator's supply to move the price, handed to whoever is about to sell.
    function _fund(address who, uint256 divisor) internal returns (uint256 amount) {
        amount = token.balanceOf(address(this)) / divisor;
        token.transfer(who, amount);
    }

    // ------------------------------------------------------------------ the feature

    /// The queue runs INSIDE the seller's swap. No keeper, no second transaction: the position
    /// is taken by the trade that reached it.
    function test_anIncomingSellTakesTheLiquidationAheadOfItself() public {
        _openAndStrand();
        uint256 amount = _fund(seller, 8);

        (uint128 collateralBefore,) = market.positions(trader);
        uint256 debtBefore = market.debtOf(trader);

        uint256 received = _sell(seller, amount);

        (uint128 collateralAfter,) = market.positions(trader);
        assertLt(collateralAfter, collateralBefore, "the position was taken by the swap itself");
        assertLt(market.debtOf(trader), debtBefore, "and the sale repaid its debt");
        assertGt(received, 0, "the seller's own swap still completed");
    }

    /// The seller pays for the queue, and pays it as slippage.
    ///
    /// The control is `repay`, which is the one action that changes a position's health without
    /// touching the pool: both runs sell the same tokens into the same reserves at the same
    /// price, and the ONLY difference is whether there is a liquidation ahead of them.
    function test_theSellerPaysForTheQueueAsSlippage() public {
        _openAndStrand();
        uint256 amount = _fund(seller, 8);

        uint256 snap = vm.snapshotState();

        uint256 withQueue = _sell(seller, amount);

        vm.revertToState(snap);

        vm.deal(trader, 1_000 ether);
        // Read the debt BEFORE the prank. An argument expression that makes its own external
        // call consumes the prank, and `repay` then arrives as the test contract — which has
        // no position, so it reverts NoPosition and the control never runs.
        uint256 owed = market.debtOf(trader);
        vm.prank(trader);
        market.repay{value: owed}();
        assertGt(market.liquidationHealthOf(trader), WAD, "control: nothing left for the queue to take");

        uint256 withoutQueue = _sell(seller, amount);

        assertLt(withQueue, withoutQueue, "waiting behind a liquidation must cost the seller");
        // Stated as a proportion so the assertion says something about size rather than merely
        // about direction — a one-wei difference would satisfy `assertLt` and mean nothing.
        assertGt(withoutQueue - withQueue, withoutQueue / 1_000, "and the cost is a real one");
    }

    /// The queue is announced, so a trader can be shown why their fill was worse than quoted.
    function test_theQueueIsAnnouncedAgainstTheSwapperWhoTriggeredIt() public {
        _openAndStrand();
        uint256 amount = _fund(seller, 8);

        vm.prank(seller);
        token.approve(address(router), type(uint256).max);
        // Only the topic layout is asserted: the counts and the projected price are outputs of
        // the pool's own arithmetic and pinning them here would make this a change-detector.
        vm.expectEmit(true, true, false, false, address(hook));
        emit LiquidatedAhead(id, address(router), 0, 0, 0);
        vm.prank(seller);
        router.swap(
            LeverageRouter.SwapArgs({
                key: key,
                zeroForOne: false,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: MAX_LIMIT,
                amountBound: 0,
                recipient: seller,
                deadline: type(uint256).max
            })
        );
    }

    /// Nobody is paid for a liquidation nobody performed. The bonus would have made a cascade
    /// something worth causing.
    function test_theQueuePaysNoKeeperBonus() public {
        _openAndStrand();
        uint256 amount = _fund(seller, 8);

        (uint128 collateralBefore,) = market.positions(trader);
        _sell(seller, amount);
        (uint128 collateralAfter,) = market.positions(trader);
        assertLt(collateralAfter, collateralBefore, "setup: the queue must actually have fired");

        assertEq(market.claimable(seller), 0, "the swapper earned nothing");
        assertEq(market.claimable(address(router)), 0, "nor did the route they came through");
        assertEq(market.claimable(address(hook)), 0, "nor the hook");
        assertEq(market.claimable(address(0)), 0, "and no bonus was credited to nobody");
    }

    // ------------------------------------------------------------------ what it must not cost

    /// The property the whole design is built around: a trade cannot MANUFACTURE a liquidation.
    ///
    /// Spot is shoved far below the position's liquidation price inside a single block, with no
    /// time for the average to follow, and then a second sell arrives. The projected price says
    /// the position is under water; the average says it is fine; the average wins, nothing is
    /// taken — and the seller's swap completes regardless, which is the failure isolation this
    /// path lives or dies by.
    function test_aSameBlockPushCannotManufactureALiquidation() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 100 ether}();
        _warmOracle();

        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);
        _warmOracle();

        assertGt(market.liquidationHealthOf(trader), WAD, "setup: the position starts healthy");

        // One block, no warp: the ring records the tick that PREVAILED, so the average cannot
        // follow spot down inside this transaction sequence.
        uint256 push = _fund(arb, 2);
        _sell(arb, push);

        (uint128 collateralBefore,) = market.positions(trader);
        assertGt(market.liquidationHealthOf(trader), WAD, "setup: the average still calls it healthy");
        assertLe(market.healthFactorOf(trader), WAD, "setup: but spot does not - the queue is being tempted");

        uint256 amount = _fund(seller, 8);
        uint256 received = _sell(seller, amount);

        (uint128 collateralAfter,) = market.positions(trader);
        assertEq(collateralAfter, collateralBefore, "a pushed price liquidates nobody");
        assertGt(received, 0, "and the refusal did not cost the seller their swap");
    }

    /// A buy cannot trigger the queue: it lifts the price, and there is nothing below it.
    function test_buysDoNotRunTheQueue() public {
        _openAndStrand();
        (uint128 collateralBefore,) = market.positions(trader);
        _buy(arb, 5 ether);
        (uint128 collateralAfter,) = market.positions(trader);
        assertEq(collateralAfter, collateralBefore, "a buy reaches nobody");
    }

    /// A sell far too small to reach anybody leaves the book alone. The queue is triggered by
    /// crossing a liquidation price, not by the mere existence of a liquidatable position —
    /// otherwise every trade in the pool would be doing a keeper's job on a stranger's gas.
    function test_aSellThatReachesNobodyLeavesTheBookAlone() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 100 ether}();
        _warmOracle();
        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);
        _warmOracle();

        (uint128 collateralBefore,) = market.positions(trader);
        _buy(seller, 1 ether);
        _sell(seller, token.balanceOf(seller));
        (uint128 collateralAfter,) = market.positions(trader);
        assertEq(collateralAfter, collateralBefore, "a healthy book is not disturbed by ordinary flow");
    }

    /// Only the hook may run the queue, and only with a real projection behind it.
    function test_onlyTheHookMayRunTheQueue() public {
        _openAndStrand();
        vm.expectRevert(LeverageMarket.NotHook.selector);
        market.liquidateAhead(trader, WAD);

        vm.prank(address(hook));
        vm.expectRevert(LeverageMarket.NothingToDo.selector);
        market.liquidateAhead(trader, 0);
    }

    /// The market's own sale is a self-call and nothing else may reach it. It moves the
    /// market's tokens into the pool, so an open door here is an open door onto the collateral.
    function test_theInLockSaleIsSelfCallOnly() public {
        vm.expectRevert(LeverageMarket.NotSelf.selector);
        market.sellInLock(1 ether, 0, false);

        vm.prank(address(hook));
        vm.expectRevert(LeverageMarket.NotSelf.selector);
        market.sellInLock(1 ether, 0, false);
    }

    // ------------------------------------------------------------------ the book, read back

    /// The bucket lists and the bucket sums have to describe the same book. They are maintained
    /// by the same branch of `_bookWrite` precisely so they cannot disagree — this walks the
    /// lists the way the hook does and checks the membership against `positions` directly.
    function test_theBucketListsEnumerateExactlyTheBookedPositions() public {
        _warmOracle();
        vm.prank(lp);
        market.deposit{value: 200 ether}();
        _warmOracle();

        address[4] memory traders = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];
        for (uint256 i = 0; i < traders.length; i++) {
            vm.deal(traders[i], 100 ether);
            vm.prank(traders[i]);
            market.openPosition{value: (i + 1) * 1 ether}((15 + i) * WAD / 10, 0);
            // Each open is a buy, and four of them in a row walk spot far enough from the
            // average that the market protects itself and refuses the next one. Letting the
            // ring catch up between opens is the difference between exercising the book and
            // testing the deviation guard.
            _warmOracle();
        }
        assertEq(_walk(), 4, "every open is filed");

        // Churn the book through every path that writes it.
        uint256 half = market.debtOf(traders[0]) / 2;
        vm.prank(traders[0]);
        market.repay{value: half}();
        assertEq(_walk(), 4, "a partial repay keeps the position filed, in its new bucket");

        vm.prank(traders[1]);
        market.addCollateral{value: 1 ether}(0);
        assertEq(_walk(), 4, "so does more collateral");

        vm.prank(traders[2]);
        market.closePosition(0);
        assertEq(_walk(), 3, "a close removes it");

        uint256 whole = market.debtOf(traders[3]);
        vm.prank(traders[3]);
        market.repay{value: whole}();
        assertEq(_walk(), 3, "a full repay leaves a debt-free position filed under nothing");

        assertEq(market.bookedScaled(), market.totalScaledDebt(), "and the sums agree with the ledger");
    }

    /// Walks the book exactly as `LeverageHook._drainQueue` does, and returns how many
    /// positions it found. Asserts as it goes that every listed address is a real position and
    /// that no address is listed twice.
    function _walk() internal view returns (uint256 found) {
        address[] memory seen = new address[](64);
        uint256 om = market.bookOct();
        while (om != 0) {
            uint256 e = LeverageBookLib.msb(om);
            om ^= uint256(1) << e;
            uint256 sm = market.bookSub(e);
            while (sm != 0) {
                uint256 m = LeverageBookLib.msb(sm);
                sm ^= uint256(1) << m;
                address t = market.bucketHead((e << LeverageBookLib.MANT) | m);
                while (t != address(0)) {
                    (, uint128 scaled) = market.positions(t);
                    assertGt(scaled, 0, "a listed position must carry debt");
                    for (uint256 i = 0; i < found; i++) {
                        assertTrue(seen[i] != t, "no position may be listed twice");
                    }
                    seen[found++] = t;
                    t = market.bucketNext(t);
                }
            }
        }
    }

    /// The guard slot is a literal because inline assembly cannot take anything else. This is
    /// the check that keeps it honest.
    function test_queueGuardSlotIsTheDerivedValue() public pure {
        assertEq(
            uint256(keccak256("hookr.leverage.queue.entered")) - 1,
            0xb2f3d58a155e26575a8bb36171afb15191209824eb910b2d1e511daf11ccafb9,
            "LeverageHook.QUEUE_GUARD_SLOT no longer matches its own derivation"
        );
    }

    /// The hook still holds no value, before or after running somebody else's book.
    function test_theHookStillHoldsNothing() public {
        _openAndStrand();
        _sell(seller, _fund(seller, 8));
        assertEq(address(hook).balance, 0, "no quote");
        assertEq(token.balanceOf(address(hook)), 0, "no tokens");
        assertEq(market.balanceOf(address(hook)), 0, "no shares");
    }
}
