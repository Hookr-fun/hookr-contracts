// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrLaneRules} from "../../src/interfaces/IHookrLaneRules.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {LegTaxFixture} from "./utils/LegTaxFixture.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {DeltaAdvisory, TieredSellTax, LockAwareTax, EndTickSellTax} from "./mocks/QuoteLegMocks.sol";
import {BandAdvisory, LegExecutor} from "./mocks/LegTaxMocks.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";

/// @notice The root's `quoteLeg` answers what a recapture leg then pays the pool's advisory, to the wei in every
///         shape, and refuses where the leg is refused.
contract QuoteLegTest is LegTaxFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint24 internal constant BUY = 10_000;
    uint24 internal constant SELL = 20_000;
    uint24 internal constant SURCHARGE = 5_000;

    PoolKey internal taxed;

    function setUp() public {
        _setUpLegTax();
        taxed = _taxedPool();
        _nextBlock();
    }

    function _quote(PoolKey memory key, bool zeroForOne, int256 amount)
        internal
        returns (uint24 lp, uint24 take, address to, bool full)
    {
        vm.prank(address(legEx));
        uint256 g = gasleft();
        (lp, take, to, full,,) = root.quoteLeg(key, SwapParams(zeroForOne, amount, zeroForOne ? LO + 1 : HI - 1), 1, 1);
        console2.log("  quoteLeg gas", g - gasleft());
    }

    /// @dev One before-phase leg beside a 1e18 buy; returns the leg's take credited, beyond the buy's own, and the LP
    ///      fee its Swap event carries.
    function _leg(bool zeroForOne, int256 amount) internal returns (uint256 credited, uint24 lpFee) {
        uint256 b0 = rules.claimable(ETH, tax.BUY_TO());
        uint256 s0 = rules.claimable(ETH, tax.SELL_TO());
        legEx.clear();
        legEx.add(false, taxed, zeroForOne, amount, zeroForOne ? LO + 1 : HI - 1, 0);
        vm.recordLogs();
        _buy(taxed, ETH, whale, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(legEx.legs(), 1, "the leg ran");
        credited = rules.claimable(ETH, tax.BUY_TO()) - b0 - 1e18 * uint256(BUY) / PIPS
            + rules.claimable(ETH, tax.SELL_TO()) - s0;
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == swapTopic
                    && address(uint160(uint256(logs[i].topics[2]))) == address(legEx)
            ) (,,,,, lpFee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
        }
    }

    /// For each shape the leg's take is the shape's formula applied to the quoted pips, to the wei, and its LP fee is
    /// the quoted one.
    function test_quoteLegMatchesEveryShape() public {
        tax.set(BUY, SELL);
        tax.setSurcharge(SURCHARGE);
        uint256 snap = vm.snapshotState();

        // Exact-input sell: the after-phase take on the gross quote out.
        (uint24 lp, uint24 take, address to, bool full) = _quote(taxed, false, -1e20);
        assertEq(lp, BASE_FEE + SURCHARGE);
        assertEq(take, SELL);
        assertEq(to, tax.SELL_TO());
        assertFalse(full);
        (uint256 credited, uint24 fee) = _leg(false, -1e20);
        uint256 out = uint256(legEx.last0());
        assertEq(credited, (out + credited) * take / PIPS, "the quoted pips of the gross quote out");
        assertEq(fee, lp, "the quoted LP fee");
        vm.revertToState(snap);

        // Exact-input buy: the before-phase take reserved on the specified input.
        (lp, take, to, full) = _quote(taxed, true, -1e20);
        assertEq(take, BUY);
        assertEq(to, tax.BUY_TO());
        (credited, fee) = _leg(true, -1e20);
        assertEq(credited, 1e20 * uint256(take) / PIPS, "the quoted pips of the specified input");
        assertEq(fee, lp, "the quoted LP fee");
        vm.revertToState(snap);

        // Exact-output buy: the take grossed up on the quote that filled.
        (lp, take, to, full) = _quote(taxed, true, 1e20);
        assertEq(take, BUY);
        (credited, fee) = _leg(true, 1e20);
        uint256 actual = uint256(-legEx.last0()) - credited;
        assertEq(credited, actual * PIPS / (PIPS - take) - actual, "the quoted gross-up");
        assertEq(fee, lp, "the quoted LP fee");
        vm.revertToState(snap);

        // Exact-output sell: the reserve on the specified output.
        (lp, take, to, full) = _quote(taxed, false, 1e20);
        assertEq(take, SELL);
        assertEq(to, tax.SELL_TO());
        (credited, fee) = _leg(false, 1e20);
        assertEq(credited, (1e20 * uint256(take) + (PIPS - take) - 1) / (PIPS - take), "the quoted reserve");
        assertEq(fee, lp, "the quoted LP fee");
    }

    /// On a pool without an advisory it answers the base fee and no take.
    function test_quoteLegOnAPoolWithoutAnAdvisory() public {
        PoolKey memory plain = _plainPool();
        (uint24 lp, uint24 take, address to, bool full) = _quote(plain, false, -1e20);
        assertEq(abi.encode(lp, take, to, full), abi.encode(BASE_FEE, uint24(0), address(0), false));
    }

    /// It reverts with the error the leg is refused with: a refusal, a strict advisory that fails, an answer the root
    /// refuses and a take over the cap.
    function test_quoteLegRefusesAsTheLegIsRefused() public {
        tax.set(BUY, SELL);
        uint256 snap = vm.snapshotState();
        tax.setRefuseFor(address(legEx));
        _refusedBoth(abi.encodeWithSelector(IHookrRootState.SwapRejected.selector));
        vm.revertToState(snap);
        tax.setBurn(150_000, address(legEx));
        _refusedBoth(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallFailed.selector, address(tax), IHookrAdvisory.beforeSwap.selector
            )
        );
        vm.revertToState(snap);
        tax.setMalformFor(address(legEx));
        _refusedBoth(abi.encodeWithSelector(IHookrRootEvents.InvalidModuleResult.selector, address(tax)));
        vm.revertToState(snap);
        // 60,000 pips in each phase of an exact-input sell: 120,000 over the admitted 100,000.
        tax.set(BUY, 60_000);
        tax.setDoubleSell(true);
        _refusedBoth(abi.encodeWithSelector(IHookrRootState.AggregateCapExceeded.selector));
    }

    /// @dev The quote of an exact-input sell of 1e19 reverts with `reason`, and the same leg is refused with it.
    function _refusedBoth(bytes memory reason) internal {
        vm.prank(address(legEx));
        vm.expectRevert(reason);
        root.quoteLeg(taxed, SwapParams(false, -1e19, HI - 1), 1, 1);
        _runLeg(taxed, taxed, false, false, -1e19);
        assertEq(legEx.legs(), 0, "the leg was refused");
        assertEq(_innerReason(legEx.lastError()), reason, "with the same error");
    }

    /// It writes nothing and answers under staticcall.
    function test_quoteLegWritesNothing() public {
        tax.set(BUY, SELL);
        vm.prank(address(legEx));
        (bool ok, bytes memory out) = address(root)
            .staticcall(abi.encodeCall(IHookrLaneRoot.quoteLeg, (taxed, SwapParams(false, -1e20, HI - 1), 1, 1)));
        assertTrue(ok, "answers under staticcall");
        (, uint24 take,,,) = abi.decode(out, (uint24, uint24, address, bool, bool));
        assertEq(take, SELL);
    }

    /// A buy leg during the launch guard takes the trader's whole path, which `fullPath` says; a sell leg and a buy leg
    /// after the guard do not.
    function test_quoteLegFullPathOnGuardBuy() public {
        HookrTypes.RulesConfig memory r = _laneRules(false);
        r.guardEndBlock = uint40(vm.getBlockNumber() + 10);
        r.snipeTaxPips = 300_000;
        r.maxBuyQuoteAmount = 1e22;
        PoolKey memory guarded = _launchPool(address(tax), BOTH, false, r, _recaptureOnlyRc());
        (,,, bool full) = _quote(guarded, true, -1e18);
        assertTrue(full, "a guarded buy leg takes the full path");
        (,,, full) = _quote(guarded, false, -1e18);
        assertFalse(full, "a sell leg does not");
        vm.roll(vm.getBlockNumber() + 10);
        (,,, full) = _quote(guarded, true, -1e18);
        assertFalse(full, "nor a buy leg after the guard");
    }

    /// `quoteLeg` is the root's own function and does not shadow any of the lane surface the root serves through its
    /// fallback; `settleLeg` (0x4f735c09) is not one of HookrRules' own functions, so the Rules' fallback routes it
    /// to HookrRecapture. It reads each compiled ABI once, with gas metering paused: the artifacts carry their file's
    /// AST (`ast = true`), several megabytes each, and what this checks is the dispatch, not its gas.
    function test_rootSelectorsDoNotShadowTheLane() public {
        vm.pauseGasMetering();
        bytes4 q = IHookrLaneRoot.quoteLeg.selector;
        assertEq(q, bytes4(0xba835629));
        bytes4[5] memory lane = [
            IHookrLaneRoot.settleRecapture.selector,
            IHookrLaneRoot.laneOf.selector,
            IHookrLaneRoot.sameTxLiquidityOnPath.selector,
            IHookrLaneRoot.sweepClaims.selector,
            IHookrLaneRoot.laneModule.selector
        ];
        for (uint256 i; i < lane.length; ++i) {
            assertTrue(lane[i] != q, "quoteLeg shadows a lane function");
        }
        bytes4[] memory root = _selectors("HookrRoot");
        assertTrue(_has(root, q), "the root's own function");
        for (uint256 i; i < lane.length; ++i) {
            assertFalse(_has(root, lane[i]), "the root's dispatcher shadows a lane function");
        }
        bytes4 s = IHookrLaneRules.settleLeg.selector;
        assertEq(s, bytes4(0x4f735c09));
        assertFalse(_has(_selectors("HookrRules"), s), "settleLeg is not HookrRules' own");
        assertTrue(_has(_selectors("HookrRecapture"), s), "HookrRecapture serves it");
    }

    /// @dev The selectors of the compiled contract's own ABI, read from its artifact.
    function _selectors(string memory name) internal view returns (bytes4[] memory selectors) {
        string memory json = vm.readFile(string.concat("out/", name, ".sol/", name, ".json"));
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        selectors = new bytes4[](sigs.length);
        for (uint256 i; i < sigs.length; ++i) {
            selectors[i] = bytes4(keccak256(bytes(sigs[i])));
        }
    }

    /// @dev Whether `selectors` holds `selector`.
    function _has(bytes4[] memory selectors, bytes4 selector) internal pure returns (bool) {
        for (uint256 i; i < selectors.length; ++i) {
            if (selectors[i] == selector) return true;
        }
        return false;
    }
}

