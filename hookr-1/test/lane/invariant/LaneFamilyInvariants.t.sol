// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {HookrRegistry} from "../../../src/core/HookrRegistry.sol";
import {HookrRules} from "../../../src/core/HookrRules.sol";
import {HookrRouter} from "../../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../../src/interfaces/IHookrRouter.sol";
import {HookrLauncher} from "../../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../../src/support/HookrToken.sol";
import {IHookrLanes} from "../../../src/interfaces/IHookrLanes.sol";
import {IHookrRecaptureRules} from "../../../src/interfaces/IHookrRecaptureRules.sol";
import {CyclingExecutor, HooklessVenue} from "../../fixtures/CyclingExecutor.sol";
import {Actor} from "../mocks/Actors.sol";
import {ArbSysKit} from "../../kit/ArbSysMock.sol";
import {PartnerShapedFixture} from "../utils/PartnerShapedFixture.sol";
import {HookrTypes} from "../../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../../src/interfaces/IHookrRegistry.sol";
import {LegTaxAdvisory} from "../mocks/LegTaxMocks.sol";
import {IHookrRecaptureEvents} from "../../../src/interfaces/IHookrRecaptureEvents.sol";

/// @notice Drives a three-member lane family (ETH, tokenA and tokenB quotes on one subject) under the partner-shaped
///         executor: authenticated buys and sells and unauthenticated swaps on every member, outside moves on the ETH
///         member's venue, the executor's brake (off, a lowered cap, a timelocked switch-on at any cap), time, claims
///         and the family owner's recapture claims. Tallies the lane's and the Rules' events of every action.
contract LaneFamilyHandler is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint160 internal constant MIN_PRICE = 4295128740;
    uint160 internal constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;
    bytes32 internal constant SUCCEEDED =
        keccak256("CorrectionSucceeded(bytes32,uint8,address,uint256,uint256,address)");
    bytes32 internal constant FAILED = keccak256("CorrectionFailed(bytes32,uint8,address,bytes4)");
    bytes32 internal constant LANE_ON = keccak256("LANE_ON");
    /// @dev The share the stand-in executor keeps of each profit and the lane pins: WTH's 25%.
    uint256 internal constant KEEP_BPS = 2_500;

    HookrRouter internal immutable router;
    HookrRules internal immutable rules;
    HookrRegistry internal immutable registry;
    HookrLauncher internal immutable launcher;
    HooklessVenue internal immutable venue;
    address internal immutable root;
    address internal immutable executor;
    address internal immutable owner;
    Currency internal immutable subject;
    bytes32 internal immutable family;
    PoolKey[] internal members;
    PoolKey internal refA;
    Actor[] internal actors;
    mapping(PoolId => Currency) internal quoteOf;

    uint256 public calls;
    uint256 public recaptures;
    uint256 public pushes;
    uint256 public failures;
    /// @dev What the partner must have received per quote: every arb recapture's profit (its push at the pinned rate)
    ///      less its push, and the pushes that went into it.
    mapping(Currency => uint256) public partnerOwed;
    mapping(Currency => uint256) public pushesIn;
    bool public ghostOn = true;
    bool public ghostRecapturedWhileOff;
    bool public ghostBeforePhaseCredit;
    bool public ghostPushBelowRate;
    bool public ghostSplitMismatch;

    constructor(
        HookrRouter _router,
        HookrRules _rules,
        HookrRegistry _registry,
        HookrLauncher _launcher,
        HooklessVenue _venue,
        address _root,
        address _executor,
        address _owner,
        Currency _subject,
        bytes32 _family,
        PoolKey[] memory _members,
        PoolKey memory _refA,
        Actor[] memory _actors
    ) {
        (router, rules, registry, launcher, venue) = (_router, _rules, _registry, _launcher, _venue);
        (root, executor, owner, subject, family) = (_root, _executor, _owner, _subject, _family);
        for (uint256 i; i < _members.length; ++i) {
            members.push(_members[i]);
            quoteOf[_members[i].toId()] =
                _members[i].currency0 == _subject ? _members[i].currency1 : _members[i].currency0;
        }
        refA = _refA;
        for (uint256 i; i < _actors.length; ++i) {
            actors.push(_actors[i]);
        }
        IERC20(Currency.unwrap(_subject)).approve(address(_venue), type(uint256).max);
    }

    /// @dev Records every log of the action and checks each arb recapture: the push is at least the profit net of the
    ///      pinned 25%, a before-phase push names no trader and credits none, the split's parts add up to the push and
    ///      it reports the profit the root read back, and none runs while the executor's switch is off.
    modifier tally() {
        vm.recordLogs();
        _;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address splitTrader;
        uint256 splitTraderAmount;
        uint256 splitTotal;
        uint256 splitProfit;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter == address(rules) && l.topics[0] == IHookrRecaptureEvents.RecaptureSplit.selector) {
                (uint256 tr, uint256 lp, uint256 pot, uint256 pro,, uint256 reported) =
                    abi.decode(l.data, (uint256, uint256, uint256, uint256, Currency, uint256));
                splitTrader = address(uint160(uint256(l.topics[2])));
                splitTraderAmount = tr;
                splitTotal = tr + lp + pot + pro;
                splitProfit = reported;
            } else if (l.emitter == root && (l.topics[0] == SUCCEEDED || l.topics[0] == FAILED)) {
                if (!ghostOn) ghostRecapturedWhileOff = true;
                if (l.topics[0] == FAILED) {
                    ++failures;
                    continue;
                }
                ++recaptures;
                (uint256 profit, uint256 pushed) = abi.decode(l.data, (uint256, uint256));
                if (pushed * 10_000 < profit * (10_000 - KEEP_BPS)) ghostPushBelowRate = true;
                partnerOwed[quoteOf[PoolId.wrap(l.topics[1])]] += profit - pushed;
                if (pushed != 0) {
                    ++pushes;
                    ++pushesIn[quoteOf[PoolId.wrap(l.topics[1])]];
                    if (splitTotal != pushed || splitProfit != profit) ghostSplitMismatch = true;
                    if (uint256(l.topics[2]) == 1 && (splitTrader != address(0) || splitTraderAmount != 0)) {
                        ghostBeforePhaseCredit = true;
                    }
                    if (uint256(l.topics[2]) == 1 && l.topics[3] != bytes32(0)) ghostBeforePhaseCredit = true;
                }
                (splitTrader, splitTraderAmount, splitTotal, splitProfit) = (address(0), 0, 0, 0);
            }
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return address(actors[i]);
    }

    function _swap(PoolKey memory key, bool buy, uint256 amount) internal view returns (IHookrRouter.Swap memory p) {
        bool zeroForOne = buy ? !(key.currency0 == subject) : key.currency0 == subject;
        p = IHookrRouter.Swap(
            key, zeroForOne, -int128(int256(amount)), 1, zeroForOne ? MIN_PRICE : MAX_PRICE, address(0), block.timestamp
        );
    }

    function _balance(Currency c, address who) internal view returns (uint256) {
        return c.isAddressZero() ? who.balance : IERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function buy(uint256 who, uint256 member, uint256 amount) external tally {
        calls++;
        Actor a = actors[who % actors.length];
        PoolKey memory key = members[member % members.length];
        Currency q = quoteOf[key.toId()];
        amount = bound(amount, 1e12, 5e22);
        a.routerSwap(_swap(key, true, amount), q.isAddressZero() ? amount : 0);
    }

    function sell(uint256 who, uint256 member, uint256 amount) external tally {
        calls++;
        Actor a = actors[who % actors.length];
        uint256 held = _balance(subject, address(a));
        if (held < 1e12) return;
        amount = bound(amount, 1e12, held > 5e22 ? 5e22 : held);
        a.routerSwap(_swap(members[member % members.length], false, amount), 0);
    }

    function direct(uint256 who, uint256 member, bool buyIt, uint256 amount) external tally {
        calls++;
        Actor a = actors[who % actors.length];
        PoolKey memory key = members[member % members.length];
        if (!buyIt) {
            uint256 held = _balance(subject, address(a));
            if (held < 1e12) return;
            amount = bound(amount, 1e12, held > 5e22 ? 5e22 : held);
        } else {
            amount = bound(amount, 1e12, 5e22);
        }
        bool zeroForOne = buyIt ? !(key.currency0 == subject) : key.currency0 == subject;
        a.directSwap(key, zeroForOne, -int256(amount), zeroForOne ? MIN_PRICE + 1 : MAX_PRICE - 1);
    }

    /// @dev Someone trades the subject on the ETH member's outside venue: the next lane swap's before-phase sees it.
    function moveVenue(bool buyIt, uint256 amount) external {
        calls++;
        amount = bound(amount, 1e18, 3e22);
        bool zeroForOne = buyIt ? !(refA.currency0 == subject) : refA.currency0 == subject;
        venue.swap{value: zeroForOne && refA.currency0.isAddressZero() ? amount : 0}(refA, zeroForOne, amount, 0);
    }

    function brake(uint256 mode, uint256 cap) external {
        calls++;
        (bool on, uint32 current) = IHookrLanes(address(registry)).executorLane(root, executor);
        uint256 m = mode % 3;
        vm.startPrank(owner);
        if (m == 0) {
            registry.stopExecutorLane(root, executor);
            ghostOn = false;
        } else if (m == 1 && current > 500_000) {
            registry.tuneExecutorLane(root, executor, uint32(bound(cap, 500_000, current - 1)));
        } else {
            // A switch-on is queued after the last brake: one second on, then the delay.
            vm.warp(block.timestamp + 1);
            uint32 next = uint32(bound(cap, 500_000, 5_000_000));
            registry.queue(LANE_ON, abi.encode(root, executor, next));
            vm.warp(block.timestamp + registry.delay());
            registry.startExecutorLaneAt(root, executor, next);
            ghostOn = true;
        }
        vm.stopPrank();
        on;
    }

    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 1 days));
        vm.roll(block.number + 1);
    }

    /// @dev Robinhood Chain's two clocks: an even `k` is the next parent block (120 L2 blocks, 12 seconds), an odd one
    ///      1 to 119 L2 blocks inside the current parent block, which only the recapture release sees.
    function clock(uint256 k) external {
        calls++;
        if (k % 2 == 0) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
        } else {
            ArbSysKit.stepL2(vm, bound(k >> 1, 1, 119));
        }
    }

    function claim(uint256 who, uint256 which) external {
        calls++;
        Actor a = actors[who % actors.length];
        Currency c = quoteOf[members[which % members.length].toId()];
        if (rules.claimable(c, address(a)) == 0) return;
        vm.prank(address(a));
        rules.claim(c);
    }

    function claimRecapture(uint256 member) external {
        calls++;
        uint8 m = uint8(member % members.length);
        if (IHookrRecaptureRules(address(rules)).poolAccruedCurrencies(members[m].toId()).length == 0) return;
        vm.prank(owner);
        launcher.claimRecapture(family, m, owner);
    }

    receive() external payable {}
}

