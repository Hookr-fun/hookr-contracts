// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrQuoteBrakes
/// @notice The Hookr 1 registry's per-asset quote brake (`brakeOneQuoteInstantly`), read for every routed asset.
interface IHookrQuoteBrakes {
    function quoteIsBraked(address asset) external view returns (bool braked, uint48 brakedAt);
}
