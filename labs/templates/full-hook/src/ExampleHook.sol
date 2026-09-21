// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title Example Hook
/// @notice A standalone Uniswap v4 hook: two permissions, a per-pool swap counter, and a fixed LP
///         fee override for dynamic-fee pools. Everything a full hook for review needs to have, and
///         nothing it does not.
/// @dev A full hook is not admitted to Hookr's registry; it has an address of its own and is
///      reviewed for listing. It does not inherit `BaseHook` (that lives in v4-periphery, which
///      this repository does not vendor); it implements `IHooks` directly, reverts on the eight
///      callbacks it has no permission for, and validates its own address at construction the
///      way `BaseHook` does. Copy this file and change `beforeSwap` and `afterSwap`.
contract ExampleHook is IHooks {
    using PoolIdLibrary for PoolKey;

    /// @dev The low fourteen address bits this hook must carry: `beforeSwap` and `afterSwap`.
    uint160 public constant REQUIRED_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

    IPoolManager public immutable poolManager;
    /// @notice The LP fee returned for every swap on a dynamic-fee pool, in pips.
    uint24 public immutable lpFeePips;

    mapping(PoolId => uint256) public swapCount;

    error NotPoolManager();
    error HookNotImplemented();
    error FeeTooLarge();

    constructor(IPoolManager poolManager_, uint24 lpFeePips_) {
        if (lpFeePips_ > LPFeeLibrary.MAX_LP_FEE) revert FeeTooLarge();
        poolManager = poolManager_;
        lpFeePips = lpFeePips_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // The override flag tells the PoolManager to use this fee for this swap. It is honoured
        // only on a pool whose `PoolKey.fee` carries `LPFeeLibrary.DYNAMIC_FEE_FLAG`.
        return
            (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        swapCount[key.toId()] += 1;
        return (IHooks.afterSwap.selector, 0);
    }

    // The eight callbacks this hook has no permission for. The PoolManager never calls them,
    // because the address says not to; they exist so the contract satisfies `IHooks`.

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
