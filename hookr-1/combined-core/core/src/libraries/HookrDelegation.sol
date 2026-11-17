// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title HookrDelegation
/// @notice How Hookr contracts recognise an account whose key holder can re-point its code: an EIP-7702 delegation
///         designator, 0xef0100 || target (23 bytes).
/// @dev Internal library: each contract compiles in the predicate it uses. EIP-3541 refuses created code that starts
///      with 0xEF, except on Arbitrum chains with Stylus such as Robinhood Chain 4663, where a Stylus program deploys:
///      0xeff0, a format byte and the program, at least 4 bytes (formats 0x00, 0x01 and 0x02 deploy on 4663). So code
///      that starts with 0xEF is a designator or a Stylus program. `isDelegated` answers true for both: HookrGoverned,
///      HookrTreasury, HookrComplianceGuard and the registry's contract and any-quote checks refuse both.
///      `isDesignator` answers true for the designator only: the registry's owner, nominee and guardian check refuses
///      it alone. HookrLane reads a pool subject's first byte only when its code is 23 bytes long, a designator's
///      length, and refuses it there when `isDelegated`.
library HookrDelegation {
    /// @dev Whether `account`'s code starts with 0xEF: an EIP-7702 delegation designator or, on a chain with Stylus, a
    ///      Stylus program. An account without code answers false: EXTCODECOPY pads past the code with zeros.
    function isDelegated(address account) internal view returns (bool delegated) {
        assembly ("memory-safe") {
            extcodecopy(account, 0, 0, 1)
            delegated := eq(byte(0, mload(0)), 0xef)
        }
    }

    /// @dev Whether `account`'s code is an EIP-7702 delegation designator: exactly 23 bytes starting 0xef0100.
    function isDesignator(address account) internal view returns (bool designator) {
        assembly ("memory-safe") {
            if eq(extcodesize(account), 23) {
                extcodecopy(account, 0, 0, 3)
                designator := eq(shr(232, mload(0)), 0xef0100)
            }
        }
    }
}
