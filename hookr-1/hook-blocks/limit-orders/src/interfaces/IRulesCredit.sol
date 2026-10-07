// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IRulesCredit
/// @dev The HookrRules surface the book uses to pass a fill's lane trader share through and to sweep strays.
interface IRulesCredit {
    function claimable(Currency currency, address beneficiary) external view returns (uint256);
    function claimTo(Currency currency, address to) external returns (uint256);
    function claimAsClaims(Currency currency, address to) external returns (uint256);
    function protocolRecipient() external view returns (address);
    function hill(PoolId id)
        external
        view
        returns (uint64 epochStart, uint64 epochEnd, address leader, uint128 leaderAmount, uint128 pot);
    function settleEpoch(PoolId id) external;
}
