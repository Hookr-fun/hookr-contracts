// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HookrFeeConversionTypes} from "../types/HookrFeeConversionTypes.sol";
import {IHookrFeeRouteRegistry} from "./IHookrFeeRouteRegistry.sol";

/// @title Hookr fee swap executor
/// @notice Verifies a signed plan against the route registry and the authorizer, then runs the route's adapter.
interface IHookrFeeSwapExecutor {
    /// @notice Returns the immutable route registry the executor reads.
    function routeRegistry() external view returns (IHookrFeeRouteRegistry);

    /// @notice Returns the EIP-712 digest a signer approves for `plan`.
    function hashPlan(HookrFeeConversionTypes.ExecutionPlan calldata plan) external view returns (bytes32);

    /// @notice Converts `plan.amountIn` from the calling strategy and returns the output to it.
    /// @dev `plan.strategy` must be `msg.sender`; the nonce is consumed only when the conversion succeeds.
    function execute(
        HookrFeeConversionTypes.ExecutionPlan calldata plan,
        bytes calldata signature,
        bytes calldata routeData
    ) external payable returns (uint256 amountOut, bytes32 planDigest);
}
