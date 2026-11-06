// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrBalanceHistory} from "./IHookrBalanceHistory.sol";

/// @title Hookr drop host, part of the HookRevenue Tokenizer
/// @notice What a `HookrDropBox` needs from the token whose holders it pays: the balance history and a way to
///         record each drop's snapshot block.
interface IHookrDropHost is IHookrBalanceHistory {
    /// @notice The caller may not do this: `snapshot` from anyone but the token's drop box, or, in the revenue token,
    ///         `initialize` or `addDoor` from anyone but the tokenizer, `addAsset` from anyone but the tokenizer or the
    ///         stream manager, the stream manager's calls from anyone else, a claim for a holder by a non-operator.
    error Unauthorized(address caller);

    /// @notice The drop box every drop into this token goes through. Fixed at construction.
    function dropBox() external view returns (address);
    /// @notice Records `clock() - 1` as a snapshot block and returns it with the earning supply at it, what a drop
    ///         is split over. Only the drop box.
    function snapshot() external returns (uint48 snapshotBlock, uint256 supply);
}
