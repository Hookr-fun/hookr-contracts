// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IHookrMaturityTokenV1
/// @notice Read-only maturity surface implemented by V6.1 launch tokens.
interface IHookrMaturityTokenV1 {
    function maturityTokenVersion() external pure returns (uint32);

    function maturityPolicyHash() external pure returns (bytes32);

    function balanceOf(address account) external view returns (uint256);

    function weightedAcquiredAt(address account) external view returns (uint40);

    function holdingAge(address account) external view returns (uint40);

    function maturityBps(address account, uint40 fullMaturitySeconds) external view returns (uint16);
}
