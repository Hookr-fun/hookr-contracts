// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Universal Router surface used by Hookr best-route
/// @notice The pinned Universal Router 2.1.1 on Robinhood Chain 4663 (0x8876789976dEcBfCbBbe364623C63652db8C0904).
interface IUniversalRouter {
    /// @notice Executes `commands` with one ABI-encoded input per command. Reverts after `deadline`.
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;

    /// @notice The account that called `execute` while a command is running; zero outside a call.
    function msgSender() external view returns (address);

    /// @notice The v4 PoolManager this router settles against.
    function poolManager() external view returns (address);
}
