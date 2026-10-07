// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHookrUsageFeeRouter
/// @notice Collects each version's usage fees from HookrRules claims and splits them: developer, backers,
///         protocol, per-version reserve.
interface IHookrUsageFeeRouter {
    /// @notice The marketplace this router serves.
    function market() external view returns (address);

    /// @notice The deterministic fee account a module must name as its advisory recipient.
    function feeAccountOf(address module) external view returns (address);

    /// @notice Deploys the fee account of a module being published. Only the marketplace can call.
    function deployFeeAccount(address module) external returns (address account);

    /// @notice Adds rewards the vault could not stream to anyone to the version's reserve. Only the vault.
    function receiveStranded(uint256 versionId, Currency currency, uint256 amount) external payable;

    /// @notice Pays part of a version's reserve out. Only the marketplace, after a timelocked operation.
    function drawReserve(uint256 versionId, Currency currency, address to, uint256 amount) external;
}
