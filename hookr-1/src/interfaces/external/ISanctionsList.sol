// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISanctionsList
/// @notice Minimal interface of an on-chain sanctions oracle (Chainalysis-compatible, selector 0xdf592f7d).
interface ISanctionsList {
    /// @notice Returns whether the address is sanctioned.
    function isSanctioned(address addr) external view returns (bool);
}
