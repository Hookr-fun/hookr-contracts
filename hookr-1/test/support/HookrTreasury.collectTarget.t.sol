// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

/// @notice F-051: a matured Treasury target proposal never expired, and a new owner could accept a stale proposal
///         made by the previous one (PoC T1: accepted 3,650 days after proposal).
///         ATT-01: `collectTo` emitted `ProtocolCollected` and `ProtocolForwarded` for funds the treasury never held,
///         while the source's `Claimed` named the target, so the commission service could not reconcile it. Every
///         collection now emits exactly one `ProtocolCollected(source, currency, to, amount)` matching `Claimed`.
contract HookrTreasuryCollectTargetTest is GovernanceSecurityBase {
    event ProtocolCollected(address indexed source, Currency indexed currency, address indexed to, uint256 amount);

    HookrTreasury internal treasury;
    HookrRules internal r2;
    address internal constant TARGET = address(0x7A7);
    bytes32 internal constant CLAIMED = keccak256("Claimed(address,address,address,uint256)");
    bytes32 internal constant COLLECTED = keccak256("ProtocolCollected(address,address,address,uint256)");
    bytes32 internal constant FORWARDED = keccak256("ProtocolForwarded(address,address,uint256)");

    function setUp() public {
        _setUpPeriphery();
        treasury = new HookrTreasury(address(this), TARGET, manager);
    }

    // ------------------------------------------------------------ F-051

    function test_maturedTargetExpires() public {
        treasury.proposeTarget(address(0xBAD));
        uint256 ready = treasury.targetReadyAt();
        vm.warp(ready + treasury.TARGET_GRACE() + 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.TargetExpired.selector, address(0xBAD), ready + 14 days));
        treasury.acceptTarget();
        assertEq(treasury.target(), TARGET);
        // A fresh proposal works within its window.
        treasury.proposeTarget(address(0xBAD));
        vm.warp(treasury.targetReadyAt() + treasury.TARGET_GRACE());
        treasury.acceptTarget();
        assertEq(treasury.target(), address(0xBAD));
    }

    function test_ownershipChangeClearsPendingTarget() public {
        treasury.proposeTarget(address(0xBAD));
        treasury.proposeOwner(address(0xB0B));
        // Two steps: nothing moves until the nominee accepts.
        assertEq(treasury.owner(), address(this));
        vm.warp(treasury.targetReadyAt());
        vm.prank(address(0xB0B));
        treasury.acceptOwnership();
        assertEq(treasury.owner(), address(0xB0B));
        assertEq(treasury.pendingTarget(), address(0));
        assertEq(treasury.targetReadyAt(), 0);
        vm.prank(address(0xB0B));
        vm.expectRevert(IHookrTreasury.NoPendingTarget.selector);
        treasury.acceptTarget();
        assertEq(treasury.target(), TARGET);
    }

    // ------------------------------------------------------------ ATT-01

    function _earn() internal returns (Currency q) {
        r2 = new HookrRules(manager, registry, address(treasury), address(root), 0);
        IHookrRegistry.Admission memory a = _rulesAdmission(address(r2), address(r2).codehash, r2.configSchemaHash());
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        treasury.admitSource(address(r2));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[0].config.rules = address(r2);
        (bytes32 fam,) = launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        PoolKey memory key = launcher.position(fam, 0).key;
        IHookrRouter.Swap memory buy = _swap(key, true, true, 1e22);
        vm.prank(trader);
        router.swap(buy, address(0), new uint256[](0));
        q = Currency.wrap(address(tokenB));
        assertGt(r2.claimable(q, address(treasury)), 0);
    }

    /// Returns the single ProtocolCollected and the single Claimed of the call, and the number of ProtocolForwarded.
    function _shape(Vm.Log[] memory logs)
        internal
        view
        returns (address collectedTo, uint256 collected, address claimedTo, uint256 claimed, uint256 forwards)
    {
        uint256 collections;
        uint256 claims;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            bytes32 t0 = logs[i].topics[0];
            if (t0 == COLLECTED && logs[i].emitter == address(treasury)) {
                ++collections;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(r2));
                collectedTo = address(uint160(uint256(logs[i].topics[3])));
                collected = abi.decode(logs[i].data, (uint256));
            } else if (t0 == CLAIMED && logs[i].emitter == address(r2)) {
                ++claims;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(treasury), "beneficiary");
                claimedTo = address(uint160(uint256(logs[i].topics[3])));
                claimed = abi.decode(logs[i].data, (uint256));
            } else if (t0 == FORWARDED && logs[i].emitter == address(treasury)) {
                ++forwards;
            }
        }
        assertEq(collections, 1, "one ProtocolCollected per collection");
        assertEq(claims, 1, "one Claimed per collection");
    }

    function test_collectToEmitsOneCanonicalCollection() public {
        Currency q = _earn();
        uint256 owed = r2.claimable(q, address(treasury));
        vm.recordLogs();
        vm.prank(address(0xCAFE)); // permissionless
        uint256 received = treasury.collectTo(address(r2), q);
        (address collectedTo, uint256 collected, address claimedTo, uint256 claimed, uint256 forwards) =
            _shape(vm.getRecordedLogs());
        assertEq(received, owed);
        assertEq(collectedTo, TARGET);
        assertEq(claimedTo, TARGET);
        assertEq(collected, claimed);
        assertEq(collected, owed);
        assertEq(forwards, 0, "the treasury never held these funds");
    }

    function test_collectEmitsCollectionThenDelivery() public {
        Currency q = _earn();
        uint256 owed = r2.claimable(q, address(treasury));
        vm.recordLogs();
        treasury.collect(address(r2), q);
        (address collectedTo, uint256 collected, address claimedTo, uint256 claimed, uint256 forwards) =
            _shape(vm.getRecordedLogs());
        assertEq(collectedTo, address(treasury));
        assertEq(claimedTo, address(treasury));
        assertEq(collected, claimed);
        assertEq(collected, owed);
        assertEq(forwards, 1);
    }
}
