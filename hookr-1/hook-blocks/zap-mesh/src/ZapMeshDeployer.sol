// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {HookrZapMeshVault} from "./HookrZapMeshVault.sol";
import {ZapMeshLeg} from "./ZapMeshLeg.sol";
import {ZapMeshTypes} from "./types/ZapMeshTypes.sol";

/// @title Zap mesh leg deployer
/// @notice Holds the leg's creation code and deploys legs only for its accrual, at CREATE2 addresses keyed by the mesh
///         and the route index, so a mesh can name its legs before they exist.
contract ZapMeshLegDeployer is HookrReleased {
    error OnlyAccrual(address caller);

    /// @notice The HookrZapMeshAccrual that deployed this contract; the only caller of deploy.
    address public immutable accrual;

    constructor() {
        accrual = msg.sender;
    }

    /// @notice Deploys route `index`'s leg for `mesh`. Only the accrual.
    function deploy(address mesh, uint8 index) external returns (address) {
        if (msg.sender != accrual) revert OnlyAccrual(msg.sender);
        return address(new ZapMeshLeg{salt: _salt(mesh, index)}(mesh, index));
    }

    /// @notice The address deploy(mesh, index) deploys to.
    function predict(address mesh, uint8 index) external view returns (address) {
        bytes32 initHash = keccak256(abi.encodePacked(type(ZapMeshLeg).creationCode, abi.encode(mesh, index)));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(mesh, index), initHash))))
        );
    }

    function _salt(address mesh, uint8 index) private pure returns (bytes32) {
        return keccak256(abi.encode(mesh, index));
    }
}

/// @title Zap mesh deployer
/// @notice Holds the mesh's creation code and deploys meshes only for its accrual. Each mesh reads the accrual and the
///         leg deployer from this contract in its constructor.
contract ZapMeshDeployer is HookrReleased {
    error OnlyAccrual(address caller);

    /// @notice The HookrZapMeshAccrual that deployed this contract; the only caller of deploy.
    address public immutable accrual;
    /// @notice The leg deployer whose CREATE2 addresses every mesh's legs take.
    address public immutable legDeployer;

    constructor(address legDeployer_) {
        accrual = msg.sender;
        legDeployer = legDeployer_;
    }

    /// @notice Deploys a mesh for `mesh` at its CREATE2 address for `salt`. Only the accrual.
    function deploy(ZapMeshTypes.Mesh calldata mesh, bytes32 salt) external returns (address) {
        if (msg.sender != accrual) revert OnlyAccrual(msg.sender);
        return address(new HookrZapMeshVault{salt: salt}(mesh));
    }

    /// @notice The address deploy(mesh, salt) deploys to.
    function predict(ZapMeshTypes.Mesh calldata mesh, bytes32 salt) external view returns (address) {
        bytes32 initHash = keccak256(abi.encodePacked(type(HookrZapMeshVault).creationCode, abi.encode(mesh)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }
}
