// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PackedUserOperation} from "./PackedUserOperation.sol";

/// @title IPaymaster
/// @notice ERC-4337 v0.7 paymaster interface (minimal, matches the canonical EntryPoint).
interface IPaymaster {
    /// @notice opSucceeded: the account call succeeded. opReverted: it reverted. postOpReverted: legacy, never passed in v0.7.
    enum PostOpMode {
        opSucceeded,
        opReverted,
        postOpReverted
    }

    /// @notice Validates a user operation and precharges it.
    /// @return context Data passed to postOp. validationData Packed (aggregator, validUntil, validAfter).
    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        external
        returns (bytes memory context, uint256 validationData);

    /// @notice Settles an operation after execution.
    function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        external;
}
