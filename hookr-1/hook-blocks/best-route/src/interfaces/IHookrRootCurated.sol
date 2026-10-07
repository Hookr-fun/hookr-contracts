// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrRootCurated
/// @notice The Hookr root's public getter for the curated router's pinned code hash.
interface IHookrRootCurated {
    function curatedRouterCodeHash() external view returns (bytes32);
}
