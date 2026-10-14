// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";

/// @notice Records real PoolManager/Hookr logs for the operator service's security regressions.
/// @dev The exported vector uses the operator service's fixture shape. Every step is one
///      transaction; `from` is the transaction origin the step simulates. Exported JSON is test evidence only.
abstract contract ServiceEventExport is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    string internal eventsJson;
    string internal storageJson;
    uint256 internal step;

    /// @dev Starts one simulated transaction: next block, 12 s later, fresh log recording.
    function _begin() internal {
        ++step;
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        vm.recordLogs();
    }

    /// @dev Appends every log recorded since `_begin` with the step's simulated transaction origin.
    function _capture(address origin) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            string memory topics;
            for (uint256 j; j < logs[i].topics.length; ++j) {
                topics = string.concat(topics, j == 0 ? "" : ",", '"', vm.toString(logs[i].topics[j]), '"');
            }
            eventsJson = string.concat(
                eventsJson,
                bytes(eventsJson).length == 0 ? "" : ",",
                '{"address":"',
                vm.toString(logs[i].emitter),
                '","topics":[',
                topics,
                '],"data":"',
                vm.toString(logs[i].data),
                '","step":',
                vm.toString(step),
                ',"index":',
                vm.toString(i),
                ',"from":"',
                vm.toString(origin),
                '","contractBlock":"',
                vm.toString(block.number),
                '","timestamp":',
                vm.toString(vm.getBlockTimestamp()),
                "}"
            );
        }
    }

    /// @dev Adds the PoolManager pool words (slot0, fee growth, liquidity), selected ticks and positions.
    function _exportPool(PoolKey memory key, int24[] memory ticks, bytes32[] memory positions) internal {
        bytes32 pool = keccak256(abi.encode(key.toId(), uint256(6)));
        _words(pool, 4);
        for (uint256 i; i < ticks.length; ++i) {
            _words(keccak256(abi.encode(int256(ticks[i]), bytes32(uint256(pool) + 4))), 3);
        }
        for (uint256 i; i < positions.length; ++i) {
            _words(keccak256(abi.encode(positions[i], bytes32(uint256(pool) + 6))), 3);
        }
    }

    function _words(bytes32 slot, uint256 count) internal {
        bytes32[] memory words = manager.extsload(slot, count);
        for (uint256 i; i < words.length; ++i) {
            storageJson = string.concat(
                storageJson,
                bytes(storageJson).length == 0 ? "" : ",",
                '"',
                vm.toString(bytes32(uint256(slot) + i)),
                '":"',
                vm.toString(words[i]),
                '"'
            );
        }
    }

    /// @dev Launcher family position key inside PoolManager (sender = launcher, salt = keccak(family, member)).
    function _familyPosition(bytes32 family, int24 lower, int24 upper) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(launcher), lower, upper, keccak256(abi.encode(family, uint8(0)))));
    }

    function _header(string memory extra) internal view returns (string memory) {
        return string.concat(
            '{"schema":"hookr.lp-fixture.v1","chainId":"',
            vm.toString(block.chainid),
            '","kind":"local-solidity-real-poolmanager","manager":"',
            vm.toString(address(manager)),
            '","root":"',
            vm.toString(address(root)),
            '","rules":"',
            vm.toString(address(rules)),
            '","launcher":"',
            vm.toString(address(launcher)),
            '","router":"',
            vm.toString(address(router)),
            '","treasury":"',
            vm.toString(protocol),
            '",',
            extra
        );
    }

    function _vector(string memory extra) internal view returns (string memory) {
        return string.concat(_header(extra), '"storage":{', storageJson, '},"events":[', eventsJson, "]}");
    }
}
