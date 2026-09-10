// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Immutable identity exposed by a Hookr kernel instance.
interface IHookrKernelInstanceV1 {
    function factory() external view returns (address);
    function implementation() external view returns (address);
    function implementationCodeHash() external view returns (bytes32);
}
