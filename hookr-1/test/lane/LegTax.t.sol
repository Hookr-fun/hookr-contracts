// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {IHookrLaneRules} from "../../src/interfaces/IHookrLaneRules.sol";
import {IHookrFeeOnlyRules} from "../../src/interfaces/IHookrFeeOnlyRules.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {PartnerShapedFixture} from "./utils/PartnerShapedFixture.sol";
import {LegTaxAdvisory, BandAdvisory, ReceiptSink} from "./mocks/LegTaxMocks.sol";
import {LegTaxFixture} from "./utils/LegTaxFixture.sol";
import {IHookrLaneEvents} from "../../src/interfaces/IHookrLaneEvents.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";

/// @notice An arb recapture leg on a pool with an advisory is asked and charged as an unauthenticated swap of the
///         executor on that pool: its take in the pool's quote credited to the advisory's recipient through the Rules,
///         its surcharge as LP fee, its refusal in either phase. It runs no rule. A leg on a pool without an advisory is
///         unchanged.
///         Audit findings BA-R3-A and MG-201.
contract LegTaxTest is LegTaxFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    PoolKey internal taxed;
    PoolKey internal plain;

    function setUp() public {
        _setUpLegTax();
        taxed = _taxedPool();
        plain = _plainPool();
        _nextBlock();
    }

    /// An exact-input sell leg pays the after-phase take on the gross quote out, floored.
    function test_exactInputSellLegPaysTheAfterPhaseTax() public {
        tax.set(TAX, TAX);
        (Outcome memory o,, uint256 sc) = _runLeg(taxed, taxed, false, false, -1e20);
        assertEq(o.failed, 0, "the frame passed");
        assertEq(legEx.legs(), 1, "the leg ran");
        uint256 out = uint256(legEx.last0());
        assertEq(sc, (out + sc) * TAX / PIPS, "1% of the gross quote out");
        assertApproxEqAbs(sc, 0.9899e18, 0.0001e18, "about 0.98990e18 on a 1e20 leg");
    }

    /// An exact-input buy leg pays the before-phase take reserved on its specified input.
    function test_exactInputBuyLegPaysTheBeforePhaseTax() public {
        tax.set(TAX, TAX);
        (Outcome memory o, uint256 bc,) = _runLeg(taxed, taxed, false, true, -1e20);
        assertEq(o.failed, 0, "the frame passed");
        assertEq(legEx.legs(), 1, "the leg ran");
        // The trigger buy of 1e18 pays 1e16; the leg's 1e20 pays 1e18.
        assertEq(bc, 1e16 + 1e18, "the leg paid 1% of its gross spend");
        assertEq(uint256(-legEx.last0()), 1e20, "the leg spent exactly its input");
    }

    /// An exact-output buy leg pays the take grossed up on the quote it spent.
    function test_exactOutputBuyLegPaysTheTax() public {
        tax.set(TAX, TAX);
        (Outcome memory o, uint256 bc,) = _runLeg(taxed, taxed, false, true, 1e20);
        assertEq(o.failed, 0, "the frame passed");
        uint256 spent = uint256(-legEx.last0());
        uint256 take = bc - 1e16;
        uint256 actual = spent - take;
        assertEq(take, actual * PIPS / (PIPS - TAX) - actual, "the gross-up of the quote that filled");
        assertEq(uint256(legEx.last1()), 1e20, "the executor received exactly its output");
        assertApproxEqAbs(take, 1.0204e18, 0.0001e18, "about 1.0204e18");
    }

    /// An exact-output sell leg pays the reserve on its specified output, and still nets exactly that output.
    function test_exactOutputSellLegPaysTheReserve() public {
        tax.set(TAX, TAX);
        (Outcome memory o,, uint256 sc) = _runLeg(taxed, taxed, false, false, 1e20);
        assertEq(o.failed, 0, "the frame passed");
        assertEq(uint256(legEx.last0()), 1e20, "the executor nets exactly its output");
        assertEq(sc, (1e20 * uint256(TAX) + (PIPS - TAX) - 1) / (PIPS - TAX), "ceil(Q x t / (1e6 - t))");
        assertEq(sc, 1010101010101010102);
    }

    /// A partially filled exact-input buy leg with a take is refused as an unauthenticated trader's is
    /// (UnauthenticatedRefund inside the PoolManager's WrappedError), and the trigger buy goes on.
    function test_partialExactInputBuyLegIsRefusedAndTheSwapGoesOn() public {
        tax.set(TAX, TAX);
        (uint160 p,,,) = manager.getSlot0(taxed.toId());
        legEx.clear();
        legEx.add(false, taxed, true, -1e24, p - p / 1000, 0);
        uint256 b0 = rules.claimable(ETH, tax.BUY_TO());
        vm.recordLogs();
        _buy(taxed, ETH, whale, 1e18);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.failed, 0, "the frame closed clean");
        assertEq(legEx.legs(), 0, "no leg completed");
        assertEq(_inner(legEx.lastError()), IHookrRootState.UnauthenticatedRefund.selector, "the root refused it");
        assertEq(rules.claimable(ETH, tax.BUY_TO()) - b0, 1e16, "the trigger buy paid its own take and went on");
    }

    /// A leg on an advised pool runs no rule: it pays no protocol share (none paid in its frame), leaves the protocol's
    /// claim, the King of the Pool round (`hill`), the launch guard word and the dynamic fee reference where the
    /// trigger alone leaves them.
    function test_advisedLegTouchesNoRulesState() public {
        PoolKey memory koth = _launchPool(address(tax), BOTH, false, _laneRules(true), _kothRc());
        tax.set(TAX, TAX);
        _nextBlock();
        _buy(koth, ETH, whale, 5e18); // crowns the whale
        _nextBlock();
        (, address leader0,,) = _hill(koth);
        assertEq(leader0, whale, "a leader to keep");
        uint256 snap = vm.snapshotState();
        // The trigger alone.
        legEx.clear();
        _buy(koth, ETH, minnow, 1e18);
        (uint64 s1, address l1, uint128 a1, uint128 p1) = _hill(koth);
        uint256 protocol1 = rules.claimable(ETH, protocol);
        bytes32 guard1 = _guardWord(koth);
        (, int24 ref1, int24 anchor1,,,) = rules.referenceState(koth.toId());
        vm.revertToState(snap);
        // The trigger with a taxed sell leg on the pool.
        legEx.clear();
        legEx.add(false, koth, false, -1e19, HI - 1, 0);
        uint256 s0 = rules.claimable(ETH, tax.SELL_TO());
        _buy(koth, ETH, minnow, 1e18);
        assertEq(legEx.legs(), 1, "the leg ran");
        assertGt(rules.claimable(ETH, tax.SELL_TO()), s0, "the leg paid the take");
        assertEq(legEx.paidInFrame(), 0, "no protocol share paid by the executor");
        (uint64 s2, address l2, uint128 a2, uint128 p2) = _hill(koth);
        assertEq(l2, whale, "the lead is not voided");
        assertEq(abi.encode(s1, l1, a1, p1), abi.encode(s2, l2, a2, p2), "the round as the trigger alone leaves it");
        assertEq(rules.claimable(ETH, protocol), protocol1, "the protocol claim as the trigger alone leaves it");
        assertEq(_guardWord(koth), guard1, "the guard word");
        (, int24 ref2, int24 anchor2,,,) = rules.referenceState(koth.toId());
        assertEq(abi.encode(ref1, anchor1), abi.encode(ref2, anchor2), "the reference and anchor");
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// A taxed leg, then a call that returns two words: the frame fails and every leg credit, mint and log unwinds.
    function test_failedFrameUnwindsLegTakes() public {
        tax.set(TAX, TAX);
        uint256 snap = vm.snapshotState();
        legEx.clear();
        _buy(taxed, ETH, whale, 1e18);
        uint256 claimable = rules.claimable(ETH, tax.SELL_TO());
        uint256 liability = rules.totalLiability(ETH);
        uint256 held = manager.balanceOf(address(rules), ETH.toId());
        vm.revertToState(snap);
        legEx.clear();
        legEx.add(false, taxed, false, -1e20, HI - 1, 0);
        legEx.setBadReturn(true);
        vm.recordLogs();
        _buy(taxed, ETH, whale, 1e18);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.failed, 2, "both frames failed");
        assertEq(o.lastReason, IHookrLaneEvents.LaneBadReturn.selector);
        assertEq(rules.claimable(ETH, tax.SELL_TO()), claimable, "the leg's credit unwound");
        assertEq(rules.totalLiability(ETH), liability, "liabilities unwound");
        assertEq(manager.balanceOf(address(rules), ETH.toId()), held, "the mint unwound");
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// settleLeg answers only the trusted root, only by DELEGATECALL, only for a bound pool with recapture on, and only
    /// a nonzero amount to a nonzero recipient.
    function test_settleLegGuards() public {
        IHookrLaneRules lr = IHookrLaneRules(address(rules));
        PoolId id = taxed.toId();
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        lr.settleLeg(id, address(1), 1);
        (address module,) = IHookrRecaptureRules(address(rules)).recaptureModule();
        vm.prank(address(root));
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        IHookrLaneRules(module).settleLeg(id, address(1), 1);
        vm.prank(address(root));
        vm.expectRevert(IHookrRulesEvents.UnknownPool.selector);
        lr.settleLeg(PoolId.wrap(keccak256("unbound")), address(1), 1);
        PoolKey memory off = _openStd(ETH);
        vm.prank(address(root));
        vm.expectRevert(IHookrRulesEvents.InvalidSettlement.selector);
        lr.settleLeg(off.toId(), address(1), 1);
        vm.prank(address(root));
        vm.expectRevert(IHookrRulesEvents.InvalidSettlement.selector);
        lr.settleLeg(id, address(0), 1);
        vm.prank(address(root));
        vm.expectRevert(IHookrRulesEvents.InvalidSettlement.selector);
        lr.settleLeg(id, address(1), 0);
        vm.prank(address(root));
        assertEq(lr.settleLeg(id, address(1), 5), 5, "the root credits");
        assertEq(rules.claimable(ETH, address(1)), 5);
        assertEq(IHookrLaneRules.settleLeg.selector, bytes4(0x4f735c09));
    }

    /// Rules without settleLeg refuse a leg that takes (ModuleCallFailed(rules, 0x4f735c09)) and credit nothing; the
    /// trade goes on, and a leg with a zero take never calls it.
    function test_rulesWithoutSettleLegRefusesTakingLegs() public {
        vm.mockCallRevert(address(rules), abi.encodeWithSelector(IHookrLaneRules.settleLeg.selector), "");
        tax.set(TAX, TAX);
        (Outcome memory o,, uint256 sc) = _runLeg(taxed, taxed, false, false, -1e20);
        assertEq(o.failed, 0);
        assertEq(legEx.legs(), 0, "the taxed leg was refused");
        assertEq(sc, 0, "nothing credited");
        bytes memory reason = _innerReason(legEx.lastError());
        assertEq(
            reason,
            abi.encodeWithSelector(IHookrRootEvents.ModuleCallFailed.selector, address(rules), bytes4(0x4f735c09)),
            "ModuleCallFailed(rules, settleLeg)"
        );
        _nextBlock();
        tax.set(0, 0);
        (o,, sc) = _runLeg(taxed, taxed, false, false, -1e20);
        assertEq(legEx.legs(), 1, "a zero-take leg passes");
        vm.clearMockedCalls();
    }

    /// Starving a leg of gas cannot lower its charge: at every gas grant the leg either reverts or pays what it pays
    /// with gas to spare. An advisory that cannot answer within its gas limit refuses the leg when strict, and charges
    /// the admitted surcharge ceiling when fail-open, never less than an answer.
    function test_starvedAdvisoryCannotLowerALegsCharge() public {
        // Strict, with a take.
        tax.set(TAX, TAX);
        tax.setBurn(20_000, address(legEx));
        uint256 snap = vm.snapshotState();
        (,, uint256 full) = _runLeg(taxed, taxed, false, false, -1e19);
        assertEq(legEx.legs(), 1);
        uint256 ran;
        uint256 refused;
        for (uint256 g = 60_000; g <= 400_000; g += 10_000) {
            vm.revertToState(snap);
            legEx.clear();
            legEx.add(false, taxed, false, -1e19, HI - 1, g);
            uint256 s0 = rules.claimable(ETH, tax.SELL_TO());
            _buy(taxed, ETH, whale, 1e18);
            if (legEx.legs() == 1) {
                ran++;
                assertEq(rules.claimable(ETH, tax.SELL_TO()) - s0, full, "a leg that runs pays the whole take");
            } else {
                refused++;
            }
        }
        assertGt(ran, 0, "some grants run the leg");
        assertGt(refused, 0, "some grants starve it");
        // Past its gas limit the strict advisory fails: the leg is refused.
        vm.revertToState(snap);
        tax.setBurn(150_000, address(legEx));
        _runLeg(taxed, taxed, false, false, -1e19);
        assertEq(legEx.legs(), 0, "refused");
        assertEq(
            _innerReason(legEx.lastError()),
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallFailed.selector, address(tax), IHookrAdvisory.beforeSwap.selector
            )
        );
        // Fail-open, surcharge only.
        vm.revertToState(snap);
        LegTaxAdvisory open = new LegTaxAdvisory();
        _admit(address(open), 50_000, 0, HookrTypes.BEFORE_SWAP, true);
        open.setSurcharge(5_000);
        open.setBurn(20_000, address(legEx));
        PoolKey memory failOpen =
            _launchPool(address(open), HookrTypes.BEFORE_SWAP, true, _laneRules(false), _recaptureOnlyRc());
        _nextBlock();
        snap = vm.snapshotState();
        _runLeg(failOpen, failOpen, false, false, -1e19);
        int256 answered = legEx.last0();
        assertGt(answered, 0);
        ran = 0;
        for (uint256 g = 60_000; g <= 400_000; g += 10_000) {
            vm.revertToState(snap);
            legEx.clear();
            legEx.add(false, failOpen, false, -1e19, HI - 1, g);
            _buy(failOpen, ETH, whale, 1e18);
            if (legEx.legs() == 1) {
                ran++;
                assertLe(legEx.last0(), answered, "never charged less than the answer");
            }
        }
        assertGt(ran, 0, "some grants run the leg");
        // Past its gas limit the fail-open advisory fails: the leg runs at the ceiling, 50,000 pips over 5,000.
        vm.revertToState(snap);
        open.setBurn(150_000, address(legEx));
        _runLeg(failOpen, failOpen, false, false, -1e19);
        assertEq(legEx.legs(), 1, "a fail-open failure charges, it does not refuse");
        assertLt(legEx.last0(), answered, "the ceiling");
    }

    /// A router swap with a receipt on a lane pool, with advised taxed legs in both phases: the receipt and the outer
    /// HookFee equal the figures of the same swap with no legs, since the outer frame is read before the after-phase
    /// legs and its receipt written after them.
    function test_advisedLegKeepsTheOuterFrame() public {
        tax.set(TAX, TAX);
        ReceiptSink sink = new ReceiptSink(address(router), address(manager));
        uint256 snap = vm.snapshotState();
        legEx.clear();
        (uint256 feeA, uint256 volumeA, uint256 outA) = _receiptSwap(sink);
        assertEq(legEx.legs(), 0);
        vm.revertToState(snap);
        legEx.clear();
        legEx.add(false, taxed, false, -1e19, HI - 1, 0);
        legEx.add(true, taxed, false, -1e19, HI - 1, 0);
        uint256 s0 = rules.claimable(ETH, tax.SELL_TO());
        (uint256 feeB, uint256 volumeB, uint256 outB) = _receiptSwap(sink);
        assertEq(legEx.legs(), 2, "a taxed leg in each phase");
        assertGt(rules.claimable(ETH, tax.SELL_TO()), s0, "the legs paid the sell take");
        assertEq(feeB, feeA, "the outer HookFee");
        assertEq(volumeB, volumeA, "the receipt's quote volume");
        assertEq(feeA, 1e16, "1% of the 1e18 buy");
        assertTrue(outB != outA, "the legs moved the price the buy filled at");
        assertEq(sink.records(), 1);
    }

    function _receiptSwap(ReceiptSink sink) internal returns (uint256 fee, uint256 volume, uint256 out) {
        IHookrRouter.Swap memory p = _swapParams(taxed, ETH, true, true, 1e18, whale);
        uint256[] memory campaigns = new uint256[](1);
        campaigns[0] = 1;
        vm.recordLogs();
        vm.prank(whale);
        (, out) = router.swap{value: 1e18}(p, address(sink), campaigns);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 hookFee = keccak256("HookFee(bytes32,address,uint256,uint256,uint256)");
        // The outer swap's HookFee is the root's last: its afterSwap emits it after the after-phase legs' own.
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(root) && logs[i].topics[0] == hookFee) {
                (fee,,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        volume = sink.quoteVolume();
    }

    /// A leg on a pool without an advisory is unchanged: the base LP fee, no rule, the HEAD output to the wei.
    function test_unadvisedLegUnchanged() public {
        _runLeg(plain, plain, false, false, -1e20);
        assertEq(legEx.legs(), 1);
        assertEq(uint256(legEx.last0()), 98_990_199_970_202_949_907, "the HEAD exact-input sell leg output");
        _nextBlock();
        _runLeg(plain, plain, false, true, -1e20);
        assertEq(uint256(legEx.last1()), 99_009_603_980_885_107_744, "the HEAD exact-input buy leg output");
    }

    /// During the launch guard a buy leg on an advised pool still takes the whole trader path: Snipe, the guard and the
    /// advisory's take, as at HEAD.
    function test_guardBuyLegStillTakesTheFullPath() public {
        HookrTypes.RulesConfig memory r = _laneRules(false);
        r.guardEndBlock = uint40(vm.getBlockNumber() + 100_000);
        r.snipeTaxPips = 300_000;
        r.maxBuyQuoteAmount = 1e22;
        PoolKey memory guarded = _launchPool(address(tax), BOTH, false, r, _recaptureOnlyRc());
        tax.set(TAX, TAX);
        _nextBlock();
        uint256 b0 = rules.claimable(ETH, tax.BUY_TO());
        _runLeg(guarded, guarded, false, true, -1e18);
        assertEq(legEx.legs(), 1);
        assertEq(uint256(legEx.last1()), 699_974_510_035_342_338, "the HEAD guarded buy leg output");
        assertEq(rules.claimable(ETH, tax.BUY_TO()) - b0, 2e16, "the leg's and the trigger's 1% take");
    }

    /// Per taxed leg: FeesAllocated.advisoryFee == HookFee.earned == the ERC-6909 mint to the Rules, in the pool's
    /// quote; over the frame the executor-sender HookFees sum to the tax paid.
    function test_eventIdentities() public {
        tax.set(TAX, TAX);
        legEx.clear();
        legEx.add(false, taxed, false, -1e20, HI - 1, 0);
        legEx.add(true, taxed, false, 1e19, HI - 1, 0);
        uint256 s0 = rules.claimable(ETH, tax.SELL_TO());
        vm.recordLogs();
        _buy(taxed, ETH, whale, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(legEx.legs(), 2);
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bytes32 fees = keccak256("FeesAllocated(bytes32,address,uint256,uint256,uint256,address,uint256)");
        bytes32 transfer = keccak256("Transfer(address,address,address,uint256,uint256)");
        bytes32 hookFee = keccak256("HookFee(bytes32,address,uint256,uint256,uint256)");
        uint256 legs;
        uint256 sum;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != swapTopic) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != address(legEx)) continue;
            // Swap, then FeesAllocated, the mint's Transfer to the Rules and HookFee, in that order.
            assertEq(logs[i + 1].topics[0], fees, "FeesAllocated follows the leg's Swap");
            assertEq(logs[i + 1].emitter, address(rules));
            (uint256 prot, uint256 roy, uint256 refund, address to, uint256 advisoryFee) =
                abi.decode(logs[i + 1].data, (uint256, uint256, uint256, address, uint256));
            assertEq(prot + roy + refund, 0, "no protocol, royalty or refund on a leg");
            assertEq(to, tax.SELL_TO());
            assertEq(logs[i + 2].topics[0], transfer, "the mint");
            assertEq(address(uint160(uint256(logs[i + 2].topics[2]))), address(rules), "minted to the Rules");
            (, uint256 minted) = abi.decode(logs[i + 2].data, (address, uint256));
            assertEq(logs[i + 3].topics[0], hookFee, "HookFee");
            (uint256 earned, uint256 r2, uint256 burned) = abi.decode(logs[i + 3].data, (uint256, uint256, uint256));
            assertEq(r2 + burned, 0);
            assertEq(advisoryFee, earned, "FeesAllocated == HookFee");
            assertEq(minted, earned, "HookFee == mint");
            sum += earned;
            legs++;
        }
        assertEq(legs, 2, "both legs found");
        assertEq(sum, rules.claimable(ETH, tax.SELL_TO()) - s0, "the frame's leg HookFees are the tax paid");
    }

    /// A lane pool never takes the fee-only branch, whatever its Rules answer, so an advised leg always takes the full
    /// branch.
    function test_advisedLegNeverTakesTheFeeOnlyBranch() public {
        LegTaxAdvisory surchargeOnly = new LegTaxAdvisory();
        _admit(address(surchargeOnly), 50_000, 0, HookrTypes.BEFORE_SWAP, false);
        vm.mockCall(
            address(rules),
            abi.encodeWithSelector(IHookrFeeOnlyRules.feeOnlyFrom.selector),
            abi.encode(vm.getBlockNumber() + 1)
        );
        PoolKey memory lane =
            _launchPool(address(surchargeOnly), HookrTypes.BEFORE_SWAP, false, _laneRules(false), _recaptureOnlyRc());
        HookrTypes.RecaptureConfig memory off;
        PoolKey memory noLane =
            _launchPool(address(surchargeOnly), HookrTypes.BEFORE_SWAP, false, _laneRules(false), off);
        vm.clearMockedCalls();
        assertEq(root.feeOnlyFrom(lane.toId()), 0, "a lane pool binds no fee-only block");
        assertEq(
            root.feeOnlyFrom(noLane.toId()), vm.getBlockNumber() + 1, "the same Rules answer binds it off the lane"
        );
    }

    /// An advised taxed frame reads the L2 clock (ArbSys at 0x64) exactly as often as the same frame unadvised: a leg
    /// reaches no clock reader.
    function test_taxedLegReadsNoClock() public {
        tax.set(TAX, TAX);
        uint256 snap = vm.snapshotState();
        uint256 advised = _clockReads(taxed);
        assertEq(legEx.legs(), 1);
        vm.revertToState(snap);
        uint256 unadvised = _clockReads(plain);
        assertEq(legEx.legs(), 1);
        assertEq(advised, unadvised, "the same ArbSys reads");
    }

    function _clockReads(PoolKey memory key) internal returns (uint256 n) {
        legEx.clear();
        legEx.add(false, key, false, -1e19, HI - 1, 0);
        vm.startStateDiffRecording();
        _buy(key, ETH, whale, 1e18);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        for (uint256 i; i < acc.length; ++i) {
            if (acc[i].account == address(0x64)) n++;
        }
    }

    /// Gas of one leg of each shape from the same state: no advisory, an advisory with a zero take, a 1% take. The
    /// first take ever on the pool pays three zero-to-nonzero writes.
    function test_legGas() public {
        _legGas("first take ever on the pool", 200_000);
    }

    /// The same once the queues, the Rules' liabilities and their PoolManager balance are nonzero.
    function test_legGasSteady() public {
        tax.set(TAX, TAX);
        _runLeg(taxed, taxed, false, true, -1e19);
        _nextBlock();
        _runLeg(taxed, taxed, false, false, -1e19);
        _nextBlock();
        _legGas("steady state", 120_000);
    }

    function _legGas(string memory label, uint256 budget) internal {
        console2.log(label);
        uint256 snap = vm.snapshotState();
        string[4] memory shapes = ["exact-input sell", "exact-input buy", "exact-output buy", "exact-output sell"];
        bool[4] memory z = [false, true, true, false];
        int256[4] memory amt = [int256(-1e20), int256(-1e20), int256(1e20), int256(1e20)];
        for (uint256 i; i < 4; ++i) {
            vm.revertToState(snap);
            _runLeg(plain, plain, false, z[i], amt[i]);
            uint256 g0 = legEx.legGas();
            vm.revertToState(snap);
            tax.set(0, 0);
            _runLeg(taxed, taxed, false, z[i], amt[i]);
            uint256 g1 = legEx.legGas();
            vm.revertToState(snap);
            tax.set(TAX, TAX);
            _runLeg(taxed, taxed, false, z[i], amt[i]);
            uint256 g2 = legEx.legGas();
            console2.log(shapes[i]);
            console2.log("  leg gas: no advisory / zero take / 1% take", g0, g1, g2);
            assertLt(g2, budget, "a taxed leg inside its budget");
        }
    }

    /// BA-R3-A (builder attribution). A before-phase tax of 3% on buys and 5% on sells, bound for the before
    /// phase only. Before, a 1e21 exact-input sell leg took 994.02e18 quote out untaxed. Now the leg pays what an
    /// ordinary unauthenticated sell of the same size pays from the same state, and the trigger its own 3%.
    function test_sellLegPaysTheSellTax() public {
        LegTaxAdvisory before = new LegTaxAdvisory();
        _admit(address(before), 0, 100_000, HookrTypes.BEFORE_SWAP, false);
        before.set(30_000, 50_000);
        before.setSellsBefore(true);
        PoolKey memory key = _launchPoolAt(address(before), HookrTypes.BEFORE_SWAP, false, _laneRules(false), 3_000);
        _nextBlock();
        legEx.clear();
        uint256 snap = vm.snapshotState();
        // An ordinary unauthenticated sell of 1e21 from this state.
        HookrToken subject = HookrToken(Currency.unwrap(key.currency1));
        uint256 s0 = rules.claimable(ETH, before.SELL_TO());
        uint256 ordinaryOut = outsider.swap(key, false, 1e21, 0);
        uint256 ordinaryTax = rules.claimable(ETH, before.SELL_TO()) - s0;
        assertEq(ordinaryTax, (ordinaryOut + ordinaryTax) * 50_000 / PIPS, "5% of the gross quote out");
        assertApproxEqAbs(ordinaryTax, 49.8e18, 0.1e18, "about 49.8e18");
        vm.revertToState(snap);
        legEx.clear();
        legEx.add(false, key, false, -1e21, HI - 1, 0);
        uint256 b0 = rules.claimable(ETH, before.BUY_TO());
        s0 = rules.claimable(ETH, before.SELL_TO());
        _buy(key, ETH, whale, 1e18);
        assertEq(legEx.legs(), 1, "the sell leg ran");
        assertApproxEqAbs(rules.claimable(ETH, before.SELL_TO()) - s0, ordinaryTax, 2, "the leg paid the sell tax");
        assertApproxEqAbs(uint256(legEx.last0()), ordinaryOut, 2, "and got what an ordinary sell gets");
        assertEq(rules.claimable(ETH, before.BUY_TO()) - b0, 3e16, "the trigger's own 3%");
        assertEq(subject.balanceOf(address(legEx)), 1e26 - 1e21);
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// MG2-01 REFUSE (market guard). Before, a 3e23 leg filled to tick 5,233 against a band edge at 953. Now
    /// the strict band refuses it in the after phase (InvalidModuleResult inside the WrappedError), no leg moves the
    /// tick past the edge, and an in-band 1e18 leg runs.
    function test_refuseLegPastTheBandRevertsAfterTheSwap() public {
        BandAdvisory band = new BandAdvisory(manager);
        _admit(address(band), 50_000, 0, BOTH, false);
        PoolKey memory key = _launchPool(address(band), BOTH, false, _laneRules(false), _recaptureOnlyRc());
        _nextBlock();
        (, int24 tick0,,) = manager.getSlot0(key.toId());
        band.setBand(tick0 - 953, tick0 + 953);
        // The 3e23 leg buys: currency0 (ETH) in, the price of currency1 falls, the tick falls toward the lower edge.
        legEx.clear();
        legEx.add(true, key, true, -3e23, LO + 1, 0);
        _buy(key, ETH, whale, 1e18);
        assertEq(legEx.legs(), 0, "the leg past the band was refused");
        assertEq(_inner(legEx.lastError()), IHookrRootEvents.InvalidModuleResult.selector, "refused in the after phase");
        (, int24 tick1,,) = manager.getSlot0(key.toId());
        assertGe(tick1, tick0 - 953, "in band");
        _nextBlock();
        legEx.clear();
        legEx.add(true, key, true, -1e18, LO + 1, 0);
        _buy(key, ETH, whale, 1e18);
        assertEq(legEx.legs(), 1, "an in-band leg runs");
        (, int24 tick2,,) = manager.getSlot0(key.toId());
        assertGe(tick2, tick0 - 953, "in band");
    }

    /// MG2-01 SURCHARGE. Before, a leg paid the 3,000 base fee against a 20,000 surcharge priced for its move. Now its
    /// LP fee, read from feeGrowthGlobal, is 23,000 pips, and its output equals an ordinary swap's to the wei.
    function test_surchargeLegPaysThePricedSurcharge() public {
        BandAdvisory band = new BandAdvisory(manager);
        _admit(address(band), 50_000, 0, HookrTypes.BEFORE_SWAP, false);
        band.setPrice(20_000, 1e22);
        HookrTypes.RulesConfig memory r = _laneRules(false);
        PoolKey memory key = _launchPoolAt(address(band), HookrTypes.BEFORE_SWAP, false, r, 3_000);
        _nextBlock();
        legEx.clear();
        uint256 snap = vm.snapshotState();
        uint256 ordinary = outsider.swap{value: 3e22}(key, true, 3e22, 0);
        vm.revertToState(snap);
        (uint256 g0,) = manager.getFeeGrowthGlobals(key.toId());
        legEx.clear();
        legEx.add(false, key, true, -3e22, LO + 1, 0);
        _buy(key, ETH, whale, 1e15);
        assertEq(legEx.legs(), 1);
        assertEq(uint256(legEx.last1()), ordinary, "the leg's output equals an ordinary swap's");
        // The leg's LP fee in pips of its 3e22 input (the trigger's 1e15 adds under a pip).
        uint256 feePips = _fees0(key, g0) * PIPS / 3e22;
        assertEq(feePips, 23_000, "base 3,000 + surcharge 20,000");
    }

    /// MG2-01 fail-open. A fail-open advisory is asked about legs too: on an answer the leg pays base + surcharge, on a
    /// failure base + the admitted ceiling, as an ordinary swap does.
    function test_failOpenAdvisoryIsAskedOnLegs() public {
        LegTaxAdvisory open = new LegTaxAdvisory();
        _admit(address(open), 40_000, 0, HookrTypes.BEFORE_SWAP, true);
        open.setSurcharge(20_000);
        PoolKey memory key = _launchPoolAt(address(open), HookrTypes.BEFORE_SWAP, true, _laneRules(false), 3_000);
        _nextBlock();
        for (uint256 k; k < 2; ++k) {
            open.setBroken(k == 1);
            legEx.clear();
            uint256 snap = vm.snapshotState();
            uint256 ordinary = outsider.swap{value: 1e22}(key, true, 1e22, 0);
            vm.revertToState(snap);
            (uint256 g0,) = manager.getFeeGrowthGlobals(key.toId());
            legEx.clear();
            legEx.add(false, key, true, -1e22, LO + 1, 0);
            _buy(key, ETH, whale, 1e15);
            assertEq(legEx.legs(), 1);
            assertEq(uint256(legEx.last1()), ordinary, "as an ordinary swap");
            assertEq(_fees0(key, g0) * PIPS / 1e22, k == 0 ? 23_000 : 43_000, "base + surcharge, or base + ceiling");
            vm.revertToState(snap);
        }
    }

    function _launchPoolAt(address advisory, uint8 phases, bool failOpen, HookrTypes.RulesConfig memory r, uint24 fee)
        internal
        returns (PoolKey memory key)
    {
        HookrToken subject = _newSubject();
        subject.transfer(address(legEx), 1e26);
        subject.approve(address(outsider), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        r.maxFeePips = fee;
        members[0] = _laneMember(ETH, r, _recaptureOnlyRc());
        members[0].config.baseLpFeePips = fee;
        members[0].config.advisory = advisory;
        members[0].config.advisoryGasLimit = 100_000;
        members[0].config.advisoryPhases = phases;
        members[0].config.advisoryFailOpen = failOpen;
        bytes[] memory data = new bytes[](1);
        data[0] = hex"01";
        (bytes32 family,) = launcher.launchAdvised{value: 1e24}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            data,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    /// @dev The Rules' launch guard word for a pool: State.guard (the fourth mapping) under HookrRules' storage slot.
    function _guardWord(PoolKey memory key) internal view returns (bytes32) {
        bytes32 slot = 0x762913e4bc0f59f7b08c82f07586fa48932548ab5fab99e6db0b09765b4ff900;
        return vm.load(address(rules), keccak256(abi.encode(key.toId(), uint256(slot) + 3)));
    }
}

/// @notice A family whose trigger member has no advisory and whose tokenB sibling is taxed: the partner-shaped
///         executor's cycles leg through the sibling, pay the sibling's tax in the sibling's quote, and the frame's
///         sibling checks still pass.
contract SiblingLegTaxTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;

    LegTaxAdvisory internal tax;
    Currency internal qb;
    PoolKey internal a;
    PoolKey internal b;

    function setUp() public {
        _setUpPartnerShaped();
        tax = new LegTaxAdvisory();
        IHookrRegistry.Admission memory adm = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(tax),
            codeHash: address(tax).codehash,
            schemaHash: tax.configSchemaHash(),
            caps: HookrTypes.Caps(0, 100_000, 0),
            gasLimit: 100_000,
            phaseMask: HookrTypes.BEFORE_SWAP | HookrTypes.AFTER_SWAP,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), adm));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), adm);
        HookrToken subject = _newSubject();
        subject.approve(address(venue), type(uint256).max);
        qb = Currency.wrap(address(tokenB));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _laneMemberAt(ETH);
        members[1] = _laneMemberAt(qb);
        members[1].config.advisory = address(tax);
        members[1].config.advisoryGasLimit = 100_000;
        members[1].config.advisoryPhases = HookrTypes.BEFORE_SWAP | HookrTypes.AFTER_SWAP;
        bytes[] memory data = new bytes[](2);
        data[1] = hex"01";
        (bytes32 family,) = launcher.launchAdvised{value: 1e24}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            data,
            vm.getBlockTimestamp()
        );
        a = launcher.position(family, 0).key;
        b = launcher.position(family, 1).key;
        PoolKey memory refA = _hookless(a.currency0, a.currency1);
        PoolKey memory conn = _hookless(ETH, qb);
        ex.setTrigger(a, 1e22);
        ex.addVenue(a, refA, PAIR_GAP);
        ex.addCycle(a, b, conn, CYCLE_GAP);
        _nextBlock();
    }

    function _case(uint24 pips) internal returns (Outcome memory o, uint256 cycles, uint256 credited) {
        tax.set(pips, pips);
        uint256 b0 = rules.claimable(qb, tax.BUY_TO());
        uint256 s0 = rules.claimable(qb, tax.SELL_TO());
        vm.recordLogs();
        _buy(a, ETH, whale, 5e22);
        o = _outcome(vm.getRecordedLogs());
        cycles = ex.lastCycles();
        credited = rules.claimable(qb, tax.BUY_TO()) - b0 + rules.claimable(qb, tax.SELL_TO()) - s0;
    }

    function test_siblingLegsPayTheSiblingsTaxInItsQuote() public {
        uint256 snap = vm.snapshotState();
        (Outcome memory o0,, uint256 t0) = _case(0);
        vm.revertToState(snap);
        (Outcome memory o1, uint256 c1, uint256 t1) = _case(1_000);
        console2.log("pushed after, untaxed / 0.1% taxed sibling", o0.pushedAfter, o1.pushedAfter);
        console2.log("sibling tax credited in tokenB", t1);
        assertEq(o1.failed, 0, "no frame failed");
        assertGt(c1, 0, "cycles legged through the taxed sibling");
        assertEq(t0, 0, "no tax, nothing credited");
        assertGt(t1, 0, "the sibling's legs paid its tax, in its quote");
        assertLt(o1.pushedAfter, o0.pushedAfter, "the push is net of the tax");
        assertTrue(rules.accountingInvariant(qb));
        assertTrue(rules.accountingInvariant(ETH));
    }
}

