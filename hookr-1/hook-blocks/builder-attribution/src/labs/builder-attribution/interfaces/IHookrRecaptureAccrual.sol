// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IHookrRecaptureAccrual
/// @dev The recapture surface of a pool's Rules the launcher uses: its liquidity owner accrual.
interface IHookrRecaptureAccrual {
    function claimPool(PoolId id, address to) external returns (uint256);
}
