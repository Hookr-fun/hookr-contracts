// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHookrRulesClaims
/// @notice The Hookr 1 `HookrRules` surface the vault uses: the protocol recipient every premium share is paid to, and
///         the claims ledger that holds a recapture member's liquidity owner accrual once the Launcher moves it.
interface IHookrRulesClaims {
    function protocolRecipient() external view returns (address);
    function claimable(Currency currency, address beneficiary) external view returns (uint256);
    function claim(Currency currency) external returns (uint256);
    function claimAsClaims(Currency currency, address to) external returns (uint256);
}
