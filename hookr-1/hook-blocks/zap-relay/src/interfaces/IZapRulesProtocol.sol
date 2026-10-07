// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IZapRulesProtocol
/// @dev The two HookrRules getters the vault reads at construction (the package's IHookrRules does not declare them).
interface IZapRulesProtocol {
    function protocolRecipient() external view returns (address);
    function minProtocolShareBps() external view returns (uint16);
}
