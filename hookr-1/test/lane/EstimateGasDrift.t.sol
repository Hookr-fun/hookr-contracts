// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRoot} from "../../src/interfaces/IHookrRoot.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {PartnerShapedFixture} from "./utils/PartnerShapedFixture.sol";
import {LaneRootFixture} from "./utils/LaneRootFixture.sol";
import {Actor} from "./mocks/Actors.sol";
import {IHookrLaneEvents} from "../../src/interfaces/IHookrLaneEvents.sol";

/// @notice ATK-EX-1 regression (estimateGas and the floor). Routers send what `eth_estimateGas` returns for a lane swap:
///         the least gas that succeeds in the state it was taken in. Before the fix the after-phase checked its floor
///         after the before-phase had spent whatever the state at inclusion made it spend (up to the cap), so a swap
///         estimated while the pool was aligned reverted InsufficientLaneGas once an outside move landed before
///         inclusion. The before-phase now requires the whole entry floor (its own floor, its whole grant, LANE_BODY
///         and the after-phase floor), so the estimate no longer depends on what the before-phase will do.
contract EstimateGasDriftTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;

    HookrToken internal subject;
    PoolKey internal a;
    PoolKey internal b;
    PoolKey internal refA;
    PoolKey internal refB;
    PoolKey internal conn;

    function setUp() public {
        _setUpPartnerShaped();
        subject = _newSubject();
        subject.approve(address(venue), type(uint256).max);
        Currency qb = Currency.wrap(address(tokenB));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _laneMemberAt(ETH);
        members[1] = _laneMemberAt(qb);
        (, PoolKey[] memory keys) = _launch(subject, members);
        (a, b) = (keys[0], keys[1]);
        refA = _hookless(a.currency0, a.currency1);
        refB = _hookless(b.currency0, b.currency1);
        conn = _hookless(ETH, qb);
        ex.setTrigger(a, 1e22);
        ex.addVenue(a, refA, PAIR_GAP);
        ex.addCycle(a, b, conn, CYCLE_GAP);
        ex.setTrigger(b, 1e22);
        ex.addVenue(b, refB, PAIR_GAP);
        ex.addCycle(b, a, conn, CYCLE_GAP);
        _nextBlock();
    }

    function sellWithGasOn(PoolKey memory key, address who, uint256 amount, uint256 g) external {
        require(msg.sender == address(this));
        IHookrRouter.Swap memory p = _swapParams(key, ETH, false, true, amount, who);
        vm.prank(who);
        router.swap{gas: g}(p, address(0), new uint256[](0));
    }

    /// @dev The least gas limit (to 1,000) at which the whale's 1e18 sell on A succeeds in the current state: what a
    ///      binary-searching eth_estimateGas returns.
    function _estimate() internal returns (uint256 hi) {
        uint256 lo = 100_000;
        hi = 12_000_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            try this.sellWithGasOn(a, whale, 1e18, mid) {
                hi = mid;
            } catch {
                lo = mid;
            }
            vm.revertToState(snap);
        }
    }

    /// @dev Runs the sell at `g` in the current state (then rolls back): 0 success, 1 InsufficientLaneGas, 2 other.
    function _tryAt(uint256 g) internal returns (uint256 result) {
        uint256 snap = vm.snapshotState();
        try this.sellWithGasOn(a, whale, 1e18, g) {
            result = 0;
        } catch (bytes memory err) {
            result = _contains(err, IHookrLaneEvents.InsufficientLaneGas.selector) ? 1 : 2;
        }
        vm.revertToState(snap);
    }

    function _contains(bytes memory data, bytes4 sel) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i; i + 4 <= data.length; ++i) {
            if (data[i] == sel[0] && data[i + 1] == sel[1] && data[i + 2] == sel[2] && data[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }

    /// Outside moves of 0.6% to 20% (the kind a popular token's other pools see every block) between the estimate and
    /// inclusion make the before-phase arb recapture; the swap sent at the quiet estimate still succeeds, and the
    /// estimate taken after the move is the quiet one.
    function test_regression_quietEstimateSucceedsAfterAnOutsideMove() public {
        (,,,,, uint32 cap, uint256 floor) = IHookrLaneRoot(address(root)).laneOf(a.toId());
        uint256 quiet = _estimate();
        console2.log("cap, entry floor, quiet estimate", cap, floor, quiet);
        assertEq(_tryAt(quiet), 0, "the quiet estimate succeeds in the quiet state");
        assertGt(quiet, floor, "the estimate carries the entry floor");

        uint256[5] memory moves = [uint256(3e21), 5e21, 1e22, 3e22, 1e23];
        for (uint256 m; m < moves.length; ++m) {
            uint256 snap = vm.snapshotState();
            // Someone buys the subject on the outside venue (the subject is currency1 there, so zeroForOne).
            venue.swap{value: moves[m]}(refA, true, moves[m], 0);
            uint256 gap = _gapBps(_px(a, Currency.wrap(address(subject))), _px(refA, Currency.wrap(address(subject))));
            uint256 moved = _estimate();
            console2.log("outside buy (ETH), gap bps, estimate now", moves[m], gap, moved);
            assertEq(_tryAt(quiet), 0, "the quiet estimate succeeds after the move");
            assertLe(moved, quiet, "the estimate after the move is no higher than the quiet one");
            vm.revertToState(snap);
        }
        // The same move with the partner-shaped executor also having a family cycle to run: still funded.
        venue.swap{value: 3e22}(refA, true, 3e22, 0);
        venue.swap(conn, false, 3e22, 0);
        assertEq(_tryAt(quiet), 0, "an outside and a family gap together: still funded");
        vm.recordLogs();
        this.sellWithGasOn(a, whale, 1e18, quiet);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2, "both arb recaptures ran at the quiet estimate");
        assertGt(o.pushedBefore, 0, "the before-phase recaptured");
    }
}