/// @notice quoteLeg's amounts are the pool's own swap delta, and without them the after phase is flagged as skipped.
contract QuoteLegAmountsTest is LegTaxFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint24 internal constant BUY = 10_000;
    uint24 internal constant SELL = 20_000;

    PoolKey internal taxed;

    function setUp() public {
        _setUpLegTax();
        taxed = _taxedPool();
        _nextBlock();
    }

    // ───────────── the after phase's amounts (EX-1) ─────────────

    /// @dev A before-phase leg of `amount` on `key` beside a 1e18 buy there; returns the take credited to the
    ///      DeltaAdvisory's recipient beyond the buy's own, and the pool's own swap delta from the leg's `Swap` event.
    function _deltaLeg(DeltaAdvisory d, PoolKey memory key, bool zeroForOne, int256 amount)
        internal
        returns (uint256 credited, int128 e0, int128 e1)
    {
        uint256 c0 = rules.claimable(ETH, d.TO());
        legEx.clear();
        legEx.add(false, key, zeroForOne, amount, zeroForOne ? LO + 1 : HI - 1, 0);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(legEx.legs(), 1, "the leg ran");
        credited = rules.claimable(ETH, d.TO()) - c0 - 1e18 * uint256(d.beforeTake()) / PIPS;
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == swapTopic
                    && address(uint160(uint256(logs[i].topics[2]))) == address(legEx)
            ) (e0, e1) = abi.decode(logs[i].data, (int128, int128));
        }
    }

    /// @dev The take a leg of each shape pays on `take` pips: 0 exact-input sell (gross quote out `e0`), 1 exact-input
    ///      buy of 1e20, 2 exact-output buy (the quote that filled, `-e0`), 3 exact-output sell of 1e20.
    function _takeOf(uint256 shape, uint256 take, int128 e0) internal pure returns (uint256) {
        if (shape == 0) return uint256(uint128(e0)) * take / PIPS;
        if (shape == 1) return 1e20 * take / PIPS;
        if (shape == 2) {
            uint256 q = uint256(uint128(-e0));
            return q * PIPS / (PIPS - take) - q;
        }
        return (1e20 * take + (PIPS - take) - 1) / (PIPS - take);
    }

    /// quoteLeg's amounts are the pool's own swap delta, the one the root's afterSwap receives and the PoolManager's
    /// `Swap` event carries, not what `PoolManager.swap` returns to the executor. For each shape, against an advisory
    /// whose after-phase answer depends on the exact amounts: the event and the executor's delta differ as the
    /// documented relation says, the quote on the event's amounts equals the leg's take to the wei, and a quote on the
    /// executor's own delta is refused by an advisory that checks its amounts, where the leg is not.
    function test_quoteLegTakesThePoolsOwnSwapDelta() public {
        DeltaAdvisory d = new DeltaAdvisory();
        _admit(address(d), 50_000, 100_000, BOTH, false);
        PoolKey memory pool = _launchPool(address(d), BOTH, false, _laneRules(false), _recaptureOnlyRc());
        _nextBlock();
        uint256 t = 10_000;
        d.set(uint24(t));
        bool[4] memory z = [false, true, true, false];
        int256[4] memory amt = [int256(-1e20), int256(-1e20), int256(1e20), int256(1e20)];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 4; ++i) {
            vm.revertToState(snap);
            (uint256 credited, int128 e0, int128 e1) = _deltaLeg(d, pool, z[i], amt[i]);
            (int256 n0, int256 n1) = (legEx.last0(), legEx.last1());
            if (i == 0) {
                assertEq(e1, -1e20, "exact-input sell: the specified side is -A");
                assertEq(n0, int256(e0) - int256(credited), "the executor gets the gross quote out less the take");
            } else if (i == 1) {
                assertEq(e0, -int128(int256(1e20 - 1e20 * t / PIPS)), "exact-input buy: -(A - floor(A t / 1e6))");
                assertEq(n0, -1e20, "the executor spends A");
                assertEq(n1, e1);
            } else if (i == 2) {
                assertEq(e1, 1e20, "exact-output buy: the specified side is Q");
                assertEq(n0, int256(e0) - int256(credited), "the executor pays the quote that filled and the take");
            } else {
                assertEq(
                    e0, int128(int256(1e20 + (1e20 * t + (PIPS - t) - 1) / (PIPS - t))), "Q + ceil(Q t / (1e6 - t))"
                );
                assertEq(n0, 1e20, "the executor nets Q");
                assertEq(n1, e1);
            }
            vm.revertToState(snap);
            SwapParams memory p = SwapParams(z[i], amt[i], z[i] ? LO + 1 : HI - 1);
            vm.prank(address(legEx));
            (, uint24 take,,, bool skipped, bool preSwap) = root.quoteLeg(pool, p, e0, e1);
            assertFalse(skipped, "the after phase was asked");
            assertTrue(preSwap, "on the state before the swap");
            assertEq(_takeOf(i, take, e0), credited, "the quote on the pool's delta is the leg's take");
            // Without amounts the after phase is not asked, and the flag says so.
            vm.prank(address(legEx));
            (, take,,, skipped, preSwap) = root.quoteLeg(pool, p, 0, 0);
            assertTrue(skipped, "the after phase was skipped");
            assertFalse(preSwap, "and not asked");
            assertEq(take, t, "the before phase alone");
            // An advisory that checks its amounts refuses the executor's own delta and passes the pool's, as the leg.
            d.setGuard(true, address(legEx), e0, e1);
            vm.prank(address(legEx));
            vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.InvalidModuleResult.selector, address(d)));
            root.quoteLeg(pool, p, int128(n0), int128(n1));
            vm.prank(address(legEx));
            root.quoteLeg(pool, p, e0, e1);
            (uint256 again,,) = _deltaLeg(d, pool, z[i], amt[i]);
            assertEq(again, credited, "the guarded leg ran and paid the same");
        }
    }

    /// EX-1, the reviewer's case: a 2% sell tax from a size tier the gross quote out reaches and the executor's net
    /// does not. The leg pays 2% of the gross; a quote on the executor's own delta says no take, and one on the pool's
    /// delta says 20,000 pips.
    function test_quoteLegOnTheExecutorsOwnDeltaMisquotesATieredTax() public {
        TieredSellTax t = new TieredSellTax();
        _admit(address(t), 50_000, 100_000, HookrTypes.AFTER_SWAP, false);
        PoolKey memory pool =
            _launchPool(address(t), HookrTypes.AFTER_SWAP, false, _laneRules(false), _recaptureOnlyRc());
        _nextBlock();
        uint256 snap = vm.snapshotState();
        legEx.clear();
        legEx.add(false, pool, false, -1e20, HI - 1, 0);
        _buy(pool, ETH, whale, 1e18);
        uint256 gross = uint256(legEx.last0());
        assertEq(gross, 98_990_199_970_202_949_907, "the untaxed quote out");
        vm.revertToState(snap);
        t.set(gross, 0, 20_000);
        snap = vm.snapshotState();
        legEx.clear();
        legEx.add(false, pool, false, -1e20, HI - 1, 0);
        _buy(pool, ETH, whale, 1e18);
        assertEq(legEx.legs(), 1, "the leg ran");
        uint256 paid = rules.claimable(ETH, t.TO());
        assertEq(paid, gross * 20_000 / PIPS, "2% of the gross");
        (int256 n0, int256 n1) = (legEx.last0(), legEx.last1());
        assertEq(uint256(n0), gross - paid, "the executor's net");
        vm.revertToState(snap);
        SwapParams memory p = SwapParams(false, -1e20, HI - 1);
        vm.prank(address(legEx));
        (, uint24 takeNet,,,,) = root.quoteLeg(pool, p, int128(n0), int128(n1));
        vm.prank(address(legEx));
        (, uint24 takeGross,,,,) = root.quoteLeg(pool, p, int128(int256(gross)), int128(n1));
        assertEq(takeNet, 0, "the executor's own delta misquotes");
        assertEq(takeGross, 20_000, "the pool's delta quotes the take");
    }
}

