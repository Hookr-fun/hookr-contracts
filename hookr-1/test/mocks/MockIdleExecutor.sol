// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice An executor that does nothing: no partnerBps(), no checkV3PoolsMev(), only the lane call.
contract MockIdleExecutor {
    function executeArbitrage(PoolKey calldata, address) external pure returns (uint256) {
        return 0;
    }
}
