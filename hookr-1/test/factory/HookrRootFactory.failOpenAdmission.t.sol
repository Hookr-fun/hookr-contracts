// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {IHookrFactoryRegistry, IHookrRootFactory} from "../../src/interfaces/IHookrRootFactory.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrPairRoot} from "../../src/factory/HookrPairRoot.sol";
import {HookrRootFactory} from "../../src/factory/HookrRootFactory.sol";
import {mineSalt} from "../../script/HookrPairRootSalt.s.sol";
import {MockPairAdvisory, PairRootFixture} from "./PairRootFixture.sol";

/// @dev A factory registry that reports whatever admission it is given and records every registration. It stands in
///      for a registry whose admission rules differ from HookrRegistry's, so the factory's own check is what decides.
contract StubFactoryRegistry is IHookrFactoryRegistry {
    IHookrRegistry.Admission internal stored;
    uint256 public registrations;

    function setAdmission(IHookrRegistry.Admission memory a) external {
        stored = a;
    }

    function admission(address, address) external view returns (IHookrRegistry.Admission memory) {
        return stored;
    }

    function isRootFactory(address) external pure returns (bool) {
        return true;
    }

    function registerFactoryRoot(address, address) external {
        ++registrations;
    }
}

/// @notice A pair root with `advisoryFailOpen` charges its full advisory cap whenever the advisory fails, so the
///         advisory must be admitted as fail-open capable and fee-only with no quote take, exactly as HookrRoot
///         requires when it binds a fail-open advisory. The factory checks the admission's `failOpen`, `feeOnly` and
///         quote take cap before it deploys anything; a fail-closed root is accepted under any admission.
///         Audit finding PR-02.
contract HookrRootFactoryFailOpenAdmissionTest is PairRootFixture {
    function setUp() public {
        _setUpFactory();
    }

    function _failClosedAdmission(address module) internal view returns (IHookrRegistry.Admission memory a) {
        a = _pairAdmission(module);
        a.failOpen = false;
    }

    function _admit(IHookrRegistry.Admission memory a) internal {
        uint256 t = vm.getBlockTimestamp();
        registry.queue(registry.ADMIT(), abi.encode(address(factory), a));
        vm.warp(t + registry.delay());
        registry.admit(address(factory), a);
        vm.warp(t);
    }

    function _params(address module, bool failOpen) internal view returns (IHookrPairRoot.Params memory p) {
        (Currency c0, Currency c1) = _erc();
        p = _advised(c0, c1, 3_000, 2_000, failOpen);
        p.advisory = module;
    }

    function _deployRaw(HookrRootFactory f, IHookrPairRoot.Params memory p) internal returns (address root) {
        bytes32 salt = mineSalt(address(f), deployer, f.initCodeHash(p), 0);
        vm.prank(deployer);
        (root,) = f.deploy(salt, p, SQRT_ONE, "");
    }

    function _expectRefused(HookrRootFactory f, IHookrPairRoot.Params memory p) internal {
        bytes32 salt = mineSalt(address(f), deployer, f.initCodeHash(p), 0);
        address predicted = f.computeAddress(deployer, salt, p);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IHookrRootFactory.AdvisoryNotAdmitted.selector, p.advisory));
        f.deploy(salt, p, SQRT_ONE, "");
        assertEq(predicted.code.length, 0, "nothing deployed");
    }

    /// A fail-closed-only admission refuses a fail-open pair root. Without the check the factory deploys and registers
    /// a root that charges the full cap on every advisory failure, which the admission never allowed.
    function test_failOpenRootRefusedUnderFailClosedAdmission() public {
        MockPairAdvisory module = new MockPairAdvisory();
        _admit(_failClosedAdmission(address(module)));
        _expectRefused(factory, _params(address(module), true));
    }

    /// Control: the same fail-closed admission accepts a fail-closed root, and a fail-open admission accepts both.
    function test_matchingAdmissionsDeploy() public {
        MockPairAdvisory closedOnly = new MockPairAdvisory();
        _admit(_failClosedAdmission(address(closedOnly)));
        address root = _deployRaw(factory, _params(address(closedOnly), false));
        assertTrue(registry.isRoot(root));
        assertFalse(HookrPairRoot(root).params().advisoryFailOpen);

        MockPairAdvisory open = new MockPairAdvisory();
        _admit(_pairAdmission(address(open)));
        assertTrue(registry.admission(address(factory), address(open)).failOpen);
        root = _deployRaw(factory, _params(address(open), true));
        assertTrue(HookrPairRoot(root).params().advisoryFailOpen);
        (Currency c0, Currency c1) = _eth();
        IHookrPairRoot.Params memory p = _advised(c0, c1, 3_000, 2_000, false);
        p.advisory = address(open);
        assertTrue(registry.isRoot(_deployRaw(factory, p)));
    }

    /// HookrRegistry never admits a fail-open advisory that is not fee-only or carries a quote take, so these two
    /// refusals run against a registry that reports such admissions: the factory refuses them itself.
    function test_failOpenNeedsFeeOnlyAdmissionWithoutQuoteTake() public {
        StubFactoryRegistry stub = new StubFactoryRegistry();
        HookrRootFactory f = new HookrRootFactory(manager, stub);
        MockPairAdvisory module = new MockPairAdvisory();
        IHookrRegistry.Admission memory a = _pairAdmission(address(module));

        a.feeOnly = false;
        stub.setAdmission(a);
        _expectRefused(f, _params(address(module), true));

        a.feeOnly = true;
        a.caps.maxQuoteTakePips = 1;
        stub.setAdmission(a);
        _expectRefused(f, _params(address(module), true));

        a.failOpen = false;
        a.caps.maxQuoteTakePips = 0;
        stub.setAdmission(a);
        _expectRefused(f, _params(address(module), true));

        // Control: the fail-open, fee-only admission without a quote take deploys the fail-open root.
        a.failOpen = true;
        stub.setAdmission(a);
        _deployRaw(f, _params(address(module), true));
        assertEq(stub.registrations(), 1);
    }

    /// For every admission the stub can report, the factory deploys a root exactly when HookrRoot's bind rule accepts
    /// the pair: fail-closed always, fail-open only with a fail-open, fee-only admission without a quote take.
    function testFuzz_factoryMatchesRootFailOpenRule(
        bool rootFailOpen,
        bool admittedFailOpen,
        bool admittedFeeOnly,
        uint24 quoteTake
    ) public {
        StubFactoryRegistry stub = new StubFactoryRegistry();
        HookrRootFactory f = new HookrRootFactory(manager, stub);
        MockPairAdvisory module = new MockPairAdvisory();
        IHookrRegistry.Admission memory a = _pairAdmission(address(module));
        a.failOpen = admittedFailOpen;
        a.feeOnly = admittedFeeOnly;
        a.caps.maxQuoteTakePips = uint24(bound(quoteTake, 0, 2));
        stub.setAdmission(a);
        IHookrPairRoot.Params memory p = _params(address(module), rootFailOpen);
        bool accepted = !rootFailOpen || (admittedFailOpen && admittedFeeOnly && a.caps.maxQuoteTakePips == 0);
        if (accepted) {
            _deployRaw(f, p);
            assertEq(stub.registrations(), 1);
        } else {
            _expectRefused(f, p);
            assertEq(stub.registrations(), 0);
        }
    }

    /// The factory reads the registry's admission, not the root's own claim: a revoked fail-open admission refuses
    /// both kinds of root again.
    function test_revokedAdmissionRefusesBoth() public {
        address guardianAccount = address(0x6A7D);
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardianAccount));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardianAccount);
        MockPairAdvisory module = new MockPairAdvisory();
        _admit(_pairAdmission(address(module)));
        address[] memory list = new address[](1);
        list[0] = address(module);
        vm.prank(guardianAccount);
        registry.revokeFactoryAdmissions(address(factory), list);
        _expectRefused(factory, _params(address(module), true));
        _expectRefused(factory, _params(address(module), false));
    }
}
