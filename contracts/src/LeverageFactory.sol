// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILeverage, ILeverageHook} from "./interfaces/ILeverage.sol";
import {LeverageTokenDeployLib, LeverageMarketDeployLib} from "./libraries/LeverageDeployLib.sol";
import {LeverageMarket} from "./LeverageMarket.sol";

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title LeverageFactory
/// @notice Opens leverage-enabled markets: deploys the token and the market, registers the
///         pool with the hook, initializes it, and seeds the founding liquidity.
///
///         Exists because `HookrLaunchpad.setHook` is one-shot and every PoolKey it builds
///         hardcodes its own hook, so the existing launchpad cannot open a pool on a second
///         hook at all. This is that opener, and nothing else — it holds no fees and has no
///         reach into a market once created.
contract LeverageFactory {
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

    /// @dev Only the market it just created may return unconsumed seed capital. An open
    ///      receive() made stray ETH claimable by the next createMarket caller.
    receive() external payable {
        if (marketOf[pendingToken] != msg.sender && msg.sender != pendingMarket) revert BadSeed();
    }

    /// @dev Set for the duration of createMarket so the refund hop can be authenticated.
    address private pendingToken;
    address private pendingMarket;

    constructor(IPoolManager manager, ILeverageHook hook_) {
        poolManager = manager;
        hook = hook_;
    }

    function marketCount() external view returns (uint256) {
        return allMarkets.length;
    }

    /// @notice Creates a token, its leverage-enabled market, and seeds the pool.
    /// @dev The caller's ETH becomes the market's opening liquidity, paired with the whole
    ///      token supply. Price is therefore chosen by what the creator commits rather than
    ///      supplied as a number, exactly as the instant-launch path already works.
    function createMarket(
        string calldata name,
        string calldata symbol,
        string calldata tagline,
        string calldata logoURI,
        uint256 supply,
        uint160 sqrtPriceX96,
        uint128 seedLiquidity,
        ILeverage.MarketConfig calldata cfg
    ) external payable returns (address tokenAddr, address marketAddr) {
        if (msg.value == 0 || seedLiquidity == 0) revert BadSeed();

        tokenAddr = LeverageTokenDeployLib.deployToken(name, symbol, tagline, logoURI, address(this), supply);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(tokenAddr),
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
        IERC20Min(tokenAddr).transfer(marketAddr, supply);
        uint256 dust = LeverageMarket(payable(marketAddr)).seedLiquidity{value: msg.value}(
            int256(uint256(seedLiquidity)), FULL_LOWER, FULL_UPPER
        );
        // Unsold supply and unconsumed ETH belong to whoever opened the market, not to the
        // market's LPs. Leaving either behind converts a creator's capital into LP value that
        // nobody minted a share against.
        if (dust > 0) IERC20Min(tokenAddr).transfer(msg.sender, dust);
        uint256 quoteBack = address(this).balance;
        if (quoteBack > 0) {
            (bool ok,) = msg.sender.call{value: quoteBack}("");
            if (!ok) revert BadSeed();
        }

        pendingMarket = address(0);
        marketOf[tokenAddr] = marketAddr;
        allMarkets.push(marketAddr);
        emit MarketCreated(tokenAddr, marketAddr, key.toId(), msg.sender);
    }
}
