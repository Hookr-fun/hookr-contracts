// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
// HookrRegistry and HookrLauncher link these four libraries. Importing them here keeps them in every lane suite's
// compilation, so forge can link both.
import {HookrRegistryChecks} from "../../src/libraries/HookrRegistryChecks.sol";
import {HookrRegistryAdmin} from "../../src/libraries/HookrRegistryAdmin.sol";
import {HookrTokenDeployer} from "../../src/libraries/HookrTokenDeployer.sol";
import {HookrLaunchChecks} from "../../src/libraries/HookrLaunchChecks.sol";
import {TwoVenueExecutor} from "./mocks/TwoVenueExecutor.sol";
import {HooklessPoolSeeder} from "./mocks/HooklessPoolSeeder.sol";
import {Actor} from "./mocks/Actors.sol";
import {ArbSysKit} from "../kit/ArbSysMock.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";

/// @notice The release stack (PoolManager, registry, HookrRoot with its HookrLane module, HookrRules with its
///         HookrRecapture module, router, quoter, HookrLauncher) with the recapture lane: pools launch through the
///         release launcher as `creator`, the family owner, and freeze the lane the registry has open on the root.
abstract contract LaneFixture is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    bytes32 internal constant SUCCEEDED =
        keccak256("CorrectionSucceeded(bytes32,uint8,address,uint256,uint256,address)");
    bytes32 internal constant FAILED = keccak256("CorrectionFailed(bytes32,uint8,address,bytes4)");
    bytes32 internal constant OPEN_LANE = keccak256("OPEN_LANE");
    bytes32 internal constant LANE_ON = keccak256("LANE_ON");
    bytes32 internal constant ADD_SETTLEMENT = keccak256("ADD_SETTLEMENT");

    HooklessPoolSeeder internal seeder;
    Actor internal mover;
    address internal partner = address(0x2001);
    address internal creator = address(0x2002);
    address internal whale = address(0x2003);
    address internal minnow = address(0x2004);
    address internal attacker = address(0x2005);
    /// @dev The partner share every lane suite opens the lane at: WTH's production share, 25%, the registry's cap
    ///      (MAX_LANE_PARTNER_BPS). The suites' "pinned 25%" is this share.
    uint16 internal constant PARTNER_BPS = 2_500;
    /// @dev Hookr's cut of every arb recapture, in basis points of the profit a push stands for: the Rules'
    ///      RECAPTURE_PROTOCOL_BPS, 25%.
    uint16 internal constant PROTOCOL_BPS = 2_500;
    uint32 internal constant PERIOD = 1 days;
    uint24 internal constant BASE_FEE = 10_000;
    /// @dev The two-venue executor's measured cost with its bounded crossings on both legs is under 450k
    ///      (DustTicks).
    uint32 internal constant LANE_GAS = 600_000;
    uint128 internal constant MIN_BUY = 1e18;
    /// @dev The King of the Pool pools' native rules: the protocol's 25% of 4% LP Rewards is 1% of every buy, and half
    ///      of it, 0.5%, is the largest prize ceiling they admit (HookrRecapture.prizeBound).
    uint16 internal constant SHARE = 2500;
    uint16 internal constant KOTH_LP_REWARDS = 400;
    uint16 internal constant POT_BPS = 4000;
    uint16 internal constant TRADER_BPS = 2000;
    /// @dev The release period every fixture config freezes, in L2 blocks: the least allowed, so a test reaches a full
    ///      release in few parent blocks.
    uint32 internal constant RELEASE = 1_200;
    /// @dev Parent blocks (block.number) in one release period under the Nitro clock model (ArbSysKit): 120 L2 blocks
    ///      to a parent block, so each `_nextBlock` releases 1/RELEASE_PARENTS of a pending share.
    uint256 internal constant RELEASE_PARENTS = RELEASE / ArbSysKit.L2_PER_PARENT;
    Currency internal constant ETH = Currency.wrap(address(0));

    struct Outcome {
        uint256 succeeded;
        uint256 failed;
        uint256 pushedBefore;
        uint256 pushedAfter;
        bytes4 lastReason;
        uint256 profitBefore;
        uint256 profitAfter;
    }

    /// @dev The recapture suites run at the global protocol share floor the release deploys (Rehearse.s.sol).
    function _minProtocolShareBps() internal view virtual override returns (uint16) {
        return 2_000;
    }

    function _setUpLane() internal {
        _parentClock();
        _setUpPeriphery();
        _setUpLaneActors();
    }

    /// @dev The same stack on an existing PoolManager (a fork's).
    function _setUpLaneOn(IPoolManager pm) internal {
        _parentClock();
        _deployPeriphery(pm);
        _setUpLaneActors();
    }

    /// @dev Under a whole-suite fork run (`--fork-url robinhood`) block.number starts at the fork's L2 header number,
    ///      L2_BASE itself, which would put the two clocks together. Inside a contract on Robinhood Chain block.number
    ///      is the parent height, so a suite that has not rolled there starts at L2_BASE's parent height.
    function _parentClock() internal {
        if (vm.getBlockNumber() >= ArbSysKit.PARENT_BASE * 2) vm.roll(ArbSysKit.PARENT_BASE);
    }

    function _setUpLaneActors() internal {
        // Robinhood Chain's two clocks: ArbSys at 0x64 answers an L2 height about 74M away from block.number, 120 L2
        // blocks to a parent block, so a release that read the wrong clock shows. On a fork this is the pinned block
        // (L2_BASE) at the parent height the suite rolled to.
        ArbSysKit.install(vm, ArbSysKit.L2_BASE, vm.getBlockNumber());
        seeder = new HooklessPoolSeeder(manager);
        tokenA.approve(address(seeder), type(uint256).max);
        tokenB.approve(address(seeder), type(uint256).max);
        address[4] memory people = [creator, whale, minnow, attacker];
        for (uint256 i; i < people.length; ++i) {
            vm.deal(people[i], 1e28);
            tokenA.transfer(people[i], 1e27);
            tokenB.transfer(people[i], 1e27);
            vm.startPrank(people[i]);
            tokenA.approve(address(router), type(uint256).max);
            tokenB.approve(address(router), type(uint256).max);
            tokenA.approve(address(launcher), type(uint256).max);
            tokenB.approve(address(launcher), type(uint256).max);
            vm.stopPrank();
        }
        mover = _newActor();
    }

    // ───────────── the lane ─────────────

    function _openLane(address executor, uint32 gasCap) internal {
        _openLane(executor, gasCap, PARTNER_BPS);
    }

    /// @dev Opens `executor` as the root's lane at the partner share `partnerBps`; pools launched after it freeze it.
    function _openLane(address executor, uint32 gasCap, uint16 partnerBps) internal {
        registry.queue(OPEN_LANE, abi.encode(address(root), executor, executor.codehash, gasCap, partnerBps));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.openLaneOf(address(root), executor, executor.codehash, gasCap, partnerBps);
    }

    /// @dev Adds `currency` to the registry's recapture settlement set through the timelock.
    function _settlementCurrency(address currency) internal {
        registry.queue(ADD_SETTLEMENT, abi.encode(currency));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.addSettlementCurrency(currency);
    }

    /// @dev Turns the pool's pending LP share into the liquidity owner's accrual: `owner` withdraws all of the family
    ///      member's launch liquidity in this block (the pool's only liquidity), and in the next block an outside LP's
    ///      add finds no in-range liquidity when the share is flushed, before the add lands. Returns that LP.
    function _pendingToOwner(PoolKey memory key, bytes32 family, uint8 member, address owner)
        internal
        returns (Actor lp)
    {
        uint128 l = launcher.position(family, member).liquidity;
        vm.prank(owner);
        launcher.withdraw(family, member, l, 0, 0, owner, vm.getBlockTimestamp());
        // A full release period later the whole pending share is released, with no liquidity in range.
        ArbSysKit.nextParent(vm, RELEASE_PARENTS);
        lp = _newActor(key);
        Currency other = key.currency0 == _subjectOf(key) ? key.currency1 : key.currency0;
        if (!other.isAddressZero()) {
            uint256 held = HookrToken(Currency.unwrap(other)).balanceOf(address(this));
            HookrToken(Currency.unwrap(other)).transfer(address(lp), held < 4e24 ? held / 4 : 1e24);
            lp.approveAll(Currency.unwrap(other));
        }
        lp.modify(key, -600, 600, 1e18);
    }

    function _openLane(address executor) internal {
        _openLane(executor, LANE_GAS);
    }

    function _switchOn(address executor, uint32 gasCap) internal {
        registry.queue(LANE_ON, abi.encode(address(root), executor, gasCap));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.startExecutorLaneAt(address(root), executor, gasCap);
    }

    /// @dev A two-venue executor for the fixture root against the pair's hookless 0.3% spacing-60 reference venue.
    function _twoVenueExecutor(uint128 maxQuoteIn) internal returns (TwoVenueExecutor) {
        return new TwoVenueExecutor(manager, address(root), partner, PARTNER_BPS, 3000, 60, address(0), maxQuoteIn);
    }

    /// @dev The gas a lane swap must carry when it reaches the before-phase (HookrLane.entryFloorOf): the call floor
    ///      `cap + cap/63 + 155,000`, the before-phase's whole grant and the 600,000 the swap's own work may take
    ///      until the after-phase.
    function _entryFloor(uint256 cap) internal pure returns (uint256) {
        return cap + cap / 63 + 155_000 + cap + 600_000;
    }

    function _laneOf(PoolKey memory key)
        internal
        view
        returns (address executor, bool on, uint32 gasCap, uint256 floor)
    {
        (executor,,,, on, gasCap, floor) = IHookrLaneRoot(address(root)).laneOf(key.toId());
    }

    function _outcome(Vm.Log[] memory logs) internal view returns (Outcome memory o) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(root)) continue;
            if (logs[i].topics[0] == SUCCEEDED) {
                o.succeeded++;
                (uint256 profit, uint256 p) = abi.decode(logs[i].data, (uint256, uint256));
                if (uint256(logs[i].topics[2]) == 1) {
                    (o.pushedBefore, o.profitBefore) = (o.pushedBefore + p, o.profitBefore + profit);
                } else {
                    (o.pushedAfter, o.profitAfter) = (o.pushedAfter + p, o.profitAfter + profit);
                }
            } else if (logs[i].topics[0] == FAILED) {
                o.failed++;
                o.lastReason = abi.decode(logs[i].data, (bytes4));
            }
        }
    }

    // ───────────── configs ─────────────

    /// @dev Recapture with King of the Pool: 20% trader, 40% pot, 40% LP of the push net of the protocol's cut (25%
    ///      of the profit the push stands for).
    function _kothRc() internal pure virtual returns (HookrTypes.RecaptureConfig memory c) {
        c.on = true;
        c.traderBps = TRADER_BPS;
        c.lpBps = 10_000 - TRADER_BPS - POT_BPS;
        c.period = PERIOD;
        c.maxPrizeBps = 50;
        c.potReleaseBps = _potReleaseBps();
        c.minBuyQuote = MIN_BUY;
        c.releaseBlocks = RELEASE;
    }

    /// @dev Recapture without King of the Pool: 20% trader, 80% LP.
    function _recaptureOnlyRc() internal pure returns (HookrTypes.RecaptureConfig memory c) {
        c.on = true;
        c.traderBps = TRADER_BPS;
        c.lpBps = 10_000 - TRADER_BPS;
        c.releaseBlocks = RELEASE;
    }

    /// @dev The pot release every `_kothRc` pool freezes: half per closed epoch unless a suite overrides it.
    function _potReleaseBps() internal pure virtual returns (uint16) {
        return 5_000;
    }

    /// @dev The native rules of a recapture pool: 1% base fee, the protocol's 25%, and for King of the Pool 4% LP
    ///      Rewards (so the protocol takes 1% of every buy) with the pot share.
    function _laneRules(bool koth) internal pure returns (HookrTypes.RulesConfig memory r) {
        r.maxFeePips = BASE_FEE;
        r.protocolShareBps = SHARE;
        if (koth) {
            r.lpBps = KOTH_LP_REWARDS;
            r.potBps = POT_BPS;
        }
    }

    // ───────────── launches ─────────────

    /// @dev A fresh subject held by the test, the people and the mover, approved for the router, launcher and seeder.
    function _newSubject() internal returns (HookrToken t) {
        t = new HookrToken("S", "S", 1e30, address(this));
        t.approve(address(launcher), type(uint256).max);
        t.approve(address(seeder), type(uint256).max);
        address[5] memory people = [creator, whale, minnow, attacker, address(mover)];
        for (uint256 i; i < people.length; ++i) {
            t.transfer(people[i], 1e27);
            vm.startPrank(people[i]);
            t.approve(address(router), type(uint256).max);
            t.approve(address(launcher), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev One member: `liquidity` 1e24 over [-60,000, 60,000] at price 1, the fixture's Rules at `BASE_FEE`.
    function _laneMember(Currency quote, HookrTypes.RulesConfig memory r, HookrTypes.RecaptureConfig memory rc)
        internal
        view
        returns (IHookrLauncher.Member memory m)
    {
        m.quote = quote;
        m.tickSpacing = 60;
        m.sqrtPriceX96 = SQRT_ONE;
        m.tickLower = -60_000;
        m.tickUpper = 60_000;
        m.liquidity = 1e24;
        m.amount0Max = 1e24;
        m.amount1Max = 1e24;
        m.config.rules = address(rules);
        m.config.baseLpFeePips = BASE_FEE;
        m.config.caps = HookrTypes.Caps(600_000, 200_000, 1000);
        m.config.rulesGasLimit = 2_000_000;
        m.config.policyId = keccak256("lane");
        m.rules = r;
        m.recapture = rc;
    }

    /// @dev Launches a one-member family of `subject` as `creator`, the family owner.
    function _launchAs(address owner, HookrToken subject, IHookrLauncher.Member[] memory members)
        internal
        returns (bytes32 family, PoolKey[] memory keys)
    {
        uint256 value;
        for (uint256 i; i < members.length; ++i) {
            if (members[i].quote.isAddressZero()) value = members[i].amount0Max;
        }
        vm.prank(owner);
        (family,) = launcher.launch{value: value}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        keys = new PoolKey[](members.length);
        for (uint256 i; i < members.length; ++i) {
            keys[i] = launcher.position(family, uint8(i)).key;
        }
    }

    /// @dev Launches one pool of a fresh subject against `quote` as `creator`.
    function _openPool(Currency quote, HookrTypes.RulesConfig memory r, HookrTypes.RecaptureConfig memory rc)
        internal
        returns (PoolKey memory key)
    {
        (key,) = _openPoolWithFamily(quote, r, rc);
    }

    function _openPoolWithFamily(Currency quote, HookrTypes.RulesConfig memory r, HookrTypes.RecaptureConfig memory rc)
        internal
        returns (PoolKey memory key, bytes32 family)
    {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(quote, r, rc);
        PoolKey[] memory keys;
        (family, keys) = _launchAs(creator, _newSubject(), members);
        key = keys[0];
    }

    /// @dev A King of the Pool pool of a fresh subject against `quote`.
    function _openKoth(HookrTypes.RecaptureConfig memory rc, Currency quote) internal returns (PoolKey memory) {
        return _openPool(quote, _laneRules(true), rc);
    }

    function _openKoth(Currency quote) internal returns (PoolKey memory) {
        return _openPool(quote, _laneRules(true), _kothRc());
    }

    /// @dev A recapture pool without King of the Pool.
    function _openRecapture(Currency quote) internal returns (PoolKey memory) {
        return _openPool(quote, _laneRules(false), _recaptureOnlyRc());
    }

    /// @dev A pool without recapture, with the phase-one fixture's full native rules.
    function _openStd(Currency quote) internal returns (PoolKey memory) {
        HookrTypes.RulesConfig memory r;
        r.maxFeePips = BASE_FEE;
        r.burnBps = 100;
        r.lpBps = 200;
        r.royaltyBps = 500;
        r.protocolShareBps = SHARE;
        r.royaltyTo = royalty;
        HookrTypes.RecaptureConfig memory off;
        return _openPool(quote, r, off);
    }

    // ───────────── venues ─────────────

    function _ref(PoolKey memory key) internal pure returns (PoolKey memory) {
        return PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(address(0)));
    }

    /// @dev A hookless reference venue of the pool's pair, fee 0.3%, spacing 60, same liquidity shape.
    function _seedReference(PoolKey memory key) internal returns (PoolKey memory ref) {
        ref = _ref(key);
        seeder.seed{value: key.currency0.isAddressZero() ? 1e24 : 0}(ref, SQRT_ONE, -60_000, 60_000, 1e24);
    }

    /// @dev Raises the reference venue's price to `priceWad` (currency1 per currency0); a no-op when it is there.
    function _moveReference(PoolKey memory key, uint256 priceWad) internal {
        uint160 target = uint160(Math.sqrt(priceWad * 1e18) * (1 << 96) / 1e18);
        (uint160 current,,,) = manager.getSlot0(_ref(key).toId());
        if (current >= target) return;
        mover.directSwap(_ref(key), false, -int256(1e26), target);
    }

    /// @dev Sends every fuzzed call from one account no invariant reads: under `isolate` on a fork, whose base fee is
    ///      not zero, a call's sender is left holding ETH for its gas, which would read as a balance of the system or
    ///      of a party the invariants account for when the fuzzer picks one of them as the sender.
    function _targetPlainSender() internal {
        targetSender(address(uint160(uint256(keccak256("hookr.invariant.sender")))));
    }

    /// @dev The next parent block (block.number + 1, 12 seconds later): 120 L2 blocks under the Nitro clock model.
    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
    }

    /// @dev `k` sequencer-paced L2 blocks inside the current parent block: the release clock moves, block.number does
    ///      not, and the time moves with them at 10 a second (ArbSysKit.stepL2).
    function _stepL2(uint256 k) internal {
        ArbSysKit.stepL2(vm, k);
    }

    /// @dev The L2 height ArbSys answers now.
    function _l2() internal view returns (uint256) {
        return ArbSysKit.l2();
    }

    /// @dev What the Rules release of a pending `amount` `age` L2 blocks after its release block, over a release period
    ///      of `n` (HookrRecapture._released).
    function _releasedAfter(uint256 amount, uint256 age, uint256 n) internal pure returns (uint256 out) {
        if (age == 0) return 0;
        if (age >= n) return amount;
        out = (amount * age + n - 1) / n;
    }

    // ───────────── swaps ─────────────

    function _poolQuote(PoolKey memory key) internal view returns (Currency) {
        return root.poolConfig(key.toId()).quote;
    }

    function _subjectOf(PoolKey memory key) internal view returns (Currency) {
        return root.poolConfig(key.toId()).subject;
    }

    function _swapParams(PoolKey memory key, Currency quote, bool buy, bool exactInput, uint256 amount, address to)
        internal
        view
        returns (IHookrRouter.Swap memory p)
    {
        bool quoteIs0 = Currency.unwrap(key.currency0) == Currency.unwrap(quote);
        bool zeroForOne = buy ? quoteIs0 : !quoteIs0;
        p = IHookrRouter.Swap(
            key,
            zeroForOne,
            exactInput ? -int128(int256(amount)) : int128(int256(amount)),
            exactInput ? 1 : uint128(1e27),
            zeroForOne ? MIN_PRICE : MAX_PRICE,
            to,
            vm.getBlockTimestamp()
        );
    }

    /// @dev Authenticated exact-input buy of `quoteIn` through the pinned router, as `who`.
    function _buy(PoolKey memory key, Currency quote, address who, uint256 quoteIn) internal returns (uint256 out) {
        IHookrRouter.Swap memory p = _swapParams(key, quote, true, true, quoteIn, who);
        vm.prank(who);
        (, out) = router.swap{value: quote.isAddressZero() ? quoteIn : 0}(p, address(0), new uint256[](0));
    }

    /// @dev Authenticated exact-input sell of `subjectIn` through the pinned router, as `who`.
    function _sell(PoolKey memory key, Currency quote, address who, uint256 subjectIn) internal returns (uint256 out) {
        IHookrRouter.Swap memory p = _swapParams(key, quote, false, true, subjectIn, who);
        vm.prank(who);
        (, out) = router.swap(p, address(0), new uint256[](0));
    }

    /// @dev An actor holding ETH, tokenA and tokenB, approved for the router. Fund it with a subject separately.
    function _newActor() internal returns (Actor a) {
        a = new Actor(manager, router);
        vm.deal(address(a), 1e28);
        tokenA.transfer(address(a), 1e27);
        tokenB.transfer(address(a), 1e27);
        a.approveAll(address(tokenA));
        a.approveAll(address(tokenB));
    }

    /// @dev An actor that also holds and approved the pool's subject.
    function _newActor(PoolKey memory key) internal returns (Actor a) {
        a = _newActor();
        address s = Currency.unwrap(_subjectOf(key));
        HookrToken(s).transfer(address(a), 1e26);
        a.approveAll(s);
    }

    // ───────────── recapture reads ─────────────

    function _recap() internal view returns (IHookrRecaptureRules) {
        return IHookrRecaptureRules(address(rules));
    }

    function _hill(PoolKey memory key)
        internal
        view
        returns (uint64 start, address leader, uint128 amount, uint128 pot)
    {
        (start,, leader, amount, pot) = _recap().hill(key.toId());
    }

    /// @dev The pool's LP share not yet paid out: the liquidity owner's accrual and the pending donation, in both of
    ///      the pool's currencies (the suites push in one currency, so only one side is nonzero).
    function _accrued(PoolKey memory key) internal view returns (uint256 total) {
        PoolId id = key.toId();
        (uint256 d0, uint256 d1, uint256 f0, uint256 f1,) = _recap().pendingDonation(id);
        total = _recap().poolAccrued(id, key.currency0) + _recap().poolAccrued(id, key.currency1) + d0 + d1 + f0 + f1;
    }

    /// @dev The pool's pending donation, due and fresh, in both currencies.
    function _pending(PoolKey memory key) internal view returns (uint256) {
        (uint256 d0, uint256 d1, uint256 f0, uint256 f1,) = _recap().pendingDonation(key.toId());
        return d0 + d1 + f0 + f1;
    }

    /// @dev Releases the whole of the pool's pending LP share: a full release period (RELEASE L2 blocks,
    ///      RELEASE_PARENTS parent blocks) later, a dust add at the top of the tick range, which changes no in-range
    ///      liquidity, flushes it.
    function _flushAll(PoolKey memory key) internal {
        if (_pending(key) == 0) return;
        ArbSysKit.nextParent(vm, RELEASE_PARENTS);
        int24 top = TickMath.maxUsableTick(key.tickSpacing);
        _newActor(key).modify(key, top - key.tickSpacing, top, 1);
        assertEq(_pending(key), 0, "the whole pending share released");
    }

    /// @dev The liquidity owner's accrual in both of the pool's currencies.
    function _ownerAccrued(PoolKey memory key) internal view returns (uint256) {
        PoolId id = key.toId();
        return _recap().poolAccrued(id, key.currency0) + _recap().poolAccrued(id, key.currency1);
    }

    struct Splits {
        uint256 count;
        uint256 trader;
        uint256 lp;
        uint256 pot;
        uint256 protocol;
        address lastTrader;
        uint256 reported;
    }

    /// @dev Totals of the Rules' RecaptureSplit events in `logs`: the four legs and the profit the pushes stood for.
    function _splits(Vm.Log[] memory logs) internal view returns (Splits memory t) {
        bytes32 topic = IHookrRecaptureEvents.RecaptureSplit.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rules) || logs[i].topics[0] != topic) continue;
            (uint256 tr, uint256 lp, uint256 pot, uint256 pro,, uint256 reported) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, Currency, uint256));
            t.count++;
            t.trader += tr;
            t.lp += lp;
            t.pot += pot;
            t.protocol += pro;
            t.lastTrader = address(uint160(uint256(logs[i].topics[2])));
            t.reported += reported;
        }
    }

    /// @dev The profit a push of `pushed` stands for at the fixture's pinned partner share: the executor kept
    ///      PARTNER_BPS of it and pushed the rest (HookrLane._run), rounded down.
    function _profitOf(uint256 pushed) internal pure returns (uint256) {
        return pushed * 10_000 / (10_000 - PARTNER_BPS);
    }

    /// @dev The protocol's cut of one push of `pushed` standing for `profit`: 25% of the profit, at most the push.
    function _cut(uint256 profit, uint256 pushed) internal pure returns (uint256) {
        uint256 c = profit * PROTOCOL_BPS / 10_000;
        return c < pushed ? c : pushed;
    }

    /// @dev The split of one push `p` at the pinned partner share: the protocol's 25% of the profit the push stands
    ///      for first, then trader (if named), pot, LP. What the executor returns is not read.
    function _split(uint256 p, bool trader, uint16 potBps, uint16 traderBps)
        internal
        pure
        returns (uint256 toProtocol, uint256 toTrader, uint256 toPot, uint256 toLp)
    {
        return _split(_profitOf(p), p, trader, potBps, traderBps);
    }

    /// @dev The split of one push `p` standing for `profit`, the trader's basis covering the push: the protocol's
    ///      25% of the profit (at most the push) first, then trader (if named), pot, LP.
    function _split(uint256 profit, uint256 p, bool trader, uint16 potBps, uint16 traderBps)
        internal
        pure
        returns (uint256 toProtocol, uint256 toTrader, uint256 toPot, uint256 toLp)
    {
        toProtocol = _cut(profit, p);
        uint256 rest = p - toProtocol;
        toTrader = trader ? rest * traderBps / 10_000 : 0;
        toPot = rest * potBps / 10_000;
        toLp = rest - toTrader - toPot;
    }
}
