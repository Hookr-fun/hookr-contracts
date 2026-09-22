// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IHookrArbExecutorV3} from "../interfaces/IHookrArbExecutorV3.sol";
import {HookrArbTypesV3} from "./HookrArbTypesV3.sol";
import {HookrWthFeePolicyV2} from "./HookrWthFeePolicyV2.sol";

/// @notice Fail-open correction dispatcher for the always-on WTH profile.
/// @dev Same gas stipend, gas reserve, return-shape checks and skip taxonomy as
///      HookrModularCorrectionLibV2. The one behavioural change is that a correction plan is now
///      optional. A swap that arrives without an authenticated recipient (any caller that is not
///      the market's trusted router or quoter) still reaches the executor, with
///      `rebateRecipient = address(0)` and the trader's share reassigned to the triggering pool's
///      LPs. A swap that carries a signed plan keeps every V2 check and the V2 trader split.
///      This library is only linked into the WTH root hook; the standard root keeps V2.
library HookrModularCorrectionLibV3 {
    uint256 internal constant SIGNED_HOOK_DATA_LENGTH = 480;
    /// @dev The stipend is exactly HookrWthExecutorAdapterV1.EXECUTOR_CALL_GAS_LIMIT (2,200,000)
    ///      plus its ADAPTER_GAS_RESERVE (60,000), which is the most the adapter can consume before
    ///      it returns. V2's 2,500,000 was 240,000 higher than that, and those 240,000 could never
    ///      reach the executor: they only raised the gas at which a correction is allowed to start.
    ///      Route lookup is still one mapping read and the number of registered pools is never
    ///      iterated, so the bound keeps the same headroom for v3 callback settlement and v4
    ///      nested-hook execution. HookrWthAlwaysOnRootV1.t.sol pins both halves of this identity.
    /// @dev Ceiling on what the executor is handed. The EVM forwards at most 63/64 of the gas
    ///      remaining, so a caller who sends less simply gives the executor less.
    uint256 internal constant EXECUTOR_GAS_STIPEND = 2_300_000;
    /// @dev Retained for callers that still read it. It is no longer an admission condition:
    ///      dispatch does not check the gas remaining before calling the executor, so a swap sent
    ///      with a fixed limit too small to cover the correction can run out of gas and revert.
    ///      That is deliberate. Gating on a fixed floor let any caller take the arbitrage by
    ///      sending just under it, which is what happened on every live attempt; sizing by
    ///      `eth_estimateGas` prices the correction into the caller's own estimate instead.
    uint256 internal constant DISPATCH_GAS_RESERVE = 800_000;
    uint256 internal constant CLOCK_GAS_STIPEND = 30_000;

    uint8 internal constant STATUS_SKIPPED = 0;
    uint8 internal constant STATUS_SUCCEEDED = 1;
    uint8 internal constant STATUS_FAILED = 2;

    /// @notice Split used when no authenticated recipient exists: the trader's 2000 bps moves to
    ///         the triggering pool's LPs. WTH (1000) and Hookr (1000) stay inside the executor,
    ///         so the three shares the hook names still sum to 8000.
    uint16 internal constant FALLBACK_TRADER_BPS = 0;
    uint16 internal constant FALLBACK_CREATOR_BPS = 4_000;
    uint16 internal constant FALLBACK_TRIGGER_POOL_BPS = 4_000;

    bytes32 internal constant SKIP_INELIGIBLE = keccak256("HOOKR_CORRECTION_V3_INELIGIBLE");
    bytes32 internal constant SKIP_BAD_PAYLOAD = keccak256("HOOKR_CORRECTION_V3_BAD_PAYLOAD");
    bytes32 internal constant SKIP_PHASE = keccak256("HOOKR_CORRECTION_V3_PHASE_MISMATCH");
    bytes32 internal constant SKIP_EXPIRED = keccak256("HOOKR_CORRECTION_V3_EXPIRED");
    bytes32 internal constant SKIP_CLOCK = keccak256("HOOKR_CORRECTION_V3_CLOCK_UNAVAILABLE");
    bytes32 internal constant SKIP_LOW_GAS = keccak256("HOOKR_CORRECTION_V3_LOW_GAS");

    struct DispatchResult {
        uint8 status;
        uint256 realizedProfitQuote;
        bytes32 planDigest;
        bytes32 reasonHash;
    }

    function dispatch(
        address executor,
        PoolKey calldata key,
        bool outerZeroForOne,
        uint128 triggerBaseAmount,
        address authenticatedRecipient,
        address creator,
        uint16 maxArbVolumeBps,
        uint96 poolMinProfitQuote,
        uint8 phase,
        bytes calldata raw
    ) public returns (DispatchResult memory result) {
        // The recipient may be zero here; the creator may not. A zero creator with a 4000 bps
        // creator share is exactly the shape the executor is required to reject, so skip early.
        if (executor == address(0) || triggerBaseAmount == 0 || creator == address(0)) {
            result.reasonHash = SKIP_INELIGIBLE;
            return result;
        }
        HookrArbTypesV3.ProfitSplit memory split = HookrArbTypesV3.ProfitSplit({
            creator: creator,
            traderBps: FALLBACK_TRADER_BPS,
            creatorBps: FALLBACK_CREATOR_BPS,
            triggerPoolBps: FALLBACK_TRIGGER_POOL_BPS
        });
        if (authenticatedRecipient != address(0)) {
            split.traderBps = HookrWthFeePolicyV2.TRADER_BPS;
            split.creatorBps = HookrWthFeePolicyV2.CREATOR_BPS;
            split.triggerPoolBps = HookrWthFeePolicyV2.TRIGGER_POOL_LP_BPS;
        }

        HookrArbTypesV3.ArbPlan memory plan;
        bytes32 r;
        bytes32 s;
        uint8 v;
        if (raw.length != 0) {
            // A plan only ever arrives inside an authenticated router envelope, so a plan without
            // a recipient is a malformed payload rather than the fallback case.
            if (authenticatedRecipient == address(0)) {
                result.reasonHash = SKIP_BAD_PAYLOAD;
                return result;
            }
            (HookrArbTypesV3.HookData memory data, bool valid) = _decode(raw);
            if (!valid || data.recipient != authenticatedRecipient || data.plan.version != HookrArbTypesV3.PLAN_VERSION)
            {
                result.reasonHash = SKIP_BAD_PAYLOAD;
                return result;
            }
            if (data.plan.phase != phase) {
                result.reasonHash = SKIP_PHASE;
                return result;
            }
            (bool clockOk, uint64 executionBlock) = _executionBlockNumber(executor);
            if (!clockOk) {
                result.reasonHash = SKIP_CLOCK;
                return result;
            }
            if (executionBlock > data.plan.maxBlock || block.timestamp > data.plan.deadline) {
                result.reasonHash = SKIP_EXPIRED;
                return result;
            }
            plan = data.plan;
            r = data.r;
            s = data.s;
            v = data.v;
        }

        HookrArbTypesV3.ExecutionRequest memory request = HookrArbTypesV3.ExecutionRequest({
            targetKey: key,
            outerZeroForOne: outerZeroForOne,
            triggerBaseAmount: triggerBaseAmount,
            rebateRecipient: authenticatedRecipient,
            maxArbVolumeBps: maxArbVolumeBps,
            profitSplit: split,
            poolMinProfitQuote: poolMinProfitQuote,
            plan: plan,
            r: r,
            s: s,
            v: v
        });

        bytes memory input = abi.encodeCall(IHookrArbExecutorV3.executeArbitrage, (request));
        bool ok;
        uint256 returnSize;
        uint256 firstWord;
        uint256 secondWord;
        assembly ("memory-safe") {
            mstore(0, 0)
            mstore(0x20, 0)
            ok := call(EXECUTOR_GAS_STIPEND, executor, 0, add(input, 0x20), mload(input), 0, 0x40)
            returnSize := returndatasize()
            if gt(returnSize, 0) {
                let copySize := returnSize
                if gt(copySize, 0x40) { copySize := 0x40 }
                returndatacopy(0, 0, copySize)
                firstWord := mload(0)
                secondWord := mload(0x20)
            }
        }
        if (!ok || returnSize != 64) {
            result.status = STATUS_FAILED;
            result.reasonHash = keccak256(abi.encode(ok, returnSize, firstWord, secondWord));
            return result;
        }
        result.status = STATUS_SUCCEEDED;
        result.realizedProfitQuote = firstWord;
        result.planDigest = bytes32(secondWord);
    }

    function _executionBlockNumber(address executor) private view returns (bool valid, uint64 number) {
        bytes memory input = abi.encodeWithSelector(IHookrArbExecutorV3.executionBlockNumber.selector);
        uint256 raw;
        uint256 size;
        assembly ("memory-safe") {
            valid := staticcall(CLOCK_GAS_STIPEND, executor, add(input, 0x20), mload(input), 0, 0x20)
            size := returndatasize()
            raw := mload(0)
        }
        if (!valid || size != 32 || raw > type(uint64).max) return (false, 0);
        number = uint64(raw);
    }

    function _decode(bytes calldata raw) private pure returns (HookrArbTypesV3.HookData memory data, bool valid) {
        if (raw.length != SIGNED_HOOK_DATA_LENGTH) return (data, false);
        uint256[15] memory word;
        assembly ("memory-safe") {
            let source := raw.offset
            let destination := word
            for { let i := 0 } lt(i, 15) { i := add(i, 1) } {
                mstore(add(destination, mul(i, 32)), calldataload(add(source, mul(i, 32))))
            }
        }
        if (
            word[0] >> 160 != 0 || word[1] >> 8 != 0 || word[2] >> 8 != 0 || word[4] > 1 || word[5] >> 128 != 0
                || word[6] >> 96 != 0 || word[7] >> 160 != 0 || word[8] >> 160 != 0 || word[9] >> 64 != 0
                || word[10] >> 64 != 0 || word[11] >> 64 != 0 || word[14] >> 8 != 0
        ) return (data, false);

        data.recipient = address(uint160(word[0]));
        data.plan = HookrArbTypesV3.ArbPlan({
            version: uint8(word[1]),
            phase: uint8(word[2]),
            routeId: bytes32(word[3]),
            buyBaseOnTarget: word[4] != 0,
            baseAmount: uint128(word[5]),
            minProfitQuote: uint96(word[6]),
            hookrSqrtPriceLimitX96: uint160(word[7]),
            externalSqrtPriceLimitX96: uint160(word[8]),
            maxBlock: uint64(word[9]),
            deadline: uint64(word[10]),
            nonce: uint64(word[11])
        });
        data.r = bytes32(word[12]);
        data.s = bytes32(word[13]);
        data.v = uint8(word[14]);
        valid = data.recipient != address(0);
    }
}
