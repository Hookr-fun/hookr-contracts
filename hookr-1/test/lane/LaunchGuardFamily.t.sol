// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {LaneRootFixture} from "./utils/LaneRootFixture.sol";
import {TwoVenueExecutor} from "./mocks/TwoVenueExecutor.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {Actor} from "./mocks/Actors.sol";

/// @dev Launches a two-member lane family (ETH and tokenB quotes) and swaps on member 1, then member 0, in the same
///      transaction.
contract FamilyLaunchThenSwap {
    function run(
        HookrLauncher launcher,
        HookrRouter router,
        address root,
        IERC20 quoteB,
        IHookrLauncher.Member[] calldata members
    ) external payable returns (PoolKey memory k0, PoolKey memory k1) {
        HookrToken t = new HookrToken("C", "C", 1e30, address(this));
        t.approve(address(launcher), type(uint256).max);
        t.approve(address(router), type(uint256).max);
        quoteB.approve(address(launcher), type(uint256).max);
        quoteB.approve(address(router), type(uint256).max);
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(t), "", "", 0, bytes32(0)), root, members, block.timestamp
        );
        k0 = launcher.position(family, 0).key;
        k1 = launcher.position(family, 1).key;
        // A buy of the subject on member 1 (tokenB in), then on member 0 (ETH in).
        bool zf1 = Currency.unwrap(k1.currency0) == address(quoteB);
        router.swap(
            IHookrRouter.Swap(
                k1,
                zf1,
                -int128(1e21),
                1,
                zf1 ? 4295128740 : 1461446703485210103287273052203988822378723970341 - 1,
                address(this),
                block.timestamp
            ),
            address(0),
            new uint256[](0)
        );
        router.swap{value: 1e21}(
            IHookrRouter.Swap(k0, true, -int128(1e21), 1, 4295128740, address(this), block.timestamp),
            address(0),
            new uint256[](0)
        );
    }

    receive() external payable {}
}

/// @notice Held: no arb recapture runs in the transaction that creates a family, on any member, even though every
///         member is a lane pool and the executor would leg across the family.
contract CreationTxFamilyTest is LaneRootFixture {
    ScriptedExecutor internal exec;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        exec.setRoot(address(root));
        _openLane(address(exec), 3_000_000);
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
    }

    function test_held_noArbRecaptureOnAnyMemberInTheFamilyCreationTx() public {
        FamilyLaunchThenSwap l = new FamilyLaunchThenSwap();
        vm.deal(address(l), 1e26);
        tokenB.transfer(address(l), 1e26);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(ETH, true, false, 200);
        members[1] = _member(Currency.wrap(address(tokenB)), true, false, 200);
        vm.recordLogs();
        (PoolKey memory k0,) = l.run(launcher, router, address(root), IERC20(address(tokenB)), members);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded + o.failed, 0, "no lane call on either member in the creation transaction");
        assertEq(exec.calls(), 0);
        _nextBlock();
        vm.recordLogs();
        _buy(k0, ETH, whale, 1e18);
        o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2, "the next transaction runs both phases");
    }
}

