// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @title Doppler hook initializer, the part the Hookr Doppler adapter reads and calls
/// @notice The Doppler Multicurve initializer on Uniswap v4 (`DopplerHookInitializer`, which inherits Doppler's
///         `FeesManager`). It owns the launch's curve positions, collects their LP fees and splits them among the
///         beneficiaries by share (WAD, summing to 1e18 at launch). Only what this adapter uses is declared here;
///         `docs/doppler.md` has the full reading of the verified source.
/// @dev Behaviour the adapter rests on, from the verified source:
///      - `collectFees(poolId)`: anyone; reverts unless the pool's status is `Locked` (2). Collects the curve
///        positions' fees into the initializer, adds them to the cumulated totals, then pays the CALLER's share
///        only (`_releaseFees(poolId, msg.sender)`), in the pool's two currencies (native ETH by a plain call when a
///        side is address zero). Every other beneficiary's share stays owed until it calls or is updated.
///      - `updateBeneficiary(poolId, newBeneficiary)`: moves ALL of the caller's shares to `newBeneficiary`
///        (added to what it holds), paying both their owed fees first. Only the holder's own shares move; nothing
///        else in the contract writes shares after launch. Reverts when `newBeneficiary == msg.sender`.
///      - No owner, no proxy, no override of a share. The Airlock owner can only toggle Doppler hook flags
///        (`setDopplerHookState`), and the asset's timelock (or its delegate) can only change the pool's Doppler
///        hook; graduation (`graduate`) ends fee collection for every beneficiary.
interface IDopplerHookInitializer {
    /// @notice The Doppler Airlock this initializer serves.
    function airlock() external view returns (address);
    /// @notice Collects the pool's curve fees and pays the caller's share. Reverts unless the pool is `Locked`.
    /// @return fees0 What the pool's positions earned in currency0 since the last collection, for everyone.
    /// @return fees1 The same in currency1.
    function collectFees(PoolId poolId) external returns (uint128 fees0, uint128 fees1);
    /// @notice Moves every share the caller holds in `poolId` to `newBeneficiary`.
    function updateBeneficiary(PoolId poolId, address newBeneficiary) external;
    /// @notice Shares (WAD) `beneficiary` holds in `poolId`.
    function getShares(PoolId poolId, address beneficiary) external view returns (uint256);
    /// @notice Every currency0 fee ever collected for `poolId`.
    function getCumulatedFees0(PoolId poolId) external view returns (uint256);
    /// @notice Every currency1 fee ever collected for `poolId`.
    function getCumulatedFees1(PoolId poolId) external view returns (uint256);
    /// @notice `getCumulatedFees0` when `beneficiary` was last paid.
    function getLastCumulatedFees0(PoolId poolId, address beneficiary) external view returns (uint256);
    /// @notice `getCumulatedFees1` when `beneficiary` was last paid.
    function getLastCumulatedFees1(PoolId poolId, address beneficiary) external view returns (uint256);
    /// @notice The pool key stored when the beneficiaries were stored (zero for a pool with none).
    function getPoolKey(PoolId poolId)
        external
        view
        returns (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks);
    /// @notice The launch state of `asset` (the public getter; the two array members are left out by Solidity).
    /// @return numeraire The other side of the pool (address zero for native ETH).
    /// @return totalTokensOnBondingCurve The asset amount on the curve.
    /// @return dopplerHook The pool's Doppler hook (dynamic fee, swap callback, graduation), or zero.
    /// @return graduationDopplerHookCalldata What `graduate` passes the hook.
    /// @return status 0 Uninitialized, 1 Initialized, 2 Locked, 3 Graduated, 4 Exited.
    /// @return poolKey The pool.
    /// @return farTick The tick the price must reach before `graduate` or an exit.
    function getState(address asset)
        external
        view
        returns (
            address numeraire,
            uint256 totalTokensOnBondingCurve,
            address dopplerHook,
            bytes memory graduationDopplerHookCalldata,
            uint8 status,
            PoolKey memory poolKey,
            int24 farTick
        );
    /// @notice The flags the Airlock owner set for a Doppler hook (bit 2 is the graduation callback).
    function isDopplerHookEnabled(address dopplerHook) external view returns (uint256);
}

/// @title Doppler Airlock, the part the Hookr Doppler adapter reads
/// @notice The Doppler launch registry: one record per launched asset.
interface IDopplerAirlock {
    /// @notice The Airlock owner (Doppler's protocol owner, a beneficiary of every pool's minimum share).
    function owner() external view returns (address);
    /// @notice The launch record of `asset`; the adapter reads `timelock`, the only account (with its delegate)
    ///         that may change the pool's Doppler hook.
    function getAssetData(address asset)
        external
        view
        returns (
            address numeraire,
            address timelock,
            address governance,
            address liquidityMigrator,
            address poolInitializer,
            address pool,
            address migrationPool,
            uint256 numTokensToSell,
            uint256 totalSupply,
            address integrator
        );
}
