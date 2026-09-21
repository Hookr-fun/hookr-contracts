// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Narrow execution-height clock used by Robinhood Orbit correction plans.
interface IHookrExecutionClockV1 {
    function executionBlockNumber() external view returns (uint64);
}
