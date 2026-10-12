// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {CREATE3} from "solmate/src/utils/CREATE3.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice Deploys through solmate's CREATE3 exactly as the owned-root factory does.
contract OwnedCreate3Harness {
    function deploy(bytes32 salt, bytes memory initCode) external returns (address) {
        return CREATE3.deploy(salt, initCode, 0);
    }

    function predict(bytes32 salt) external view returns (address) {
        return CREATE3.getDeployed(salt);
    }
}

/// @notice A contract whose code depends on its constructor argument.
contract OwnedEcho {
    uint256 public immutable value;

    constructor(uint256 v) {
        value = v;
    }
}

/// @notice A constructor that always reverts.
contract OwnedReverter {
    constructor() {
        revert("no");
    }
}

/// @notice solmate's CREATE3, the library the owned-root factory deploys roots with (the lab's own LibCreate3 is not
///         used): the address depends on the deploying contract and the salt only, never on the creation code; a salt
///         deploys once; a reverting constructor leaves nothing behind. The factory's address is the solmate address of
///         the salt namespaced by the deployer, and both creation codes it deploys stay inside EIP-3860's initcode
///         limit with their constructor arguments.
contract OwnedRootsCreate3Test is OwnedRootsFixture {
    OwnedCreate3Harness internal h;

    function setUp() public {
        _setUpOwned();
        h = new OwnedCreate3Harness();
    }

    /// @notice The address is predicted before anything is deployed and does not depend on the creation code: the
    ///         same salt yields the same address whatever code it deploys.
    function testFuzz_predictMatchesDeployAndIgnoresTheCreationCode(bytes32 salt, uint256 v) public {
        address predicted = h.predict(salt);
        assertEq(predicted.code.length, 0);
        uint256 snapshot = vm.snapshotState();
        address echo = h.deploy(salt, abi.encodePacked(type(OwnedEcho).creationCode, abi.encode(v)));
        assertEq(echo, predicted);
        assertEq(OwnedEcho(echo).value(), v);
        vm.revertToState(snapshot);
        address other = h.deploy(salt, type(OwnedCreate3Harness).creationCode);
        assertEq(other, predicted, "other code, same address");
        assertEq(CREATE3.getDeployed(salt, address(h)), predicted);
    }

    /// @notice The address depends on the deploying contract.
    function testFuzz_predictDependsOnTheDeployingContract(bytes32 salt, address other) public view {
        vm.assume(other != address(h));
        assertTrue(CREATE3.getDeployed(salt, other) != h.predict(salt));
    }

    /// @notice A salt deploys once: the second CREATE2 of its proxy fails, whatever the code.
    function test_aSaltDeploysOnce() public {
        bytes32 salt = bytes32(uint256(1));
        h.deploy(salt, abi.encodePacked(type(OwnedEcho).creationCode, abi.encode(uint256(1))));
        vm.expectRevert(bytes("DEPLOYMENT_FAILED"));
        h.deploy(salt, abi.encodePacked(type(OwnedEcho).creationCode, abi.encode(uint256(2))));
    }

    /// @notice A reverting constructor reverts the deployment and leaves no code and no proxy at the address.
    function test_aRevertingConstructorLeavesNothing() public {
        bytes32 salt = bytes32(uint256(2));
        address predicted = h.predict(salt);
        vm.expectRevert(bytes("INITIALIZATION_FAILED"));
        h.deploy(salt, type(OwnedReverter).creationCode);
        assertEq(predicted.code.length, 0);
        // The salt is still free: nothing of the failed attempt survived.
        address echo = h.deploy(salt, abi.encodePacked(type(OwnedEcho).creationCode, abi.encode(uint256(3))));
        assertEq(echo, predicted);
    }

    /// @notice The factory's address is solmate's CREATE3 address of keccak256(abi.encode(deployer, salt)) from the
    ///         factory, which the fixture's miner computes the same way.
    function testFuzz_factoryAddressIsTheNamespacedSolmateAddress(address deployer, bytes32 salt) public view {
        address expected = CREATE3.getDeployed(keccak256(abi.encode(deployer, salt)), address(factory));
        assertEq(factory.computeAddress(deployer, salt), expected);
        assertEq(_create3(address(factory), deployer, uint256(salt)), expected);
    }

    /// @notice The factory deploys at that address and, through solmate's own salt check, can never deploy a second
    ///         time at it: a used salt is refused before the proxy is touched.
    function test_factoryDeploysAtThePredictionAndRefusesTheSaltAgain() public {
        bytes32 salt = _mine(brand);
        address predicted = factory.computeAddress(brand, salt);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        (HookrRoot r,) = _deployWith(factory, brand, sel, salt);
        assertEq(address(r), predicted);
        assertTrue(factory.saltUsed(brand, salt));
        uint256 fee = _fee(factory);
        vm.deal(brand, brand.balance + fee);
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.SaltUsed.selector, brand, salt));
        _deployCall(factory, fee, sel, salt);
    }

    /// @notice Both creation codes the factory deploys, with their constructor arguments, fit EIP-3860's 49,152-byte
    ///         initcode limit: the root through the CREATE3 proxy's CREATE, the companion through CREATE2. Derived from
    ///         the build, so a later change to either contract that crosses the limit fails here first.
    function test_creationCodesFitTheInitcodeLimit() public view {
        uint256 rootArgs = abi.encode(manager, registry, address(router), address(quoter), address(0)).length;
        uint256 rulesArgs = abi.encode(manager, registry, address(hookrTreasury), address(root), PROTOCOL_FLOOR).length;
        assertLe(type(HookrRoot).creationCode.length + rootArgs, 49_152, "root initcode");
        assertLe(type(HookrRules).creationCode.length + rulesArgs, 49_152, "companion initcode");
    }

    /// @notice A deployment's calldata carries both creation codes and must stay under the 95,000 bytes Nitro's
    ///         sequencer accepts by default (execution.sequencer.max-tx-data-size). Derived from the build, so a later
    ///         change to HookrRoot, HookrLane, HookrRules or HookrRecapture that crosses it fails here first.
    function test_deployCalldataFitsTheSequencerLimit() public view {
        bytes memory data = abi.encodeCall(
            IHookrOwnedRootFactory.deploy,
            (type(HookrRoot).creationCode, type(HookrRules).creationCode, _sel(brand, F.ALL_FEATURES), bytes32(0))
        );
        assertLt(data.length, 95_000);
    }
}
