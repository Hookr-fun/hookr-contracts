// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Hook Fee Split
/// @notice The arithmetic of a hook fee: what is charged, how it is divided, and how the buyback's
///         slippage floor is derived. Pure functions only, so the model in
///         `../verification/FeeSplit.lean` can be replayed against them case by case
///         (`test/FeeSplitParity.t.sol`).
/// @dev Every ceiling here is a hard bound in the contract, not a convention: the owner's share of
///      the hook fee can never exceed 10%, the hook fee can never exceed 10% of the swap's
///      specified amount, and the slippage allowance can never exceed 20%.
library HookFeeSplit {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PIPS = 1_000_000;

    /// @dev Ceiling on the hook fee: 100,000 pips = 10% of the specified amount.
    uint256 internal constant MAX_HOOK_FEE_PIPS = 100_000;
    /// @dev Ceiling on the owner's share of the hook fee: 1,000 bps = 10%.
    uint256 internal constant MAX_OWNER_BPS = 1_000;
    /// @dev Ceiling on the buyback's tolerated shortfall against the pre-swap spot estimate.
    uint256 internal constant MAX_SLIPPAGE_BPS = 2_000;

    error SharesNotNormalized(uint256 sum);
    error OwnerShareAboveCeiling(uint256 ownerBps);
    error HookFeeAboveCeiling(uint256 hookFeePips);
    error SlippageAboveCeiling(uint256 slippageBps);

    /// @notice Owner + LP + buyback weights must sum to exactly 10,000 bps, with the owner at or
    ///         below its ceiling.
    function validateShares(uint256 ownerBps, uint256 lpBps, uint256 buybackBps) internal pure {
        if (ownerBps > MAX_OWNER_BPS) revert OwnerShareAboveCeiling(ownerBps);
        if (ownerBps + lpBps + buybackBps != BPS) revert SharesNotNormalized(ownerBps + lpBps + buybackBps);
    }

    function validateHookFee(uint256 hookFeePips) internal pure {
        if (hookFeePips > MAX_HOOK_FEE_PIPS) revert HookFeeAboveCeiling(hookFeePips);
    }

    function validateSlippage(uint256 maxSlippageBps) internal pure {
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) revert SlippageAboveCeiling(maxSlippageBps);
    }

    /// @notice The hook fee, in pips of the swap's specified amount.
    /// @dev `specifiedAmount` is at most `type(int128).max` (the PoolManager enforces it) and
    ///      `hookFeePips <= 100_000`, so the product fits a uint256 and the result fits an int128.
    function hookFee(uint256 specifiedAmount, uint256 hookFeePips) internal pure returns (uint256) {
        return specifiedAmount * hookFeePips / PIPS;
    }

    /// @notice Split a collected amount three ways. The buyback leg absorbs the integer dust, so
    ///         the three legs sum to exactly `amount` — nothing is stranded in the hook.
    function split(uint256 amount, uint256 ownerBps, uint256 lpBps)
        internal
        pure
        returns (uint256 owner, uint256 lp, uint256 buyback)
    {
        owner = amount * ownerBps / BPS;
        lp = amount * lpBps / BPS;
        buyback = amount - owner - lp;
    }

    /// @notice Floor on the buyback's output, given the pre-swap spot estimate.
    function slippageFloor(uint256 spotOut, uint256 maxSlippageBps) internal pure returns (uint256) {
        return spotOut * (BPS - maxSlippageBps) / BPS;
    }

    /// @notice The two quadrants whose *specified* leg is the quote currency, and therefore the two
    ///         the hook may charge a quote-denominated fee on without touching the LP fee: an
    ///         exact-input buy (quote in) and an exact-output sell (quote out).
    /// @dev `isBuy` means "the trader receives the subject currency", i.e. pays the quote.
    function chargeable(bool isBuy, bool exactInput) internal pure returns (bool) {
        return isBuy == exactInput;
    }
}
