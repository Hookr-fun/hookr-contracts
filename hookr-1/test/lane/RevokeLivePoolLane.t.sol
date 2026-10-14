// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrModuleBond} from "../../src/interfaces/IHookrModuleBond.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {MockModuleBond} from "../mocks/MockModuleBond.sol";
import {ArbSysKit} from "../kit/ArbSysMock.sol";
import {TwoVenueExecutor} from "./mocks/TwoVenueExecutor.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ReleaseWiring} from "../utils/ReleaseWiring.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice Owner amendment 2 on arb recapture pools: revoking a Rules module's admission, or letting the bond behind it
///         lapse, blocks new binds only and never silently disables a live pool. The root's lane is open at WTH's 2,500
///         bps to the two-venue executor, which keeps 25% of each arb recapture's realized profit; Hookr takes 25% of
///         it. Two live pools bind Rules that pay a HookrTreasury, as the release deploys them, each with a launch
///         guard that locks its principal: King of the Pool on (ETH quote) and off (tokenB quote). Each refuses its
///         principal while locked, then trades both ways with an arb recapture in both phases, the King of the Pool
///         epoch closes and pays its prize, each pool's LP share is released (as the launch position's fees and as the
///         liquidity owner's accrual), each removes its liquidity after its lock, and every claim is paid: the trader's
///         legs and prize, the LP accrual and the protocol's 25% through the treasury to its target. After the revoke,
///         or the lapse, every amount and every balance equals the run without it, no admission is read on any of those
///         paths, and a new pool naming the Rules is refused.
abstract contract RevokeLivePoolLaneFixture is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    bytes32 internal constant SET_ADMISSION_BOND = keccak256("SET_ADMISSION_BOND");
    /// @dev WTH's production share: the share this suite opens the lane at and its stand-in keeps, set here so the
    ///      25/25 split it checks is the one production pays whatever share the other lane suites run at.
    uint16 internal constant WTH_BPS = 2_500;
    /// @dev The treasury's target, to which `collect` forwards what it pulls.
    address internal constant TARGET = address(0x7A7);
    /// @dev Parent blocks each pool's launch guard, and so its principal lock, lasts.
    uint256 internal constant GUARD_BLOCKS = 50;
    /// @dev The whale's buy (quote) and sell (subject) on each pool: about a 4% move, past both venues' fees.
    uint256 internal constant TRADE = 2e22;
    /// @dev Values one `_exercise` records: 9 per trade, 4 trades; 2 for the epoch; 3 per pool's exit; claims of 2
    ///      accounts, collections and liabilities in 4 currencies; balances of 5 holders in 4 currencies.
    uint256 internal constant RECORDED = 4 * 9 + 2 + 2 * 3 + 2 * 4 + 4 + 4 + 5 * 4;

    address internal guardian = address(0x6A7D);
    HookrTreasury internal treasury;
    /// @dev Rules that pay the HookrTreasury, at the release's 2,000 bps protocol share floor.
    HookrRules internal paid;
    MockModuleBond internal bond;
    TwoVenueExecutor internal arb;
    bytes32 internal kothFamily;
    bytes32 internal recapFamily;
    PoolKey internal kothKey;
    PoolKey internal recapKey;

    /// @dev Whether the Rules' admission carries a bond, attached through the timelock before the pools launch.
    function _bonded() internal pure virtual returns (bool);

    function setUp() public {
        _setUpLane();
        treasury = new HookrTreasury(address(this), TARGET, manager);
        paid = new HookrRules(manager, registry, address(treasury), address(root), _minProtocolShareBps());
        IHookrRegistry.Admission memory a = ReleaseWiring.rulesAdmission(paid, 200_000);
        ReleaseWiring.queueAdmission(registry, address(root), a);
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardian));
        ReleaseWiring.waitDelay(registry);
        ReleaseWiring.admit(registry, address(root), a);
        registry.setGuardian(guardian);
        treasury.admitSource(address(paid));
        if (_bonded()) {
            bond = new MockModuleBond();
            bond.setCovered(address(root), address(paid), true);
            registry.queue(SET_ADMISSION_BOND, abi.encode(address(root), address(paid), address(bond)));
            vm.warp(vm.getBlockTimestamp() + registry.delay());
            registry.pinModuleBondFor(address(root), address(paid), address(bond));
        }
        arb = new TwoVenueExecutor(manager, address(root), partner, WTH_BPS, 3000, 60, address(0), 1e22);
        _openLane(address(arb), LANE_GAS, WTH_BPS);
        (kothKey, kothFamily) = _openPaidPool(ETH, true);
        (recapKey, recapFamily) = _openPaidPool(Currency.wrap(address(tokenB)), false);
        _seedReference(kothKey);
        _seedReference(recapKey);
        _nextBlock();
    }

    // ───────────────────────────── pools ─────────────────────────────

    /// @dev A lane member on the treasury-paying Rules with a launch guard of GUARD_BLOCKS (no Snipe, no buy cap), which
    ///      locks the family's principal: King of the Pool on, or recapture only.
    function _paidMember(Currency quote, bool koth) internal view returns (IHookrLauncher.Member memory m) {
        m = _laneMember(quote, _laneRules(koth), koth ? _kothRc() : _recaptureOnlyRc());
        m.config.rules = address(paid);
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + GUARD_BLOCKS);
    }

    function _openPaidPool(Currency quote, bool koth) internal returns (PoolKey memory key, bytes32 family) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _paidMember(quote, koth);
        PoolKey[] memory keys;
        (family, keys) = _launchAs(creator, _newSubject(), members);
        key = keys[0];
    }

    /// @dev Launches a fresh subject's King of the Pool lane member on `rulesAddress` as `creator`, sending the member's
    ///      ETH budget.
    function _launchNew(address rulesAddress) internal returns (bytes32 family) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _paidMember(ETH, true);
        members[0].config.rules = rulesAddress;
        (family,) = _launchAs(creator, _newSubject(), members);
    }

    /// @dev `_launchNew` expected to revert with `reason`.
    function _expectLaunchRefused(address rulesAddress, bytes memory reason) internal {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _paidMember(ETH, true);
        members[0].config.rules = rulesAddress;
        IHookrLauncher.Token memory token = IHookrLauncher.Token(address(_newSubject()), "", "", 0, bytes32(0));
        uint256 deadline = vm.getBlockTimestamp();
        vm.prank(creator);
        vm.expectRevert(reason);
        launcher.launch{value: members[0].amount0Max}(token, address(root), members, deadline);
    }

    // ───────────────────────────── reads ─────────────────────────────

    function _paidRecap() internal view returns (IHookrRecaptureRules) {
        return IHookrRecaptureRules(address(paid));
    }

    function _pendingOf(PoolKey memory key) internal view returns (uint256) {
        (uint256 d0, uint256 d1, uint256 f0, uint256 f1,) = _paidRecap().pendingDonation(key.toId());
        return d0 + d1 + f0 + f1;
    }

    /// @dev The paid Rules' RecaptureSplit events in `logs`, each checked against the 25/25 split: the push reports the
    ///      profit read back from it at WTH's 2,500 (push x 10,000 / 7,500, rounded down), and the protocol takes 25% of
    ///      that profit first. Returns the legs' totals.
    function _paidSplits(Vm.Log[] memory logs) internal view returns (Splits memory t) {
        bytes32 topic = IHookrRecaptureEvents.RecaptureSplit.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(paid) || logs[i].topics[0] != topic) continue;
            (uint256 tr, uint256 lp, uint256 pot, uint256 pro,, uint256 reported) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, Currency, uint256));
            uint256 pushed = tr + lp + pot + pro;
            assertEq(reported, pushed * 10_000 / (10_000 - WTH_BPS), "the push reports its profit at WTH's 2,500");
            assertEq(pro, _cut(reported, pushed), "Hookr's 25% of that profit first");
            t.count++;
            t.trader += tr;
            t.lp += lp;
            t.pot += pot;
            t.protocol += pro;
            t.reported += reported;
        }
    }

    /// @dev The two-venue executor's arb recaptures in `logs`, each checked: it kept 25% of its realized profit for the
    ///      partner and pushed the rest. Returns what the partner kept.
    function _partnerKept(Vm.Log[] memory logs) internal view returns (uint256 kept) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(arb) || logs[i].topics[0] != TwoVenueExecutor.ArbRecaptured.selector) {
                continue;
            }
            (, uint256 quoteIn, uint256 quoteOut, uint256 partnerShare, uint256 pushed) =
                abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256));
            uint256 profit = quoteOut - quoteIn;
            assertEq(partnerShare, profit * WTH_BPS / 10_000, "WTH keeps 25% of the profit");
            assertEq(pushed, profit - partnerShare, "and pushes the rest");
            kept += partnerShare;
        }
    }

    // ───────────────────────────── the exercise ─────────────────────────────

    /// @dev Moves the pool's reference venue about 3% away from the pool's price, so the next swap's before-phase has a
    ///      gap to close: up or down in the pool's sqrt price.
    function _openGap(PoolKey memory key, bool up) internal {
        (uint160 here,,,) = manager.getSlot0(key.toId());
        uint160 target = uint160(uint256(here) * (up ? 10_149 : 9_853) / 10_000);
        PoolKey memory ref = _ref(key);
        (uint160 there,,,) = manager.getSlot0(ref.toId());
        mover.directSwap(ref, target < there, -int256(1e26), target);
    }

    /// @dev One trade by the whale with an arb recapture in both phases: an outside gap, then a buy of TRADE quote or a
    ///      sell of TRADE subject. Checks the 25/25 split of every push and what the partner received, and records the
    ///      trade's output, both pushes, the split's legs, the profit they report and the partner's share.
    function _trade(uint256[] memory out, uint256 n, PoolKey memory key, Currency quote, bool buy)
        internal
        returns (uint256)
    {
        _openGap(key, buy);
        uint256 partnerBefore = quote.balanceOf(partner);
        vm.recordLogs();
        uint256 got = buy ? _buy(key, quote, whale, TRADE) : _sell(key, quote, whale, TRADE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        assertEq(o.succeeded, 2, "an arb recapture in both phases");
        assertEq(o.failed, 0, "no arb recapture failed");
        assertGt(o.pushedBefore, 0, "the before-phase closed the outside gap");
        assertGt(o.pushedAfter, 0, "the after-phase closed the trade's gap");
        Splits memory t = _paidSplits(logs);
        assertEq(t.count, 2, "both pushes split");
        assertEq(t.reported, o.profitBefore + o.profitAfter, "the splits report the root's profits");
        uint256 kept = _partnerKept(logs);
        assertEq(quote.balanceOf(partner) - partnerBefore, kept, "WTH received its 25%");
        out[n++] = got;
        out[n++] = o.pushedBefore;
        out[n++] = o.pushedAfter;
        out[n++] = t.trader;
        out[n++] = t.lp;
        out[n++] = t.pot;
        out[n++] = t.protocol;
        out[n++] = t.reported;
        out[n++] = kept;
        _nextBlock();
        return n;
    }

    /// @dev Refuses `family`'s principal while its guard's lock lasts.
    function _expectLocked(bytes32 family) internal {
        uint256 lockedUntil = launcher.principalLockedUntil(family);
        assertGt(lockedUntil, vm.getBlockNumber(), "the guard locks the principal");
        uint256 deadline = vm.getBlockTimestamp();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.PrincipalLocked.selector, family, 0, lockedUntil));
        launcher.withdraw(family, 0, 1, 0, 0, creator, deadline);
    }

    /// @dev Everything a live arb recapture pool serves, recorded. Both pools refuse their principal while locked; past
    ///      the lock each trades both ways with both phases. The King of the Pool epoch closes and its prize is the
    ///      whale's. The recapture-only pool's owner removes all of its liquidity, so a release period later its pending
    ///      LP share is the liquidity owner's accrual, which the owner moves into its claim; the King of the Pool pool's
    ///      share is released to its launch position, which its owner then removes with the fees. Then every claim is
    ///      paid (the family owner's and the trader's) and the treasury collects the protocol's for its target. Last,
    ///      what the Rules still owe and every balance the payments reach.
    function _exercise() internal returns (uint256[] memory out) {
        out = new uint256[](RECORDED);
        _expectLocked(kothFamily);
        _expectLocked(recapFamily);
        uint256 lockedUntil = launcher.principalLockedUntil(kothFamily);
        assertEq(launcher.principalLockedUntil(recapFamily), lockedUntil, "one lock for both");
        ArbSysKit.nextParent(vm, lockedUntil - vm.getBlockNumber());
        Currency qb = Currency.wrap(address(tokenB));
        uint256 n = _trade(out, 0, kothKey, ETH, true);
        n = _trade(out, n, kothKey, ETH, false);
        n = _trade(out, n, recapKey, qb, true);
        n = _trade(out, n, recapKey, qb, false);
        n = _settleEpoch(out, n);
        n = _exitToAccrual(out, n);
        n = _exitWithFees(out, n);
        n = _payEveryone(out, n);
        assertEq(n, out.length, "every value recorded");
    }

    /// @dev King of the Pool: the whale's buy leads the epoch; once it closes, anyone settles it and the prize is the
    ///      whale's. Half of the rest of the pot joins the pool's pending LP share. Records the pot and the prize.
    function _settleEpoch(uint256[] memory out, uint256 n) internal returns (uint256) {
        (uint64 start,, address leader,, uint128 pot) = _paidRecap().hill(kothKey.toId());
        assertEq(leader, whale, "the whale leads the epoch");
        uint256 whaleBefore = paid.claimable(ETH, whale);
        vm.warp(uint256(start) + PERIOD);
        vm.prank(minnow);
        _paidRecap().settleEpoch(kothKey.toId());
        uint256 prize = paid.claimable(ETH, whale) - whaleBefore;
        assertGt(prize, 0, "the prize is credited");
        out[n++] = pot;
        out[n++] = prize;
        return n;
    }

    /// @dev The recapture-only pool: its owner removes all of its liquidity; a release period later an outside LP's add
    ///      finds none in range, so the whole pending share is the liquidity owner's accrual, which the owner moves into
    ///      its claim. Records the removal's two amounts and the currencies moved.
    function _exitToAccrual(uint256[] memory out, uint256 n) internal returns (uint256) {
        uint128 l = launcher.position(recapFamily, 0).liquidity;
        uint256 deadline = vm.getBlockTimestamp();
        vm.prank(creator);
        (uint256 amount0, uint256 amount1) = launcher.withdraw(recapFamily, 0, l, 0, 0, creator, deadline);
        assertGt(_pendingOf(recapKey), 0, "an LP share still pending");
        ArbSysKit.nextParent(vm, RELEASE_PARENTS);
        _newActor(recapKey).modify(recapKey, -600, 600, 1e18);
        assertEq(_pendingOf(recapKey), 0, "the whole pending share released");
        assertGt(_paidRecap().poolAccrued(recapKey.toId(), Currency.wrap(address(tokenB))), 0, "to the owner's accrual");
        vm.prank(creator);
        uint256 moved = launcher.claimRecapture(recapFamily, 0, creator);
        out[n++] = amount0;
        out[n++] = amount1;
        out[n++] = moved;
        return n;
    }

    /// @dev The King of the Pool pool: a release period later a dust add at the top of the range releases the pending
    ///      share to the launch position, and its owner removes all of it with the fees. Records the removal's two
    ///      amounts and the currencies a claim of the accrual then moves.
    function _exitWithFees(uint256[] memory out, uint256 n) internal returns (uint256) {
        assertGt(_pendingOf(kothKey), 0, "an LP share still pending");
        ArbSysKit.nextParent(vm, RELEASE_PARENTS);
        int24 top = TickMath.maxUsableTick(kothKey.tickSpacing);
        _newActor(kothKey).modify(kothKey, top - kothKey.tickSpacing, top, 1);
        assertEq(_pendingOf(kothKey), 0, "the whole pending share released");
        uint128 l = launcher.position(kothFamily, 0).liquidity;
        uint256 deadline = vm.getBlockTimestamp();
        vm.prank(creator);
        (uint256 amount0, uint256 amount1) = launcher.withdraw(kothFamily, 0, l, 0, 0, creator, deadline);
        assertEq(launcher.position(kothFamily, 0).liquidity, 0, "the principal is out");
        vm.prank(creator);
        uint256 moved = launcher.claimRecapture(kothFamily, 0, creator);
        out[n++] = amount0;
        out[n++] = amount1;
        out[n++] = moved;
        return n;
    }

    /// @dev Every claim: the family owner's and the trader's in every currency, then the protocol's through the
    ///      treasury, forwarded to its target. Records each claim, each collection, what the Rules still owe and the
    ///      balance of every holder the payments reach, in every currency.
    function _payEveryone(uint256[] memory out, uint256 n) internal returns (uint256) {
        Currency[4] memory currencies = [ETH, Currency.wrap(address(tokenB)), _subjectOf(kothKey), _subjectOf(recapKey)];
        address[2] memory claimants = [creator, whale];
        for (uint256 k; k < claimants.length; ++k) {
            for (uint256 c; c < currencies.length; ++c) {
                uint256 owed = paid.claimable(currencies[c], claimants[k]);
                out[n++] = owed;
                if (owed != 0) {
                    vm.prank(claimants[k]);
                    assertEq(paid.claim(currencies[c]), owed, "claimed in full");
                }
            }
        }
        for (uint256 c; c < currencies.length; ++c) {
            out[n++] = treasury.collect(address(paid), currencies[c]);
            assertEq(paid.claimable(currencies[c], address(treasury)), 0, "collected in full");
        }
        for (uint256 c; c < currencies.length; ++c) {
            out[n++] = paid.totalLiability(currencies[c]);
            assertTrue(paid.accountingInvariant(currencies[c]), "the Rules stay backed");
        }
        address[5] memory holders = [creator, whale, partner, TARGET, address(treasury)];
        for (uint256 h; h < holders.length; ++h) {
            for (uint256 c; c < currencies.length; ++c) {
                out[n++] = currencies[c].balanceOf(holders[h]);
            }
        }
        return n;
    }

    /// @dev What `_exercise` records from the current state, without the brake, checked to pay on every leg; the
    ///      state is restored afterwards.
    function _baseline() internal returns (uint256[] memory expected) {
        uint256 snapshot = vm.snapshotState();
        expected = _exercise();
        vm.revertToState(snapshot);
        // The baseline really pays: the whale's trader legs and prize in ETH and its trader legs in tokenB, the family
        // owner's LP accrual in tokenB, and the protocol's 25% in both quotes through the treasury.
        uint256 claims = 4 * 9 + 2 + 2 * 3;
        assertGt(expected[claims + 1], 0, "the family owner's LP accrual");
        assertGt(expected[claims + 4], 0, "the whale's ETH claim");
        assertGt(expected[claims + 5], 0, "the whale's tokenB claim");
        assertGt(expected[claims + 8], 0, "the treasury collects ETH");
        assertGt(expected[claims + 9], 0, "the treasury collects tokenB");
    }
}

