// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {LegTaxFixture} from "./utils/LegTaxFixture.sol";
import {LegTaxAdvisory, LegExecutor} from "./mocks/LegTaxMocks.sol";
import {HooklessVenue} from "../fixtures/CyclingExecutor.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";

/// @notice The Hookr minimum on arb recapture pools: none binds (HookrRules.bind), whatever the treasury's arb
///         recapture rate, so neither an executor leg nor a trader's swap on such a pool pays one; Hookr earns its cut
///         of the arb recaptures there. A leg outside the launch guard, and every sell leg, never reaches the Rules; a
///         buy leg during the guard takes the Rules path and pays what a trader pays, and the lane asks the Rules for
///         nothing else: it marks no leg.
contract MinimumFeeLegsTest is LegTaxFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    HookrTreasury internal treasury;

    struct Charge {
        address sender;
        uint256 protocol;
        uint256 advisory;
    }

    function setUp() public {
        _setUpLane();
        // The release pays a HookrTreasury, which holds the minimum: these suites' Rules pay one.
        treasury = new HookrTreasury(address(this), address(0x7A7), manager);
        HookrRules r2 = new HookrRules(manager, registry, address(treasury), address(root), 2_000);
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: address(r2),
            codeHash: address(r2).codehash,
            schemaHash: r2.configSchemaHash(),
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        treasury.admitSource(address(r2));
        rules = r2;
        protocol = address(treasury);
        legEx = new LegExecutor(manager);
        legEx.setUp(address(root), address(rules));
        _openLane(address(legEx), 3_000_000);
        vm.deal(address(legEx), 1e28);
        tax = new LegTaxAdvisory();
        _admit(address(tax), 50_000, 100_000, BOTH, false);
        outsider = new HooklessVenue(manager);
    }

    function _setRecaptureMin(uint16 pips) internal {
        treasury.proposeMinFee(true, pips);
        vm.warp(vm.getBlockTimestamp() + treasury.TERMS_DELAY());
        treasury.acceptMinFee(true);
    }

    /// @dev A lane pool without rules; guarded (no Snipe, no cap) for the whole test when `guarded`.
    function _pool(bool guarded) internal returns (PoolKey memory) {
        HookrTypes.RulesConfig memory r = _laneRules(false);
        if (guarded) r.guardEndBlock = uint40(vm.getBlockNumber() + 100_000);
        return _launchPool(address(0), 0, false, r, _recaptureOnlyRc());
    }

    /// @dev Each settled swap's sender and what the Rules credited on it, in order.
    function _charges(Vm.Log[] memory logs) internal view returns (Charge[] memory c, uint256 n) {
        c = new Charge[](8);
        address sender;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                sender = address(uint160(uint256(logs[i].topics[2])));
            } else if (
                logs[i].emitter == address(rules) && logs[i].topics[0] == IHookrRulesEvents.FeesAllocated.selector
            ) {
                (uint256 pro,,,, uint256 adv) = abi.decode(logs[i].data, (uint256, uint256, uint256, address, uint256));
                c[n++] = Charge(sender, pro, adv);
            }
        }
    }

    /// A guarded lane pool of a Hookr token without rules binds no minimum at the recapture rate's default 1,000. A
    /// buy leg during the launch guard still takes the Rules path, in both phases, and pays Hookr nothing, and so does
    /// the trader's swap between them; the lane never asks the Rules to mark a leg (markLeg(bytes32), 0xa2697f38).
    function test_minFee_guardBuyLegsAndTheTraderPayNone() public {
        PoolKey memory key = _pool(true);
        assertEq(treasury.minFeePips(true), 1_000);
        assertEq(IHookrRecaptureRules(address(rules)).minimumFee(key.toId()), 0);
        _nextBlock();
        legEx.clear();
        legEx.add(false, key, true, -1e18, LO + 1, 0);
        legEx.add(true, key, true, -1e18, LO + 1, 0);
        vm.expectCall(address(rules), abi.encodeWithSelector(bytes4(0xa2697f38)), 0);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        (Charge[] memory c, uint256 n) = _charges(vm.getRecordedLogs());
        assertEq(legEx.legs(), 2, "both legs ran");
        assertEq(n, 3, "the two legs and the trader settle through the Rules");
        assertEq(c[0].sender, address(legEx));
        assertEq(c[0].protocol, 0, "the before-phase leg pays Hookr nothing");
        assertEq(c[1].protocol, 0, "the trader pays no minimum");
        assertEq(c[2].sender, address(legEx));
        assertEq(c[2].protocol, 0, "the after-phase leg pays Hookr nothing");
        assertEq(manager.balanceOf(address(rules), ETH.toId()) >= rules.totalLiability(ETH), true, "backed");
    }

    /// The first guarded buy leg receives the same to the wei on twin lane pools bound at the recapture rate's default
    /// 1,000 and at its 10,000 ceiling: neither binds a minimum.
    function test_minFee_guardBuyLegIsTheSameAtAnyRecaptureRate() public {
        PoolKey memory key = _pool(true);
        _setRecaptureMin(10_000);
        PoolKey memory twin = _pool(true);
        assertEq(IHookrRecaptureRules(address(rules)).minimumFee(key.toId()), 0);
        assertEq(IHookrRecaptureRules(address(rules)).minimumFee(twin.toId()), 0);
        _nextBlock();
        legEx.clear();
        legEx.add(false, key, true, -1e18, LO + 1, 0);
        _buy(key, ETH, whale, 1e18);
        int256 a = legEx.last1();
        legEx.clear();
        legEx.add(false, twin, true, -1e18, LO + 1, 0);
        _buy(twin, ETH, whale, 1e18);
        int256 b = legEx.last1();
        assertGt(a, 0);
        assertEq(a, b, "the leg pays the same");
    }

    /// Outside the guard no leg reaches the Rules: only the trader's swap settles there, and it pays Hookr nothing.
    function test_minFee_unguardedLegsNeverReachTheRules() public {
        PoolKey memory key = _pool(false);
        _nextBlock();
        legEx.clear();
        legEx.add(false, key, false, -1e18, HI - 1, 0);
        legEx.add(true, key, true, -1e18, LO + 1, 0);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        (Charge[] memory c, uint256 n) = _charges(vm.getRecordedLogs());
        assertEq(legEx.legs(), 2);
        assertEq(n, 1, "the trader's swap alone");
        assertEq(c[0].sender != address(legEx), true);
        assertEq(c[0].protocol, 0, "no minimum");
    }

    /// No recapture rate reaches a lane pool: at 0 and at the 10,000 ceiling, new lane pools bind none, and so did
    /// the one bound at the default 1,000; a lane pool is never fee-only, so each trader swap still settles through the
    /// Rules, paying Hookr nothing on a pool without rules.
    function test_minFee_noRecaptureRateReachesALanePool() public {
        PoolKey memory before = _pool(false);
        _setRecaptureMin(0);
        PoolKey memory zero = _pool(false);
        _setRecaptureMin(10_000);
        PoolKey memory ceiling = _pool(false);
        assertEq(IHookrRecaptureRules(address(rules)).minimumFee(before.toId()), 0);
        assertEq(IHookrRecaptureRules(address(rules)).minimumFee(zero.toId()), 0);
        assertEq(IHookrRecaptureRules(address(rules)).minimumFee(ceiling.toId()), 0);
        PoolKey[3] memory keys = [before, zero, ceiling];
        for (uint256 i; i < keys.length; ++i) {
            _nextBlock();
            legEx.clear();
            vm.recordLogs();
            _buy(keys[i], ETH, whale, 1e18);
            (Charge[] memory c, uint256 n) = _charges(vm.getRecordedLogs());
            assertEq(n, 1, "a lane pool is never fee-only");
            assertEq(c[0].protocol, 0, "no minimum at any rate");
        }
    }
}
