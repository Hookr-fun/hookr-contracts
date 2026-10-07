// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HookrCloneArgs
/// @notice ERC-1167 minimal proxies with immutable arguments appended to the runtime code.
/// @dev The creation code is byte-for-byte OpenZeppelin 5.1's `cloneDeterministicWithImmutableArgs`
///      (PUSH2 length, CODECOPY, RETURN, then the 45-byte ERC-1167 runtime and the arguments). The arguments are
///      never executed: the proxy runtime ends in RETURN/REVERT before them. Because the arguments are part of the
///      runtime code, the clone's code hash commits to every frozen term, which is what a reviewer pins.
library HookrCloneArgs {
    /// @dev ERC-1167 runtime length; the arguments start at this code offset.
    uint256 internal constant RUNTIME_PREFIX = 45;

    error CloneArgumentsTooLong();
    error CloneFailed();

    /// @notice Returns the creation code of a clone of `implementation` carrying `args`.
    function initCode(address implementation, bytes memory args) internal pure returns (bytes memory) {
        if (args.length > 24_531) revert CloneArgumentsTooLong();
        return abi.encodePacked(
            hex"61",
            uint16(args.length + RUNTIME_PREFIX),
            hex"3d81600a3d39f3363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91602b57fd5bf3",
            args
        );
    }

    /// @notice Deploys a clone with CREATE2. Reverts if the address is already occupied.
    function deploy(address implementation, bytes memory args, bytes32 salt) internal returns (address instance) {
        bytes memory code = initCode(implementation, args);
        assembly ("memory-safe") {
            instance := create2(0, add(code, 32), mload(code), salt)
        }
        if (instance == address(0)) revert CloneFailed();
    }

    /// @notice Predicts the CREATE2 address of a clone deployed by `deployer`.
    function predict(address implementation, bytes memory args, bytes32 salt, address deployer)
        internal
        pure
        returns (address)
    {
        bytes32 hash =
            keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(initCode(implementation, args))));
        return address(uint160(uint256(hash)));
    }

    /// @notice Reads `length` argument bytes from the currently executing clone's own code.
    /// @dev Must run in the implementation's code under DELEGATECALL from the clone, so `address()` is the clone.
    function read(uint256 length) internal view returns (bytes memory result) {
        result = new bytes(length);
        assembly ("memory-safe") {
            extcodecopy(address(), add(result, 32), RUNTIME_PREFIX, length)
        }
    }
}
