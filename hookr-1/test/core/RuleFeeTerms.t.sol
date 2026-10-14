// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

/// @notice Rule-fee terms: the governed floor of a pool's protocolShareBps, raisable and lowerable by the treasury
///         owner through a 30-minute timelock and never below the Rules' immutable floor, read once at bind; and the
///         integrator list, whose entries a pool names at launch and is paid on, at the rate frozen at bind, of every
///         Hookr share of the Snipe, dynamic fee, LP Rewards and Auto Burn, the odd unit to the protocol.
contract RuleFeeTermsTest is GovernanceSecurityBase {
    using PoolIdLibrary for PoolKey;

    Currency internal constant NATIVE = Currency.wrap(address(0));
    address internal constant TARGET = address(0x7A7);
    address internal constant INTEGRATOR = address(0x1A7E);
    address internal constant OTHER = address(0x2B8F);
    uint16 internal constant RELEASE_FLOOR = 2_000;

    HookrTreasury internal treasury;
    HookrRules internal r2;
    uint256 internal salt;

    function setUp() public {
        _setUpPeriphery();
        treasury = new HookrTreasury(address(this), TARGET, manager);
        r2 = new HookrRules(manager, registry, address(treasury), address(root), RELEASE_FLOOR);
        IHookrRegistry.Admission memory a = _rulesAdmission(address(r2), address(r2).codehash, r2.configSchemaHash());
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        treasury.admitSource(address(r2));
        vm.deal(trader, 1e30);
    }

    // ------------------------------------------------------------------ helpers

    function _setFloor(uint16 bps) internal {
        treasury.proposeRuleShareFloor(bps);
        vm.warp(vm.getBlockTimestamp() + treasury.TERMS_DELAY());
        treasury.acceptRuleShareFloor();
    }

    function _list(address account, uint16 bps) internal {
        treasury.proposeIntegrator(account, bps);
        vm.warp(vm.getBlockTimestamp() + treasury.TERMS_DELAY());
        treasury.acceptIntegrator(account);
    }

    function _members(uint16 share, address integrator, uint16 lp, uint16 burn)
        internal
        view
        returns (IHookrLauncher.Member[] memory members)
    {
        members = new IHookrLauncher.Member[](1);
        members[0] = _member(NATIVE);
        members[0].config.rules = address(r2);
        members[0].rules.lpBps = lp;
        members[0].rules.burnBps = burn;
        members[0].rules.protocolShareBps = share;
        members[0].rules.royaltyBps = 0;
        members[0].rules.royaltyTo = address(0);
        members[0].rules.integrator = integrator;
    }

    function _subject() internal returns (HookrToken s) {
        s = new HookrToken{salt: bytes32(++salt)}("S", "S", 1e30, address(this));
        s.approve(address(launcher), type(uint256).max);
    }

    function _launch(IHookrLauncher.Member[] memory members) internal returns (PoolKey memory key) {
        HookrToken s = _subject();
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function _launch(uint16 share, address integrator) internal returns (PoolKey memory) {
        return _launch(_members(share, integrator, 200, 100));
    }

    /// @dev The launch reverts with r2's bind refusal, carried in ModuleCallReverted: UnknownIntegrator for an
    ///      integrator the bind does not admit, InvalidConfig for a share below the floor without one.
    function _launchReverts(uint16 share, address integrator) internal {
        IHookrLauncher.Member[] memory members = _members(share, integrator, 200, 100);
        HookrToken s = _subject();
        bytes memory reason = integrator != address(0)
            ? abi.encodeWithSelector(IHookrRulesState.UnknownIntegrator.selector, integrator)
            : abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector, address(r2), IHookrRules.bind.selector, reason
            )
        );
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    /// @dev One exact-input buy of `amount` native; returns what the protocol recipient and the integrator were
    ///      credited, from the Rules' events of that swap.
    function _buy(PoolKey memory key, uint128 amount) internal returns (uint256 protocolPart, uint256 integratorPart) {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        IHookrRouter.Swap memory p = _swap(key, true, true, amount);
        vm.recordLogs();
        vm.prank(trader);
        router.swap{value: amount}(p, address(0), new uint256[](0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 allocations;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(r2)) continue;
            if (logs[i].topics[0] == IHookrRulesEvents.FeesAllocated.selector) {
                (protocolPart,,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, address, uint256));
                ++allocations;
            } else if (logs[i].topics[0] == IHookrRulesState.IntegratorPaid.selector) {
                integratorPart = abi.decode(logs[i].data, (uint256));
            }
        }
        assertEq(allocations, 1, "one settlement per swap");
    }

    function _backed() internal view {
        assertEq(manager.balanceOf(address(r2), NATIVE.toId()), r2.totalLiability(NATIVE), "backed to the wei");
    }

    // ------------------------------------------------------------------ treasury terms: bounds and timelock

    function test_terms_constantsAndStart() public view {
        assertEq(treasury.TERMS_DELAY(), 30 minutes);
        assertEq(treasury.TERMS_GRACE(), 14 days);
        assertEq(treasury.MAX_RULE_SHARE_FLOOR_BPS(), 5_000);
        assertEq(treasury.MAX_INTEGRATOR_BPS(), 5_000);
        assertEq(treasury.DEFAULT_INTEGRATOR_BPS(), 5_000);
        assertEq(treasury.ruleShareFloorBps(), 0);
        (uint16 floor, uint16 rate,) = treasury.feeTerms(INTEGRATOR, false, PoolId.wrap(0));
        assertEq(floor, 0);
        assertEq(rate, 0);
    }

    function test_floor_timelockBoundsAndOwner() public {
        vm.prank(OTHER);
        vm.expectRevert(IHookrTreasury.NotOwner.selector);
        treasury.proposeRuleShareFloor(3_000);
        vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
        treasury.proposeRuleShareFloor(5_001);
        vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
        treasury.proposeRuleShareFloor(0); // already the floor
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        treasury.acceptRuleShareFloor();

        treasury.proposeRuleShareFloor(3_000);
        (uint16 pending, uint256 readyAt) = treasury.pendingRuleShareFloor();
        assertEq(pending, 3_000);
        assertEq(readyAt, vm.getBlockTimestamp() + 30 minutes);
        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.TermsNotReady.selector, readyAt));
        treasury.acceptRuleShareFloor();
        vm.warp(readyAt);
        vm.prank(OTHER);
        vm.expectRevert(IHookrTreasury.NotOwner.selector);
        treasury.acceptRuleShareFloor();
        treasury.acceptRuleShareFloor();
        assertEq(treasury.ruleShareFloorBps(), 3_000);
        (pending, readyAt) = treasury.pendingRuleShareFloor();
        assertEq(readyAt, 0, "nothing pending");

        // Lowering back waits the same delay; the hard ceiling holds.
        treasury.proposeRuleShareFloor(0);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        treasury.acceptRuleShareFloor();
        assertEq(treasury.ruleShareFloorBps(), 0);
        _setFloor(5_000);
        assertEq(treasury.ruleShareFloorBps(), 5_000);

        // A proposal lapses TERMS_GRACE after it matures, and can be cancelled.
        treasury.proposeRuleShareFloor(2_500);
        (, readyAt) = treasury.pendingRuleShareFloor();
        vm.warp(readyAt + 14 days + 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.TermsExpired.selector, readyAt + 14 days));
        treasury.acceptRuleShareFloor();
        treasury.cancelRuleShareFloor();
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        treasury.cancelRuleShareFloor();
        assertEq(treasury.ruleShareFloorBps(), 5_000);
    }

    function test_terms_ownerChangeVoidsEveryPendingProposal() public {
        treasury.proposeRuleShareFloor(3_000);
        treasury.proposeIntegrator(INTEGRATOR, 5_000);
        treasury.proposeOwner(OTHER);
        vm.prank(OTHER);
        treasury.acceptOwnership();
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.startPrank(OTHER);
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        treasury.acceptRuleShareFloor();
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        treasury.acceptIntegrator(INTEGRATOR);
        (, uint16 pendingRate, uint256 readyAt) = treasury.integrator(INTEGRATOR);
        assertEq(pendingRate, 0);
        assertEq(readyAt, 0);
        vm.stopPrank();
        assertEq(treasury.ruleShareFloorBps(), 0);
    }

    function test_integrator_timelockBoundsAndOwner() public {
        vm.prank(OTHER);
        vm.expectRevert(IHookrTreasury.NotOwner.selector);
        treasury.proposeIntegrator(INTEGRATOR, 5_000);
        address[4] memory refused = [address(0), address(treasury), address(manager), address(r2)];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
            treasury.proposeIntegrator(refused[i], 5_000);
        }
        vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
        treasury.proposeIntegrator(INTEGRATOR, 0);
        vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
        treasury.proposeIntegrator(INTEGRATOR, 5_001);

        treasury.proposeIntegrator(INTEGRATOR, 5_000);
        (uint16 rate, uint16 pendingRate, uint256 readyAt) = treasury.integrator(INTEGRATOR);
        assertEq(rate, 0, "not listed while pending");
        assertEq(pendingRate, 5_000);
        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.TermsNotReady.selector, readyAt));
        treasury.acceptIntegrator(INTEGRATOR);
        vm.warp(readyAt);
        treasury.acceptIntegrator(INTEGRATOR);
        (, rate,) = treasury.feeTerms(INTEGRATOR, false, PoolId.wrap(0));
        assertEq(rate, 5_000);
        (, rate,) = treasury.feeTerms(address(0), false, PoolId.wrap(0));
        assertEq(rate, 0, "the zero address is never listed");

        // A re-rate waits the delay; the same rate is refused.
        vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
        treasury.proposeIntegrator(INTEGRATOR, 5_000);
        treasury.proposeIntegrator(INTEGRATOR, 3_000);
        (rate,,) = treasury.integrator(INTEGRATOR);
        assertEq(rate, 5_000, "the old rate holds while the re-rate waits");
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        treasury.acceptIntegrator(INTEGRATOR);
        (rate,,) = treasury.integrator(INTEGRATOR);
        assertEq(rate, 3_000);

        // Removal is immediate and voids a pending re-rate; removing what is not listed reverts.
        treasury.proposeIntegrator(INTEGRATOR, 4_000);
        vm.prank(OTHER);
        vm.expectRevert(IHookrTreasury.NotOwner.selector);
        treasury.removeIntegrator(INTEGRATOR);
        treasury.removeIntegrator(INTEGRATOR);
        (rate, pendingRate, readyAt) = treasury.integrator(INTEGRATOR);
        assertEq(rate, 0);
        assertEq(readyAt, 0);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        treasury.acceptIntegrator(INTEGRATOR);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.NotListed.selector, INTEGRATOR));
        treasury.removeIntegrator(INTEGRATOR);

        // A proposal lapses TERMS_GRACE after it matures, and can be cancelled.
        treasury.proposeIntegrator(OTHER, 5_000);
        (,, readyAt) = treasury.integrator(OTHER);
        vm.warp(readyAt + 14 days + 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.TermsExpired.selector, readyAt + 14 days));
        treasury.acceptIntegrator(OTHER);
        treasury.cancelIntegrator(OTHER);
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        treasury.cancelIntegrator(OTHER);
    }

    // ------------------------------------------------------------------ the floor at bind

    /// A raised floor refuses new pools below it and leaves bound pools at the share they froze; lowered back, the
    /// effective floor is the Rules' immutable one again, never below it.
    function test_floor_raiseReachesOnlyNewPools() public {
        PoolKey memory before = _launch(2_000, address(0));
        (uint256 paidBefore,) = _buy(before, 1 ether);

        _setFloor(3_000);
        _launchReverts(2_999, address(0));
        PoolKey memory after_ = _launch(3_000, address(0));
        assertEq(r2.config(after_.toId()).protocolShareBps, 3_000);

        assertEq(r2.config(before.toId()).protocolShareBps, 2_000, "the bound pool keeps its share");
        (uint256 paidAfter,) = _buy(before, 1 ether);
        assertEq(paidAfter, paidBefore, "and pays at it");

        _setFloor(1_000);
        _launchReverts(1_999, address(0));
        _launch(2_000, address(0));
        _setFloor(0);
        _launchReverts(1_999, address(0));
        _launch(2_000, address(0));
        _backed();
    }

    /// The floor is read once, at bind: a raise does not change what a bound pool's swaps pay.
    function testFuzz_floor_boundPoolsNeverReadIt(uint16 floor, uint16 share) public {
        share = uint16(bound(share, RELEASE_FLOOR, 5_000));
        floor = uint16(bound(floor, 1, 5_000));
        PoolKey memory key = _launch(share, address(0));
        (uint256 paid,) = _buy(key, 1 ether);
        if (floor != treasury.ruleShareFloorBps()) _setFloor(floor);
        (uint256 again,) = _buy(key, 1 ether);
        assertEq(again, paid);
        if (share < floor) _launchReverts(share, address(0));
        else _launch(share, address(0));
    }

    // ------------------------------------------------------------------ integrators at bind

    function test_integrator_unknownRefusedAtBind() public {
        _launchReverts(2_500, INTEGRATOR);
        // Pending is not listed.
        treasury.proposeIntegrator(INTEGRATOR, 5_000);
        _launchReverts(2_500, INTEGRATOR);
        // The reason, from the Rules' bind itself.
        PoolKey memory key =
            PoolKey(NATIVE, Currency.wrap(address(tokenA)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
        HookrTypes.PoolConfig memory pc;
        pc.subject = Currency.wrap(address(tokenA));
        pc.quote = NATIVE;
        pc.rules = address(r2);
        pc.liquidityOwner = address(this);
        pc.baseLpFeePips = 3000;
        pc.caps = HookrTypes.Caps(600_000, 200_000, 1000);
        HookrTypes.RulesConfig memory c = _members(2_500, INTEGRATOR, 200, 100)[0].rules;
        vm.mockCall(address(root), abi.encodeWithSignature("bindingPool()"), abi.encode(key.toId()));
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrRulesState.UnknownIntegrator.selector, INTEGRATOR));
        r2.bind(key, pc, abi.encode(c));
        // Listed, the same bind goes through.
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        treasury.acceptIntegrator(INTEGRATOR);
        vm.prank(address(root));
        r2.bind(key, pc, abi.encode(c));
        (address named, uint16 rate) = r2.integration(key.toId());
        assertEq(named, INTEGRATOR);
        assertEq(rate, 5_000);
    }

    /// A Rules whose protocol recipient has no code has no list: it admits no integrator, and no pool without one pays
    /// anyone but the protocol.
    function test_integrator_recipientWithoutCodeAdmitsNone() public {
        IHookrLauncher.Member[] memory members = _members(2_500, INTEGRATOR, 200, 100);
        members[0].config.rules = address(rules);
        HookrToken s = _subject();
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector,
                address(rules),
                IHookrRules.bind.selector,
                abi.encodeWithSelector(IHookrRulesState.UnknownIntegrator.selector, INTEGRATOR)
            )
        );
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        members[0].rules.integrator = address(0);
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    /// A protocol recipient with code must answer feeTerms: the Rules refuse one that cannot at deployment.
    function test_constructor_refusesARecipientWithoutFeeTerms() public {
        vm.expectRevert();
        new HookrRules(manager, registry, address(tokenA), address(root), RELEASE_FLOOR);
    }

    /// Removal stops new pools from naming the integrator; a pool bound with it keeps paying it.
    function test_integrator_removedStopsOnlyNewPools() public {
        _list(INTEGRATOR, 5_000);
        PoolKey memory key = _launch(2_500, INTEGRATOR);
        treasury.removeIntegrator(INTEGRATOR);
        _launchReverts(2_500, INTEGRATOR);
        uint256 before = r2.claimable(NATIVE, INTEGRATOR);
        (, uint256 cut) = _buy(key, 1 ether);
        assertGt(cut, 0);
        assertEq(r2.claimable(NATIVE, INTEGRATOR) - before, cut);
        _backed();
    }

    /// A re-rate reaches only pools bound after it: each pool keeps the rate it froze.
    function test_integrator_rateIsFrozenAtBind() public {
        _list(INTEGRATOR, 5_000);
        PoolKey memory half = _launch(2_500, INTEGRATOR);
        treasury.proposeIntegrator(INTEGRATOR, 3_000);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        treasury.acceptIntegrator(INTEGRATOR);
        PoolKey memory third = _launch(2_500, INTEGRATOR);
        (, uint16 rate) = r2.integration(half.toId());
        assertEq(rate, 5_000);
        (, rate) = r2.integration(third.toId());
        assertEq(rate, 3_000);
        (uint256 p1, uint256 c1) = _buy(half, 1 ether);
        (uint256 p2, uint256 c2) = _buy(third, 1 ether);
        assertEq(p1 + c1, p2 + c2, "the same Hookr share on both pools");
        assertEq(c1, (p1 + c1) * 5_000 / 10_000);
        assertEq(c2, (p2 + c2) * 3_000 / 10_000);
        (address named, uint16 none) = r2.integration(_launch(2_500, address(0)).toId());
        assertEq(named, address(0));
        assertEq(none, 0);
    }

    // ------------------------------------------------------------------ the split

    /// Every Hookr share of a buy's rule fees splits exactly: the integrator floor(share x rate / 10,000), the protocol
    /// recipient the rest (the odd unit included); together what a pool without an integrator pays the protocol; the
    /// buyer pays the same; claims and liabilities move together.
    function testFuzz_integrator_splitIsExact(uint16 rate, uint16 share, uint16 lp, uint16 burn, uint128 amount)
        public
    {
        rate = uint16(bound(rate, 1, 5_000));
        share = uint16(bound(share, RELEASE_FLOOR, 5_000));
        // At least one rule fee: a pool with neither LP Rewards nor Auto Burn (and no guard or dynamic fee) is fee-only
        // and never reaches the Rules on a swap.
        lp = uint16(bound(lp, 1, 1_000));
        burn = uint16(bound(burn, 0, 1_000 - lp));
        amount = uint128(bound(amount, 1e6, 1e21));
        _list(INTEGRATOR, rate);
        PoolKey memory plain = _launch(_members(share, address(0), lp, burn));
        PoolKey memory named = _launch(_members(share, INTEGRATOR, lp, burn));
        (uint256 whole,) = _buy(plain, amount);
        uint256 protocolBefore = r2.claimable(NATIVE, address(treasury));
        uint256 integratorBefore = r2.claimable(NATIVE, INTEGRATOR);
        uint256 liabilityBefore = r2.totalLiability(NATIVE);
        uint256 traderBefore = trader.balance;
        (uint256 kept, uint256 cut) = _buy(named, amount);
        assertEq(kept + cut, whole, "the same Hookr share as a pool without an integrator");
        assertEq(cut, whole * rate / 10_000, "the integrator's part, rounded down");
        assertEq(kept, whole - whole * rate / 10_000, "the protocol keeps the rest and the odd unit");
        assertEq(r2.claimable(NATIVE, address(treasury)) - protocolBefore, kept);
        assertEq(r2.claimable(NATIVE, INTEGRATOR) - integratorBefore, cut);
        assertEq(r2.totalLiability(NATIVE) - liabilityBefore, whole, "liabilities grow by the whole share");
        assertEq(traderBefore - trader.balance, amount, "the buyer pays the same");
        _backed();
    }

    /// Rounding at the smallest shares, from one unit (a 134 wei buy at 75 bps of Hookr share): the odd unit stays
    /// with the protocol, so a share of one unit pays the integrator nothing.
    function testFuzz_integrator_oddUnitToTheProtocol(uint128 amount) public {
        amount = uint128(bound(amount, 134, 1e9));
        _list(INTEGRATOR, 5_000);
        PoolKey memory key = _launch(2_500, INTEGRATOR);
        (uint256 kept, uint256 cut) = _buy(key, amount);
        uint256 whole = kept + cut;
        assertGt(whole, 0);
        assertEq(cut, whole / 2);
        assertEq(kept - cut, whole % 2, "the odd unit to the protocol");
        _backed();
    }

    /// The paymaster's transient ledger counts what the protocol recipient kept, not the integrator's part.
    function test_integrator_paymasterLedgerIsTheProtocolsPart() public {
        _list(INTEGRATOR, 5_000);
        PoolKey memory key = _launch(2_500, INTEGRATOR);
        (uint256 kept, uint256 cut) = _buy(key, 1 ether);
        assertGt(cut, 0);
        assertEq(r2.protocolFeePaid(trader, NATIVE), kept);
    }

    /// Integrators claim through the Rules' existing claim path; with the protocol collected through the treasury and
    /// the integrator's claim paid, the Rules hold exactly what they still owe.
    function test_integrator_claimsFollowTheClaimPatternAndStayBacked() public {
        _list(INTEGRATOR, 5_000);
        _list(OTHER, 1_234);
        PoolKey memory a = _launch(2_500, INTEGRATOR);
        PoolKey memory b = _launch(4_000, OTHER);
        PoolKey memory c = _launch(3_000, address(0));
        uint256 cutA;
        uint256 cutB;
        for (uint256 i; i < 5; ++i) {
            (, uint256 x) = _buy(a, uint128(1 ether + i));
            (, uint256 y) = _buy(b, uint128(3 ether + 7 * i));
            _buy(c, uint128(2 ether + i));
            (cutA, cutB) = (cutA + x, cutB + y);
            _backed();
        }
        assertEq(r2.claimable(NATIVE, INTEGRATOR), cutA);
        assertEq(r2.claimable(NATIVE, OTHER), cutB);
        uint256 balance = INTEGRATOR.balance;
        vm.prank(INTEGRATOR);
        assertEq(r2.claim(NATIVE), cutA);
        assertEq(INTEGRATOR.balance - balance, cutA);
        vm.prank(OTHER);
        r2.claimTo(NATIVE, address(0xBEEF));
        assertEq(address(0xBEEF).balance, cutB);
        treasury.collectTo(address(r2), NATIVE);
        assertEq(r2.claimable(NATIVE, INTEGRATOR), 0);
        assertEq(r2.claimable(NATIVE, address(treasury)), 0);
        _backed();
        assertEq(r2.totalLiability(NATIVE), 0, "nothing else is owed on these pools");
    }

    // ------------------------------------------------------------------ accounts that can never claim

    /// An admitted source can never be listed: admitSource refuses an account on the list or with a pending listing,
    /// in either order, so a Rules or vault cannot become an integrator whose credit no code ever claims. Off the
    /// list, or with only a lapsed proposal, it can be admitted.
    function test_integrator_admitSourceRefusesAListedOrProposedIntegrator() public {
        HookrRules r3 = new HookrRules(manager, registry, address(treasury), address(root), RELEASE_FLOOR);
        treasury.proposeIntegrator(address(r3), 5_000);
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        treasury.admitSource(address(r3));
        vm.warp(vm.getBlockTimestamp() + treasury.TERMS_DELAY());
        treasury.acceptIntegrator(address(r3));
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        treasury.admitSource(address(r3));
        treasury.removeIntegrator(address(r3));
        treasury.admitSource(address(r3));
        assertEq(treasury.sourceCodeHash(address(r3)), address(r3).codehash);

        HookrRules r4 = new HookrRules(manager, registry, address(treasury), address(root), RELEASE_FLOOR);
        treasury.proposeIntegrator(address(r4), 5_000);
        vm.warp(vm.getBlockTimestamp() + treasury.TERMS_DELAY() + treasury.TERMS_GRACE() + 1);
        treasury.admitSource(address(r4));
    }

    /// acceptIntegrator re-runs the checks proposeIntegrator made: an account that became an admitted source while
    /// its proposal waited is refused. admitSource refuses that order, so the source is written directly here.
    function test_integrator_acceptRechecksTheProposeTimeRules() public {
        HookrRules r3 = new HookrRules(manager, registry, address(treasury), address(root), RELEASE_FLOOR);
        treasury.proposeIntegrator(address(r3), 5_000);
        // sourceCodeHash is the sixth word of the treasury's ERC-7201 struct.
        bytes32 base = 0xfbe7548a70873d48ea7fddfba1199106377ceedcd42dbef7dc33de62b5287a00;
        vm.store(address(treasury), keccak256(abi.encode(address(r3), uint256(base) + 5)), address(r3).codehash);
        assertEq(treasury.sourceCodeHash(address(r3)), address(r3).codehash, "the slot is sourceCodeHash");
        vm.warp(vm.getBlockTimestamp() + treasury.TERMS_DELAY());
        vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
        treasury.acceptIntegrator(address(r3));
        (uint16 rate,,) = treasury.integrator(address(r3));
        assertEq(rate, 0);
    }

    /// The Rules never bind an integrator that cannot claim what they would credit it: themselves, their trusted
    /// root, their protocol recipient, the PoolManager and their recapture module, whatever the treasury answers.
    function test_integrator_bindRefusesAccountsThatNeverClaim() public {
        // Listed for real: the root is not an admitted source, so the treasury lists it.
        _list(address(root), 5_000);
        _launchReverts(2_500, address(root));

        PoolKey memory key =
            PoolKey(NATIVE, Currency.wrap(address(tokenA)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
        HookrTypes.PoolConfig memory pc;
        pc.subject = Currency.wrap(address(tokenA));
        pc.quote = NATIVE;
        pc.rules = address(r2);
        pc.liquidityOwner = address(this);
        pc.baseLpFeePips = 3000;
        pc.caps = HookrTypes.Caps(600_000, 200_000, 1000);
        vm.mockCall(address(root), abi.encodeWithSignature("bindingPool()"), abi.encode(key.toId()));
        (address module,) = IHookrRecaptureRules(address(r2)).recaptureModule();
        address[5] memory never = [address(r2), address(root), address(treasury), address(manager), module];
        for (uint256 i; i < never.length; ++i) {
            // Whatever the treasury answers for it.
            vm.mockCall(
                address(treasury),
                abi.encodeWithSelector(HookrTreasury.feeTerms.selector, never[i]),
                abi.encode(uint16(0), uint16(5_000), uint16(1_000))
            );
            HookrTypes.RulesConfig memory c = _members(2_500, never[i], 200, 100)[0].rules;
            vm.prank(address(root));
            vm.expectRevert(abi.encodeWithSelector(IHookrRulesState.UnknownIntegrator.selector, never[i]));
            r2.bind(key, pc, abi.encode(c));
        }
        // A listed account that can claim still binds.
        _list(INTEGRATOR, 5_000);
        HookrTypes.RulesConfig memory ok = _members(2_500, INTEGRATOR, 200, 100)[0].rules;
        vm.prank(address(root));
        r2.bind(key, pc, abi.encode(ok));
        (address named,) = r2.integration(key.toId());
        assertEq(named, INTEGRATOR);
    }

    // ------------------------------------------------------------------ lapsed and voided proposals

    /// A proposal past its grace is not pending: every pending view reports none from the second after
    /// readyAt + TERMS_GRACE (and still reports it at that second), and removeIntegrator refuses an account whose only
    /// entry is a lapsed proposal, as it refuses one with none.
    function test_terms_lapsedProposalIsNotPending() public {
        treasury.proposeRuleShareFloor(4_000);
        treasury.proposeIntegrator(INTEGRATOR, 5_000);
        treasury.proposeMinFee(false, 500);
        treasury.proposeMinFee(true, 700);
        treasury.proposeIntegratorMinFee(OTHER, 0);
        uint256 readyAt = vm.getBlockTimestamp() + treasury.TERMS_DELAY();
        vm.warp(readyAt + treasury.TERMS_GRACE());
        (uint16 floorBps, uint256 pendingReadyAt) = treasury.pendingRuleShareFloor();
        assertEq(floorBps, 4_000, "pending through the last second of its grace");
        assertEq(pendingReadyAt, readyAt);

        vm.warp(readyAt + treasury.TERMS_GRACE() + 1);
        (floorBps, pendingReadyAt) = treasury.pendingRuleShareFloor();
        assertEq(floorBps, 0);
        assertEq(pendingReadyAt, 0);
        (uint16 rate, uint16 pendingRate, uint256 rateAt) = treasury.integrator(INTEGRATOR);
        assertEq(rate, 0);
        assertEq(pendingRate, 0);
        assertEq(rateAt, 0);
        (uint16 pips, uint256 pipsAt) = treasury.pendingMinFee(false);
        assertEq(pips, 0);
        assertEq(pipsAt, 0);
        (pips, pipsAt) = treasury.pendingMinFee(true);
        assertEq(pips, 0);
        assertEq(pipsAt, 0);
        (, uint16 pendingPips, uint256 overrideAt) = treasury.integratorMinFee(OTHER);
        assertEq(pendingPips, treasury.NO_MIN_FEE_OVERRIDE());
        assertEq(overrideAt, 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.NotListed.selector, INTEGRATOR));
        treasury.removeIntegrator(INTEGRATOR);
        // The accept paths still name the lapse.
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.TermsExpired.selector, readyAt + 14 days));
        treasury.acceptIntegrator(INTEGRATOR);
    }

    /// Every path that voids a pending fee-terms proposal says so: a change of owner emits the cancellation of the
    /// floor and of both minimum proposals, and FeeTermsProposalsVoided for the per-account ones it cannot list;
    /// removeIntegrator emits the cancellation of the account's pending re-rate and of its pending override.
    function test_terms_voidingEmitsTheCancellations() public {
        treasury.proposeRuleShareFloor(3_000);
        treasury.proposeMinFee(false, 400);
        treasury.proposeMinFee(true, 600);
        treasury.proposeIntegrator(INTEGRATOR, 5_000);
        treasury.proposeOwner(OTHER);
        vm.expectEmit(address(treasury));
        emit IHookrTreasury.RuleShareFloorProposalCancelled(3_000);
        vm.expectEmit(address(treasury));
        emit IHookrTreasury.MinFeeProposalCancelled(false, 400);
        vm.expectEmit(address(treasury));
        emit IHookrTreasury.MinFeeProposalCancelled(true, 600);
        vm.expectEmit(address(treasury));
        emit IHookrTreasury.FeeTermsProposalsVoided(1);
        vm.expectEmit(address(treasury));
        emit IHookrTreasury.OwnershipTransferred(address(this), OTHER);
        vm.prank(OTHER);
        treasury.acceptOwnership();

        vm.startPrank(OTHER);
        treasury.proposeIntegrator(INTEGRATOR, 5_000);
        vm.warp(vm.getBlockTimestamp() + treasury.TERMS_DELAY());
        treasury.acceptIntegrator(INTEGRATOR);
        treasury.proposeIntegratorMinFee(INTEGRATOR, 0);
        vm.warp(vm.getBlockTimestamp() + treasury.TERMS_DELAY());
        treasury.acceptIntegratorMinFee(INTEGRATOR);
        treasury.proposeIntegrator(INTEGRATOR, 4_000);
        treasury.proposeIntegratorMinFee(INTEGRATOR, 250);
        vm.expectEmit(address(treasury));
        emit IHookrTreasury.IntegratorProposalCancelled(INTEGRATOR, 4_000);
        vm.expectEmit(address(treasury));
        emit IHookrTreasury.IntegratorRemoved(INTEGRATOR, 5_000);
        vm.expectEmit(address(treasury));
        emit IHookrTreasury.IntegratorMinFeeProposalCancelled(INTEGRATOR, 250);
        vm.expectEmit(address(treasury));
        emit IHookrTreasury.IntegratorMinFeeSet(INTEGRATOR, 0, treasury.NO_MIN_FEE_OVERRIDE());
        treasury.removeIntegrator(INTEGRATOR);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ the effective floor

    /// protocolShareFloor() is the floor a bind checks: the larger of the Rules' immutable floor and the treasury's
    /// governed one. A share one below it does not bind and a share at it does.
    function test_floor_effectiveFloorView() public {
        IHookrRecaptureRules view_ = IHookrRecaptureRules(address(r2));
        assertEq(view_.protocolShareFloor(), RELEASE_FLOOR, "the immutable floor while the governed one is below it");
        _setFloor(3_500);
        assertEq(view_.protocolShareFloor(), 3_500);
        _launchReverts(3_499, address(0));
        _launch(3_500, address(0));
        _setFloor(1_000);
        assertEq(view_.protocolShareFloor(), RELEASE_FLOOR);
        _launchReverts(RELEASE_FLOOR - 1, address(0));
        // A Rules paying an address without code has only its immutable floor.
        assertEq(IHookrRecaptureRules(address(rules)).protocolShareFloor(), rules.minProtocolShareBps());
    }

    /// A proposal can still be accepted at the last second of its grace, and is expired the second after. Mutation gate
    /// TR-4 (a proposal expired in its last second).
    function test_floor_acceptsAtTheLastSecondOfItsGrace() public {
        treasury.proposeRuleShareFloor(3_000);
        (, uint256 readyAt) = treasury.pendingRuleShareFloor();
        vm.warp(readyAt + treasury.TERMS_GRACE());
        treasury.acceptRuleShareFloor();
        assertEq(treasury.ruleShareFloorBps(), 3_000);
        treasury.proposeRuleShareFloor(0);
        (, readyAt) = treasury.pendingRuleShareFloor();
        vm.warp(readyAt + treasury.TERMS_GRACE() + 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.TermsExpired.selector, readyAt + treasury.TERMS_GRACE()));
        treasury.acceptRuleShareFloor();
    }
}
