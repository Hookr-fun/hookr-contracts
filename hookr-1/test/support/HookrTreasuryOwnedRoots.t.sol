// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrOwnedRoots} from "../../src/interfaces/IHookrOwnedRoots.sol";
import {IHookrRootRegistrar} from "../../src/interfaces/IHookrRootRegistrar.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {OwnedFakeCompanion, OwnedForgedRegistry} from "../owned/OwnedRootsMocks.sol";
import {OwnedRootsFixture} from "../owned/OwnedRootsFixture.sol";

/// @notice Decision 7: HookrTreasury collects from an owned root's companion Rules without `admitSource`, by provenance
///         (the owned-root registry's `isOwnedRoot` and the root's factory's `rulesOf`), and pins the companion's
///         codehash at that first collection as it does for admitted sources.
contract HookrTreasuryOwnedRootsTest is OwnedRootsFixture {
    using CurrencyLibrary for Currency;

    HookrRoot internal owned;
    HookrRules internal companion;
    PoolKey internal ownedKey;

    function setUp() public {
        _setUpOwned();
        (owned, companion) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        (, ownedKey,) = _launchAs(stranger, address(owned), _nativeMember(address(companion), _rc(), 0));
        _trade(ownedKey, true, true, 5 ether);
    }

    /// @notice The first collection admits the companion at its codehash and pays the whole claim to the target.
    function test_companionIsCollectedWithoutAdmitSource() public {
        uint256 owed = companion.claimable(ETH, address(hookrTreasury));
        assertGt(owed, 0, "protocol fees accrued in the companion");
        assertEq(hookrTreasury.sourceCodeHash(address(companion)), bytes32(0), "never admitted");
        uint256 before = TARGET.balance;
        vm.expectEmit(true, true, false, false, address(hookrTreasury));
        emit IHookrTreasury.SourceAdmitted(address(companion), address(companion).codehash);
        vm.expectEmit(true, true, true, true, address(hookrTreasury));
        emit IHookrTreasury.ProtocolCollected(address(companion), ETH, address(hookrTreasury), owed);
        vm.prank(stranger);
        assertEq(hookrTreasury.collect(address(companion), ETH), owed);
        assertEq(TARGET.balance - before, owed, "the target received the whole claim");
        assertEq(hookrTreasury.sourceCodeHash(address(companion)), address(companion).codehash, "pinned");
        assertEq(companion.claimable(ETH, address(hookrTreasury)), 0);
        assertEq(address(hookrTreasury).balance, 0);
        assertTrue(companion.accountingInvariant(ETH));
        // Later collections read the pin, as for any admitted source.
        _trade(ownedKey, true, true, 1 ether);
        uint256 more = companion.claimable(ETH, address(hookrTreasury));
        vm.recordLogs();
        assertEq(hookrTreasury.collect(address(companion), ETH), more);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IHookrTreasury.SourceAdmitted.selector, "admitted once");
        }
        vm.expectRevert(IHookrTreasury.SourceAlreadyAdmitted.selector);
        hookrTreasury.admitSource(address(companion));
    }

    /// @notice ATT-01's rule holds for a collection that admits by provenance: one `SourceAdmitted`, then exactly one
    ///         `ProtocolCollected(source, currency, to, amount)` matching the companion's `Claimed`.
    function test_provenanceCollectionEmitsOneCollectionEvent() public {
        uint256 owed = companion.claimable(ETH, address(hookrTreasury));
        vm.recordLogs();
        hookrTreasury.collect(address(companion), ETH);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 admitted;
        uint256 collected;
        uint256 claimed;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 topic = logs[i].topics[0];
            if (logs[i].emitter == address(hookrTreasury) && topic == IHookrTreasury.SourceAdmitted.selector) {
                ++admitted;
            }
            if (logs[i].emitter == address(hookrTreasury) && topic == IHookrTreasury.ProtocolCollected.selector) {
                ++collected;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(companion));
                assertEq(address(uint160(uint256(logs[i].topics[3]))), address(hookrTreasury));
                assertEq(abi.decode(logs[i].data, (uint256)), owed);
            }
            if (logs[i].emitter == address(companion) && topic == keccak256("Claimed(address,address,address,uint256)"))
            {
                ++claimed;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(hookrTreasury), "the beneficiary");
                assertEq(address(uint160(uint256(logs[i].topics[3]))), address(hookrTreasury), "paid to the treasury");
                assertEq(abi.decode(logs[i].data, (uint256)), owed);
            }
        }
        assertEq(admitted, 1);
        assertEq(collected, 1);
        assertEq(claimed, 1);
    }

    /// @notice The provenance answers are bounded calls that fail closed: a collection starved of gas reverts and
    ///         admits nothing, and the same collection with gas admits the companion.
    function test_starvedProvenanceCheckAdmitsNothing() public {
        bytes memory call = abi.encodeCall(HookrTreasury.collect, (address(companion), ETH));
        (bool ok,) = address(hookrTreasury).call{gas: 60_000}(call);
        assertFalse(ok);
        assertEq(hookrTreasury.sourceCodeHash(address(companion)), bytes32(0), "nothing admitted");
        (ok,) = address(hookrTreasury).call(call);
        assertTrue(ok);
        assertEq(hookrTreasury.sourceCodeHash(address(companion)), address(companion).codehash);
    }

    /// @notice `collectTo` (anyone) and `collectAsClaims` (owner or target) admit by provenance too.
    function test_collectToAndCollectAsClaimsAdmitByProvenance() public {
        uint256 owed = companion.claimable(ETH, address(hookrTreasury));
        uint256 before = TARGET.balance;
        vm.prank(stranger);
        assertEq(hookrTreasury.collectTo(address(companion), ETH), owed);
        assertEq(TARGET.balance - before, owed);
        assertEq(hookrTreasury.sourceCodeHash(address(companion)), address(companion).codehash);

        (HookrRoot second, HookrRules secondCompanion) = _deployOwned(_sel(stranger, F.ALL_FEATURES));
        (, PoolKey memory key,) =
            _launchAs(stranger, address(second), _nativeMember(address(secondCompanion), _rc(), 0));
        _trade(key, true, true, 2 ether);
        uint256 owed2 = secondCompanion.claimable(ETH, address(hookrTreasury));
        vm.prank(stranger);
        vm.expectRevert(IHookrTreasury.NotOwner.selector);
        hookrTreasury.collectAsClaims(address(secondCompanion), ETH);
        uint256 claimsBefore = manager.balanceOf(TARGET, ETH.toId());
        assertEq(hookrTreasury.collectAsClaims(address(secondCompanion), ETH), owed2);
        assertEq(manager.balanceOf(TARGET, ETH.toId()) - claimsBefore, owed2);
        assertEq(hookrTreasury.sourceCodeHash(address(secondCompanion)), address(secondCompanion).codehash);
    }

    /// @notice With no registry named, an unadmitted companion is refused as before; companions already admitted
    ///         keep being collected, and `admitSource` still admits one.
    function test_noRegistryNamedRefusesUnadmittedCompanions() public {
        hookrTreasury.collect(address(companion), ETH);
        (HookrRoot second, HookrRules secondCompanion) = _deployOwned(_sel(stranger, F.ALL_FEATURES));
        (, PoolKey memory key,) =
            _launchAs(stranger, address(second), _nativeMember(address(secondCompanion), _rc(), 0));
        _trade(key, true, true, 2 ether);
        _trade(ownedKey, true, true, 2 ether);
        vm.expectEmit(true, true, false, false, address(hookrTreasury));
        emit IHookrTreasury.OwnedRootRegistrySet(address(registry), address(0));
        hookrTreasury.setOwnedRootRegistry(address(0));
        assertEq(hookrTreasury.ownedRootRegistry(), address(0));
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(secondCompanion), ETH);
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collectTo(address(secondCompanion), ETH);
        assertGt(hookrTreasury.collect(address(companion), ETH), 0, "an admitted companion stays admitted");
        hookrTreasury.admitSource(address(secondCompanion));
        assertGt(hookrTreasury.collect(address(secondCompanion), ETH), 0);
    }

    function test_setOwnedRootRegistryIsTheOwners() public {
        assertEq(hookrTreasury.ownedRootRegistry(), address(registry));
        vm.prank(stranger);
        vm.expectRevert(IHookrTreasury.NotOwner.selector);
        hookrTreasury.setOwnedRootRegistry(address(0));
        vm.expectRevert(IHookrTreasury.InvalidAddress.selector);
        hookrTreasury.setOwnedRootRegistry(address(0xBEEF));
        HookrTreasury fresh = new HookrTreasury(address(this), TARGET, manager);
        assertEq(fresh.ownedRootRegistry(), address(0), "none at construction");
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        fresh.collect(address(companion), ETH);
    }

    /// @notice The registry is appended to the treasury's namespaced State after the owned-root fee: field 14.
    function test_registryIsAppendedToTheTreasuryState() public view {
        // keccak256(abi.encode(uint256(keccak256("hookr.treasury")) - 1)) & ~bytes32(uint256(0xff))
        uint256 base = 0xfbe7548a70873d48ea7fddfba1199106377ceedcd42dbef7dc33de62b5287a00;
        bytes32 word = vm.load(address(hookrTreasury), bytes32(base + 14));
        assertEq(address(uint160(uint256(word))), address(registry));
        assertEq(uint256(word) >> 160, 0, "alone in its slot");
        assertEq(uint16(uint256(vm.load(address(hookrTreasury), bytes32(base + 13)))), 100, "the fee before it");
    }

    /// @notice A contract posing as a companion is refused: it names an owned root whose factory names another
    ///         companion, a root that is not owned, or an account that is not a root at all.
    function test_fakeCompanionsAreRefused() public {
        OwnedFakeCompanion posing = new OwnedFakeCompanion(address(owned), address(hookrTreasury), manager);
        posing.setOwed{value: 1 ether}(1 ether);
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(posing), ETH);
        OwnedFakeCompanion onShared = new OwnedFakeCompanion(address(root), address(hookrTreasury), manager);
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(onShared), ETH);
        OwnedFakeCompanion onNothing = new OwnedFakeCompanion(address(0xA11CE), address(hookrTreasury), manager);
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collectTo(address(onNothing), ETH);
        // The shared Rules, admitted by the owner, are no owned root's companion either way.
        HookrRules unadmitted = new HookrRules(manager, registry, address(hookrTreasury), address(root), PROTOCOL_FLOOR);
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(unadmitted), ETH);
        assertEq(hookrTreasury.sourceCodeHash(address(posing)), bytes32(0));
        assertEq(hookrTreasury.sourceCodeHash(address(unadmitted)), bytes32(0));
    }

    /// @notice A forged registry vouches for nothing: the treasury asks only the registry its owner named. Naming a
    ///         forged one is the owner's act and admits no more than `admitSource` could.
    function test_forgedRegistryIsNeverAsked() public {
        OwnedForgedRegistry forged = new OwnedForgedRegistry();
        OwnedForgedRegistry forgedRegistrar = new OwnedForgedRegistry();
        OwnedFakeCompanion fake = new OwnedFakeCompanion(address(0xF00D), address(hookrTreasury), manager);
        forged.vouch(address(0xF00D), address(forgedRegistrar), address(fake));
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(fake), ETH);
        // The owner could name it, as it could `admitSource(fake)`: the fake is then a source like any admitted one,
        // whose collection only ever pays this treasury.
        hookrTreasury.setOwnedRootRegistry(address(forged));
        fake.setOwed{value: 1 ether}(1 ether);
        uint256 before = TARGET.balance;
        assertEq(hookrTreasury.collect(address(fake), ETH), 1 ether);
        assertEq(TARGET.balance - before, 1 ether);
    }

    /// @notice Provenance refuses what `admitSource` refuses: a companion that is the target, the pending target, a
    ///         listed integrator or one with a pending listing.
    function test_companionAsTargetOrIntegratorIsRefused() public {
        hookrTreasury.proposeIntegrator(address(companion), 5_000);
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(companion), ETH);
        vm.warp(vm.getBlockTimestamp() + hookrTreasury.TERMS_DELAY());
        hookrTreasury.acceptIntegrator(address(companion));
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(companion), ETH);
        hookrTreasury.removeIntegrator(address(companion));
        hookrTreasury.proposeTarget(address(companion));
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(companion), ETH);
        vm.warp(vm.getBlockTimestamp() + hookrTreasury.TARGET_DELAY());
        hookrTreasury.acceptTarget();
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(companion), ETH);
        hookrTreasury.proposeTarget(TARGET);
        vm.warp(vm.getBlockTimestamp() + hookrTreasury.TARGET_DELAY());
        hookrTreasury.acceptTarget();
        assertGt(hookrTreasury.collect(address(companion), ETH), 0, "admitted once it is neither");
    }

    /// @notice Once admitted, a companion can be neither the target nor an integrator, as any admitted source.
    function test_admittedCompanionCanBeNeitherTargetNorIntegrator() public {
        hookrTreasury.collect(address(companion), ETH);
        vm.expectRevert(IHookrTreasury.InvalidTarget.selector);
        hookrTreasury.proposeTarget(address(companion));
        vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
        hookrTreasury.proposeIntegrator(address(companion), 5_000);
    }

    /// @notice The codehash is pinned at the first collection; a later change of code refuses collection.
    function test_pinnedCompanionRefusesACodeChange() public {
        hookrTreasury.collect(address(companion), ETH);
        _trade(ownedKey, true, true, 1 ether);
        vm.etch(address(companion), address(sharedRules).code);
        vm.expectRevert(IHookrTreasury.SourceCodeChanged.selector);
        hookrTreasury.collect(address(companion), ETH);
        vm.expectRevert(IHookrTreasury.SourceCodeChanged.selector);
        hookrTreasury.collectTo(address(companion), ETH);
        vm.expectRevert(IHookrTreasury.SourceCodeChanged.selector);
        hookrTreasury.collectAsClaims(address(companion), ETH);
    }

    /// @notice A companion admitted before its factory broke keeps being collected; one not yet admitted is refused
    ///         while the factory cannot answer.
    function test_brokenFactoryFailsClosedForUnadmittedCompanions() public {
        hookrTreasury.collect(address(companion), ETH);
        (HookrRoot second, HookrRules secondCompanion) = _deployOwned(_sel(stranger, F.ALL_FEATURES));
        (, PoolKey memory key,) =
            _launchAs(stranger, address(second), _nativeMember(address(secondCompanion), _rc(), 0));
        _trade(key, true, true, 2 ether);
        _trade(ownedKey, true, true, 2 ether);
        vm.etch(address(factory), hex"fe");
        assertGt(hookrTreasury.collect(address(companion), ETH), 0);
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(secondCompanion), ETH);
    }

    /// @notice Every answer of the check fails closed: a source without `trustedRoot()`, one with dirty high bits, a
    ///         registry or a factory that reverts or answers more than one word.
    function test_everyAnswerFailsClosed() public {
        vm.mockCallRevert(address(companion), abi.encodeCall(IHookrRules.trustedRoot, ()), "no");
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(companion), ETH);
        vm.clearMockedCalls();
        vm.mockCall(
            address(companion),
            abi.encodeCall(IHookrRules.trustedRoot, ()),
            abi.encode(uint256(uint160(address(owned))) | (1 << 160))
        );
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(companion), ETH);
        vm.clearMockedCalls();
        vm.mockCallRevert(address(registry), abi.encodeCall(IHookrOwnedRoots.isOwnedRoot, (address(owned))), "no");
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(companion), ETH);
        vm.clearMockedCalls();
        vm.mockCall(
            address(registry), abi.encodeCall(IHookrOwnedRoots.isOwnedRoot, (address(owned))), abi.encode(uint256(2))
        );
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(companion), ETH);
        vm.clearMockedCalls();
        vm.mockCall(
            address(factory),
            abi.encodeCall(IHookrRootRegistrar.rulesOf, (address(owned))),
            abi.encode(address(companion), uint256(0))
        );
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(companion), ETH);
        vm.clearMockedCalls();
        assertGt(hookrTreasury.collect(address(companion), ETH), 0, "the true answers admit it");
    }

    /// @notice A companion of this registry that pays another treasury is not this treasury's source.
    function test_aCompanionPayingAnotherTreasuryIsRefused() public {
        HookrTreasury other = new HookrTreasury(address(this), TARGET, manager);
        other.setOwnedRootRegistry(address(registry));
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        other.collect(address(companion), ETH);
        assertEq(other.sourceCodeHash(address(companion)), bytes32(0));
    }

    /// @notice A companion that names this treasury but pays on another PoolManager is not this treasury's source: the
    ///         claims it would move are not claims on this PoolManager. Mutation gate TR-7.
    function test_aCompanionOnAnotherPoolManagerIsRefused() public {
        vm.mockCall(address(companion), abi.encodeWithSignature("poolManager()"), abi.encode(address(0xBAD)));
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        hookrTreasury.collect(address(companion), ETH);
        assertEq(hookrTreasury.sourceCodeHash(address(companion)), bytes32(0), "nothing admitted");
        vm.clearMockedCalls();
        assertGt(hookrTreasury.collect(address(companion), ETH), 0, "its true answer admits it");
    }

    /// @notice The registry's brakes on the owned root and its factory leave its companion collectable.
    function test_brakesLeaveTheCompanionCollectable() public {
        registry.deactivateRootFactory(address(factory));
        registry.closeRoot(address(owned));
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(owned)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.retireRoot(address(owned));
        assertTrue(IHookrOwnedRoots(address(registry)).isOwnedRoot(address(owned)));
        uint256 owed = companion.claimable(ETH, address(hookrTreasury));
        assertEq(hookrTreasury.collect(address(companion), ETH), owed);
    }
}
