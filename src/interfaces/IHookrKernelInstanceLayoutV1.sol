// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Compatibility marker for root hooks that may execute behind a Hookr kernel instance.
interface IHookrKernelInstanceLayoutV1 {
    function kernelInstanceLayoutId() external view returns (bytes32);
}
