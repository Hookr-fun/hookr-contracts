// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {Actor} from "./mocks/Actors.sol";
import {ArbSysKit} from "../kit/ArbSysMock.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";

/// @notice Two independent operations in one transaction, each with its own gas limit, as an ERC-4337 EntryPoint
///         runs the user operations of a bundle.
contract Bundle {
    HookrRouter internal immutable router;

    constructor(HookrRouter r) {
        router = r;
    }

    function op(IHookrRouter.Swap calldata p, uint256 value) external {
        require(msg.sender == address(this));
        router.swap{value: value}(p, address(0), new uint256[](0));
    }

    function one(IHookrRouter.Swap calldata p, uint256 value, uint256 g) external returns (bool ok) {
        try this.op{gas: g}(p, value) {
            ok = true;
        } catch {}
    }

    function two(IHookrRouter.Swap calldata p1, IHookrRouter.Swap calldata p2, uint256 value, uint256 g)
        external
        returns (bool ok1, bool ok2, bytes memory err2)
    {
        try this.op{gas: g}(p1, value) {
            ok1 = true;
        } catch {}
        try this.op{gas: g}(p2, value) {
            ok2 = true;
        } catch (bytes memory e) {
            err2 = e;
        }
    }

    receive() external payable {}
}

/// @notice A smart account whose one operation is a route in its own unlock: a swap on a pool without a lane, then a
///         lane swap, so the lane swap follows open PoolManager deltas of its own unlock. Unauthenticated, so the root's
///         payer for it is the account itself. Native ETH in on both pools.
contract RouteAccount is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function execute(PoolKey calldata plain, PoolKey calldata lane) external {
        manager.unlock(abi.encode(plain, lane));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory plain, PoolKey memory lane) = abi.decode(data, (PoolKey, PoolKey));
        manager.swap(plain, SwapParams(true, -1e15, TickMath.MIN_SQRT_PRICE + 1), "");
        manager.swap(lane, SwapParams(true, -1e17, TickMath.MIN_SQRT_PRICE + 1), "");
        _close(plain.currency0);
        _close(plain.currency1);
        _close(lane.currency1);
        return "";
    }

    function _close(Currency c) internal {
        int256 d = manager.currencyDelta(address(this), c);
        if (d > 0) manager.take(c, address(this), uint256(d));
        else if (d < 0) manager.settle{value: uint256(-d)}();
    }

    receive() external payable {}
}

/// @notice Runs the operations of one bundle as an ERC-4337 EntryPoint does: each account's operation with its own
///         gas limit, a failed one not failing the others.
contract EntryPointLike {
    function run(RouteAccount a, PoolKey calldata plain, PoolKey calldata lane, uint256 g) public returns (bool ok) {
        try a.execute{gas: g}(plain, lane) {
            ok = true;
        } catch {}
    }

    function bundle(
        RouteAccount a1,
        uint256 g1,
        RouteAccount a2,
        uint256 g2,
        PoolKey calldata plain,
        PoolKey calldata lane1,
        PoolKey calldata lane2
    ) external returns (bool ok1, bool ok2) {
        ok1 = run(a1, plain, lane1, g1);
        ok2 = run(a2, plain, lane2, g2);
    }
}

