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
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";

/// Old numbers: the guard LP owner pulled 16.09475 ETH (9,467 bps of buyers' ETH) mid-guard.
/// Audit finding L-06.
contract GuardLiquidityLockTest is RootSecurityBase {
    using PoolIdLibrary for PoolKey;

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

    function testPrincipalRemovalLockedDuringGuardAndFeeCollectionAllowed() public {
        HookrTypes.RulesConfig memory c = _rulesConfig();
        uint256 guardEnd = block.number + 100;
        c.guardEndBlock = uint40(guardEnd);
        PoolKey memory key = _open(_config(address(rules)), abi.encode(c), 60);
        PoolId id = key.toId();
        _addLiquidity(key, -600, 600, 1e22);
        assertEq(rules.removalLockedUntil(id), guardEnd);
        vm.expectRevert(
            _wrapped(
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(IHookrRootState.LiquidityLocked.selector, id, guardEnd)
            )
        );
        _addLiquidity(key, -600, 600, -1e22);
        _addLiquidity(key, -600, 600, 0);
        vm.roll(guardEnd - 1);
        vm.expectRevert(
            _wrapped(
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(IHookrRootState.LiquidityLocked.selector, id, guardEnd)
            )
        );
        _addLiquidity(key, -600, 600, -1);
        vm.roll(guardEnd);
        // removalLockedUntil keeps returning guardEndBlock (NatSpec: the block *before which* removal is refused);
        // at guardEnd that block is no longer in the future, so the lock is spent. Root enforces with the same `<`.
        assertLe(rules.removalLockedUntil(id), block.number);
        _addLiquidity(key, -600, 600, -1e22);
    }

    /// The lock is read from Rules once, at initialization; later answers from the module are never consulted.
    function testRemovalLockIsFrozenAtInitialization() public {
        uint256 until = block.number + 50;
        mock.setLock(until, false);
        PoolKey memory key = _open(_config(address(mock)), bytes("m"), 60);
        _addLiquidity(key, -600, 600, 1e22);
        mock.setLock(0, true);
        vm.expectRevert();
        _addLiquidity(key, -600, 600, -1e22);
        vm.roll(until);
        mock.setLock(type(uint256).max, false);
        _addLiquidity(key, -600, 600, -1e22);
    }

    /// A Rules module that cannot answer its removal lock is refused at initialization.
    function testRulesWithoutARemovalLockAnswerIsRefused() public {
        mock.setLock(0, true);
        HookrTypes.PoolConfig memory pc = _config(address(mock));
        PoolKey memory key = _key(60);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallFailed.selector, address(mock), IHookrRules.removalLockedUntil.selector
            )
        );
        root.initializePool(key, pc, bytes("m"), bytes(""), SQRT_ONE);
    }
}
