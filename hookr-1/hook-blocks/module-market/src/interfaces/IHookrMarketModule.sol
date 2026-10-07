// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrModuleMarket} from "./IHookrModuleMarket.sol";

/// @title IHookrMarketModule
/// @notice What a marketplace module exposes besides IHookrAdvisory, read at publish.
interface IHookrMarketModule {
    /// @notice The only marketplace this module records installs with.
    function market() external view returns (IHookrModuleMarket);

    /// @notice The recipient the module names for every quote take: its router-derived fee account.
    function feeRecipient() external view returns (address);

    /// @notice The developer wallet that alone may publish this module.
    function developer() external view returns (address);
}
