// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrModuleTypesV1} from "../libraries/HookrModuleTypesV1.sol";

/// @title Hookr Module V1
/// @notice Read-only policy interface for modules admitted to the SWAP_DELTA_V1 kernel family.
interface IHookrModuleV1 {
    function moduleKey() external pure returns (bytes32);
    function moduleVersion() external pure returns (uint32);
    function configSchemaHash() external pure returns (bytes32);

    /// @notice Validates canonical config bytes and returns their exact commitment.
    function validateConfig(bytes calldata config) external view returns (bytes32 configHash);

    /// @notice Validates that canonical config is bound to this exact future pool and kernel.
    /// @dev Stack creation fails here rather than admitting a configuration that can only discover
    ///      a pool, currency, or kernel mismatch during its first user swap.
    function validateStack(bytes32 poolId, address kernel, address subject, address quote, bytes calldata config)
        external
        view
        returns (HookrModuleTypesV1.ModuleConfigCaps memory caps);

    /// @notice Returns true when this liquidity change is allowed.
    function beforeAddLiquidity(HookrModuleTypesV1.LiquidityContext calldata context, bytes calldata config)
        external
        view
        returns (bool allowed);

    function beforeSwap(HookrModuleTypesV1.SwapContext calldata context, bytes calldata config)
        external
        view
        returns (HookrModuleTypesV1.ModuleResult memory result);

    function afterSwap(HookrModuleTypesV1.AfterSwapContext calldata context, bytes calldata config)
        external
        view
        returns (HookrModuleTypesV1.ModuleResult memory result);
}
