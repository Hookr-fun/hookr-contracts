// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LaneFixture} from "../LaneFixture.sol";
import {ScriptedExecutor} from "../mocks/ScriptedExecutor.sol";
import {IHookrRecaptureEvents} from "../../../src/interfaces/IHookrRecaptureEvents.sol";

/// @notice A King of the Pool lane pool on HookrRoot with a scripted executor holding the subject, a plain pool
///         beside it, and the tally of one transaction's lane events: the shared setup of the lane suites on gas
///         floors, the crown ledger, executor legs and frame trust. The 2026-09-24 audit's lab launcher findings
///         (F-032: deadlines, codeless currencies, existing pools, exact funding, two-step ownership) are covered by
///         the launcher suites under test/periphery.
abstract contract ScriptedLaneFixture is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    bytes32 internal constant CODE_CHANGED = keccak256("LaneCodeChanged(bytes32,uint8)");
    bytes32 internal constant HOOK_FEE = keccak256("HookFee(bytes32,address,uint256,uint256,uint256)");
    /// @dev HookrLane's MAX_TRACKED_POSITIONS: distinct same-transaction positions the King of the Pool ledger tracks.
    uint256 internal constant MAX_TRACKED_POSITIONS = 8;

    ScriptedExecutor internal exec;
    PoolKey internal key;
    PoolKey internal stdKey;
    PoolId internal id;
    bytes32 internal family;

    struct Tally {
        uint256 failed;
        uint256 succeeded;
        uint256 splits;
        uint256 codeChanged;
        uint256 pushed;
        bytes4 lastReason;
        uint256 reported;
    }

    function setUp() public virtual {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e28);
        exec.setRoot(address(root));
        _openLane(address(exec));
        (key, family) = _openPoolWithFamily(ETH, _laneRules(true), _kothRc());
        id = key.toId();
        stdKey = _openStd(ETH);
        IERC20(Currency.unwrap(_subjectOf(key))).transfer(address(exec), 1e26);
    }

    function _tally(Vm.Log[] memory logs) internal view returns (Tally memory t) {
        for (uint256 i; i < logs.length; ++i) {
            bytes32 topic = logs[i].topics[0];
            if (logs[i].emitter == address(rules)) {
                if (topic == IHookrRecaptureEvents.RecaptureSplit.selector) {
                    t.splits++;
                    (,,,,, uint256 reported) =
                        abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, Currency, uint256));
                    t.reported += reported;
                }
                continue;
            }
            if (logs[i].emitter != address(root)) continue;
            if (topic == FAILED) {
                t.failed++;
                t.lastReason = abi.decode(logs[i].data, (bytes4));
            } else if (topic == SUCCEEDED) {
                t.succeeded++;
                (, uint256 pushed) = abi.decode(logs[i].data, (uint256, uint256));
                t.pushed += pushed;
            } else if (topic == CODE_CHANGED) {
                t.codeChanged++;
            }
        }
    }

    function _pot() internal view returns (uint128 pot) {
        (,,, pot) = _hill(key);
    }

    /// @dev The inner revert reason of a PoolManager `WrappedError`.
    function _wrappedReason(bytes memory e) internal pure returns (bytes4) {
        assertEq(bytes4(e), CustomRevert.WrappedError.selector, "a hook refusal");
        bytes memory tail = new bytes(e.length - 4);
        for (uint256 i; i < tail.length; ++i) {
            tail[i] = e[i + 4];
        }
        (,, bytes memory reason,) = abi.decode(tail, (address, bytes4, bytes, bytes));
        return bytes4(reason);
    }
}
