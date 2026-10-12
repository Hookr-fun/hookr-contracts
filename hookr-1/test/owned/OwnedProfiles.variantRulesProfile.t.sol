// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {IHookrOwnedRootsLens} from "../../src/interfaces/IHookrOwnedRootsLens.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice Stand-in for a HookrRules variant the release admits on the shared root beside the template Rules
///         (HookrRulesRoundTrip of the Buy/Sell Block lab, HookrObservedRules of the Oracle Recorder lab): the same
///         RulesConfig schema, the same treasury and protocol-share floor, plus a feature of its own.
contract VariantRules is HookrRules {
    constructor(IPoolManager m, IHookrRegistry r, address treasury_, address root_, uint16 floorBps)
        HookrRules(m, r, treasury_, root_, floorBps)
    {}

    /// @notice The variant's own surface, after HookrRulesRoundTrip.recordsRoundTrips(id).
    function recordsRoundTrips(PoolId) external pure returns (bool) {
        return true;
    }
}

/// @notice OR-1: HookrOwnedRootFactory takes the profile's Rules module only as the source of the companion's admission
///         terms and always deploys plain HookrRules from the pinned creation code. A profile naming a HookrRules
///         variant admitted on the shared root, valid for tier 1, yielded an owned root whose companion was plain
///         HookrRules under the variant's terms: the deploy took the fee and a slot, the lens reported it deployable,
///         and the frozen root could never offer the variant. The factory now pins the template Rules (the template's
///         HookrRules paying the treasury) and refuses a profile naming any other with InvalidTemplate, and the lens
///         reports such a profile not deployable.
contract OwnedProfilesVariantRulesProfileTest is OwnedRootsFixture {
    using PoolIdLibrary for PoolKey;

    VariantRules internal variant;
    bytes32 internal variantProfile;

    function setUp() public {
        _setUpOwned();
        // Governance admits the variant on the shared root with the template Rules' terms (timelocked ADMIT).
        variant = new VariantRules(manager, registry, address(hookrTreasury), address(root), PROTOCOL_FLOOR);
        _admit(address(root), _rulesAdmission(address(variant)));
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        p.rules = address(variant);
        vm.prank(brand);
        variantProfile = book.writeProfile(bytes32("variant"), p);
    }

    /// The PoC: tier 1 still works with the variant, but no root can be derived from its profile: the lens says so,
    /// the deploy reverts, and neither the fee nor a slot is taken.
    function test_aProfileNamingAVariantRulesDerivesNoRoot() public {
        assertEq(factory.templateRules(), address(sharedRules), "the factory pins the template Rules");
        (, PoolKey memory tier1,) =
            _launchAs(stranger, address(root), _nativeMember(address(variant), _rc(), variantProfile));
        assertTrue(book.profileConforms(variantProfile, tier1.toId()), "tier-1 pool binds the profile's Rules");

        IHookrOwnedRootsLens.SelectionBounds memory b = lens.selectionBounds(factory, variantProfile, brand);
        assertFalse(b.deployable, "lens: not deployable");

        IHookrOwnedRootFactory.RootSelections memory sel = _selFor(variantProfile, brand, F.ALL_FEATURES, true);
        bytes32 salt = _mine(brand);
        uint256 fee = _fee(factory);
        uint256 targetBefore = TARGET.balance;
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.InvalidTemplate.selector, address(root)));
        _deployCall(factory, fee, sel, salt);
        assertEq(TARGET.balance, targetBefore, "no fee taken");
        assertEq(factory.allDeploymentsLength(), 0, "no slot taken");
    }

    /// The template Rules' own profile still derives a root whose companion carries its terms.
    function test_theTemplateRulesProfileStillDerivesARoot() public {
        IHookrOwnedRootsLens.SelectionBounds memory b = lens.selectionBounds(factory, templateProfile, address(this));
        assertTrue(b.deployable, "lens: deployable");
        (HookrRoot owned, HookrRules companion) =
            _deployOwned(_selFor(templateProfile, address(this), F.ALL_FEATURES, true));
        IHookrRegistry.Admission memory a = registry.admission(address(owned), address(companion));
        IHookrRegistry.Admission memory t = registry.admission(address(root), address(sharedRules));
        assertEq(a.schemaHash, t.schemaHash);
        assertEq(a.gasLimit, t.gasLimit);
        assertEq(factory.rulesOf(address(owned)), address(companion));
    }
}