/// @notice A guardian's revoke of the root's Rules admission reaches no live arb recapture pool.
contract RevokeLivePoolLaneTest is RevokeLivePoolLaneFixture {
    function _bonded() internal pure override returns (bool) {
        return false;
    }

    function test_aRevokedRulesAdmissionLeavesLiveLanePoolsServingAsBefore() public {
        uint256[] memory expected = _baseline();
        vm.prank(guardian);
        registry.revokeModuleAdmission(address(root), address(paid));
        assertEq(registry.admission(address(root), address(paid)).implementation, address(0), "revoked");
        assertTrue(registry.isRevokedAdmission(address(root), address(paid)));
        // No path a live pool serves, and no claim, settlement or collection, reads an admission.
        vm.expectCall(address(registry), abi.encodeWithSelector(IHookrRegistry.admission.selector), 0);
        uint256[] memory got = _exercise();
        assertEq(got, expected);
    }

    function test_aRevokedRulesAdmissionRefusesNewLanePools() public {
        vm.prank(guardian);
        registry.revokeModuleAdmission(address(root), address(paid));
        _expectLaunchRefused(
            address(paid), abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, address(paid))
        );
        // The same pool on Rules the brake did not touch reads its admission, opens and freezes the lane.
        vm.expectCall(address(registry), abi.encodeCall(IHookrRegistry.admission, (address(root), address(rules))));
        bytes32 family = _launchNew(address(rules));
        (address executor,,,) = _laneOf(launcher.position(family, 0).key);
        assertEq(executor, address(arb), "the new pool froze the lane");
    }
}

