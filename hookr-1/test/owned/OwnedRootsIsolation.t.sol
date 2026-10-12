// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRootRegistrar} from "../../src/interfaces/IHookrRootRegistrar.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice No owned-root failure reaches pools that do not use it, and no brake, profile rewrite, pause or factory
///         failure reaches existing pools: each keeps trading both ways, its LPs exit and every claim is paid.
contract OwnedRootsIsolationTest is OwnedRootsFixture {
    using PoolIdLibrary for PoolKey;

    HookrRoot internal owned;
    HookrRules internal companion;
    PoolKey internal sharedKey;
    PoolKey internal ownedKey;
    bytes32 internal sharedFamily;
    bytes32 internal ownedFamily;

    function setUp() public {
        _setUpOwned();
        (owned, companion) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        (sharedFamily, sharedKey,) = _launchAs(trader, address(root), _nativeMember(address(sharedRules), _rc(), 0));
        (ownedFamily, ownedKey,) = _launchAs(brand, address(owned), _nativeMember(address(companion), _rc(), 0));
    }

    function _allStillWork() internal {
        (, uint256 a) = _trade(sharedKey, true, true, 1 ether);
        (, uint256 b) = _trade(ownedKey, true, true, 1 ether);
        assertGt(a, 0);
        assertGt(b, 0);
        _trade(sharedKey, false, true, uint128(a / 2));
        _trade(ownedKey, false, true, uint128(b / 2));
        vm.prank(trader);
        launcher.withdraw(sharedFamily, 0, 1e18, 0, 0, trader, vm.getBlockTimestamp());
        vm.prank(brand);
        launcher.withdraw(ownedFamily, 0, 1e18, 0, 0, brand, vm.getBlockTimestamp());
        assertGt(_collect(address(sharedRules)), 0, "the shared Rules pay the treasury");
        assertGt(_collect(address(companion)), 0, "the companion pays the treasury");
        uint256 royaltyOwed = companion.claimable(ETH, royalty);
        assertGt(royaltyOwed, 0);
        vm.prank(royalty);
        companion.claim(ETH);
        assertTrue(sharedRules.accountingInvariant(ETH));
        assertTrue(companion.accountingInvariant(ETH));
    }

    function test_everyBrakeAndRewriteLeavesExistingPoolsTrading() public {
        book.writeProfile(bytes32("standard"), _profile(0, false, address(this)));
        vm.prank(brand);
        factory.setPaused(address(owned), true);
        registry.deactivateRootFactory(address(factory));
        registry.pauseNewMarkets();
        registry.closeRoot(address(owned));
        registry.closeRoot(address(root));
        registry.closeLaneOf(address(owned));
        // The module brake reaches the frozen owned root through its owner alone.
        registry.revokeModuleAdmission(address(owned), address(companion));
        assertEq(registry.admission(address(owned), address(companion)).implementation, address(0));
        _allStillWork();
    }

    function test_retiringBothRootsLeavesExistingPoolsTrading() public {
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(owned)));
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.retireRoot(address(owned));
        registry.retireRoot(address(root));
        _allStillWork();
    }

    /// @notice Neither the factory nor the book is on any pool path: broken, both leave every pool trading.
    function test_brokenFactoryAndBookDoNotTouchSwaps() public {
        _collect(address(companion));
        vm.etch(address(factory), hex"fe");
        vm.etch(address(book), hex"fe");
        _allStillWork();
    }

    /// @notice A failure inside an owned root's companion stops that root's swaps only; its LPs still exit because
    ///         HookrRoot's removal check fails open, and the shared root's pools are untouched.
    function test_brokenCompanionDoesNotReachTheSharedRoot() public {
        vm.etch(address(companion), hex"fe");
        (, uint256 a) = _trade(sharedKey, true, true, 1 ether);
        assertGt(a, 0);
        vm.expectRevert();
        this.tradeExternal(ownedKey);
        vm.prank(brand);
        (uint256 x, uint256 y) = launcher.withdraw(ownedFamily, 0, 1e18, 0, 0, brand, vm.getBlockTimestamp());
        assertGt(x + y, 0, "principal exits although the Rules are gone");
    }

    function tradeExternal(PoolKey memory key) external {
        _trade(key, true, true, 1 ether);
    }

    /// @notice Nothing owned roots add is on the swap path: no swap asks the factory or the book, and the router's
    ///         registry read stays the one `isRoot`.
    function test_swapPathNeverAsksTheFactoryOrTheBook() public {
        vm.expectCall(address(factory), abi.encodeWithSelector(IHookrRootRegistrar.mayOpen.selector), 0);
        vm.expectCall(address(factory), abi.encodeWithSelector(IHookrRootRegistrar.rulesOf.selector), 0);
        vm.expectCall(address(book), abi.encodeWithSelector(IHookrOwnedProfiles.profile.selector), 0);
        (, uint256 out) = _trade(ownedKey, true, true, 1 ether);
        _trade(ownedKey, false, true, uint128(out / 2));
        uint256 before = gasleft();
        registry.isRoot(address(owned));
        assertLt(before - gasleft(), 12_000);
    }
}
