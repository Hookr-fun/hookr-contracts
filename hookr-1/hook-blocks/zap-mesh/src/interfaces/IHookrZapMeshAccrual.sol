// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {IZapSessionTiered} from "zap-relay/interfaces/IZapSessionTiered.sol";
import {ZapMeshTypes} from "../types/ZapMeshTypes.sol";

/// @title Zap mesh accrual
/// @notice ADVISORY module for a source pool whose buy cut feeds a zap mesh, and the only factory of zap meshes and
///         their legs. It binds the same terms as HookrZapAccrual (ZapRelayTypes.ACCRUAL_SCHEMA) and answers the same
///         `vaultRecord` read, for legs, so the deployed HookrGatedRelay admits a leg as a feeder of its target exactly
///         as it admits a zap vault, once this contract is admitted on the root.
interface IHookrZapMeshAccrual is IHookrAdvisory, IZapSessionTiered {
    error InvalidTerms(uint8 code);
    error InvalidPoolConfig(uint8 code);
    error AlreadyBound(address binder, PoolId id);
    error LegMismatch(uint256 index, address deployed, address predicted);

    event AccrualBound(address indexed binder, PoolId indexed id, address indexed mesh, uint24 takePips);
    event MeshCreated(
        address indexed mesh, address indexed creator, address gate, uint8 mode, uint8 split, address sink
    );
    event LegCreated(address indexed mesh, address indexed leg, PoolId indexed target, uint8 index, uint16 weight);

    /// @notice Deploys a mesh for `mesh` at a CREATE2 address keyed by (msg.sender, salt), and one leg per target.
    ///         Permissionless.
    function createMesh(ZapMeshTypes.Mesh calldata mesh, bytes32 salt)
        external
        returns (address vault, address[] memory legs);
    /// @notice The mesh and leg addresses createMesh(mesh, salt) called by `creator` deploys to.
    function predictMesh(address creator, ZapMeshTypes.Mesh calldata mesh, bytes32 salt)
        external
        view
        returns (address vault, address[] memory legs);
    /// @notice Hookr's share of every source cut, fixed at construction.
    function protocolShareBps() external view returns (uint16);
    /// @notice Whether `mesh` was created here.
    function meshRecord(address mesh) external view returns (bool exists);
    /// @notice Whether `leg` was created here, with the target pool and gate it was created for. The gated relay's
    ///         feeder check reads this.
    function vaultRecord(address leg) external view returns (bool exists, PoolId target, address gate);
    /// @notice The frozen cut a binder (the root) stored for a source pool.
    function terms(address binder, PoolId id) external view returns (uint24 takePips, address mesh, bool bound);
}
