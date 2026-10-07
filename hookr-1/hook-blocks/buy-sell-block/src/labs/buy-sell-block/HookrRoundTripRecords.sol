// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../../types/HookrTypes.sol";
import {HookrRules} from "../../core/HookrRules.sol";
import {HookrRoundTrip} from "./HookrRoundTrip.sol";
import {HookrRoundTripKey} from "./HookrRoundTripKey.sol";
import {HookrRoundTripStorage} from "./HookrRoundTripStorage.sol";

/// @title Round-trip record writes
/// @notice The round-trip record's writes, as a module HookrRulesRoundTrip creates in its own constructor (by CREATE2
///         with a zero salt, from this creation code as a code store holds it) and reaches only by DELEGATECALL, with
///         the calldata of its own `bind` and `settleSwap`, whose selectors this shares: the way HookrRules reaches
///         HookrRecapture. The Rules do not fit under 24,576 bytes with the record inline beside HookrRules, nor under
///         49,152 bytes of initcode with this creation code inside theirs.
/// @dev Runs in the Rules' storage. Every entry reverts on the module's own address.
contract HookrRoundTripRecords {
    using PoolIdLibrary for PoolKey;

    /// @dev HookrRules' State namespace (erc7201 "hookr.rules"), read for a pool's recapture flag, as HookrRecapture
    ///      reads it.
    bytes32 private constant SLOT = 0x762913e4bc0f59f7b08c82f07586fa48932548ab5fab99e6db0b09765b4ff900;
    /// @dev Gas cap of the bind-time ROUND_TRIP_ADVISORY() read.
    uint256 private constant ROUND_TRIP_ASK_GAS = 10_000;
    /// @dev Gas cap of the read of a recapture pool's arb recapture executor from the root (IHookrLaneRoot.laneOf).
    uint256 private constant LANE_READ_GAS = 50_000;
    /// @dev IHookrRoundTripAdvisory.ROUND_TRIP_ADVISORY.selector and IHookrLaneRoot.laneOf.selector.
    bytes4 private constant ROUND_TRIP_ADVISORY_SELECTOR = 0x27b05553;
    bytes4 private constant LANE_OF_SELECTOR = 0xda500641;

    /// @dev The Rules' trusted root, whose laneOf names a recapture pool's arb recapture executor.
    address private immutable trustedRoot;
    address private immutable self;

    /// @notice The pool records round trips from its bind on: its advisory asked for them.
    event RoundTripsRecorded(PoolId indexed id, address indexed advisory);

    error Unauthorized();

    constructor(address _trustedRoot) {
        trustedRoot = _trustedRoot;
        self = address(this);
    }

    /// @dev Every entry runs only as the Rules' DELEGATECALL, never on the module's own address.
    modifier delegated() {
        if (address(this) == self) revert Unauthorized();
        _;
    }

    /// @notice HookrRulesRoundTrip.bind forwarded after the Rules bound the pool: a pool whose advisory answers
    ///         ROUND_TRIP_ADVISORY() with the magic value records, per trader key, the directions each completed swap
    ///         traded in its block.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata) external delegated {
        if (!_asksRoundTrips(pc.advisory)) return;
        PoolId id = key.toId();
        HookrRoundTripStorage.load().recording[id] = true;
        emit RoundTripsRecorded(id, pc.advisory);
    }

    /// @notice HookrRulesRoundTrip.settleSwap forwarded for a recording pool, after the Rules checked the caller and
    ///         the context: adds the swap's direction to its trader's word for this block. The record never refuses
    ///         a swap. The pool's arb recapture executor is not a trader: its swaps are never recorded, since a buy leg
    ///         inside the launch guard takes the Rules path, and its record would make the advisory refuse the
    ///         executor's later legs from the same transaction origin in that block. The executor is never
    ///         authenticated (the root refuses a lane whose executor is its router, quoter or curated router), so only
    ///         an unauthenticated swap on a recapture pool reads it.
    function settleSwap(HookrTypes.SwapContext calldata x, HookrTypes.Settlement calldata) external delegated {
        if (!x.authenticated && _state().recapture[x.id].on && _isLaneExecutor(x.id, x.sender)) return;
        mapping(bytes32 => uint256) storage words = HookrRoundTripStorage.load().words[x.id];
        bytes32 trader = HookrRoundTripKey.trader(x.sender, x.payer, x.authenticated, tx.origin);
        uint256 word = words[trader];
        uint256 bit = x.isBuy ? HookrRoundTrip.BOUGHT : HookrRoundTrip.SOLD;
        uint256 next = word >> 2 == block.number ? word | bit : block.number << 2 | bit;
        if (next != word) words[trader] = next;
    }

    /// @dev Whether the pool's advisory asks for round-trip records: a bounded static read of ROUND_TRIP_ADVISORY()
    ///      that must return exactly the magic word. Any failure means no.
    function _asksRoundTrips(address advisory) private view returns (bool) {
        if (advisory == address(0)) return false;
        bytes32 answer;
        assembly ("memory-safe") {
            mstore(0, ROUND_TRIP_ADVISORY_SELECTOR)
            // The call first: Yul evaluates arguments right to left, so returndatasize() must follow it.
            let ok := staticcall(ROUND_TRIP_ASK_GAS, advisory, 0, 4, 0, 32)
            if and(ok, eq(returndatasize(), 32)) { answer := mload(0) }
        }
        return answer == HookrRoundTrip.MAGIC;
    }

    /// @dev Whether `account` is the arb recapture executor the root froze for recapture pool `id` when it initialized
    ///      the pool, from a bounded static read of the root's IHookrLaneRoot.laneOf, whose first word is the
    ///      executor. Any failure reads as no, so the swap is recorded as a trader's.
    function _isLaneExecutor(PoolId id, address account) private view returns (bool found) {
        address root = trustedRoot;
        assembly ("memory-safe") {
            mstore(0, LANE_OF_SELECTOR)
            mstore(4, id)
            let ok := staticcall(LANE_READ_GAS, root, 0, 36, 0, 32)
            if and(ok, gt(returndatasize(), 31)) { found := eq(mload(0), account) }
        }
    }

    function _state() private pure returns (HookrRules.State storage s) {
        assembly ("memory-safe") {
            s.slot := SLOT
        }
    }
}