/// @notice Held: the dev buy closes its member's launch parent block to every buy, including an executor buy leg
///         from a sibling's arb recapture in a later transaction of that parent block; the next parent block opens it
///         and the leg pays Snipe.
contract DevBuyBlockLegTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    ScriptedExecutor internal exec;
    PoolKey internal guarded;
    PoolKey internal open;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        exec.setRoot(address(root));
        vm.deal(address(exec), 1e28);
        tokenB.transfer(address(exec), 1e27);
        _openLane(address(exec), 3_000_000);
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        IHookrLauncher.Member memory m = _member(ETH, true, true, 0);
        m.tickLower = -60_000;
        m.tickUpper = 0;
        uint160 lower = TickMath.getSqrtPriceAtTick(-60_000);
        m.liquidity = LiquidityAmounts.getLiquidityForAmount1(lower, SQRT_ONE, 9.65e26) / 1000 * 999;
        m.amount0Max = 0;
        m.amount1Max = 9.65e26;
        members[0] = m;
        members[1] = _member(Currency.wrap(address(tokenB)), true, false, 0);
        tokenB.approve(address(launcher), type(uint256).max);
        (bytes32 family,,) = launcher.launchWithBuy{value: 1e21}(
            IHookrLauncher.Token(address(0), "New", "NEW", 1e27, bytes32(uint256(78))),
            address(root),
            members,
            new bytes[](2),
            IHookrLauncher.DevBuy(0, 1e21, 1, 0),
            vm.getBlockTimestamp()
        );
        guarded = launcher.position(family, 0).key;
        open = launcher.position(family, 1).key;
        address subject = Currency.unwrap(root.poolConfig(open.toId()).subject);
        HookrToken(subject).transfer(whale, 1e24);
        vm.prank(whale);
        HookrToken(subject).approve(address(router), type(uint256).max);
    }

    function _planBuyOnGuarded() internal {
        ScriptedExecutor.Step[] memory steps = new ScriptedExecutor.Step[](1);
        steps[0] = ScriptedExecutor.Step(guarded, true, 1e18); // ETH in: a buy of the subject
        exec.setPlan(steps, false, false, ETH);
        exec.set(ScriptedExecutor.Mode.PLAN, 0);
        exec.clearPlanRecord();
    }

    function test_held_devBuyBlockRefusesASiblingArbRecapturesBuyLeg() public {
        _planBuyOnGuarded();
        (uint160 before,,,) = manager.getSlot0(guarded.toId());
        vm.recordLogs();
        _sell(open, Currency.wrap(address(tokenB)), whale, 1e18); // same parent block, a later transaction
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2);
        assertEq(exec.planErrorCount(), 2, "the buy leg on the dev-buy member was refused in both frames");
        bytes memory err = exec.planErrors(0);
        console2.logBytes(err);
        (uint160 afterP,,,) = manager.getSlot0(guarded.toId());
        assertEq(afterP, before, "the dev-buy member did not move");
        // Next parent block: the leg clears and pays Snipe (50%).
        _nextBlock();
        _planBuyOnGuarded();
        _sell(open, Currency.wrap(address(tokenB)), whale, 1e18);
        assertEq(exec.planErrorCount(), 0);
        console2.log("guarded buy leg out for 1e18 ETH in the next parent block", exec.planOuts(0));
        assertLt(exec.planOuts(0), 6e17, "Snipe paid");
    }
}

/// @notice ATK-LF-4, pinned known limit (fee routing across members): an arb recapture's legs on a member with LP
///         Rewards, Auto Burn and a royalty pay the member's base fee only, as legs on the triggering pool do. The same
///         subject taken out of the member by an ordinary buy pays the royalty recipient, burns subject and pays the
///         protocol's LP Rewards share; taken by a family leg it pays none of them (the protocol takes its share of the
///         push instead). Stated in the README and on the launch surface for families that mix taxed and plain members.
contract FamilyRuleDodgeTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address internal constant DEAD = address(0xdead);
    ScriptedExecutor internal exec;
    HookrToken internal subject;
    PoolKey internal taxed;
    PoolKey internal plain;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        exec.setRoot(address(root));
        vm.deal(address(exec), 1e28);
        tokenB.transfer(address(exec), 1e27);
        _openLane(address(exec), 3_000_000);
        subject = _newSubject();
        subject.transfer(address(exec), 1e27);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(ETH, true, false, 400);
        members[0].rules.burnBps = 100;
        members[0].rules.royaltyBps = 1000;
        members[0].rules.royaltyTo = royalty;
        members[1] = _member(Currency.wrap(address(tokenB)), true, false, 0);
        (, PoolKey[] memory keys) = _launch(subject, members);
        (taxed, plain) = (keys[0], keys[1]);
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        _nextBlock();
    }

    function test_pinned_familyLegsSkipRoyaltyBurnAndProtocolShareOfTheTaxedMember() public {
        uint256 snap = vm.snapshotState();
        // An ordinary buy of 1e21 ETH on the taxed member.
        uint256 r0 = rules.claimable(ETH, royalty);
        uint256 p0 = rules.claimable(ETH, protocol);
        uint256 d0 = subject.balanceOf(DEAD);
        uint256 ordinaryOut = exec.outsideSwap(taxed, 1e21);
        uint256 ordRoyalty = rules.claimable(ETH, royalty) - r0;
        uint256 ordProtocol = rules.claimable(ETH, protocol) - p0;
        uint256 ordBurn = subject.balanceOf(DEAD) - d0;
        vm.revertToState(snap);
        // The same buy as a family leg from an arb recapture triggered on the plain member.
        ScriptedExecutor.Step[] memory steps = new ScriptedExecutor.Step[](1);
        steps[0] = ScriptedExecutor.Step(taxed, true, 1e21);
        exec.setPlan(steps, true, false, ETH);
        exec.set(ScriptedExecutor.Mode.PLAN, 0);
        subject.transfer(whale, 1e22);
        vm.prank(whale);
        subject.approve(address(router), type(uint256).max);
        r0 = rules.claimable(ETH, royalty);
        p0 = rules.claimable(ETH, protocol);
        d0 = subject.balanceOf(DEAD);
        _sell(plain, Currency.wrap(address(tokenB)), whale, 1e15);
        uint256 legOut = exec.planOuts(0);
        console2.log("ordinary buy: subject out, royalty, protocol, burned", ordinaryOut, ordRoyalty, ordProtocol);
        console2.log("  (burned)", ordBurn);
        console2.log("family leg (before-phase): subject out", legOut);
        console2.log(
            "  royalty, protocol, burned deltas over both frames",
            rules.claimable(ETH, royalty) - r0,
            rules.claimable(ETH, protocol) - p0,
            subject.balanceOf(DEAD) - d0
        );
        assertGt(ordRoyalty, 0);
        assertGt(ordBurn, 0);
        assertGt(ordProtocol, 0);
        assertEq(rules.claimable(ETH, royalty) - r0, 0, "no royalty on family legs");
        assertEq(subject.balanceOf(DEAD) - d0, 0, "no Auto Burn on family legs");
        assertEq(rules.claimable(ETH, protocol) - p0, 0, "no protocol LP Rewards share on family legs");
        assertGt(legOut, ordinaryOut);
    }
}

