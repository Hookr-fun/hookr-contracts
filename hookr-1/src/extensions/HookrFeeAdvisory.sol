// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrAdvisory} from "../interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrRules} from "../interfaces/IHookrRules.sol";
import {IHookrRulesConfig} from "../interfaces/IHookrRulesConfig.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {HookrGoverned} from "../base/HookrGoverned.sol";
import {IHookrPairAdvisory} from "../interfaces/IHookrPairAdvisory.sol";
import {IHookrPairRoot} from "../interfaces/IHookrPairRoot.sol";
import {HookrSessionTiers} from "../libraries/HookrSessionTiers.sol";
import {IHookrFeeAdvisory} from "../interfaces/IHookrFeeAdvisory.sol";

/// @title HookrFeeAdvisory
/// @notice Fee-only BEFORE_SWAP advisory for HookrRoot pools and Hookr pair roots. Charges an LP surcharge above the
///         pool's frozen base fee, which is the pool's floor. A keeper reprices the surcharge up or down inside bounds
///         the creator froze at launch. A pool may also bind session tiers, a higher fee outside US regular hours,
///         which add to the keeper's surcharge.
/// @dev The surcharge is the keeper's target plus a per-direction premium while the target is live, and the pool
///      default otherwise, plus the pool's session tier when it bound one, clamped to the cap. The tiers read the
///      shared market calendar at `calendar`. Every bound is fixed at bind: cap, default, tiers, largest step,
///      shortest interval and longest TTL. On a HookrRoot pool the cap fits the admission cap and the pool's LP-fee
///      room above the worst-case native fee, and during the Rules launch guard buys are clamped to the smaller room
///      left beside Anti-Snipe.
///      On a pair root the cap fits the root's immutable advisory cap, and only a root that a root factory
///      registered in `registry` can bind its own pool. A returned surcharge never trips a root's caps. Adding a
///      keeper is timelocked; removing one is immediate. The owner has no other power. beforeSwap and surchargeForSwap
///      read one storage slot on a pool without tiers, and surchargeForSwap reverts only for a pool the caller has not
///      bound.
contract HookrFeeAdvisory is HookrReleased, HookrGoverned, IHookrAdvisory, IHookrPairAdvisory, IHookrFeeAdvisory {
    using PoolIdLibrary for PoolKey;

    /// @notice Longest lifetime of any keeper target.
    uint32 public constant MAX_TTL = 72 hours;
    /// @notice Longest minimum interval between two keeper updates a pool may bind.
    uint32 public constant MAX_MIN_INTERVAL = 1 days;
    /// @notice Smallest advisory gas limit a pool may bind with.
    uint32 public constant MIN_ADVISORY_GAS = 30_000;
    /// @notice Smallest advisory gas limit a pair root may bind with.
    uint32 public constant MIN_PAIR_GAS = 10_000;
    /// @notice Smallest advisory gas limit, on either root type, for a pool with session tiers.
    uint32 public constant MIN_TIERED_GAS = 60_000;
    /// @notice Kind for adding a keeper.
    bytes32 public constant ADD_KEEPER = keccak256("ADD_KEEPER");
    /// @notice Configuration schema of HookrRules, the supported Rules module: HookrTypes.RULES_CONFIG_SCHEMA, the
    ///         keccak256 of RulesConfig's type string (HookrRules.configSchemaHash), the 16-word layout.
    bytes32 public constant RULES_SCHEMA = HookrTypes.RULES_CONFIG_SCHEMA;
    uint256 private constant MAX_LP_FEE = 600_000;
    uint256 private constant BPS = 10_000;
    /// @dev ABI-encoded size of a Config.
    uint256 private constant CONFIG_SIZE = 224;

    /// @inheritdoc IHookrFeeAdvisory
    IHookrRegistry public immutable registry;
    /// @inheritdoc IHookrFeeAdvisory
    address public immutable calendar;

    mapping(PoolId => State) private _state;
    mapping(PoolId => Bounds) private _bounds;
    mapping(address root => mapping(PoolId => State)) private _pairState;
    mapping(PoolId => Session) private _session;

    /// @inheritdoc IHookrFeeAdvisory
    mapping(PoolId id => address root) public pairRoot;

    /// @inheritdoc IHookrFeeAdvisory
    mapping(address account => bool) public isKeeper;

    /// @param owner_ Keeper-set owner.
    /// @param delay_ Timelock delay for adding keepers.
    /// @param registry_ Registry whose roots may bind pools.
    /// @param calendar_ Shared market calendar for session tiers, or zero to refuse tiers.
    constructor(address owner_, uint48 delay_, IHookrRegistry registry_, address calendar_)
        HookrGoverned(owner_, delay_)
    {
        if (address(registry_).code.length == 0) revert InvalidRegistry(address(registry_));
        if (calendar_ != address(0) && calendar_.code.length == 0) revert InvalidCalendar(calendar_);
        registry = registry_;
        calendar = calendar_;
    }

    /// @inheritdoc IHookrAdvisory
    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("hookr.advisory.fee.config");
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Only a registered root, for the pool it is initializing. Reads the pool's frozen Rules configuration to
    ///      size the room above the worst-case native LP fee. `data` is an ABI-encoded Config, or a Config and a
    ///      HookrSessionTiers.Tiers whose every tier is at most the cap.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32 configHash)
    {
        PoolId id = key.toId();
        if (
            !registry.isRoot(msg.sender) || address(key.hooks) != msg.sender
                || PoolId.unwrap(IHookrRoot(msg.sender).bindingPool()) != PoolId.unwrap(id)
        ) revert NotRoot(msg.sender);
        if (_bounds[id].bound) revert AlreadyBound(id);
        Config memory c;
        HookrSessionTiers.Tiers memory t;
        (c, t, configHash) = _decode(data);
        IHookrRegistry.Admission memory a = registry.admission(msg.sender, address(this));
        if (
            a.implementation != address(this) || a.kind != IHookrRegistry.Kind.ADVISORY || pc.advisory != address(this)
                || pc.advisoryPhases & HookrTypes.BEFORE_SWAP == 0 || pc.advisoryGasLimit < MIN_ADVISORY_GAS
        ) revert InvalidConfig();
        (uint256 room, uint256 guardRoom, uint40 guardEnd) = _room(id, pc);
        (uint24 default0, uint24 default1) = _defaults(c, room < a.caps.maxLpFeePips ? room : a.caps.maxLpFeePips);
        uint24 guardCeiling = guardRoom < c.cap ? uint24(guardRoom) : c.cap;
        bool tiered = _bindTiers(id, c.cap, t, data.length, pc.advisoryGasLimit);
        _state[id] = State(0, 0, 0, default0, default1, guardCeiling, guardEnd, 0, true, tiered);
        _bounds[id] = Bounds(c.cap, c.maxStep, c.minInterval, c.maxTtl, pc.quote == key.currency0, true, false);
        emit PoolBound(id, msg.sender, configHash, data, guardCeiling, guardEnd);
    }

    /// @inheritdoc IHookrPairAdvisory
    /// @dev Only a root that a root factory registered in `registry` and whose pool is `id`. `data` is an ABI-encoded
    ///      Config whose cap is at most `capPips`, optionally followed by session tiers as in `bind`. The pool has no
    ///      guard and no buy side: premium0 and premium1 price the two directions.
    function bindPair(PoolId id, uint24 capPips, uint32 gasLimit, bytes calldata data) external returns (bytes4) {
        if (
            !registry.isRoot(msg.sender) || registry.rootFactoryOf(msg.sender) == address(0)
                || PoolId.unwrap(IHookrPairRoot(msg.sender).poolId()) != PoolId.unwrap(id)
        ) revert NotRoot(msg.sender);
        if (_bounds[id].bound) revert AlreadyBound(id);
        (Config memory c, HookrSessionTiers.Tiers memory t, bytes32 configHash) = _decode(data);
        if (gasLimit < MIN_PAIR_GAS) revert InvalidConfig();
        (uint24 default0, uint24 default1) = _defaults(c, capPips);
        bool tiered = _bindTiers(id, c.cap, t, data.length, gasLimit);
        _pairState[msg.sender][id] = State(0, 0, 0, default0, default1, 0, 0, 0, true, tiered);
        _bounds[id] = Bounds(c.cap, c.maxStep, c.minInterval, c.maxTtl, false, true, true);
        pairRoot[id] = msg.sender;
        emit PairBound(id, msg.sender, configHash, data);
        return IHookrPairAdvisory.bindPair.selector;
    }

    /// @inheritdoc IHookrPairAdvisory
    function surchargeForSwap(PoolId id, bool zeroForOne, int256, uint160, bytes calldata, address)
        external
        view
        returns (uint24)
    {
        State storage s = _pairState[msg.sender][id];
        if (!s.bound) revert UnknownPool(id);
        if (s.tiered) {
            return _withSession(
                id,
                s.expiry > block.timestamp
                    ? (zeroForOne ? s.target0 : s.target1)
                    : (zeroForOne ? s.default0 : s.default1)
            );
        }
        if (s.expiry > block.timestamp) return zeroForOne ? s.target0 : s.target1;
        return zeroForOne ? s.default0 : s.default1;
    }

    /// @inheritdoc IHookrAdvisory
    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IHookrAdvisory
    function beforeSwap(HookrTypes.SwapContext calldata context)
        external
        view
        returns (HookrTypes.Advice memory advice)
    {
        advice.lpFeeSurchargePips = _surcharge(context.id, _state[context.id], context.zeroForOne, context.isBuy);
    }

    /// @inheritdoc IHookrAdvisory
    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory advice)
    {}

    /// @inheritdoc IHookrFeeAdvisory
    function reprice(PoolId id, uint24 target, uint24 premium0, uint24 premium1, uint32 ttl) external {
        if (!isKeeper[msg.sender]) revert NotKeeper(msg.sender);
        Bounds memory b = _bounds[id];
        if (!b.bound) revert UnknownPool(id);
        if (ttl == 0 || ttl > b.maxTtl) revert InvalidTtl(ttl);
        mapping(PoolId => State) storage states = _states(id, b);
        State memory s = states[id];
        if (s.updatedAt != 0 && block.timestamp < uint256(s.updatedAt) + b.minInterval) {
            revert TooSoon(uint256(s.updatedAt) + b.minInterval);
        }
        bool live = s.expiry > block.timestamp;
        uint256 next0 = uint256(target) + premium0;
        uint256 next1 = uint256(target) + premium1;
        _check(live ? s.target0 : s.default0, next0, b);
        _check(live ? s.target1 : s.default1, next1, b);
        s.target0 = uint24(next0);
        s.target1 = uint24(next1);
        s.expiry = uint40(block.timestamp + ttl);
        s.updatedAt = uint40(block.timestamp);
        states[id] = s;
        emit Repriced(id, msg.sender, target, premium0, premium1, s.expiry);
    }

    /// @inheritdoc IHookrFeeAdvisory
    function addKeeper(address keeper) external onlyOwner {
        if (keeper == address(0)) revert InvalidKeeper(keeper);
        _consume(ADD_KEEPER, abi.encode(keeper));
        isKeeper[keeper] = true;
        emit KeeperAdded(keeper);
    }

    /// @inheritdoc IHookrFeeAdvisory
    function removeKeeper(address keeper) external onlyOwner {
        _remove(keeper);
    }

    /// @inheritdoc IHookrFeeAdvisory
    function resign() external {
        _remove(msg.sender);
    }

    /// @inheritdoc IHookrFeeAdvisory
    function surcharge(PoolId id, bool zeroForOne) external view returns (uint24) {
        Bounds memory b = _bounds[id];
        return _surcharge(id, _states(id, b)[id], zeroForOne, !b.pair && zeroForOne == b.buyZeroForOne);
    }

    /// @inheritdoc IHookrFeeAdvisory
    function sessionTiers(PoolId id) external view returns (Session memory) {
        return _session[id];
    }

    /// @inheritdoc IHookrFeeAdvisory
    function poolState(PoolId id) external view returns (State memory) {
        return _states(id, _bounds[id])[id];
    }

    /// @inheritdoc IHookrFeeAdvisory
    function poolBounds(PoolId id) external view returns (Bounds memory) {
        return _bounds[id];
    }

    function _surcharge(PoolId id, State storage s, bool zeroForOne, bool isBuy) private view returns (uint24 fee) {
        if (s.expiry > block.timestamp) fee = zeroForOne ? s.target0 : s.target1;
        else fee = zeroForOne ? s.default0 : s.default1;
        if (s.tiered) fee = _withSession(id, fee);
        if (isBuy && block.number < s.guardEnd && fee > s.guardCeiling) fee = s.guardCeiling;
    }

    /// @dev The state mapping that holds `id`: per pair root for pair pools.
    function _states(PoolId id, Bounds memory b) private view returns (mapping(PoolId => State) storage) {
        return b.pair ? _pairState[pairRoot[id]] : _state;
    }

    /// @dev Keeper surcharge plus the pool's session tier now, clamped to the pool's cap. A failed calendar read
    ///      charges the highest tier.
    function _withSession(PoolId id, uint256 fee) private view returns (uint24) {
        Session memory x = _session[id];
        fee += _sessionValueAt()(x, calendar, block.timestamp);
        return fee < x.cap ? uint24(fee) : x.cap;
    }

    /// @dev Stores the tiers of a pool whose bind data carries them: nonempty, each tier at most `cap`, a calendar
    ///      set and at least MIN_TIERED_GAS of advisory gas. Returns whether the pool is tiered.
    function _bindTiers(PoolId id, uint24 cap, HookrSessionTiers.Tiers memory t, uint256 size, uint256 gasLimit)
        private
        returns (bool)
    {
        if (size == CONFIG_SIZE) return false;
        if (HookrSessionTiers.isEmpty(t) || gasLimit < MIN_TIERED_GAS) revert InvalidConfig();
        if (calendar == address(0)) revert InvalidCalendar(address(0));
        HookrSessionTiers.check(t, cap);
        _session[id] = Session(
            t.regularPips,
            t.preMarketPips,
            t.afterHoursPips,
            t.overnightPips,
            t.closedPips,
            t.openRampSeconds,
            t.closeRampSeconds,
            t.flags,
            cap
        );
        return true;
    }

    /// @dev HookrSessionTiers.valueAt taking a Session: a Session in memory starts with the eight fields of
    ///      HookrSessionTiers.Tiers, in the same order. Retyping the function instead of the struct avoids allocating a
    ///      zeroed Tiers on every swap.
    function _sessionValueAt()
        private
        pure
        returns (function(Session memory, address, uint256) internal view returns (uint256) f)
    {
        function(HookrSessionTiers.Tiers memory, address, uint256) internal view returns (uint256) g =
        HookrSessionTiers.valueAt;
        assembly ("memory-safe") {
            f := g
        }
    }

    /// @dev Decodes a Config, or a Config and session tiers, and refuses any encoding other than the canonical one.
    function _decode(bytes calldata data)
        private
        pure
        returns (Config memory c, HookrSessionTiers.Tiers memory t, bytes32 configHash)
    {
        configHash = keccak256(data);
        if (data.length == CONFIG_SIZE + HookrSessionTiers.ENCODED_SIZE) {
            (c, t) = abi.decode(data, (Config, HookrSessionTiers.Tiers));
            if (configHash != keccak256(abi.encode(c, t))) revert InvalidConfig();
        } else {
            c = abi.decode(data, (Config));
            if (configHash != keccak256(abi.encode(c))) revert InvalidConfig();
        }
    }

    /// @dev Checks the bounds of `c` against the largest cap `limit` and returns the directional defaults.
    function _defaults(Config memory c, uint256 limit) private pure returns (uint24 default0, uint24 default1) {
        uint256 d0 = uint256(c.surcharge) + c.premium0;
        uint256 d1 = uint256(c.surcharge) + c.premium1;
        if (
            c.cap == 0 || c.cap > limit || d0 > c.cap || d1 > c.cap || c.maxStep == 0 || c.minInterval == 0
                || c.minInterval > MAX_MIN_INTERVAL || c.maxTtl == 0 || c.maxTtl > MAX_TTL
        ) revert InvalidConfig();
        return (uint24(d0), uint24(d1));
    }

    function _check(uint256 current, uint256 next, Bounds memory b) private pure {
        if (next > b.cap) revert AboveCap(next, b.cap);
        uint256 step = next > current ? next - current : current - next;
        if (step > b.maxStep) revert StepTooLarge(current, next, b.maxStep);
    }

    /// @dev ADD_KEEPER epochs are keyed by keeper, so a removal voids only the re-admission of that keeper.
    function _epochKey(bytes32 kind, bytes memory arguments) internal pure override returns (bytes32) {
        return kind == ADD_KEEPER ? keccak256(abi.encode(kind, arguments)) : kind;
    }

    function _remove(address keeper) private {
        if (!isKeeper[keeper]) revert NotKeeper(keeper);
        isKeeper[keeper] = false;
        _invalidateQueued(keccak256(abi.encode(ADD_KEEPER, abi.encode(keeper))));
        emit KeeperRemoved(keeper);
    }

    /// @dev LP-fee room above the worst-case native fee, after and during the Rules guard.
    function _room(PoolId id, HookrTypes.PoolConfig calldata pc)
        private
        view
        returns (uint256 room, uint256 guardRoom, uint40 guardEnd)
    {
        if (IHookrRules(pc.rules).configSchemaHash() != RULES_SCHEMA) revert UnsupportedRules(pc.rules);
        HookrTypes.RulesConfig memory r = IHookrRulesConfig(pc.rules).config(id);
        uint256 base = pc.baseLpFeePips;
        uint256 cap = pc.caps.maxLpFeePips;
        if (r.maxFeePips < base || r.maxFeePips > MAX_LP_FEE) revert UnsupportedRules(pc.rules);
        uint256 native = _nativeCeiling(r, base, 0);
        room = cap > native ? cap - native : 0;
        guardRoom = room;
        if (r.guardEndBlock > block.number && r.snipeTaxPips != 0) {
            if (r.guardEndBlock > type(uint40).max) revert UnsupportedRules(pc.rules);
            native = _nativeCeiling(r, base, r.snipeTaxPips);
            guardRoom = cap > native ? cap - native : 0;
            guardEnd = uint40(r.guardEndBlock);
        }
    }

    /// @dev Largest native LP fee (base + Rules surcharge) HookrRules can quote, with Anti-Snipe at `snipeTax`.
    ///      Buys pay LP Rewards, as HookrRules quotes them (the protocol's share taken in pips, rounded up, then the
    ///      royalty), the dynamic fee up to the span and Snipe, less their separately rounded protocol shares. Sells
    ///      pay at most maxFeePips.
    function _nativeCeiling(HookrTypes.RulesConfig memory r, uint256 base, uint256 snipeTax)
        private
        pure
        returns (uint256 ceiling)
    {
        uint256 share = r.protocolShareBps;
        uint256 lpNet = uint256(r.lpBps) * 100 - (uint256(r.lpBps) * share + 99) / 100;
        uint256 lpReward = lpNet - lpNet * r.royaltyBps / BPS;
        if (base + lpReward >= MAX_LP_FEE) return MAX_LP_FEE;
        uint256 room = MAX_LP_FEE - base - lpReward;
        uint256 span = uint256(r.maxFeePips) - base;
        uint256 dynamicFee = span > room ? room : span;
        uint256 snipe = snipeTax > room - dynamicFee ? room - dynamicFee : snipeTax;
        uint256 slice = dynamicFee * share / BPS + snipe * share / BPS;
        if (span + snipeTax > room && share != 0) {
            // A clipped split rounds each share separately: allow one pip less protocol share.
            slice = (dynamicFee + snipe) * share / BPS;
            if (slice != 0) --slice;
        }
        ceiling = base + lpReward + dynamicFee + snipe - slice;
        if (ceiling < r.maxFeePips) ceiling = r.maxFeePips;
    }
}
