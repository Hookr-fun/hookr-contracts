// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title Fee Bridge v2, the subset the tokenizer and the revenue token use
/// @notice The Fee Bridge v2 factory and the bridges it makes, in the part the tokenizer and the revenue token call: the revenue token sends a native
///         bridge a slice of each sync's ETH, and a keeper the factory lists drips it to the in-range LPs of the
///         revenue token's own market pool.
/// @dev A native bridge's `receive()` writes nothing and takes ETH from anyone, so the token's plain send lands in
///      full. The factory's owner chooses the keepers; a bridge has no owner and nothing but a drip moves its funds.
interface IHookrFeeBridge {
    /// @notice The bridge's terms, frozen when it is made.
    /// @param key The destination pool. Its hook must take no donate callback.
    /// @param currency The currency the bridge holds and donates: one side of `key`.
    /// @param maxPerDrip Most of `currency` (raw units) one drip moves, tip included.
    /// @param minBlocks Fewest blocks between two drips, 1..100,000.
    /// @param tipBps The keeper's tip in basis points of what each drip donates, 0..100.
    /// @param maxJumpBps How far in-range liquidity may have risen since the keeper's record for a drip to go ahead.
    struct Terms {
        PoolKey key;
        Currency currency;
        uint128 maxPerDrip;
        uint32 minBlocks;
        uint16 tipBps;
        uint16 maxJumpBps;
    }

    /// @notice The factory that made this bridge.
    function factory() external view returns (address);
    /// @notice The destination pool's id.
    function destinationId() external view returns (PoolId);
    /// @notice The currency the bridge holds and donates.
    function currency() external view returns (Currency);
    /// @notice What the bridge holds of its currency.
    function held() external view returns (uint256);
}

/// @title Fee Bridge v2 factory, the subset the tokenizer uses
interface IHookrFeeBridgeFactory {
    /// @notice The PoolManager every bridge donates through.
    function poolManager() external view returns (IPoolManager);
    /// @notice Makes a bridge for `terms` at a CREATE2 address keyed by (caller, salt). Permissionless.
    function create(IHookrFeeBridge.Terms calldata terms, bytes32 salt) external returns (address bridge);
    /// @notice The address `create(terms, salt)` called by `creator` deploys to.
    function predict(address creator, IHookrFeeBridge.Terms calldata terms, bytes32 salt)
        external
        view
        returns (address);
    /// @notice Whether `bridge` was made here.
    function isBridge(address bridge) external view returns (bool);
    /// @notice Whether every bridge made here takes record() and drip() from `account`.
    function isKeeper(address account) external view returns (bool);
}
