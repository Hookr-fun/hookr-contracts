// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title Fee bridge
/// @notice Pays another pool's LPs: whatever this contract holds in one currency is donated, a capped drip at a time, to
///         the in-range LPs of one pool fixed when it is made, by anyone, for a tip.
interface IHookrFeeBridge {
    error InvalidBridge(uint8 code);
    error Reentered();
    error TooSoon(uint256 nextBlock);
    error NothingToDrip();
    error NoLiquidity();
    error NeedsEarlierRecord(uint64 recordedAt);
    error LiquidityJumped(uint128 recorded, uint128 current);
    /// @notice The price left the record's tick-spacing bucket, so other positions may be in range: record again.
    error PriceMoved(int24 recordedTick, int24 tick);
    /// @notice record() and drip() refuse while the PoolManager is unlocked (inside someone's unlock callback).
    error ManagerUnlocked();
    error InvalidTipRecipient(address tipTo);
    error InvalidCallback();
    error UnexpectedNative(address sender);

    /// @notice The bridge's terms, frozen when it is made.
    /// @param key The destination pool. Its hook must take no donate callback, so a donation runs no outside code.
    /// @param currency The currency the bridge holds and donates: one side of `key`.
    /// @param maxPerDrip Most of `currency` (raw units) one drip moves, tip included.
    /// @param minBlocks Fewest blocks between two drips, 1..100,000.
    /// @param tipBps The caller's tip in basis points of what each drip donates, 0..100 (1%): tip * 10,000 <=
    ///        donated * tipBps, and donated + tip is the drip.
    /// @param maxJumpBps How far the pool's in-range liquidity may have risen since the record of an earlier block for a
    ///        drip to go ahead, 0..10,000 basis points; also the most one record may raise the reference over the last
    ///        (at least 1%). Liquidity added in the drip's own block above this stops the drip.
    struct Terms {
        PoolKey key;
        Currency currency;
        uint128 maxPerDrip;
        uint32 minBlocks;
        uint16 tipBps;
        uint16 maxJumpBps;
    }

    /// @notice One drip: who called, who got the tip, what the pool's LPs got and the liquidity it was paid over.
    event Dripped(address indexed caller, address indexed tipTo, uint256 donated, uint256 tip, uint128 liquidity);
    /// @notice The pool's in-range liquidity was recorded for drips in later blocks.
    event LiquidityRecorded(uint64 blockNumber, uint128 liquidity);

    /// @notice The factory that made this bridge.
    function factory() external view returns (address);
    /// @notice The destination pool's key, and its id.
    function destination() external view returns (PoolKey memory);
    function destinationId() external view returns (PoolId);
    function currency() external view returns (Currency);
    function maxPerDrip() external view returns (uint128);
    function minBlocks() external view returns (uint32);
    function tipBps() external view returns (uint16);
    function maxJumpBps() external view returns (uint16);
    /// @notice The block of the last drip (zero before the first).
    function lastDripBlock() external view returns (uint64);
    /// @notice The last liquidity record and its block (zero before the first). The liquidity is the bounded reference
    ///         a drip compares against, which can be below what was in range when it was taken.
    function recorded() external view returns (uint64 blockNumber, uint128 liquidity);
    /// @notice The tick of the last record: a drip needs the price in the same tick-spacing bucket.
    function recordedTick() external view returns (int24);
    /// @notice The anchor: the tick and reference of the last drip (or the first record), kept current by records in its
    ///         bucket. A record in another bucket starts from it, less what left range on the way.
    function anchor() external view returns (int24 tick, uint128 liquidity);
    /// @notice What the bridge holds of its currency.
    function held() external view returns (uint256);
    /// @notice Whether drip() would pass its checks now (false while the PoolManager is unlocked).
    function ready() external view returns (bool);
    /// @notice Claims this bridge's HookrRules claim in its currency into the bridge, where the next drip spends it:
    ///         the path for a bridge named as a royalty payee, which Rules credits rather than pays. Anyone.
    /// @param rules The HookrRules holding the claim.
    function collect(address rules) external returns (uint256 amount);
    /// @notice Records the pool's in-range liquidity and tick, once per block, for a drip in a later block. Anyone. The
    ///         reference may fall to any reading but rise at most maxJumpBps (at least 1%) over the last one for that
    ///         tick-spacing bucket; in a bucket other than the anchor's and the last record's, that is the anchor less
    ///         the liquidity of positions that left range on the way (at most a tenth of it). Refused while the
    ///         PoolManager is unlocked.
    function record() external returns (bool recorded_);
    /// @notice Donates min(held, maxPerDrip) less the tip to the destination's in-range LPs and pays the tip. Anyone.
    ///         Needs a record from an earlier block, the price in that record's tick-spacing bucket and in-range
    ///         liquidity at most maxJumpBps above the record.
    /// @param tipTo Receives the tip; must be nonzero when tipBps is nonzero.
    function drip(address tipTo) external returns (uint256 donated, uint256 tip);
}

/// @title Fee bridge factory
/// @notice Makes fee bridges at CREATE2 addresses keyed by (creator, salt), so a launch can name a bridge as a royalty
///         payee or tax recipient before or after it exists.
interface IHookrFeeBridgeFactory {
    event BridgeCreated(address indexed bridge, address indexed creator, PoolId indexed destination, Currency currency);

    function poolManager() external view returns (IPoolManager);
    /// @notice Makes a bridge for `terms`. Permissionless.
    function create(IHookrFeeBridge.Terms calldata terms, bytes32 salt) external returns (address bridge);
    /// @notice The address create(terms, salt) called by `creator` deploys to.
    function predict(address creator, IHookrFeeBridge.Terms calldata terms, bytes32 salt)
        external
        view
        returns (address);
    /// @notice Whether `bridge` was made here.
    function isBridge(address bridge) external view returns (bool);
}
