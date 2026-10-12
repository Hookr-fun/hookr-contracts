// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {TwoVenueExecutor} from "./mocks/TwoVenueExecutor.sol";
import {Actor} from "./mocks/Actors.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";

/// @notice The King of the Pool walkthrough end to end on HookrRoot: a creator launches with arb recaptures and King of
///         the Pool on, the lab arbitrage executor recaptures against a hookless reference venue, and the pot pays the
///         epoch's largest buyer.
contract KothWalkthroughTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    bytes32 internal constant RULES_BOUND = keccak256("RulesBound(bytes32,address,bytes32,bytes)");

    TwoVenueExecutor internal arb;
    PoolKey internal key;
    bytes32 internal family;

    function setUp() public {
        _setUpLane();
        arb = _twoVenueExecutor(1e22);
        _openLane(address(arb));
    }

    function _setUpPool() internal {
        (key, family) = _openPoolWithFamily(ETH, _laneRules(true), _kothRc());
        _seedReference(key);
    }

    /// Steps 1 and 2: the creator switches King of the Pool on inside recapture and sets the period and split; the
    /// pool freezes them at initialization, publishes the preimage and freezes the root's lane.
    function test_step1_2_creatorTogglesKothWithPeriodAndSplit() public {
        vm.recordLogs();
        _setUpPool();
        PoolId id = key.toId();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory preimage;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(rules) && logs[i].topics[0] == RULES_BOUND) {
                (, preimage) = abi.decode(logs[i].data, (bytes32, bytes));
            }
        }
        (HookrTypes.RulesConfig memory r,, HookrTypes.RecaptureConfig memory c) =
            abi.decode(preimage, (HookrTypes.RulesConfig, HookrTypes.RulesKnobs, HookrTypes.RecaptureConfig));
        assertEq(keccak256(abi.encode(c)), keccak256(abi.encode(_kothRc())), "RulesBound preimage carries the knobs");
        assertEq(r.potBps, POT_BPS);
        (address executor,,,) = _laneOf(key);
        assertEq(executor, address(arb), "the pool froze the root's lane");
        assertEq(_recap().recaptureMode(id), 2);
        (uint64 start, uint64 end, address leader, uint128 amount, uint128 pot) = _recap().hill(id);
        assertEq(start, vm.getBlockTimestamp());
        assertEq(end, vm.getBlockTimestamp() + PERIOD);
        assertEq(leader, address(0));
        assertEq(amount, 0);
        assertEq(pot, 0);
        assertEq(uint256(c.traderBps) + c.lpBps + r.potBps, 10_000);
        assertTrue(root.policyHash(id) != bytes32(0));
    }

    /// Step 3: arbitrage profit fills the pot. The executor keeps the fixture's partner share; of the push the protocol
    /// takes 25% of the profit the push stands for first, then the trader 20%, the pot 40% and the LP accrual the rest.
    function test_step3_recaptureFillsPot() public {
        _setUpPool();
        uint256 partnerBefore = partner.balance;
        vm.recordLogs();
        _buy(key, ETH, whale, 2e22);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        Splits memory t = _splits(logs);
        assertGt(o.pushedAfter, 0, "the arb recapture pushed the Hookr side");
        assertEq(o.succeeded, 1, "one successful arb recapture (after phase)");
        uint256 partnerShare = partner.balance - partnerBefore;
        assertEq(partnerShare, (partnerShare + o.pushedAfter) * PARTNER_BPS / 10_000, "the partner kept WTH's 25%");
        (uint256 pro, uint256 tr, uint256 pot, uint256 lp) =
            _split(o.profitAfter, o.pushedAfter, true, POT_BPS, TRADER_BPS);
        assertEq(t.protocol, pro, "protocol's cut first");
        assertEq(t.trader, tr, "trader leg");
        assertEq(t.pot, pot, "pot leg");
        assertEq(t.lp, lp, "LP leg takes the dust");
        assertEq(_accrued(key), t.lp, "LP leg pending, to be donated to the in-range liquidity from the next block");
        assertEq(t.lastTrader, whale, "trader is the authenticated payer");
        (,,, uint128 potNow) = _hill(key);
        assertEq(potNow, t.pot);
        assertEq(rules.claimable(ETH, whale), t.trader);
        assertTrue(rules.accountingInvariant(ETH));
        assertEq(manager.balanceOf(address(root), ETH.toId()), 0, "root holds no claims");
        // The creator's position earned the swap's LP fees in this block.
        vm.prank(creator);
        (uint256 fees0,) = launcher.withdraw(family, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        assertGt(fees0, 0, "the position earns the swap fees");
        assertEq(_accrued(key), t.lp, "a fee collection never donates");
        // From the next block every add, removal or swap first releases a part of the LP leg (the blocks since the
        // last flush over the pool's release period) to the in-range liquidity (here all the creator's); a full period
        // later all of it is out. The creator collects it with the fees.
        _nextBlock();
        _newActor(key).modify(key, 800_040, 800_100, 1e18);
        _flushAll(key);
        assertEq(_accrued(key), 0, "donated");
        uint256 before = creator.balance;
        vm.prank(creator);
        (uint256 fees,) = launcher.withdraw(family, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        assertGe(fees + 2, t.lp, "the LP leg reaches the family owner as fees");
        assertEq(creator.balance - before, fees);
    }

    /// Step 4: the hook tracks the period's leading buyer on every buy.
    function test_step4_tracksLeadingBuyer() public {
        _setUpPool();
        _buy(key, ETH, minnow, 5e21);
        (, address leader, uint128 amount,) = _hill(key);
        assertEq(leader, minnow);
        assertEq(amount, 5e21);
        _buy(key, ETH, whale, 2e22);
        (, leader, amount,) = _hill(key);
        assertEq(leader, whale, "bigger buy takes the lead");
        assertEq(amount, 2e22);
        _buy(key, ETH, minnow, 1e22);
        (, leader,,) = _hill(key);
        assertEq(leader, whale, "smaller buy does not");
        _buy(key, ETH, minnow, 2e22);
        (, leader,,) = _hill(key);
        assertEq(leader, whale, "a tie does not displace the leader");
        _sell(key, ETH, minnow, 1e21);
        (, leader,,) = _hill(key);
        assertEq(leader, whale, "an unrelated sell in a later transaction leaves the lead");
    }

    /// Step 5: the winner gets the pot credited when the period rolls over, and claims it.
    function test_step5_winnerCreditedOnRollover() public {
        _setUpPool();
        PoolId id = key.toId();
        _buy(key, ETH, whale, 2e22);
        _buy(key, ETH, minnow, 5e21);
        (uint64 start,,, uint128 pot) = _hill(key);
        uint256 prize = uint256(2e22) * 100 / 10_000;
        if (prize > pot) prize = pot;
        uint256 traderLeg = rules.claimable(ETH, whale);
        vm.expectRevert(IHookrRecaptureEvents.EpochOpen.selector);
        _recap().settleEpoch(id);
        vm.warp(uint256(start) + PERIOD);
        vm.expectEmit(true, true, false, true, address(rules));
        emit IHookrRecaptureEvents.KingCrowned(id, whale, prize, start);
        vm.prank(minnow);
        _recap().settleEpoch(id);
        (uint64 next, address leader,, uint128 carried) = _hill(key);
        assertEq(next, start + PERIOD);
        assertEq(leader, address(0));
        assertEq(carried, (pot - prize) / 2);
        assertEq(rules.claimable(ETH, whale), traderLeg + prize);
        uint256 before = whale.balance;
        vm.prank(whale);
        rules.claim(ETH);
        assertEq(whale.balance - before, traderLeg + prize);
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// Step 5, lazy form: the first arb recapture or swap after the period rolls the epoch over without settleEpoch.
    function test_step5_firstSwapAfterPeriodRollsOver() public {
        _setUpPool();
        _buy(key, ETH, whale, 2e22);
        (uint64 start,,, uint128 pot) = _hill(key);
        uint256 traderLeg = rules.claimable(ETH, whale);
        vm.warp(uint256(start) + 3 * PERIOD + 5);
        _buy(key, ETH, minnow, 2e21);
        (uint64 next, address leader, uint128 amount,) = _hill(key);
        assertEq(next, start + 3 * PERIOD, "epochs stay aligned");
        assertEq(leader, minnow, "the rolling buy leads the new epoch");
        assertEq(amount, 2e21);
        uint256 prize = uint256(2e22) * 100 / 10_000;
        assertEq(rules.claimable(ETH, whale) - traderLeg, prize > pot ? pot : prize);
    }

    /// An arb recapture triggered by an unauthenticated caller has no trader: the trader leg joins the LP accrual.
    function test_noTraderJoinsLp() public {
        _setUpPool();
        Actor a = _newActor(key);
        vm.recordLogs();
        a.directSwap(key, true, -2e22, MIN_PRICE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        Splits memory t = _splits(logs);
        assertGt(o.pushedAfter, 0);
        assertEq(t.trader, 0);
        assertEq(t.lastTrader, address(0));
        assertEq(t.lp, o.pushedAfter + o.pushedBefore - t.pot - t.protocol);
        (, address leader,,) = _hill(key);
        assertEq(leader, address(0), "an unauthenticated buy cannot lead");
    }

    /// A creator that opts out launches a pool on the same root without a lane; it runs no arb recapture.
    function test_optedOutPoolOnTheSameRootHasNoLane() public {
        HookrTypes.RecaptureConfig memory off;
        PoolKey memory k = _openPool(Currency.wrap(address(tokenB)), _laneRules(false), off);
        (address executor,,,) = _laneOf(k);
        assertEq(executor, address(0));
        vm.recordLogs();
        _buy(k, Currency.wrap(address(tokenB)), whale, 1e21);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded + o.failed, 0);
        assertTrue(rules.accountingInvariant(Currency.wrap(address(tokenB))));
    }
}
