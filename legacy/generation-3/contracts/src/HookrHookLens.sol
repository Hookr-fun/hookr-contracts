// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrHook} from "./HookrHook.sol";

/// @title HookrHookLens
/// @notice Read-only helper for the arb-buyback block. Lives outside HookrHook because the hook
///         sits exactly at this solc version's codegen cliff: one more parameterized view making
///         an external call crashes compilation ("Assembly exception for bytecode"). Everything
///         here is derivable from public hook state plus the PoolManager's slot 0.
contract HookrHookLens {
    uint16 internal constant MAX_BUYBACK_SLIP_BPS = 500;
    uint256 internal constant BPS = 10_000;

    struct BuybackStatus {
        bool ready;
        bool configured;
        uint96 spendWei;
        uint96 accruedWei;
        uint96 minSpendWei;
        uint96 maxSpendWei;
        uint160 currentSqrtX96;
        uint160 anchorSqrtX96;
        uint40 lastExecBlock;
        uint32 cooldownBlocks;
        uint16 drawdownBps;
    }

    HookrHook public immutable hook;

    constructor(HookrHook hook_) {
        hook = hook_;
    }

    /// @notice Live readiness of a pool's arb buyback. Mirrors the conditions the hook re-checks
    ///         atomically inside executeBuyback; between this read and any transaction both the
    ///         price and the reserve may move.
    function buybackStatus(PoolId id) external view returns (BuybackStatus memory v) {
        (
            bool initialized,,,,,,,,,,,,,
            uint96 burnTriggerWei,
            uint16 buybackBps,
            uint16 buybackDrawdownBps,
            uint32 buybackCooldownBlocks,
            uint96 buybackMinSpendWei,
            uint96 buybackMaxSpendWei,,
        ) = hook.poolConfig(id);
        if (!initialized || buybackBps == 0) return v;
        v.configured = true;
        v.minSpendWei = buybackMinSpendWei;
        v.maxSpendWei = buybackMaxSpendWei;
        v.cooldownBlocks = buybackCooldownBlocks;
        v.drawdownBps = buybackDrawdownBps;
        v.accruedWei = uint96(hook.buybackAccruedWei(id));
        v.anchorSqrtX96 = hook.buybackAnchorSqrtX96(id);
        v.lastExecBlock = hook.buybackLastExecBlock(id);

        // slot 0 is the first storage slot of the pool: packed sqrtPriceX96 | tick | fees.
        bytes32 raw = IExtsload(address(hook.poolManager())).extsload(PoolId.unwrap(id));
        v.currentSqrtX96 = uint160(uint256(raw));

        if (v.currentSqrtX96 == 0 || v.anchorSqrtX96 == 0) return v;
        if (v.lastExecBlock != 0 && block.number < uint256(v.lastExecBlock) + v.cooldownBlocks) return v;
        if (v.accruedWei < v.minSpendWei) return v;
        // Higher sqrt = cheaper token (price is tokens-per-quote): trigger when the live sqrt is
        // drawdownBps above the running anchor.
        uint256 ratio1e18 = (uint256(v.currentSqrtX96) * 1e18) / uint256(v.anchorSqrtX96);
        uint256 threshold1e18 = 1e18 + (uint256(v.drawdownBps) * 1e18) / BPS;
        if (ratio1e18 < threshold1e18) return v;
        v.ready = true;
        v.spendWei = v.accruedWei > v.maxSpendWei ? v.maxSpendWei : v.accruedWei;
    }
}
