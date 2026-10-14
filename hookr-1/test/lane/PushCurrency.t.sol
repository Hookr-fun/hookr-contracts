// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {Actor} from "./mocks/Actors.sol";
import {ArbSysKit} from "../kit/ArbSysMock.sol";
import {IHookrLaneEvents} from "../../src/interfaces/IHookrLaneEvents.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice Mints PoolManager claims of native ETH to any account outside a swap: a stray mint to the root.
contract ClaimMinter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function mintTo(address to, uint256 amount) external payable {
        manager.unlock(abi.encode(to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        manager.settle{value: amount}();
        manager.mint(to, 0, amount);
        return "";
    }
}

/// @notice The push currency: an executor pushes in the currency it made the profit in, the pool's quote or subject
///         or a member of the registry's settlement set, one or several per frame, and nothing it mints to the root
///         strands there. The Rules split every currency's push in its currency; only a quote push pays the trader leg
///         and the pot.
contract MoneyPushCurrencyTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// @dev The registry's genesis WETH and USDG on Robinhood Chain (4663).
    address internal constant WETH_4663 = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG_4663 = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    ScriptedExecutor internal exec;
    PoolKey internal b;
    bytes32 internal familyB;
    PoolKey internal k;
    bytes32 internal familyK;
    Currency internal tb;
    Currency internal ta;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e28);
        exec.setRoot(address(root));
        _openLane(address(exec));
        tb = Currency.wrap(address(tokenB));
        ta = Currency.wrap(address(tokenA));
        (b, familyB) = _openPoolWithFamily(tb, _laneRules(false), _recaptureOnlyRc());
        (k, familyK) = _openPoolWithFamily(ETH, _laneRules(true), _kothRc());
        tokenA.transfer(address(exec), 1e27);
        tokenB.transfer(address(exec), 1e27);
        IERC20(Currency.unwrap(_subjectOf(b))).transfer(address(exec), 1e26);
        IERC20(Currency.unwrap(_subjectOf(k))).transfer(address(exec), 1e26);
        _nextBlock();
    }

    function _reason(Vm.Log[] memory logs) internal view returns (bytes4) {
        return _outcome(logs).lastReason;
    }

    // ---------------------------------------------------------------- currencies

    /// An ETH push on a tokenB-quoted pool: the protocol takes its cut in ETH first; ETH is not one of the pool's
    /// currencies, so the trader's share joins the LP share and all of it is the liquidity owner's accrual in ETH.
    function test_anEthPushOnATokenQuotedPoolSplitsInEth() public {
        exec.setPushCurrency(ETH);
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        uint256 protocolBefore = rules.claimable(ETH, protocol);
        vm.recordLogs();
        _buy(b, tb, whale, 1e20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        assertEq(o.succeeded, 2, "both phases pushed");
        uint256 pro = _cut(_profitOf(9e18), 9e18);
        assertEq(rules.claimable(ETH, protocol) - protocolBefore, 2 * pro, "the protocol cut in ETH");
        assertEq(_recap().poolAccrued(b.toId(), ETH), 2 * (9e18 - pro), "the rest to the owner's ETH accrual");
        assertEq(rules.claimable(tb, whale), 0, "no trader leg outside the quote");
        assertEq(rules.claimable(ETH, whale), 0);
        Currency[] memory accrued = _recap().poolAccruedCurrencies(b.toId());
        assertEq(accrued.length, 1);
        assertTrue(accrued[0] == ETH);
        assertEq(manager.balanceOf(address(root), ETH.toId()), 0, "nothing at the root");
        assertTrue(rules.accountingInvariant(ETH));
        // The owner moves it with claimRecapture, in its currency.
        vm.prank(creator);
        assertEq(launcher.claimRecapture(familyB, 0, creator), 1);
        uint256 before = creator.balance;
        vm.prank(creator);
        rules.claim(ETH);
        assertEq(creator.balance - before, 2 * (9e18 - pro));
    }

    /// A push in the pool's subject: no pot and no trader leg (both quote units), the LP share pending in the subject,
    /// donated to the in-range liquidity from the next block.
    function test_aSubjectPushIsDonatedInTheSubject() public {
        Currency s = _subjectOf(k);
        exec.setPushCurrency(s);
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        (,,, uint128 pot0) = _hill(k);
        _buy(k, ETH, whale, 1e20);
        (,,, uint128 pot1) = _hill(k);
        assertEq(pot1, pot0, "no pot from a subject push");
        uint256 pro = _cut(_profitOf(9e18), 9e18);
        assertEq(rules.claimable(s, protocol), 2 * pro);
        assertEq(rules.claimable(s, whale), 0);
        (uint256 d0, uint256 d1, uint256 f0, uint256 f1,) = _recap().pendingDonation(k.toId());
        bool subjectIs0 = k.currency0 == s;
        assertEq(subjectIs0 ? f0 : f1, 2 * (9e18 - pro), "pending in the subject");
        assertEq(d0 + d1 + (subjectIs0 ? f1 : f0), 0);
        vm.prank(creator);
        launcher.withdraw(familyK, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        _nextBlock();
        _newActor(k).modify(k, 800_040, 800_100, 1e18);
        _flushAll(k);
        uint256 before = IERC20(Currency.unwrap(s)).balanceOf(creator);
        vm.prank(creator);
        launcher.withdraw(familyK, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        assertApproxEqAbs(
            IERC20(Currency.unwrap(s)).balanceOf(creator) - before, 2 * (9e18 - pro), 2, "donated in the subject"
        );
        assertTrue(rules.accountingInvariant(s));
    }

    /// A quote push on a King of the Pool pool keeps the trader leg and the pot.
    function test_aQuotePushKeepsTheTraderLegAndThePot() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        (,,, uint128 pot0) = _hill(k);
        vm.recordLogs();
        _buy(k, ETH, whale, 1e20);
        Splits memory t = _splits(vm.getRecordedLogs());
        (,,, uint128 pot1) = _hill(k);
        assertEq(uint256(pot1 - pot0), t.pot);
        assertGt(t.pot, 0, "the pot fills");
        assertEq(t.count, 2);
    }

    /// A currency that is neither the pool's nor in the settlement set is refused: the push reverts SinkClosed, the
    /// frame unwinds with the mint, and the swap completes.
    function test_aCurrencyOutsideTheSetIsRefused() public {
        exec.setPushCurrency(ta);
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        vm.recordLogs();
        _buy(b, tb, whale, 1e20);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 0);
        assertEq(o.failed, 2, "both phases failed open");
        assertEq(o.lastReason, IHookrLaneEvents.SinkClosed.selector);
        assertEq(manager.balanceOf(address(root), ta.toId()), 0, "the mint unwound with the frame");
    }

    /// The settlement set grows through the timelock and a brake takes a member out at once.
    function test_aSettlementCurrencyIsAddedByTimelockAndRemovedByBrake() public {
        _settlementCurrency(address(tokenA));
        exec.setPushCurrency(ta);
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        vm.recordLogs();
        _buy(b, tb, whale, 1e20);
        assertEq(_outcome(vm.getRecordedLogs()).succeeded, 2, "accepted once in the set");
        assertGt(_recap().poolAccrued(b.toId(), ta), 0);
        registry.removeSettlementCurrency(address(tokenA));
        _nextBlock();
        vm.recordLogs();
        _buy(b, tb, whale, 1e20);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 0, "refused at once after the brake");
        assertEq(o.lastReason, IHookrLaneEvents.SinkClosed.selector);
    }

    // ---------------------------------------------------------------- nothing strands at the root

    /// A claim minted to the root and not pushed reverts the frame: the arb recapture fails, the swap goes on, and the
    /// root holds nothing. In the quote and in a settlement currency.
    function test_aStrayMintRevertsTheArbRecapture() public {
        exec.set(ScriptedExecutor.Mode.STRAY_MINT, 1e18);
        vm.recordLogs();
        _buy(b, tb, whale, 1e20);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 0);
        assertEq(o.failed, 2);
        assertEq(o.lastReason, IHookrLaneEvents.LaneStrayClaims.selector);
        assertEq(manager.balanceOf(address(root), tb.toId()), 0);
        exec.setPushCurrency(ETH);
        _nextBlock();
        vm.recordLogs();
        _buy(b, tb, whale, 1e20);
        assertEq(_reason(vm.getRecordedLogs()), IHookrLaneEvents.LaneStrayClaims.selector);
        assertEq(manager.balanceOf(address(root), ETH.toId()), 0);
    }

    /// A frame may push in several currencies: a quote push and an ETH push in each phase, each split on its own in
    /// its currency, the profit of each read from it at the pinned rate, and nothing left at the root.
    function test_aMixedCurrencyFrameSplitsEachCurrency() public {
        exec.setPushCurrency(ETH);
        exec.set(ScriptedExecutor.Mode.MIXED, 1e18);
        uint256 pEth = rules.claimable(ETH, protocol);
        uint256 pTb = rules.claimable(tb, protocol);
        vm.recordLogs();
        _buy(b, tb, whale, 1e20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        assertEq(o.failed, 0);
        assertEq(o.succeeded, 4, "two currencies in each phase");
        assertEq(o.profitBefore, 2 * _profitOf(1e18), "one profit per currency, each read from its push");
        assertEq(_splits(logs).count, 4);
        uint256 pro = _cut(_profitOf(1e18), 1e18);
        assertEq(rules.claimable(ETH, protocol) - pEth, 2 * pro, "the protocol's cut in ETH");
        assertEq(rules.claimable(tb, protocol) - pTb, 2 * pro, "and in the quote");
        assertEq(manager.balanceOf(address(root), ETH.toId()), 0);
        assertEq(manager.balanceOf(address(root), tb.toId()), 0);
        assertTrue(rules.accountingInvariant(ETH));
        assertTrue(rules.accountingInvariant(tb));
    }

    /// A frame that pushed in two currencies returns only with EXTRA_PUSH_GAS (200,000) left for the second split.
    /// An executor that leaves less fails the frame with LaneOutOfGas: both pushes unwind with it, nothing stays at the
    /// root and the swap completes. Leaving 200,000, both currencies land in both phases.
    function test_aMixedFrameShortOfTheSecondSplitsGasFailsOpen() public {
        exec.setPushCurrency(ETH);
        exec.set(ScriptedExecutor.Mode.MIXED, 1e18);
        exec.setLeaveGas(100_000);
        vm.recordLogs();
        uint256 out = _buy(b, tb, whale, 1e20);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertGt(out, 0, "the swap completed");
        assertEq(o.succeeded, 0);
        assertEq(o.failed, 2);
        assertEq(o.lastReason, IHookrLaneEvents.LaneOutOfGas.selector);
        assertEq(manager.balanceOf(address(root), ETH.toId()), 0);
        assertEq(manager.balanceOf(address(root), tb.toId()), 0);
        assertTrue(rules.accountingInvariant(ETH));
        assertTrue(rules.accountingInvariant(tb));
        exec.setLeaveGas(200_000);
        _nextBlock();
        vm.recordLogs();
        _buy(b, tb, whale, 1e20);
        o = _outcome(vm.getRecordedLogs());
        assertEq(o.failed, 0);
        assertEq(o.succeeded, 4, "left 200,000: both currencies land in both phases");
    }

    /// The sweep is refused inside a swap (here from the executor's frame, whose push still lands) and moves claims
    /// minted to the root outside a swap to the protocol recipient's Rules claim.
    function test_theSweepInsideAndOutsideASwap() public {
        exec.set(ScriptedExecutor.Mode.SWEEP_INSIDE, 1e18);
        vm.recordLogs();
        _buy(b, tb, whale, 1e20);
        assertEq(_outcome(vm.getRecordedLogs()).succeeded, 2, "the push after the refused sweep lands");
        assertEq(bytes4(exec.lastSweepError()), IHookrRootEvents.ReentrantCallback.selector, "refused inside the frame");
        ClaimMinter minter = new ClaimMinter(manager);
        minter.mintTo{value: 5e18}(address(root), 5e18);
        assertEq(manager.balanceOf(address(root), ETH.toId()), 5e18, "a stray mint outside any swap");
        uint256 before = rules.claimable(ETH, protocol);
        vm.prank(attacker);
        assertEq(IHookrLaneRoot(address(root)).sweepClaims(b.toId(), ETH), 5e18, "anyone sweeps");
        assertEq(manager.balanceOf(address(root), ETH.toId()), 0);
        assertEq(rules.claimable(ETH, protocol) - before, 5e18, "to the protocol recipient");
        assertTrue(rules.accountingInvariant(ETH));
        assertEq(IHookrLaneRoot(address(root)).sweepClaims(b.toId(), ETH), 0, "nothing left");
        PoolKey memory plain = _openStd(ETH);
        vm.expectRevert(IHookrRootEvents.InvalidPool.selector);
        IHookrLaneRoot(address(root)).sweepClaims(plain.toId(), ETH);
    }

    // ---------------------------------------------------------------- the registry's set

    function test_theSettlementSetIsTimelockedBoundedAndBraked() public {
        // Native ETH at genesis, then WETH and USDG where they hold code (on a Robinhood Chain fork).
        address[] memory set = registry.settlementCurrencies();
        uint256 genesis = 1 + (WETH_4663.code.length != 0 ? 1 : 0) + (USDG_4663.code.length != 0 ? 1 : 0);
        assertEq(set.length, genesis, "native ETH, and WETH and USDG where they hold code");
        assertEq(set[0], address(0));
        assertEq(registry.isSettlementCurrency(WETH_4663), WETH_4663.code.length != 0);
        assertEq(registry.isSettlementCurrency(USDG_4663), USDG_4663.code.length != 0);
        assertTrue(registry.isSettlementCurrency(address(0)));
        registry.queue(ADD_SETTLEMENT, abi.encode(address(tokenA)));
        vm.expectRevert();
        registry.addSettlementCurrency(address(tokenA));
        vm.prank(attacker);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.removeSettlementCurrency(address(0));
        // A removal before execution refuses the addition queued ahead of it.
        registry.removeSettlementCurrency(address(tokenA));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert();
        registry.addSettlementCurrency(address(tokenA));
        registry.cancel(registry.operationHash(ADD_SETTLEMENT, abi.encode(address(tokenA))));
        _nextBlock();
        _settlementCurrency(address(tokenA));
        assertTrue(registry.isSettlementCurrency(address(tokenA)));
        vm.expectRevert(IHookrRegistry.InvalidLane.selector);
        registry.queue(ADD_SETTLEMENT, abi.encode(address(tokenA)));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, address(0xbeef)));
        registry.queue(ADD_SETTLEMENT, abi.encode(address(0xbeef)));
        // At most 8 members.
        for (uint256 n = registry.settlementCurrencies().length; n < 8; ++n) {
            _settlementCurrency(address(new HookrToken("X", "X", 1, address(this))));
        }
        assertEq(registry.settlementCurrencies().length, 8);
        address ninth = address(new HookrToken("X", "X", 1, address(this)));
        vm.expectRevert(IHookrRegistry.InvalidLane.selector);
        registry.queue(ADD_SETTLEMENT, abi.encode(ninth));
        registry.removeSettlementCurrency(address(0));
        assertFalse(registry.isSettlementCurrency(address(0)));
        assertEq(registry.settlementCurrencies().length, 7);
    }

    // ---------------------------------------------------------------- JIT-safe donation (M-02, M-03, F-014)

    /// M-02: liquidity added, swapped against and removed in one transaction gets none of the arb recapture's LP share.
    function test_regression_sameTransactionLiquidityGetsNone() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        Actor jit = _newActor(k);
        uint256 ethBefore = address(jit).balance;
        jit.jitSwap(k, true, -1e20, MIN_PRICE, -600, 600, 1e26);
        uint256 leg = _accrued(k);
        assertGt(leg, 0, "an LP share, pending");
        uint256 jitPaid = ethBefore - address(jit).balance;
        vm.prank(creator);
        launcher.withdraw(familyK, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        _nextBlock();
        _newActor(k).modify(k, 800_040, 800_100, 1e18);
        _flushAll(k);
        assertEq(_accrued(k), 0);
        uint256 before = creator.balance;
        vm.prank(creator);
        launcher.withdraw(familyK, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        assertApproxEqAbs(creator.balance - before, leg, 2, "all of it to the liquidity held across the boundary");
        assertGt(jitPaid, 0, "the JIT position paid for its swap and took no share back");
    }

    /// M-03: liquidity added in one transaction and removed in another of the arb recapture's block gets none either.
    function test_regression_sameBlockLiquidityGetsNone() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        Actor band = _newActor(k);
        band.modify(k, -600, 600, 1e26);
        _buy(k, ETH, whale, 1e20);
        uint256 leg = _accrued(k);
        band.modify(k, -600, 600, -1e26);
        vm.prank(creator);
        launcher.withdraw(familyK, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        _nextBlock();
        _newActor(k).modify(k, 800_040, 800_100, 1e18);
        _flushAll(k);
        uint256 before = creator.balance;
        vm.prank(creator);
        launcher.withdraw(familyK, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        assertApproxEqAbs(creator.balance - before, leg, 2, "the band left before the flush and got none");
    }

    /// A position held across the block boundary gets its pro-rata share: here as much liquidity as the launch
    /// position over the same range, so half. A position added after the arb recapture in the same block and held
    /// into the next is in range at the flush too, and shares it the same way (documented).
    function test_positionsHeldAcrossTheBoundaryShareProRata() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        Actor early = _newActor(k);
        early.modify(k, -60_000, 60_000, 1e24);
        _nextBlock();
        _buy(k, ETH, whale, 1e20);
        uint256 leg = _accrued(k);
        Actor late = _newActor(k);
        late.modify(k, -60_000, 60_000, 1e24);
        early.modify(k, -60_000, 60_000, 0);
        late.modify(k, -60_000, 60_000, 0);
        vm.prank(creator);
        launcher.withdraw(familyK, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        _nextBlock();
        _newActor(k).modify(k, 800_040, 800_100, 1e18);
        _flushAll(k);
        uint256 e0 = address(early).balance;
        uint256 l0 = address(late).balance;
        uint256 c0 = creator.balance;
        early.modify(k, -60_000, 60_000, 0);
        late.modify(k, -60_000, 60_000, 0);
        vm.prank(creator);
        launcher.withdraw(familyK, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        assertApproxEqAbs(address(early).balance - e0, leg / 3, 3, "a third to the early position");
        assertApproxEqAbs(address(late).balance - l0, leg / 3, 3, "a third to the one added after, held over");
        assertApproxEqAbs(creator.balance - c0, leg / 3, 3, "a third to the launch position");
    }

    /// An add in a later block lands after that block's flush: it gets none of the part released then (120/N of the
    /// share a parent block after the arb recapture, N the pool's release period in L2 blocks), and a fee collection (a
    /// zero removal) does not flush. The rest goes to whatever is in range in later blocks.
    function test_anAddFlushesBeforeItLands_andAFeeCollectionNever() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        _buy(k, ETH, whale, 1e20);
        uint256 leg = _accrued(k);
        _nextBlock();
        vm.prank(creator);
        launcher.withdraw(familyK, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        assertEq(_accrued(k), leg, "a fee collection does not flush");
        Actor newcomer = _newActor(k);
        newcomer.modify(k, -60_000, 60_000, 1e24);
        uint256 part = _releasedAfter(leg, ArbSysKit.L2_PER_PARENT, RELEASE);
        assertEq(_accrued(k), leg - part, "one parent block (120 L2 blocks) of release flushed before the add landed");
        uint256 n0 = address(newcomer).balance;
        newcomer.modify(k, -60_000, 60_000, 0);
        assertEq(address(newcomer).balance - n0, 0, "the newcomer got none of that part");
        uint256 c0 = creator.balance;
        vm.prank(creator);
        launcher.withdraw(familyK, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        assertApproxEqAbs(creator.balance - c0, part, 2);
    }

    /// With no in-range liquidity when the share accrues, it goes to the liquidity owner's accrual at once, so nobody
    /// can add liquidity later to capture it.
    function test_zeroInRangeLiquidityAtAccrualGoesToTheOwner() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        uint128 l = launcher.position(familyK, 0).liquidity;
        vm.prank(creator);
        launcher.withdraw(familyK, 0, l, 0, 0, creator, vm.getBlockTimestamp());
        Actor out = _newActor(k);
        out.modify(k, 800_040, 800_100, 1e18);
        _nextBlock();
        vm.recordLogs();
        out.directSwap(k, false, -1e6, 79228162514264337593543950336 * 2);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertGt(o.succeeded, 0, "an arb recapture pushed");
        (uint256 d0, uint256 d1, uint256 f0, uint256 f1,) = _recap().pendingDonation(k.toId());
        assertEq(d0 + d1 + f0 + f1, 0, "nothing pending");
        assertGt(_recap().poolAccrued(k.toId(), ETH), 0, "the owner's accrual");
    }
}
