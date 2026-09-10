// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrStatefulModuleTypesV1} from "../libraries/HookrStatefulModuleTypesV1.sol";

/// @title Hookr Stateful Module V1
/// @notice Opt-in lifecycle ABI for codehash-pinned modules on HookrSwapKernelV3.
/// @dev The kernel calls exactly one gas-bounded stateful callback per declared phase and validates
///      its typed action plan. Implementations are privileged reviewed code: CALL is not a sandbox
///      against direct PoolManager interactions while an unlock is active.
interface IHookrStatefulModuleV1 {
    function statefulModuleMagic() external pure returns (bytes32);

    function beforeSwapStateful(HookrStatefulModuleTypesV1.BeforeSwapContext calldata context, bytes calldata config)
        external
        returns (HookrStatefulModuleTypesV1.BeforeSwapResult memory result);

    function afterSwapStateful(HookrStatefulModuleTypesV1.AfterSwapContext calldata context, bytes calldata config)
        external
        returns (HookrStatefulModuleTypesV1.AfterSwapResult memory result);
}
