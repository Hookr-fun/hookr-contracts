// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrRegistry} from "./IHookrRegistry.sol";

/// @title IHookrRoot
/// @notice Interface for HookrRoot, the Uniswap v4 hook that binds admitted Rules and advisory modules to a pool.
interface IHookrRoot {
    /// @notice Returns the immutable Uniswap v4 PoolManager.
    /// @return The PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns the immutable Hookr admission registry.
    /// @return The registry.
    function registry() external view returns (IHookrRegistry);

    /// @notice Returns the pinned Hookr swap router.
    /// @return The router.
    function router() external view returns (address);

    /// @notice Returns the pinned Hookr quoter.
    /// @return The quoter.
    function quoter() external view returns (address);

    /// @notice Returns the curated router whose `msgSender()` is trusted as the swap identity, or zero.
    /// @return The curated router, or zero.
    function curatedRouter() external view returns (address);

    /// @notice Binds admitted modules and initializes one pool. Only an admitted launcher can call.
    /// @param key The pool.
    /// @param config The pool's identity, trusted modules and execution limits.
    /// @param rulesConfig The pool's ABI-encoded rules configuration.
    /// @param advisoryConfig The pool's advisory bind data, empty without an advisory.
    /// @param sqrtPriceX96 The pool's opening price as a sqrt price in Q64.96.
    /// @return The new pool's id.
    function initializePool(
        PoolKey calldata key,
        HookrTypes.PoolConfig calldata config,
        bytes calldata rulesConfig,
        bytes calldata advisoryConfig,
        uint160 sqrtPriceX96
    ) external returns (PoolId);

    /// @notice Returns the immutable configuration of an initialized Hookr pool.
    /// @param id The pool.
    /// @return The pool's configuration.
    function poolConfig(PoolId id) external view returns (HookrTypes.PoolConfig memory);

    /// @notice Returns the commitment to the pool key, configuration and module data.
    /// @param id The pool.
    /// @return The pool's policy hash.
    function policyHash(PoolId id) external view returns (bytes32);

    /// @notice Returns whether this root initialized the pool.
    /// @param id The pool.
    /// @return True when this root initialized the pool.
    function knownPool(PoolId id) external view returns (bool);

    /// @notice Returns the pool being bound during initialization. Zero outside binding.
    /// @return The pool being bound, or zero outside binding.
    function bindingPool() external view returns (PoolId);

    /// @notice Consumes the current swap receipt once. Only the pinned router or quoter can call.
    /// @param id The pool.
    /// @return The swap's execution receipt.
    function takeReceipt(PoolId id) external returns (HookrTypes.ExecutionReceipt memory);
}
