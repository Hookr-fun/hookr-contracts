// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrFamilyLauncher} from "./interfaces/IHookrFamilyLauncher.sol";
import {PayLaterTerms} from "./PayLaterTerms.sol";
import {PayLaterVault} from "./PayLaterVault.sol";

/// @title Pay Later vault deployer
/// @notice Holds the vault's creation code on behalf of one `PayLaterFactory`, so the factory's own runtime stays far
///         under the 24,576-byte limit. Deploys a vault only when that factory asks, at CREATE2 salt
///         keccak256(familyId, beneficiary): one vault per family and beneficiary.
/// @dev Created by the factory's constructor (so `factory` is fixed at birth); holds no funds and has no owner.
contract PayLaterVaultDeployer {
    /// @notice The only caller allowed to deploy vaults.
    address public immutable factory;

    error NotFactory(address caller);

    constructor() {
        factory = msg.sender;
    }

    /// @notice Deploys a vault for `familyId` and `beneficiary` at its deterministic address. Factory only.
    function deploy(
        IHookrFamilyLauncher launcher,
        bytes32 familyId,
        uint8 member,
        address beneficiary,
        PayLaterTerms.Terms calldata terms,
        uint16 protocolShareBps
    ) external returns (address) {
        if (msg.sender != factory) revert NotFactory(msg.sender);
        return address(
            new PayLaterVault{salt: salt(familyId, beneficiary)}(
                launcher, familyId, member, beneficiary, terms, protocolShareBps
            )
        );
    }

    /// @notice Address `deploy` would use for these arguments.
    function predict(
        IHookrFamilyLauncher launcher,
        bytes32 familyId,
        uint8 member,
        address beneficiary,
        PayLaterTerms.Terms calldata terms,
        uint16 protocolShareBps
    ) external view returns (address) {
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(PayLaterVault).creationCode,
                abi.encode(launcher, familyId, member, beneficiary, terms, protocolShareBps)
            )
        );
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt(familyId, beneficiary), initHash)))
            )
        );
    }

    /// @notice The CREATE2 salt of the vault for `familyId` and `beneficiary`.
    function salt(bytes32 familyId, address beneficiary) public pure returns (bytes32) {
        return keccak256(abi.encode(familyId, beneficiary));
    }
}
