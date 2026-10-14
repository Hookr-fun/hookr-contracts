// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {MockFeeOnTransferToken} from "../mocks/MockFeeOnTransferToken.sol";
import {IHookrLaneEvents} from "../../src/interfaces/IHookrLaneEvents.sol";
import {ScriptedLaneFixture} from "./utils/ScriptedLaneFixture.sol";

/// @notice Leaves a sync pending, then swaps, then settles everything.
contract SyncThenSwap is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function go(PoolKey calldata key, Currency synced, uint256 amountIn) external {
        pm.unlock(abi.encode(key, synced, amountIn));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        (PoolKey memory key, Currency synced, uint256 amountIn) = abi.decode(raw, (PoolKey, Currency, uint256));
        pm.sync(synced);
        pm.swap(key, SwapParams(true, -int256(amountIn), 4295128741), "");
        pm.settle();
        _close(key.currency0);
        _close(key.currency1);
        return "";
    }

    function _close(Currency c) internal {
        int256 d = pm.currencyDelta(address(this), c);
        if (d > 0) {
            pm.take(c, address(this), uint256(d));
        } else if (d < 0) {
            if (c.isAddressZero()) {
                pm.settle{value: uint256(-d)}();
            } else {
                pm.sync(c);
                IERC20(Currency.unwrap(c)).transfer(address(pm), uint256(-d));
                pm.settle();
            }
        }
    }

    receive() external payable {}
}

/// @notice What the lane trusts in a frame: a delegated lane or a changed lane code is skipped and the split follows
///         the push (audit finding F-013), a pending sync is refused (F-038), the frame batches its transient reads
///         (F-072) and a reverted frame leaves no settlement events (F-074).
contract FrameTrustTest is ScriptedLaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// F-013. An EIP-7702 delegated account cannot be opened as a lane.
    function test_delegatedLaneRefused() public {
        address eoa = makeAddr("delegated-lane");
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(exec)));
        vm.expectRevert();
        registry.queue(OPEN_LANE, abi.encode(address(root), eoa, eoa.codehash, LANE_GAS, PARTNER_BPS));
    }

    /// F-013. The executor's code hash is frozen per pool; changed code is skipped with `LaneCodeChanged` and never
    /// called, and the swap needs no lane gas.
    function test_changedLaneCodeIsSkipped() public {
        (, bytes32 codeHash,,,,,) = IHookrLaneRoot(address(root)).laneOf(id);
        assertEq(codeHash, address(exec).codehash);
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        uint128 potBefore = _pot();
        ScriptedExecutor other = new ScriptedExecutor(IPoolManager(address(0xbeef)));
        vm.etch(address(exec), address(other).code);
        vm.recordLogs();
        uint256 out = _buy(key, ETH, whale, 1e18);
        Tally memory t = _tally(vm.getRecordedLogs());
        assertGt(out, 0, "the swap completed");
        assertEq(t.codeChanged, 1, "read once, in the before-phase");
        assertEq(t.succeeded + t.failed, 0, "the changed lane was never called");
        assertEq(_pot(), potBefore);
    }

    /// F-013. What the executor returns is not read: the profit is its push at the pool's frozen partner
    /// share, so an executor that returns more than its push is split as its push, the protocol's 25% taken from it.
    function test_theSplitFollowsThePush() public {
        exec.set(ScriptedExecutor.Mode.SKIM, 9e18);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Tally memory t = _tally(logs);
        assertEq(t.failed, 0);
        assertEq(t.succeeded, 2);
        assertEq(t.pushed, 9e18, "4.5e18 in each phase");
        Splits memory s = _splits(logs);
        assertEq(s.protocol, 2 * _cut(_profitOf(4.5e18), 4.5e18), "25% of the profit the push stands for at 25%");
        assertEq(s.count, 2);
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// F-038. A lane pool refuses a swap while a sync is pending, so the executor can never inherit one. A pool without
    /// the lane on the same root is unaffected.
    function test_pendingSyncRefused() public {
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        SyncThenSwap s = new SyncThenSwap(manager);
        vm.deal(address(s), 1e24);
        // An ERC-20 that burns 1% of every transfer.
        Currency pending = Currency.wrap(address(new MockFeeOnTransferToken("Taxed", "TAX", 1e30, 100, address(0))));
        vm.expectRevert();
        s.go(key, pending, 1e18);
        s.go(stdKey, pending, 1e18);
    }

    /// F-072. Each frame reads its snapshot in one batched `exttload` before and one after the executor; the only
    /// single-slot reads left are the sync checks: the lane's, one per phase, and HookrRouter's stale-sync check before
    /// it swaps (SYS-01).
    function test_frameBatchesExttload() public {
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        vm.expectCall(address(manager), abi.encodeWithSelector(bytes4(keccak256("exttload(bytes32[])"))), 4);
        vm.expectCall(address(manager), abi.encodeWithSelector(bytes4(keccak256("exttload(bytes32)"))), 3);
        _buy(key, ETH, whale, 1e18);
    }

    /// F-074. A frame that reverts after the push leaves no split event, even in logs that include reverted frames.
    function test_revertedFrameLeavesNoSettlementEvents() public {
        exec.set(ScriptedExecutor.Mode.PUSH_THEN_LEAVE_DELTA, 9e18);
        uint128 potBefore = _pot();
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        Tally memory t = _tally(vm.getRecordedLogs());
        assertEq(t.failed, 2);
        assertEq(t.lastReason, IHookrLaneEvents.LaneLeftDelta.selector);
        assertEq(t.succeeded, 0);
        assertEq(t.splits, 0);
        assertEq(_pot(), potBefore);
    }
}
