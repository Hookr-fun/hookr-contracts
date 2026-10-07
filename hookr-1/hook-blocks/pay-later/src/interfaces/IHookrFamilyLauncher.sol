// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";

/// @title Hookr family launcher, the part Pay Later uses
/// @notice The subset of the Hookr 1 `HookrLauncher` ABI that a contract family owner needs: read a family,
///         collect its LP fees, and hand the family on through the two-step transfer.
/// @dev Mirrors the Hookr 1 `HookrLauncher` exactly (same selectors, same `Position` layout). The release ships no
///      separate interface file for the Launcher, so this file declares the functions it calls instead of compiling
///      the Launcher into the vault.
interface IHookrFamilyLauncher {
    /// @notice A member's managed position, as `HookrLauncher.position` returns it.
    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @notice The Uniswap v4 PoolManager every family position lives in.
    function poolManager() external view returns (IPoolManager);

    /// @notice The Hookr registry the Launcher reads roots and launchers from.
    function registry() external view returns (IHookrRegistry);

    /// @notice Current owner of a family. Unknown families return zero.
    function familyOwner(bytes32 familyId) external view returns (address);

    /// @notice Address that may accept a pending family transfer (or zero) and the current owner's fee form.
    function pendingFamilyOwner(bytes32 familyId) external view returns (address pendingOwner, uint16 claims);

    /// @notice Number of pools in the family (one to eight).
    function memberCount(bytes32 familyId) external view returns (uint8);

    /// @notice A member's managed position. Unknown members return zero fields.
    function position(bytes32 familyId, uint8 member) external view returns (Position memory);

    /// @notice Removes liquidity, or with `liquidity == 0` collects the member's accrued LP fees. Owner only.
    /// @dev The PoolManager pays `recipient` directly: ERC20s by transfer, native ETH by a call.
    function withdraw(
        bytes32 familyId,
        uint8 member,
        uint128 liquidity,
        uint256 min0,
        uint256 min1,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice `withdraw`, delivering currency0 (bit 0) and/or currency1 (bit 1) as PoolManager ERC-6909 claims.
    ///         `claims == 0` is exactly `withdraw`.
    function withdrawWithClaims(
        bytes32 familyId,
        uint8 member,
        uint128 liquidity,
        uint256 min0,
        uint256 min1,
        address recipient,
        uint8 claims,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Starts the two-step transfer of every family position. `claims` bits (2i, 2i+1) pay member i's
    ///         accrued fees to the current owner as PoolManager ERC-6909 claims when the new owner accepts.
    function transferFamily(bytes32 familyId, address newOwner, uint16 claims) external;

    /// @notice Completes a pending transfer; the previous owner is paid its accrued fees first.
    function acceptFamily(bytes32 familyId) external;

    /// @notice Burns the caller's PoolManager ERC-6909 claim and pays `recipient` exactly `amount`.
    function redeem(Currency currency, uint256 amount, address recipient) external;
}
