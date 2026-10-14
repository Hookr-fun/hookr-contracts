// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrLaneRules} from "../../src/interfaces/IHookrLaneRules.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice Mints PoolManager claims of native ETH to an account outside a swap.
contract ReasonClaimMinter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function mintTo(address to, uint256 amount) external payable {
        manager.unlock(abi.encode(to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        manager.settle{value: amount}();
        manager.mint(to, 0, amount);
        return "";
    }
}

/// @notice N15 on HookrLane's own module calls on a lane pool: an arb recapture's settlement (the Rules'
///         settleRecapture after a frame pushed) and a sweep (the Rules' creditSweep). A Rules module that reverts with
///         data raises ModuleCallReverted(rules, selector, reason), the data cut to its first 132 bytes; one that
///         reverts without data keeps ModuleCallFailed(rules, selector). The settlement runs inside the swap's hook
///         call, so the PoolManager wraps the lane's error and the swap reverts; a sweep is called directly.
contract ModuleRevertReasonLaneTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ScriptedExecutor internal exec;
    PoolKey internal key;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e30);
        exec.setRoot(address(root));
        _openLane(address(exec));
        key = _openKoth(ETH);
    }

    function _wrapped(bytes4 callback, bytes memory inner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(root),
            callback,
            inner,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _reason(uint256 length, bytes32 seed) internal pure returns (bytes memory reason) {
        reason = new bytes(length);
        for (uint256 i; i < length; ++i) {
            reason[i] = bytes1(keccak256(abi.encode(seed, i)));
        }
    }

    function _cut(bytes memory reason) internal pure returns (bytes memory cut) {
        uint256 n = reason.length < 132 ? reason.length : 132;
        cut = new bytes(n);
        for (uint256 i; i < n; ++i) {
            cut[i] = reason[i];
        }
    }

    /// @dev What HookrLane raises for the Rules' failed `selector` call that reverted with `reason`.
    function _raised(bytes4 selector, bytes memory reason) internal view returns (bytes memory) {
        if (reason.length == 0) {
            return abi.encodeWithSelector(IHookrRootEvents.ModuleCallFailed.selector, address(rules), selector);
        }
        return
            abi.encodeWithSelector(IHookrRootEvents.ModuleCallReverted.selector, address(rules), selector, _cut(reason));
    }

    function _buyExpecting(bytes memory err) internal {
        IHookrRouter.Swap memory p = _swapParams(key, ETH, true, true, 1e18, whale);
        vm.expectRevert(err);
        vm.prank(whale);
        router.swap{value: 1e18}(p, address(0), new uint256[](0));
    }

    /// The Rules refuse a push's settlement with data: the before-phase frame pushed, HookrLane's settleRecapture call
    /// carries the refusal (short, at the cap and cut from 1,000 bytes), and the swap reverts inside beforeSwap. Without
    /// data the error stays ModuleCallFailed. With the Rules healthy again the same buy settles both phases.
    function test_settlementRefusalCarriesTheRulesReason() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 1e18);
        bytes4 settle = IHookrLaneRules.settleRecapture.selector;
        bytes[4] memory reasons =
            [abi.encodeWithSignature("Refused(uint256)", 42), _reason(132, "cap"), _reason(1000, "long"), bytes("")];
        for (uint256 i; i < reasons.length; ++i) {
            vm.mockCallRevert(address(rules), abi.encodeWithSelector(settle), reasons[i]);
            _buyExpecting(_wrapped(IHooks.beforeSwap.selector, _raised(settle, reasons[i])));
            vm.clearMockedCalls();
        }
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        assertEq(_outcome(vm.getRecordedLogs()).succeeded, 2, "both phases settle");
    }

    /// The Rules refuse a sweep's credit with data: sweepClaims reverts with ModuleCallReverted, not wrapped (no hook
    /// call), and the claims stay with the root; without data, ModuleCallFailed; healthy, the sweep moves them.
    function test_sweepRefusalCarriesTheRulesReason() public {
        ReasonClaimMinter minter = new ReasonClaimMinter(manager);
        minter.mintTo{value: 5e18}(address(root), 5e18);
        bytes4 credit = IHookrLaneRules.creditSweep.selector;
        bytes[2] memory reasons = [abi.encodeWithSignature("Error(string)", "credit refused"), bytes("")];
        for (uint256 i; i < reasons.length; ++i) {
            vm.mockCallRevert(address(rules), abi.encodeWithSelector(credit), reasons[i]);
            vm.expectRevert(_raised(credit, reasons[i]));
            IHookrLaneRoot(address(root)).sweepClaims(key.toId(), ETH);
            vm.clearMockedCalls();
            assertEq(manager.balanceOf(address(root), ETH.toId()), 5e18, "the claims stay with the root");
        }
        assertEq(IHookrLaneRoot(address(root)).sweepClaims(key.toId(), ETH), 5e18, "healthy, the sweep moves them");
        assertEq(manager.balanceOf(address(root), ETH.toId()), 0);
    }
}
