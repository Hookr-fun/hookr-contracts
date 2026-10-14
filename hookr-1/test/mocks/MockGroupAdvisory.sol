// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {FixedAdvice} from "../utils/FixedAdvice.sol";

/// @notice A FixedAdvice that declares an exclusive group the way Tax + Conversion's advisory does, as
///         `EXCLUSIVE_GROUP()`. With keccak256("DIRECTIONAL_QUOTE_TAX") it is what HookrRules knows Tax + Conversion
///         by at bind; its before-phase advice (the same on every swap) stands in for the tax.
contract MockGroupAdvisory is FixedAdvice {
    bytes32 public immutable EXCLUSIVE_GROUP;

    constructor(bytes32 group, HookrTypes.Advice memory before_)
        FixedAdvice(before_, HookrTypes.Advice(0, 0, address(0), false), false, false)
    {
        EXCLUSIVE_GROUP = group;
    }
}

/// @notice A FixedAdvice whose `EXCLUSIVE_GROUP()` answers badly with Tax + Conversion's group: reverting with it
///         (`mode` 0), spending all the gas it is given (1), or returning it with a second word (2).
contract MockBadGroupAdvisory is FixedAdvice {
    uint8 internal immutable mode;

    constructor(uint8 mode_)
        FixedAdvice(
            HookrTypes.Advice(0, 0, address(0), false), HookrTypes.Advice(0, 0, address(0), false), false, false
        )
    {
        mode = mode_;
    }

    function EXCLUSIVE_GROUP() external view returns (bytes32) {
        bytes32 group = keccak256("DIRECTIONAL_QUOTE_TAX");
        if (mode == 0) {
            assembly ("memory-safe") {
                mstore(0, group)
                revert(0, 32)
            }
        }
        if (mode == 1) {
            uint256 spent;
            while (gasleft() > 0) {
                ++spent;
            }
            return bytes32(spent);
        }
        assembly ("memory-safe") {
            mstore(0, group)
            mstore(32, group)
            return(0, 64)
        }
    }
}
