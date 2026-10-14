// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrLane} from "../../src/core/HookrLane.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice HookrRoot runs initialization and the recapture lane in the HookrLane module it deploys in its constructor
///         and reaches only by DELEGATECALL. The root's runtime fixes the module's address and runtime codehash and
///         reports both from `laneModule()`; `REGISTER_ROOT` refuses a root whose module's code differs, so the pinned
///         root codehash also pins the module. The module refuses to run on its own address.
contract RootLaneModuleTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _setUpPeriphery();
    }

    function _secondRoot() internal returns (HookrRoot second) {
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(HookrRoot).creationCode,
                abi.encode(manager, registry, address(router), address(quoter), address(0))
            )
        );
        for (uint256 i = 2_000_000;; ++i) {
            address predicted = vm.computeCreate2Address(bytes32(i), initHash, address(this));
            if (uint160(predicted) & 0x3fff == root.PERMISSION_FLAGS()) {
                return new HookrRoot{salt: bytes32(i)}(manager, registry, address(router), address(quoter), address(0));
            }
        }
    }

    function _createdAt(address deployer, uint8 nonce) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, nonce)))));
    }

    function test_laneModule_isTheRootsFirstCreation() public view {
        (address module, bytes32 codeHash) = IHookrLaneRoot(address(root)).laneModule();
        assertEq(module, _createdAt(address(root), 1), "deployed by the root's constructor at nonce 1");
        assertGt(module.code.length, 0);
        assertEq(module.codehash, codeHash, "the reported codehash is the module's");
        assertEq(address(HookrLane(module).registry()), address(registry));
        assertEq(address(HookrLane(module).poolManager()), address(manager));
    }

    function test_register_refusesARootWhoseModuleCodeDiffers() public {
        HookrRoot second = _secondRoot();
        (address module,) = IHookrLaneRoot(address(second)).laneModule();
        bytes32 rootHash = address(second).codehash;
        bytes32 register = registry.REGISTER_ROOT();
        // The same root runtime over another module: what a constructor other than HookrRoot's could leave behind.
        bytes memory original = module.code;
        vm.etch(module, address(new HookrLane(manager, registry)).code);
        assertEq(address(second).codehash, rootHash, "the root's own codehash does not see the module");
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, module));
        registry.queue(register, abi.encode(address(second), rootHash));
        // With the module's own code back, it queues; a module changed before execution is refused again.
        vm.etch(module, original);
        registry.queue(register, abi.encode(address(second), rootHash));
        vm.etch(module, "");
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, module));
        registry.registerRoot(address(second), rootHash);
        vm.etch(module, original);
        registry.registerRoot(address(second), rootHash);
        assertTrue(registry.isRoot(address(second)));
    }

    function test_module_refusesDirectCalls() public {
        (address module,) = IHookrLaneRoot(address(root)).laneModule();
        PoolKey memory key;
        vm.expectRevert(IHookrRootEvents.Unauthorized.selector);
        HookrLane(module).settleRecapture(key, key.currency0, 1);
        vm.expectRevert(IHookrRootEvents.Unauthorized.selector);
        HookrLane(module).sweepClaims(key.toId(), key.currency0);
        vm.expectRevert(IHookrRootEvents.Unauthorized.selector);
        HookrLane(module).sameTxLiquidityOnPath(key.toId());
        (bool ok,) = module.call(new bytes(192));
        assertFalse(ok, "the frame runs only as the root's self-call");
    }

    function test_laneModule_answersOnlyTheExactSelector() public {
        (bool ok, bytes memory out) =
            address(root).staticcall(abi.encodePacked(IHookrLaneRoot.laneModule.selector, uint256(0)));
        assertFalse(ok && out.length == 64, "longer input is the lane surface, not laneModule");
    }
}

