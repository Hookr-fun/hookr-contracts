// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrPairRoot} from "../interfaces/IHookrPairRoot.sol";
import {IHookrFactoryRegistry} from "../interfaces/IHookrFactoryRegistry.sol";
import {IHookrRootFactory} from "../interfaces/IHookrRootFactory.sol";
import {HookrPairRoot} from "./HookrPairRoot.sol";

/// @title HookrRootFactory
/// @notice Permissionless CREATE2 deployer of Hookr pair roots. Deploys, registers, binds the advisory and initializes
///         in one call.
/// @dev The CREATE2 salt binds the caller, so a salt mined for one deployer yields a different address for any other.
///      A root's advisory must be admitted for this factory in the registry: kind ADVISORY, the admitted runtime
///      codehash, the root's advisory cap within the admitted maxLpFeePips and its advisory gas within the admitted
///      gas limit. A fail-open root also needs a fail-open, fee-only admission without a quote take, the rule HookrRoot
///      applies when it binds a fail-open advisory. The factory holds no funds and no configuration beyond its
///      immutables.
contract HookrRootFactory is HookrReleased, IHookrRootFactory {
    /// @notice Permission flags every pair root address carries in its low 14 bits.
    uint160 public constant PERMISSION_FLAGS = 0x2080;
    /// @notice Role identifier of this contract in the Hookr release.
    bytes32 public constant ROLE = keccak256("hookr.root.factory");

    /// @inheritdoc IHookrRootFactory
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrRootFactory
    IHookrFactoryRegistry public immutable registry;
    /// @inheritdoc IHookrRootFactory
    bytes32 public immutable pairRootCreationCodeHash;

    constructor(IPoolManager manager, IHookrFactoryRegistry registry_) {
        if (address(manager).code.length == 0 || address(registry_).code.length == 0) revert InvalidWiring();
        poolManager = manager;
        registry = registry_;
        pairRootCreationCodeHash = keccak256(type(HookrPairRoot).creationCode);
    }

    /// @inheritdoc IHookrRootFactory
    function deploySalt(address deployer, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(deployer, salt));
    }

    /// @inheritdoc IHookrRootFactory
    function initCodeHash(IHookrPairRoot.Params calldata params) public view returns (bytes32) {
        return keccak256(_initCode(params));
    }

    /// @inheritdoc IHookrRootFactory
    function computeAddress(address deployer, bytes32 salt, IHookrPairRoot.Params calldata params)
        external
        view
        returns (address)
    {
        return _address(deploySalt(deployer, salt), initCodeHash(params));
    }

    /// @inheritdoc IHookrRootFactory
    /// @dev A constructor revert bubbles. The root is registered before it opens, so an advisory can tell a
    ///      registered root from any other caller when the root binds its pool.
    function deploy(
        bytes32 salt,
        IHookrPairRoot.Params calldata params,
        uint160 sqrtPriceX96,
        bytes calldata advisoryData
    ) external returns (address root, PoolId id) {
        if (params.advisory != address(0)) _checkAdvisory(params);
        bytes32 finalSalt = deploySalt(msg.sender, salt);
        bytes memory initCode = _initCode(params);
        address predicted = _address(finalSalt, keccak256(initCode));
        if (uint160(predicted) & 0x3fff != PERMISSION_FLAGS) revert InvalidHookAddress(predicted);
        if (predicted.code.length != 0) revert RootExists(predicted);
        assembly ("memory-safe") {
            root := create2(0, add(initCode, 32), mload(initCode), finalSalt)
            if iszero(root) {
                let p := mload(0x40)
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
        registry.registerFactoryRoot(root, params.advisory);
        HookrPairRoot(root).open(sqrtPriceX96, advisoryData);
        id = HookrPairRoot(root).poolId();
        emit PairRootDeployed(root, id, msg.sender, salt);
    }

    /// @dev Reverts unless the registry admits `params.advisory` for this factory with the advisory's current runtime
    ///      codehash, a cap of at least `params.advisoryCapPips` and a gas limit of at least `params.advisoryGasLimit`.
    ///      A fail-open root charges its full cap whenever the advisory fails, so it also needs an admission that is
    ///      fail-open, fee-only and without a quote take.
    function _checkAdvisory(IHookrPairRoot.Params calldata params) private view {
        address advisory = params.advisory;
        IHookrRegistry.Admission memory a = IHookrRegistry(address(registry)).admission(address(this), advisory);
        if (
            a.implementation != advisory || a.kind != IHookrRegistry.Kind.ADVISORY
                || params.advisoryCapPips > a.caps.maxLpFeePips || params.advisoryGasLimit > a.gasLimit
                || params.advisoryFailOpen && (!a.failOpen || !a.feeOnly || a.caps.maxQuoteTakePips != 0)
        ) revert AdvisoryNotAdmitted(advisory);
        if (advisory.codehash != a.codeHash) revert AdvisoryCodeHashMismatch(advisory);
    }

    function _initCode(IHookrPairRoot.Params calldata params) private view returns (bytes memory) {
        return abi.encodePacked(
            type(HookrPairRoot).creationCode, abi.encode(poolManager, IHookrRegistry(address(registry)), params)
        );
    }

    function _address(bytes32 finalSalt, bytes32 codeHash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), finalSalt, codeHash)))));
    }
}
