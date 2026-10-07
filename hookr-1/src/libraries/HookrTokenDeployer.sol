// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrToken} from "../support/HookrToken.sol";

/// @title HookrTokenDeployer
/// @notice Creates the HookrTokens HookrLauncher launches and predicts their addresses.
/// @dev An external (linked) library, so HookrToken's creation code sits here and not in the launcher's runtime. It is
///      deployed through CREATE3 and linked into the launcher's bytecode before the launcher is deployed, as
///      HookrPaymasterAdmin is into the paymaster. The launcher reaches `deploy` by DELEGATECALL: CREATE2 runs from the
///      launcher's address and `address(this)`, the token's first holder, is the launcher, so every token keeps the
///      address and the first holder it had when the launcher created tokens itself. `deploy` changes state, so solc's
///      library call guard refuses it on any call but a DELEGATECALL. `predict` is a pure function of its inputs.
library HookrTokenDeployer {
    /// @notice Deploys a HookrToken whose whole `supply` goes to the calling launcher, at CREATE2 salt
    ///         keccak256(abi.encode(creator, salt)) from the launcher, so other creators cannot consume `salt`.
    /// @dev Reverts as HookrToken's constructor does for empty or long metadata and a zero supply, and without data when
    ///      the address is already taken (CREATE2 then spends the gas it was given).
    /// @param creator The launch caller the salt is namespaced by.
    /// @param salt The creator's CREATE2 salt.
    /// @param name The token's name, 1 to 64 bytes.
    /// @param symbol The token's symbol, 1 to 16 bytes.
    /// @param supply The fixed supply, above zero.
    /// @return token The new token.
    function deploy(address creator, bytes32 salt, string calldata name, string calldata symbol, uint256 supply)
        external
        returns (address token)
    {
        token = address(new HookrToken{salt: keccak256(abi.encode(creator, salt))}(name, symbol, supply, address(this)));
    }

    /// @notice The address `deploy` creates when `launcher` runs it for the same inputs.
    /// @param launcher The launcher that runs `deploy`, the CREATE2 deployer and the token's first holder.
    /// @param creator The launch caller the salt is namespaced by.
    /// @param salt The creator's CREATE2 salt.
    /// @param name The token's name.
    /// @param symbol The token's symbol.
    /// @param supply The fixed supply.
    /// @return The predicted token address.
    function predict(
        address launcher,
        address creator,
        bytes32 salt,
        string calldata name,
        string calldata symbol,
        uint256 supply
    ) external pure returns (address) {
        bytes32 initHash = keccak256(
            abi.encodePacked(type(HookrToken).creationCode, abi.encode(name, symbol, supply, launcher))
        );
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), launcher, keccak256(abi.encode(creator, salt)), initHash))
                )
            )
        );
    }
}
