// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookrDrawdownBurn} from "../src/HookrDrawdownBurn.sol";
import {DrawdownBurnBase} from "./DrawdownBurnBase.sol";

/// @dev Exposes the engine's internals to the fuzz tests.
contract DrawdownBurnHarness is HookrDrawdownBurn {
    constructor(Config memory c) HookrDrawdownBurn(c) {}

    function ratioTicks(uint256 bps) external pure returns (int24) {
        return _ratioTicks(bps);
    }

    function tierOf(int256 refValue) external view returns (uint8) {
        return _tier(refValue);
    }
}

/// @dev Calls the engine's checkpoint from inside an unlock, where a pump would be free.
contract UnlockPoker is IUnlockCallback {
    IPoolManager internal immutable manager;
    HookrDrawdownBurn internal immutable engine;

    constructor(IPoolManager m, HookrDrawdownBurn e) {
        manager = m;
        engine = e;
    }

    function go() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        engine.checkpoint();
        return "";
    }
}

/// @dev Calls the engine's start from inside an unlock.
contract StartPoker is IUnlockCallback {
    IPoolManager internal immutable manager;
    HookrDrawdownBurn internal immutable engine;

    constructor(IPoolManager m, HookrDrawdownBurn e) {
        manager = m;
        engine = e;
    }

    function go() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        engine.start();
        return "";
    }
}

/// @dev A recipient that refuses every payment.
contract Refuser {
    fallback() external payable {
        revert("no");
    }
}

