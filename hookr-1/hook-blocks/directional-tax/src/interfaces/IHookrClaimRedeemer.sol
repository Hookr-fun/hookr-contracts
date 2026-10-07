// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Hookr claim redeemer
/// @notice Redeems the caller's own PoolManager ERC-6909 claims into the currency they stand for.
interface IHookrClaimRedeemer {
    /// @notice `owner` burned `amount` of its claims on `currency`; the PoolManager paid out `amount` and `recipient`
    ///         received `received`, less than `amount` only by a fee the currency's issuer charges on the transfer.
    event ClaimsRedeemed(
        address indexed owner, Currency indexed currency, address indexed recipient, uint256 amount, uint256 received
    );

    /// @notice The PoolManager has no code.
    error InvalidPoolManager();
    /// @notice A zero amount.
    error InvalidAmount(uint256 amount);
    /// @notice The zero address, this contract or the PoolManager.
    error InvalidRecipient(address recipient);
    /// @notice An unlock callback from anyone but the PoolManager.
    error NotPoolManager();
    /// @notice The PoolManager's balance fell by other than `amount`, or the recipient received more than it.
    error DeliveryMismatch(uint256 amount, uint256 debited, uint256 received);
    /// @notice The recipient received less than the caller's minimum.
    error TooLittleReceived(uint256 minimum, uint256 received);

    /// @notice The PoolManager whose claims this contract redeems.
    function poolManager() external view returns (IPoolManager);

    /// @notice Burns `amount` of the caller's ERC-6909 claims on `currency` and has the PoolManager pay `amount` of
    ///         the currency straight to `recipient`.
    /// @dev The caller first lets this contract burn the claims: `poolManager.approve(redeemer, currency.toId(),
    ///      amount)`, or `poolManager.setOperator(redeemer, true)`. Only the caller's own claims can be burned, whoever
    ///      else has approved this contract. The PoolManager's balance must fall by exactly `amount`; the recipient
    ///      bears any transfer fee the currency's issuer charges and must receive at least `minReceived`.
    /// @param currency The currency the claims stand for; zero is native ETH.
    /// @param amount The claims to burn, and the currency the PoolManager pays out.
    /// @param recipient Receives the currency; not zero, this contract or the PoolManager.
    /// @param minReceived The least `recipient` must receive.
    /// @return received What `recipient` received: `amount` for native ETH, otherwise its balance change.
    function redeem(Currency currency, uint256 amount, address recipient, uint256 minReceived)
        external
        returns (uint256 received);
}
