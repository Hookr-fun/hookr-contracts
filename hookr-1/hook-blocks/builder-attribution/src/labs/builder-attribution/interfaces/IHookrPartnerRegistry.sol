// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HookrAttributionTypes} from "../types/HookrAttributionTypes.sol";

/// @title Partner registry surface used by the tax advisory and the attribution launcher
interface IHookrPartnerRegistry {
    /// @notice Returns the attribution of a pool; `recorded` is false for an unattributed pool.
    function attribution(bytes32 poolId) external view returns (HookrAttributionTypes.Attribution memory);

    /// @notice Verifies a voucher for `caller` and records the pool's attribution and vault. Bound launcher only.
    function consume(
        HookrAttributionTypes.Voucher calldata voucher,
        bytes calldata signature,
        address caller,
        address vault
    ) external returns (HookrAttributionTypes.Attribution memory);

    /// @notice Initial treasury payee written into every vault.
    function treasuryBeneficiary() external view returns (address);

    /// @notice Initial HOOKR buy/burn payee written into every vault.
    function buyBurnBeneficiary() external view returns (address);

    /// @notice Returns a registered partner record; unknown ids return zero fields.
    function partner(bytes32 partnerId) external view returns (HookrAttributionTypes.Partner memory);
}
