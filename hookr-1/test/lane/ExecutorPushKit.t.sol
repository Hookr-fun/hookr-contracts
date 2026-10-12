// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {TwoVenueExecutor} from "./mocks/TwoVenueExecutor.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";

/// @notice Executor push kit. Drives an arb recapture executor's pushes (IHookrLaneRoot.settleRecapture) through real
///         trader swaps on a Hookr pool beside a hookless reference venue, at the partner share WTH's lane runs at
///         (2,500 bps), and checks, for every push, what the Rules record and split:
///         - the push lands as one RecaptureSplit in its currency, whose legs add up to it;
///         - the split's `reportedProfit` is the profit the push reports, push x 10,000 / 7,500 rounded down, the
///           same figure as the root's CorrectionSucceeded (the executor's figure: the kit checks it against what the
///           executor kept);
///         - the protocol takes 25% of that profit, at most the push;
///         - the executor keeps at most its 25% of the profit it realized (`_kitHoldings` measures what it keeps), so
///           the protocol's 25% is of the whole profit: the 25/25 split.
///         Nothing stays at the root and the Rules stay backed to the wei.
/// @dev To run it against another executor, derive from this contract and override `_kitExecutor` (deploy the executor
///      for `address(root)`, pricing the reference venue `_ref(key)`: the pool's pair, 0.3%, spacing 60, no hooks),
///      `_kitHoldings` when its share does not land in `partner`'s ETH or PoolManager ETH claims, and `_kitGasCap` for
///      a lane call above 600,000 gas. The pool is quoted in native ETH, launched with arb recapture and no rule fees,
///      so every protocol credit on it is an arb recapture's.
abstract contract ExecutorPushKit is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @dev WTH's share of each arb recapture's realized profit, the rate the kit opens the lane at.
    uint16 internal constant KIT_PARTNER_BPS = 2_500;

    address internal kitExecutor;
    PoolKey internal kitKey;
    PoolKey internal kitRef;

    /// @dev One frame's pushes, as the Rules split them and the root reported them.
    struct KitFrame {
        uint256 pushes;
        uint256 pushed;
        uint256 protocol;
        uint256 kept;
        uint256 realized;
    }

    function setUp() public virtual {
        _setUpLane();
        kitExecutor = _kitExecutor();
        _openLane(kitExecutor, _kitGasCap(), KIT_PARTNER_BPS);
        kitKey = _openRecapture(ETH);
        kitRef = _seedReference(kitKey);
        _nextBlock();
    }

    /// @dev The executor under test, built for `address(root)` and the reference venue `_ref(key)`.
    function _kitExecutor() internal virtual returns (address);

    /// @dev The lane call's gas cap the kit opens the lane at: the fixture's 600,000 by default. An executor that
    ///      needs more (WTH runs at 3,000,000) overrides it.
    function _kitGasCap() internal view virtual returns (uint32) {
        return LANE_GAS;
    }

    /// @dev Everything the executor's kept share can land in, in the pool's quote (native ETH): by default `partner`'s
    ///      balance and PoolManager ETH claims. The kit reads its change across a swap as what the executor kept.
    function _kitHoldings() internal view virtual returns (uint256) {
        return partner.balance + manager.balanceOf(partner, ETH.toId());
    }

    /// @dev Moves the kit pool's reference venue to `priceWad` (subject per ETH, 1e18 = 1).
    function _kitReference(uint256 priceWad) internal {
        _kitReferenceOf(kitRef, priceWad);
    }

    /// @dev Moves reference venue `ref` to `priceWad` with an unauthenticated swap.
    function _kitReferenceOf(PoolKey memory ref, uint256 priceWad) internal {
        uint160 target = uint160(Math.sqrt(priceWad * 1e18) * (1 << 96) / 1e18);
        (uint160 current,,,) = manager.getSlot0(ref.toId());
        if (current == target) return;
        mover.directSwap(ref, current > target, -int256(1e26), target);
    }

    /// @dev Runs a trader swap on the kit pool and checks every push of its frames; returns what they added up to.
    function _kitSwap(bool buy, uint256 amount) internal returns (KitFrame memory f) {
        f = _kitMeasure(kitKey, buy, amount);
        if (f.pushes != 0) {
            // The executor kept at most its 25% of what it realized (a unit of rounding a push), so the push carries
            // the rest and the protocol's 25% is of the whole profit (two units of rounding a push).
            assertGe(
                f.pushed * 10_000 + f.pushes * 10_000, f.realized * (10_000 - KIT_PARTNER_BPS), "partner kept <= 25%"
            );
            assertGe(
                f.protocol * 10_000 + 2 * f.pushes * 10_000, f.realized * PROTOCOL_BPS, "protocol took 25% of profit"
            );
        }
    }

    /// @dev Runs a trader swap on pool `key` and checks every push of its frames and what stays behind, and returns
    ///      what the pushes added up to and what the executor kept (`_kitHoldings`), without judging the keep.
    function _kitMeasure(PoolKey memory key, bool buy, uint256 amount) internal returns (KitFrame memory f) {
        uint256 holdings = _kitHoldings();
        uint256 hookr = rules.claimable(ETH, protocol);
        vm.recordLogs();
        if (buy) _buy(key, ETH, whale, amount);
        else _sell(key, ETH, whale, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        f = _kitCheckPushes(key, logs);
        f.kept = _kitHoldings() - holdings;
        f.realized = f.kept + f.pushed;
        assertEq(rules.claimable(ETH, protocol) - hookr, f.protocol, "the protocol's claim grew by its split legs");
        assertEq(manager.balanceOf(address(root), ETH.toId()), 0, "nothing stays at the root");
        assertTrue(rules.accountingInvariant(ETH), "the Rules stay backed");
        assertEq(manager.balanceOf(address(rules), ETH.toId()), rules.totalLiability(ETH), "backed to the wei");
    }

    /// @dev Pairs each Rules RecaptureSplit with the root's CorrectionSucceeded that follows it for the same push and
    ///      checks the pair.
    function _kitCheckPushes(PoolKey memory key, Vm.Log[] memory logs) internal view returns (KitFrame memory f) {
        bytes32 splitTopic = IHookrRecaptureEvents.RecaptureSplit.selector;
        bool open;
        uint256 legs;
        uint256 splitProtocol;
        uint256 splitProfit;
        Currency splitCurrency;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter == address(rules) && l.topics[0] == splitTopic) {
                assertFalse(open, "a split without its push");
                assertEq(PoolId.unwrap(PoolId.wrap(l.topics[1])), PoolId.unwrap(key.toId()), "split on the pool");
                (uint256 tr, uint256 lp, uint256 pot, uint256 pro, Currency c, uint256 reported) =
                    abi.decode(l.data, (uint256, uint256, uint256, uint256, Currency, uint256));
                (open, legs, splitProtocol, splitProfit, splitCurrency) = (true, tr + lp + pot + pro, pro, reported, c);
            } else if (l.emitter == address(root) && l.topics[0] == SUCCEEDED) {
                (uint256 profit, uint256 pushed, Currency c) = abi.decode(l.data, (uint256, uint256, Currency));
                if (pushed == 0) {
                    assertFalse(open, "a split without a push");
                    continue;
                }
                assertTrue(open, "every push is split");
                open = false;
                assertEq(Currency.unwrap(c), Currency.unwrap(splitCurrency), "split in the push's currency");
                assertEq(Currency.unwrap(c), Currency.unwrap(ETH), "the kit's executor pushes in the quote");
                assertEq(legs, pushed, "the split's legs add up to the push");
                assertEq(splitProfit, profit, "the split reports the root's profit");
                assertEq(splitProfit, pushed * 10_000 / (10_000 - KIT_PARTNER_BPS), "the push at 25%, rounded down");
                uint256 cut = splitProfit * PROTOCOL_BPS / 10_000;
                assertEq(splitProtocol, cut < pushed ? cut : pushed, "the protocol's 25% of the reported profit");
                ++f.pushes;
                f.pushed += pushed;
                f.protocol += splitProtocol;
            }
        }
        assertFalse(open, "the last split has its push");
    }

    /// A trader buy while the reference prices the subject 3% cheaper: the executor's before-phase frame buys it there
    /// and sells it into the pool, and every push is split at the profit it reports, 25/25.
    function test_kit_buyFramePushesSplitTwentyFiveTwentyFive() public {
        _kitReference(1.03e18);
        KitFrame memory f = _kitSwap(true, 1e15);
        assertGt(f.pushes, 0, "the executor pushed");
    }

    /// A trader sell while the reference prices the subject 3% dearer: the frame runs the other way, same checks.
    function test_kit_sellFramePushesSplitTwentyFiveTwentyFive() public {
        _kitReference(0.97e18);
        KitFrame memory f = _kitSwap(false, 1e15);
        assertGt(f.pushes, 0, "the executor pushed");
    }

    /// A trader buy large enough to carry the pool past the reference: frames in both phases, each push checked.
    function test_kit_bothPhasesPushSplitTwentyFiveTwentyFive() public {
        _kitReference(1.02e18);
        KitFrame memory f = _kitSwap(true, 6e22);
        assertGt(f.pushes, 1, "pushes in both phases");
    }

    /// Repeated swaps both ways around a moving reference: every push of every frame checked, the claims stay backed.
    function test_kit_aSequenceOfFramesStaysTwentyFiveTwentyFive() public {
        uint256[4] memory prices = [uint256(1.025e18), 0.98e18, 1.04e18, 0.99e18];
        for (uint256 i; i < prices.length; ++i) {
            _kitReference(prices[i]);
            _kitSwap(i % 2 == 0, 3e15);
            _nextBlock();
        }
    }

    /// With the reference at the pool's price there is nothing to recapture: no push, no split, no protocol credit,
    /// and the trader's swap completes.
    function test_kit_noOpportunityNoPush() public {
        (uint160 price,,,) = manager.getSlot0(kitKey.toId());
        (uint160 ref,,,) = manager.getSlot0(kitRef.toId());
        assertEq(price, ref, "aligned venues");
        KitFrame memory f = _kitSwap(true, 1e15);
        assertEq(f.pushes, 0);
        assertEq(f.kept, 0);
    }
}

