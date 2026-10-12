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
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// Old numbers: Root allowed base + surcharge above the admission cap that bind refused.
/// Audit finding I-04.
contract RulesCapMeaningTest is RootSecurityBase {
    function setUp() public {
        _setUpRootSecurity();
    }

    function _wrapped(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(root),
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function testAdmissionCapBoundsTotalNativeLpFee() public {
        PoolKey memory key = _open(_config(address(mock)), bytes("m"), 60);
        _addLiquidity(key, -600, 600, 1e22);
        mock.setQuotes(HookrTypes.FeeQuote(99_000, 0, 0), HookrTypes.FeeQuote(0, 0, 0));
        vm.expectRevert(
            _wrapped(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IHookrRootEvents.InvalidModuleResult.selector, address(mock))
            )
        );
        _genericSwap(key, true, -1e18, 0);
        mock.setQuotes(HookrTypes.FeeQuote(97_000, 0, 0), HookrTypes.FeeQuote(0, 0, 0));
        _genericSwap(key, true, -1e18, 0);
    }
}
