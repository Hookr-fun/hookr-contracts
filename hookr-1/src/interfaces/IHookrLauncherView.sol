// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IHookrLauncherView
/// @notice The launcher getters the compliance guard reads; HookrLauncher implements them.
/// @dev `poolFamily` and `familyOwner` are set before `initializePool`; `familyOwner` is the only address allowed to add
/// liquidity and is always the current owner, never a pending one. `launchBuyPool` is optional: a launcher without it
/// gets no launch buy past the guard.
interface IHookrLauncherView {
    /// @notice Returns the family of a launched pool, or zero. Selector 0x1616229e.
    /// @param id The pool.
    /// @return The pool's family, or zero.
    function poolFamily(PoolId id) external view returns (bytes32);

    /// @notice Returns the current owner of a family, or zero. Selector 0xeff13096.
    /// @param familyId The family.
    /// @return The family's current owner, or zero.
    function familyOwner(bytes32 familyId) external view returns (address);

    /// @notice Returns the pool whose launch buy the launcher is swapping right now, or zero. Transient: nonzero only
    ///         inside that swap. Selector 0x768065e9.
    /// @return The pool whose launch buy is being swapped, or zero.
    function launchBuyPool() external view returns (PoolId);
}
