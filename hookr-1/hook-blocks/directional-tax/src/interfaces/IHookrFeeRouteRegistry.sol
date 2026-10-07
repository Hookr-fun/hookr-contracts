// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HookrFeeConversionTypes} from "../types/HookrFeeConversionTypes.sol";

/// @title Hookr fee route registry
/// @notice Read surface of the owner-curated set of conversion routes.
interface IHookrFeeRouteRegistry {
    /// @notice Returns the route record. An unknown id returns a zeroed record with status NONE.
    function route(bytes32 routeId) external view returns (HookrFeeConversionTypes.Route memory);

    /// @notice Returns whether the route is active, converts `tokenIn` to `tokenOut`, and its adapter code is unchanged.
    function isActive(bytes32 routeId, address tokenIn, address tokenOut) external view returns (bool);
}
