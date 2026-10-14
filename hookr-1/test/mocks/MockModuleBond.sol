// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IHookrModuleBond} from "../../src/interfaces/IHookrModuleBond.sol";

/// @notice A module bond whose answer a test sets per (scope, implementation), and which can answer badly: revert,
///         return a short, long or dirty word, or burn every gas unit it is given.
contract MockModuleBond is IHookrModuleBond {
    enum Mode {
        ANSWER,
        REVERT,
        SHORT,
        LONG,
        DIRTY,
        BURN
    }

    Mode public mode;
    mapping(address scope => mapping(address implementation => bool)) public covered;

    function setCovered(address scope, address implementation, bool value) external {
        covered[scope][implementation] = value;
    }

    function setMode(Mode next) external {
        mode = next;
    }

    /// @inheritdoc IHookrModuleBond
    function covers(address scope, address implementation) external view returns (bool) {
        Mode m = mode;
        if (m == Mode.REVERT) revert("bond");
        if (m == Mode.BURN) {
            while (true) {}
        }
        bool value = covered[scope][implementation];
        if (m == Mode.SHORT) {
            assembly ("memory-safe") {
                mstore(0, value)
                return(1, 31)
            }
        }
        if (m == Mode.LONG) {
            assembly ("memory-safe") {
                mstore(0, value)
                mstore(32, 0)
                return(0, 64)
            }
        }
        if (m == Mode.DIRTY) {
            assembly ("memory-safe") {
                mstore(0, or(value, shl(8, 1)))
                return(0, 32)
            }
        }
        return value;
    }
}
