// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../../src/interfaces/IHookrRoot.sol";
import {IHookrPairAdvisory} from "../../src/interfaces/IHookrPairAdvisory.sol";

/// @title TemplateAdvisory
/// @notice The smallest advisory that passes AdvisoryConformance: one constant LP-fee surcharge per pool, frozen at
///         bind, for HookrRoot pools and Hookr pair roots. Copy it as the starting point of a new advisory.
/// @dev No owner, no storage other than the bindings, no upgrade path, no DELEGATECALL. Bindings are keyed by the
///      calling root, so a caller can only bind and read its own pools. The bind data is `abi.encode(uint24)`, the
///      surcharge in pips. On a HookrRoot pool it must be at most the advisory's admitted LP-fee cap; on a pair root,
///      at most the root's immutable advisory cap. Every swap-path function reads one storage slot.
contract TemplateAdvisory is IHookrAdvisory, IHookrPairAdvisory {
    using PoolIdLibrary for PoolKey;

    /// @notice One pool's frozen surcharge. One storage slot.
    /// @param surchargePips The LP-fee surcharge added on every swap.
    /// @param bound Whether the pool is bound.
    struct Binding {
        uint24 surchargePips;
        bool bound;
    }

    /// @notice Smallest advisory gas limit a HookrRoot pool may bind with. The root forwards the same limit to
    ///         `bind`, which reads the admission and writes one new slot.
    uint32 public constant MIN_ADVISORY_GAS = 60_000;
    /// @notice Smallest advisory gas limit a pair root may bind with.
    uint32 public constant MIN_PAIR_GAS = 5_000;

    mapping(address binder => mapping(PoolId => Binding)) private _bindings;

    /// @notice Emitted when a root binds a pool.
    /// @param binder The root that bound the pool.
    /// @param id The pool.
    /// @param surchargePips The frozen surcharge.
    event Bound(address indexed binder, PoolId indexed id, uint24 surchargePips);

    /// @notice Thrown when the caller binds a pool it already bound.
    error AlreadyBound(address binder, PoolId id);
    /// @notice Thrown when the caller asks for a pool it has not bound.
    error UnknownPool(address binder, PoolId id);
    /// @notice Thrown when the bind data or the pool's advisory settings are out of range.
    error InvalidConfig();

    /// @inheritdoc IHookrAdvisory
    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("hookr.advisory.template.config");
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev The caller must be a root that has this contract admitted as a fee-only ADVISORY, binding its own pool
    ///      with this contract before the swap only. The surcharge must fit the admitted LP-fee cap.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32 configHash)
    {
        uint24 surchargePips = _decode(data);
        if (
            address(key.hooks) != msg.sender || pc.advisory != address(this)
                || pc.advisoryPhases != HookrTypes.BEFORE_SWAP || pc.advisoryGasLimit < MIN_ADVISORY_GAS
        ) revert InvalidConfig();
        IHookrRegistry.Admission memory a = IHookrRoot(msg.sender).registry().admission(msg.sender, address(this));
        if (
            a.kind != IHookrRegistry.Kind.ADVISORY || a.implementation != address(this) || !a.feeOnly
                || surchargePips > a.caps.maxLpFeePips
        ) revert InvalidConfig();
        _bind(key.toId(), surchargePips);
        return keccak256(data);
    }

    /// @inheritdoc IHookrPairAdvisory
    /// @dev The surcharge must fit `capPips`, and `gasLimit` must be at least MIN_PAIR_GAS.
    function bindPair(PoolId id, uint24 capPips, uint32 gasLimit, bytes calldata data) external returns (bytes4) {
        uint24 surchargePips = _decode(data);
        if (surchargePips > capPips || gasLimit < MIN_PAIR_GAS) revert InvalidConfig();
        _bind(id, surchargePips);
        return IHookrPairAdvisory.bindPair.selector;
    }

    /// @inheritdoc IHookrPairAdvisory
    function surchargeForSwap(PoolId id, bool, int256, uint160, bytes calldata, address)
        external
        view
        returns (uint24)
    {
        Binding memory b = _bindings[msg.sender][id];
        if (!b.bound) revert UnknownPool(msg.sender, id);
        return b.surchargePips;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Liquidity is never restricted.
    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Zero advice for a pool the caller has not bound; the root only calls it for pools it bound.
    function beforeSwap(HookrTypes.SwapContext calldata context)
        external
        view
        returns (HookrTypes.Advice memory advice)
    {
        advice.lpFeeSurchargePips = _bindings[msg.sender][context.id].surchargePips;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Never called: the template binds only with the BEFORE_SWAP phase.
    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory advice)
    {
        return advice;
    }

    /// @notice Returns the binding of `id` by `binder`.
    function binding(address binder, PoolId id) external view returns (Binding memory) {
        return _bindings[binder][id];
    }

    /// @dev Decodes exactly one word holding a uint24.
    function _decode(bytes calldata data) private pure returns (uint24) {
        if (data.length != 32) revert InvalidConfig();
        uint256 word = abi.decode(data, (uint256));
        if (word > type(uint24).max) revert InvalidConfig();
        return uint24(word);
    }

    function _bind(PoolId id, uint24 surchargePips) private {
        Binding storage b = _bindings[msg.sender][id];
        if (b.bound) revert AlreadyBound(msg.sender, id);
        b.surchargePips = surchargePips;
        b.bound = true;
        emit Bound(msg.sender, id, surchargePips);
    }
}
