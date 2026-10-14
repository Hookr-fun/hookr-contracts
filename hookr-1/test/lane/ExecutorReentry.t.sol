// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrRoot} from "../../src/interfaces/IHookrRoot.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrLaneRules} from "../../src/interfaces/IHookrLaneRules.sol";
import {IHookrLanes} from "../../src/interfaces/IHookrLanes.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {LaneRootFixture} from "./utils/LaneRootFixture.sol";

/// @notice An executor that, inside its frame, tries every entry into the root, its module, the Rules, the launcher,
///         the router, the registry and the PoolManager it can reach, records each outcome and returns cleanly.
contract ReentryExecutor {
    struct Attempt {
        address target;
        uint256 value;
        bytes data;
        string label;
    }

    address public immutable root;
    Attempt[] internal _attempts;
    bool[] public oks;
    bytes4[] public reasons;
    bool public armed;

    constructor(address _root) {
        root = _root;
    }

    function add(address target, uint256 value, bytes calldata data, string calldata label) external {
        _attempts.push(Attempt(target, value, data, label));
    }

    function arm(bool a) external {
        armed = a;
    }

    function count() external view returns (uint256) {
        return _attempts.length;
    }

    function label(uint256 i) external view returns (string memory) {
        return _attempts[i].label;
    }

    function executeArbitrage(PoolKey calldata, address) external returns (uint256) {
        require(msg.sender == root, "root");
        if (!armed) return 0;
        for (uint256 i; i < _attempts.length; ++i) {
            Attempt storage a = _attempts[i];
            (bool ok, bytes memory ret) = a.target.call{value: a.value}(a.data);
            oks.push(ok);
            bytes4 r;
            if (ret.length >= 4) r = bytes4(ret);
            reasons.push(r);
        }
        armed = false;
        return 0;
    }

    receive() external payable {}
}

/// @notice ATK-EX-4 and ATK-EX-5, held (reentrancy into the root, module, Rules and periphery; the brake): nothing
///         reachable from inside a frame opens a second way in, and a brake cannot be undone before a full delay.
contract ExecutorReentryTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;

    ReentryExecutor internal rx;
    PoolKey internal key;
    bytes32 internal family;

    function setUp() public {
        _setUpLane();
        rx = new ReentryExecutor(address(root));
        vm.deal(address(rx), 1e26);
        _openLane(address(rx), 3_000_000);
        (family, key) = _one(_newSubject(), true, false, 0);
        _nextBlock();
    }

    function _attempts() internal {
        PoolId id = key.toId();
        (address module,) = IHookrLaneRoot(address(root)).laneModule();
        IHookrRouter.Swap memory p = _swapParams(key, ETH, true, true, 1e15, address(rx));
        rx.add(
            address(router), 1e15, abi.encodeCall(HookrRouter.swap, (p, address(0), new uint256[](0))), "router.swap"
        );
        rx.add(address(manager), 0, abi.encodeCall(IPoolManager.unlock, (bytes(""))), "manager.unlock");
        rx.add(
            address(manager),
            0,
            abi.encodeCall(IPoolManager.modifyLiquidity, (key, ModifyLiquidityParams(-60, 60, 1e18, 0), bytes(""))),
            "manager.modifyLiquidity(add) on the pool"
        );
        rx.add(
            address(rules),
            0,
            abi.encodeCall(IHookrLaneRules.settleRecapture, (key, key.currency0, address(rx), 1, 1, 1)),
            "rules.settleRecapture"
        );
        rx.add(
            address(rules), 0, abi.encodeWithSignature("claimPool(bytes32,address)", id, address(rx)), "rules.claimPool"
        );
        rx.add(address(root), 0, abi.encode(key, address(rx)), "root frame entry (192-byte fallback)");
        rx.add(
            module,
            0,
            abi.encodeCall(IHookrLaneRoot.settleRecapture, (key, key.currency0, 1)),
            "module.settleRecapture direct"
        );
        rx.add(module, 0, abi.encode(key, address(rx)), "module frame entry direct");
        rx.add(address(root), 0, abi.encodeWithSignature("takeReceipt(bytes32)", id), "root.takeReceipt");
        rx.add(
            address(launcher),
            0,
            abi.encodeCall(HookrLauncher.claimRecapture, (family, 0, address(rx))),
            "launcher.claimRecapture"
        );
        rx.add(
            address(registry),
            0,
            abi.encodeWithSignature("stopExecutorLane(address,address)", address(root), address(rx)),
            "registry.stopExecutorLane"
        );
        // A whole launch from inside the frame: the root refuses initializePool while a swap is active.
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(ETH, true, false, 0);
        rx.add(
            address(launcher),
            1e24,
            abi.encodeCall(
                HookrLauncher.launch,
                (
                    IHookrLauncher.Token(address(0), "X", "X", 1e27, bytes32(uint256(7))),
                    address(root),
                    members,
                    type(uint256).max
                )
            ),
            "launcher.launch (new family inside the frame)"
        );
    }

    function test_held_everyEntryFromInsideTheFrameIsRefused_andTheFrameStillSucceeds() public {
        _attempts();
        rx.arm(true);
        vm.recordLogs();
        _sell(key, ETH, whale, 1e18);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2, "the frame that tried everything still passed its checks");
        uint256 n = rx.count();
        for (uint256 i; i < n; ++i) {
            console2.log(rx.label(i));
            console2.logBytes4(rx.reasons(i));
            assertFalse(rx.oks(i), rx.label(i));
        }
    }

    /// The brake reaches the open pool at once and nothing queued before it lifts it early.
    function test_held_brakeCannotBeUndoneEarly() public {
        bytes32 codeHash = address(rx).codehash;
        // Queued before the brake: a switch-on at a raised cap and a re-opening of the same executor.
        registry.queue(LANE_ON, abi.encode(address(root), address(rx), uint32(5_000_000)));
        registry.queue(OPEN_LANE, abi.encode(address(root), address(rx), codeHash, uint32(5_000_000), PARTNER_BPS));
        vm.warp(vm.getBlockTimestamp() + 1);
        registry.stopExecutorLane(address(root), address(rx));
        uint256 brakedAt = vm.getBlockTimestamp();
        // The open pool: no lane call, no floor.
        vm.recordLogs();
        this.sellWithGas(key, 400_000);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded + o.failed, 0, "off at once on the open pool, no floor");
        vm.warp(brakedAt + registry.delay());
        vm.expectRevert();
        registry.startExecutorLaneAt(address(root), address(rx), 5_000_000);
        vm.expectRevert();
        registry.openLaneOf(address(root), address(rx), codeHash, 5_000_000, PARTNER_BPS);
        // A lower is a brake; a raise through tune is refused.
        vm.expectRevert();
        registry.tuneExecutorLane(address(root), address(rx), 4_000_000);
        // Cancel and re-queue after the brake: not before a full delay.
        registry.cancel(registry.operationHash(LANE_ON, abi.encode(address(root), address(rx), uint32(5_000_000))));
        registry.queue(LANE_ON, abi.encode(address(root), address(rx), uint32(5_000_000)));
        vm.warp(vm.getBlockTimestamp() + registry.delay() - 1);
        vm.expectRevert();
        registry.startExecutorLaneAt(address(root), address(rx), 5_000_000);
        vm.warp(vm.getBlockTimestamp() + 1);
        registry.startExecutorLaneAt(address(root), address(rx), 5_000_000);
        (bool on, uint32 cap) = registry.executorLane(address(root), address(rx));
        assertTrue(on);
        assertEq(cap, 5_000_000);
    }
}
