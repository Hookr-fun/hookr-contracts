// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRootFactory as HookrPairRootFactory} from "../../src/factory/HookrRootFactory.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {IHookrFactoryRegistry} from "../../src/interfaces/IHookrFactoryRegistry.sol";
import {IHookrOwnedRoots} from "../../src/interfaces/IHookrOwnedRoots.sol";
import {HookrOwnedRootFactory} from "../../src/owned/HookrOwnedRootFactory.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice The genesis-registry path the owned-root factory relies on: `SET_ROOT_FACTORY` is published, timelocked
///         (30 minutes), pinned to the factory's runtime codehash and expires; only an active factory at that hash
///         registers; the pair-root factory registers beside it, and neither registers the other's roots.
contract OwnedRootsGenesisPathTest is OwnedRootsFixture {
    function setUp() public {
        _setUpOwned();
    }

    function test_delayIsTheReleaseThirtyMinutes() public view {
        assertEq(registry.delay(), 30 minutes);
        assertEq(registry.MIN_DELAY(), 30 minutes);
        assertEq(registry.RULES_MIN_GAS_LIMIT(), 2_000_000);
        assertEq(sharedRules.minProtocolShareBps(), 2_000);
    }

    function test_setRootFactoryIsPublishedTimelockedPinnedAndExpires() public {
        HookrOwnedRootFactory f = _newFactory(500);
        bytes32 kind = registry.SET_ROOT_FACTORY();
        bytes memory args = abi.encode(address(f), address(f).codehash, true);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, registry.operationHash(kind, args)));
        registry.setRootFactory(address(f), address(f).codehash, true);
        bytes32 op = registry.queue(kind, args);
        vm.warp(vm.getBlockTimestamp() + DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.setRootFactory(address(f), address(f).codehash, true);
        vm.warp(vm.getBlockTimestamp() + 1 + 14 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrRegistry.OperationExpired.selector, op, uint48(registry.readyAt(op) + 14 days))
        );
        registry.setRootFactory(address(f), address(f).codehash, true);
        registry.queue(kind, args);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.setRootFactory(address(f), address(f).codehash, true);
        assertEq(registry.rootFactoryCodeHash(address(f)), address(f).codehash);
        // The codehash commits to every immutable: a factory with another cap is another codehash.
        assertTrue(address(_newFactory(499)).codehash != address(f).codehash);
        // Not deployed yet, or already active: refused when queued.
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, address(0xFAC7)));
        registry.queue(kind, abi.encode(address(0xFAC7), bytes32(uint256(1)), true));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.AlreadyActive.selector, address(f)));
        registry.queue(kind, abi.encode(address(f), address(f).codehash, true));
        // Only the owner queues; the guardian's powers are brakes.
        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.queue(kind, args);
    }

    /// @notice The pair-root factory and the owned-root factory register side by side; neither registers a root the
    ///         other registered, and one's brake does not reach the other.
    function test_pairRootFactoryRegistersBesideOwnedRoots() public {
        HookrPairRootFactory pf = new HookrPairRootFactory(manager, IHookrFactoryRegistry(address(registry)));
        _activateFactory(address(pf));
        IHookrPairRoot.Params memory p = _pairParams();
        (address pair,) = pf.deploy(_minePair(pf, p), p, SQRT_ONE, "");
        (HookrRoot owned,) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        IHookrOwnedRoots o = IHookrOwnedRoots(address(registry));
        assertEq(registry.rootFactoryOf(pair), address(pf));
        assertEq(registry.rootFactoryOf(address(owned)), address(0));
        assertTrue(o.isOwnedRoot(address(owned)));
        assertFalse(o.isOwnedRoot(pair));
        assertFalse(factory.isFromFactory(pair));
        assertTrue(registry.rootOpen(pair));
        vm.prank(address(pf));
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.registerFactoryRoot(address(owned), address(0));
        vm.prank(address(factory));
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.registerFactoryRoot(pair, address(0));
        // The pair-root factory's brake does not touch owned roots, and the reverse.
        registry.deactivateRootFactory(address(pf));
        assertTrue(registry.isRootFactory(address(factory)));
        _deployOwned(_sel(stranger, F.ALL_FEATURES));
        registry.deactivateRootFactory(address(factory));
        assertTrue(registry.rootOpen(pair));
        assertTrue(registry.rootOpen(address(owned)));
    }

    function _pairParams() internal view returns (IHookrPairRoot.Params memory p) {
        (address c0, address c1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        p.currency0 = Currency.wrap(c0);
        p.currency1 = Currency.wrap(c1);
        p.tickSpacing = 60;
        p.baseLpFeePips = 3000;
        p.maxLpFeePips = 3000;
    }

    /// @dev A salt whose pair-root address under `pf` for this caller carries the pair-root flags 0x2080.
    function _minePair(HookrPairRootFactory pf, IHookrPairRoot.Params memory p) internal view returns (bytes32 salt) {
        bytes32 initHash = pf.initCodeHash(p);
        for (uint256 i;; ++i) {
            bytes32 finalSalt = keccak256(abi.encode(address(this), bytes32(i)));
            if (uint160(vm.computeCreate2Address(finalSalt, initHash, address(pf))) & 0x3fff == 0x2080) {
                return salt = bytes32(i);
            }
        }
    }
}