/// @notice An executor that is idle whenever tx.gasprice is zero (how eth_estimateGas and eth_call run by default) and
///         spends its whole grant in the before-phase otherwise, then fails open. It never breaks a frame check.
contract EstimateAwareExecutor {
    address public immutable root;
    bool public before = true;
    uint256 public seenGasPrice;

    constructor(address _root) {
        root = _root;
    }

    function executeArbitrage(PoolKey calldata, address) external returns (uint256) {
        require(msg.sender == root, "root");
        bool isBefore = before;
        before = !isBefore;
        seenGasPrice = tx.gasprice;
        if (tx.gasprice == 0 || !isBefore) return 0;
        uint256 i;
        while (gasleft() > 60_000) {
            unchecked {
                ++i;
            }
        }
        return 0;
    }
}

/// @notice ATK-EX-1 regression (a hostile executor and the estimate): the executor can tell an estimate from inclusion.
///         Before the fix every swap a wallet estimated reverted InsufficientLaneGas when mined; now the estimate
///         already funds the whole before-phase grant, so the mined swap succeeds at the estimated limit.
contract EstimateAwareExecutorTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;

    EstimateAwareExecutor internal ea;
    PoolKey internal key;

    function setUp() public {
        _setUpLane();
        ea = new EstimateAwareExecutor(address(root));
        _openLane(address(ea), 3_000_000);
        (, key) = _one(_newSubject(), true, false, 0);
        _nextBlock();
    }

    uint256 internal gp;

    /// @dev One swap at gas limit `g` and the test's gas price: zero is how eth_estimateGas runs by default.
    function sellAt(uint256 g) external {
        require(msg.sender == address(this));
        vm.txGasPrice(gp);
        _sellWithGas(key, whale, 1e18, g);
    }

    function _least() internal returns (uint256 hi) {
        uint256 lo = 100_000;
        hi = 12_000_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            try this.sellAt(mid) {
                hi = mid;
            } catch {
                lo = mid;
            }
            vm.revertToState(snap);
        }
    }

    function test_regression_executorIdleUnderEstimate_theEstimateStillFundsInclusion() public {
        gp = 0;
        uint256 est = _least();
        gp = 1 gwei;
        uint256 real = _least();
        uint256 snap = vm.snapshotState();
        this.sellAt(8_000_000);
        console2.log("tx.gasprice seen by the executor", ea.seenGasPrice());
        vm.revertToState(snap);
        console2.log("least gas: as estimated (gasprice 0), as mined (gasprice 1 gwei)", est, real);
        assertEq(real, est, "the executor's behaviour no longer moves the least succeeding limit");
        // Sent at the estimate, the mined swap succeeds and both frames record their outcome.
        vm.recordLogs();
        this.sellAt(est);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2, "the burning before-phase and the idle after-phase both returned");
        assertEq(o.failed, 0);
    }
}

