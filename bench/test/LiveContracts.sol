// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";

/// @title LiveContracts
/// @notice The addresses of the live Robinhood Chain (4663) contracts the bench calls. The Hookr 1 addresses are those
///         of hookr-1/deployments/robinhood-4663.json, except the Wallet Cap Rules, deployed on 2026-10-12 and named in
///         the README; the PoolManager, Permit2, the routers, WETH and the price feed are the chain's own. Nothing
///         here is deployed by the bench.
abstract contract LiveContracts {
    // Uniswap infrastructure on 4663.
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    /// @dev The Universal Router 2.1.1 the Hookr root curates: the root asks it who the payer is, so a swap through it
    ///      is authenticated.
    address internal constant ROUTER_CURATED = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    /// @dev The second Universal Router in Uniswap's deployment registry for 4663: a later deployment with different
    ///      bytecode, which Hookr does not pin and the root does not curate (hookr-1/deployments/robinhood-4663.v2.json
    ///      records its runtime code hash). The root asks only a curated router who the payer is, so a swap through this
    ///      one is unauthenticated and the router itself is the payer the root records.
    address internal constant ROUTER_NOT_CURATED = 0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99;

    // Hookr 1: the shared root, its launcher and its Rules.
    address internal constant ROOT = 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc;
    IHookrLauncher internal constant LAUNCHER = IHookrLauncher(0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4);
    address internal constant RULES = 0x4a71c270b1520F94064268102AebD744b0DE7942;
    address internal constant RULES_WHOLE_POT = 0x10f684361b35C8411a2c07F68A6fB1F4B7e555F7;
    address internal constant RULES_WALLET_CAP = 0xb67b73E28C522a3AAC438bE970bf94976Deee52a;
    address internal constant RULES_ROUND_TRIP = 0x3d7e31746127FD9a14d3C7fC12E73611D2e8cb34;

    // Hook Blocks that run beside a pool.
    address internal constant LIMIT_ORDERS = 0x0c376cc30b1AC98b8ef80a4F516212D3B99402fA;
    address internal constant FAMILY_LOCK = 0xfAFEcE64099C1E791C4B46189c277f00c0c7e00b;
    address internal constant MARKET_GUARD = 0xFc5CAE364FDEE4347D97E2aEB82f3155068693A4;
    address internal constant BUY_SELL_BLOCK = 0xffefEA428C13813D4526fc77A8CA0df0c787626f;
    /// @dev The ETH / USD price feed the Market Guard has admitted.
    address internal constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
}
