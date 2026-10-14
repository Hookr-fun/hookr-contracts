// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {IHookrPairAdvisory} from "../../src/interfaces/IHookrPairAdvisory.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrPairRoot} from "../../src/factory/HookrPairRoot.sol";
import {HookrRootFactory} from "../../src/factory/HookrRootFactory.sol";
import {IHookrRootFactory} from "../../src/interfaces/IHookrRootFactory.sol";
import {MockPairAdvisory, PairRootFixture} from "./PairRootFixture.sol";

/// @dev Accepts every binding and reverts every swap in the sell direction (one for zero).
contract SellRefusingAdvisory {
    function bindPair(PoolId, uint24, uint32, bytes calldata) external pure returns (bytes4) {
        return IHookrPairAdvisory.bindPair.selector;
    }

    function surchargeForSwap(PoolId, bool zeroForOne, int256, uint160, bytes calldata, address)
        external
        pure
        returns (uint24)
    {
        if (!zeroForOne) revert("no sells");
        return 0;
    }
}

/// @dev Accepts every binding and returns a surcharge its deployer sets at any time.
contract SwitchableAdvisory {
    address public immutable deployer;
    uint24 public surcharge;

    constructor(address deployer_) {
        deployer = deployer_;
    }

    function set(uint24 surcharge_) external {
        require(msg.sender == deployer);
        surcharge = surcharge_;
    }

    function bindPair(PoolId, uint24, uint32, bytes calldata) external pure returns (bytes4) {
        return IHookrPairAdvisory.bindPair.selector;
    }

    function surchargeForSwap(PoolId, bool, int256, uint160, bytes calldata, address) external view returns (uint24) {
        return surcharge;
    }
}

