// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrGoverned} from "./IHookrGoverned.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRegistry} from "./IHookrRegistry.sol";

/// @title IHookrFeeAdvisory
/// @notice Interface for HookrFeeAdvisory, the fee-only BEFORE_SWAP advisory whose LP surcharge a keeper reprices
///         inside bounds the creator froze at launch.
interface IHookrFeeAdvisory is IHookrGoverned {
    /// @notice Pool configuration bytes, ABI-encoded. Pips of the pool input.
    struct Config {
        /// @notice The largest surcharge in either direction.
        uint24 cap;
        /// @notice The default surcharge while no keeper target is live.
        uint24 surcharge;
        /// @notice The default premium on zeroForOne swaps.
        uint24 premium0;
        /// @notice The default premium on oneForZero swaps.
        uint24 premium1;
        /// @notice The largest change of either directional surcharge in one update.
        uint24 maxStep;
        /// @notice The shortest time between two updates, in seconds, from 1 to MAX_MIN_INTERVAL.
        uint32 minInterval;
        /// @notice The longest lifetime of a keeper target, in seconds.
        uint32 maxTtl;
    }

    /// @notice Swap-path state of one pool. One storage slot.
    struct State {
        /// @notice The keeper surcharge on zeroForOne swaps while live.
        uint24 target0;
        /// @notice The keeper surcharge on oneForZero swaps while live.
        uint24 target1;
        /// @notice The timestamp at which the keeper surcharges lapse.
        uint40 expiry;
        /// @notice The default surcharge on zeroForOne swaps.
        uint24 default0;
        /// @notice The default surcharge on oneForZero swaps.
        uint24 default1;
        /// @notice The largest buy surcharge before `guardEnd`.
        uint24 guardCeiling;
        /// @notice The Rules guard end, on the contract's block.number clock; zero without a guard.
        uint40 guardEnd;
        /// @notice The timestamp of the last keeper update.
        uint40 updatedAt;
        /// @notice Whether the pool is bound.
        bool bound;
        /// @notice Whether the pool bound session tiers.
        bool tiered;
    }

    /// @notice Session tiers of one pool and the cap of the combined surcharge. One storage slot. The first eight
    ///         fields are the pool's HookrSessionTiers.Tiers.
    struct Session {
        /// @notice The surcharge during regular hours, in pips.
        uint24 regularPips;
        /// @notice The surcharge from 04:00 to the open, in pips.
        uint24 preMarketPips;
        /// @notice The surcharge for four hours after the close, in pips.
        uint24 afterHoursPips;
        /// @notice The surcharge from the end of after-hours to 04:00 before a trading day, in pips.
        uint24 overnightPips;
        /// @notice The surcharge on weekends, closures and the evening before them, in pips.
        uint24 closedPips;
        /// @notice The seconds after the open over which the surcharge moves linearly from the pre-market to the
        ///         regular value; zero disables.
        uint16 openRampSeconds;
        /// @notice The seconds before the close over which the surcharge moves linearly from the regular to the
        ///         after-hours value; zero disables.
        uint16 closeRampSeconds;
        /// @notice UNCOVERED_AS_CLOSED, or zero.
        uint8 flags;
        /// @notice The pool's cap, repeated here so the swap path reads one more slot, not two.
        uint24 cap;
    }

    /// @notice Immutable update bounds of one pool.
    struct Bounds {
        /// @notice The largest surcharge in either direction.
        uint24 cap;
        /// @notice The largest change of either directional surcharge in one update.
        uint24 maxStep;
        /// @notice The shortest time between two updates, in seconds.
        uint32 minInterval;
        /// @notice The longest lifetime of a keeper target, in seconds.
        uint32 maxTtl;
        /// @notice Whether a buy of the subject is a zeroForOne swap on the pool.
        bool buyZeroForOne;
        /// @notice Whether the pool is bound.
        bool bound;
        /// @notice Whether a pair root bound the pool.
        bool pair;
    }

    /// @notice `registry` holds no code.
    error InvalidRegistry(address registry);
    /// @notice `calendar` holds no code, or a pool with session tiers has none.
    error InvalidCalendar(address calendar);
    /// @notice `caller` is not a registered root acting for the pool it binds.
    error NotRoot(address caller);
    /// @notice `keeper` is the zero address.
    error InvalidKeeper(address keeper);
    /// @notice Pool `id` is already bound.
    error AlreadyBound(PoolId id);
    /// @notice Pool `id` is not bound.
    error UnknownPool(PoolId id);
    /// @notice The pool's configuration is out of bounds.
    error InvalidConfig();
    /// @notice The pool's Rules `rules` do not carry the configuration schema the advisory reads, or their fee ceiling
    ///         is out of its bounds.
    error UnsupportedRules(address rules);
    /// @notice `caller` is not a keeper.
    error NotKeeper(address caller);
    /// @notice `ttl` is zero or above the pool's `maxTtl`.
    error InvalidTtl(uint256 ttl);
    /// @notice The pool can be repriced again from `readyAt`.
    error TooSoon(uint256 readyAt);
    /// @notice A directional surcharge of `surcharge` is above the pool's `cap`.
    error AboveCap(uint256 surcharge, uint256 cap);
    /// @notice The surcharge moves from `from` to `to`, more than `maxStep`.
    error StepTooLarge(uint256 from, uint256 to, uint256 maxStep);

