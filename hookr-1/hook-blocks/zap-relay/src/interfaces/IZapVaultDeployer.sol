// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Zap vault deployer
/// @notice The helper each HookrZapAccrual creates in its constructor to hold the vault's creation code.
interface IZapVaultDeployer {
    /// @notice The accrual that created this deployer; the only account that may deploy through it.
    function accrual() external view returns (address);
}
