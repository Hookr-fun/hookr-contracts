// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {IHookrRevenueToken} from "tokenizer/interfaces/IHookrRevenueToken.sol";
import {IHookrRevenueCompounder} from "../interfaces/IHookrRevenueCompounder.sol";
import {IHookrCompounderLens} from "../interfaces/IHookrCompounderLens.sol";
import {HookrShareMath} from "../libraries/HookrShareMath.sol";

/// @title Hookr compounder lens
/// @notice The reads of a compounder a front end wants (IHookrCompounderLens), computed from the compounder's own
///         reads and the PoolManager's state. Stateless.
contract HookrCompounderLens is IHookrCompounderLens {
    using StateLibrary for IPoolManager;

    /// @inheritdoc IHookrCompounderLens
    function terms(IHookrRevenueCompounder vault) external view returns (Terms memory) {
        return Terms(
            address(vault.token()),
            vault.poolKey(),
            vault.tokenIsCurrency0(),
            vault.bandTicks(),
            vault.tipBps(),
            vault.tipCap()
        );
    }

    /// @inheritdoc IHookrCompounderLens
    function pendingFees(IHookrRevenueCompounder vault) public view returns (uint256 tokens, uint256 quote) {
        IPoolManager manager = vault.poolManager();
        PoolId id = vault.poolId();
        IHookrRevenueCompounder.Band[] memory bands = vault.bands();
        uint256 fees0;
        uint256 fees1;
        for (uint256 i; i < bands.length; ++i) {
            IHookrRevenueCompounder.Band memory b = bands[i];
            if (b.liquidity == 0) continue;
            (, uint256 last0, uint256 last1) =
                manager.getPositionInfo(id, address(vault), b.tickLower, b.tickUpper, bytes32(0));
            (uint256 inside0, uint256 inside1) = manager.getFeeGrowthInside(id, b.tickLower, b.tickUpper);
            // Fee growth wraps; the difference is the pool's own rule.
            unchecked {
                fees0 += FullMath.mulDiv(inside0 - last0, b.liquidity, FixedPoint128.Q128);
                fees1 += FullMath.mulDiv(inside1 - last1, b.liquidity, FixedPoint128.Q128);
            }
        }
        return vault.tokenIsCurrency0() ? (fees0, fees1) : (fees1, fees0);
    }

    /// @inheritdoc IHookrCompounderLens
    function totals(IHookrRevenueCompounder vault) public view returns (uint256 tokens, uint256 quote) {
        (tokens, quote) = vault.holdings();
        (uint256 feeTokens, uint256 feeQuote) = pendingFees(vault);
        tokens += feeTokens;
        quote += feeQuote;
        IHookrRevenueToken token = vault.token();
        Currency q = vault.quote();
        uint256 n = token.assetCount();
        for (uint256 i; i < n; ++i) {
            if (token.assetAt(i).currency == q) quote += token.claimable(address(vault), i);
        }
    }

    /// @inheritdoc IHookrCompounderLens
    function previewDeposit(IHookrRevenueCompounder vault, uint256 tokensMax, uint256 quoteMax)
        external
        view
        returns (uint256 shares, uint256 tokens, uint256 quote)
    {
        (uint256 totalTokens, uint256 totalQuote) = totals(vault);
        uint256 supply = ERC20(address(vault)).totalSupply();
        (shares, tokens, quote) = HookrShareMath.sharesFor(supply, totalTokens, totalQuote, tokensMax, quoteMax);
        if (supply == 0) {
            uint256 minimum = vault.MIN_SHARES();
            shares = shares > minimum ? shares - minimum : 0;
        }
    }

    /// @inheritdoc IHookrCompounderLens
    function previewRedeem(IHookrRevenueCompounder vault, uint256 shares)
        external
        view
        returns (uint256 tokens, uint256 quote)
    {
        uint256 supply = ERC20(address(vault)).totalSupply();
        if (supply == 0) return (0, 0);
        (uint256 totalTokens, uint256 totalQuote) = totals(vault);
        return (FullMath.mulDiv(totalTokens, shares, supply), FullMath.mulDiv(totalQuote, shares, supply));
    }
}
