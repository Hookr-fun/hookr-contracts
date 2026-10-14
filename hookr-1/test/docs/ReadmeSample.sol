// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHookrLaneExecutor} from "../../src/interfaces/callback/IHookrLaneExecutor.sol";

/// @notice The smallest executor a lane takes: it recaptures nothing and answers every call with one word.
contract IdleExecutor is IHookrLaneExecutor {
    /// @notice Thrown when a caller other than the root calls `executeArbitrage`.
    error NotTheRoot();

    address public immutable root;

    constructor(address root_) {
        root = root_;
    }

    /// @inheritdoc IHookrLaneExecutor
    function executeArbitrage(PoolKey calldata, address) external view returns (uint256) {
        if (msg.sender != root) revert NotTheRoot();
        return 0;
    }

    /// @inheritdoc IHookrLaneExecutor
    function checkV3PoolsMev(address, address, address, bool) external pure returns (bool) {
        return false;
    }
}
