// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUniversalRouter
/// @notice The one function of Uniswap's Universal Router the bench calls.
interface IUniversalRouter {
    /// @notice Runs `commands` on their `inputs`, as long as `deadline` has not passed.
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
