// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrOwnedRoots} from "../../src/interfaces/IHookrOwnedRoots.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice The owned-roots walkthrough, steps 3 to 5 (steps 1 and 2 are in OwnedProfiles.t.sol): a brand deploys its
///         own root from reviewed code at the address it mined, registered and frozen in the same transaction, wired
///         to Hookr's registry, Rules and treasury, and its pools keep Hookr's launcher, router, quoter and analytics.
contract OwnedRootsWalkthroughTest is OwnedRootsFixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _setUpOwned();
    }

    function launchExternalAs(address caller, address rootAddr, IHookrLauncher.Member memory m)
        external
        returns (bytes32 family, PoolKey memory key, address subject)
    {
        return _launchAs(caller, rootAddr, m);
    }

    /// @notice Step 3. The brand deploys its root from reviewed code at the address it mined, paying the fee; the
    ///         registry registers it frozen with its companion in the same transaction.
    function test_step3_brandDeploysItsRootFromReviewedCode() public {
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        bytes32 salt = _mine(brand);
        address predicted = factory.computeAddress(brand, salt);
        assertEq(uint160(predicted) & Hooks.ALL_HOOK_MASK, CLASS);
        assertEq(predicted.code.length, 0);

        bytes memory args = abi.encode(manager, address(registry), address(router), address(quoter), address(0));
        uint256 fee = _fee(factory);
        // The registry registers the root inside the deployment, before the factory's own events.
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrOwnedRoots.OwnedRootRegistered(
            predicted, address(factory), address(root), _companionAddress(predicted, salt)
        );
        vm.expectEmit(true, true, true, true, address(factory));
        emit IHookrOwnedRootFactory.Deployed(
            predicted, keccak256(type(HookrRoot).creationCode), brand, args, keccak256(abi.encode(brand, salt))
        );
        vm.prank(brand);
        address owned = _deployCall(factory, fee, sel, salt);

        assertEq(owned, predicted);
        assertTrue(factory.isFromFactory(owned));
        assertEq(factory.allDeploymentsLength(), 1);
        assertTrue(factory.saltUsed(brand, salt));
        assertTrue(registry.isRoot(owned));
        assertTrue(IHookrOwnedRoots(address(registry)).isOwnedRoot(owned));
        assertTrue(registry.rootFrozen(owned));
        IHookrOwnedRootFactory.OwnedRoot memory o = factory.ownedRoot(owned);
        assertEq(o.rules, factory.rulesOf(owned));
        assertEq(o.owner, brand);
        assertEq(o.profileVersion, 1);
        assertEq(o.ruleMask, F.ALL_FEATURES);
        IHookrRegistry.Admission memory a = registry.admission(owned, o.rules);
        assertEq(uint8(a.kind), uint8(IHookrRegistry.Kind.RULES));
        assertEq(a.codeHash, o.rules.codehash);
        assertEq(a.caps.maxLpFeePips, 600_000);
        assertEq(a.gasLimit, 2_000_000);
        assertEq(registry.admission(owned, address(sharedRules)).implementation, address(0));
    }

    /// @notice Step 4. Every root is wired to Hookr's registry, Rules and treasury.
    function test_step4_everyRootWiredToHookrRegistryRulesAndTreasury() public {
        (HookrRoot owned, HookrRules companion) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        assertTrue(factory.runtimeMatchesTemplate(address(owned)), "the template's build and wiring");
        assertEq(address(owned.registry()), address(registry));
        assertEq(address(owned.poolManager()), address(manager));
        assertEq(owned.router(), address(router));
        assertEq(owned.quoter(), address(quoter));
        assertEq(owned.curatedRouter(), address(0));
        assertEq(uint160(address(owned)) & Hooks.ALL_HOOK_MASK, owned.PERMISSION_FLAGS());
        assertEq(companion.trustedRoot(), address(owned));
        assertEq(address(companion.registry()), address(registry));
        assertEq(companion.protocolRecipient(), address(hookrTreasury));
        assertEq(companion.protocolRecipient(), factory.treasury());
        assertEq(companion.protocolRecipient(), sharedRules.protocolRecipient());
        assertEq(companion.configSchemaHash(), sharedRules.configSchemaHash());
        assertEq(factory.rulesCreationCodeHash(), keccak256(type(HookrRules).creationCode));
        assertEq(factory.rootCreationCodeHash(), keccak256(type(HookrRoot).creationCode));
    }

    /// @notice Step 5. Pools keep Hookr's launcher, router, quoter and analytics, and pay Hookr's treasury.
    function test_step5_poolsKeepLauncherRouterQuoterAndAnalytics() public {
        (HookrRoot owned, HookrRules companion) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        assertTrue(registry.rootOpen(address(owned)));
        IHookrLauncher.Member memory m = _nativeMember(address(companion), _rc(), bytes32("brand-pool"));
        (bytes32 family, PoolKey memory key, address subject) = _launchAs(stranger, address(owned), m);
        PoolId pid = key.toId();
        assertEq(address(key.hooks), address(owned));
        assertTrue(owned.knownPool(pid));
        assertEq(launcher.familyOwner(family), stranger);
        assertTrue(factory.ownedRootConforms(address(owned), pid));

        IHookrRouter.Swap memory p = _swapParams(key, true, true, 2 ether);
        HookrTypes.ExecutionReceipt memory q = quoter.quote(p, trader);
        (uint256 inBuy, uint256 outBuy) = _trade(key, true, true, 2 ether);
        assertEq(inBuy, q.inputAmount);
        assertEq(outBuy, q.outputAmount);
        (uint256 inSell, uint256 outSell) = _trade(key, false, true, uint128(outBuy / 2));
        assertEq(inSell, outBuy / 2);
        assertGt(outSell, 0);

        uint256 protocolClaim = companion.claimable(ETH, address(hookrTreasury));
        assertGt(protocolClaim, 0);
        assertGt(companion.claimable(ETH, royalty), 0);
        assertGt(HookrToken(subject).balanceOf(address(0xdead)), 0);
        assertTrue(companion.accountingInvariant(ETH));
        uint256 before = TARGET.balance;
        assertEq(_collect(address(companion)), protocolClaim);
        assertEq(TARGET.balance, before + protocolClaim);
        assertEq(sharedRules.claimable(ETH, address(hookrTreasury)), 0, "the shared ledger is untouched");

        uint256 lpBefore = stranger.balance;
        vm.prank(stranger);
        launcher.withdraw(family, 0, 0, 0, 0, stranger, vm.getBlockTimestamp());
        assertGt(stranger.balance, lpBefore);
    }

    /// @notice The walkthrough in one pass: a brand profile on the shared root, an owner-only root derived from it
    ///         with Auto Burn off, a conforming pool by its owner, a stranger refused by the registry and the factory,
    ///         trades and claims, the owner's pause, and the registry's brake closing the root to new pools while its
    ///         pool keeps trading.
    function test_walkthroughEndToEnd() public {
        IHookrOwnedProfiles.Profile memory p = _profile(F.SOFT_FEATURES | F.AUTO_BURN, false, brand);
        p.caps = HookrTypes.Caps(100_000, 100_000, 500);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("brand"), p);
        (HookrRoot owned, HookrRules companion) = _deployOwned(_selFor(id, brand, F.SOFT_FEATURES, false));
        IHookrRegistry.Admission memory a = registry.admission(address(owned), address(companion));
        assertEq(a.caps.maxLpFeePips, 100_000);
        assertEq(a.caps.maxSubjectTakeBps, 0, "Auto Burn off is enforced by the admission's cap");
        IHookrOwnedRoots o = IHookrOwnedRoots(address(registry));
        assertFalse(o.rootOpenFor(address(owned), stranger), "owner-only: the registry refuses a stranger");
        assertFalse(factory.mayOpen(address(owned), stranger), "and so does the factory");
        assertTrue(o.rootOpenFor(address(owned), brand));
        // The owner's own burning pool is refused when the Rules bind it: the root's subject cap is zero.
        IHookrLauncher.Member memory burning = _nativeMember(address(companion), _rc(), id);
        vm.expectRevert(_bindRefusal(address(companion)));
        this.launchExternalAs(brand, address(owned), burning);
        HookrTypes.RulesConfig memory c = _rc();
        c.burnBps = 0;
        (, PoolKey memory key,) = _launchAs(brand, address(owned), _nativeMember(address(companion), c, id));
        assertTrue(factory.ownedRootConforms(address(owned), key.toId()));
        _trade(key, true, true, 3 ether);
        assertGt(companion.claimable(ETH, address(hookrTreasury)), 0);
        assertTrue(companion.accountingInvariant(ETH));
        vm.prank(brand);
        factory.setPaused(address(owned), true);
        assertFalse(o.rootOpenFor(address(owned), brand), "paused by its owner");
        registry.closeRoot(address(owned));
        assertFalse(registry.rootOpen(address(owned)));
        IHookrLauncher.Member memory again = _nativeMember(address(companion), c, id);
        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        this.launchExternalAs(brand, address(owned), again);
        (, uint256 out) = _trade(key, true, true, 1 ether);
        assertGt(out, 0);
    }

    /// @dev The companion's CREATE2 address: the factory with the root's address as salt.
    function _companionAddress(address ownedRoot, bytes32) internal view returns (address) {
        bytes memory init = bytes.concat(
            type(HookrRules).creationCode,
            abi.encode(manager, registry, address(hookrTreasury), ownedRoot, sharedRules.minProtocolShareBps())
        );
        return vm.computeCreate2Address(bytes32(uint256(uint160(ownedRoot))), keccak256(init), address(factory));
    }
}
