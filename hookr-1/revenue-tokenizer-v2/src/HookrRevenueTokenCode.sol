// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrRevenueToken} from "./HookrRevenueToken.sol";

/// @title Hookr revenue token code
/// @notice Holds one half of the revenue token's creation code as its runtime, behind a leading STOP byte so the data
///         never runs. The tokenizer reads both halves and creates every revenue token from them: the creation code is
///         larger than one contract's runtime may be, so no single contract or library can carry it.
/// @dev `part` 0 holds the first `SPLIT` bytes of `type(HookrRevenueToken).creationCode`, `part` 1 the rest. Both halves
///      are linked as the token is, to its three libraries (HookrSignatures, HookrDropBoxDeployer and
///      HookrIncomeRecovery), because they are the token's own creation code.
contract HookrRevenueTokenCode {
    /// @notice The length of the first half.
    uint256 public constant SPLIT = 14_000;

    /// @notice `part` is not 0 or 1.
    error InvalidPart(uint256 part);

    /// @param part Which half this contract holds.
    constructor(uint256 part) {
        if (part > 1) revert InvalidPart(part);
        bytes memory code = type(HookrRevenueToken).creationCode;
        uint256 start = part == 0 ? 0 : SPLIT;
        uint256 end = part == 0 ? SPLIT : code.length;
        assembly ("memory-safe") {
            let n := sub(end, start)
            let out := mload(0x40)
            mstore8(out, 0)
            mcopy(add(out, 1), add(add(code, 0x20), start), n)
            return(out, add(n, 1))
        }
    }
}
