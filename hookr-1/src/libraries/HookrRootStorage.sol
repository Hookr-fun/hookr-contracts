// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title HookrRootStorage
/// @notice HookrRoot's pool record, shared with the HookrLane module that runs in the root's context through
///         DELEGATECALL. Slots 0-7 are HookrRoot's record with the dynamic fee flag widened to `mode` (bit 0 dynamic
///         fee, bit 1 lane, bit 2 King of the Pool ledger) and `laneLiquidity` (a lane pool, whose removals HookrLane
///         sees) in the removal-lock slot. Slots 8-10 hold a lane pool's frozen lane: its executor with the pinned
///         partner share, the executor's runtime codehash and the family the launcher reported; slot 8 also holds
///         `laneDue`: 1 while the Rules may hold a pending LP share (after a push, or a flush that left one pending),
///         0 once nothing is pending. While it is 1 every lane operation flushes. The lane's switch and gas cap are not
///         frozen: the root reads them from the registry on each swap.
library HookrRootStorage {
    bytes32 internal constant SLOT = 0x3c0d3d8cba92527b3a48aa783c8734a4e170057eb16401c9df8a7c8a6588b900;
    bytes32 internal constant ACTIVE = keccak256("hookr.root.transient.active");
    bytes32 internal constant BINDING = keccak256("hookr.root.transient.binding");
    uint8 internal constant MODE_DYNAMIC_FEE = 1;
    uint8 internal constant MODE_LANE = 2;
    uint8 internal constant MODE_LEDGER = 4;
    /// @dev ACTIVE carries LEG while an executor leg on a pool of the open arb recapture is in flight, and LEG_DYNAMIC
    ///      beside it while that pool (one without an advisory) charges Hookr dynamic fees, so the root's afterSwap has
    ///      HookrLane carry the pool's dynamic fee state for the leg (HookrLane.updateLegDynamicFee).
    uint256 internal constant LEG = 16;
    uint256 internal constant LEG_DYNAMIC = 32;
    /// @dev The price an executor leg on a dynamic fee pool starts from, recorded by HookrLane._enter before the swap
    ///      and read by HookrLane.updateLegDynamicFee after it: the sqrt price, and the tick above bit 160.
    bytes32 internal constant LEG_START = keccak256("hookr.root.transient.leg.start");
    /// @dev Op word flags the root appends to a hook callback it forwards to HookrLane; the trader (or, with OP_ENTER,
    ///      the ACTIVE depth) sits above bit 8. Zero on a liquidity callback: the King of the Pool ledger.
    uint256 internal constant OP_RUN = 1;
    uint256 internal constant OP_MARK = 2;
    uint256 internal constant OP_ENTER = 4;
    /// @dev An open arb recapture frame (HookrLane): its pool id, zero outside a frame; its executor; its pool's
    ///      family. The root's `quoteLeg` reads them to refuse a pool the frame's executor could not leg on.
    bytes32 internal constant LANE_FRAME = keccak256("hookr.root.transient.lane.frame");
    bytes32 internal constant LANE_EXECUTOR = keccak256("hookr.root.transient.lane.executor");
    bytes32 internal constant LANE_FAMILY = keccak256("hookr.root.transient.lane.family");
    /// @dev The selectors of the two errors HookrRoot and HookrLane declare for a module call they require
    ///      (`revertModuleCall`): ModuleCallFailed(address,bytes4) and ModuleCallReverted(address,bytes4,bytes).
    bytes4 internal constant MODULE_CALL_FAILED = 0x66b1f70e;
    bytes4 internal constant MODULE_CALL_REVERTED = 0xa3f86114;
    /// @dev The most of a module's revert data a ModuleCallReverted carries: a selector and four words.
    uint256 internal constant MAX_REASON = 132;

    /// @dev Slot 0 serves every swap, slot 1 every swap that calls a module, slot 2 every advised swap. Swaps take
    ///      subject and quote from the pool key and `quoteIsCurrency0`, so slots 3-7 serve views, initialization and
    ///      removals (slot 5 holds the removal lock, which a lane leg also reads as the launch guard's end).
    ///      `feeOnlyFrom` is the block from which swaps skip the Rules module (zero: never); it is set only for a pool
    ///      without a lane whose Rules declare it at binding and whose advisory, if any, is admitted without a quote
    ///      take. `mode` bit 0 marks a pool whose Rules declare a dynamic fee at binding: its swaps are simulated before
    ///      Rules quote them. Slots 8-10 are read only on a lane pool's swaps.
    struct Record {
        address rules;
        uint24 baseLpFeePips;
        uint40 feeOnlyFrom;
        uint8 advisoryPhases;
        bool initialized;
        bool quoteIsCurrency0;
        uint8 mode;
        uint24 capLp;
        uint24 capQuote;
        uint16 capSubject;
        uint32 rulesGasLimit;
        uint24 rulesCapLp;
        uint24 rulesCapQuote;
        uint16 rulesCapSubject;
        uint32 advisoryGasLimit;
        uint24 advisoryCapLp;
        uint24 advisoryCapQuote;
        bool advisoryFailOpen;
        address advisory;
        Currency subject;
        Currency quote;
        address liquidityOwner;
        uint40 lockedUntil;
        bool laneLiquidity;
        bytes32 policyId;
        bytes32 policy;
        address laneExecutor;
        uint16 lanePartnerBps;
        uint40 laneDue;
        bytes32 laneCodeHash;
        bytes32 laneFamily;
    }

    /// @custom:storage-location erc7201:hookr.root
    struct State {
        mapping(PoolId => Record) pools;
    }

    function state() internal pure returns (State storage s) {
        assembly ("memory-safe") {
            s.slot := SLOT
        }
    }

    /// @dev Calls `target` with at most `gasLimit` gas (a static call when `readOnly`) and copies `size` bytes of its
    ///      return into `output`; `ok` only when the call succeeded and returned exactly `size` bytes, `reverted` when
    ///      the call itself failed (it reverted or ran out of gas).
    function bounded(address target, bytes memory input, uint256 gasLimit, uint256 size, bool readOnly)
        internal
        returns (bool ok, bytes memory output, bool reverted)
    {
        output = new bytes(size);
        assembly ("memory-safe") {
            switch readOnly
            case 1 { ok := staticcall(gasLimit, target, add(input, 32), mload(input), add(output, 32), size) }
            default { ok := call(gasLimit, target, 0, add(input, 32), mload(input), add(output, 32), size) }
            reverted := iszero(ok)
            ok := and(ok, eq(returndatasize(), size))
        }
    }

    /// @dev Reverts for a module call its caller requires and `bounded` just answered not ok, before any other call
    ///      replaces the return data: ModuleCallReverted(target, selector, reason) when the call reverted with data,
    ///      `reason` that data cut to its first MAX_REASON bytes; otherwise ModuleCallFailed(target, selector), for a
    ///      call that ran out of gas, reverted without data or answered in a shape the caller refuses. `selector` is
    ///      the first four bytes of `input`. The reason travels inside the error, so a module's data never reads as the
    ///      caller's own error, and the cap bounds what a module's revert data can cost the caller.
    function revertModuleCall(address target, bytes memory input, bool reverted) internal pure {
        assembly ("memory-safe") {
            let p := mload(0x40)
            let length := mul(reverted, returndatasize())
            if gt(length, MAX_REASON) { length := MAX_REASON }
            // The error's selector; the module, its 20 bytes at p + 16 (the shift drops any bits above them) after the
            // 12 zero bytes the selector's word left; the call's selector. ModuleCallFailed ends here.
            mstore(p, MODULE_CALL_FAILED)
            if length { mstore(p, MODULE_CALL_REVERTED) }
            mstore(add(p, 16), shl(96, target))
            mstore(add(p, 36), and(mload(add(input, 32)), shl(224, 0xffffffff)))
            if iszero(length) { revert(p, 68) }
            // The reason: its offset (three head words), its length, then its bytes from p + 132, zero-padded to a
            // whole word.
            mstore(add(p, 68), 96)
            mstore(add(p, 100), length)
            returndatacopy(add(p, 132), 0, length)
            mstore(add(add(p, 132), length), 0)
            revert(p, add(132, and(add(length, 31), not(31))))
        }
    }

    /// @dev The transient word at `slot`.
    function tget(bytes32 slot) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    /// @dev Writes the transient word at `slot`.
    function tput(bytes32 slot, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}