/// @notice quoteLeg answers only for a pool the caller's swap is a leg on, is exact only inside the frame, and needs
///         gas for both phases' advisory limits.
contract QuoteLegFrameTest is LegTaxFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint24 internal constant BUY = 10_000;
    uint24 internal constant SELL = 20_000;

    PoolKey internal taxed;

    function setUp() public {
        _setUpLegTax();
        taxed = _taxedPool();
        _nextBlock();
    }

    // ───────────── leg eligibility (EX-2) ─────────────

    /// quoteLeg refuses (`NotALeg`) a caller that is not the pool's frozen executor and a pool without a lane, and
    /// inside a frame a pool of another family, where the executor's swap is an ordinary one that pays the pool's
    /// Rules too; inside the frame it answers for the frame's pool. Outside a frame it answers for any lane pool of the
    /// executor: each is a leg in its own family's frames.
    function test_quoteLegRefusesAPoolThatIsNotALeg() public {
        tax.set(TAX, TAX);
        SwapParams memory p = SwapParams(true, -1e19, LO + 1);
        vm.prank(whale);
        vm.expectRevert(IHookrRootState.NotALeg.selector);
        root.quoteLeg(taxed, p, 0, 0);

        HookrTypes.RecaptureConfig memory off;
        PoolKey memory noLane = _launchPool(address(tax), BOTH, false, _laneRules(false), off);
        vm.prank(address(legEx));
        vm.expectRevert(IHookrRootState.NotALeg.selector);
        root.quoteLeg(noLane, p, 0, 0);

        PoolKey memory other = _launchPool(address(tax), BOTH, false, _laneRules(true), _kothRc());
        _nextBlock();
        vm.prank(address(legEx));
        (uint24 lp,,,,,) = root.quoteLeg(other, p, 0, 0);
        assertEq(lp, BASE_FEE, "outside a frame another family's lane pool is quoted as its own frames' leg");

        // Inside the taxed pool's frame the executor's swap on `other` is an ordinary swap: refused.
        uint256 snap = vm.snapshotState();
        legEx.clear();
        legEx.setQuoting(true, 0, 0);
        legEx.add(false, other, true, -1e19, LO + 1, 0);
        _buy(taxed, ETH, whale, 1e18);
        assertEq(legEx.legs(), 1, "the swap ran");
        assertFalse(legEx.quoteOk(), "refused in the frame");
        assertEq(legEx.quoteOut(), abi.encodeWithSelector(IHookrRootState.NotALeg.selector));
        vm.revertToState(snap);

        // On the frame's own pool it answers.
        legEx.clear();
        legEx.setQuoting(true, 0, 0);
        legEx.add(false, taxed, true, -1e19, LO + 1, 0);
        _buy(taxed, ETH, whale, 1e18);
        assertEq(legEx.legs(), 1);
        assertTrue(legEx.quoteOk(), "answered in the frame");
        (, uint24 take,,,) = abi.decode(legEx.quoteOut(), (uint24, uint24, address, bool, bool));
        assertEq(take, TAX);
    }

    /// Inside a frame quoteLeg answers for a lane sibling of the frame's family, and the sibling leg pays the quote in
    /// the sibling's quote.
    function test_quoteLegAnswersForASiblingInTheFrame() public {
        tax.set(TAX, TAX);
        HookrToken subject = _newSubject();
        subject.transfer(address(legEx), 1e26);
        tokenB.approve(address(launcher), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _laneMember(ETH, _laneRules(false), _recaptureOnlyRc());
        members[1] = _laneMember(Currency.wrap(address(tokenB)), _laneRules(false), _recaptureOnlyRc());
        bytes[] memory data = new bytes[](2);
        for (uint256 i; i < 2; ++i) {
            members[i].config.advisory = address(tax);
            members[i].config.advisoryGasLimit = 100_000;
            members[i].config.advisoryPhases = BOTH;
            data[i] = hex"01";
        }
        (bytes32 family,) = launcher.launchAdvised{value: 1e24}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            data,
            vm.getBlockTimestamp()
        );
        PoolKey memory first = launcher.position(family, 0).key;
        PoolKey memory sibling = launcher.position(family, 1).key;
        _nextBlock();
        // An exact-input sell of the subject on the tokenB sibling: its tax is asked after the swap.
        bool quoteIs0 = Currency.unwrap(sibling.currency0) == address(tokenB);
        bool zeroForOne = !quoteIs0;
        legEx.clear();
        legEx.setQuoting(true, 1, 1);
        legEx.add(false, sibling, zeroForOne, -1e19, zeroForOne ? LO + 1 : HI - 1, 0);
        Currency qb = Currency.wrap(address(tokenB));
        uint256 s0 = rules.claimable(qb, tax.SELL_TO());
        _buy(first, ETH, whale, 1e18);
        assertEq(legEx.legs(), 1, "the sibling leg ran");
        assertTrue(legEx.quoteOk(), "the sibling is quoted in the frame");
        (, uint24 take,,, bool skipped) = abi.decode(legEx.quoteOut(), (uint24, uint24, address, bool, bool));
        assertEq(take, TAX);
        assertFalse(skipped);
        uint256 credited = rules.claimable(qb, tax.SELL_TO()) - s0;
        uint256 out = uint256(quoteIs0 ? legEx.last0() : legEx.last1());
        assertEq(credited, (out + credited) * take / PIPS, "the sibling leg paid the quoted take in tokenB");
    }

    // ───────────── eth_call against the frame, and the quote's gas (EX-3) ─────────────

    /// An advisory can tell an `eth_call` quote (the PoolManager locked) from the leg (unlocked). Outside a frame the
    /// quote says no take and the leg pays 10%; a staticcall of quoteLeg inside the frame, right before the leg, says
    /// what the leg pays.
    function test_onlyTheFrameQuoteSeesTheLegsState() public {
        LockAwareTax h = new LockAwareTax(manager);
        _admit(address(h), 50_000, 100_000, HookrTypes.BEFORE_SWAP, false);
        PoolKey memory pool =
            _launchPool(address(h), HookrTypes.BEFORE_SWAP, false, _laneRules(false), _recaptureOnlyRc());
        _nextBlock();
        vm.prank(address(legEx));
        (, uint24 outside,,, bool skipped, bool preSwap) = root.quoteLeg(pool, SwapParams(true, -1e19, LO + 1), 0, 0);
        assertEq(outside, 0, "the eth_call estimate");
        assertFalse(skipped, "a before-only advisory has no after phase to skip");
        assertFalse(preSwap, "nor one to ask");
        legEx.clear();
        legEx.setQuoting(true, 0, 0);
        legEx.add(false, pool, true, -1e19, LO + 1, 0);
        uint256 c0 = rules.claimable(ETH, h.TO());
        _buy(pool, ETH, whale, 1e18);
        assertEq(legEx.legs(), 1);
        assertTrue(legEx.quoteOk());
        (, uint24 inFrame,,,) = abi.decode(legEx.quoteOut(), (uint24, uint24, address, bool, bool));
        assertEq(inFrame, 100_000, "the frame quote");
        uint256 legPaid = rules.claimable(ETH, h.TO()) - c0 - 1e18 * 100_000 / PIPS;
        assertEq(legPaid, 1e19 * uint256(inFrame) / PIPS, "the leg paid the frame quote");
    }

    /// Each phase asked can spend the pool's advisoryGasLimit: with an advisory that spends nearly all of it in both
    /// phases, `2 x (limit + limit / 63) + 60,000` gas answers what an unbounded quote answers; the limit alone does not.
    function test_quoteLegGasCap() public {
        tax.set(BUY, SELL);
        tax.setBurn(85_000, address(legEx));
        SwapParams memory p = SwapParams(false, -1e20, HI - 1);
        vm.prank(address(legEx));
        (uint24 lp, uint24 take, address to,,,) = root.quoteLeg(taxed, p, 1, 1);
        uint256 limit = 100_000;
        uint256 cap = 2 * (limit + limit / 63) + 60_000;
        vm.prank(address(legEx));
        (uint24 lp2, uint24 take2, address to2,,,) = root.quoteLeg{gas: cap}(taxed, p, 1, 1);
        assertEq(abi.encode(lp2, take2, to2), abi.encode(lp, take, to), "the capped quote answers the same");
        vm.prank(address(legEx));
        (bool ok,) = address(root).call{gas: limit}(abi.encodeCall(IHookrLaneRoot.quoteLeg, (taxed, p, 1, 1)));
        assertFalse(ok, "the limit alone does not suffice");
    }
}

