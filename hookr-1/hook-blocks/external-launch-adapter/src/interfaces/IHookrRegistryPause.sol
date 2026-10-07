// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrRegistryPause
/// @notice The Hookr registry's global brake, which `IHookrRegistry` does not expose.
interface IHookrRegistryPause {
    function newMarketsPaused() external view returns (bool);
}