/// @notice A pair root's advisory sees the swap direction and sender and can revert the swap or set the surcharge up
///         to the root's cap, and anyone can deploy a pair root that the registry lists as a Hookr root. The factory
///         therefore deploys a root with an advisory only when the registry admits that advisory for the factory
///         through the ADMIT timelock, pinned to its codehash, cap and gas; a brake revokes an admission for new
///         roots at once without touching deployed ones.
///         Audit finding PR-01.
contract HookrPairRootHoneypotTest is PairRootFixture {
    address internal attacker = address(0xBAD);
    address internal guardianAccount = address(0x6A7D);

    function setUp() public {
        _setUpFactory();
        vm.deal(attacker, 1_000 ether);
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardianAccount));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardianAccount);
    }

    function _salt(IHookrPairRoot.Params memory p) internal view returns (bytes32) {
        return _mine(attacker, p);
    }

    function _attackerDeploys(IHookrPairRoot.Params memory p) internal returns (address root) {
        bytes32 salt = _salt(p);
        vm.prank(attacker);
        (root,) = factory.deploy(salt, p, SQRT_ONE, "");
    }

    function _expectRefused(IHookrPairRoot.Params memory p, bytes memory reason) internal {
        bytes32 salt = _salt(p);
        address predicted = factory.computeAddress(attacker, salt, p);
        vm.prank(attacker);
        vm.expectRevert(reason);
        factory.deploy(salt, p, SQRT_ONE, "");
        assertFalse(registry.isRoot(predicted));
        assertEq(predicted.code.length, 0);
    }

    function _one(address implementation) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = implementation;
    }

    function _notAdmitted(address module) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHookrRootFactory.AdvisoryNotAdmitted.selector, module);
    }

    function _pair(address module, uint24 base, uint24 cap, uint32 gasLimit)
        internal
        view
        returns (IHookrPairRoot.Params memory p)
    {
        (Currency c0, Currency c1) = _eth();
        p = _plain(c0, c1, base);
        p.maxLpFeePips = base + cap;
        p.advisory = module;
        p.advisoryCapPips = cap;
        p.advisoryGasLimit = gasLimit;
    }

    function _admission(address module, uint24 cap, uint32 gasLimit)
        internal
        view
        returns (IHookrRegistry.Admission memory a)
    {
        a = _pairAdmission(module);
        a.caps.maxLpFeePips = cap;
        a.gasLimit = gasLimit;
    }

    function _admit(IHookrRegistry.Admission memory a) internal {
        registry.queue(registry.ADMIT(), abi.encode(address(factory), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(factory), a);
    }

    // ------------------------------------------------------------------------------------------------------------
    // The honeypots are refused
    // ------------------------------------------------------------------------------------------------------------

    /// A fail-closed advisory that reverts sells would list a buy-only pool as a Hookr root. It is not admitted, so
    /// the factory refuses it before anything is deployed or registered.
    function test_sellRefusingAdvisoryRefused() public {
        address module = address(new SellRefusingAdvisory());
        _expectRefused(_pair(module, 3_000, 1, 50_000), _notAdmitted(module));
    }

    /// An advisory the deployer controls could switch the surcharge to the full 600,000-pip ceiling after buyers
    /// enter. It is not admitted, so the factory refuses it.
    function test_deployerSwitchableSurchargeRefused() public {
        address module = address(new SwitchableAdvisory(attacker));
        _expectRefused(_pair(module, 3_000, 600_000 - 3_000, 50_000), _notAdmitted(module));
    }

    /// Fixed-fee pair roots stay permissionless.
    function test_plainRootNeedsNoAdmission() public {
        (Currency c0, Currency c1) = _eth();
        address root = _attackerDeploys(_plain(c0, c1, 3_000));
        assertTrue(registry.isRoot(root));
        assertEq(registry.rootFactoryOf(root), address(factory));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Admission
    // ------------------------------------------------------------------------------------------------------------

    /// An advisory admitted for the factory is accepted from any deployer, up to the admitted cap and gas.
    function test_admittedAdvisoryAccepted() public {
        MockPairAdvisory module = new MockPairAdvisory();
        module.set(0, 700);
        _admit(_admission(address(module), 1_000, 60_000));
        _expectRefused(_pair(address(module), 3_000, 1_001, 60_000), _notAdmitted(address(module)));
        _expectRefused(_pair(address(module), 3_000, 1_000, 60_001), _notAdmitted(address(module)));

        address root = _attackerDeploys(_pair(address(module), 3_000, 1_000, 60_000));
        assertTrue(registry.isRoot(root));
        PoolKey memory key = HookrPairRoot(root).poolKey();
        _fund(key);
        assertEq(_swapFee(key, true, -1 ether, ""), 3_700);
        assertEq(_swapFee(key, false, -1 ether, ""), 3_700);
    }

    /// The admission pins the advisory's runtime codehash; code at the address that differs from it is refused.
    function test_codeHashMismatchRefused() public {
        MockPairAdvisory module = new MockPairAdvisory();
        _admit(_admission(address(module), 1_000, 60_000));
        vm.etch(address(module), address(new SwitchableAdvisory(attacker)).code);
        _expectRefused(
            _pair(address(module), 3_000, 1_000, 60_000),
            abi.encodeWithSelector(IHookrRootFactory.AdvisoryCodeHashMismatch.selector, address(module))
        );
    }

    /// Only an ADVISORY admission counts, and an admission for another scope does not.
    function test_admissionScope() public {
        MockPairAdvisory module = new MockPairAdvisory();
        IHookrRegistry.Admission memory a = _admission(address(module), 1_000, 60_000);
        a.kind = IHookrRegistry.Kind.RULES;
        bytes32 kind = registry.ADMIT();
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.queue(kind, abi.encode(address(factory), a));

        // An inactive factory, or an address that is neither an active root nor an active factory, has no scope.
        a.kind = IHookrRegistry.Kind.ADVISORY;
        HookrRootFactory idle = new HookrRootFactory(manager, factory.registry());
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(kind, abi.encode(address(idle), a));

        // Admitted for a pair root's own scope, it is still not admitted for the factory.
        (Currency c0, Currency c1) = _eth();
        address plain = _attackerDeploys(_plain(c0, c1, 3_000));
        registry.queue(kind, abi.encode(plain, a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(plain, a);
        IHookrPairRoot.Params memory p = _pair(address(module), 3_000, 1_000, 60_000);
        p.currency1 = Currency.wrap(address(tokenB));
        _expectRefused(p, _notAdmitted(address(module)));
    }

    /// Only the timelock admits: an attacker cannot queue or execute.
    function test_admissionIsTimelocked() public {
        IHookrRegistry.Admission memory a = _admission(address(new SellRefusingAdvisory()), 1, 50_000);
        bytes32 kind = registry.ADMIT();
        vm.prank(attacker);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.queue(kind, abi.encode(address(factory), a));
        bytes32 op = registry.queue(kind, abi.encode(address(factory), a));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.admit(address(factory), a);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Revocation
    // ------------------------------------------------------------------------------------------------------------

    /// A revoked admission stops new roots at once; roots already deployed keep trading at the same fee.
    function test_revokedAdmissionDoesNotBrickExistingPools() public {
        MockPairAdvisory module = new MockPairAdvisory();
        module.set(0, 700);
        _admit(_admission(address(module), 1_000, 60_000));
        IHookrPairRoot.Params memory p = _pair(address(module), 3_000, 1_000, 60_000);
        address root = _attackerDeploys(p);
        PoolKey memory key = HookrPairRoot(root).poolKey();
        _fund(key);
        assertEq(_swapFee(key, true, -1 ether, ""), 3_700);

        vm.prank(attacker);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.revokeFactoryAdmissions(address(factory), _one(address(module)));
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrRegistry.AdmissionRevoked(address(factory), address(module), guardianAccount);
        vm.prank(guardianAccount);
        registry.revokeFactoryAdmissions(address(factory), _one(address(module)));
        assertTrue(registry.isRevokedAdmission(address(factory), address(module)));
        assertEq(registry.admission(address(factory), address(module)).implementation, address(0));

        assertEq(_swapFee(key, true, -1 ether, ""), 3_700);
        assertEq(_swapFee(key, false, -1 ether, ""), 3_700);
        assertTrue(registry.isRoot(root));
        assertTrue(registry.rootOpen(root));

        p.currency1 = Currency.wrap(address(tokenB));
        _expectRefused(p, _notAdmitted(address(module)));
    }

    /// No admission queued before the brake, or after it, readmits the same address for the factory.
    function test_revocationCannotBeLiftedByAQueuedAdmission() public {
        MockPairAdvisory module = new MockPairAdvisory();
        IHookrRegistry.Admission memory first = _admission(address(module), 1_000, 60_000);
        IHookrRegistry.Admission memory second = _admission(address(module), 2_000, 60_000);
        bytes32 kind = registry.ADMIT();
        registry.queue(kind, abi.encode(address(factory), first));
        registry.queue(kind, abi.encode(address(factory), second));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(factory), first);
        vm.prank(guardianAccount);
        registry.revokeFactoryAdmissions(address(factory), _one(address(module)));

        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.admit(address(factory), second);
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.queue(kind, abi.encode(address(factory), first));
    }

    /// `revokeFactoryAdmissions` reaches only live factory-scope admissions; a root's are revoked one at a time with
    /// `revokeModuleAdmission`.
    function test_revokeScope() public {
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.revokeFactoryAdmissions(address(factory), _one(address(0x1234)));

        (Currency c0, Currency c1) = _eth();
        address plain = _attackerDeploys(_plain(c0, c1, 3_000));
        IHookrRegistry.Admission memory a = _admission(address(advisory), 1_000, 60_000);
        registry.queue(registry.ADMIT(), abi.encode(plain, a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(plain, a);
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.revokeFactoryAdmissions(plain, _one(address(advisory)));
        assertEq(registry.admission(plain, address(advisory)).implementation, address(advisory));

        // A deactivated factory's admission can still be revoked.
        vm.prank(guardianAccount);
        registry.deactivateRootFactory(address(factory));
        vm.prank(guardianAccount);
        registry.revokeFactoryAdmissions(address(factory), _one(address(advisory)));
        assertTrue(registry.isRevokedAdmission(address(factory), address(advisory)));
    }

    /// The per-module brake covers factory scopes too: `revokeModuleAdmission(factory, advisory)` withdraws one pair
    /// advisory as `revokeFactoryAdmissions` does. A pair root's own admission of the same address is a root scope,
    /// untouched by the factory brake and revoked on its own.
    function test_moduleRevokeCoversFactoryAndPairRootScopes() public {
        MockPairAdvisory module = new MockPairAdvisory();
        module.set(0, 700);
        IHookrRegistry.Admission memory a = _admission(address(module), 1_000, 60_000);
        IHookrRegistry.Admission memory later = _admission(address(module), 2_000, 60_000);
        registry.queue(registry.ADMIT(), abi.encode(address(factory), later));
        _admit(a);
        IHookrPairRoot.Params memory p = _pair(address(module), 3_000, 1_000, 60_000);
        address deployed = _attackerDeploys(p);
        PoolKey memory key = HookrPairRoot(deployed).poolKey();
        _fund(key);
        (, bool verified) = registry.rootStatus(deployed);
        assertTrue(verified);

        (Currency c0, Currency c1) = _eth();
        address plain = _attackerDeploys(_plain(c0, c1, 3_000));
        registry.queue(registry.ADMIT(), abi.encode(plain, a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(plain, a);

        vm.prank(attacker);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.revokeModuleAdmission(address(factory), address(module));
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrRegistry.AdmissionRevoked(address(factory), address(module), guardianAccount);
        vm.prank(guardianAccount);
        registry.revokeModuleAdmission(address(factory), address(module));

        assertTrue(registry.isRevokedAdmission(address(factory), address(module)));
        assertEq(registry.admission(address(factory), address(module)).implementation, address(0));
        (, verified) = registry.rootStatus(deployed);
        assertFalse(verified);
        assertEq(_swapFee(key, true, -1 ether, ""), 3_700);
        assertEq(_swapFee(key, false, -1 ether, ""), 3_700);
        p.currency1 = Currency.wrap(address(tokenB));
        _expectRefused(p, _notAdmitted(address(module)));
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.admit(address(factory), later);

        assertEq(registry.admission(plain, address(module)).implementation, address(module));
        assertFalse(registry.isRevokedAdmission(plain, address(module)));
        vm.prank(guardianAccount);
        registry.revokeModuleAdmission(plain, address(module));
        assertTrue(registry.isRevokedAdmission(plain, address(module)));
        bytes32 kind = registry.ADMIT();
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.queue(kind, abi.encode(plain, a));
    }

    /// One brake call revokes several admissions, all or none.
    function test_revokeBatchIsAtomic() public {
        MockPairAdvisory second = new MockPairAdvisory();
        _admit(_admission(address(second), 1_000, 60_000));
        address[] memory list = new address[](3);
        list[0] = address(advisory);
        list[1] = address(second);
        list[2] = address(0x1234);
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.revokeFactoryAdmissions(address(factory), list);
        assertFalse(registry.isRevokedAdmission(address(factory), address(advisory)));
        assertEq(registry.admission(address(factory), address(second)).implementation, address(second));

        address[] memory both = new address[](2);
        both[0] = address(advisory);
        both[1] = address(second);
        vm.prank(guardianAccount);
        registry.revokeFactoryAdmissions(address(factory), both);
        assertTrue(registry.isRevokedAdmission(address(factory), address(advisory)));
        assertTrue(registry.isRevokedAdmission(address(factory), address(second)));
        assertEq(registry.admission(address(factory), address(second)).implementation, address(0));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Root status
    // ------------------------------------------------------------------------------------------------------------

    /// The registry records each factory root's advisory; a root is verified while that advisory stays admitted
    /// for the factory with its pinned codehash, and a root without an advisory is always verified.
    function test_rootStatusTracksTheAdmission() public {
        (Currency c0, Currency c1) = _eth();
        address plain = _attackerDeploys(_plain(c0, c1, 3_000));
        (address recorded, bool verified) = registry.rootStatus(plain);
        assertEq(recorded, address(0));
        assertTrue(verified);
        (recorded, verified) = registry.rootStatus(address(0xDEAD));
        assertEq(recorded, address(0));
        assertFalse(verified);

        MockPairAdvisory module = new MockPairAdvisory();
        _admit(_admission(address(module), 1_000, 60_000));
        IHookrPairRoot.Params memory p = _pair(address(module), 3_000, 1_000, 60_000);
        p.currency1 = Currency.wrap(address(tokenB));
        address advised = _attackerDeploys(p);
        (recorded, verified) = registry.rootStatus(advised);
        assertEq(recorded, address(module));
        assertTrue(verified);

        vm.prank(guardianAccount);
        registry.revokeFactoryAdmissions(address(factory), _one(address(module)));
        (recorded, verified) = registry.rootStatus(advised);
        assertEq(recorded, address(module));
        assertFalse(verified);
        assertTrue(registry.isRoot(advised));
    }

    /// Code at the advisory's address that no longer matches the admitted codehash unverifies the root.
    function test_rootStatusFollowsTheCodeHash() public {
        MockPairAdvisory module = new MockPairAdvisory();
        _admit(_admission(address(module), 1_000, 60_000));
        address advised = _attackerDeploys(_pair(address(module), 3_000, 1_000, 60_000));
        (, bool verified) = registry.rootStatus(advised);
        assertTrue(verified);
        vm.etch(address(module), address(new SwitchableAdvisory(attacker)).code);
        (, verified) = registry.rootStatus(advised);
        assertFalse(verified);
    }
}