/// @notice LANE_BODY sizing: the entry floor funds the swap's own work between the lane calls. With an executor that
///         burns its whole grant and then pushes (the most the before-phase can spend, split included), the least
///         succeeding limit equals the idle one on plain, every-rule King of the Pool, dynamic fee and guarded pools,
///         buys and sells. A swap crossing many initialized ticks on a dynamic fee pool (its simulation crosses them
///         too) can need more than LANE_BODY: pinned as the documented limit.
contract LaneBodyAllowanceTest is LaneRootFixture {
    BurnThenPushExecutor internal bx;

    function setUp() public {
        _setUpLane();
        bx = new BurnThenPushExecutor(manager, address(root));
        vm.deal(address(bx), 1e27);
        _openLane(address(bx), 3_000_000);
    }

    function swapAt(PoolKey memory key, bool buy, uint256 amount, uint256 g) external {
        require(msg.sender == address(this));
        IHookrRouter.Swap memory p = _swapParams(key, ETH, buy, true, amount, whale);
        vm.prank(whale);
        router.swap{gas: g, value: buy ? amount : 0}(p, address(0), new uint256[](0));
    }

    function _least(PoolKey memory key, bool buy, uint256 amount) internal returns (uint256 hi) {
        uint256 lo = 100_000;
        hi = 20_000_000;
        while (hi - lo > 500) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            try this.swapAt(key, buy, amount, mid) {
                hi = mid;
            } catch {
                lo = mid;
            }
            vm.revertToState(snap);
        }
    }

    /// @dev The least limit with the executor idle (the estimate) minus the least with it burning and pushing in the
    ///      before-phase or in both phases.
    function _margin(string memory what, PoolKey memory key, bool buy, uint256 amount) internal returns (int256 m) {
        bx.setMode(0);
        uint256 idle = _least(key, buy, amount);
        bx.setMode(1);
        uint256 w1 = _least(key, buy, amount);
        bx.setMode(2);
        uint256 w2 = _least(key, buy, amount);
        bx.setMode(0);
        m = int256(idle) - int256(w1 > w2 ? w1 : w2);
        console2.log(what);
        console2.log("  least: idle, burning before, burning both", idle, w1, w2);
    }

    function test_regression_theEstimateFundsTheWorstExecutorOnEveryPoolShape() public {
        (, PoolKey memory plain) = _one(_newSubject(), true, false, 0);
        IHookrLauncher.Member[] memory m = new IHookrLauncher.Member[](1);
        m[0] = _member(ETH, true, false, 400);
        m[0].rules.burnBps = 100;
        m[0].rules.royaltyBps = 500;
        m[0].rules.royaltyTo = royalty;
        m[0].rules.potBps = POT_BPS;
        m[0].recapture = _kothRc();
        (, PoolKey[] memory k) = _launch(_newSubject(), m);
        PoolKey memory koth = k[0];
        m[0] = _member(ETH, true, false, 400);
        m[0].rules.maxFeePips = 50_000;
        m[0].rules.dynamicFeeSens = 5;
        m[0].rules.burnBps = 100;
        (, k) = _launch(_newSubject(), m);
        PoolKey memory dyn = k[0];
        m[0] = _member(ETH, true, true, 400);
        (, k) = _launch(_newSubject(), m);
        PoolKey memory guarded = k[0];
        _nextBlock();
        assertEq(_margin("plain buy", plain, true, 1e21), 0, "plain buy");
        assertEq(_margin("plain sell", plain, false, 1e21), 0, "plain sell");
        assertEq(_margin("every rule, King of the Pool, buy", koth, true, 1e21), 0, "koth buy");
        assertEq(_margin("every rule, King of the Pool, sell", koth, false, 1e21), 0, "koth sell");
        assertEq(_margin("dynamic fee buy", dyn, true, 1e21), 0, "dynamic buy");
        assertEq(_margin("dynamic fee sell", dyn, false, 1e21), 0, "dynamic sell");
        assertEq(_margin("guarded buy", guarded, true, 1e21), 0, "guarded buy");
    }

    /// @dev The least `edge` (to 1,000) at which the mixed executor's frames still return, both currencies landing in
    ///      both phases: from there on the frame leaves just the EXTRA_PUSH_GAS the second split needs.
    function _edge(PoolKey memory key, bool buy, uint256 amount) internal returns (uint256 hi) {
        uint256 lo = 50_000;
        hi = 900_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            bx.setMixed(bx.second(), mid);
            uint256 snap = vm.snapshotState();
            vm.recordLogs();
            this.swapAt(key, buy, amount, 20_000_000);
            Outcome memory o = _outcome(vm.getRecordedLogs());
            vm.revertToState(snap);
            if (o.succeeded == 4) hi = mid;
            else lo = mid;
        }
    }

    /// @dev The least limit with the executor idle minus the least with the mixed executor at its edge.
    function _mixedMargin(string memory what, PoolKey memory key, bool buy, uint256 amount)
        internal
        returns (int256 m)
    {
        bx.setMode(0);
        uint256 idle = _least(key, buy, amount);
        bx.setMode(3);
        uint256 e = _edge(key, buy, amount);
        bx.setMixed(bx.second(), e);
        uint256 worst = _least(key, buy, amount);
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        this.swapAt(key, buy, amount, worst);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        vm.revertToState(snap);
        assertEq(o.succeeded, 4, "at its least limit the mixed swap lands both currencies in both phases");
        bx.setMode(0);
        m = int256(idle) - int256(worst);
        console2.log(what);
        console2.log("  least: idle, mixed at its edge; edge", idle, worst, e);
    }

    /// The worst executor that pushes in two currencies: in both phases it burns its grant down to the least that lets
    /// its frame return (EXTRA_PUSH_GAS left for the second split) and pushes 1e15 in the quote and in tokenB. The
    /// least succeeding limit is still the idle one, on plain and every-rule King of the Pool pools, buys and sells:
    /// the second split is paid from the grant the executor left.
    function test_regression_theEstimateFundsTheWorstMixedExecutor() public {
        _settlementCurrency(address(tokenB));
        tokenB.transfer(address(bx), 1e24);
        bx.setMixed(Currency.wrap(address(tokenB)), 0);
        (, PoolKey memory plain) = _one(_newSubject(), true, false, 0);
        IHookrLauncher.Member[] memory m = new IHookrLauncher.Member[](1);
        m[0] = _member(ETH, true, false, 400);
        m[0].rules.burnBps = 100;
        m[0].rules.royaltyBps = 500;
        m[0].rules.royaltyTo = royalty;
        m[0].rules.potBps = POT_BPS;
        m[0].recapture = _kothRc();
        (, PoolKey[] memory k) = _launch(_newSubject(), m);
        _nextBlock();
        assertEq(_mixedMargin("mixed, plain buy", plain, true, 1e21), 0, "plain buy");
        assertEq(_mixedMargin("mixed, plain sell", plain, false, 1e21), 0, "plain sell");
        assertEq(_mixedMargin("mixed, King of the Pool buy", k[0], true, 1e21), 0, "koth buy");
        assertEq(_mixedMargin("mixed, King of the Pool sell", k[0], false, 1e21), 0, "koth sell");
    }

    /// The root asks the executor's MEV view (`checkV3PoolsMev(address,address,address,bool)`) with
    /// at most 200,000 gas right after the before-phase call, inside the swap's own work between the lane calls
    /// (LANE_BODY). An executor whose view burns all of it, on top of burning its whole grant and pushing in both
    /// phases, needs no more gas than an idle one on every pool shape.
    function test_regression_aMevViewBurningItsGasKeepsTheEstimate() public {
        (, PoolKey memory plain) = _one(_newSubject(), true, false, 0);
        IHookrLauncher.Member[] memory m = new IHookrLauncher.Member[](1);
        m[0] = _member(ETH, true, false, 400);
        m[0].rules.burnBps = 100;
        m[0].rules.royaltyBps = 500;
        m[0].rules.royaltyTo = royalty;
        m[0].rules.potBps = POT_BPS;
        m[0].recapture = _kothRc();
        (, PoolKey[] memory k) = _launch(_newSubject(), m);
        PoolKey memory koth = k[0];
        m[0] = _member(ETH, true, false, 400);
        m[0].rules.maxFeePips = 50_000;
        m[0].rules.dynamicFeeSens = 5;
        m[0].rules.burnBps = 100;
        (, k) = _launch(_newSubject(), m);
        PoolKey memory dyn = k[0];
        m[0] = _member(ETH, true, true, 400);
        (, k) = _launch(_newSubject(), m);
        PoolKey memory guarded = k[0];
        _nextBlock();
        PoolKey[4] memory keys = [plain, koth, dyn, guarded];
        uint256[8] memory idle;
        bx.setMode(0);
        bx.setMevBurn(false);
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j; j < 2; ++j) {
                if (i == 3 && j == 1) continue;
                idle[2 * i + j] = _least(keys[i], j == 0, 1e21);
            }
        }
        // Registered after every idle run, so only the burning runs can meet it.
        vm.expectCall(address(bx), abi.encodePacked(bytes4(0x9e97c424)));
        bx.setMode(2);
        bx.setMevBurn(true);
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j; j < 2; ++j) {
                if (i == 3 && j == 1) continue;
                uint256 worst = _least(keys[i], j == 0, 1e21);
                console2.log("  least: idle, burning grant and MEV view", idle[2 * i + j], worst);
                assertEq(worst, idle[2 * i + j], "the MEV view's gas is inside the entry floor");
            }
        }
        bx.setMode(0);
        bx.setMevBurn(false);
    }

    /// Pinned limit: 30 initialized ticks on each side of a dynamic fee pool and a swap across all of them (the
    /// simulation crosses them as well) take more than LANE_BODY between the lane calls, so there the estimate
    /// depends on the executor again, by the excess.
    function test_pinned_aSwapAcrossThirtyTicksOfADynamicFeePoolExceedsTheBody() public {
        IHookrLauncher.Member[] memory m = new IHookrLauncher.Member[](1);
        m[0] = _member(ETH, true, false, 400);
        m[0].rules.maxFeePips = 50_000;
        m[0].rules.dynamicFeeSens = 5;
        m[0].rules.burnBps = 100;
        (, PoolKey[] memory k) = _launch(_newSubject(), m);
        Actor lp = _newActor(k[0]);
        for (int24 i = 1; i <= 30; ++i) {
            lp.modify(k[0], -60 * i, 60 * i, int256(1e21));
        }
        _nextBlock();
        int256 buy = _margin("dynamic fee, 30 ticks each side, 5e22 buy", k[0], true, 5e22);
        int256 sell = _margin("dynamic fee, 30 ticks each side, 5e22 sell", k[0], false, 5e22);
        console2.log("  excess over the estimate, buy and sell");
        console2.logInt(-buy);
        console2.logInt(-sell);
        assertLt(buy, 0);
        assertLt(sell, 0);
        assertGt(buy, -500_000, "the excess stays below 500,000 gas");
        assertGt(sell, -500_000, "the excess stays below 500,000 gas");
    }
}

