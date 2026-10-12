// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrRecapture} from "../../src/core/HookrRecapture.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";

/// @notice HookrRules runs a recapture pool's split and King of the Pool in the HookrRecapture module it deploys in
///         its constructor and reaches only by DELEGATECALL. The Rules' runtime fixes the module's address and runtime
///         codehash and reports both from `recaptureModule()`; ADMIT of a RULES implementation refuses one whose module's
///         code differs, so the admission's codehash pin also pins the module. The module refuses to run on its own
///         address, and its surface (bounds, defaults, views) is served through the Rules' fallback, so no selector
///         joins the Rules' dispatcher.
contract RulesRecaptureModuleTest is PeripheryFixture {
    function setUp() public {
        _setUpPeriphery();
    }

    function _createdAt(address deployer, uint8 nonce) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, nonce)))));
    }

    function _admission(address implementation) internal view returns (IHookrRegistry.Admission memory) {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: implementation,
            codeHash: implementation.codehash,
            schemaHash: HookrRules(implementation).configSchemaHash(),
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
    }

    function test_recaptureModule_isTheRulesFirstCreation() public view {
        (address module, bytes32 codeHash) = IHookrRecaptureRules(address(rules)).recaptureModule();
        assertEq(module, _createdAt(address(rules), 1), "deployed by the Rules' constructor at nonce 1");
        assertGt(module.code.length, 0);
        assertEq(module.codehash, codeHash, "the reported codehash is the module's");
        assertEq(HookrRecapture(module).trustedRoot(), address(root));
        assertEq(HookrRecapture(module).protocolRecipient(), protocol);
    }

    function test_admit_refusesARulesWhoseModuleCodeDiffers() public {
        HookrRules second = new HookrRules(manager, registry, protocol, address(root), 2000);
        (address module,) = IHookrRecaptureRules(address(second)).recaptureModule();
        bytes32 rulesHash = address(second).codehash;
        IHookrRegistry.Admission memory a = _admission(address(second));
        bytes32 admit = registry.ADMIT();
        bytes memory original = module.code;
        // The same Rules runtime over another module: what a constructor other than HookrRules' could leave behind.
        vm.etch(module, address(new HookrRecapture(manager, address(0xbad), address(root))).code);
        assertEq(address(second).codehash, rulesHash, "the Rules' own codehash does not see the module");
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, module));
        registry.queue(admit, abi.encode(address(root), a));
        // With the module's own code back, it queues; a module changed before execution is refused again.
        vm.etch(module, original);
        registry.queue(admit, abi.encode(address(root), a));
        vm.etch(module, "");
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, module));
        registry.admit(address(root), a);
        vm.etch(module, original);
        registry.admit(address(root), a);
        assertEq(registry.admission(address(root), address(second)).implementation, address(second));
    }

    function test_module_refusesDirectCalls() public {
        (address module,) = IHookrRecaptureRules(address(rules)).recaptureModule();
        PoolId id;
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        PoolKey memory k;
        HookrRecapture(module).settleRecapture(k, k.currency0, address(this), 1, 1, 1);
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        HookrRecapture(module).flushRecapture(k);
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        HookrRecapture(module).creditSweep(k.currency0, 1);
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        HookrRecapture(module).settleEpoch(id);
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        HookrRecapture(module).claimPool(id, address(this));
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        HookrRecapture(module).recaptureMode(id);
        PoolKey memory key;
        HookrTypes.PoolConfig memory pc;
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        HookrRecapture(module).bind(key, pc, "");
    }

    /// The module's own bind and settleSwap share the Rules' selectors, so the Rules' functions answer them: from
    /// outside, a bind is the Rules' bind with its checks, never the module's.
    function test_moduleEntriesThatShareARulesSelectorAreUnreachableFromOutside() public {
        PoolKey memory key;
        HookrTypes.PoolConfig memory pc;
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        rules.bind(key, pc, "");
        HookrTypes.SwapContext memory x;
        HookrTypes.Settlement memory z;
        vm.expectRevert(IHookrRulesEvents.UnknownPool.selector);
        rules.settleSwap(x, z);
    }

    function test_surfaceIsServedThroughTheRules() public view {
        IHookrRecaptureRules r = IHookrRecaptureRules(address(rules));
        assertEq(r.MAX_TRADER_BPS(), 5_000);
        assertEq(r.DEFAULT_TRADER_BPS(), 2_500);
        (HookrTypes.RecaptureConfig memory d, uint16 potBps) = r.recaptureDefaults();
        assertTrue(d.on);
        assertEq(potBps, 0);
        assertEq(r.prizeBound(400, 0, 2500), 50, "half the protocol's 1% of a buy");
        assertEq(r.recaptureMode(PoolId.wrap(bytes32(uint256(1)))), 0, "an unknown pool has no recapture");
    }

    function test_recaptureModule_answersOnlyTheExactSelector() public view {
        (bool ok, bytes memory out) =
            address(rules).staticcall(abi.encodePacked(IHookrRecaptureRules.recaptureModule.selector, uint256(0)));
        assertFalse(ok && out.length == 64, "longer input is the module's surface, not recaptureModule");
    }
}
