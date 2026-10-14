// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LiveContracts} from "./LiveContracts.sol";

/// @title Fork
/// @notice Forks Robinhood Chain (4663) at the one block every figure is measured at. The rpc alias `robinhood` is
///         defined in the reader's own Foundry config, with the URL in an environment variable (README.md): this
///         repository keeps no RPC table.
abstract contract Fork is Test, LiveContracts {
    /// @dev The block the bench forks. The fork needs an archive node for this block.
    uint256 internal constant FORK_BLOCK = 87_300_000;
    /// @dev Seconds between parent blocks on 4663, whose `block.number` is the parent chain's height.
    uint256 internal constant BLOCK_SECONDS = 12;

    /// @dev Forks the chain; a test contract that sets more up calls this first.
    function setUp() public virtual {
        vm.createSelectFork("robinhood", FORK_BLOCK);
    }

    /// @dev Moves to the next parent block, so no two measured swaps share a block's per-block state.
    function _nextBlock() internal {
        _advance(1, BLOCK_SECONDS);
    }

    /// @dev Moves `blocks` parent blocks and `seconds_` seconds on.
    function _advance(uint256 blocks, uint256 seconds_) internal {
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + seconds_);
    }
}
