// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrSwapGate} from "../../src/interfaces/IHookrSwapGate.sol";
import {IHookrFamilyRouter} from "../../src/interfaces/IHookrFamilyRouter.sol";
import {IHookrLauncherView} from "../../src/interfaces/IHookrLauncherView.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {HookrFamilyRouter} from "../../src/periphery/HookrFamilyRouter.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {OwnedRootsFixture} from "../owned/OwnedRootsFixture.sol";

/// @dev A gate whose check turns out to be wrong: it vouches for any payer a caller names.
contract VouchAnyGate is IHookrSwapGate {
    function beforeUnlock(address, address, PoolKey calldata, bool, int256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHookrSwapGate.beforeUnlock.selector;
    }
}

/// @notice REG-02: an owned root is frozen, so only the owner can revoke its admissions, and its copy of a template
///         gate stays live when the template's admission is revoked. The guardian's documented instant answer on a
///         frozen root, `closeRoot`, stopped new pools only, while HookrRouter.swapGated reads a GATE admission on every
///         swap: a misbehaving gate copy kept vouching for any payer a caller named on every owned root that copied it
///         until the owner revoked each copy. swapGated now refuses every gate on a root a brake holds closed while the
///         owner can still reopen it (`rootReopenable`), so `closeRoot` stops the copy at once and the owner lifts it.
///         The frozen-root rule is unchanged, a retired root (which never reopens) keeps its gates, so the guardian
///         gains no permanent switch, and pausing new markets still leaves every swap running.
contract HookrRegistryOwnedGateCopyBrakeTest is OwnedRootsFixture {
    address internal guardian = address(0x6A7D);
    address internal victim = address(0xBEEF);
    VouchAnyGate internal gate;
    HookrFamilyRouter internal fam;
    HookrRoot internal owned;
    PoolKey internal ownedKey;
    bytes32 internal ownedFamily;
    PoolKey internal sharedKey;
    bytes32 internal sharedFamily;

    function setUp() public {
        _setUpOwned();
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardian));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.setGuardian(guardian);
        // Two gates admitted on the template through the timelock: one that turns out to vouch for anyone, and the
        // release's family router.
        gate = new VouchAnyGate();
        _admit(address(root), _gateAdmission(address(gate)));
        // Any contract with code stands in for Permit2: these trades pay native ETH.
        fam = new HookrFamilyRouter(router, IHookrLauncherView(address(launcher)), address(manager));
        _admit(address(root), _gateAdmission(address(fam)));
        // An owned root deployed from a profile listing both copies them, frozen.
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        p.gates = new address[](2);
        (p.gates[0], p.gates[1]) = (address(gate), address(fam));
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("reg02"), p);
        HookrRules companion;
        (owned, companion) = _deployOwned(_selFor(id, brand, F.ALL_FEATURES, true));
        assertEq(registry.admission(address(owned), address(gate)).implementation, address(gate), "gate copied");
        assertEq(registry.admission(address(owned), address(fam)).implementation, address(fam), "router copied");
        (ownedFamily, ownedKey,) = _launchAs(brand, address(owned), _nativeMember(address(companion), _rc(), 0));
        (sharedFamily, sharedKey,) = _launchAs(stranger, address(root), _nativeMember(address(sharedRules), _rc(), 0));
    }

    /// @dev A stranger buys on `key` with 1 ETH through the misbehaving gate, naming the victim as the payer.
    function _spoof(PoolKey memory key) internal returns (uint256 amountOut) {
        IHookrRouter.Swap memory p = _swapParams(key, true, true, 1 ether);
        p.recipient = stranger;
        vm.prank(stranger);
        (, amountOut) = router.swapGated{value: 1 ether}(p, victim, address(gate), "", address(0), new uint256[](0));
    }

    /// @dev A one-leg family buy of `key` for 1 ETH (native quote, so the subject is currency1).
    function _familyBuy(PoolKey memory key, bytes32 family) internal returns (uint256 amountOut) {
        IHookrFamilyRouter.FamilyTrade memory t;
        t.familyId = family;
        t.input = ETH;
        t.output = key.currency1;
        t.legs = new IHookrFamilyRouter.Leg[](1);
        t.legs[0].key = key;
        t.legs[0].amountIn = 1 ether;
        t.legs[0].minOut = 1;
        t.legs[0].campaigns = new uint256[](0);
        t.minTotalOut = 1;
        t.recipient = trader;
        t.deadline = vm.getBlockTimestamp();
        vm.prank(trader);
        (, amountOut) = fam.trade{value: 1 ether}(t, "");
    }

    function _closed(address r) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHookrRouter.RootClosed.selector, r);
    }

    /// The PoC: once the guardian has braked, the misbehaving gate copy no longer vouches on the owned root. The
    /// frozen-root rule stands (the guardian still cannot revoke the copy), and the pool keeps trading.
    function test_poc_guardianClosesTheOwnedRootAndItsGateCopyStopsVouching() public {
        assertGt(_spoof(ownedKey), 0, "the copy vouches for anyone");

        vm.startPrank(guardian);
        registry.revokeModuleAdmission(address(root), address(gate));
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.revokeModuleAdmission(address(owned), address(gate));
        registry.closeRoot(address(owned));
        vm.stopPrank();
        assertEq(registry.admission(address(root), address(gate)).implementation, address(0), "template stopped");
        IHookrRegistry.Admission memory copy = registry.admission(address(owned), address(gate));
        assertEq(copy.implementation, address(gate), "the copy stays: copies never follow the template");
        assertTrue(registry.rootReopenable(address(owned)));

        vm.expectRevert(_closed(address(owned)));
        this.spoofExternal(ownedKey);
        vm.expectRevert(_closed(address(owned)));
        this.familyBuyExternal(ownedKey, ownedFamily);
        (uint256 amountIn, uint256 amountOut) = _trade(ownedKey, true, true, 1 ether);
        assertEq(amountIn, 1 ether);
        assertGt(amountOut, 0, "plain swaps keep running on the closed root");
        assertGt(_familyBuy(sharedKey, sharedFamily), 0, "another root's gates are untouched");
    }

    /// The owner revokes the copy and lifts the closure through the timelock: the revoked copy stays refused for good
    /// and the root's other gate vouches again.
    function test_ownerRevokesTheCopyAndReopensTheRoot() public {
        vm.prank(guardian);
        registry.closeRoot(address(owned));
        registry.revokeModuleAdmission(address(owned), address(gate));
        registry.queue(registry.REOPEN_ROOT(), abi.encode(address(owned)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.reopenRoot(address(owned));
        assertFalse(registry.rootReopenable(address(owned)));

        vm.expectRevert(abi.encodeWithSelector(IHookrRouter.GateNotAdmitted.selector, address(owned), address(gate)));
        this.spoofExternal(ownedKey);
        assertGt(_familyBuy(ownedKey, ownedFamily), 0, "the family router vouches again");
    }

    /// A retired root never reopens, so closing it holds nothing for its gates: the guardian gains no permanent switch
    /// over a retired root's gated swaps.
    function test_aClosureOnARetiredRootNeverStopsItsGates() public {
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(owned)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.retireRoot(address(owned));
        vm.prank(guardian);
        registry.closeRoot(address(owned));
        assertTrue(registry.rootClosed(address(owned)));
        assertFalse(registry.rootReopenable(address(owned)), "a retired root never reopens");
        assertGt(_familyBuy(ownedKey, ownedFamily), 0, "the retired root's gates still vouch");
    }

    /// Pausing new markets stops new activity only: gated swaps keep running on every root.
    function test_pausingNewMarketsLeavesGatedSwapsRunning() public {
        vm.prank(guardian);
        registry.pauseNewMarkets();
        assertFalse(registry.rootReopenable(address(owned)));
        assertGt(_familyBuy(ownedKey, ownedFamily), 0, "owned root");
        assertGt(_familyBuy(sharedKey, sharedFamily), 0, "shared root");
    }

    /// The brake works the same on the shared root, where the guardian could also revoke the gate itself.
    function test_closingTheSharedRootStopsItsGatesUntilItReopens() public {
        vm.prank(guardian);
        registry.closeRoot(address(root));
        vm.expectRevert(_closed(address(root)));
        this.familyBuyExternal(sharedKey, sharedFamily);
        (, uint256 amountOut) = _trade(sharedKey, true, true, 1 ether);
        assertGt(amountOut, 0, "plain swaps keep running");
        assertGt(_familyBuy(ownedKey, ownedFamily), 0, "the owned root is untouched");

        registry.queue(registry.REOPEN_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.reopenRoot(address(root));
        assertGt(_familyBuy(sharedKey, sharedFamily), 0, "the shared root's gates vouch again");
    }

    /// `rootReopenable` is true exactly while a closed root is unretired, the condition REOPEN_ROOT executes under.
    function test_rootReopenableReadsClosedUnretiredRootsOnly() public {
        assertFalse(registry.rootReopenable(address(0x1234)), "unregistered");
        assertFalse(registry.rootReopenable(address(owned)), "open");
        vm.prank(guardian);
        registry.closeRoot(address(owned));
        assertTrue(registry.rootReopenable(address(owned)), "closed");
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(owned)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.retireRoot(address(owned));
        assertTrue(registry.rootClosed(address(owned)));
        assertFalse(registry.rootReopenable(address(owned)), "closed and retired");
    }

    /// @dev External wrappers, so an expected revert applies to the router call inside.
    function spoofExternal(PoolKey memory key) external returns (uint256) {
        return _spoof(key);
    }

    function familyBuyExternal(PoolKey memory key, bytes32 family) external returns (uint256) {
        return _familyBuy(key, family);
    }
}
