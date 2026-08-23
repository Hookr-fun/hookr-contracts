// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ILeverage, ILeverageHook} from "../interfaces/ILeverage.sol";
import {LeverageMarket} from "../LeverageMarket.sol";
import {HookrToken} from "../HookrToken.sol";

/// @title LeverageTokenDeployLib / LeverageMarketDeployLib
/// @notice The `new` statements, kept out of the factory's own runtime — and kept out of each
///         other's.
///
///         An inline `new LeverageMarket(...)` in the factory embeds the market's entire
///         creation code in the factory's bytecode and blows EIP-170 — this repo already hit
///         that exact wall and wrote it down at `HookrLaunchpadLib.sol:168`, where the same
///         problem forced `new HookrToken(...)` out of the launchpad. A `public` library is
///         DELEGATECALLed, so its code lives at its own address and the caller pays no size
///         for it.
///
///         These were ONE library until the credit book landed. A single library embeds both
///         creation codes, so it measured 24,096 B against EIP-170's 24,576 — 480 B of margin,
///         and the book needs 1,902. Splitting costs nothing behavioural and is not a
///         micro-optimisation: the two halves share no code, because a token deployment and a
///         market deployment have no common machinery. Measured after the split: token half
///         4,298 B (margin 20,278), market half carrying the book 21,804 B (margin 2,772).
///
///         Stateless by value, in this repo's convention: neither library reads or writes
///         caller storage. Every SSTORE stays with the factory.
library LeverageTokenDeployLib {
    function deployToken(
        string calldata name,
        string calldata symbol,
        string calldata tagline,
        string calldata logoURI,
        address creator,
        uint256 supply
    ) public returns (address) {
        return address(new HookrToken(name, symbol, tagline, logoURI, creator, supply));
    }
}

library LeverageMarketDeployLib {
    function deployMarket(
        IPoolManager manager,
        ILeverageHook hook,
        PoolKey memory key,
        ILeverage.MarketConfig memory cfg
    ) public returns (address) {
        return address(new LeverageMarket(manager, hook, key, cfg));
    }
}
