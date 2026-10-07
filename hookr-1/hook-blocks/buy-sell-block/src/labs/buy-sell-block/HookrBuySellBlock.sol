// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../../types/HookrTypes.sol";
import {IHookrAdvisory} from "../../interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "../../interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../../interfaces/IHookrRoot.sol";
import {IHookrPairAdvisory} from "../../interfaces/IHookrPairAdvisory.sol";
import {HookrRoundTrip} from "./HookrRoundTrip.sol";
import {HookrRoundTripKey} from "./HookrRoundTripKey.sol";
import {IHookrRoundTripAdvisory} from "./interfaces/IHookrRoundTripAdvisory.sol";
import {IHookrRoundTripBook} from "./interfaces/IHookrRoundTripBook.sol";

/// @title Buy/Sell Selective Block
/// @notice A fail-closed, before-swap advisory for HookrRoot pools that refuses two kinds of trade and charges nothing:
///         - the same-block round trip: a trader that bought on the pool in this block cannot sell in it (and, in
///           mode BOTH, a trader that sold cannot buy), read from the round-trip record the pool's Rules keeps;
///         - bounded launch windows: buys refused for `buyPauseBlocks` after launch (the launch's own dev buy is
///           exempt) and sells refused for `sellLockBlocks` after launch, at most MAX_SELL_LOCK_BLOCKS;
///         - the same two exits through a liquidity position: an addition inside the sell lock, or after a same-block
///           trade the round trip blocks.
/// @dev Holders can never be trapped. A sell is refused only inside the sell lock, which ends at
///      launchBlock + sellLockBlocks (sellLockBlocks <= MAX_SELL_LOCK_BLOCKS), or when the same trader key bought on
///      the pool in the same block.number. There is no owner, keeper, setter, pause or upgrade path: every knob is
///      frozen per pool at bind. A failed read of the round-trip record counts as no record, so a read failure never
///      refuses a sell. A sell swap is not the only exit: a trader can also sell by parking subject in a
///      concentrated range that incoming buys fill, then removing it. So a liquidity addition is refused in the same two
///      cases: inside the sell lock, except the launch's own position, which the pool's liquidity owner adds in
///      the launch block; and when the adder's key traded on the pool in this block in a direction the round-trip mode
///      blocks, the liquidity owner included. Advisories have no remove hook and removal is never
///      refused, so a range added before its adder's first trade on the pool in the block is not caught, whether it
///      was added in an earlier block or earlier in the same block, the buy's own transaction included: one identity
///      can open a range, buy, let a later buyer in the block fill the range and remove it, all in one block (a
///      disclosed limit; only the sell swap and an addition after the trade are refused). "Block" is block.number, the
///      parent-chain height on Arbitrum-style chains such as 4663. Bindings are keyed by the calling root.
///      A Hookr pair root cannot refuse a swap (it only reads a surcharge), so on pair roots the advisory binds only the
///      all-zero config and returns a zero surcharge: it is inert there, and a creator cannot be shown a window it
///      would not enforce.
contract HookrBuySellBlock is IHookrAdvisory, IHookrPairAdvisory, IHookrRoundTripAdvisory {
    using PoolIdLibrary for PoolKey;

    /// @notice Pool knobs, frozen at bind from `abi.encode(Config)`.
    /// @param roundTrip ROUND_TRIP_OFF, ROUND_TRIP_SELL (refuse a sell after a buy in the same block) or
    ///        ROUND_TRIP_BOTH (also refuse a buy after a sell in the same block).
    /// @param buyPauseBlocks Buys are refused while block.number < launchBlock + buyPauseBlocks.
    /// @param sellLockBlocks Sells are refused while block.number < launchBlock + sellLockBlocks.
    struct Config {
        uint8 roundTrip;
        uint16 buyPauseBlocks;
        uint8 sellLockBlocks;
    }

    /// @notice One pool's frozen binding. Two storage slots.
    struct Binding {
        address rules;
        uint64 launchBlock;
        uint8 roundTrip;
        bool bound;
        address liquidityOwner;
        uint16 buyPauseBlocks;
        uint8 sellLockBlocks;
    }

    /// @notice Why a swap is refused. NONE means it is not.
    enum Reason {
        NONE,
        BUY_PAUSE,
        SELL_LOCK,
        ROUND_TRIP_SELL,
        ROUND_TRIP_BUY,
        LIQUIDITY_SELL_LOCK,
        LIQUIDITY_ROUND_TRIP
    }

    uint8 public constant ROUND_TRIP_OFF = 0;
    uint8 public constant ROUND_TRIP_SELL = 1;
    uint8 public constant ROUND_TRIP_BOTH = 2;

    uint8 public constant MIN_ROUND_TRIP = ROUND_TRIP_OFF;
    uint8 public constant MAX_ROUND_TRIP = ROUND_TRIP_BOTH;
    uint8 public constant DEFAULT_ROUND_TRIP = ROUND_TRIP_BOTH;

    uint16 public constant MIN_BUY_PAUSE_BLOCKS = 0;
    /// @notice About an hour of parent blocks on 4663.
    uint16 public constant MAX_BUY_PAUSE_BLOCKS = 300;
    uint16 public constant DEFAULT_BUY_PAUSE_BLOCKS = 0;

    uint8 public constant MIN_SELL_LOCK_BLOCKS = 0;
    /// @notice The longest a sell can ever be refused outside the same-block round trip: about a minute on 4663.
    uint8 public constant MAX_SELL_LOCK_BLOCKS = 5;
    uint8 public constant DEFAULT_SELL_LOCK_BLOCKS = 0;

    /// @notice Smallest advisory gas limit a pool may bind with: bind reads the admission and the Rules record flag
    ///         and writes two slots; a swap reads two slots and at most one Rules word, a liquidity addition two slots and
    ///         at most two Rules words.
    uint32 public constant MIN_ADVISORY_GAS = 60_000;
    /// @notice Gas cap of each round-trip record read: one on a swap, at most two on a liquidity addition. A failed
    ///         read counts as no record.
    uint256 public constant BOOK_READ_GAS = 20_000;
    /// @notice Smallest gas limit a pair root may bind with: one cold slot read.
    uint32 public constant MIN_PAIR_GAS = 10_000;

    mapping(address binder => mapping(PoolId => Binding)) private _bindings;
    mapping(address binder => mapping(PoolId => bool)) private _pairBound;

    /// @notice Emitted when a root binds a pool.
    event Bound(
        address indexed binder,
        PoolId indexed id,
        address rules,
        uint64 launchBlock,
        uint8 roundTrip,
        uint16 buyPauseBlocks,
        uint8 sellLockBlocks
    );

    /// @notice Emitted when a pair root binds a pool (always inert).
    event PairBound(address indexed binder, PoolId indexed id);

    /// @notice Thrown when a pair root asks for a pool it has not bound.
    error UnknownPool(address binder, PoolId id);
    /// @notice Thrown when the caller binds a pool it already bound.
    error AlreadyBound(address binder, PoolId id);
    /// @notice Thrown when the bind data or the pool's advisory settings are out of range; `code` names the check.
    error InvalidConfig(uint8 code);

    /// @inheritdoc IHookrAdvisory
    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("hookr.advisory.buysellblock.config");
    }

    /// @inheritdoc IHookrRoundTripAdvisory
    function ROUND_TRIP_ADVISORY() external pure returns (bytes32) {
        return HookrRoundTrip.MAGIC;
    }

    /// @notice The default knobs. `bind` never reads them.
    function defaults() external pure returns (Config memory) {
        return Config(DEFAULT_ROUND_TRIP, DEFAULT_BUY_PAUSE_BLOCKS, DEFAULT_SELL_LOCK_BLOCKS);
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev The caller must be a root that has this contract admitted as an ADVISORY with no quote take, binding its
    ///      own pool with this contract in the before-swap phase only and at least MIN_ADVISORY_GAS. A fail-open pool
    ///      cannot refuse a swap, so it binds only an inert config. A round-trip mode needs a Rules module that
    ///      records this pool.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32 configHash)
    {
        Config memory c = _decode(data);
        if (address(key.hooks) != msg.sender || pc.advisory != address(this)) revert InvalidConfig(1);
        if (pc.advisoryPhases != HookrTypes.BEFORE_SWAP || pc.advisoryGasLimit < MIN_ADVISORY_GAS) {
            revert InvalidConfig(2);
        }
        IHookrRegistry.Admission memory a = IHookrRoot(msg.sender).registry().admission(msg.sender, address(this));
        if (a.kind != IHookrRegistry.Kind.ADVISORY || a.implementation != address(this) || a.caps.maxQuoteTakePips != 0)
        {
            revert InvalidConfig(3);
        }
        if (pc.advisoryFailOpen && (c.roundTrip != 0 || c.buyPauseBlocks != 0 || c.sellLockBlocks != 0)) {
            revert InvalidConfig(4);
        }
        if (c.roundTrip != ROUND_TRIP_OFF && !_records(pc.rules, key.toId())) revert InvalidConfig(5);
        PoolId id = key.toId();
        Binding storage b = _bindings[msg.sender][id];
        if (b.bound) revert AlreadyBound(msg.sender, id);
        b.rules = pc.rules;
        b.launchBlock = uint64(block.number);
        b.roundTrip = c.roundTrip;
        b.bound = true;
        b.liquidityOwner = pc.liquidityOwner;
        b.buyPauseBlocks = c.buyPauseBlocks;
        b.sellLockBlocks = c.sellLockBlocks;
        emit Bound(msg.sender, id, pc.rules, uint64(block.number), c.roundTrip, c.buyPauseBlocks, c.sellLockBlocks);
        return keccak256(data);
    }

    /// @inheritdoc IHookrPairAdvisory
    /// @dev Only the all-zero config: a pair root cannot refuse, so no window or round trip can be offered there.
    function bindPair(PoolId id, uint24, uint32 gasLimit, bytes calldata data) external returns (bytes4) {
        Config memory c = _decode(data);
        if (c.roundTrip != 0 || c.buyPauseBlocks != 0 || c.sellLockBlocks != 0) revert InvalidConfig(9);
        if (gasLimit < MIN_PAIR_GAS) revert InvalidConfig(2);
        if (_pairBound[msg.sender][id]) revert AlreadyBound(msg.sender, id);
        _pairBound[msg.sender][id] = true;
        emit PairBound(msg.sender, id);
        return IHookrPairAdvisory.bindPair.selector;
    }

    /// @inheritdoc IHookrPairAdvisory
    /// @dev Always zero for a bound pool.
    function surchargeForSwap(PoolId id, bool, int256, uint160, bytes calldata, address)
        external
        view
        returns (uint24)
    {
        if (!_pairBound[msg.sender][id]) revert UnknownPool(msg.sender, id);
        return 0;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Refuses only for a Reason other than NONE (see liquidityReasonOf). Allowed for a pool the caller did not
    ///      bind. Removal is never refused.
    function beforeAddLiquidity(PoolId id, address sender) external view returns (bool) {
        Binding memory b = _bindings[msg.sender][id];
        return !b.bound || _liquidityReason(b, id, sender, tx.origin) == Reason.NONE;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Never charges. Refuses only for a Reason other than NONE. Zero advice for a pool the caller did not bind.
    function beforeSwap(HookrTypes.SwapContext calldata context)
        external
        view
        returns (HookrTypes.Advice memory advice)
    {
        Binding memory b = _bindings[msg.sender][context.id];
        if (b.bound) advice.reject = _reason(b, context, tx.origin) != Reason.NONE;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Never called: the advisory binds only with the BEFORE_SWAP phase.
    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory advice)
    {
        return advice;
    }

    /// @notice Why the swap `context`, sent from `origin`, would be refused on the pool `binder` bound, at this block.
    function reasonOf(address binder, HookrTypes.SwapContext calldata context, address origin)
        external
        view
        returns (Reason)
    {
        Binding memory b = _bindings[binder][context.id];
        if (!b.bound) return Reason.NONE;
        return _reason(b, context, origin);
    }

    /// @notice Why a liquidity addition to `id` by `sender` (the PoolManager's caller), sent from `origin`, would be
    ///         refused on the pool `binder` bound, at this block.
    /// @dev LIQUIDITY_SELL_LOCK inside the sell lock, except for the pool's liquidity owner in the launch block (the
    ///      launch's own position). LIQUIDITY_ROUND_TRIP when the round trip is on and the key of `sender` or of
    ///      `origin` itself (with `origin` as the transaction origin) bought on the pool in this block, or, in mode
    ///      BOTH, sold. The second key is the one an EOA gets when it swaps through the pinned or curated router, so an
    ///      EOA that bought that way cannot open a range order or a JIT position later in the same block through any
    ///      contract, the liquidity owner included (a launcher's family owner adding to its range), and a contract that
    ///      bought as its own identity cannot add through itself. A buy under one identity and an addition under
    ///      another are not linked (a disclosed limit). A range added before the key's first trade in the block, in an
    ///      earlier block or earlier in the same block (the buy's own transaction included), is never checked again,
    ///      since removal is never refused: it remains a same-block exit (a disclosed limit).
    function liquidityReasonOf(address binder, PoolId id, address sender, address origin)
        external
        view
        returns (Reason)
    {
        Binding memory b = _bindings[binder][id];
        if (!b.bound) return Reason.NONE;
        return _liquidityReason(b, id, sender, origin);
    }

    /// @notice The first block from which a sell on the pool, by swap or through a liquidity position added from
    ///         then on, can be refused only by the same-block round trip.
    function sellOpenFrom(address binder, PoolId id) external view returns (uint256) {
        Binding memory b = _bindings[binder][id];
        return uint256(b.launchBlock) + b.sellLockBlocks;
    }

    /// @notice The first block from which buys on the pool are open, the round trip aside.
    function buyOpenFrom(address binder, PoolId id) external view returns (uint256) {
        Binding memory b = _bindings[binder][id];
        return uint256(b.launchBlock) + b.buyPauseBlocks;
    }

    /// @notice Returns the binding of `id` by `binder`.
    function binding(address binder, PoolId id) external view returns (Binding memory) {
        return _bindings[binder][id];
    }

    function _reason(Binding memory b, HookrTypes.SwapContext calldata x, address origin)
        private
        view
        returns (Reason)
    {
        uint256 n = block.number;
        if (x.isBuy) {
            if (n < uint256(b.launchBlock) + b.buyPauseBlocks && !(n == b.launchBlock && x.sender == b.liquidityOwner))
            {
                return Reason.BUY_PAUSE;
            }
            if (b.roundTrip == ROUND_TRIP_BOTH && _traded(b.rules, x.id, _key(x, origin)) & HookrRoundTrip.SOLD != 0) {
                return Reason.ROUND_TRIP_BUY;
            }
        } else {
            if (n < uint256(b.launchBlock) + b.sellLockBlocks) return Reason.SELL_LOCK;
            if (b.roundTrip != ROUND_TRIP_OFF && _traded(b.rules, x.id, _key(x, origin)) & HookrRoundTrip.BOUGHT != 0) {
                return Reason.ROUND_TRIP_SELL;
            }
        }
        return Reason.NONE;
    }

    function _liquidityReason(Binding memory b, PoolId id, address sender, address origin)
        private
        view
        returns (Reason)
    {
        uint256 n = block.number;
        // The launch's own position: the liquidity owner adds it in the block that binds the pool, inside any lock.
        if (n < uint256(b.launchBlock) + b.sellLockBlocks && !(n == b.launchBlock && sender == b.liquidityOwner)) {
            return Reason.LIQUIDITY_SELL_LOCK;
        }
        if (b.roundTrip != ROUND_TRIP_OFF) {
            uint256 blocked =
                b.roundTrip == ROUND_TRIP_BOTH ? HookrRoundTrip.BOUGHT | HookrRoundTrip.SOLD : HookrRoundTrip.BOUGHT;
            uint256 t = _traded(b.rules, id, HookrRoundTripKey.trader(sender, sender, true, origin));
            if (sender != origin) t |= _traded(b.rules, id, HookrRoundTripKey.trader(origin, origin, true, origin));
            if (t & blocked != 0) return Reason.LIQUIDITY_ROUND_TRIP;
        }
        return Reason.NONE;
    }

    function _key(HookrTypes.SwapContext calldata x, address origin) private pure returns (bytes32) {
        return HookrRoundTripKey.trader(x.sender, x.payer, x.authenticated, origin);
    }

    /// @dev The directions `trader` traded on the pool in this block, from a bounded static read of the Rules
    ///      record. Any failure or malformed answer reads as nothing traded.
    function _traded(address rules, PoolId id, bytes32 trader) private view returns (uint256) {
        (bool ok, bytes memory out) =
            rules.staticcall{gas: BOOK_READ_GAS}(abi.encodeCall(IHookrRoundTripBook.roundTripWord, (id, trader)));
        if (!ok || out.length != 32) return 0;
        uint256 word = abi.decode(out, (uint256));
        return word >> 2 == block.number ? word & 3 : 0;
    }

    /// @dev A bounded static read of the Rules record flag at bind. Any failure means no.
    function _records(address rules, PoolId id) private view returns (bool) {
        (bool ok, bytes memory out) =
            rules.staticcall{gas: BOOK_READ_GAS}(abi.encodeCall(IHookrRoundTripBook.recordsRoundTrips, (id)));
        return ok && out.length == 32 && abi.decode(out, (uint256)) == 1;
    }

    /// @dev Exactly three words, each in range and within its MIN and MAX.
    function _decode(bytes calldata data) private pure returns (Config memory c) {
        if (data.length != 96) revert InvalidConfig(0);
        (uint256 roundTrip, uint256 buyPause, uint256 sellLock) = abi.decode(data, (uint256, uint256, uint256));
        if (roundTrip > MAX_ROUND_TRIP) revert InvalidConfig(6);
        if (buyPause > MAX_BUY_PAUSE_BLOCKS) revert InvalidConfig(7);
        if (sellLock > MAX_SELL_LOCK_BLOCKS) revert InvalidConfig(8);
        c = Config(uint8(roundTrip), uint16(buyPause), uint8(sellLock));
    }
}
