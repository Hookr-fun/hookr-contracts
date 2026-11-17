// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title Hookr code chunk
/// @notice A contract whose runtime is a piece of another contract's creation code, behind a leading STOP so calling
///         it does nothing. HookrCodeStore writes a creation code too large for one contract as several of these and
///         reads them back with `extcodecopy`.
contract HookrCodeChunk {
    /// @param data The bytes to store; the runtime is `0x00` followed by them.
    constructor(bytes memory data) {
        bytes memory runtime = abi.encodePacked(hex"00", data);
        assembly ("memory-safe") {
            return(add(runtime, 32), mload(runtime))
        }
    }
}
