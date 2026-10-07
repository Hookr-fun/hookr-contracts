// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrPairRoot} from "../interfaces/IHookrPairRoot.sol";
import {IHookrPairAdvisory} from "../interfaces/IHookrPairAdvisory.sol";

/// @title HookrPairRoot
/// @notice Immutable Uniswap v4 hook for exactly one dynamic-fee pool. No owner, no storage, no upgrade path.
/// @dev Permissions are BEFORE_INITIALIZE and BEFORE_SWAP. Without an advisory the swap uses the base fee held in
///      slot0. With one, the root binds its pool in the advisory when the pool opens, and the fee is base plus the
///      advisory surcharge clamped to the advisory cap, returned with the override flag. Every returned fee is at
///      most maxLpFeePips.
contract HookrPairRoot is HookrReleased, IHookrPairRoot {
    using PoolIdLibrary for PoolKey;

    /// @notice BEFORE_INITIALIZE | BEFORE_SWAP. The root's address carries exactly these low 14 bits.
    uint160 public constant PERMISSION_FLAGS = 0x2080;
    /// @notice Role identifier of this contract in the Hookr release.
    bytes32 public constant ROLE = keccak256("hookr.root.pair");
    /// @notice The ceiling on maxLpFeePips.
    uint24 public constant MAX_LP_FEE_PIPS = 600_000;
    /// @notice The ceiling on advisoryGasLimit.
    uint32 public constant MAX_ADVISORY_GAS = 500_000;
    /// @dev Gas held back for the call itself (cold account access included) when checking that the advisory
    ///      receives its full limit.
    uint256 private constant ADVISORY_GAS_RESERVE = 5_000;

    /// @inheritdoc IHookrPairRoot
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrPairRoot
    IHookrRegistry public immutable registry;
    /// @inheritdoc IHookrPairRoot
    address public immutable factory;
    Currency private immutable currency0;
    Currency private immutable currency1;
    int24 private immutable tickSpacing;
    uint24 private immutable baseLpFeePips;
    uint24 private immutable maxLpFeePips;
    address private immutable advisory;
    uint24 private immutable advisoryCapPips;
    uint32 private immutable advisoryGasLimit;
    bool private immutable advisoryFailOpen;
    PoolId private immutable id;

    constructor(IPoolManager manager, IHookrRegistry registry_, Params memory p) {
        if (
            address(manager).code.length == 0 || address(registry_).code.length == 0
                || (uint160(address(this)) & 0x3fff) != PERMISSION_FLAGS
        ) revert InvalidHookAddress();
        if (
            Currency.unwrap(p.currency0) >= Currency.unwrap(p.currency1) || p.tickSpacing < TickMath.MIN_TICK_SPACING
                || p.tickSpacing > TickMath.MAX_TICK_SPACING || p.maxLpFeePips > MAX_LP_FEE_PIPS
                || uint256(p.baseLpFeePips) + p.advisoryCapPips > p.maxLpFeePips
        ) revert InvalidParams();
        if (p.advisory == address(0)) {
            if (p.advisoryCapPips != 0 || p.advisoryGasLimit != 0 || p.advisoryFailOpen) revert InvalidParams();
        } else if (
            p.advisory.code.length == 0 || p.advisory == address(manager) || p.advisoryCapPips == 0
                || p.advisoryGasLimit == 0 || p.advisoryGasLimit > MAX_ADVISORY_GAS
        ) {
            revert InvalidParams();
        }
        poolManager = manager;
        registry = registry_;
        factory = msg.sender;
        currency0 = p.currency0;
        currency1 = p.currency1;
        tickSpacing = p.tickSpacing;
        baseLpFeePips = p.baseLpFeePips;
        maxLpFeePips = p.maxLpFeePips;
        advisory = p.advisory;
        advisoryCapPips = p.advisoryCapPips;
        advisoryGasLimit = p.advisoryGasLimit;
        advisoryFailOpen = p.advisoryFailOpen;
        id = PoolKey(p.currency0, p.currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, p.tickSpacing, IHooks(address(this)))
            .toId();
    }

    /// @inheritdoc IHookrPairRoot
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, IHooks(address(this)));
    }

    /// @inheritdoc IHookrPairRoot
    function poolId() external view returns (PoolId) {
        return id;
    }

    /// @inheritdoc IHookrPairRoot
    function knownPool(PoolId poolId_) external view returns (bool) {
        return PoolId.unwrap(poolId_) == PoolId.unwrap(id);
    }

    /// @inheritdoc IHookrPairRoot
    function params() external view returns (Params memory) {
        return Params({
            currency0: currency0,
            currency1: currency1,
            tickSpacing: tickSpacing,
            baseLpFeePips: baseLpFeePips,
            maxLpFeePips: maxLpFeePips,
            advisory: advisory,
            advisoryCapPips: advisoryCapPips,
            advisoryGasLimit: advisoryGasLimit,
            advisoryFailOpen: advisoryFailOpen
        });
    }

    /// @inheritdoc IHookrPairRoot
    /// @dev The PoolManager does not call a hook back for an initialization the hook starts itself.
    function open(uint160 sqrtPriceX96, bytes calldata advisoryData) external returns (int24 tick) {
        if (msg.sender != factory) revert Unauthorized();
        address target = advisory;
        if (target == address(0)) {
            if (advisoryData.length != 0) revert InvalidParams();
        } else if (
            IHookrPairAdvisory(target).bindPair(id, advisoryCapPips, advisoryGasLimit, advisoryData)
                != IHookrPairAdvisory.bindPair.selector
        ) {
            revert AdvisoryRefused(target);
        }
        PoolKey memory key = poolKey();
        tick = poolManager.initialize(key, sqrtPriceX96);
        if (baseLpFeePips != 0) poolManager.updateDynamicLPFee(key, baseLpFeePips);
    }

    /// @inheritdoc IHookrPairRoot
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert Unauthorized();
    }

    /// @inheritdoc IHookrPairRoot
    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata swap, bytes calldata hookData)
        external
        view
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        if (advisory == address(0)) return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        uint24 fee = baseLpFeePips + _surcharge(sender, swap, hookData);
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Returns the advisory surcharge clamped to the cap. On failure returns the cap (fail-open) or reverts.
    ///      The gas check runs after the call data is built in memory, immediately before the call, so a starved
    ///      call cannot select the failure path whatever the hookData size.
    function _surcharge(address sender, SwapParams calldata swap, bytes calldata hookData)
        private
        view
        returns (uint24)
    {
        address target = advisory;
        uint256 limit = advisoryGasLimit;
        uint256 required = limit + limit / 63 + ADVISORY_GAS_RESERVE;
        bytes4 selector = IHookrPairAdvisory.surchargeForSwap.selector;
        bytes4 starved = InsufficientAdvisoryGas.selector;
        PoolId pool = id;
        bool ok;
        uint256 word;
        // abi.encodeCall(surchargeForSwap, (id, zeroForOne, amountSpecified, sqrtPriceLimitX96, hookData, sender)),
        // built in scratch memory past the free memory pointer. The swap fields are copied as the PoolManager
        // encoded them. The payload after the selector is padded with zeros to a multiple of 32 bytes.
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, selector)
            mstore(add(p, 0x04), pool)
            calldatacopy(add(p, 0x24), swap, 0x60)
            mstore(add(p, 0x84), 0xc0)
            mstore(add(p, 0xa4), sender)
            mstore(add(p, 0xc4), hookData.length)
            calldatacopy(add(p, 0xe4), hookData.offset, hookData.length)
            mstore(add(add(p, 0xe4), hookData.length), 0)
            let size := add(0xe4, and(add(hookData.length, 31), not(31)))
            if lt(gas(), required) {
                mstore(0, starved)
                revert(0, 4)
            }
            ok := staticcall(limit, target, p, size, 0, 32)
            ok := and(ok, eq(returndatasize(), 32))
            word := mload(0)
        }
        uint24 cap = advisoryCapPips;
        if (ok && word <= type(uint24).max) return word < cap ? uint24(word) : cap;
        if (!advisoryFailOpen) revert AdvisoryFailed(target);
        return cap;
    }
}
