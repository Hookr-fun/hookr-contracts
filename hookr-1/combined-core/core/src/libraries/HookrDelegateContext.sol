// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Root transport for the core's shared Claims and Recapture modules.
/// @dev The core appends its immutable trustedRoot as the final, clean 32-byte word on EVERY forwarded call.
/// Modules retain a private SELF immutable and reject direct state-changing calls before using this helper.
/// This is distinct from the block-table protocol; block tails end in their running words instead.
library HookrDelegateContext {
    error InvalidDelegateContext();

    function trustedRoot() internal pure returns (address root) {
        uint256 length;
        uint256 word;
        assembly ("memory-safe") {
            length := calldatasize()
            word := calldataload(sub(length, 32))
        }
        if (length < 36 || word == 0 || word >> 160 != 0) revert InvalidDelegateContext();
        return address(uint160(word));
    }
}
