// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrOwnedRoots} from "../../src/interfaces/IHookrOwnedRoots.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice The owned-roots lab's review findings (M-1, L-1 to L-4) on the self-serve genesis design: what owner
///         decisions 2 and 4 closed, what stays pinned, and the isolation of owned ledgers.
///         Audit findings L-2 and L-3.
contract OwnedRootsRegistrationLimitsTest is OwnedRootsFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    function setUp() public {
        _setUpOwned();
    }

    function launchExternal(address rootAddr, IHookrLauncher.Member memory m)
        external
        returns (bytes32 family, PoolKey memory key, address subject)
    {
        return _launchAs(stranger, rootAddr, m);
    }

    /// @notice M-1, cap exhaustion (decision 2). Tier 2 is self-serve, so anyone can take a slot of the factory's 500,
    ///         and every slot now pays the treasury's fee to its target on top of the gas (the cost is recorded in
    ///         OwnedRootsFee.t.sol). No funds are at risk, existing pools are unaffected, and the brakes are instant.
    function test_eachSlotPaysTheFee() public {
        vm.prank(stranger);
        bytes32 own = book.writeProfile(bytes32("filler"), _profile(F.ALL_FEATURES, true, stranger));
        uint256 before = TARGET.balance;
        _deployOwned(_selFor(own, stranger, F.ALL_FEATURES, true));
        _deployOwned(_sel(stranger, F.ALL_FEATURES));
        assertEq(factory.allDeploymentsLength(), 2);
        assertEq(TARGET.balance - before, 2 * hookrTreasury.ownedRootFee(), "each slot paid the fee");
        registry.deactivateRootFactory(address(factory));
        bytes32 salt = _mine(brand);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        uint256 fee = _fee(factory);
        vm.prank(brand);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        _deployCall(factory, fee, sel, salt);
    }

    /// @notice L-1 stays fixed: the selections name the profile version, and a rewrite before inclusion refuses the
    ///         deployment (OwnedRootFactory.t.sol has the full case).
    function test_profileVersionIsPinned() public {
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        book.writeProfile(bytes32("standard"), _profile(F.ALL_FEATURES, true, address(this)));
        bytes32 salt = _mine(brand);
        uint256 fee = _fee(factory);
        vm.prank(brand);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrOwnedRootFactory.ProfileVersionMismatch.selector, templateProfile, uint32(1), uint32(2)
            )
        );
        _deployCall(factory, fee, sel, salt);
    }

    /// @notice L-2 CLOSED by decision 4: there is no transaction-wide arm. Whether an opener may open a pool on an
    ///         owner-only root is a function of the root's record and the opener alone, which the registry asks with
    ///         the launcher's caller (`rootOpenFor`); nothing the owner does earlier in a transaction opens it for
    ///         anyone else.
    function test_ownerOnlyOpeningIsCallerBound() public {
        (HookrRoot ownerOnly, HookrRules companion) =
            _deployOwned(_selFor(templateProfile, brand, F.ALL_FEATURES, false));
        IHookrOwnedRoots o = IHookrOwnedRoots(address(registry));
        assertTrue(o.rootOpenFor(address(ownerOnly), brand));
        assertFalse(o.rootOpenFor(address(ownerOnly), stranger));
        // The owner opens a pool, then a stranger asks in the same transaction: still closed for the stranger.
        _launchAs(brand, address(ownerOnly), _nativeMember(address(companion), _rc(), 0));
        assertFalse(o.rootOpenFor(address(ownerOnly), stranger));
        assertFalse(factory.mayOpen(address(ownerOnly), stranger));
    }

    /// @notice L-3: the registry's pause stops owned-root registration at once, in the factory (the template takes no
    ///         new pools) and in the registry's own `registerOwnedRoot` (`MarketsPaused`).
    function test_pauseStopsOwnedRootRegistration() public {
        bytes32 salt = _mine(brand);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        uint256 fee = _fee(factory);
        registry.pauseNewMarkets();
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.InvalidTemplate.selector, address(root)));
        _deployCall(factory, fee, sel, salt);
        // The registry's own check, whatever a factory passes: refused while new markets are paused.
        IHookrRegistry.Admission memory a = registry.admission(address(root), address(sharedRules));
        vm.prank(address(factory));
        vm.expectRevert(IHookrRegistry.MarketsPaused.selector);
        IHookrOwnedRoots(address(registry))
            .registerOwnedRoot(address(root), address(root), address(sharedRules), a, new address[](0));
    }

    /// @notice PIN L-4 (low, latent; NOT reachable on Robinhood Chain, where 0x0 holds wei, nor with the release's
    ///         curated router). With no curated router, HookrRoot stores `curatedRouterCodeHash = address(0).codehash`:
    ///         zero while 0x0 is empty, keccak256("") once it holds any wei. A root deployed after 0x0 gained wei still
    ///         registers (the registry checks the curated router's address, not that hash), but its byte identity with
    ///         the template reads false. The release pins the Universal Router, whose codehash does not move.
    function test_pin_curatedZeroIdentityDependsOnAddressZeroState() public {
        assertEq(address(0).codehash, bytes32(0), "0x0 is empty in the unit-test environment");
        assertEq(root.curatedRouter(), address(0));
        assertEq(root.curatedRouterCodeHash(), bytes32(0));
        vm.deal(address(0), 1);
        (HookrRoot owned,) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        assertEq(owned.curatedRouterCodeHash(), keccak256(""));
        assertFalse(factory.runtimeMatchesTemplate(address(owned)), "the identity check sees the difference");
        assertTrue(IHookrOwnedRoots(address(registry)).isOwnedRoot(address(owned)));
    }

    /// @notice The owned root's companion cannot reach the shared ledger, nor the shared Rules an owned root.
    function test_attack_ownedRootCannotReachTheSharedLedger() public {
        (HookrRoot owned, HookrRules companion) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        IHookrLauncher.Member memory m = _nativeMember(address(sharedRules), _rc(), 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, address(sharedRules)));
        this.launchExternal(address(owned), m);
        m = _nativeMember(address(companion), _rc(), 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, address(companion)));
        this.launchExternal(address(root), m);
        (, PoolKey memory shared,) = _launchAs(trader, address(root), _nativeMember(address(sharedRules), _rc(), 0));
        _trade(shared, true, true, 5 ether);
        uint256 sharedProtocol = sharedRules.claimable(ETH, address(hookrTreasury));
        assertGt(sharedProtocol, 0);
        assertEq(companion.claimable(ETH, address(hookrTreasury)), 0);
        assertEq(manager.balanceOf(address(companion), ETH.toId()), 0);
        HookrTypes.Settlement memory z;
        HookrTypes.SwapContext memory x;
        x.id = shared.toId();
        vm.prank(address(owned));
        vm.expectRevert();
        companion.settleSwap(x, z);
        assertEq(sharedRules.claimable(ETH, address(hookrTreasury)), sharedProtocol);
    }

    /// @notice Nobody becomes a root's owner of record without consent: an owner the deployer names is only nominated
    ///         until it accepts, and holds no power before.
    function test_attack_cannotAssignARootToABrandWithoutConsent() public {
        (HookrRoot owned,) = _deployWith(factory, stranger, _sel(brand, F.ALL_FEATURES), _mine(stranger));
        assertEq(factory.ownedRoot(address(owned)).owner, address(0));
        assertEq(factory.pendingRootOwner(address(owned)), brand);
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.NotRootOwner.selector, address(owned), brand));
        factory.setPaused(address(owned), true);
    }
}
