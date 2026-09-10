// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Hookr Hook Data V1
/// @notice Canonical authenticated-router envelope shared by the modular kernel and its routers.
/// @dev `moduleData` remains opaque to the root and is exposed only to frozen modules. Direct or
///      unreviewed routers cannot assert a wallet payer/recipient and must use empty hook data.
library HookrHookDataV1 {
    uint256 internal constant VERSION = 1;

    error InvalidHookData();

    struct Envelope {
        address payer;
        address recipient;
        bytes32 stackHash;
        bytes moduleData;
    }

    function encode(address payer, address recipient, bytes32 stackHash, bytes memory moduleData)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(VERSION, payer, recipient, stackHash, moduleData);
    }

    function decode(bytes calldata raw, bytes32 expectedStackHash) internal pure returns (Envelope memory envelope) {
        // Five ABI head words plus the dynamic byte-array length word.
        if (raw.length < 192) revert InvalidHookData();
        uint256 version;
        (version, envelope.payer, envelope.recipient, envelope.stackHash, envelope.moduleData) =
            abi.decode(raw, (uint256, address, address, bytes32, bytes));
        if (
            version != VERSION || envelope.payer == address(0) || envelope.recipient == address(0)
                || envelope.stackHash != expectedStackHash
                || keccak256(raw)
                    != keccak256(encode(envelope.payer, envelope.recipient, envelope.stackHash, envelope.moduleData))
        ) revert InvalidHookData();
    }
}
