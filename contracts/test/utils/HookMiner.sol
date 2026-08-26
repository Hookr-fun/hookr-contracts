// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Mines a CREATE2 salt whose resulting address carries exactly the requested
///         Uniswap v4 hook permission bits in its low 14 bits.
library HookMiner {
    uint160 internal constant FLAG_MASK = 0x3FFF;

    function find(address deployer, uint160 flags, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCodeWithArgs);
        for (uint256 i = 0; i < 1_000_000; i++) {
            salt = bytes32(i);
            hookAddress =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            // Avoid an RPC code lookup for every counterfactual address. CREATE2 itself rejects a
            // collision, while test VMs begin from a clean local nonce/state namespace.
            if (uint160(hookAddress) & FLAG_MASK == flags) {
                return (hookAddress, salt);
            }
        }
        revert("HookMiner: no salt found");
    }
}