/// @notice Burns its grant down to 140,000 gas and then pushes 1e15 quote: the most a successful before-phase can
///         spend, the split included. Mode 0 idle, 1 in the before-phase only, 2 in both phases; mode 3, in both
///         phases, burns down to `edge` and pushes 1e15 quote and 1e15 of `second`.
contract BurnThenPushExecutor {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable manager;
    address public immutable root;
    uint256 public mode;
    Currency public second;
    uint256 public edge;

    constructor(IPoolManager m, address r) {
        manager = m;
        root = r;
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    function setMixed(Currency c, uint256 e) external {
        (second, edge) = (c, e);
    }

    /// @notice When set, the MEV view the root asks on every outer lane swap runs out of the 200,000 gas it gets.
    bool public mevBurn;

    function setMevBurn(bool on) external {
        mevBurn = on;
    }

    function checkV3PoolsMev(address, address, address, bool) external view returns (bool) {
        if (mevBurn) {
            uint256 i;
            while (true) {
                unchecked {
                    ++i;
                }
            }
        }
        return false;
    }

    function executeArbitrage(PoolKey calldata key, address trader) external returns (uint256) {
        require(msg.sender == root, "root");
        uint256 m = mode;
        if (m == 0 || (m == 1 && trader != address(0))) return 0;
        uint256 stop = m == 3 ? edge : 140_000;
        while (gasleft() > stop) {}
        HookrTypes.PoolConfig memory pc = IHookrRoot(root).poolConfig(key.toId());
        uint256 a = 1e15;
        _push(key, pc.quote, a);
        if (m == 3) _push(key, second, a);
        return a;
    }

    function _push(PoolKey calldata key, Currency c, uint256 a) internal {
        if (c.isAddressZero()) {
            manager.settle{value: a}();
        } else {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(manager), a);
            manager.settle();
        }
        manager.mint(root, c.toId(), a);
        IHookrLaneRoot(root).settleRecapture(key, c, a);
    }

    receive() external payable {}
}