/// @notice System invariants of a lane family under the partner-shaped executor. After every call: the PoolManager is
///         settled; the root, Router, Quoter and launcher hold nothing; the Rules' ERC-6909 claims equal their
///         liabilities in every quote; the launcher's positions are the PoolManager's; every arb recapture pushed at
///         least its profit net of the pinned 25%, and the partner received exactly the rest; no before-phase push
///         credited a trader; no arb recapture ran while the executor was switched off; every split adds up to its
///         push. After every run every party exits and nothing is left in the Rules.
contract LaneFamilyInvariantsTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    LaneFamilyHandler internal handler;
    HookrToken internal subject;
    bytes32 internal fam;
    PoolKey[] internal keys;
    Currency[4] internal cs;
    uint256[4] internal partnerStart;
    /// @dev A 0.1% quote tax on the tokenB member, which the executor's cycles leg through: its legs pay it.
    LegTaxAdvisory internal tax;

    function setUp() public {
        _setUpPartnerShaped();
        subject = _newSubject();
        subject.approve(address(venue), type(uint256).max);
        Currency s = Currency.wrap(address(subject));
        Currency qa = Currency.wrap(address(tokenA));
        Currency qb = Currency.wrap(address(tokenB));
        IHookrLauncher.Member[] memory m = new IHookrLauncher.Member[](3);
        m[0] = _laneMemberAt(ETH);
        m[1] = _laneMemberAt(qa);
        m[2] = _laneMemberAt(qb);
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
        tax.set(1_000, 1_000);
        m[2].config.advisory = address(tax);
        m[2].config.advisoryGasLimit = 100_000;
        m[2].config.advisoryPhases = HookrTypes.BEFORE_SWAP | HookrTypes.AFTER_SWAP;
        bytes[] memory data = new bytes[](3);
        data[2] = hex"01";
        (fam,) = launcher.launchAdvised{value: 1e24}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            m,
            data,
            vm.getBlockTimestamp()
        );
        PoolKey[] memory k = new PoolKey[](3);
        for (uint256 i; i < 3; ++i) {
            k[i] = launcher.position(fam, uint8(i)).key;
        }
        for (uint256 i; i < 3; ++i) {
            keys.push(k[i]);
        }
        PoolKey memory refA = _hookless(k[0].currency0, k[0].currency1);
        PoolKey memory cA = _hookless(ETH, qa);
        PoolKey memory cB = _hookless(ETH, qb);
        (Currency lo, Currency hi) = address(tokenA) < address(tokenB) ? (qa, qb) : (qb, qa);
        PoolKey memory cAB = _hookless(lo, hi);
        ex.setTrigger(k[0], 1e22);
        ex.addVenue(k[0], refA, PAIR_GAP);
        ex.addCycle(k[0], k[1], cA, CYCLE_GAP);
        ex.addCycle(k[0], k[2], cB, CYCLE_GAP);
        ex.setTrigger(k[1], 1e22);
        ex.addCycle(k[1], k[0], cA, CYCLE_GAP);
        ex.addCycle(k[1], k[2], cAB, CYCLE_GAP);
        ex.setTrigger(k[2], 1e22);
        ex.addCycle(k[2], k[0], cB, CYCLE_GAP);
        ex.addCycle(k[2], k[1], cAB, CYCLE_GAP);
        Actor[] memory actors = new Actor[](3);
        for (uint256 i; i < 3; ++i) {
            actors[i] = _newActor();
            subject.transfer(address(actors[i]), 1e26);
            actors[i].approveAll(address(subject));
        }
        handler = new LaneFamilyHandler(
            router,
            rules,
            registry,
            launcher,
            venue,
            address(root),
            address(ex),
            address(this),
            s,
            fam,
            keys,
            refA,
            actors
        );
        vm.deal(address(handler), 1e28);
        subject.transfer(address(handler), 1e27);
        cs = [ETH, qa, qb, s];
        for (uint256 i; i < 4; ++i) {
            partnerStart[i] = _bal(cs[i], partner);
        }
        _nextBlock();
        targetContract(address(handler));
        _targetPlainSender();
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return c.isAddressZero() ? who.balance : IERC20(Currency.unwrap(c)).balanceOf(who);
    }

    /// The PoolManager is locked with no open delta after every call.
    function invariant_poolManagerSettled() public view {
        assertFalse(manager.isUnlocked(), "PoolManager left unlocked");
        assertEq(manager.getNonzeroDeltaCount(), 0, "nonzero delta count");
    }

    /// The root, Router, Quoter and launcher hold no token and no ERC-6909 claim; the Rules hold claims only, exactly
    /// their liabilities.
    function invariant_nothingHeld_rulesExactlyBacked() public view {
        address[4] memory holders = [address(root), address(router), address(quoter), address(launcher)];
        for (uint256 j; j < 4; ++j) {
            for (uint256 i; i < holders.length; ++i) {
                assertEq(_bal(cs[j], holders[i]), 0, "root or periphery holds tokens");
                assertEq(manager.balanceOf(holders[i], cs[j].toId()), 0, "root or periphery holds claims");
            }
            assertEq(_bal(cs[j], address(rules)), 0, "the Rules hold tokens");
            assertEq(manager.balanceOf(address(rules), cs[j].toId()), rules.totalLiability(cs[j]), "Rules claims");
        }
    }

    /// Each member's launch position is the PoolManager's.
    function invariant_launcherCustody() public view {
        for (uint256 i; i < keys.length; ++i) {
            IHookrLauncher.Position memory p = launcher.position(fam, uint8(i));
            bytes32 pk = Position.calculatePositionKey(
                address(launcher), p.tickLower, p.tickUpper, keccak256(abi.encode(fam, uint8(i)))
            );
            assertEq(manager.getPositionLiquidity(keys[i].toId(), pk), p.liquidity, "launcher custody");
        }
    }

    /// Every arb recapture's profit is its push at the pinned 25%, the partner received the rest in each quote (to a
    /// wei per push: the root reads the profit back from the push rounding down, and the stand-in keeps 25% rounding
    /// down), and every split adds up to its push and reports that profit.
    function invariant_partnerKeepsExactlyThePinnedRate() public view {
        assertFalse(handler.ghostPushBelowRate(), "a push below the pinned rate");
        assertFalse(handler.ghostSplitMismatch(), "a split that does not add up to its push or its profit");
        for (uint256 i; i < 3; ++i) {
            uint256 received = _bal(cs[i], partner) - partnerStart[i];
            assertLe(received, handler.partnerOwed(cs[i]), "partner receipts");
            assertGe(received + handler.pushesIn(cs[i]), handler.partnerOwed(cs[i]), "partner receipts, a wei per push");
        }
    }

    /// No before-phase push credited a trader, and no lane call ran while the executor was switched off.
    function invariant_beforePhaseCreditsNoneAndTheBrakeHolds() public view {
        assertFalse(handler.ghostBeforePhaseCredit(), "a before-phase push credited a trader");
        assertFalse(handler.ghostRecapturedWhileOff(), "a lane call while switched off");
        assertEq(handler.failures(), 0, "an arb recapture frame failed");
    }

    /// Every party exits: each member's pending LP share is donated, actors and the protocol claim every quote, the
    /// family owner claims every member's accrual and withdraws every position; nothing is left in the Rules and the PoolManager is settled.
    function afterInvariant() public {
        // Each member's pending LP share is released whole a full release period later, at the first add, outside
        // the range.
        ArbSysKit.nextParent(vm, RELEASE_PARENTS);
        for (uint8 i; i < keys.length; ++i) {
            _newActor(keys[i]).modify(keys[i], 800_040, 800_100, 1e18);
        }
        for (uint256 j; j < 3; ++j) {
            for (uint256 i; i < handler.actorCount(); ++i) {
                address a = handler.actorAt(i);
                if (rules.claimable(cs[j], a) == 0) continue;
                vm.prank(a);
                rules.claim(cs[j]);
            }
            if (rules.claimable(cs[j], protocol) != 0) {
                vm.prank(protocol);
                rules.claim(cs[j]);
            }
            address[2] memory queues = [tax.BUY_TO(), tax.SELL_TO()];
            for (uint256 i; i < 2; ++i) {
                if (rules.claimable(cs[j], queues[i]) == 0) continue;
                vm.prank(queues[i]);
                rules.claim(cs[j]);
            }
        }
        for (uint8 i; i < keys.length; ++i) {
            if (IHookrRecaptureRules(address(rules)).poolAccruedCurrencies(keys[i].toId()).length != 0) {
                launcher.claimRecapture(fam, i, address(this));
            }
            IHookrLauncher.Position memory p = launcher.position(fam, i);
            launcher.withdraw(fam, i, p.liquidity, 0, 0, address(this), vm.getBlockTimestamp());
        }
        for (uint256 j; j < 3; ++j) {
            if (rules.claimable(cs[j], address(this)) != 0) rules.claim(cs[j]);
            assertEq(rules.totalLiability(cs[j]), 0, "liabilities left after every exit");
            assertEq(manager.balanceOf(address(rules), cs[j].toId()), 0, "claims left after every exit");
        }
        invariant_poolManagerSettled();
        invariant_nothingHeld_rulesExactlyBacked();
        emit log_named_uint("handler calls", handler.calls());
        emit log_named_uint("arb recaptures (pushes)", handler.pushes());
        emit log_named_uint("executor chunks: arbitrages", ex.totalArbs());
        emit log_named_uint("executor chunks: family cycles", ex.totalCycles());
    }

    /// The campaign reaches what it checks: an arb recapture that pushes, in each phase.
    function test_handlerReachesArbRecaptures() public {
        handler.buy(0, 0, 5e22);
        assertGt(handler.pushes(), 0, "an after-phase push");
        handler.moveVenue(true, 3e22);
        uint256 before = handler.pushes();
        handler.sell(1, 0, 1e15);
        assertGt(handler.pushes(), before, "a before-phase push");
        invariant_partnerKeepsExactlyThePinnedRate();
        invariant_beforePhaseCreditsNoneAndTheBrakeHolds();
        handler.brake(0, 0);
        before = handler.recaptures();
        handler.buy(0, 0, 5e22);
        assertEq(handler.recaptures(), before, "no lane call while off");
        handler.brake(2, 3_000_000);
        handler.buy(0, 1, 5e22);
        assertGt(handler.recaptures(), before, "on again");
        assertGt(ex.totalCycles(), 0, "family cycles legged on siblings");
        Currency qb = Currency.wrap(address(tokenB));
        assertGt(
            rules.claimable(qb, tax.BUY_TO()) + rules.claimable(qb, tax.SELL_TO()),
            0,
            "legs on the taxed member paid its tax"
        );
        assertGt(ex.totalArbs(), 0, "arbitrages against the outside venue");
        afterInvariant();
    }
}
