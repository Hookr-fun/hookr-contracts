// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CREATE3} from "solmate/src/utils/CREATE3.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLanes} from "../../src/interfaces/IHookrLanes.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {HookrOwnedProfiles} from "../../src/owned/HookrOwnedProfiles.sol";
import {HookrOwnedRootFactory} from "../../src/owned/HookrOwnedRootFactory.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {ReleaseWiring} from "../utils/ReleaseWiring.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice The live executor's shape for these cases (WTH's 0xBAAf): it serves the one root it pins and answers any
///         other caller `NotHook`. On its own root it pushes a set amount of native ETH; its MEV view answers false.
contract RootPinnedStandIn {
    using CurrencyLibrary for Currency;

    error NotHook();

    IPoolManager public immutable manager;
    address public immutable root;
    uint256 public amount;
    uint256 public calls;

    constructor(IPoolManager manager_, address root_) {
        (manager, root) = (manager_, root_);
    }

    function set(uint256 amount_) external {
        amount = amount_;
    }

    function executeArbitrage(PoolKey calldata key, address) external returns (uint256) {
        if (msg.sender != root) revert NotHook();
        ++calls;
        uint256 a = amount;
        if (a == 0) return 0;
        manager.settle{value: a}();
        manager.mint(root, CurrencyLibrary.ADDRESS_ZERO.toId(), a);
        IHookrLaneRoot(root).settleRecapture(key, CurrencyLibrary.ADDRESS_ZERO, a);
        return a;
    }

    function checkV3PoolsMev(address, address, address, bool) external pure returns (bool) {
        return false;
    }

    receive() external payable {}
}

/// @notice What WTH's executor must become to serve owned roots: it accepts `executeArbitrage` from any root the
///         registry registered that has it switched on and that is the pool's hook, and pushes back through the calling
///         root. Each call stands for a set profit in native ETH: it keeps KEEP_BPS of it for the partner and pushes
///         the rest.
contract RootAgnosticStandIn {
    using CurrencyLibrary for Currency;

    error NotTheCallingRoot();

    uint16 public constant KEEP_BPS = 2_500;
    IPoolManager public immutable manager;
    IHookrRegistry public immutable registry;
    address public immutable partner;
    uint256 public profit;
    uint256 public calls;

    constructor(IPoolManager manager_, IHookrRegistry registry_, address partner_) {
        (manager, registry, partner) = (manager_, registry_, partner_);
    }

    function set(uint256 profit_) external {
        profit = profit_;
    }

    /// @dev `msg.sender == key.hooks` alone would let any contract pose as a root and take the push (the lab's I-01):
    ///      the caller must also be a registered root with this executor switched on.
    function executeArbitrage(PoolKey calldata key, address) external returns (uint256) {
        if (msg.sender != address(key.hooks) || !registry.isRoot(msg.sender)) revert NotTheCallingRoot();
        (bool on,) = IHookrLanes(address(registry)).executorLane(msg.sender, address(this));
        if (!on) revert NotTheCallingRoot();
        ++calls;
        uint256 p = profit;
        if (p == 0) return 0;
        uint256 keep = p * KEEP_BPS / 10_000;
        uint256 push = p - keep;
        (bool paid,) = partner.call{value: keep}("");
        require(paid, "partner");
        manager.settle{value: push}();
        manager.mint(msg.sender, CurrencyLibrary.ADDRESS_ZERO.toId(), push);
        IHookrLaneRoot(msg.sender).settleRecapture(key, CurrencyLibrary.ADDRESS_ZERO, push);
        return p;
    }

    function checkV3PoolsMev(address, address, address, bool) external pure returns (bool) {
        return false;
    }

    receive() external payable {}
}

/// @notice A contract that is not a registered root and poses as one to the root-agnostic executor.
contract PosingRoot is IUnlockCallback {
    IPoolManager public immutable manager;
    RootAgnosticStandIn public immutable target;

    constructor(IPoolManager manager_, RootAgnosticStandIn target_) {
        (manager, target) = (manager_, target_);
    }

    function drain() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(1)), 0, 1, IHooks(address(this)));
        target.executeArbitrage(key, address(this));
        return "";
    }

    function settleRecapture(PoolKey calldata, Currency, uint256) external {}
}

