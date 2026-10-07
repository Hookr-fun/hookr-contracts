// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrAdvisory} from "../interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {HookrGoverned} from "../base/HookrGoverned.sol";
import {HookrMarketCalendar} from "../libraries/HookrMarketCalendar.sol";
import {HookrSessionTiers} from "../libraries/HookrSessionTiers.sol";
import {IHookrPairAdvisory} from "../interfaces/IHookrPairAdvisory.sol";
import {IHookrSessionAdvisory} from "../interfaces/IHookrSessionAdvisory.sol";

/// @title HookrSessionAdvisory
/// @notice Fee-only BEFORE_SWAP advisory for tokenized-stock pools on HookrRoot and on Hookr pair roots. It adds an
/// LP-fee surcharge that follows the US equity session: regular hours, pre-market, after-hours, overnight, and closed
/// (weekends and NYSE closures).
/// @dev Every time input is block.timestamp. The surcharge never rejects a bound pool's swap and never takes quote.
/// On a HookrRoot pool it is clamped to the advisory admission cap and to the pool room left above the Rules' largest
/// possible native LP fee; on a pair root, every tier is at most the root's immutable advisory cap. Pool schedules
/// are frozen at bind and keyed by the binder, so a caller can only bind and read its own pools. The calendar is
/// shared: 2026-2030 are constants, and the owner may append each following year through the timelock. Appended
/// years cannot be changed. Through the timelock (MARK_SESSION_DAY) the owner may also mark a weekday the calendar
/// covers, from the current New York day on, as closed or as a 13:00 early close: an unscheduled NYSE closure or early
/// close. A mark never opens a day the calendar closes, a cleared mark leaves the day to the calendar, and a day's
/// mark is replaced only by a mark queued after it took effect.
contract HookrSessionAdvisory is
    HookrReleased,
    HookrGoverned,
    IHookrAdvisory,
    IHookrPairAdvisory,
    IHookrSessionAdvisory
{
    using PoolIdLibrary for PoolKey;

    /// @param bound Each binder's frozen pools.
    /// @param calendar The shared calendar's storage: appended years and, last, the day marks (namespace slot + 4).
    /// @custom:storage-location erc7201:hookr.session.advisory
    struct State {
        mapping(address binder => mapping(PoolId => Bound)) bound;
        HookrMarketCalendar.Extension calendar;
    }

    /// @dev cast index-erc7201 hookr.session.advisory
    bytes32 private constant STATE_SLOT = 0x5d5d14a4b6eaf57142360288c8d49dac28d237caaa9ae18ae1b8baa3c2abf600;
    /// @dev keccak256 of the Schedule type string.
    bytes32 private constant SCHEMA_HASH = keccak256(
        "SessionSchedule(uint24 regularPips,uint24 preMarketPips,uint24 afterHoursPips,uint24 overnightPips,uint24 closedPips,uint16 openRampSeconds,uint16 closeRampSeconds,uint8 flags)"
    );
    /// @dev Schema of the Rules configuration whose ceiling this advisory derives: HookrTypes.RULES_CONFIG_SCHEMA, the
    ///      keccak256 of RulesConfig's type string (HookrRules.configSchemaHash), the 16-word layout.
    bytes32 private constant RULES_SCHEMA = HookrTypes.RULES_CONFIG_SCHEMA;
    uint256 private constant NATIVE_CEILING = 600_000;
    uint256 private constant BPS = 10_000;
    uint256 private constant VIEW_GAS = 60_000;
    /// @dev Length of `abi.encode(HookrTypes.RulesConfig)`: 16 words.
    uint256 private constant RULES_CONFIG_BYTES = 16 * 32;

    /// @notice Kind for appending the next calendar year. Arguments: abi.encode(uint16 year, uint16[] closed,
    ///         uint16[] early), dates as month * 100 + day.
    bytes32 public constant APPEND_YEAR = keccak256("APPEND_YEAR");
    /// @notice Kind for marking one weekday closed or as a 13:00 early close, or clearing its mark. Arguments:
    ///         abi.encode(uint16 year, uint16 monthDay, uint8 mark), the date as month * 100 + day and the mark
    ///         MARK_NONE, MARK_EARLY_CLOSE or MARK_CLOSED. Its epochs are keyed by date:
    ///         keccak256(abi.encode(MARK_SESSION_DAY, abi.encode(year, monthDay))).
    bytes32 public constant MARK_SESSION_DAY = keccak256("MARK_SESSION_DAY");
    /// @notice A day's mark: none. Marking a day with it clears its mark, so the day follows the calendar again.
    uint8 public constant MARK_NONE = uint8(HookrMarketCalendar.FULL);
    /// @notice A day's mark: the regular session closes at 13:00.
    uint8 public constant MARK_EARLY_CLOSE = uint8(HookrMarketCalendar.EARLY);
    /// @notice A day's mark: a full-day closure.
    uint8 public constant MARK_CLOSED = uint8(HookrMarketCalendar.SHUT);
    /// @notice Flag: a weekday outside the calendar is charged the closed surcharge.
    uint8 public constant UNCOVERED_AS_CLOSED = HookrSessionTiers.UNCOVERED_AS_CLOSED;
    /// @notice Smallest advisory gas limit a pool may bind with.
    uint32 public constant MIN_ADVISORY_GAS = 150_000;
    /// @notice Largest combined open and close ramp: the shortest regular session.
    uint256 public constant MAX_RAMP_SECONDS = HookrSessionTiers.MAX_RAMP_SECONDS;
    /// @notice Smallest advisory gas limit a pair root may bind with.
    uint32 public constant MIN_PAIR_GAS = 60_000;

    /// @param owner_ Calendar owner.
    /// @param delay_ Timelock delay for appending years, marking days and transferring ownership.
    constructor(address owner_, uint48 delay_) HookrGoverned(owner_, delay_) {}

    /// @inheritdoc IHookrAdvisory
    function configSchemaHash() external pure returns (bytes32) {
        return SCHEMA_HASH;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev The binder must be a root on whose registry this contract is admitted as an ADVISORY. Every tier must be
    ///      within the admission cap. The limits subtract the Rules' largest native LP fee from the pool cap.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32 configHash)
    {
        PoolId id = key.toId();
        (Schedule memory s, Bound storage entry) = _open(id, data);
        if (pc.advisory != address(this) || pc.advisoryPhases != HookrTypes.BEFORE_SWAP) revert InvalidPoolConfig(1);
        if (pc.advisoryGasLimit < MIN_ADVISORY_GAS) revert InvalidPoolConfig(2);

        IHookrRegistry registry = IHookrRoot(msg.sender).registry();
        IHookrRegistry.Admission memory own = registry.admission(msg.sender, address(this));
        if (own.kind != IHookrRegistry.Kind.ADVISORY || own.implementation != address(this)) {
            revert InvalidPoolConfig(3);
        }
        uint256 cap = own.caps.maxLpFeePips;
        _checkTiers(s, cap);

        uint256 poolCap = pc.caps.maxLpFeePips;
        uint256 ceiling = registry.admission(msg.sender, pc.rules).caps.maxLpFeePips;
        if (ceiling > poolCap) ceiling = poolCap;
        (uint256 after_, uint256 guard, uint256 guardEnd) = _rulesCeiling(pc, id, ceiling);

        _write(entry, id, s, _min(cap, poolCap - after_), _min(cap, poolCap - guard), guardEnd);
        return keccak256(data);
    }

    /// @inheritdoc IHookrPairAdvisory
    /// @dev `data` is an ABI-encoded Schedule. Every tier must be at most `capPips`, and `gasLimit` at least
    ///      MIN_PAIR_GAS. The pool has no guard. The schedule is keyed by the calling root.
    function bindPair(PoolId id, uint24 capPips, uint32 gasLimit, bytes calldata data) external returns (bytes4) {
        (Schedule memory s, Bound storage entry) = _open(id, data);
        if (gasLimit < MIN_PAIR_GAS) revert InvalidPoolConfig(2);
        _checkTiers(s, capPips);
        _write(entry, id, s, capPips, capPips, 0);
        return IHookrPairAdvisory.bindPair.selector;
    }

    /// @inheritdoc IHookrPairAdvisory
    function surchargeForSwap(PoolId id, bool, int256, uint160, bytes calldata, address)
        external
        view
        returns (uint24)
    {
        Bound memory b = _state().bound[msg.sender][id];
        if (!b.bound) revert UnknownPool(msg.sender, id);
        return uint24(_value(b, block.timestamp));
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Liquidity is never restricted.
    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IHookrAdvisory
    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory advice) {
        advice.lpFeeSurchargePips = uint24(_surcharge(_state().bound[msg.sender][x.id], block.timestamp));
    }

    /// @inheritdoc IHookrAdvisory
    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory advice)
    {
        return advice;
    }

    /// @inheritdoc IHookrSessionAdvisory
    function surchargeAt(address binder, PoolId id, uint256 timestamp) external view returns (uint24) {
        return uint24(_surcharge(_state().bound[binder][id], timestamp));
    }

    /// @inheritdoc IHookrSessionAdvisory
    function schedule(address binder, PoolId id) external view returns (Bound memory) {
        return _state().bound[binder][id];
    }

    /// @inheritdoc IHookrSessionAdvisory
    function sessionAt(uint256 timestamp) external view returns (HookrMarketCalendar.Session memory) {
        return HookrMarketCalendar.session(_state().calendar, timestamp);
    }

    /// @inheritdoc IHookrSessionAdvisory
    function lastCoveredYear() external view returns (uint256) {
        return HookrMarketCalendar.lastYear(_state().calendar);
    }

    /// @inheritdoc IHookrSessionAdvisory
    function appendYear(uint16 year, uint16[] calldata closed, uint16[] calldata early) external onlyOwner {
        _consume(APPEND_YEAR, abi.encode(year, closed, early));
        HookrMarketCalendar.append(_state().calendar, year, closed, early);
        emit YearAppended(year, closed, early);
    }

    /// @inheritdoc IHookrSessionAdvisory
    function markSessionDay(uint16 year, uint16 monthDay, uint8 mark) external onlyOwner {
        bytes memory arguments = abi.encode(year, monthDay, mark);
        _consume(MARK_SESSION_DAY, arguments);
        _invalidateQueued(_epochKey(MARK_SESSION_DAY, arguments));
        uint256 day = HookrMarketCalendar.mark(_state().calendar, year, monthDay, mark, block.timestamp);
        emit SessionDayMarked(day, year, monthDay, mark);
    }

    /// @inheritdoc IHookrSessionAdvisory
    function sessionDayMark(uint16 year, uint16 monthDay) external view returns (uint8) {
        return uint8(HookrMarketCalendar.markOf(_state().calendar, HookrMarketCalendar.weekdayOf(year, monthDay)));
    }

    /// @dev Queue-time admission: MARK_SESSION_DAY with canonical arguments and only when the mark could take effect
    ///      now (HookrMarketCalendar.checkMark, checked again when it executes), APPEND_YEAR with canonical arguments
    ///      (its year and dates are checked when it executes), TRANSFER_OWNER as the base checks it; every other kind
    ///      is refused.
    function _checkQueue(bytes32 kind, bytes calldata arguments) internal view override {
        if (kind == MARK_SESSION_DAY) {
            (uint16 year, uint16 monthDay, uint8 mark) = abi.decode(arguments, (uint16, uint16, uint8));
            _requireCanonical(kind, arguments, abi.encode(year, monthDay, mark));
            HookrMarketCalendar.checkMark(_state().calendar, year, monthDay, mark, block.timestamp);
        } else if (kind == APPEND_YEAR) {
            (uint16 year, uint16[] memory closed, uint16[] memory early) =
                abi.decode(arguments, (uint16, uint16[], uint16[]));
            _requireCanonical(kind, arguments, abi.encode(year, closed, early));
        } else if (kind == TRANSFER_OWNER) {
            super._checkQueue(kind, arguments);
        } else {
            revert UnknownOperation(kind);
        }
    }

    /// @dev MARK_SESSION_DAY epochs are keyed by date, so executing a mark voids every mark of its date queued before
    ///      it and no other operation. Every other kind keeps its own key.
    function _epochKey(bytes32 kind, bytes memory arguments) internal pure override returns (bytes32) {
        if (kind != MARK_SESSION_DAY) return kind;
        (uint16 year, uint16 monthDay,) = abi.decode(arguments, (uint16, uint16, uint8));
        return keccak256(abi.encode(kind, abi.encode(year, monthDay)));
    }

    /// @dev Decodes a schedule, checks its flags and ramps, and returns the caller's unbound entry for `id`.
    function _open(PoolId id, bytes calldata data) private view returns (Schedule memory s, Bound storage entry) {
        if (data.length != HookrSessionTiers.ENCODED_SIZE) revert InvalidSchedule(0);
        s = abi.decode(data, (Schedule));
        entry = _state().bound[msg.sender][id];
        if (entry.bound) revert AlreadyBound(msg.sender, id);
        _checkTiers(s, type(uint256).max);
    }

    /// @dev HookrSessionTiers.check with this contract's error: 1 unknown flag, 2 ramps too long, 3 tier above `cap`.
    function _checkTiers(Schedule memory s, uint256 cap) private pure {
        uint256 code = HookrSessionTiers.validate(_tiers(s), cap);
        if (code != 0) revert InvalidSchedule(code);
    }

    function _write(
        Bound storage entry,
        PoolId id,
        Schedule memory s,
        uint256 limit,
        uint256 guardLimit,
        uint256 guardEnd
    ) private {
        entry.regularPips = s.regularPips;
        entry.preMarketPips = s.preMarketPips;
        entry.afterHoursPips = s.afterHoursPips;
        entry.overnightPips = s.overnightPips;
        entry.closedPips = s.closedPips;
        entry.openRampSeconds = s.openRampSeconds;
        entry.closeRampSeconds = s.closeRampSeconds;
        entry.flags = s.flags;
        entry.limit = uint24(limit);
        entry.guardLimit = uint24(guardLimit);
        entry.guardEnd = uint40(guardEnd);
        entry.bound = true;
        emit SessionBound(msg.sender, id, s, uint24(limit), uint24(guardLimit));
    }

    /// @dev Tier value with the open and close ramps, clamped to the pool limit on the current block. Zero for an
    ///      unbound pool.
    function _surcharge(Bound storage stored, uint256 timestamp) private view returns (uint256) {
        Bound memory b = stored;
        return b.bound ? _value(b, timestamp) : 0;
    }

    /// @dev Tier value of a bound pool with the open and close ramps, clamped to the pool limit on the current block.
    function _value(Bound memory b, uint256 timestamp) private view returns (uint256 value) {
        value = _boundValue()(b, HookrMarketCalendar.session(_state().calendar, timestamp));
        uint256 limit = block.number < b.guardEnd ? b.guardLimit : b.limit;
        if (value > limit) value = limit;
    }

    /// @dev Largest native LP fee after and during the Rules guard, and the guard end. Uses `ceiling` alone when the
    ///      Rules does not report the Hookr rules schema or `config` does not return exactly one configuration. An
    ///      out-of-range configuration refuses the bind.
    function _rulesCeiling(HookrTypes.PoolConfig calldata pc, PoolId id, uint256 ceiling)
        private
        view
        returns (uint256 after_, uint256 guard, uint256 guardEnd)
    {
        after_ = ceiling;
        guard = ceiling;
        (bool ok, bytes memory out) = _view(pc.rules, abi.encodeWithSignature("configSchemaHash()"), 32);
        if (!ok || abi.decode(out, (bytes32)) != RULES_SCHEMA) return (after_, guard, 0);
        (ok, out) = _view(pc.rules, abi.encodeWithSignature("config(bytes32)", id), RULES_CONFIG_BYTES);
        if (!ok) return (after_, guard, 0);
        HookrTypes.RulesConfig memory c = abi.decode(out, (HookrTypes.RulesConfig));
        uint256 base = pc.baseLpFeePips;
        // LP Rewards as HookrRules quotes them: the protocol's share in pips, rounded up, then the royalty.
        uint256 lpNet = uint256(c.lpBps) * 100 - (uint256(c.lpBps) * c.protocolShareBps + 99) / 100;
        uint256 lpReward = lpNet - lpNet * c.royaltyBps / BPS;
        uint256 span = c.maxFeePips > base ? c.maxFeePips - base : 0;
        after_ = _min(ceiling, _min(NATIVE_CEILING, base + lpReward + span));
        guard = _min(ceiling, _min(NATIVE_CEILING, base + lpReward + span + c.snipeTaxPips));
        guardEnd = c.guardEndBlock;
    }

    /// @dev Bounded static call that must return exactly `size` bytes.
    function _view(address target, bytes memory input, uint256 size)
        private
        view
        returns (bool ok, bytes memory output)
    {
        output = new bytes(size);
        assembly ("memory-safe") {
            ok := staticcall(VIEW_GAS, target, add(input, 32), mload(input), add(output, 32), size)
            ok := and(ok, eq(returndatasize(), size))
        }
    }

    /// @dev A Schedule in memory is a HookrSessionTiers.Tiers: the same eight fields in the same order.
    function _tiers(Schedule memory s) private pure returns (HookrSessionTiers.Tiers memory t) {
        assembly ("memory-safe") {
            t := s
        }
    }

    /// @dev HookrSessionTiers.value taking a Bound: a Bound in memory starts with the eight fields of
    ///      HookrSessionTiers.Tiers, in the same order. Retyping the function instead of the struct avoids allocating a
    ///      zeroed Tiers on every swap.
    function _boundValue()
        private
        pure
        returns (function(Bound memory, HookrMarketCalendar.Session memory) internal pure returns (uint256) f)
    {
        function(HookrSessionTiers.Tiers memory, HookrMarketCalendar.Session memory) internal pure returns (uint256)
            g = HookrSessionTiers.value;
        assembly ("memory-safe") {
            f := g
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") {
            s.slot := STATE_SLOT
        }
    }
}
