// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";

/// @notice The recapture split (HookrRecapture through HookrRules): split order and rounding at the knob bounds and at
///         several rule-fee protocol shares, claims backing to the wei, a full exit to zero, and the protocol's cut of
///         every arb recapture: 25% of the profit the push stands for at the pool's frozen partner share
///         (RECAPTURE_PROTOCOL_BPS) on every pool, whatever its protocolShareBps, even on Rules deployed with a zero
///         floor.
contract MoneySplitAttackTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ScriptedExecutor internal exec;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e30);
        tokenB.transfer(address(exec), 1e27);
        exec.setRoot(address(root));
        _openLane(address(exec));
    }

    function _knobs(uint256 i) internal pure returns (uint16 trader, uint16 pot) {
        if (i == 0) return (5000, 0);
        if (i == 1) return (0, 0);
        if (i == 2) return (5000, 5000);
        if (i == 3) return (0, 5000);
        if (i == 4) return (2500, 0);
        return (2500, 2500);
    }

    function _share(uint256 i) internal pure returns (uint16) {
        if (i == 0) return 2000;
        if (i == 1) return 2500;
        return 5000;
    }

    function _pool(uint16 trader, uint16 pot, uint16 share) internal returns (PoolKey memory key) {
        HookrTypes.RulesConfig memory r;
        r.maxFeePips = BASE_FEE;
        r.protocolShareBps = share;
        HookrTypes.RecaptureConfig memory rc;
        rc.on = true;
        rc.traderBps = trader;
        rc.lpBps = 10_000 - trader - pot;
        rc.releaseBlocks = RELEASE;
        if (pot != 0) {
            r.lpBps = 400;
            r.potBps = pot;
            rc.period = 1 days;
            rc.maxPrizeBps = uint16(uint256(400) * share / 10_000 / 2);
            rc.potReleaseBps = 5000;
            rc.minBuyQuote = 1e18;
        }
        key = _openPool(ETH, r, rc);
    }

    /// Every push splits protocol-first to the wei at every knob bound and at rule shares 2,000 / 2,500 / 5,000, the
    /// protocol always taking 25% of the profit the push stands for at the pinned 25% partner share; the parts
    /// sum to the push, the before-phase names no trader, the after-phase names the payer but credits it nothing for
    /// a push that undid nothing of its move (this executor legs nowhere), and the Rules' ERC-6909 balance moves by
    /// exactly what its liabilities move by.
    function testFuzz_money_splitIsExactAndBacked(uint256 amount, uint8 knobI, uint8 shareI) public {
        amount = bound(amount, 1, 1e24);
        (uint16 t, uint16 p) = _knobs(knobI % 6);
        uint16 share = _share(shareI % 3);
        PoolKey memory key = _pool(t, p, share);
        exec.set(ScriptedExecutor.Mode.PUSH, amount);
        uint256 bal0 = manager.balanceOf(address(rules), ETH.toId());
        uint256 liab0 = rules.totalLiability(ETH);
        assertEq(bal0, liab0, "backed to the wei before");
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IHookrRecaptureEvents.RecaptureSplit.selector;
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rules) || logs[i].topics[0] != topic) continue;
            (uint256 tr, uint256 lp, uint256 pot, uint256 pro,, uint256 reported) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, Currency, uint256));
            address named = address(uint160(uint256(logs[i].topics[2])));
            assertEq(reported, _profitOf(amount), "the profit the push stands for");
            uint256 expPro = _cut(_profitOf(amount), amount);
            uint256 rest = amount - expPro;
            uint256 expTr = 0;
            uint256 expPot = rest * p / 10_000;
            assertEq(pro, expPro, "protocol first");
            assertEq(tr, expTr, "trader");
            assertEq(pot, expPot, "pot");
            assertEq(lp, rest - expTr - expPot, "lp takes the dust");
            assertEq(tr + lp + pot + pro, amount, "sums to the push");
            if (n == 0) assertEq(named, address(0), "before-phase names no trader");
            else assertEq(named, whale, "after-phase names the payer");
            ++n;
        }
        assertEq(n, 2, "a split per phase");
        assertEq(manager.balanceOf(address(rules), ETH.toId()), rules.totalLiability(ETH), "backed to the wei after");
        assertEq(rules.totalLiability(ETH) - liab0 >= 2 * amount, true, "both pushes are liabilities");
    }

    /// Several arb recaptures, crowns and releases, the LP share donated, then every party claims: the Rules end with
    ///      exactly zero ERC-6909 balance and zero liabilities in the quote (no stuck residue, no shortfall).
    function test_money_fullExitEndsAtExactlyZero_owner() public {
        (PoolKey memory key, bytes32 family) = _openPoolWithFamily(ETH, _laneRules(true), _kothRc());
        PoolId id = key.toId();
        exec.set(ScriptedExecutor.Mode.PUSH, 3e17 + 7);
        _buy(key, ETH, whale, 5e18);
        _buy(key, ETH, minnow, 2e18 + 3);
        _sell(key, ETH, attacker, 1e18);
        vm.warp(vm.getBlockTimestamp() + PERIOD + 1);
        exec.set(ScriptedExecutor.Mode.PUSH, 1e18 + 13);
        _buy(key, ETH, minnow, 7e18 + 1);
        vm.warp(vm.getBlockTimestamp() + 300 * uint256(PERIOD));
        _recap().settleEpoch(id);
        (,,, uint128 pot) = _hill(key);
        assertEq(pot, 0, "every epoch released the pot");
        // The next block's first add donates the pending LP share to the in-range liquidity, burning its backing.
        _nextBlock();
        _newActor(key).modify(key, 60_000, 60_060, 1e18);
        _flushAll(key);
        vm.prank(creator);
        launcher.claimRecapture(family, 0, creator);
        address[6] memory parties = [protocol, royalty, whale, minnow, attacker, creator];
        for (uint256 i; i < parties.length; ++i) {
            if (rules.claimable(ETH, parties[i]) == 0) continue;
            vm.prank(parties[i]);
            rules.claim(ETH);
        }
        assertEq(rules.totalLiability(ETH), 0, "no liabilities left");
        assertEq(manager.balanceOf(address(rules), ETH.toId()), 0, "no residue left");
    }

    /// The recapture suites run at the release floor: a recapture pool below 2,000 does not bind.
    function test_regression_theSuitesRunAtTheReleaseFloor() public {
        assertEq(rules.minProtocolShareBps(), 2_000, "the release floor");
        HookrTypes.RulesConfig memory r;
        r.maxFeePips = BASE_FEE;
        r.protocolShareBps = 1_999;
        _bindReverts(rules, r, _rcOn());
        r.protocolShareBps = 2_000;
        _openPool(ETH, r, _rcOn());
    }

    /// Rules deployed with a zero floor: the arb recapture cut does not follow the pool's rule share, so a recapture
    /// pool at a zero protocolShareBps binds and still pays the protocol 25% of every arb recapture's profit.
    function test_regression_aZeroFloorRulesStillTakesTwentyFivePercentOfEveryRecapture() public {
        HookrRules zero = _admitRules(0);
        assertEq(zero.minProtocolShareBps(), 0, "floor zero");
        assertEq(IHookrRecaptureRules(address(zero)).RECAPTURE_PROTOCOL_BPS(), 2_500);
        HookrTypes.RulesConfig memory r;
        r.maxFeePips = BASE_FEE;
        r.protocolShareBps = 0;
        PoolKey memory key = _launchWith(zero, r, _rcOn());
        exec.set(ScriptedExecutor.Mode.PUSH, 1e20);
        uint256 before = zero.claimable(ETH, protocol);
        _buy(key, ETH, whale, 1e18);
        assertEq(zero.claimable(ETH, protocol) - before, 2 * _cut(_profitOf(1e20), 1e20), "25% of each push's profit");
    }

    function _rcOn() internal pure returns (HookrTypes.RecaptureConfig memory rc) {
        rc.on = true;
        rc.traderBps = 2500;
        rc.lpBps = 7500;
        rc.releaseBlocks = RELEASE;
    }

    /// @dev A second HookrRules on the fixture root with global floor `floor`, admitted through the timelock.
    function _admitRules(uint16 floor) internal returns (HookrRules r) {
        r = new HookrRules(manager, registry, protocol, address(root), floor);
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: address(r),
            codeHash: address(r).codehash,
            schemaHash: r.configSchemaHash(),
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    function _member(HookrRules r, HookrTypes.RulesConfig memory c, HookrTypes.RecaptureConfig memory rc)
        internal
        view
        returns (IHookrLauncher.Member[] memory members)
    {
        members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(ETH, c, rc);
        members[0].config.rules = address(r);
    }

    function _launchWith(HookrRules r, HookrTypes.RulesConfig memory c, HookrTypes.RecaptureConfig memory rc)
        internal
        returns (PoolKey memory key)
    {
        (, PoolKey[] memory keys) = _launchAs(creator, _newSubject(), _member(r, c, rc));
        key = keys[0];
    }

    function _bindReverts(HookrRules r, HookrTypes.RulesConfig memory c, HookrTypes.RecaptureConfig memory rc)
        internal
    {
        IHookrLauncher.Member[] memory members = _member(r, c, rc);
        HookrToken s = _newSubject();
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector,
                address(r),
                IHookrRules.bind.selector,
                abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector)
            )
        );
        vm.prank(creator);
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }
}
