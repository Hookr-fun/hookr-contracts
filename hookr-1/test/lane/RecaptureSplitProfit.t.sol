// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";

/// @notice RecaptureSplit carries the profit each push reports (`reportedProfit`), the figure the Rules take the
///         protocol's 25% of: the push at the pool's frozen partner share, push x 10,000 / (10,000 - partnerBps)
///         rounded down, the same figure as the root's CorrectionSucceeded for that push. It is the executor's figure,
///         not a measurement: Hookr never sees the arbitrage's real profit or the share the partner kept. An indexer
///         that reads only the Rules' events can check every split: its legs, what Hookr paid, add up to the push, and
///         its protocol leg is 25% of `reportedProfit`, at most the push. The field changed the event's topic0: the
///         new and the old one are pinned below.
contract RecaptureSplitProfitTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    bytes32 internal constant SPLIT_TOPIC =
        keccak256("RecaptureSplit(bytes32,address,uint256,uint256,uint256,uint256,address,uint256)");
    /// @dev The event before it carried the profit, which no Rules log may carry any more.
    bytes32 internal constant UNPROFITED_SPLIT_TOPIC =
        keccak256("RecaptureSplit(bytes32,address,uint256,uint256,uint256,uint256,address)");

    ScriptedExecutor internal exec;
    PoolKey internal key;

    struct Split {
        PoolId id;
        address trader;
        uint256 traderAmount;
        uint256 lp;
        uint256 pot;
        uint256 protocol;
        Currency currency;
        uint256 reportedProfit;
    }

    struct Push {
        uint8 phase;
        uint256 reportedProfit;
        uint256 pushed;
        Currency currency;
    }

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e30);
        exec.setRoot(address(root));
        _openLane(address(exec));
        key = _openKoth(ETH);
    }

    /// @dev Every Rules RecaptureSplit in `logs`, in order, decoded in full.
    function _splitsIn(Vm.Log[] memory logs) internal view returns (Split[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(rules) && logs[i].topics[0] == SPLIT_TOPIC) ++n;
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != UNPROFITED_SPLIT_TOPIC, "no old split");
        }
        out = new Split[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rules) || logs[i].topics[0] != SPLIT_TOPIC) continue;
            Split memory s = out[n++];
            s.id = PoolId.wrap(logs[i].topics[1]);
            s.trader = address(uint160(uint256(logs[i].topics[2])));
            (s.traderAmount, s.lp, s.pot, s.protocol, s.currency, s.reportedProfit) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, Currency, uint256));
            assertEq(logs[i].data.length, 6 * 32, "six data words");
        }
    }

    /// @dev Every root CorrectionSucceeded with a push in `logs`, in order.
    function _pushesIn(Vm.Log[] memory logs) internal view returns (Push[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(root) || logs[i].topics[0] != SUCCEEDED) continue;
            (, uint256 pushed,) = abi.decode(logs[i].data, (uint256, uint256, Currency));
            if (pushed != 0) ++n;
        }
        out = new Push[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(root) || logs[i].topics[0] != SUCCEEDED) continue;
            (uint256 profit, uint256 pushed, Currency c) = abi.decode(logs[i].data, (uint256, uint256, Currency));
            if (pushed == 0) continue;
            out[n++] = Push(uint8(uint256(logs[i].topics[2])), profit, pushed, c);
        }
    }

    /// @dev Each split against the push it splits (the Rules emit the split, then the root its CorrectionSucceeded):
    ///      the same currency, legs adding up to the push, the root's read-back profit at `partnerBps`, and the
    ///      protocol's 25% of it, at most the push.
    function _checkPairs(Split[] memory splits, Push[] memory pushes, uint16 partnerBps) internal pure {
        assertEq(splits.length, pushes.length, "one split per push");
        for (uint256 i; i < splits.length; ++i) {
            Split memory s = splits[i];
            Push memory p = pushes[i];
            assertEq(Currency.unwrap(s.currency), Currency.unwrap(p.currency), "the split's currency is the push's");
            assertEq(s.traderAmount + s.lp + s.pot + s.protocol, p.pushed, "the legs add up to the push");
            assertEq(s.reportedProfit, p.reportedProfit, "the split reports the root's profit");
            assertEq(s.reportedProfit, p.pushed * 10_000 / (10_000 - partnerBps), "the push at the pinned share");
            uint256 cut = s.reportedProfit * PROTOCOL_BPS / 10_000;
            assertEq(s.protocol, cut < p.pushed ? cut : p.pushed, "the protocol's 25% of the reported profit");
        }
    }

    /// The event's topic0 with the profit and the one before it, as the build artifacts give them: an indexer that
    /// filters RecaptureSplit on the old topic sees nothing from this release until it moves to the new one.
    function test_split_topicsPinned() public pure {
        assertEq(SPLIT_TOPIC, 0x48b0be8c256a9fedca8f3dead0058317e9e6c6f2a7bee2b7ee5c7e8436b70364, "new");
        assertEq(UNPROFITED_SPLIT_TOPIC, 0x8cefb93b0c12d225ac4a6c4a10fc4aec51f69fa4f9b5f2de2156550ebe7f909c, "old");
        assertEq(IHookrRecaptureEvents.RecaptureSplit.selector, SPLIT_TOPIC, "the interface's event");
        assertEq(IHookrRecaptureEvents.RecaptureSplit.selector, SPLIT_TOPIC, "the module's event");
    }

    /// The event's signature carries the profit last, after the currency, so the first five data words keep their
    /// places; the module and the interface declare the same event.
    function test_split_signatureCarriesTheProfitLast() public {
        assertEq(IHookrRecaptureEvents.RecaptureSplit.selector, SPLIT_TOPIC);
        assertEq(IHookrRecaptureEvents.RecaptureSplit.selector, SPLIT_TOPIC, "the module emits the interface's event");
        exec.set(ScriptedExecutor.Mode.PUSH, 1e18);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        Split[] memory splits = _splitsIn(vm.getRecordedLogs());
        assertEq(splits.length, 2, "a split per phase");
    }

    /// Both phases of a King of the Pool pool: each split reports the profit the root read back from its push at the
    /// pinned share, and the protocol's leg is 25% of it. The after-phase names the trader.
    function test_split_reportsTheProfitTheRootReadBack() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 1e18 + 7);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Split[] memory splits = _splitsIn(logs);
        Push[] memory pushes = _pushesIn(logs);
        _checkPairs(splits, pushes, PARTNER_BPS);
        assertEq(splits.length, 2);
        assertEq(pushes[0].phase, 1, "before");
        assertEq(splits[0].trader, address(0), "the before-phase names no trader");
        assertEq(pushes[1].phase, 2, "after");
        assertEq(splits[1].trader, whale, "the after-phase names the payer");
        assertEq(splits[0].reportedProfit, _profitOf(1e18 + 7));
        assertGt(splits[0].pot, 0, "a King of the Pool pool's pot leg");
        assertEq(_splits(logs).reported, 2 * _profitOf(1e18 + 7), "the fixture's totals carry the profit");
    }

    /// A frame that pushes in two currencies gets a split per currency, each reporting the profit of its own push.
    function test_split_eachCurrencyReportsItsOwnPush() public {
        Currency subject = _subjectOf(key);
        HookrToken(Currency.unwrap(subject)).transfer(address(exec), 1e26);
        exec.setPushCurrency(subject);
        exec.set(ScriptedExecutor.Mode.MIXED, 3e17);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Split[] memory splits = _splitsIn(logs);
        _checkPairs(splits, _pushesIn(logs), PARTNER_BPS);
        assertEq(splits.length, 4, "two currencies in each phase");
        for (uint256 i; i < 4; ++i) {
            assertEq(splits[i].reportedProfit, _profitOf(3e17), "each push's own profit");
            assertEq(Currency.unwrap(splits[i].currency), Currency.unwrap(i % 2 == 0 ? ETH : subject));
            // Outside the quote the trader and pot shares join the LP share.
            if (i % 2 == 1) assertEq(splits[i].traderAmount + splits[i].pot, 0);
        }
    }

    /// Pushes in one currency add up within a frame: one split of their sum, reporting the profit of the sum.
    function test_split_pushesInOneCurrencyReportTheirSum() public {
        exec.set(ScriptedExecutor.Mode.PUSH_LEG_PUSH, 5e17 + 1);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Split[] memory splits = _splitsIn(logs);
        _checkPairs(splits, _pushesIn(logs), PARTNER_BPS);
        assertEq(splits.length, 2, "one split per phase");
        assertEq(splits[0].reportedProfit, _profitOf(2 * (5e17 + 1)), "the profit of the summed push");
    }

    /// The profit follows the pool's frozen partner share, at both ends of the registry's range and between.
    function test_split_followsThePinnedPartnerShare() public {
        uint16[5] memory shares = [uint16(0), 1, 1_500, 2_499, 2_500];
        for (uint256 i; i < shares.length; ++i) {
            _openLane(address(exec), LANE_GAS, shares[i]);
            PoolKey memory k = _openRecapture(ETH);
            (,, uint16 pinned,,,,) = IHookrLaneRoot(address(root)).laneOf(k.toId());
            assertEq(pinned, shares[i]);
            exec.set(ScriptedExecutor.Mode.PUSH, 999_999_999_999_999_999);
            vm.recordLogs();
            _buy(k, ETH, whale, 1e18);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            Split[] memory splits = _splitsIn(logs);
            _checkPairs(splits, _pushesIn(logs), shares[i]);
            assertEq(splits.length, 2);
            assertEq(splits[0].reportedProfit, uint256(999_999_999_999_999_999) * 10_000 / (10_000 - shares[i]));
            _nextBlock();
        }
    }

    /// The Rules report exactly the profit the root passes, whatever it is: the protocol's leg is 25% of it, at most
    /// the push, and the rest splits as configured. Called directly as the root, on a pool without King of the Pool.
    function testFuzz_split_reportsTheProfitItIsGiven(uint256 amount, uint256 profit, uint256 basis) public {
        amount = bound(amount, 1, 1e30);
        profit = bound(profit, 0, 1e34);
        basis = bound(basis, 0, 2e30);
        PoolKey memory k = _openRecapture(ETH);
        uint256 protocolCut = FullMath.mulDiv(profit, PROTOCOL_BPS, 10_000);
        if (protocolCut > amount) protocolCut = amount;
        uint256 rest = amount - protocolCut;
        uint256 part = basis < amount ? basis : amount;
        uint256 toTrader = basis == 0 ? 0 : FullMath.mulDiv(part, rest, amount) * TRADER_BPS / 10_000;
        uint256 before = rules.claimable(ETH, protocol);
        vm.expectEmit(true, true, true, true, address(rules));
        emit IHookrRecaptureEvents.RecaptureSplit(
            k.toId(), whale, toTrader, rest - toTrader, 0, protocolCut, ETH, profit
        );
        vm.prank(address(root));
        _recap().settleRecapture(k, ETH, whale, amount, basis, profit);
        assertEq(rules.claimable(ETH, protocol) - before, protocolCut, "the protocol's claim grew by its leg");
    }
}
