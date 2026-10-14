// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {IHookrSessionAdvisory} from "../../src/interfaces/IHookrSessionAdvisory.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice Off-market fees on owned-root pools. A tier-1 pool binds the HookrSessionAdvisory the registry owner
///         admitted on the shared root and its profile lists. Decision 3: an owned root derived from that profile takes
///         the advisory's admission at registration, so its pools bind it too; a root derived from a profile that does
///         not list it binds none.
contract OwnedRootsOffMarketTest is OwnedRootsFixture {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant REGULAR = 1000;
    uint24 internal constant CLOSED = 20_000;
    /// @dev Wednesday 2026-11-25 11:00 New York (EST), a regular session.
    uint256 internal constant WEDNESDAY_REGULAR = 1_795_622_400;
    /// @dev Saturday 2026-11-28 10:00 New York (EST), closed.
    uint256 internal constant SATURDAY = 1_795_878_000;

    HookrSessionAdvisory internal session;
    bytes32 internal profileId;

    function setUp() public {
        _setUpOwned();
        session = new HookrSessionAdvisory(address(this), DELAY);
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(session),
            codeHash: address(session).codehash,
            schemaHash: session.configSchemaHash(),
            caps: HookrTypes.Caps(50_000, 0, 0),
            gasLimit: 150_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
        _admit(address(root), a);
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        p.advisories = new address[](1);
        p.advisories[0] = address(session);
        vm.prank(brand);
        profileId = book.writeProfile(bytes32("stocks"), p);
    }

    function launchAdvisedExternal(address rootAddr, address rulesAddr, bytes32 policyId)
        external
        returns (PoolKey memory)
    {
        return _launchSession(rootAddr, rulesAddr, policyId);
    }

    function _sessionMember(address rulesAddr, bytes32 policyId)
        internal
        view
        returns (IHookrLauncher.Member memory m)
    {
        m = _nativeMember(rulesAddr, _rc(), policyId);
        m.config.advisory = address(session);
        m.config.advisoryGasLimit = 150_000;
        m.config.advisoryPhases = HookrTypes.BEFORE_SWAP;
    }

    function _schedule() internal pure returns (bytes memory) {
        return abi.encode(IHookrSessionAdvisory.Schedule(REGULAR, 4000, 6000, 10_000, CLOSED, 0, 0, 0));
    }

    function _buyFee(PoolKey memory key) internal returns (uint256) {
        return quoter.quote(_swapParams(key, true, true, 1 ether), trader).lpFeePips;
    }

    function _launchSession(address rootAddr, address rulesAddr, bytes32 policyId) internal returns (PoolKey memory) {
        IHookrLauncher.Member memory m = _sessionMember(rulesAddr, policyId);
        bytes[] memory configs = new bytes[](1);
        configs[0] = _schedule();
        IHookrLauncher.Member[] memory ms = _members(m);
        IHookrLauncher.Token memory t = _newToken();
        vm.prank(stranger);
        (bytes32 family,) =
            launcher.launchAdvised{value: m.amount0Max}(t, rootAddr, ms, configs, vm.getBlockTimestamp());
        return launcher.position(family, 0).key;
    }

    function test_tier1ProfilePoolTakesTheSessionSurchargeOffMarket() public {
        PoolKey memory key = _launchSession(address(root), address(sharedRules), profileId);
        assertTrue(book.profileConforms(profileId, key.toId()));
        book.adoptPool(profileId, key.toId());
        vm.warp(WEDNESDAY_REGULAR);
        uint256 regular = _buyFee(key);
        vm.warp(SATURDAY);
        uint256 weekend = _buyFee(key);
        assertEq(weekend - regular, CLOSED - REGULAR, "the weekend surcharge replaces the regular one");
        (, uint256 out) = _trade(key, true, true, 1 ether);
        assertGt(out, 0);
    }

    /// @notice Decision 3: a root derived from the profile carries the session advisory, and its pools take the same
    ///         off-market surcharge as the shared root's.
    function test_ownedRootTakesTheProfilesSessionAdvisory() public {
        (HookrRoot owned, HookrRules companion) = _deployOwned(_selFor(profileId, brand, F.ALL_FEATURES, true));
        IHookrRegistry.Admission memory copied = registry.admission(address(owned), address(session));
        assertEq(copied.implementation, address(session));
        assertEq(copied.caps.maxLpFeePips, 50_000);
        PoolKey memory key = _launchSession(address(owned), address(companion), 0);
        assertTrue(factory.ownedRootConforms(address(owned), key.toId()), "a listed advisory conforms");
        vm.warp(WEDNESDAY_REGULAR);
        uint256 regular = _buyFee(key);
        vm.warp(SATURDAY);
        uint256 weekend = _buyFee(key);
        assertEq(weekend - regular, CLOSED - REGULAR);
        (, uint256 out) = _trade(key, true, true, 1 ether);
        assertGt(out, 0);
    }

    /// @notice A root derived from a profile that does not list the advisory binds none.
    function test_rootWithoutTheListingCannotBindTheAdvisory() public {
        (HookrRoot owned, HookrRules companion) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        assertEq(registry.admission(address(owned), address(session)).implementation, address(0));
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, address(session)));
        this.launchAdvisedExternal(address(owned), address(companion), 0);
    }

    /// @notice Measured locally: a 1 ETH router buy on a tier-1 profile pool with and without the session advisory.
    function test_measureSessionAdvisorySwapGas() public {
        PoolKey memory advised = _launchSession(address(root), address(sharedRules), profileId);
        (, PoolKey memory plain,) =
            _launchAs(stranger, address(root), _nativeMember(address(sharedRules), _rc(), profileId));
        vm.warp(SATURDAY);
        _trade(plain, true, true, 1 ether);
        _trade(advised, true, true, 1 ether);
        uint256 g = gasleft();
        _trade(plain, true, true, 1 ether);
        uint256 without = g - gasleft();
        g = gasleft();
        _trade(advised, true, true, 1 ether);
        uint256 with = g - gasleft();
        console2.log("router buy gas, profile pool without the session advisory", without);
        console2.log("router buy gas, profile pool with the session advisory", with);
        assertGt(with, without);
    }
}