/// @notice A-04 (directional tax, lane audit). A 5% buy tax (before phase) and an 8% sell tax (after phase) on a pool
///         launched with the recapture defaults, a 100 ETH move on the outside venue, then a 0.001 ETH buy. Before,
///         87.57 ETH of buy legs credited the buy queue 0.00005 ETH (the dust buy's own tax) and in the mirror 96.03
///         ETH of sell legs credited the sell queue nothing. Now every leg pays the tax: each queue's credit beyond the
///         dust buy's is exactly the executor legs' HookFees, the partner share holds and the Rules stay backed.
contract DirectionalTaxLegsTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint24 internal constant BUY_TAX = 50_000;
    uint24 internal constant SELL_TAX = 80_000;
    uint256 internal constant DUST = 0.001 ether;

    LegTaxAdvisory internal tax;
    HookrToken internal subject;
    PoolKey internal taxed;
    PoolKey internal outside;

    function setUp() public {
        _setUpPartnerShaped();
        tax = new LegTaxAdvisory();
        IHookrRegistry.Admission memory adm = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(tax),
            codeHash: address(tax).codehash,
            schemaHash: tax.configSchemaHash(),
            caps: HookrTypes.Caps(0, 100_000, 0),
            gasLimit: 100_000,
            phaseMask: HookrTypes.BEFORE_SWAP | HookrTypes.AFTER_SWAP,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), adm));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), adm);
        tax.set(BUY_TAX, SELL_TAX);
        subject = _newSubject();
        subject.approve(address(venue), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMemberAt(ETH);
        (HookrTypes.RecaptureConfig memory rc,) = IHookrRecaptureRules(address(rules)).recaptureDefaults();
        members[0].recapture = rc;
        members[0].config.advisory = address(tax);
        members[0].config.advisoryGasLimit = 100_000;
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP | HookrTypes.AFTER_SWAP;
        bytes[] memory data = new bytes[](1);
        data[0] = hex"01";
        (bytes32 family,) = launcher.launchAdvised{value: 1e24}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            data,
            vm.getBlockTimestamp()
        );
        taxed = launcher.position(family, 0).key;
        outside = PoolKey(taxed.currency0, taxed.currency1, 3000, 60, IHooks(address(0)));
        venue.seed{value: 1e22}(outside, SQRT_ONE, -60_000, 60_000, 1e21);
        ex.setTrigger(taxed, 50 ether);
        ex.addVenue(taxed, outside, PAIR_GAP);
        _nextBlock();
    }

    /// @dev The dust buy after an outside move. Returns the queue's credit beyond the dust buy's own tax, the tax on
    ///      the quote the executor's committed legs moved through the pool (read from its price move at its one
    ///      liquidity, less the dust buy's part), and the frame outcome.
    function _run(bool buyLegs) internal returns (uint256 credited, uint256 expected, Outcome memory o) {
        if (buyLegs) venue.swap{value: 100 ether}(outside, true, 100 ether, 0);
        else venue.swap(outside, false, 100 ether, 0);
        address queue = buyLegs ? tax.BUY_TO() : tax.SELL_TO();
        address other = buyLegs ? tax.SELL_TO() : tax.BUY_TO();
        uint256 q0 = rules.claimable(ETH, queue);
        uint256 o0 = rules.claimable(ETH, other);
        (uint160 sqrt0,,,) = manager.getSlot0(taxed.toId());
        uint128 liquidity = manager.getLiquidity(taxed.toId());
        vm.recordLogs();
        _buy(taxed, ETH, whale, DUST);
        o = _outcome(vm.getRecordedLogs());
        (uint160 sqrt1,,,) = manager.getSlot0(taxed.toId());
        assertEq(manager.getLiquidity(taxed.toId()), liquidity, "one liquidity over the move");
        uint256 dustTax = DUST * BUY_TAX / 1_000_000;
        credited = rules.claimable(ETH, queue) - q0 - (buyLegs ? dustTax : 0);
        assertEq(rules.claimable(ETH, other) - o0, buyLegs ? 0 : dustTax, "the other queue got the dust buy's only");
        // The ETH that crossed the pool's price, net of LP fee; the dust buy's crossing is under 1e15.
        uint256 crossed = SqrtPriceMath.getAmount0Delta(sqrt0, sqrt1, liquidity, buyLegs);
        uint256 dust = (DUST - dustTax) * (1_000_000 - POOL_FEE - 20_000) / 1_000_000;
        if (buyLegs) {
            // Buy legs: gross of the 0.3% LP fee, then of the 5% take on the gross spend.
            uint256 into = (crossed - dust) * 1_000_000 / (1_000_000 - POOL_FEE);
            expected = into * BUY_TAX / (1_000_000 - BUY_TAX);
        } else {
            // Sell legs: 8% of the gross quote out.
            expected = (crossed + dust) * SELL_TAX / 1_000_000;
        }
    }

    function test_arbRecaptureLegsPayTheDirectionalTax() public {
        uint256 snap = vm.snapshotState();
        (uint256 credited, uint256 expected, Outcome memory o) = _run(true);
        console2.log("buy legs: buy queue credit, tax on the quote legged in, pushed", credited, expected);
        console2.log("  ", o.pushedBefore + o.pushedAfter);
        assertEq(o.failed, 0, "every frame passed the partner share");
        assertGt(credited, 1 ether, "the executor legged ETH into the taxed pool and paid its tax");
        assertApproxEqRel(credited, expected, 1e12, "5% of every quote unit legged in");
        assertTrue(rules.accountingInvariant(ETH));
        vm.revertToState(snap);
        (credited, expected, o) = _run(false);
        console2.log("sell legs: sell queue credit, tax on the quote legged out, pushed", credited, expected);
        console2.log("  ", o.pushedBefore + o.pushedAfter);
        assertEq(o.failed, 0, "every frame passed the partner share");
        assertGt(credited, 1 ether, "the executor legged ETH out of the taxed pool and paid its tax");
        assertApproxEqRel(credited, expected, 1e12, "8% of every quote unit legged out");
        assertTrue(rules.accountingInvariant(ETH));
    }
}
