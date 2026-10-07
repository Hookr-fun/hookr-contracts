// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice ERC-4337 v0.7 packed user operation, as defined by the EntryPoint at 0x0000000071727De22E5E9d8BAf0edAc6f37da032.
/// @dev accountGasLimits = verificationGasLimit (high 128) ‖ callGasLimit (low 128).
///      gasFees = maxPriorityFeePerGas (high 128) ‖ maxFeePerGas (low 128).
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}