    /// @notice A root bound a pool to the advisory.
    /// @param id The pool.
    /// @param root The root that bound it.
    /// @param configHash The hash of the pool's configuration bytes.
    /// @param config The pool's ABI-encoded configuration.
    /// @param guardCeiling The largest buy surcharge before the guard ends.
    /// @param guardEnd The Rules guard end.
    event PoolBound(
        PoolId indexed id, address indexed root, bytes32 configHash, bytes config, uint24 guardCeiling, uint40 guardEnd
    );
    /// @notice A pair root bound a pool to the advisory.
    /// @param id The pool.
    /// @param root The pair root that bound it.
    /// @param configHash The hash of the pool's configuration bytes.
    /// @param config The pool's ABI-encoded configuration.
    event PairBound(PoolId indexed id, address indexed root, bytes32 configHash, bytes config);

    /// @notice A keeper repriced a pool.
    /// @param id The pool.
    /// @param keeper The keeper.
    /// @param target The target surcharge.
    /// @param premium0 The premium on zeroForOne swaps.
    /// @param premium1 The premium on oneForZero swaps.
    /// @param expiry The timestamp at which the keeper surcharges lapse.
    event Repriced(
        PoolId indexed id, address indexed keeper, uint24 target, uint24 premium0, uint24 premium1, uint40 expiry
    );
    /// @notice A keeper was added.
    /// @param keeper The keeper.
    event KeeperAdded(address indexed keeper);
    /// @notice A keeper was removed.
    /// @param keeper The keeper.
    event KeeperRemoved(address indexed keeper);

    /// @notice Registry whose roots may bind pools.
    /// @return The registry.
    function registry() external view returns (IHookrRegistry);

    /// @notice Shared market calendar the session tiers read (HookrSessionAdvisory), or zero when tiers are off.
    /// @return The calendar, or zero.
    function calendar() external view returns (address);

    /// @notice Returns the pair root that bound a pool, or zero.
    /// @param id The pool.
    /// @return The pair root, or zero.
    function pairRoot(PoolId id) external view returns (address);

    /// @notice Returns whether the account may reprice bound pools.
    /// @param account The account.
    /// @return True when the account may reprice.
    function isKeeper(address account) external view returns (bool);

    /// @notice Sets the keeper target and per-direction premiums of a pool for `ttl` seconds.
    /// @dev Each directional surcharge (target + premium) stays within the cap and moves at most maxStep from the
    ///      surcharge in force. Updates are at least minInterval apart. Only a keeper can call.
    /// @param id The pool.
    /// @param target The target surcharge, in pips.
    /// @param premium0 The premium on zeroForOne swaps, in pips.
    /// @param premium1 The premium on oneForZero swaps, in pips.
    /// @param ttl The seconds the target stays live, at most the pool's maxTtl.
    function reprice(PoolId id, uint24 target, uint24 premium0, uint24 premium1, uint32 ttl) external;

    /// @notice Adds a keeper. Consumes a queued ADD_KEEPER(keeper).
    /// @param keeper The keeper.
    function addKeeper(address keeper) external;

    /// @notice Removes a keeper immediately and voids ADD_KEEPER(keeper) queued before it. Its live target lapses at
    ///         its expiry.
    /// @param keeper The keeper.
    function removeKeeper(address keeper) external;

    /// @notice Removes the calling keeper.
    function resign() external;

    /// @notice Returns the surcharge a swap in the given direction pays now, in pips.
    /// @param id The pool.
    /// @param zeroForOne The swap's direction.
    /// @return The surcharge in pips.
    function surcharge(PoolId id, bool zeroForOne) external view returns (uint24);

    /// @notice Returns the session tiers of a pool and the cap of its combined surcharge; all zero without tiers.
    /// @param id The pool.
    /// @return The session tiers and the cap.
    function sessionTiers(PoolId id) external view returns (Session memory);

    /// @notice Returns the swap-path state of a pool.
    /// @param id The pool.
    /// @return The swap-path state.
    function poolState(PoolId id) external view returns (State memory);

    /// @notice Returns the immutable update bounds of a pool.
    /// @param id The pool.
    /// @return The update bounds.
    function poolBounds(PoolId id) external view returns (Bounds memory);
}