/// @notice ATK-LF-3 regression. King of the Pool after the M-1 fix: with no arb recapture (a crowning buy inside the
///         executor's fee band) the prize could equal the protocol fee the crowning buy paid, so the sole-LP creator
///         could outbid an honest leader in one transaction, sell back on the same pool in a later one (no voiding)
///         and end even, denying the honest leader's prize at no cost. The prize ceiling is now half that fee
///         (HookrRecapture.prizeBound), so the same wash, at the widest ceiling the Rules admit, costs the creator at
///         least the honest leader's prize when no referral campaign rebates the protocol fee. A Protocol-fee rebate at
///         the distributor's King of the Pool cap brings that cost back to about nothing (KothReferralRebateTest).
contract KothBandWashTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    TwoVenueExecutor internal arb;
    PoolKey internal key;
    PoolKey internal ref;
    bytes32 internal family;
    Currency internal subject;

    function setUp() public {
        _setUpLane();
        arb = _twoVenueExecutor(1e24);
        _openLane(address(arb));
        HookrTypes.RecaptureConfig memory rc = _kothRc();
        // The widest prize ceiling the Rules admit for these rules.
        rc.maxPrizeBps = uint16(_recap().prizeBound(KOTH_LP_REWARDS, 0, SHARE));
        (key, family) = _openPoolWithFamily(ETH, _laneRules(true), rc);
        subject = _subjectOf(key);
        ref = _seedReference(key);
        _nextBlock();
        Actor filler = _newActor(key);
        for (uint256 i; i < 12; ++i) {
            filler.directSwap(key, true, -2e22, MIN_PRICE);
            filler.directSwap(key, false, -filler.lastDelta1(), MAX_PRICE);
        }
    }

    function _alignReference() internal {
        (uint160 k,,,) = manager.getSlot0(key.toId());
        (uint160 r,,,) = manager.getSlot0(ref.toId());
        if (r != k) mover.directSwap(ref, r > k, -int256(1e26), k);
    }

    /// @dev The creator's LP share not yet in its position's fees: the owner accrual, which it claims, and the pending
    ///      donation, which the creator's position (the pool's only liquidity) collects from the next block.
    function _claimAccrual() internal returns (uint256 amount) {
        amount = _accrued(key);
        if (_ownerAccrued(key) == 0) return amount;
        vm.prank(creator);
        launcher.claimRecapture(family, 0, creator);
    }

    function _withdrawAll() internal returns (uint256 eth, uint256 sub) {
        uint128 liquidity = launcher.position(family, 0).liquidity;
        vm.prank(creator);
        (eth, sub) = launcher.withdraw(family, 0, liquidity, 0, 0, creator, vm.getBlockTimestamp());
    }

    /// @dev The creator's side of one path: the honest leader's prize, and in ETH and subject the washer's deltas and
    ///      prize, the accrual, the withdrawal and the pot still carried (released to the creator's accrual later).
    struct Path {
        uint256 honestPrize;
        uint256 washerPrize;
        int256 eth;
        int256 sub;
    }

    /// @dev Path B (no wash): the epoch closes, the honest leader is paid, the creator claims and withdraws.
    function _pathB(uint64 start) internal returns (Path memory p) {
        uint256 m0 = rules.claimable(ETH, minnow);
        vm.warp(uint256(start) + PERIOD);
        _recap().settleEpoch(key.toId());
        p.honestPrize = rules.claimable(ETH, minnow) - m0;
        (,,, uint128 carried) = _hill(key);
        uint256 acc = _claimAccrual();
        (uint256 eth, uint256 sub) = _withdrawAll();
        p.eth = int256(acc + eth + uint256(carried));
        p.sub = int256(sub);
    }

    /// @dev Path A: the creator's washer outbids by 0.01 ETH in one transaction and sells back on the same pool in the
    ///      next; then as path B.
    function _pathA(uint64 start, uint256 honest) internal returns (Path memory p) {
        Actor w = _newActor(key);
        uint256 wEth = address(w).balance;
        uint256 wSub = subject.balanceOf(address(w));
        vm.recordLogs();
        uint256 bid = honest + 1e16;
        (, uint256 got) = w.routerSwap(_swapParams(key, ETH, true, true, bid, address(w)), bid);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.pushedBefore + o.pushedAfter, 0, "in the band: no arb recapture");
        (, address leader,,) = _hill(key);
        assertEq(leader, address(w), "the washer leads");
        vm.roll(vm.getBlockNumber() + 1);
        w.routerSwap(_swapParams(key, ETH, false, true, got, address(w)), 0);
        (, leader,,) = _hill(key);
        assertEq(leader, address(w), "a sell in a later transaction keeps the crown");
        uint256 m0 = rules.claimable(ETH, minnow);
        vm.warp(uint256(start) + PERIOD);
        _recap().settleEpoch(key.toId());
        p.honestPrize = rules.claimable(ETH, minnow) - m0;
        p.washerPrize = rules.claimable(ETH, address(w));
        (,,, uint128 carried) = _hill(key);
        uint256 acc = _claimAccrual();
        (uint256 eth, uint256 sub) = _withdrawAll();
        p.eth = int256(address(w).balance) - int256(wEth) + int256(p.washerPrize + acc + eth + uint256(carried));
        p.sub = int256(subject.balanceOf(address(w))) - int256(wSub) + int256(sub);
    }

    function test_regression_soleLpCreatorPaysAtLeastTheHonestPrizeToDenyIt() public {
        uint256 honest = 1e20;
        _buy(key, ETH, minnow, honest);
        _alignReference();
        (uint64 start,,, uint128 pot) = _hill(key);
        assertGe(pot, 2e18, "the pot covers both prizes");
        uint256 snap = vm.snapshotState();
        Path memory b = _pathB(start);
        vm.revertToState(snap);
        Path memory a = _pathA(start, honest);
        int256 dEth = a.eth - b.eth;
        int256 dSub = a.sub - b.sub;
        console2.log("honest leader's prize without / with the wash", b.honestPrize, a.honestPrize);
        console2.log("washer's prize", a.washerPrize);
        console2.log("creator net vs no wash: ETH (incl. carried pot) / subject");
        console2.logInt(dEth);
        console2.logInt(dSub);
        assertGt(b.honestPrize, 0);
        assertEq(a.honestPrize, 0, "the honest leader's prize is denied");
        int256 net = dEth + dSub;
        console2.log("creator net, subject at 1 (wei)");
        console2.logInt(net);
        // Before the fix the whole cost was the extra prize on the outbid margin (under 1% of the honest prize). Now the
        // crown costs half the protocol fee on the whole bid: at least the honest leader's prize.
        assertLt(net, 0, "the wash loses");
        assertGe(uint256(-net) + 10, b.honestPrize, "denying the prize costs the creator at least the prize");
    }
}