/// @notice Owned roots and the recapture lane (owner amendment 3), on the release stack with the release's lane cap
///         (3,000,000) and partner share (2,500): the shared root's lane, a stand-in for the live executor that pins
///         the shared root, is copied onto each owned root at registration with its switch off. A fresh owned root
///         therefore refuses a pool that asks for arb recapture, opens every other pool without a lane, and none of its
///         pools pays the lane's gas floor or ever calls the pinned executor. A timelocked OPEN_LANE queued after the
///         registration moves the owned root to a root-agnostic executor; pools opened from then on recapture with the
///         25% partner and 25% Hookr split, pools opened before stay without a lane. For the record, a timelocked
///         LANE_ON of the pinned executor on an owned root shows what the brake prevents: every call answers NotHook,
///         every arb recapture fails open and every swap still pays the gas floor. The release runbook never queues
///         that LANE_ON.
/// @dev Here, not in the owned-root suites under test/owned: lane frames rely on per-transaction transient state,
///      which the lane profile's `isolate` setting resets between calls as on chain.
contract OwnedRootLaneTest is LaneFixture {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant RECAPTURE_SPLIT = IHookrRecaptureEvents.RecaptureSplit.selector;
    /// @dev The release's lane cap; its partner share is the fixture's PARTNER_BPS, WTH's 2,500.
    uint32 internal constant RELEASE_CAP = 3_000_000;
    /// @dev The release's protocol share floor.
    uint16 internal constant FLOOR = 2_000;
    /// @dev Under the floor of a lane at the release cap (6,802,619), above what a pool without a lane needs.
    uint256 internal constant UNDER_THE_FLOOR = 1_500_000;
    address internal constant TREASURY_TARGET = address(0x7A26E8);
    address internal brand = address(0xB4A9D);

    HookrTreasury internal treasury;
    HookrRules internal sharedRules;
    HookrOwnedProfiles internal book;
    HookrOwnedRootFactory internal factory;
    bytes32 internal profileId;
    RootPinnedStandIn internal pinned;
    uint256 internal saltNonce;

    function setUp() public {
        _setUpLane();
        treasury = new HookrTreasury(address(this), TREASURY_TARGET, manager);
        sharedRules = new HookrRules(manager, registry, address(treasury), address(root), FLOOR);
        ReleaseWiring.admitAfterDelay(registry, address(root), ReleaseWiring.rulesAdmission(sharedRules, 200_000));
        book = new HookrOwnedProfiles(registry);
        factory = new HookrOwnedRootFactory(
            registry,
            book,
            address(root),
            address(sharedRules),
            address(treasury),
            keccak256(type(HookrRoot).creationCode),
            keccak256(type(HookrRules).creationCode),
            500
        );
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), address(factory).codehash, true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setRootFactory(address(factory), address(factory).codehash, true);
        IHookrOwnedProfiles.Profile memory p;
        p.root = address(root);
        p.rules = address(sharedRules);
        p.advisories = new address[](0);
        p.gates = new address[](0);
        p.caps = HookrTypes.Caps(600_000, 200_000, 1000);
        p.ruleMask = F.ALL_FEATURES;
        p.laneEnabled = true;
        p.publicOpening = true;
        p.owner = address(this);
        profileId = book.writeProfile(bytes32("standard"), p);
        // The shared root's lane: the pinned stand-in at the release cap and partner share.
        pinned = new RootPinnedStandIn(manager, address(root));
        _openLane(address(pinned), RELEASE_CAP, PARTNER_BPS);
        vm.deal(brand, 1e28);
    }

    // ───────────────────────────── a fresh owned root ─────────────────────────────

    /// @notice The copy is braked: no active lane, the pinned executor's switch off at the template's cap. A pool
    ///         asking for arb recapture is refused at launch; a plain pool opens without a lane, trades under the floor
    ///         a lane pool needs, and the pinned executor is never called.
    function test_freshOwnedRootOpensNoLanePoolAndNeverCallsThePinnedExecutor() public {
        (HookrRoot owned, HookrRules companion) = _deployOwnedRoot();
        (address active,,,) = registry.activeLaneOf(address(owned));
        assertEq(active, address(0), "the copied lane is braked");
        (bool on, uint32 cap) = registry.executorLane(address(owned), address(pinned));
        assertFalse(on);
        assertEq(cap, RELEASE_CAP, "the template's cap is copied");
        (address templateLane,, uint32 templateCap, uint16 templatePartner) = registry.activeLaneOf(address(root));
        assertEq(templateLane, address(pinned), "the shared root keeps its lane");
        assertEq(templateCap, RELEASE_CAP);
        assertEq(templatePartner, PARTNER_BPS);

        IHookrLauncher.Member[] memory ms = new IHookrLauncher.Member[](1);
        ms[0] = _ownedMember(address(companion), true);
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Owned", "OWN", 1e27, bytes32(++saltNonce));
        vm.prank(brand);
        vm.expectRevert(IHookrRootEvents.InvalidConfig.selector);
        launcher.launch{value: ms[0].amount0Max}(t, address(owned), ms, vm.getBlockTimestamp());

        PoolKey memory key = _launchOnOwned(owned, companion, false);
        (address executor,,,,,, uint256 floor) = IHookrLaneRoot(address(owned)).laneOf(key.toId());
        assertEq(executor, address(0), "no lane");
        assertEq(floor, 0, "no lane gas floor");

        vm.expectCall(address(pinned), abi.encodeWithSelector(RootPinnedStandIn.executeArbitrage.selector), 0);
        vm.expectCall(address(pinned), abi.encodeWithSelector(RootPinnedStandIn.checkV3PoolsMev.selector), 0);
        uint256 out = _swapUnder(key, true, 1 ether, UNDER_THE_FLOOR);
        assertGt(out, 0, "a buy under the lane floor trades");
        assertGt(_swapUnder(key, false, out / 2, UNDER_THE_FLOOR), 0, "and so does a sell");
        assertEq(pinned.calls(), 0);
    }

    /// @notice On the shared root a pool with the lane must carry the floor: the same buy under it reverts there.
    function test_theSharedRootsLanePoolsCarryTheFloor() public {
        IHookrLauncher.Member[] memory ms = new IHookrLauncher.Member[](1);
        ms[0] = _ownedMember(address(sharedRules), true);
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Shared", "SHR", 1e27, bytes32(++saltNonce));
        vm.prank(brand);
        (bytes32 family,) = launcher.launch{value: ms[0].amount0Max}(t, address(root), ms, vm.getBlockTimestamp());
        PoolKey memory key = launcher.position(family, 0).key;
        (address executor,,,,,, uint256 floor) = IHookrLaneRoot(address(root)).laneOf(key.toId());
        assertEq(executor, address(pinned));
        assertEq(floor, _entryFloor(RELEASE_CAP), "6,802,619 at the release cap");
        vm.expectRevert();
        this.swapWithGas(key, true, 1 ether, UNDER_THE_FLOOR);
        assertGt(this.swapWithGas(key, true, 1 ether, 9_000_000), 0);
        assertEq(pinned.calls(), 2, "both phases on its own root");
    }

    // ───────────────────────────── opening the owned root's lane ─────────────────────────────

    /// @notice A timelocked OPEN_LANE queued after the registration moves the owned root to a root-agnostic executor.
    ///         Pools opened from then on recapture: each push splits 25% of the profit it stands for to Hookr after the
    ///         executor kept 25% for the partner. The pool opened before keeps no lane and never calls an executor.
    function test_openLaneAfterRegistrationGivesNewPoolsArbRecapture() public {
        (HookrRoot owned, HookrRules companion) = _deployOwnedRoot();
        PoolKey memory before = _launchOnOwned(owned, companion, false);
        RootAgnosticStandIn agnostic = new RootAgnosticStandIn(manager, registry, partner);
        assertEq(agnostic.KEEP_BPS(), PARTNER_BPS, "the stand-in keeps the share the root reads its profit back at");
        vm.deal(address(agnostic), 1e24);
        bytes memory args =
            abi.encode(address(owned), address(agnostic), address(agnostic).codehash, RELEASE_CAP, PARTNER_BPS);
        registry.queue(OPEN_LANE, args);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrRegistry.NotReady.selector, registry.operationHash(OPEN_LANE, args))
        );
        registry.openLaneOf(address(owned), address(agnostic), address(agnostic).codehash, RELEASE_CAP, PARTNER_BPS);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.openLaneOf(address(owned), address(agnostic), address(agnostic).codehash, RELEASE_CAP, PARTNER_BPS);
        (address active,, uint32 cap, uint16 partnerBps) = registry.activeLaneOf(address(owned));
        assertEq(active, address(agnostic));
        assertEq(cap, RELEASE_CAP);
        assertEq(partnerBps, PARTNER_BPS);
        assertTrue(registry.rootFrozen(address(owned)), "the lane is the freeze's one exception");

        PoolKey memory key = _launchOnOwned(owned, companion, true);
        (address executor,, uint16 frozenPartner,,,, uint256 floor) = IHookrLaneRoot(address(owned)).laneOf(key.toId());
        assertEq(executor, address(agnostic), "the new pool froze the opened lane");
        assertEq(frozenPartner, PARTNER_BPS);
        assertEq(floor, _entryFloor(RELEASE_CAP));

        uint256 profit = 1e18;
        agnostic.set(profit);
        uint256 partnerBefore = partner.balance;
        vm.recordLogs();
        _buyOwned(key, 5 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 successes, uint256 failures) = _recaptures(logs, address(owned));
        assertEq(successes, 2, "both phases recaptured");
        assertEq(failures, 0);
        uint256 keep = profit * agnostic.KEEP_BPS() / 10_000;
        uint256 push = profit - keep;
        uint256 splits;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(companion) || logs[i].topics[0] != RECAPTURE_SPLIT) continue;
            (,,, uint256 toProtocol,, uint256 reported) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, Currency, uint256));
            assertEq(reported, _profitOf(push), "the profit the push stands for");
            assertEq(toProtocol, _cut(reported, push), "Hookr's 25% of the profit");
            ++splits;
        }
        assertEq(splits, 2);
        assertEq(partner.balance - partnerBefore, 2 * keep, "the partner's 25% of each profit");

        // The pool opened while the lane was braked stays without one.
        (executor,,,,,, floor) = IHookrLaneRoot(address(owned)).laneOf(before.toId());
        assertEq(executor, address(0));
        assertEq(floor, 0);
        uint256 callsBefore = agnostic.calls();
        assertGt(_swapUnder(before, true, 1 ether, UNDER_THE_FLOOR), 0);
        assertEq(agnostic.calls(), callsBefore, "never calls an executor");
        assertEq(pinned.calls(), 0, "the pinned executor was never called on the owned root");
    }

    /// @notice The opened lane takes every lane brake: the switch off stops the executor at the next swap and the
    ///         pool trades without the floor; closing the lane opens later pools without one.
    function test_theOpenedLaneTakesTheBrakes() public {
        (HookrRoot owned, HookrRules companion) = _deployOwnedRoot();
        RootAgnosticStandIn agnostic = new RootAgnosticStandIn(manager, registry, partner);
        vm.deal(address(agnostic), 1e24);
        registry.queue(
            OPEN_LANE,
            abi.encode(address(owned), address(agnostic), address(agnostic).codehash, RELEASE_CAP, PARTNER_BPS)
        );
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.openLaneOf(address(owned), address(agnostic), address(agnostic).codehash, RELEASE_CAP, PARTNER_BPS);
        PoolKey memory key = _launchOnOwned(owned, companion, true);
        agnostic.set(1e17);
        _buyOwned(key, 1 ether);
        assertEq(agnostic.calls(), 2);
        registry.stopExecutorLane(address(owned), address(agnostic));
        (,,,,,, uint256 floor) = IHookrLaneRoot(address(owned)).laneOf(key.toId());
        assertEq(floor, 0, "no floor while the switch is off");
        assertGt(_swapUnder(key, true, 1 ether, UNDER_THE_FLOOR), 0);
        assertEq(agnostic.calls(), 2, "the stopped executor is not called");
        registry.closeLaneOf(address(owned));
        PoolKey memory later = _launchOnOwned(owned, companion, false);
        (address executor,,,,,,) = IHookrLaneRoot(address(owned)).laneOf(later.toId());
        assertEq(executor, address(0));
        IHookrLauncher.Member[] memory ms = new IHookrLauncher.Member[](1);
        ms[0] = _ownedMember(address(companion), true);
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Owned", "OWN", 1e27, bytes32(++saltNonce));
        vm.prank(brand);
        vm.expectRevert(IHookrRootEvents.InvalidConfig.selector);
        launcher.launch{value: ms[0].amount0Max}(t, address(owned), ms, vm.getBlockTimestamp());
    }

    // ───────────────────────────── what the brake prevents ─────────────────────────────

    /// @notice For the record: a LANE_ON of the pinned executor queued in the registration's second is refused (the
    ///         copy's brake time); one queued later switches it on. A recapture pool then opens with it, every lane
    ///         call answers NotHook, both phases fail open and record CorrectionFailed, nothing is split, and every
    ///         swap still pays the floor. The release runbook never queues this LANE_ON.
    function test_laneOnOfThePinnedExecutorShowsWhatTheBrakePrevents() public {
        (HookrRoot owned, HookrRules companion) = _deployOwnedRoot();
        bytes32 laneOn = LANE_ON;
        bytes memory args = abi.encode(address(owned), address(pinned), RELEASE_CAP);
        bytes32 early = registry.queue(laneOn, args);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QueuedBeforeBrake.selector, early));
        registry.startExecutorLaneAt(address(owned), address(pinned), RELEASE_CAP);
        registry.cancel(early);
        registry.queue(laneOn, args);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.startExecutorLaneAt(address(owned), address(pinned), RELEASE_CAP);
        (address active,,,) = registry.activeLaneOf(address(owned));
        assertEq(active, address(pinned));

        PoolKey memory key = _launchOnOwned(owned, companion, true);
        (address executor,,,,,, uint256 floor) = IHookrLaneRoot(address(owned)).laneOf(key.toId());
        assertEq(executor, address(pinned));
        assertEq(floor, _entryFloor(RELEASE_CAP), "the floor is charged");
        pinned.set(1e17);
        vm.recordLogs();
        _buyOwned(key, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 successes, uint256 failures) = _recaptures(logs, address(owned));
        assertEq(successes, 0);
        assertEq(failures, 2, "both phases fail open");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(owned) && logs[i].topics[0] == FAILED) {
                assertEq(abi.decode(logs[i].data, (bytes4)), RootPinnedStandIn.NotHook.selector);
            }
            assertTrue(logs[i].topics[0] != RECAPTURE_SPLIT, "nothing to split");
        }
        assertEq(pinned.calls(), 0, "the pinned executor never served the owned root");
        vm.expectRevert();
        this.swapWithGas(key, true, 1 ether, UNDER_THE_FLOOR);
    }

    /// @notice The root-agnostic executor must authenticate its caller as a registered root with it switched on: a
    ///         contract posing as a root is refused and takes nothing.
    function test_rootAgnosticExecutorRefusesAPosingRoot() public {
        RootAgnosticStandIn agnostic = new RootAgnosticStandIn(manager, registry, partner);
        vm.deal(address(agnostic), 1e24);
        agnostic.set(1 ether);
        PosingRoot fake = new PosingRoot(manager, agnostic);
        assertFalse(registry.isRoot(address(fake)));
        uint256 before = address(agnostic).balance;
        vm.expectRevert(RootAgnosticStandIn.NotTheCallingRoot.selector);
        fake.drain();
        assertEq(address(agnostic).balance, before);
        assertEq(agnostic.calls(), 0);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function swapWithGas(PoolKey memory key, bool buy, uint256 amount, uint256 gasLimit) external returns (uint256) {
        require(msg.sender == address(this));
        return _swapWithGas(key, buy, amount, gasLimit);
    }

    /// @dev `brand` deploys a public owned root from the standard profile through the factory, paying its fee.
    function _deployOwnedRoot() internal returns (HookrRoot owned, HookrRules companion) {
        IHookrOwnedRootFactory.RootSelections memory sel = IHookrOwnedRootFactory.RootSelections({
            profileId: profileId,
            profileVersion: book.profile(profileId).version,
            ruleMask: F.ALL_FEATURES,
            publicOpening: true,
            owner: brand
        });
        bytes32 salt = _mineSalt(brand);
        uint256 fee = factory.deployFee();
        vm.prank(brand);
        owned = HookrRoot(
            factory.deploy{value: fee}(type(HookrRoot).creationCode, type(HookrRules).creationCode, sel, salt)
        );
        companion = HookrRules(factory.rulesOf(address(owned)));
    }

    /// @dev A native-quote member on `rulesAddr`: the lane rules, with the recapture lane when `recapture`.
    function _ownedMember(address rulesAddr, bool recapture) internal view returns (IHookrLauncher.Member memory m) {
        HookrTypes.RecaptureConfig memory off;
        m = _laneMember(ETH, _laneRules(false), recapture ? _recaptureOnlyRc() : off);
        m.config.rules = rulesAddr;
    }

    /// @dev A new token's pool on `owned`, launched by `brand`.
    function _launchOnOwned(HookrRoot owned, HookrRules companion, bool recapture) internal returns (PoolKey memory) {
        IHookrLauncher.Member[] memory ms = new IHookrLauncher.Member[](1);
        ms[0] = _ownedMember(address(companion), recapture);
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Owned", "OWN", 1e27, bytes32(++saltNonce));
        vm.prank(brand);
        (bytes32 family,) = launcher.launch{value: ms[0].amount0Max}(t, address(owned), ms, vm.getBlockTimestamp());
        return launcher.position(family, 0).key;
    }

    /// @dev An exact-input swap of `amount` through the pinned router as `brand`, which holds the supply of the tokens
    ///      it launched, with at most `gasLimit` gas. The quote is native, so the subject is currency1.
    function _swapWithGas(PoolKey memory key, bool buy, uint256 amount, uint256 gasLimit)
        internal
        returns (uint256 out)
    {
        IHookrRouter.Swap memory p = _swapParams(key, ETH, buy, true, amount, brand);
        if (!buy) {
            vm.prank(brand);
            HookrToken(Currency.unwrap(key.currency1)).approve(address(router), type(uint256).max);
        }
        vm.prank(brand);
        (, out) = router.swap{value: buy ? amount : 0, gas: gasLimit}(p, address(0), new uint256[](0));
    }

    /// @dev A swap with `gasLimit`, as its own transaction.
    function _swapUnder(PoolKey memory key, bool buy, uint256 amount, uint256 gasLimit) internal returns (uint256) {
        return this.swapWithGas(key, buy, amount, gasLimit);
    }

    /// @dev A buy of `quoteIn` with gas well above the release floor.
    function _buyOwned(PoolKey memory key, uint256 quoteIn) internal returns (uint256) {
        return this.swapWithGas(key, true, quoteIn, 9_000_000);
    }

    /// @dev CorrectionSucceeded and CorrectionFailed events `emitter` logged.
    function _recaptures(Vm.Log[] memory logs, address emitter)
        internal
        pure
        returns (uint256 successes, uint256 failures)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics[0] == SUCCEEDED) ++successes;
            else if (logs[i].topics[0] == FAILED) ++failures;
        }
    }

    /// @dev A salt for `deployer` whose CREATE3 address under the factory carries the root's permission flags.
    function _mineSalt(address deployer) internal returns (bytes32 salt) {
        for (uint256 i = (uint256(uint160(deployer)) << 64) + (++saltNonce << 32);; ++i) {
            address predicted = CREATE3.getDeployed(keccak256(abi.encode(deployer, bytes32(i))), address(factory));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == ReleaseWiring.ROOT_FLAGS) return salt = bytes32(i);
        }
    }
}
