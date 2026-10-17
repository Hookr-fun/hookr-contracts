// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IHookrBuybackRouter
/// @notice The slice of `HookrRouter` this contract needs: a bounded single-pool swap.
interface IHookrBuybackRouter {
    struct Swap {
        PoolKey key;
        bool zeroForOne;
        int128 amountSpecified;
        uint128 amountBound;
        uint160 sqrtPriceLimitX96;
        address recipient;
        uint256 deadline;
    }

    function swap(Swap calldata params, address engagement, uint256[] calldata campaigns)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut);
}
