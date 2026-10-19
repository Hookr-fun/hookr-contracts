// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrBalanceHistory} from "./HookrBalanceHistory.sol";
import {HookrDropBoxDeployer} from "../libraries/HookrDropBoxDeployer.sol";
import {IHookrBalanceHistory} from "../interfaces/IHookrBalanceHistory.sol";
import {IHookrDropHost} from "../interfaces/IHookrDropHost.sol";

/// @title Hookr drop host, part of the HookRevenue Tokenizer
/// @notice The balance history plus its own drop box: what the revenue token inherits so anyone can drop ETH or any
///         ERC-20 for its holders. The box is deployed at construction and fixed; shares sent to the box itself
///         can never be claimed back (no sweep), so they are excluded from the earning supply like the
///         PoolManager's and 0xdead's.
/// @dev The box is created from this token's address through HookrDropBoxDeployer, a linked library, so the box's
///      creation code stays out of the token's. The token's own `_update` (settling its fixed-asset indexes) runs
///      first and then calls `super._update`, which lands here and writes the checkpoints after the balances moved.
abstract contract HookrDropHost is HookrBalanceHistory, IHookrDropHost {
    /// @inheritdoc IHookrDropHost
    address public immutable dropBox;

    constructor() {
        dropBox = HookrDropBoxDeployer.deploy();
    }

    /// @inheritdoc IHookrBalanceHistory
    function earns(address account)
        public
        view
        virtual
        override(HookrBalanceHistory, IHookrBalanceHistory)
        returns (bool)
    {
        return super.earns(account) && account != dropBox;
    }

    /// @inheritdoc IHookrDropHost
    /// @dev One call answers both, so a drop reads the block and its supply in one round trip.
    function snapshot() external returns (uint48 snapshotBlock, uint256 supply) {
        if (msg.sender != dropBox) revert Unauthorized(msg.sender);
        snapshotBlock = _recordSnapshot();
        supply = earningSupplyAt(snapshotBlock);
    }
}
