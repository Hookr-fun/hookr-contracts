// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library HookrRoundTrip {
    /// @dev keccak256("hookr.rules.roundtrip.advisory")
    bytes32 internal constant MAGIC = 0x3b9f85950e804a66b22c8d0d93f6e2288a43115640b009d0924a56a8a5bd0333;
    uint256 internal constant BOUGHT = 1;
    uint256 internal constant SOLD = 2;
}
