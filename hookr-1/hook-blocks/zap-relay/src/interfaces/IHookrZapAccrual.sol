// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {ZapRelayTypes} from "../types/ZapRelayTypes.sol";
import {IZapSessionTiered} from "./IZapSessionTiered.sol";

/// @title Zap accrual advisory and vault factory
/// @notice Source-pool advisory: a fixed quote cut of every buy, credited by the root as a HookrRules claim to the
///         pool's vault. Also the only factory of zap vaults, through the deployer it creates in its constructor. The
///         admitted runtime code hash pins the addresses of that deployer and of the session lens; their code comes
///         from this contract's creation code, which the release checks by reading both code hashes back.
interface IHookrZapAccrual is IHookrAdvisory, IZapSessionTiered {
    error InvalidTerms(uint8 code);
    error InvalidPoolConfig(uint8 code);
    error AlreadyBound(address binder, PoolId id);

    event AccrualBound(address indexed binder, PoolId indexed id, address indexed vault, uint24 takePips);
    event VaultCreated(
        address indexed vault, address indexed creator, PoolId indexed target, address gate, uint8 mode, address sink
    );

    /// @notice Deploys a zap vault for `route` at a CREATE2 address keyed by (msg.sender, salt). Permissionless.
    function createVault(ZapRelayTypes.Route calldata route, bytes32 salt) external returns (address vault);

    /// @notice The address createVault(route, salt) called by `creator` deploys to.
    function predictVault(address creator, ZapRelayTypes.Route calldata route, bytes32 salt)
        external
        view
        returns (address);

    /// @notice Hookr's share of every source cut, fixed at construction; each vault takes at least this and at least
    ///         its Rules' minProtocolShareBps.
    function protocolShareBps() external view returns (uint16);

    /// @notice Whether `vault` was created here, with the target pool and gate it was created for.
    function vaultRecord(address vault) external view returns (bool exists, PoolId target, address gate);

    /// @notice The frozen cut a binder (the root) stored for a source pool.
    function terms(address binder, PoolId id) external view returns (uint24 takePips, address vault, bool bound);
}
