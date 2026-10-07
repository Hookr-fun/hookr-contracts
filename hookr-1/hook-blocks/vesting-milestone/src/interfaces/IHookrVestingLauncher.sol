// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IHookrVestingLauncher
/// @notice The HookrLauncher views HookrVestingMilestoneFactory reads to bind an escrow's pool to its subject. The
///         struct and signatures match HookrLauncher's own, so the live launcher is passed as-is.
interface IHookrVestingLauncher {
    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    function poolManager() external view returns (IPoolManager);
    function poolFamily(PoolId id) external view returns (bytes32);
    function memberCount(bytes32 familyId) external view returns (uint8);
    function position(bytes32 familyId, uint8 member) external view returns (Position memory);
}
