// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IHookrLockRewardsV1 {
    function checkpoint(uint32 maxEpochs) external returns (uint32 processedThroughEpoch);
    function checkpointEpoch() external view returns (uint32);
    function currentEpoch() external view returns (uint32);
    function currentEligibleWeight() external view returns (uint256);
    function tierConfig(uint8 tier) external pure returns (uint40 durationSeconds, uint16 multiplierBps);
    function notifyBoostFee(uint256 amount) external;
}