/// @dev Stands in for a Tax + Conversion advisory and its sell queue: `terms` names the queue, `payCreator` pays the
///      engine what the test credited.
contract MockTaxQueue {
    address internal immutable token;
    address internal immutable recipient;
    uint256 public due;

    constructor(address t, address r) {
        token = t;
        recipient = r;
    }

    function credit(uint256 amount) external {
        due += amount;
    }

    function payCreator() external returns (uint256 amount) {
        amount = due;
        require(amount != 0, "NothingDue");
        due = 0;
        (bool ok,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", recipient, amount));
        require(ok);
    }
}

contract MockTaxAdvisory {
    struct Terms {
        address buyQueue;
        uint24 buyTaxPips;
        bool bound;
        bool tiered;
        bool decaying;
        address sellQueue;
        uint24 sellTaxPips;
    }

    address public sellQueue;

    function set(address q) external {
        sellQueue = q;
    }

    function terms(address, bytes32) external view returns (Terms memory t) {
        t.sellQueue = sellQueue;
        t.bound = true;
        t.sellTaxPips = 33_000;
    }
}

contract HookrDrawdownBurnTest is DrawdownBurnBase {
    function subjectIs0() internal pure virtual override returns (bool) {
        return true;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Construction and bounds
    // ---------------------------------------------------------------------------------------------------------------

    function test_seedsOnInitializedPool() public view {
        assertEq(engine.count(), 1);
        HookrDrawdownBurn.Checkpoint memory cp = engine.checkpointAt(0);
        assertEq(cp.time, T0);
        assertEq(cp.tick, 0);
        assertFalse(cp.thin);
        assertFalse(engine.athSet());
        assertEq(engine.spendable(), 10e18);
    }

    function test_startOnceAfterInit() public {
        vm.expectRevert(HookrDrawdownBurn.AlreadyStarted.selector);
        engine.start();
    }

    function test_startForEngineDeployedBeforeItsPool() public {
        HookrDrawdownBurn.Config memory c = defaults();
        c.key.tickSpacing = 10; // another, not yet initialized pool
        HookrDrawdownBurn early = new HookrDrawdownBurn(c);
        assertEq(early.count(), 0);
        vm.expectRevert(HookrDrawdownBurn.NotStarted.selector);
        early.checkpoint();
        vm.expectRevert(HookrDrawdownBurn.PoolNotInitialized.selector);
        early.start();
        manager.initialize(c.key, TickMath.getSqrtPriceAtTick(120));
        vm.expectRevert(HookrDrawdownBurn.ThinStart.selector);
        early.start();
        liquidityRouter.modifyLiquidity(c.key, ModifyLiquidityParams(-887_270, 887_270, LIQ, 0), "");
        early.start();
        assertEq(early.count(), 1);
        assertEq(early.checkpointAt(0).tick, subjectIs0() ? int24(120) : int24(-120));
    }

    /// @dev Review finding 1: a pump around `start()` used to write the first record unclamped. With the seed tick (the
    ///      opening price) it moves the first record by one clamp step at most.
    function test_pumpAroundStartMovesTheFirstRecordOneStepAtMost() public {
        HookrDrawdownBurn.Config memory c = defaults();
        c.key.tickSpacing = 10;
        c.hasSeedTick = true;
        c.seedTick = 0;
        HookrDrawdownBurn early = new HookrDrawdownBurn(c);
        manager.initialize(c.key, TickMath.getSqrtPriceAtTick(0));
        liquidityRouter.modifyLiquidity(c.key, ModifyLiquidityParams(-887_270, 887_270, LIQ, 0), "");
        // Pump the new pool +20,000 ticks for the subject, start, dump.
        int24 poolTarget = subjectIs0() ? int24(20_000) : int24(-20_000);
        swapRouter.swap(
            c.key,
            SwapParams(!subjectIs0(), -1e30, TickMath.getSqrtPriceAtTick(poolTarget)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        early.start();
        assertEq(early.checkpointAt(0).tick, 500, "clamped to the seed tick + one step");
    }

    function test_startRefusedInsideAnUnlock() public {
        HookrDrawdownBurn.Config memory c = defaults();
        c.key.tickSpacing = 10;
        HookrDrawdownBurn early = new HookrDrawdownBurn(c);
        manager.initialize(c.key, TickMath.getSqrtPriceAtTick(0));
        liquidityRouter.modifyLiquidity(c.key, ModifyLiquidityParams(-887_270, 887_270, LIQ, 0), "");
        StartPoker poker = new StartPoker(manager, early);
        vm.expectRevert(HookrDrawdownBurn.ManagerUnlocked.selector);
        poker.go();
    }

    /// @dev Review finding 2: MARKET_CAP measured its baseline in the constructor, before a launched token exists.
    function test_marketCapEngineDeployedBeforeItsToken() public {
        HookrDrawdownBurn.Config memory c = defaults();
        c.measure = HookrDrawdownBurn.Reference.MARKET_CAP;
        c.key.tickSpacing = 10;
        HookrDrawdownBurn early = new HookrDrawdownBurn(c);
        assertEq(early.circulatingAtStart(), 0);
        manager.initialize(c.key, TickMath.getSqrtPriceAtTick(0));
        liquidityRouter.modifyLiquidity(c.key, ModifyLiquidityParams(-887_270, 887_270, LIQ, 0), "");
        early.start();
        assertEq(early.circulatingAtStart(), subjectToken.totalSupply() - subjectToken.balanceOf(DEAD));
    }

    /// @dev Review note: frozen recipients are paid by `claim`, never inside a run, so one that refuses payment (a native
    ///      transfer that reverts, a blocklisted token recipient) cannot stop the engine.
    function test_refusingCoAuthorDoesNotStopTheEngine() public {
        HookrDrawdownBurn.Config memory c = defaults();
        c.coAuthor = address(new Refuser());
        c.coAuthorBps = 1000;
        engine = new HookrDrawdownBurn(c);
        _withAth0();
        holdAt(-10_000, 30);
        fund(1e18);
        uint256 deadBefore = deadBalance();
        engine.run();
        assertGt(deadBalance(), deadBefore);
        // The run never paid the recipient directly; its share waits for `claim`.
        assertGt(engine.owed(c.coAuthor), 0);
        assertEq(quoteBal(c.coAuthor), 0);
        assertGe(quoteBal(address(engine)), engine.burnBudget() + engine.wallReserve() + engine.totalOwed());
    }

    function test_initialAth() public {
        HookrDrawdownBurn.Config memory c = defaults();
        c.hasInitialAth = true;
        c.initialAth = 4000;
        HookrDrawdownBurn e = new HookrDrawdownBurn(c);
        assertTrue(e.athSet());
        assertEq(e.ath(), 4000);
    }

    function test_rejectsOutOfBounds() public {
        HookrDrawdownBurn.Config memory c;

        c = defaults();
        c.checkpointInterval = 59;
        _expectInvalid(c, "checkpointInterval");
        c = defaults();
        c.maxMoveTicks = 5001;
        _expectInvalid(c, "maxMoveTicks");
        c = defaults();
        c.minLiquidity = 0;
        _expectInvalid(c, "minLiquidity");
        c = defaults();
        c.athWindow = 300 * 49;
        _expectInvalid(c, "athWindow/interval");
        c = defaults();
        c.athMinCheckpoints = 14; // 3600 / 300 = 12 intervals hold at most 13 records
        _expectInvalid(c, "athMinCheckpoints/window");
        c = defaults();
        c.athRiseCapBpsPerHour = 499;
        _expectInvalid(c, "athRiseCap");
        c = defaults();
        c.tierEdgesBps = [uint16(2000), 2000, 6000];
        _expectInvalid(c, "tierEdges");
        c = defaults();
        c.tierEdgesBps = [uint16(2000), 4000, 9600];
        _expectInvalid(c, "tierEdges");
        c = defaults();
        c.tierBurnBps = [uint16(0), 5000, 2500, 7500, 10_000];
        _expectInvalid(c, "tierBurn");
        c = defaults();
        c.spendCap = 0;
        _expectInvalid(c, "spendCap");
        c = defaults();
        c.refillSeconds = 11;
        _expectInvalid(c, "refillSeconds");
        c = defaults();
        c.maxSlippageBps = 1001;
        _expectInvalid(c, "maxSlippage");
        c = defaults();
        c.wallOffsetBps = 9001;
        _expectInvalid(c, "wallOffset");
        c = defaults();
        c.wall = HookrDrawdownBurn.Wall.SINK;
        _expectInvalid(c, "wallSink");
        c = defaults();
        c.tipBps = 51;
        _expectInvalid(c, "tip");
        c = defaults();
        c.checkpointReward = uint128(c.spendCap / 100 + 1);
        _expectInvalid(c, "checkpointReward");
        c = defaults();
        c.coAuthorBps = 100;
        _expectInvalid(c, "coAuthor");
        c = defaults();
        c.coAuthorBps = 2001;
        c.coAuthor = address(1);
        _expectInvalid(c, "coAuthor");
        c = defaults();
        c.excluded = new address[](1);
        _expectInvalid(c, "excluded");
        c = epochDefaults();
        c.deadBandBps = 10; // one record of 500 ticks over 300 s moves a 3600 s mean ~42 ticks; 10 bps is ~10 ticks
        _expectInvalid(c, "deadBand/epochWindow");
        c = epochDefaults();
        c.epochWindow = 0;
        _expectInvalid(c, "epochWindow");
        c = defaults();
        c.netOutSinkBps = 5000;
        c.netOutSink = address(1);
        _expectInvalid(c, "netOutSink");
    }

    function _expectInvalid(HookrDrawdownBurn.Config memory c, bytes32 what) internal {
        vm.expectRevert(abi.encodeWithSelector(HookrDrawdownBurn.InvalidConfig.selector, what));
        new HookrDrawdownBurn(c);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Checkpoints
    // ---------------------------------------------------------------------------------------------------------------

    function test_checkpointRateLimit() public {
        assertFalse(engine.checkpoint());
        vm.warp(T0 + 299);
        assertFalse(engine.checkpoint());
        vm.warp(T0 + 300);
        assertTrue(engine.checkpoint());
        assertFalse(engine.checkpoint());
        assertEq(engine.count(), 2);
    }

    function test_checkpointClampsEachRecord() public {
        moveTo(3000);
        step();
        assertEq(engine.checkpointAt(0).tick, 500);
        step();
        assertEq(engine.checkpointAt(0).tick, 1000);
        moveTo(-3000);
        step();
        assertEq(engine.checkpointAt(0).tick, 500);
    }

    function test_checkpointRefusedInsideUnlock() public {
        UnlockPoker poker = new UnlockPoker(manager, engine);
        vm.warp(T0 + 300);
        vm.expectRevert(HookrDrawdownBurn.ManagerUnlocked.selector);
        poker.go();
    }

    function test_thinRecordWhenLiquidityUnderFloor() public {
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, -(LIQ - 1e17), 0), "");
        step();
        assertTrue(engine.checkpointAt(0).thin);
        // A mean that weighs the thin record fails closed.
        vm.warp(vm.getBlockTimestamp() + 1);
        (bool ok,) = engine.meanTick(600);
        assertFalse(ok);
    }

    function test_checkpointReward() public {
        HookrDrawdownBurn.Config memory c = defaults();
        c.checkpointReward = 0.01e18;
        engine = new HookrDrawdownBurn(c);
        fund(1e18);
        address keeper = makeAddr("keeper");
        vm.warp(T0 + 300);
        vm.prank(keeper);
        assertTrue(engine.checkpoint());
        assertEq(quoteBal(keeper), 0.01e18);
        // No record, no reward.
        vm.prank(keeper);
        assertFalse(engine.checkpoint());
        assertEq(quoteBal(keeper), 0.01e18);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Means
    // ---------------------------------------------------------------------------------------------------------------

    function test_meanIsTimeWeightedAndNewestWeighsNothing() public {
        vm.warp(T0 + 300);
        moveTo(400);
        engine.checkpoint();
        // Just written: the 400 record has stood for 0 s.
        (bool ok, int24 m) = engine.meanTick(300);
        assertTrue(ok);
        assertEq(m, 0);
        vm.warp(T0 + 600);
        (ok, m) = engine.meanTick(600);
        assertTrue(ok);
        assertEq(m, 200);
        (ok, m) = engine.meanTick(300);
        assertEq(m, 400);
        // The ring does not reach back 900 s.
        (ok,) = engine.meanTick(900);
        assertFalse(ok);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The all-time high
    // ---------------------------------------------------------------------------------------------------------------

    function test_athFirstSetAfterAFullWindow() public {
        steps(11);
        assertFalse(engine.athSet());
        steps(1);
        assertTrue(engine.athSet());
        assertEq(engine.ath(), 0);
    }

    function test_athRatchetsToTheLevelHeldAllHour() public {
        steps(12);
        assertEq(engine.ath(), 0);
        holdAt(2000, 12);
        assertEq(engine.ath(), 0, "not yet a full hour above");
        holdAt(2000, 1);
        assertEq(engine.ath(), 500, "lowest record of the hour");
        holdAt(2000, 3);
        assertEq(engine.ath(), 2000);
        // It never goes down.
        holdAt(-5000, 20);
        assertEq(engine.ath(), 2000);
    }

    function test_athRiseCap() public {
        HookrDrawdownBurn.Config memory c = defaults();
        c.athRiseCapBpsPerHour = 500;
        c.hasInitialAth = true;
        c.initialAth = 0;
        engine = new HookrDrawdownBurn(c);
        int24 capTicks = 487; // tick of 1.05
        holdAt(5000, 40);
        uint256 elapsed = vm.getBlockTimestamp() - T0;
        assertGt(engine.ath(), 0);
        assertLe(int256(engine.ath()), int256(capTicks) * int256(elapsed) / 3600 + 1);
        assertLt(engine.ath(), 5000);
    }

    function test_thinRecordBlocksRatchet() public {
        steps(12);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, -(LIQ - 1e17), 0), "");
        holdAt(2000, 20);
        assertEq(engine.ath(), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Tiers and spending
    // ---------------------------------------------------------------------------------------------------------------

    function _withAth0() internal {
        steps(12);
        assertEq(engine.ath(), 0);
    }

    function _tierAt(int24 level) internal returns (uint8 tier) {
        holdAt(level, 30);
        bool ok;
        (ok,,, tier) = engine.drawdown();
        assertTrue(ok);
    }

    function test_tiersFollowIkasEdges() public {
        _withAth0();
        assertEq(_tierAt(0), 0);
        assertEq(_tierAt(-1000), 1); // ~9.5% under
        assertEq(_tierAt(-3000), 2); // ~26% under
        assertEq(_tierAt(-6000), 3); // ~45% under
        assertEq(_tierAt(-10_000), 4); // ~63% under
        (,, uint256 ddBps,) = engine.drawdown();
        assertApproxEqAbs(ddBps, 6321, 2);
    }

    function test_runSplitsByTierAndBurns() public {
        _withAth0();
        holdAt(-3000, 9);
        fund(4e18);
        uint256 deadBefore = deadBalance();
        engine.run();
        assertEq(engine.burnBudget(), 0, "burn share spent");
        assertEq(engine.wallReserve(), 2e18, "wall share held");
        assertGt(deadBalance() - deadBefore, 2e18, "bought under price 1 and burned");
        assertEq(quoteBal(address(engine)), 2e18);
        assertEq(subjectToken.balanceOf(address(engine)), 0, "never holds the subject");
        assertEq(engine.spendable(), 8e18);
    }

    function test_runSkipsWithoutAth() public {
        fund(1e18);
        steps(3);
        engine.run();
        assertEq(engine.burnBudget(), 0);
        assertEq(engine.unallocated(), 1e18);
    }

    function test_spendCapRefills() public {
        _withAth0();
        holdAt(-10_000, 30);
        fund(100e18);
        engine.run();
        assertEq(engine.burnBudget(), 90e18);
        engine.run();
        assertEq(engine.burnBudget(), 90e18, "bucket empty in the same second");
        vm.warp(vm.getBlockTimestamp() + 6);
        engine.run();
        assertEq(engine.burnBudget(), 85e18, "half refilled after half the period");
    }

    function test_buybackNeverPaysAboveReferencePlusSlippage() public {
        _withAth0();
        holdAt(-3000, 9);
        fund(4e18);
        // Pump in the same transaction, after the last record: the reference stays at -3000.
        moveTo(-2500);
        uint256 deadBefore = deadBalance();
        engine.run();
        assertEq(deadBalance(), deadBefore, "spot above -3000 + 296: no buy");
        assertEq(engine.burnBudget(), 2e18);
        // Back under the limit, it buys, and stops at the limit.
        moveTo(-2800);
        engine.run();
        assertLt(engine.burnBudget(), 2e18);
        assertLe(spot(), -3000 + 296);
    }

    function test_wallBuysOnlyUnderTheWallAndBurns() public {
        _withAth0();
        holdAt(-3000, 9);
        fund(4e18);
        engine.run();
        assertEq(engine.wallReserve(), 2e18);
        // Above the wall (60% under the high, tick -9163): nothing.
        holdAt(-8000, 12);
        engine.run();
        assertEq(engine.wallReserve(), 2e18);
        // Through the wall: it buys up to the wall price and burns what it bought.
        holdAt(-9600, 12);
        uint256 deadBefore = deadBalance();
        engine.run();
        assertEq(engine.wallReserve(), 0);
        assertGt(deadBalance(), deadBefore);
        assertLe(spot(), -9163);
    }

    function test_wallSinkPaysTheSink() public {
        HookrDrawdownBurn.Config memory c = defaults();
        address sink = makeAddr("floorBid");
        c.wall = HookrDrawdownBurn.Wall.SINK;
        c.wallSink = sink;
        engine = new HookrDrawdownBurn(c);
        _withAth0();
        holdAt(-3000, 9);
        fund(4e18);
        engine.run();
        assertEq(engine.owed(sink), 2e18);
        engine.claim(sink);
        assertEq(quoteBal(sink), 2e18);
        assertEq(engine.totalOwed(), 0);
        assertEq(engine.wallReserve(), 0);
    }

    function test_tipAndCoAuthorComeOutOfTheSpend() public {
        HookrDrawdownBurn.Config memory c = defaults();
        c.tipBps = 50;
        c.coAuthor = makeAddr("ika");
        c.coAuthorBps = 1000;
        engine = new HookrDrawdownBurn(c);
        _withAth0();
        holdAt(-10_000, 30);
        fund(1.1e18);
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        engine.run();
        // 1.1e18 at 100% burn: swapIn = 1.1e18 / 1.105, tip 0.5% and co-author 10% of it.
        uint256 swapIn = uint256(1.1e18) * 10_000 / 11_050;
        assertEq(quoteBal(keeper), swapIn * 50 / 10_000);
        assertEq(engine.owed(c.coAuthor), swapIn * 1000 / 10_000);
        engine.claim(c.coAuthor);
        assertEq(quoteBal(c.coAuthor), swapIn * 1000 / 10_000);
        assertLe(quoteBal(address(engine)), 2);
    }

    function test_collectsFromTheTaxQueue() public {
        MockTaxAdvisory advisory = new MockTaxAdvisory();
        HookrDrawdownBurn.Config memory c = defaults();
        c.taxAdvisory = address(advisory);
        engine = new HookrDrawdownBurn(c);
        MockTaxQueue queue = new MockTaxQueue(address(quoteToken), address(engine));
        advisory.set(address(queue));
        quoteToken.mint(address(queue), 3e18);
        queue.credit(3e18);
        _withAth0();
        holdAt(-1000, 9);
        engine.run();
        assertEq(queue.due(), 0);
        // Tier 1: 25% burned, 75% to the wall.
        assertEq(engine.wallReserve(), 2.25e18);
        // Nothing due: the queue reverts, the run goes on.
        engine.run();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Flow epochs
    // ---------------------------------------------------------------------------------------------------------------

    function test_epochAccumulatesOnNetInAndSpendsOnNetOut() public {
        HookrDrawdownBurn.Config memory c = epochDefaults();
        c.hasInitialAth = true;
        c.initialAth = 5000;
        engine = new HookrDrawdownBurn(c);
        uint256 boundary = (T0 / 4 hours + 1) * 4 hours;

        holdAt(1000, 4);
        while (vm.getBlockTimestamp() < boundary) step();
        assertEq(uint8(engine.mode()), uint8(HookrDrawdownBurn.Mode.ACCUMULATE), "price up: net quote in");

        fund(4e18);
        engine.run();
        assertEq(engine.burnBudget(), 2e18, "held while accumulating");

        holdAt(0, 4);
        while (vm.getBlockTimestamp() < boundary + 4 hours) step();
        assertEq(uint8(engine.mode()), uint8(HookrDrawdownBurn.Mode.SPEND), "price down: net quote out");
        uint256 deadBefore = deadBalance();
        engine.run();
        assertEq(engine.burnBudget(), 0);
        assertGt(deadBalance(), deadBefore);
    }

    function test_epochNetOutSink() public {
        HookrDrawdownBurn.Config memory c = epochDefaults();
        c.hasInitialAth = true;
        c.initialAth = 5000;
        address lp = makeAddr("lpAdder");
        c.netOutSink = lp;
        c.netOutSinkBps = 5000;
        engine = new HookrDrawdownBurn(c);
        steps(4);
        fund(4e18);
        engine.run();
        // SPEND from the start: 2e18 burn budget, half to the net-out sink, half bought back.
        assertEq(engine.owed(lp), 1e18);
        engine.claim(lp);
        assertEq(quoteBal(lp), 1e18);
        assertEq(engine.burnBudget(), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Market cap reference
    // ---------------------------------------------------------------------------------------------------------------

    function test_marketCapDeepensAsSupplyBurns() public {
        HookrDrawdownBurn.Config memory c = defaults();
        c.measure = HookrDrawdownBurn.Reference.MARKET_CAP;
        c.excluded = new address[](1);
        c.excluded[0] = address(this); // the test holds the uncirculating supply
        subjectToken.mint(makeAddr("holders"), 1_000_000e18);
        engine = new HookrDrawdownBurn(c);
        _withAth0();
        (,, uint256 before,) = engine.drawdown();
        assertEq(before, 0);
        // Burn 10% of circulating (holders plus what the pool holds) at a flat price: the market cap is 10% under its
        // high.
        uint256 tenth = engine.circulatingAtStart() / 10;
        vm.prank(makeAddr("holders"));
        subjectToken.transfer(DEAD, tenth);
        (bool ok,, uint256 dd, uint8 tier) = engine.drawdown();
        assertTrue(ok);
        assertApproxEqAbs(dd, 1000, 2);
        assertEq(tier, 1);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------------------------

    function testFuzz_ratioTicksMonotone(uint256 a, uint256 b) public {
        DrawdownBurnHarness h = new DrawdownBurnHarness(defaults());
        a = bound(a, 1, 1_000_000);
        b = bound(b, 1, 1_000_000);
        if (a > b) (a, b) = (b, a);
        assertLe(h.ratioTicks(a), h.ratioTicks(b));
        // Within one tick of the exact log.
        int24 t = h.ratioTicks(a);
        uint256 lo = uint256(TickMath.getSqrtPriceAtTick(t));
        uint256 hi = uint256(TickMath.getSqrtPriceAtTick(t + 1));
        uint256 target = _sqrtQ96(a);
        assertLe(lo, target + 1);
        assertGe(hi + 1, target);
    }

    function testFuzz_tierNeverFallsAsDrawdownDeepens(int256 a, int256 b) public {
        HookrDrawdownBurn.Config memory c = defaults();
        c.hasInitialAth = true;
        c.initialAth = 0;
        DrawdownBurnHarness h = new DrawdownBurnHarness(c);
        a = bound(a, -30_000, 30_000);
        b = bound(b, -30_000, 30_000);
        if (a > b) (a, b) = (b, a);
        // a is lower (deeper), so its tier is at least b's.
        assertGe(h.tierOf(a), h.tierOf(b));
    }

    function testFuzz_recordsMoveAtMostMaxMove(int24[8] memory targets) public {
        int24 prev = engine.checkpointAt(0).tick;
        for (uint256 i; i < targets.length; ++i) {
            int24 t = int24(bound(targets[i], -40_000, 40_000));
            vm.warp(vm.getBlockTimestamp() + 300);
            moveTo(t);
            engine.checkpoint();
            int24 rec = engine.checkpointAt(0).tick;
            int256 d = int256(rec) - int256(prev);
            assertLe(d < 0 ? -d : d, 500);
            prev = rec;
        }
    }

    function testFuzz_spendNeverExceedsTheBucket(uint96 amount, uint16 wait) public {
        _withAth0();
        holdAt(-10_000, 30);
        amount = uint96(bound(amount, 1, 1e24));
        fund(amount);
        engine.run();
        vm.warp(vm.getBlockTimestamp() + bound(wait, 0, 120));
        uint256 before = quoteBal(address(engine));
        uint256 can = engine.spendable();
        engine.run();
        assertLe(before - quoteBal(address(engine)), can);
    }

    function _sqrtQ96(uint256 bps) internal pure returns (uint256) {
        uint256 x = (bps << 192) / 10_000;
        uint256 z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
        return z;
    }
}

/// @dev The same suite with the subject as currency1, where the subject's price falls as the pool's tick rises.
contract HookrDrawdownBurnFlippedTest is HookrDrawdownBurnTest {
    function subjectIs0() internal pure override returns (bool) {
        return false;
    }
}
