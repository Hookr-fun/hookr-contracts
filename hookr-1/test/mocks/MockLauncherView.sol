// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Stands in for HookrLauncher's frozen coupling points (§4.2).
contract MockLauncherView {
    mapping(PoolId => bytes32) public poolFamily;
    mapping(bytes32 => address) public familyOwner;

    function setFamily(PoolId id, bytes32 family, address owner) external {
        poolFamily[id] = family;
        familyOwner[family] = owner;
    }

    function transferFamily(bytes32 family, address owner) external {
        familyOwner[family] = owner;
    }
}
