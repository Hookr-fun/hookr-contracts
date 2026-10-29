// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice The W1/K21 wallet predicate: no code or an exact 23-byte EIP-7702 designator.
library HookrWallets {
    function isWallet(address account) internal view returns (bool) {
        return account.code.length == 0 || isDesignator(account);
    }

    /// @dev A 0xEF prefix alone is insufficient: Stylus and malformed lengths remain contracts.
    function isDesignator(address account) internal view returns (bool designator) {
        assembly ("memory-safe") {
            if eq(extcodesize(account), 23) {
                extcodecopy(account, 0, 0, 3)
                designator := eq(shr(232, mload(0)), 0xef0100)
            }
        }
    }
}