/// @notice An admission bond that stops covering the root's Rules reaches no live arb recapture pool.
contract LapsedBondLivePoolLaneTest is RevokeLivePoolLaneFixture {
    function _bonded() internal pure override returns (bool) {
        return true;
    }

    function test_aLapsedAdmissionBondLeavesLiveLanePoolsServingAsBefore() public {
        uint256[] memory expected = _baseline();
        bond.setCovered(address(root), address(paid), false);
        assertEq(registry.admission(address(root), address(paid)).implementation, address(0), "lapsed");
        (address bondRef, bool covering) = registry.findBondForAdmission(address(root), address(paid));
        assertEq(bondRef, address(bond));
        assertFalse(covering);
        // No path a live pool serves reads an admission, so none asks the bond.
        vm.expectCall(address(registry), abi.encodeWithSelector(IHookrRegistry.admission.selector), 0);
        vm.expectCall(address(bond), abi.encodeWithSelector(IHookrModuleBond.covers.selector), 0);
        uint256[] memory got = _exercise();
        assertEq(got, expected);
    }

    function test_aLapsedAdmissionBondRefusesNewLanePools_untilItCoversAgain() public {
        bond.setCovered(address(root), address(paid), false);
        _expectLaunchRefused(
            address(paid), abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, address(paid))
        );
        bond.setCovered(address(root), address(paid), true);
        vm.expectCall(address(bond), abi.encodeCall(IHookrModuleBond.covers, (address(root), address(paid))));
        bytes32 family = _launchNew(address(paid));
        (address executor,,,) = _laneOf(launcher.position(family, 0).key);
        assertEq(executor, address(arb), "the new pool froze the lane");
    }
}
