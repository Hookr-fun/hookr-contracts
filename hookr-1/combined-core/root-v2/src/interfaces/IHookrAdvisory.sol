// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";

/// @title IHookrAdvisory
/// @notice Optional bounded advice. Swap and liquidity checks execute through static calls.
interface IHookrAdvisory {
    /// @notice Returns the identifier of the supported module configuration.
    /// @return The configuration schema identifier this module accepts in `bind`.
    function configSchemaHash() external pure returns (bytes32);

    /// @notice Binds immutable pool settings and returns the hash of the exact configuration bytes.
    /// @dev `config` is the frozen pool configuration; `poolConfig(id)` is not readable until initialization ends.
    /// @param key The pool being initialized.
    /// @param config The pool's frozen configuration.
    /// @param data The module's configuration bytes for this pool.
    /// @return configHash The hash of the exact bytes of `data`.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata config, bytes calldata data)
        external
        returns (bytes32 configHash);

    /// @notice Returns whether the liquidity addition is permitted.
    /// @param id The pool.
    /// @param sender The caller of PoolManager.modifyLiquidity.
    /// @return Whether the addition may proceed.
    function beforeAddLiquidity(PoolId id, address sender) external view returns (bool);

    /// @notice Returns bounded surcharge, quote-take and rejection advice before execution.
    /// @param context The authenticated swap context.
    /// @return The advice: an LP fee surcharge and a quote take, each within the pool's advisory caps, the take's
    ///         recipient (nonzero when it takes) and whether to reject the swap. A fail-open advisory may neither
    ///         reject nor take (HookrRoot._advice).
    function beforeSwap(HookrTypes.SwapContext calldata context) external view returns (HookrTypes.Advice memory);

    /// @notice Returns advice from completed pool deltas. It cannot change the completed LP fee.
    /// @dev An after-phase quote take is supported only for exact-input sells and exact-output buys.
    /// @param context The authenticated swap context.
    /// @param amount0 The pool's swap delta in currency0.
    /// @param amount1 The pool's swap delta in currency1.
    /// @return The advice: lpFeeSurchargePips must be 0 and reject false; a quoteTakePips only on exact-input sells
    ///         and exact-output buys, naming the before-phase's recipient when both phases take; anything else reverts
    ///         InvalidModuleResult.
    function afterSwap(HookrTypes.SwapContext calldata context, int128 amount0, int128 amount1)
        external
        view
        returns (HookrTypes.Advice memory);
}
