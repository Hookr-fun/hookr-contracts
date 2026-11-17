// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHookrModuleV1} from "hookr/interfaces/IHookrModuleV1.sol";
import {HookrModuleTypesV1} from "hookr/libraries/HookrModuleTypesV1.sol";

/// @dev Calls a module's `beforeSwap` the way `HookrSwapAccountingKernelV3._beforeResult` does: a
///      STATICCALL with the registration's `callbackGasLimit` that copies at most the 128 bytes of a
///      `ModuleResult`. The assembly is copied from the kernel's `_staticcallExact`. This is not the
///      kernel; it shows what the kernel's call sees (success, the result size, the revert data it
///      hashes into `ModuleCallFailed`) and the gas the call uses.
contract KernelCallHarness {
    uint256 internal constant RESULT_SIZE = 128;

    function callBeforeSwap(
        address module,
        uint256 gasLimit,
        HookrModuleTypesV1.SwapContext calldata context,
        bytes calldata config
    ) external view returns (bool ok, bytes memory output, uint256 gasUsed) {
        bytes memory input = abi.encodeCall(IHookrModuleV1.beforeSwap, (context, config));
        uint256 start = gasleft();
        (ok, output) = _staticcallExact(module, gasLimit, input, RESULT_SIZE);
        gasUsed = start - gasleft();
    }

    function _staticcallExact(address target, uint256 gasLimit, bytes memory input, uint256 expectedLength)
        internal
        view
        returns (bool ok, bytes memory output)
    {
        output = new bytes(expectedLength);
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(input, 0x20), mload(input), add(output, 0x20), expectedLength)
            let returnSize := returndatasize()
            if iszero(eq(returnSize, expectedLength)) {
                ok := 0
                if lt(returnSize, expectedLength) { mstore(output, returnSize) }
            }
        }
    }
}
