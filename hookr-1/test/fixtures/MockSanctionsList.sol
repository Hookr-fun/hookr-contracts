// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title Mock sanctions list
/// @notice External sanctions source with selectable failure modes for compliance tests.
contract MockSanctionsList {
    enum Mode {
        HEALTHY,
        REVERT,
        OOG,
        WIDE,
        TWO
    }

    Mode public mode;
    mapping(address => bool) public listed;

    /// @notice Sets the response mode.
    function setMode(Mode next) external {
        mode = next;
    }

    /// @notice Sets a wallet's sanction flag.
    function setListed(address wallet, bool value) external {
        listed[wallet] = value;
    }

    /// @notice ISanctionsList-compatible read with the configured failure mode.
    function isSanctioned(address wallet) external view returns (bool) {
        Mode m = mode;
        if (m == Mode.REVERT) revert("source down");
        if (m == Mode.OOG) {
            uint256 i;
            while (gasleft() > 0) ++i;
        }
        if (m == Mode.WIDE) {
            assembly ("memory-safe") {
                mstore(0, 0)
                mstore(32, 0)
                return(0, 64)
            }
        }
        if (m == Mode.TWO) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return listed[wallet];
    }
}
