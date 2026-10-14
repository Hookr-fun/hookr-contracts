// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {RootSecurityBase, MockRules} from "../utils/RootSecurityBase.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {FixedAdvice} from "../utils/FixedAdvice.sol";

/// Old behaviour: a broken or vetoing fail-open advisory blocked every add.
/// Audit finding I-20.
contract FailOpenAdvisoryAddsTest is RootSecurityBase {
    function setUp() public {
        _setUpRootSecurity();
    }

    function _advisory(bool failOpen, HookrTypes.Advice memory before_) internal returns (FixedAdvice a) {
        a = new FixedAdvice(before_, HookrTypes.Advice(0, 0, address(0), false), failOpen, false);
        IHookrRegistry.Admission memory ad = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(a),
            codeHash: address(a).codehash,
            schemaHash: a.configSchemaHash(),
            caps: HookrTypes.Caps(10_000, failOpen ? 0 : 20_000, 0),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: failOpen,
            failOpen: failOpen
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), ad));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), ad);
    }

    function _openAdvised(address rulesModule, FixedAdvice a, bool failOpen, uint8 phases)
        internal
        returns (PoolKey memory key)
    {
        HookrTypes.PoolConfig memory pc = _config(rulesModule);
        pc.advisory = address(a);
        pc.advisoryGasLimit = 2_000_000;
        pc.advisoryPhases = phases;
        pc.advisoryFailOpen = failOpen;
        key = _key(60);
        root.initializePool(
            key, pc, rulesModule == address(rules) ? abi.encode(_rulesConfig()) : bytes("m"), bytes(""), SQRT_ONE
        );
    }

    function testOpenAdvisoryNotConsultedOnAdds() public {
        FixedAdvice a = _advisory(true, HookrTypes.Advice(0, 0, address(0), false));
        PoolKey memory key = _openAdvised(address(rules), a, true, 1);
        vm.mockCallRevert(address(a), abi.encodeWithSelector(IHookrAdvisory.beforeAddLiquidity.selector), bytes(""));
        _addLiquidity(key, -600, 600, 1e22);
        vm.mockCall(address(a), abi.encodeWithSelector(IHookrAdvisory.beforeAddLiquidity.selector), abi.encode(false));
        _addLiquidity(key, -600, 600, 1e22);
        _genericSwap(key, true, -1e18, 0);
    }

    function testClosedAdvisoryVetoStillBlocksAdds() public {
        FixedAdvice a = _advisory(false, HookrTypes.Advice(0, 0, address(0), false));
        PoolKey memory key = _openAdvised(address(rules), a, false, 1);
        vm.mockCall(address(a), abi.encodeWithSelector(IHookrAdvisory.beforeAddLiquidity.selector), abi.encode(false));
        vm.expectRevert();
        _addLiquidity(key, -600, 600, 1e22);
    }
}
