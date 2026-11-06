// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EndKind} from "../types/EndKind.sol";

/// @title Hookr revenue door
/// @notice What every door the tokenizer makes answers: the revenue token it pays, its pull, and when its stream ends.
///         The forwarder, the FEEB adapter, the v4 and v3 position doors and the revenue token door implement it; an
///         outside right plugs in through `IHookrRevenueSource` instead.
/// @dev `pull` takes calls from its revenue token alone (`OnlyRevenueToken` otherwise), so every pull happens inside
///      the token's sync, where Hookr's leg is measured. It forwards what it collected to the token (listed assets) and
///      the token's drop box (anything else), and never reverts on an empty collection. It never calls back into the
///      token beyond plain transfers and the reads `isAsset`, `dropBox`, `legOf` and `legCollector`; the only other
///      call it makes on the token's side is the drop box's `IHookrDropBox.dropStray`. A door holds its right until
///      its term ends and returns it to `returnTo` then; a door whose right is locked forever never returns it.
interface IHookrRevenueDoor {
    /// @notice A pull came from someone other than the revenue token.
    error OnlyRevenueToken(address caller);
    /// @notice The term moves only later: `given` is not after `current`.
    error TermNotExtended(uint64 given, uint64 current);

    /// @notice The term now ends at `unlock`, a timestamp (`type(uint64).max` is forever).
    /// @param unlock The new unlock timestamp.
    event TermExtended(uint64 unlock);

    /// @notice The revenue token every pull pays.
    /// @return The revenue token.
    function revenueToken() external view returns (address);
    /// @notice When the stream ends: the kind and, for a date, the timestamp or parent block.
    /// @return kind How the stream ends.
    /// @return endsAt The end timestamp or parent block, or zero.
    function ends() external view returns (EndKind kind, uint64 endsAt);
    /// @notice Collects what the right has earned and forwards it to the revenue token. Only the revenue token.
    function pull() external;
}
