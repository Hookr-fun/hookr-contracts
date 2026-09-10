// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Canonical RouterV2/QuoterV1 payload namespace for modular-kernel generation two.
/// @dev Routers continue to pass one opaque byte string. The kernel separates module inputs from
///      phase-specific correction inputs before invoking either subsystem.
library HookrCorrectionPayloadV2 {
    uint256 internal constant VERSION = 2;
    uint256 internal constant MODULE_NAMESPACE_VERSION = 2;

    error InvalidPayload();

    struct Envelope {
        bytes modulePayload;
        bytes beforeSwapCorrection;
        bytes afterSwapCorrection;
    }

    function encode(bytes memory modulePayload, bytes memory beforeSwapCorrection, bytes memory afterSwapCorrection)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(VERSION, modulePayload, beforeSwapCorrection, afterSwapCorrection);
    }

    function decode(bytes memory raw) internal pure returns (Envelope memory envelope) {
        if (raw.length < 256) revert InvalidPayload();
        uint256 version;
        (version, envelope.modulePayload, envelope.beforeSwapCorrection, envelope.afterSwapCorrection) =
            abi.decode(raw, (uint256, bytes, bytes, bytes));
        if (
            version != VERSION
                || keccak256(raw)
                    != keccak256(
                        encode(envelope.modulePayload, envelope.beforeSwapCorrection, envelope.afterSwapCorrection)
                    )
        ) revert InvalidPayload();
    }

    /// @notice Wraps dynamic module bytes so the delegated V1 accounting kernel can never parse
    ///         them as its legacy 480-byte correction tuple.
    function encodeModulePayload(bytes memory modulePayload) internal pure returns (bytes memory) {
        return abi.encode(MODULE_NAMESPACE_VERSION, modulePayload);
    }

    function decodeModulePayload(bytes calldata raw) internal pure returns (bytes memory modulePayload) {
        if (raw.length < 96) revert InvalidPayload();
        uint256 version;
        (version, modulePayload) = abi.decode(raw, (uint256, bytes));
        if (
            version != MODULE_NAMESPACE_VERSION
                || keccak256(raw) != keccak256(abi.encode(MODULE_NAMESPACE_VERSION, modulePayload))
        ) revert InvalidPayload();
    }
}
