// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrFamilyRouter} from "../../src/periphery/HookrFamilyRouter.sol";
import {IHookrFamilyRouter} from "../../src/interfaces/IHookrFamilyRouter.sol";
import {IHookrLauncherView} from "../../src/interfaces/IHookrLauncherView.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {HookrOwnedRootsLens} from "../../src/lens/HookrOwnedRootsLens.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice OR-2: HookrFamilyRouter runs every leg of a family trade through HookrRouter.swapGated with itself as the
///         root's GATE, and an owned root takes only the gates its profile lists, frozen at registration. The lens's
///         complete defaults listed no gate, so every owned root deployed from them could never take a family trade
///         and no governance step could add the gate later. The lens now takes the release's family router and its
///         default profile lists it while it is a live GATE admission of the root, as the plan's decision 3 intends.
contract OwnedRootsLensDefaultFamilyGateTest is OwnedRootsFixture {
    HookrFamilyRouter internal fam;
    HookrOwnedRootsLens internal releaseLens;

    function setUp() public {
        _setUpOwned();
        // Any contract with code stands in for Permit2: these trades pay native ETH.
        fam = new HookrFamilyRouter(router, IHookrLauncherView(address(launcher)), address(manager));
        // The release's genesis governance: the family router's GATE admission on the shared root.
        _admit(address(root), _gateAdmission(address(fam)));
        releaseLens = new HookrOwnedRootsLens(address(fam));
    }

    /// @dev A one-leg family buy of `key` (native quote, so the subject is currency1) for 1 ETH.
    function _buy(PoolKey memory key, bytes32 family) internal view returns (IHookrFamilyRouter.FamilyTrade memory t) {
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
    }

    /// The PoC: an owned root deployed from the lens's complete defaults takes the release's family router, so a family
    /// trade runs on it as on the shared root.
    function test_ownedRootFromTheLensDefaultsTakesFamilyTrades() public {
        (bytes32 sharedFamily, PoolKey memory sharedKey,) =
            _launchAs(stranger, address(root), _nativeMember(address(sharedRules), _rc(), 0));
        vm.prank(trader);
        (, uint256 sharedOut) = fam.trade{value: 1 ether}(_buy(sharedKey, sharedFamily), "");
        assertGt(sharedOut, 0, "the shared root takes family trades");

        IHookrOwnedProfiles.Profile memory p =
            releaseLens.defaultProfile(book, address(root), address(sharedRules), brand);
        assertEq(p.gates.length, 1, "the default profile lists one gate");
        assertEq(p.gates[0], address(fam), "the release's family router");
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("lens-default"), p);
        IHookrOwnedRootFactory.RootSelections memory sel = releaseLens.defaultSelections(factory, id, brand);
        assertTrue(releaseLens.selectionBounds(factory, id, brand).deployable, "lens: deployable");
        (HookrRoot owned, HookrRules companion) = _deployOwned(sel);
        assertEq(registry.admission(address(owned), address(fam)).implementation, address(fam), "the gate is copied");

        (bytes32 family, PoolKey memory key,) =
            _launchAs(brand, address(owned), _nativeMember(address(companion), _rc(), 0));
        vm.prank(trader);
        (, uint256 out) = fam.trade{value: 1 ether}(_buy(key, family), "");
        assertGt(out, 0, "the owned root takes family trades");
    }

    /// The default lists the family router only while it is a live GATE admission of the root, so the book always takes
    /// the default as is: a lens without one, or with one the root never admitted or revoked, lists no gate.
    function test_defaultListsTheFamilyRouterOnlyWhileTheRootAdmitsIt() public {
        HookrOwnedRootsLens none = new HookrOwnedRootsLens(address(0));
        assertEq(none.defaultProfile(book, address(root), address(sharedRules), brand).gates.length, 0);

        HookrFamilyRouter unadmitted =
            new HookrFamilyRouter(router, IHookrLauncherView(address(launcher)), address(manager));
        HookrOwnedRootsLens other = new HookrOwnedRootsLens(address(unadmitted));
        assertEq(other.familyRouter(), address(unadmitted));
        IHookrOwnedProfiles.Profile memory p = other.defaultProfile(book, address(root), address(sharedRules), brand);
        assertEq(p.gates.length, 0);
        vm.prank(brand);
        book.writeProfile(bytes32("no-gate"), p);

        registry.revokeModuleAdmission(address(root), address(fam));
        p = releaseLens.defaultProfile(book, address(root), address(sharedRules), brand);
        assertEq(p.gates.length, 0, "a revoked gate is no longer listed");
        vm.prank(brand);
        book.writeProfile(bytes32("after-revoke"), p);
    }
}
