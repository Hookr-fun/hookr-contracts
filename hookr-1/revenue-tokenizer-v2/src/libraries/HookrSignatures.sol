// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title Hookr signatures
/// @notice The one signature check behind every signed path of a revenue token and its drop box: an ECDSA signature
///         that recovers to the signer, or one the signer's code accepts through ERC-1271.
/// @dev An external library the token and the box reach by delegatecall, linked at deploy, so the checker's code
///      lives here once and not in the token's runtime. ECDSA is tried before ERC-1271 whatever code the signer has
///      (OpenZeppelin's SignatureChecker), so an EIP-7702 account signs with its key and a smart wallet through its
///      validator.
library HookrSignatures {
    /// @notice Whether `signature` is `signer`'s over `digest`.
    function isValid(address signer, bytes32 digest, bytes memory signature) external view returns (bool) {
        return SignatureChecker.isValidSignatureNow(signer, digest, signature);
    }
}
