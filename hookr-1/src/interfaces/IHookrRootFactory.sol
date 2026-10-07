// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrPairRoot} from "./IHookrPairRoot.sol";
import {IHookrFactoryRegistry} from "./IHookrFactoryRegistry.sol";

/// @title IHookrRootFactory
/// @notice Permissionless deployer of Hookr pair roots. One root, one pool. A root's advisory, if any, is one the
///         registry admits for the factory through its timelock.
interface IHookrRootFactory {
    /// @notice A pair root was deployed and its pool opened.
    /// @param root The pair root.
    /// @param id The pool.
    /// @param deployer The account that deployed it.
    /// @param salt The deployer's salt.
    event PairRootDeployed(address indexed root, PoolId indexed id, address indexed deployer, bytes32 salt);

    /// @notice The factory's PoolManager or registry holds no code.
    error InvalidWiring();
    /// @notice The root's address `root` does not carry exactly the pair root permission flags.
    error InvalidHookAddress(address root);
    /// @notice A root already exists at `root`.
    error RootExists(address root);
    /// @notice The registry does not admit `advisory` for this factory, or the admission does not suit the root.
    error AdvisoryNotAdmitted(address advisory);
    /// @notice `advisory` no longer runs the runtime codehash its admission pinned.
    error AdvisoryCodeHashMismatch(address advisory);

    /// @notice Returns the Uniswap v4 PoolManager every root is wired to.
    /// @return The PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns the registry every root is registered in.
    /// @return The registry.
    function registry() external view returns (IHookrFactoryRegistry);

    /// @notice Returns keccak256 of the pair root creation code, before constructor arguments.
    /// @return The hash of the creation code.
    function pairRootCreationCodeHash() external view returns (bytes32);

    /// @notice Returns the CREATE2 salt used for `deployer` and `salt`.
    /// @param deployer The deploying account.
    /// @param salt The deployer's salt.
    /// @return The CREATE2 salt.
    function deploySalt(address deployer, bytes32 salt) external pure returns (bytes32);

    /// @notice Returns the CREATE2 init code hash for `params`.
    /// @param params The root's construction parameters.
    /// @return The CREATE2 init code hash.
    function initCodeHash(IHookrPairRoot.Params calldata params) external view returns (bytes32);

    /// @notice Returns the address `deployer` gets from `deploy(salt, params, ...)`.
    /// @param deployer The deploying account.
    /// @param salt The deployer's salt.
    /// @param params The root's construction parameters.
    /// @return The address the root deploys to.
    function computeAddress(address deployer, bytes32 salt, IHookrPairRoot.Params calldata params)
        external
        view
        returns (address);

    /// @notice Deploys a pair root, registers it, binds its pool in the advisory with `advisoryData` and initializes
    ///         the pool at `sqrtPriceX96`.
    /// @dev The root address must carry exactly the pair root permission flags in its low 14 bits. Without an
    ///      advisory, `advisoryData` must be empty. With one, the registry must admit it for this factory, and for a
    ///      fail-open root the admission must be fail-open, fee-only and without a quote take.
    /// @param salt The deployer's salt.
    /// @param params The root's construction parameters.
    /// @param sqrtPriceX96 The pool's opening price as a sqrt price in Q64.96.
    /// @param advisoryData The advisory's parameters for the pool; empty without an advisory.
    /// @return root The deployed root.
    /// @return id The pool the root serves.
    function deploy(
        bytes32 salt,
        IHookrPairRoot.Params calldata params,
        uint160 sqrtPriceX96,
        bytes calldata advisoryData
    ) external returns (address root, PoolId id);
}
