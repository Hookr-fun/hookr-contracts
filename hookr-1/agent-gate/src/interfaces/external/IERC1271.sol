// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC1271
/// @notice The one read the gate makes on a contract that links an identity: whether the contract approves a digest
///         (a Safe through its owners' signatures or a message it signed, a smart account through its signer). A
///         contract that only forwards other people's calls (Multicall3, an ERC-2771 forwarder) has no such answer.
interface IERC1271 {
    /// @notice 0x1626ba7e when the contract approves `hash` with `signature`.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue);
}
