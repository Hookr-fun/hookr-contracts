// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice Finds a CREATE2 salt whose resulting address carries the hook flags in its low fourteen
///         bits. A labs copy for tests and prototypes; the release mines through
///         `HookrReleaseCreate2FactoryV1`, which this is not.
library HookMiner {
    uint256 internal constant MAX_LOOP = 200_000;

    error NoSaltFound(uint160 flags);

    /// @param deployer The address that will run CREATE2: the test contract, or a factory.
    /// @param flags The exact low-fourteen-bit pattern the address must carry.
    /// @param creationCode `type(Hook).creationCode`.
    /// @param constructorArgs `abi.encode(...)` of the constructor arguments.
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        flags = flags & Hooks.ALL_HOOK_MASK;
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i = 0; i < MAX_LOOP; i++) {
            hookAddress = computeAddress(deployer, bytes32(i), initCodeHash);
            if (uint160(hookAddress) & Hooks.ALL_HOOK_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(i));
            }
        }
        revert NoSaltFound(flags);
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, initCodeHash)))));
    }
}