/// @notice quoteLeg asks the after phase on the pool's state before the swap, and flags it (`afterPreSwap`): exact for
///         an advisory whose after phase reads the amounts alone, not for one that reads what the swap changes. A trial
///         of the leg inside the frame, a call that swaps and reverts, is the leg's exact outcome for any advisory.
contract QuoteLegAfterStateTest is LegTaxFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpLegTax();
    }

    /// @dev The after-phase leg's pool delta beside a 1e18 buy, from a run where its advisory asks nothing (so the
    ///      executor's delta is the pool's), with the state restored after.
    function _poolDelta(PoolKey memory key, bool zeroForOne, int256 amount) internal returns (int128 d0, int128 d1) {
        uint256 snap = vm.snapshotState();
        legEx.clear();
        legEx.add(true, key, zeroForOne, amount, zeroForOne ? LO + 1 : HI - 1, 0);
        _buy(key, ETH, whale, 1e18);
        assertEq(legEx.legs(), 1, "the unasked leg ran");
        (d0, d1) = (int128(legEx.last0()), int128(legEx.last1()));
        vm.revertToState(snap);
    }

    /// EX-4, a refusal: a band whose after phase refuses a swap ending outside it. Quoted inside the frame, right
    /// before the leg, on the leg's exact pool delta, the after phase is asked at the tick before the swap and passes;
    /// the leg ends past the band and is refused. The quote flags its after phase, and the trial is refused as the leg.
    function test_quoteLegAsksTheAfterPhaseBeforeTheSwap_aBandOnTheEndTick() public {
        BandAdvisory band = new BandAdvisory(manager);
        _admit(address(band), 50_000, 0, BOTH, false);
        PoolKey memory key = _launchPool(address(band), BOTH, false, _laneRules(false), _recaptureOnlyRc());
        _nextBlock();
        (, int24 tick0,,) = manager.getSlot0(key.toId());
        (int128 d0, int128 d1) = _poolDelta(key, true, -3e23);

        band.setBand(tick0 - 953, tick0 + 953);
        legEx.clear();
        legEx.setQuoting(true, d0, d1);
        legEx.setTrying(true);
        legEx.add(true, key, true, -3e23, LO + 1, 0);
        _buy(key, ETH, whale, 1e18);
        assertTrue(legEx.quoteOk(), "the in-frame quote on the exact delta passes");
        (,,,, bool skipped, bool preSwap) = abi.decode(legEx.quoteOut(), (uint24, uint24, address, bool, bool, bool));
        assertFalse(skipped, "the after phase was asked");
        assertTrue(preSwap, "on the state before the swap, and flagged");
        assertEq(legEx.legs(), 0, "the leg is refused");
        assertEq(_inner(legEx.lastError()), IHookrRootEvents.InvalidModuleResult.selector, "after the swap");
        assertEq(legEx.trialOut(), legEx.lastError(), "the trial is refused with the leg's error");
    }

    /// EX-4, a take: a 2% sell tax charged after the swap only when it ends above a tick. Quoted inside the frame on
    /// the leg's exact pool delta it says no take, flagged; the leg pays 2% of its gross quote out, and the trial
    /// returns the leg's own delta, net of that take.
    function test_quoteLegAsksTheAfterPhaseBeforeTheSwap_aTaxOnTheEndTick() public {
        EndTickSellTax t = new EndTickSellTax(manager);
        _admit(address(t), 50_000, 100_000, BOTH, false);
        PoolKey memory key = _launchPool(address(t), BOTH, false, _laneRules(false), _recaptureOnlyRc());
        _nextBlock();
        (, int24 tick0,,) = manager.getSlot0(key.toId());
        (int128 d0, int128 d1) = _poolDelta(key, false, -1e23);

        t.setEdge(tick0 + 100);
        legEx.clear();
        legEx.setQuoting(true, d0, d1);
        legEx.setTrying(true);
        legEx.add(true, key, false, -1e23, HI - 1, 0);
        uint256 c0 = rules.claimable(ETH, t.TO());
        _buy(key, ETH, whale, 1e18);
        assertEq(legEx.legs(), 1, "the leg ran");
        assertTrue(legEx.quoteOk());
        (, uint24 take,,, bool skipped, bool preSwap) =
            abi.decode(legEx.quoteOut(), (uint24, uint24, address, bool, bool, bool));
        assertFalse(skipped);
        assertTrue(preSwap, "flagged");
        assertEq(take, 0, "the in-frame quote on the exact delta says no take");
        (, int24 tick1,,) = manager.getSlot0(key.toId());
        assertGt(tick1, tick0 + 100, "the leg ended past the edge");
        uint256 paid = rules.claimable(ETH, t.TO()) - c0;
        assertEq(paid, uint256(uint128(d0)) * t.PIPS_TAKEN() / PIPS, "the leg paid 2% of its gross quote out");
        assertEq(
            legEx.trialOut(),
            abi.encodeWithSelector(LegExecutor.Trial.selector, int128(legEx.last0()), int128(legEx.last1())),
            "the trial returned the leg's own delta"
        );
    }
}
