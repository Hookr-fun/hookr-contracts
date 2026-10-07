// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrVestingMilestoneEscrow
/// @notice Public interface for the vesting-milestone escrow module.
interface IHookrVestingMilestoneEscrow {
    /// @notice The escrow's bounded configuration. Every field is frozen at construction except through the
    ///         owner's slower-only timelocked setters.
    struct Config {
        /// @dev Seconds after funding before any time-based vesting begins.
        uint40 cliffSeconds;
        /// @dev Seconds of linear release after the cliff ends.
        uint40 vestingSeconds;
        /// @dev Pool liquidity (StateLibrary.getLiquidity) that checkpoints must observe held for LIQUIDITY_HOLD;
        ///      0 disables this milestone. The factory refuses a nonzero value, and a raise never switches it on.
        uint128 liquidityThreshold;
        /// @dev Combined pool fee growth (StateLibrary.getFeeGrowthGlobals, both currencies summed) that must be
        ///      reached as a trading-activity proxy; 0 disables this milestone. The factory refuses a nonzero
        ///      value, and a raise never switches it on.
        uint256 volumeThreshold;
        /// @dev Cumulative seconds between consecutive in-band checkpoints (each interval capped at
        ///      MAX_CHECKPOINT_INTERVAL) the pool's tick must have spent inside [rangeTickLower, rangeTickUpper];
        ///      0 disables this milestone. The factory refuses a nonzero value, and a raise never switches it on.
        uint32 timeInRangeSeconds;
        int24 rangeTickLower;
        int24 rangeTickUpper;
        /// @dev Basis points of the subject's total supply (read at fund time) the escrowed allocation may not
        ///      exceed. Composes with the launcher's dev-buy hold cap: the two allocations are independent, so this
        ///      bound keeps a vesting allocation from silently reopening the room the dev-buy cap closed.
        uint16 maxAllocationBps;
    }

    event Funded(address indexed funder, uint256 total, uint40 fundedAt);
    event Released(address indexed to, uint256 amount, uint256 releasedTotal);
    event TimeInRangeCheckpointed(int24 tick, bool inRange, uint32 cumulativeInRangeSeconds);
    event LiquidityCheckpointed(uint128 liquidity, uint40 heldSince);
    event CliffExtended(uint40 previous, uint40 next);
    event VestingExtended(uint40 previous, uint40 next);
    event LiquidityThresholdRaised(uint128 previous, uint128 next);
    event VolumeThresholdRaised(uint256 previous, uint256 next);
    event TimeInRangeThresholdRaised(uint32 previous, uint32 next);
    event ExcessRecovered(address indexed token, address indexed to, uint256 amount);

    error AlreadyFunded();
    error NotFunded();
    error ZeroTotal();
    error AllocationTooLarge(uint256 total, uint256 cap);
    error NothingReleasable();
    error OnlyBeneficiary(address caller);
    error OutOfBounds(uint256 value, uint256 min, uint256 max);
    error NotSlower(uint256 previous, uint256 next);
    error InvalidRange(int24 lower, int24 upper);
    error ManagerUnlocked();
    error NothingToRecover();
    error LiquidityBarAlreadyRaised();
    /// @notice A raise may not switch a milestone on: a bar that was 0 at construction stays 0.
    error MilestoneStaysOff();

    function beneficiary() external view returns (address);
    function subject() external view returns (address);
    function total() external view returns (uint256);
    function released() external view returns (uint256);
    function fundedAt() external view returns (uint40);
    function config() external view returns (Config memory);

    function fund(uint256 amount) external;
    function release() external returns (uint256 amount);
    function releasable() external view returns (uint256);
    function timeVested() external view returns (uint256);
    function milestoneGate() external view returns (uint256);

    function checkpointTimeInRange() external;
    function checkpointLiquidity() external;
    function liquidityMilestoneMet() external view returns (bool);
    function volumeMilestoneMet() external view returns (bool);
    function timeInRangeMilestoneMet() external view returns (bool);

    function recoverExcess(address token) external returns (uint256 amount);
}