/// @notice The kit against the lab's partner-shaped stand-in (TwoVenueExecutor) at WTH's 2,500 bps: on top of the kit's
///         checks, the stand-in's own ArbRecaptured event gives each frame's realized profit, so every push is checked
///         exactly: the stand-in keeps floor(25% x profit), pushes the rest, and the split reports the profit or one
///         unit more (the push's read-back rounds down on the larger push).
contract ExecutorPushKitTest is ExecutorPushKit {
    function _kitExecutor() internal override returns (address) {
        TwoVenueExecutor standIn =
            new TwoVenueExecutor(manager, address(root), partner, KIT_PARTNER_BPS, 3000, 60, address(0), 1e22);
        return address(standIn);
    }

    function test_kit_standInPushesExactlyTheRestOfItsProfit() public {
        _kitReference(1.03e18);
        vm.recordLogs();
        _buy(kitKey, ETH, whale, 1e15);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 checked;
        uint256 profit;
        uint256 kept;
        uint256 pushed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == kitExecutor && logs[i].topics[0] == TwoVenueExecutor.ArbRecaptured.selector) {
                uint256 quoteIn;
                uint256 quoteOut;
                (, quoteIn, quoteOut, kept, pushed) =
                    abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256));
                profit = quoteOut - quoteIn;
                assertEq(kept, profit * KIT_PARTNER_BPS / 10_000, "the stand-in keeps floor(25%)");
                assertEq(pushed, profit - kept, "and pushes the rest");
            } else if (
                logs[i].emitter == address(rules) && logs[i].topics[0] == IHookrRecaptureEvents.RecaptureSplit.selector
            ) {
                (,,, uint256 pro,, uint256 reported) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, Currency, uint256));
                assertGt(profit, 0, "the split follows the stand-in's frame");
                assertGe(reported, profit, "the reported profit covers what the stand-in realized");
                assertLe(reported, profit + 1, "or one unit more");
                assertEq(pro, reported * PROTOCOL_BPS / 10_000, "the protocol's 25%");
                (profit, kept, pushed) = (0, 0, 0);
                ++checked;
            }
        }
        assertGt(checked, 0, "a stand-in push was checked");
    }

    /// The kit's 25/25 check has teeth: the same stand-in keeping 30% on a lane pinned at 25% pushes too little, so
    /// the profit the Rules read back from its push, and the protocol's 25% of it, fall short of the profit it realized
    /// by more than the check's rounding allowance.
    function test_kit_refusesAnExecutorThatKeepsMore() public {
        TwoVenueExecutor greedy =
            new TwoVenueExecutor(manager, address(root), partner, 3_000, 3000, 60, address(0), 1e22);
        _openLane(address(greedy), _kitGasCap(), KIT_PARTNER_BPS);
        PoolKey memory key = _openRecapture(ETH);
        PoolKey memory ref = _seedReference(key);
        _nextBlock();
        _kitReferenceOf(ref, 1.03e18);
        KitFrame memory f = _kitMeasure(key, true, 1e15);
        assertGt(f.pushes, 0, "the executor pushed");
        assertLt(
            f.pushed * 10_000 + f.pushes * 10_000, f.realized * (10_000 - KIT_PARTNER_BPS), "fails partner kept <= 25%"
        );
        assertLt(
            f.protocol * 10_000 + 2 * f.pushes * 10_000, f.realized * PROTOCOL_BPS, "fails protocol took 25% of profit"
        );
    }
}
