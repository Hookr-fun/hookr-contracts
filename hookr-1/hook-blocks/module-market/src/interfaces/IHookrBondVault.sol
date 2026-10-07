// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHookrBondVault
/// @notice $HOOKR bonds behind module versions, and the backers' share of each version's usage fees.
interface IHookrBondVault {
    /// @notice The marketplace this vault serves.
    function market() external view returns (address);

    /// @notice $HOOKR currently bonded behind a version (after slashes).
    function totalAssets(uint256 versionId) external view returns (uint256);

    /// @notice Outstanding bond shares of a version.
    function totalShares(uint256 versionId) external view returns (uint256);

    /// @notice Whether the backers' share in `currency` can be streamed to this version's bond now.
    function canNotify(uint256 versionId, Currency currency) external view returns (bool);

    /// @notice Streams `amount` of `currency` to the version's bond holders. Only the router can call.
    /// @dev Native ETH arrives as msg.value; an ERC-20 is transferred by the router before the call.
    function notifyReward(uint256 versionId, Currency currency, uint256 amount) external payable;

    /// @notice Takes `bps` of the version's bond and pays it to `recipient`. Only the marketplace can call.
    function slash(uint256 versionId, uint16 bps, address recipient) external returns (uint256 amount);
}
