// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {HookrBlockKey} from "../core/HookrBlockKey.sol";
/// @notice Deterministic, immutable brake-key recipes; all indices are C1 BlockBound bits0..7.
library HookrBlockKeys {
    error InvalidBlockKey();
    function salt(uint8 index) internal pure returns (bytes32 s) {
        if (index > 7) revert InvalidBlockKey();
        // keccak256(abi.encodePacked("hookr.rules.block.v1.", index)) for index 0-7, as constants (G1a gas pass;
        // HookrBlockKeys.t.sol recomputes every one).
        assembly ("memory-safe") {
            switch index
            case 0 { s := 0x329ad4de29c08e35be5a5ee065b93680170ecda7e93ea25041c5f98c25c6fe0b }
            case 1 { s := 0xda4212ef447dea721775f997d66d05f61a531053a96e371b9ae9b2132e1ae730 }
            case 2 { s := 0x7124b7ab3592bbd7fd90510d7a7ba63fb453d7cae97fbc8009f44ea3ed592476 }
            case 3 { s := 0x120a50f95825611310c7aa524093aec55de1588a12d14e5e19a631875da36c8b }
            case 4 { s := 0x47e74051dff2da507ae2f2e28d28a13e7e2e9e0c1f36b390aec1bad2e260abfa }
            case 5 { s := 0x9fcc5d225c255e0efa26da54212428041f098e8f44af3320c9d82b312bc2f476 }
            case 6 { s := 0x1927addf8d622938ee3a92b4498eb4616b476d30c0543cf89357779fc05ca1aa }
            case 7 { s := 0x9ccfea5a7e7b6b83c3e396a008b261e66c5dbd80f7fb7427435b00ba93c4f93f }
        }
    }
    function key(address scope, uint8 index) internal pure returns (address) {
        return keyWith(scope, index, initCodeHash());
    }
    /// @dev HookrBlockKey's creation-code hash, the CREATE2 init-code hash of every brake key.
    function initCodeHash() internal pure returns (bytes32) {
        return keccak256(type(HookrBlockKey).creationCode);
    }
    /// @dev HookrBlockKey's runtime hash: an empty contract, so every key runs it and no immutable varies it.
    function runtimeCodeHash() internal pure returns (bytes32) {
        return keccak256(type(HookrBlockKey).runtimeCode);
    }
    /// @dev Whether `account` is one of `scope`'s eight keys: the same CREATE2 addresses as `key(scope, 0..7)`, the
    ///      creation code hashed once and the eight preimages built in scratch memory (G1a gas pass).
    function isKey(address scope, address account) internal pure returns (bool hit) {
        bytes32 initHash = initCodeHash();
        assembly ("memory-safe") {
            let p := mload(0x40)
            let m := 0xffffffffffffffffffffffffffffffffffffffff
            mstore(p, or(shl(248, 0xff), shl(88, scope)))
            mstore(add(p, 53), initHash)
            mstore(add(p, 21), 0x329ad4de29c08e35be5a5ee065b93680170ecda7e93ea25041c5f98c25c6fe0b)
            hit := or(hit, eq(account, and(keccak256(p, 85), m)))
            mstore(add(p, 21), 0xda4212ef447dea721775f997d66d05f61a531053a96e371b9ae9b2132e1ae730)
            hit := or(hit, eq(account, and(keccak256(p, 85), m)))
            mstore(add(p, 21), 0x7124b7ab3592bbd7fd90510d7a7ba63fb453d7cae97fbc8009f44ea3ed592476)
            hit := or(hit, eq(account, and(keccak256(p, 85), m)))
            mstore(add(p, 21), 0x120a50f95825611310c7aa524093aec55de1588a12d14e5e19a631875da36c8b)
            hit := or(hit, eq(account, and(keccak256(p, 85), m)))
            mstore(add(p, 21), 0x47e74051dff2da507ae2f2e28d28a13e7e2e9e0c1f36b390aec1bad2e260abfa)
            hit := or(hit, eq(account, and(keccak256(p, 85), m)))
            mstore(add(p, 21), 0x9fcc5d225c255e0efa26da54212428041f098e8f44af3320c9d82b312bc2f476)
            hit := or(hit, eq(account, and(keccak256(p, 85), m)))
            mstore(add(p, 21), 0x1927addf8d622938ee3a92b4498eb4616b476d30c0543cf89357779fc05ca1aa)
            hit := or(hit, eq(account, and(keccak256(p, 85), m)))
            mstore(add(p, 21), 0x9ccfea5a7e7b6b83c3e396a008b261e66c5dbd80f7fb7427435b00ba93c4f93f)
            hit := or(hit, eq(account, and(keccak256(p, 85), m)))
        }
    }
    /// @dev `key` with the init-code hash given, so a caller deriving several keys hashes the creation code once.
    function keyWith(address scope, uint8 index, bytes32 initHash) internal pure returns (address k) {
        bytes32 s = salt(index);
        // keccak256(abi.encodePacked(bytes1(0xff), scope, s, initHash)): the CREATE2 address, 85 bytes hashed in
        // scratch memory (G1a gas pass).
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, or(shl(248, 0xff), shl(88, scope)))
            mstore(add(p, 21), s)
            mstore(add(p, 53), initHash)
            k := and(keccak256(p, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
