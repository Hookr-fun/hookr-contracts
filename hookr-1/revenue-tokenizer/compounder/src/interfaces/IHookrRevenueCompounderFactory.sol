// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRevenueTokenizer} from "tokenizer/interfaces/IHookrRevenueTokenizer.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";

/// @title Hookr revenue compounder factory
/// @notice Makes one compounder per revenue token. `create` is anyone's call and opens the vault on the token's own
///         market pool with the factory's default terms, so the first caller cannot choose anything; `createWithPool`
///         is the token's creator's call and fixes another pool the token is in, and its own terms, as long as the
///         pool's hook cannot keep what is added or removed (`UnsafeHook`). Either call takes the token's one slot:
///         whoever calls first fixes the pool and the terms for good, so a front end shows a vault's terms and hook
///         before a deposit. No owner; the tokenizer it reads is pinned at deployment.
interface IHookrRevenueCompounderFactory {
    /// @notice `token` was not made by the tokenizer.
    error NotTokenized(address token);
    /// @notice `token` has no market pool; its creator may `createWithPool`.
    error NoMarket(address token);
    /// @notice `token` already has a compounder, `vault`.
    error VaultExists(address token, address vault);
    /// @notice Only the token's creator may fix a pool and terms of its own.
    error NotCreator(address caller);
    /// @notice `hooks` returns a delta after liquidity is added or removed, so it could keep part of what the vault
    ///         places or takes out, and it is not the token's market family's own root.
    error UnsafeHook(address hooks);
    /// @notice A constructor argument has no code.
    error InvalidConfig();

    /// @notice `vault` compounds `token` on `poolId` with these terms; made by `by`.
    event CompounderCreated(
        address indexed token,
        address indexed vault,
        PoolId indexed poolId,
        int24 bandTicks,
        uint16 tipBps,
        uint128 tipCap,
        address by
    );

    /// @notice The band width of a compounder made with `create`: 600 ticks, about 6%.
    function DEFAULT_BAND_TICKS() external view returns (int24);
    /// @notice The tip of a compounder made with `create`: 50 basis points of the quote a poke gathers.
    function DEFAULT_TIP_BPS() external view returns (uint16);
    /// @notice The tip cap of a compounder made with `create`: 0.01 ETH per poke.
    function DEFAULT_TIP_CAP() external view returns (uint128);

    /// @notice The PoolManager.
    function poolManager() external view returns (IPoolManager);
    /// @notice The tokenizer whose tokens this factory serves.
    function tokenizer() external view returns (IHookrRevenueTokenizer);
    /// @notice The tokenizer's launcher, which holds every market pool's key.
    function launcher() external view returns (IHookrLauncher);
    /// @notice The compounder of `token`, or zero.
    function vaultOf(address token) external view returns (address);
    /// @notice Number of compounders made.
    function vaultCount() external view returns (uint256);
    /// @notice The `i`-th compounder made.
    function vaultAt(uint256 i) external view returns (address);
    /// @notice The code chunks the compounder's creation code is kept in (HookrCodeStore), in order: what every
    ///         compounder is deployed from, written when the factory was.
    function codeChunks() external view returns (address[] memory);

    /// @notice Makes `token`'s compounder on its market pool with the default terms. Anyone may call.
    function create(address token) external returns (address vault);
    /// @notice Makes `token`'s compounder on `key` with the given terms. Only the token's creator. Reverts `UnsafeHook`
    ///         for a pool whose hook returns a delta after an add or a removal, unless it is the token's market
    ///         family's own root.
    function createWithPool(address token, PoolKey calldata key, int24 bandTicks, uint16 tipBps, uint128 tipCap)
        external
        returns (address vault);
}
