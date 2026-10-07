// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {ZapRelayTypes} from "./types/ZapRelayTypes.sol";
import {IZapVaultDeployer} from "./interfaces/IZapVaultDeployer.sol";
import {HookrZapVault} from "./HookrZapVault.sol";

/// @title Zap vault deployer
/// @notice Holds the zap vault's creation code for one HookrZapAccrual and deploys vaults only for it. The accrual
///         creates this contract in its own constructor, so this contract's address is an immutable of the accrual's
///         admitted runtime code and its code comes from the accrual's creation code: the accrual's admitted code hash
///         pins this deployer, and through it the vault code, exactly as it pins the session lens.
/// @dev Exists only to keep the accrual's runtime small: before, the accrual embedded the vault's creation code and had
///      a few hundred bytes of headroom under the 24,576-byte runtime limit. A vault's address is
///      CREATE2(this, salt, keccak256(vault creation code ++ abi.encode(route))), where the accrual passes
///      salt = keccak256(abi.encode(creator, creatorSalt)). Only the accrual may deploy, so nobody can occupy a
///      creator's vault address ahead of the accrual's createVault.
contract ZapVaultDeployer is HookrReleased, IZapVaultDeployer {
    error OnlyAccrual(address caller);

    /// @inheritdoc IZapVaultDeployer
    address public immutable accrual;

    constructor() {
        accrual = msg.sender;
    }

    /// @notice Deploys a vault for `route` at its CREATE2 address for `salt`. Only the accrual.
    function deploy(ZapRelayTypes.Route calldata route, bytes32 salt) external returns (address) {
        if (msg.sender != accrual) revert OnlyAccrual(msg.sender);
        return address(new HookrZapVault{salt: salt}(route));
    }

    /// @notice The address deploy(route, salt) deploys to.
    function predict(ZapRelayTypes.Route calldata route, bytes32 salt) external view returns (address) {
        bytes32 initHash = keccak256(abi.encodePacked(type(HookrZapVault).creationCode, abi.encode(route)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }
}