/// @notice The p2 attack round (push currency, settlement set, deferred LP donation, multi-lane gas): the one-block
///         capture of the donation, independent lane swaps in one transaction, the push currency, and a liquidity
///         change estimated in an arb recapture's block.
contract LpShareReleaseTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for *;

    ScriptedExecutor internal exec;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e28);
        exec.setRoot(address(root));
        tokenA.transfer(address(exec), 1e27);
    }

    function _tickRange(PoolKey memory k) internal view returns (int24 lo, int24 hi) {
        (, int24 tick,,) = manager.getSlot0(k.toId());
        lo = tick >= 0 ? (tick / 60) * 60 : ((tick - 59) / 60) * 60;
        hi = lo + 60;
    }

    function _donated(Vm.Log[] memory logs) internal pure returns (uint256 donated) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IHookrRecaptureEvents.LpShareDonated.selector) {
                (uint256 a0, uint256 a1) = abi.decode(logs[i].data, (uint256, uint256));
                donated += a0 + a1;
            }
        }
    }

    function _lanePool(uint32 releaseBlocks) internal returns (PoolKey memory k) {
        HookrTypes.RecaptureConfig memory rc = _recaptureOnlyRc();
        rc.releaseBlocks = releaseBlocks;
        (k,) = _openPoolWithFamily(ETH, _laneRules(false), rc);
    }

    // ─────────────────────────────────────────── A1: one-block JIT on the donation

    /// The A1 PoC at release period `n`: in L2 block B a buy's arb recaptures leave an LP share pending; still in B the
    /// attacker adds ten times the launch position's liquidity on one tick spacing at the price; `hold` L2 blocks
    /// later (whole parent blocks when `hold` is a multiple of 120, else inside the same parent block) its dust adds
    /// flush and it leaves. Returns the pending share, what that block donated and the attacker's ETH gain.
    function _oneBlockJit(uint32 n)
        internal
        returns (uint256 pending, uint256 donated, uint256 gain, PoolKey memory k)
    {
        return _jit(n, ArbSysKit.L2_PER_PARENT);
    }

    function _jit(uint32 n, uint256 hold)
        internal
        returns (uint256 pending, uint256 donated, uint256 gain, PoolKey memory k)
    {
        _openLane(address(exec));
        k = _lanePool(n);
        _nextBlock();
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        _buy(k, ETH, whale, 1e20);
        (,, uint256 f0, uint256 f1,) = _recap().pendingDonation(k.toId());
        pending = f0 + f1;
        assertGt(pending, 0, "pending LP share");
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        Actor atk = _newActor(k);
        (int24 lo, int24 hi) = _tickRange(k);
        uint256 e0 = address(atk).balance;
        atk.modify(k, lo, hi, 1e25);
        uint256 inEth = e0 - address(atk).balance;
        if (hold % ArbSysKit.L2_PER_PARENT == 0) ArbSysKit.nextParent(vm, hold / ArbSysKit.L2_PER_PARENT);
        else _stepL2(hold);
        vm.recordLogs();
        atk.modify(k, -6000, 6000, 1);
        atk.modify(k, -6000, 6000, 1);
        atk.modify(k, -6000, 6000, 1);
        uint256 e2 = address(atk).balance;
        atk.modify(k, lo, hi, -1e25);
        donated = _donated(vm.getRecordedLogs());
        uint256 outEth = address(atk).balance - e2;
        gain = outEth > inEth ? outEth - inEth : 0;
    }

    /// A1 (regression of test_poc_A1_oneBlockTightRangeTakesTheDonation). A pending LP share is released over the
    /// pool's release period of N L2 blocks: liquidity added right after the arb recapture and held across one parent
    /// block (120 L2 blocks, 12 seconds), however tight and however many flushes and removals it triggers in that
    /// block, takes its pro-rata part of 120/N of the share. At the default period (36,000 L2 blocks, about an hour)
    /// that is under 0.34% of it; before the fix it took 9,090 bps. The rest keeps going to what is in range later.
    function test_regression_aTightRangeHeldAcrossOneBlockTakesAtMostOneNthOfTheDonation() public {
        uint32 n = _recap().DEFAULT_RELEASE_BLOCKS();
        uint256 per = ArbSysKit.L2_PER_PARENT;
        (uint256 pending, uint256 donated, uint256 gain, PoolKey memory k) = _oneBlockJit(n);
        console2.log("release blocks, pending share, donated in the attacker's block", n, pending, donated);
        console2.log("attacker gain (wei ETH), bps of the pending share", gain, gain * 10_000 / pending);
        assertEq(donated, _releasedAfter(pending, per, n), "one parent block of release: 120/N, once in the block");
        assertLe(gain * n, pending * per + n, "one parent block takes at most 120/N of the share");
        // A full period later the rest is released at once to what is in range then.
        (uint256 d0, uint256 d1,,,) = _recap().pendingDonation(k.toId());
        assertEq(d0 + d1, pending - donated, "the rest stays pending");
        ArbSysKit.nextParent(vm, n / per);
        vm.recordLogs();
        _newActor(k).modify(k, -6000, 6000, 1);
        assertEq(_donated(vm.getRecordedLogs()), pending - donated, "the rest, released whole after a full period");
    }

    /// A1 at the least release period the creator can set (1,200 L2 blocks, about 2 minutes): the one-parent-block
    /// capture is at most a tenth.
    function test_regression_atTheLeastReleasePeriodOneBlockTakesAtMostATenth() public {
        uint32 n = _recap().MIN_RELEASE_BLOCKS();
        uint256 per = ArbSysKit.L2_PER_PARENT;
        (uint256 pending, uint256 donated, uint256 gain,) = _oneBlockJit(n);
        console2.log("release blocks, attacker gain bps", n, gain * 10_000 / pending);
        assertEq(donated, _releasedAfter(pending, per, n));
        assertLe(gain * n, pending * per + n, "at most 120/N");
    }

    /// The same PoC with the position held one L2 block (about 100 ms) inside one parent block: the release clock is
    /// Robinhood Chain's own block number, so the hold is worth at most 1/N of the share, 1/36,000 at the default
    /// period (about 0.28 bps against the 9,090 bps the unreleased donation gave), plus one raw unit of rounding.
    function test_clock_oneL2BlockHoldTakesAtMostOneNth() public {
        uint32 n = _recap().DEFAULT_RELEASE_BLOCKS();
        uint256 b0 = vm.getBlockNumber();
        (uint256 pending, uint256 donated, uint256 gain,) = _jit(n, 1);
        assertEq(vm.getBlockNumber(), b0 + 1, "the only parent step is the fixture's launch-to-buy one");
        console2.log(
            "one L2 block: donated, gain (wei), gain in millionths of the share", donated, gain, gain * 1e6 / pending
        );
        assertEq(donated, _releasedAfter(pending, 1, n), "one L2 block of release");
        assertLe(gain * n, pending + n, "one L2 block takes at most 1/N of the share");
    }

    /// A position is paid in proportion to the blocks it stayed in range: a removal flushes before it lands, so a
    /// position that held from before the arb recapture and leaves k blocks later is paid its part of k/N of the share
    /// in that removal, with the liquidity in range beside it. The zero-in-range fallback is unchanged: what a flush
    /// releases while nothing is in range is the liquidity owner's accrual (FullExitLpLeg).
    function test_aRemovalFlushesThePartReleasedSoFar() public {
        _openLane(address(exec));
        PoolKey memory k = _lanePool(RELEASE);
        Actor lp = _newActor(k);
        lp.modify(k, -60_000, 60_000, 1e24);
        _nextBlock();
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        _buy(k, ETH, whale, 1e20);
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        (,, uint256 f0, uint256 f1,) = _recap().pendingDonation(k.toId());
        uint256 pending = f0 + f1;
        // Four parent blocks: 480 L2 blocks.
        ArbSysKit.nextParent(vm, 4);
        uint256 part = _releasedAfter(pending, 4 * ArbSysKit.L2_PER_PARENT, RELEASE);
        vm.recordLogs();
        lp.modify(k, -60_000, 60_000, -1e24);
        assertEq(_donated(vm.getRecordedLogs()), part, "the removal flushed 480/N first");
        (uint256 d0, uint256 d1,,,) = _recap().pendingDonation(k.toId());
        assertEq(d0 + d1, pending - part, "the rest pending");
        // A second flush in the same block releases nothing.
        vm.recordLogs();
        _newActor(k).modify(k, -6000, 6000, 1);
        assertEq(_donated(vm.getRecordedLogs()), 0, "nothing more in the block");
    }

    // ─────────────────────────────────────────── A2: independent lane swaps in one transaction

    function _leastRoute(EntryPointLike ep, RouteAccount a, PoolKey memory plain, PoolKey memory lane)
        internal
        returns (uint256 hi)
    {
        uint256 lo = 100_000;
        hi = 30_000_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            if (ep.run(a, plain, lane, mid)) hi = mid;
            else lo = mid;
            vm.revertToState(snap);
        }
    }

    /// A2 (regression of test_poc_A2_aSecondIndependentLaneSwapInOneTransactionIsRefused). The operations of two
    /// accounts in one bundle, each with its own gas limit and each a route whose lane swap follows open deltas of its
    /// own unlock: the second is checked against its own gas, as its own route, even with less gas than the first
    /// had. Before the fix the second was refused InsufficientLaneGas whenever the first operation's limit did not
    /// fund both.
    function test_regression_independentOperationsOfTwoAccountsInOneBundleAreNeverRefused() public {
        _openLane(address(exec), 3_000_000);
        PoolKey memory k1 = _openRecapture(ETH);
        PoolKey memory k2 = _openRecapture(ETH);
        PoolKey memory plain = _openStd(ETH);
        _nextBlock();
        EntryPointLike ep = new EntryPointLike();
        RouteAccount a1 = new RouteAccount(manager);
        RouteAccount a2 = new RouteAccount(manager);
        vm.deal(address(a1), 1e22);
        vm.deal(address(a2), 1e22);
        uint256 least = _leastRoute(ep, a2, plain, k2);
        uint256 g = least * 130 / 100;
        console2.log("route op least limit alone, +30%", least, g);
        (bool ok1, bool ok2) = ep.bundle(a1, g * 3 / 2, a2, g, plain, k1, k2);
        assertTrue(ok1, "the first op");
        assertTrue(ok2, "the second op, with less gas than the first, at its own limit");
        (ok1, ok2) = ep.bundle(a1, g, a2, g, plain, k1, k2);
        assertTrue(ok1 && ok2, "both at the same limit");
    }

    /// A2, the original PoC shape: two lane swaps through the router in one transaction, each op with the limit that
    /// funds it alone (+30%). Each is the first swap of its own unlock, so each starts its own route.
    function test_regression_aSecondIndependentLaneSwapInOneTransactionPasses() public {
        _openLane(address(exec), 3_000_000);
        PoolKey memory k1 = _openRecapture(ETH);
        PoolKey memory k2 = _openRecapture(ETH);
        _nextBlock();
        Bundle b = new Bundle(router);
        vm.deal(address(b), 1e22);
        IHookrRouter.Swap memory p1 = _swapParams(k1, ETH, true, true, 1e17, address(b));
        IHookrRouter.Swap memory p2 = _swapParams(k2, ETH, true, true, 1e17, address(b));
        uint256 lo = 100_000;
        uint256 hi = 30_000_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            if (b.one(p2, 1e17, mid)) hi = mid;
            else lo = mid;
            vm.revertToState(snap);
        }
        uint256 g = hi * 130 / 100;
        console2.log("op least limit alone, limit given to each op (+30%)", hi, g);
        (bool ok1, bool ok2,) = b.two(p1, p2, 1e17, g);
        assertTrue(ok1, "the first op of the bundle succeeds");
        assertTrue(ok2, "the second op of the same bundle succeeds at its own limit");
    }

    /// A2, the known limit (pinned): two operations of ONE payer in one transaction, the later one's lane swap behind
    /// open deltas of its own unlock with no more gas than the earlier one's had, share the check. Operations of
    /// different payers never do (above); with more gas, or as the first swap of its unlock, the later one starts its
    /// own route.
    function test_pinned_twoOperationsOfOnePayerBehindOpenDeltasShareTheCheck() public {
        _openLane(address(exec), 3_000_000);
        PoolKey memory k1 = _openRecapture(ETH);
        PoolKey memory k2 = _openRecapture(ETH);
        PoolKey memory plain = _openStd(ETH);
        _nextBlock();
        EntryPointLike ep = new EntryPointLike();
        RouteAccount a = new RouteAccount(manager);
        vm.deal(address(a), 1e22);
        uint256 least = _leastRoute(ep, a, plain, k2);
        uint256 g = least * 130 / 100;
        uint256 snap = vm.snapshotState();
        (bool ok1, bool ok2) = ep.bundle(a, g, a, g * 3 / 2, plain, k1, k2);
        assertTrue(ok1 && ok2, "with more gas the later op starts its own route");
        vm.revertToState(snap);
        // The later op spends less before its check (warm storage), so it gets a little less gas than the first.
        (ok1, ok2) = ep.bundle(a, g, a, g - 200_000, plain, k1, k2);
        assertTrue(ok1, "the first op");
        assertFalse(ok2, "known limit: one payer, behind open deltas, no more gas: the shared check refuses it");
    }

    // ─────────────────────────────────────────── A3: the push currency is the executor's choice

    /// A3 (design, pinned; the release's executor guide). The executor picks the push currency. On an ETH-quoted
    /// King of the Pool pool the same arb recapture pushed in the quote fills the pot and is donated to in-range LPs;
    /// pushed in a settlement-set member that is not a pool currency (tokenA here, WETH or USDG at genesis), the pot
    /// and the trader leg get nothing (quote units only) and the whole remainder is the liquidity owner's accrual in
    /// that currency. The executor pushes in the quote whenever its route allows; settlement currencies are its
    /// fallback.
    function test_pinned_aSettlementSetPushPaysNoPotOrTraderLegAndItsLpShareToTheOwner() public {
        _openLane(address(exec));
        _settlementCurrency(address(tokenA));
        (PoolKey memory k,) = _openPoolWithFamily(ETH, _laneRules(true), _kothRc());
        _nextBlock();
        uint256 snap = vm.snapshotState();
        exec.set(ScriptedExecutor.Mode.PUSH, 7.5e18);
        (,,, uint128 pot0) = _hill(k);
        _buy(k, ETH, whale, 1e20);
        (,,, uint128 pot1) = _hill(k);
        (,, uint256 f0, uint256 f1,) = _recap().pendingDonation(k.toId());
        // Each phase: 7.5e18 pushed, standing for 1e19 at the pinned 25%; the protocol's 2.5e18 (25% of it) first, 40%
        // of the 5e18 left to the pot, the rest (no trader leg: this executor undoes nothing of the buy) to in-range
        // LPs.
        assertEq(pot1 - pot0, 4e18, "quote push: pot");
        assertEq(f0 + f1, 6e18, "quote push: pending donation to in-range LPs");
        vm.revertToState(snap);
        exec.setPushCurrency(Currency.wrap(address(tokenA)));
        exec.set(ScriptedExecutor.Mode.PUSH, 7.5e18);
        _buy(k, ETH, whale, 1e20);
        (,,, uint128 pot2) = _hill(k);
        (,, f0, f1,) = _recap().pendingDonation(k.toId());
        uint256 owner = _recap().poolAccrued(k.toId(), Currency.wrap(address(tokenA)));
        assertEq(pot2, pot0, "settlement push: no pot");
        assertEq(f0 + f1, 0, "settlement push: nothing for in-range LPs");
        uint256 pro = _cut(_profitOf(7.5e18), 7.5e18);
        assertEq(owner, 2 * (7.5e18 - pro), "settlement push: everything after the protocol cut to the owner");
        assertEq(owner, 10e18);
    }

    // ─────────────────────────────────────────── A4: a liquidity change estimated in the arb recapture's block

    function addAt(Actor lp, PoolKey calldata k, int256 liquidity, uint256 g) external {
        require(msg.sender == address(this));
        lp.modify{gas: g}(k, -600, 600, liquidity);
    }

    function _least(Actor lp, PoolKey memory k, int256 liquidity) internal returns (uint256 hi) {
        uint256 lo = 50_000;
        hi = 5_000_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            try this.addAt(lp, k, liquidity, mid) {
                hi = mid;
            } catch {
                lo = mid;
            }
            vm.revertToState(snap);
        }
    }

    /// A4 (regression of test_poc_A4_anAddEstimatedInTheCorrectionsBlockRevertsWhenMinedLater). The flush's gas
    /// requirement holds on every add, removal and outer swap of a lane pool, whether a share is due or not, so an add
    /// or a removal estimated in the block of an arb recapture (nothing due yet) is funded when mined in a later block
    /// with the flush due. Before the fix the add reverted there even with a 30% margin (247,588 vs 362,395).
    function test_regression_anAddEstimatedInTheArbRecapturesBlockPassesWhenMinedLater() public {
        _openLane(address(exec));
        PoolKey memory k = _openRecapture(ETH);
        _nextBlock();
        Actor lp = _newActor(k);
        lp.modify(k, -600, 600, 1e18);
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        _buy(k, ETH, whale, 1e20);
        uint256 estAdd = _least(lp, k, 1e18);
        uint256 estRemove = _least(lp, k, -1e18);
        _nextBlock();
        uint256 snap = vm.snapshotState();
        uint256 minedAdd = _least(lp, k, 1e18);
        uint256 minedRemove = _least(lp, k, -1e18);
        vm.revertToState(snap);
        console2.log("add least limit in the push's block, in the next block", estAdd, minedAdd);
        console2.log("removal least limit in the push's block, in the next block", estRemove, minedRemove);
        assertLe(minedAdd, estAdd * 110 / 100, "the add's estimate covers the mined add");
        assertLe(minedRemove, estRemove * 110 / 100, "the removal's estimate covers the mined removal");
        snap = vm.snapshotState();
        vm.recordLogs();
        this.addAt(lp, k, 1e18, estAdd * 110 / 100);
        assertGt(_donated(vm.getRecordedLogs()), 0, "the add flushed the released share");
        vm.revertToState(snap);
        vm.recordLogs();
        this.addAt(lp, k, -1e18, estRemove * 110 / 100);
        assertGt(_donated(vm.getRecordedLogs()), 0, "the removal flushed the released share");
    }
}
