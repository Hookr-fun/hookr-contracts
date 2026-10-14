// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice Library linking for the CREATE3 release.
/// @dev Five release contracts call external libraries: HookrRegistry calls HookrRegistryAdmin and
///      HookrRegistryChecks, and HookrRegistryAdmin calls HookrRegistryChecks too; HookrLauncher calls HookrLaunchChecks
///      and HookrTokenDeployer; HookrPrograms calls HookrProgramsAdmin; HookrPaymaster calls HookrAccountCalls and
///      HookrPaymasterAdmin. Each library deploys through the CREATE3 factory before the contracts that call it. The
///      exported templates stay unlinked (their standard JSON has no `libraries` setting, so the metadata hash
///      reproduces for a full explorer match); each library's CREATE3 address replaces its placeholder text before
///      deployment, matched by the library's fully qualified name.
library HookrLink {
    string internal constant REGISTRY_CHECKS = "src/libraries/HookrRegistryChecks.sol:HookrRegistryChecks";
    string internal constant REGISTRY_ADMIN = "src/libraries/HookrRegistryAdmin.sol:HookrRegistryAdmin";
    string internal constant LAUNCH_CHECKS = "src/libraries/HookrLaunchChecks.sol:HookrLaunchChecks";
    string internal constant TOKEN_DEPLOYER = "src/libraries/HookrTokenDeployer.sol:HookrTokenDeployer";
    string internal constant PROGRAMS_ADMIN = "src/libraries/HookrProgramsAdmin.sol:HookrProgramsAdmin";
    string internal constant ACCOUNT_CALLS = "src/libraries/HookrAccountCalls.sol:HookrAccountCalls";
    string internal constant PAYMASTER_ADMIN = "src/libraries/HookrPaymasterAdmin.sol:HookrPaymasterAdmin";

    error ImmutableOutOfRange(uint256 start, uint256 length);
    error ImmutableAlreadySet(uint256 start);

    /// @notice solc's placeholder: "__$" + the first 17 bytes of keccak256(sourceUnit:Library) as hex + "$__".
    function placeholder(string memory qualified) internal pure returns (string memory) {
        bytes32 digest = keccak256(bytes(qualified));
        bytes memory out = new bytes(40);
        out[0] = "_";
        out[1] = "_";
        out[2] = "$";
        for (uint256 i; i < 17; ++i) {
            out[3 + 2 * i] = _nibble(uint8(digest[i]) >> 4);
            out[4 + 2 * i] = _nibble(uint8(digest[i]) & 0x0f);
        }
        out[37] = "$";
        out[38] = "_";
        out[39] = "_";
        return string(out);
    }

    /// @notice Lowercase hex of an address without the 0x prefix: the text that replaces a placeholder.
    function hex40(address account) internal pure returns (string memory) {
        bytes20 raw = bytes20(account);
        bytes memory out = new bytes(40);
        for (uint256 i; i < 20; ++i) {
            out[2 * i] = _nibble(uint8(raw[i]) >> 4);
            out[2 * i + 1] = _nibble(uint8(raw[i]) & 0x0f);
        }
        return string(out);
    }

    /// @notice The runtime a library with state-changing external functions holds once deployed at `addr`: solc's call
    ///         guard keeps the deploy address in the immutable `library_deploy_address`, a 32-byte word at `start`
    ///         (the artifact's `deployedBytecode.immutableReferences`) that the compiled runtime leaves zero.
    function withDeployAddress(bytes memory code, uint256 start, address addr) internal pure returns (bytes memory) {
        if (start + 32 > code.length) revert ImmutableOutOfRange(start, code.length);
        bytes32 word;
        assembly ("memory-safe") {
            word := mload(add(add(code, 32), start))
        }
        if (word != bytes32(0)) revert ImmutableAlreadySet(start);
        bytes32 value = bytes32(uint256(uint160(addr)));
        assembly ("memory-safe") {
            mstore(add(add(code, 32), start), value)
        }
        return code;
    }

    /// @notice How many times `account` appears as 20 consecutive bytes of `code`.
    function occurrences(bytes memory code, address account) internal pure returns (uint256 count) {
        bytes20 target = bytes20(account);
        for (uint256 i; i + 20 <= code.length; ++i) {
            bytes20 window;
            assembly ("memory-safe") {
                window := mload(add(add(code, 32), i))
            }
            if (window == target) ++count;
        }
    }

    function _nibble(uint8 value) private pure returns (bytes1) {
        return bytes1(value < 10 ? value + 48 : value + 87);
    }
}
