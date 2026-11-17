// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title HookrCodeStore
/// @notice A data contract holding one piece of a creation code for owned-root factory v2 (DECISIONS D33c): its runtime
///         is a STOP byte followed by the data, so a call to it does nothing and a reader copies the data with
///         EXTCODECOPY from offset 1. It has no function, no owner and no way to change or destroy its code (EIP-6780
///         lets only a contract created in the same transaction self-destruct, and this code holds no SELFDESTRUCT), so
///         a hash of its runtime checked once stands for every later read.
/// @dev The round-trip Rules' pattern: the data lives in runtime, not in storage, so a reader pays 3 gas a word to
///      copy it and the store pays the deposit once. At most MAX_DATA bytes, so the runtime stays within EIP-170.
contract HookrCodeStore {
    /// @dev The most data one store holds: EIP-170's 24,576 runtime bytes less the STOP byte. Not a getter: the
    ///      runtime is the data alone.
    uint256 internal constant MAX_DATA = 24_575;

    /// @notice The data is empty or longer than MAX_DATA.
    error InvalidData(uint256 length);

    /// @param data The bytes the store holds after its STOP byte.
    constructor(bytes memory data) {
        uint256 n = data.length;
        if (n == 0 || n > MAX_DATA) revert InvalidData(n);
        assembly ("memory-safe") {
            // The length word right before the data becomes the STOP byte and the data: overwrite its last byte with
            // 0x00 and return from there. The runtime is `0x00 ++ data`.
            let start := add(data, 31)
            mstore8(start, 0)
            return(start, add(n, 1))
        }
    }
}
