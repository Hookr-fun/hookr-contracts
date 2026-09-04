// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILeverage, ILeverageHook} from "./interfaces/ILeverage.sol";
import {LeverageMarketDeployLib} from "./libraries/LeverageDeployLib.sol";
import {LeverageMarket} from "./LeverageMarket.sol";

/// @title LeverageExistingTokenFactory
/// @notice Opens a leverage-enabled market for a token that ALREADY exists: the caller
///         brings the token and the ETH, and the factory deploys the market, registers the
///         pool with its hook, initializes it at the caller-attested price, and seeds the
///         founding liquidity. The BYO half of `LeverageFactory`, which can only mint fresh
///         tokens — see contracts/LEVERAGED_HOOKS_BYO_DESIGN.md for why both exist.
///
///         Same shape as the sibling factory on purpose: permissionless, no admin surface,
///         no fees held, no reach into a market once created. `LeverageMarket` and
///         `LeverageHook` are reused byte-identical — a market derives its token from
///         `key.currency1` and never assumes the token is fresh.
///
///         What is NEW here, and why every line of it exists, is the token boundary. The
///         sibling factory's token is `HookrToken`: fixed-supply, non-taxing, callback-free,
///         true-returning. An arbitrary ERC20 is none of those by default, and each
///         violation breaks a different market invariant — so this factory verifies what it
///         can (received amount equals requested, byte-for-byte, or the call reverts),
///         wraps every token call against missing/false returns, and holds a reentrancy
///         lock across the whole creation because `transferFrom` on a foreign token is a
///         call into code nobody here reviewed.
///
///         What it deliberately does NOT try to verify: that `sqrtPriceX96` matches where
///         the token really trades. No contract can read an external venue's price. A price
///         far from the real market is arbitraged against the seeder's own liquidity, and
///         the credit engine's capacity floor (min of liquidity, executable depth, bond,
///         protocol cap) bounds what a mispriced market can lend. The UI states this; the
///         factory enforces what is enforceable.
contract LeverageExistingTokenFactory {
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant FULL_LOWER = -887220;
    int24 internal constant FULL_UPPER = 887220;

    IPoolManager public immutable poolManager;
    ILeverageHook public immutable hook;

    /// @notice token => market
    mapping(address => address) public marketOf;
    address[] public allMarkets;

    event MarketCreated(address indexed token, address indexed market, PoolId poolId, address creator);

    error BadSeed();
    error BadToken();
    error MarketExists();
    /// @dev The token kept a cut of the transfer (fee-on-transfer / tax). The market's
    ///      accounting assumes amounts move whole, so such tokens are refused outright
    ///      rather than book-kept around.
    error TaxedTransfer();
    error TokenCallFailed();
    error Reentered();

    /// @dev Only the market being created may return unconsumed seed ETH mid-flight.
    receive() external payable {
        if (msg.sender != pendingMarket) revert BadSeed();
    }

    /// @dev Set for the duration of createMarket so the refund hop can be authenticated.
    address private pendingMarket;
    /// @dev Foreign-token calls can reenter; the sibling factory never needed this because
    ///      HookrToken has no hooks. 1 = unlocked, 2 = locked (non-zero base saves gas).
    uint256 private lock = 1;

    constructor(IPoolManager manager, ILeverageHook hook_) {
        poolManager = manager;
        hook = hook_;
    }

    function marketCount() external view returns (uint256) {
        return allMarkets.length;
    }

    /// @notice Opens a leverage-enabled market for an existing token.
    /// @param token       The pre-existing ERC20. Its own name/symbol stay its identity —
    ///                    this factory never takes metadata, so a market cannot be dressed
    ///                    up as a different token.
    /// @param tokenAmount Pulled from the caller to seed the pool's token leg. Must arrive
    ///                    in full: a token that taxes the transfer reverts the creation.
    /// @param sqrtPriceX96 Opening price, caller-attested to match where the token trades.
    /// @param seedLiquidity_ Liquidity units for the founding full-range position.
    function createMarket(
        address token,
        uint256 tokenAmount,
        uint160 sqrtPriceX96,
        uint128 seedLiquidity_,
        ILeverage.MarketConfig calldata cfg
    ) external payable returns (address marketAddr) {
        if (lock != 1) revert Reentered();
        lock = 2;

        if (msg.value == 0 || seedLiquidity_ == 0 || tokenAmount == 0) revert BadSeed();
        if (token.code.length == 0) revert BadToken();
        if (marketOf[token] != address(0)) revert MarketExists();

        // Pull the token leg and require it arrived whole. The balance delta — not the
        // transfer's return value — is the fact that matters: a fee-on-transfer token
        // "succeeds" while delivering less, and every downstream number would be wrong.
        uint256 before = _balanceOf(token, address(this));
        _safeTransferFrom(token, msg.sender, address(this), tokenAmount);
        if (_balanceOf(token, address(this)) - before != tokenAmount) revert TaxedTransfer();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        marketAddr = LeverageMarketDeployLib.deployMarket(poolManager, hook, key, cfg);
        pendingMarket = marketAddr;

        // Register before initialize: the hook's beforeInitialize refuses an unregistered pool.
        hook.registerPool(key, marketAddr);
        poolManager.initialize(key, sqrtPriceX96);

        // Hand the market its inventory, then let it place its own liquidity — the hook's
        // exclusivity gate compares against the immediate caller of the pool manager, so the
        // market has to open that unlock itself.
        _safeTransfer(token, marketAddr, tokenAmount);
        uint256 dust = LeverageMarket(payable(marketAddr)).seedLiquidity{value: msg.value}(
            int256(uint256(seedLiquidity_)), FULL_LOWER, FULL_UPPER
        );
        // Unconsumed seed capital belongs to whoever opened the market, not to its LPs.
        if (dust > 0) _safeTransfer(token, msg.sender, dust);
        uint256 quoteBack = address(this).balance;
        if (quoteBack > 0) {
            (bool ok,) = msg.sender.call{value: quoteBack}("");
            if (!ok) revert BadSeed();
        }

        pendingMarket = address(0);
        marketOf[token] = marketAddr;
        allMarkets.push(marketAddr);
        emit MarketCreated(token, marketAddr, key.toId(), msg.sender);
        lock = 1;
    }

    // ------------------------------------------------------------------ token boundary

    /// @dev STRICTER than a SafeTransferLib on purpose: success requires a decodable `true`,
    ///      so a USDT-style token that returns nothing is refused at creation. That is not
    ///      pedantry — `LeverageMarket` is reused byte-identical and its `IERC20Like`
    ///      declares `transfer(...) returns (bool)`, so a no-return token does not fail
    ///      here-and-now, it fails INSIDE the engine later, and the transfer that reverts
    ///      may be the one a liquidation depends on. A token the engine cannot run must
    ///      never get a market, and creation is the only gate that can hold that line.
    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) revert TokenCallFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount));
        if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) revert TokenCallFailed();
    }

    function _balanceOf(address token, address owner) private view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", owner));
        if (!ok || ret.length < 32) revert TokenCallFailed();
        return abi.decode(ret, (uint256));
    }
}
