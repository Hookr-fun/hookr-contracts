// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HookrReleaseCreate2FactoryV1
/// @notice Reusable deterministic deployer for reviewed Hookr release components.
/// @dev Only the EOA that creates this factory may submit initcode. That removes the public
///      salt-squatting surface of permissionless singleton factories without adding an owner,
///      rotation, proxy, arbitrary-call, delegatecall, payable, or fund-custody surface.
contract HookrReleaseCreate2FactoryV1 {
    address public immutable authorizedDeployer;

    event Deployed(bytes32 indexed salt, bytes32 indexed initCodeHash, address indexed deployed);

    error NotAuthorizedDeployer();
    error EmptyInitCode();
    error DeploymentFailed();

    constructor() {
        authorizedDeployer = msg.sender;
    }

    function contractName() external pure returns (string memory) {
        return "HookrReleaseCreate2FactoryV1";
    }

    function contractVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function deploy(bytes32 salt, bytes calldata initCode) external returns (address deployed) {
        if (msg.sender != authorizedDeployer) revert NotAuthorizedDeployer();
        if (initCode.length == 0) revert EmptyInitCode();
        bytes32 initCodeHash = keccak256(initCode);
        address predicted = _computeAddress(salt, initCodeHash);
        if (predicted.code.length != 0) revert DeploymentFailed();
        bytes memory code = initCode;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 0x20), mload(code), salt)
        }
        if (deployed != predicted || deployed.code.length == 0) revert DeploymentFailed();
        emit Deployed(salt, initCodeHash, deployed);
    }

    function computeAddress(bytes32 salt, bytes32 initCodeHash) external view returns (address deployed) {
        deployed = _computeAddress(salt, initCodeHash);
    }

    function _computeAddress(bytes32 salt, bytes32 initCodeHash) private view returns (address deployed) {
        deployed =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
