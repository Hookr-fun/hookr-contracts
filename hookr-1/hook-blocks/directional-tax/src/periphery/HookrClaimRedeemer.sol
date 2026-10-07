// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {IHookrClaimRedeemer} from "../interfaces/IHookrClaimRedeemer.sol";

/// @title HookrClaimRedeemer
/// @notice Redeems the caller's own PoolManager ERC-6909 claims into the currency they stand for, for holders that
///         cannot run a PoolManager unlock themselves: an EOA or a Safe. A tax queue's ERC-6909 exit (a Rules claim the
///         quote token will not deliver to the queue) credits such holders, the treasury's target with the protocol part
///         and the creator's recipient with the rest, and so does `HookrTreasury.collectAsClaims` (the target); they
///         turn those claims into the token here.
/// @dev Immutable, ownerless and stateless. The holder first lets this contract burn the claims, with an ERC-6909
///      `approve` of the amount or `setOperator`, then calls `redeem`; a Safe batches the two in one transaction.
///      `redeem` burns claims of `msg.sender` only, so an approval or operator grant to this contract lets nobody else
///      redeem the holder's claims, between the holder's two calls or at any later time. The PoolManager pays the
///      recipient directly, so this contract holds no claim and no token at any point; claims or tokens sent here by
///      mistake stay here.
///      Delivery is measured on the PoolManager's side: its balance must fall by exactly the amount burned, so a
///      redemption never draws on another holder's backing, and the recipient bears any fee the currency's issuer
///      charges on the transfer, down to the caller's `minReceived`. That is the case `HookrLauncher.redeem` refuses,
///      since it requires exact delivery, and an issuer fee is one of the reasons a tax queue takes its exit.
contract HookrClaimRedeemer is HookrReleased, IHookrClaimRedeemer, IUnlockCallback {
    /// @inheritdoc IHookrClaimRedeemer
    IPoolManager public immutable poolManager;

    /// @param manager The PoolManager whose claims this contract redeems.
    constructor(IPoolManager manager) {
        if (address(manager).code.length == 0) revert InvalidPoolManager();
        poolManager = manager;
    }

    /// @inheritdoc IHookrClaimRedeemer
    function redeem(Currency currency, uint256 amount, address recipient, uint256 minReceived)
        external
        returns (uint256 received)
    {
        if (amount == 0) revert InvalidAmount(amount);
        if (recipient == address(0) || recipient == address(this) || recipient == address(poolManager)) {
            revert InvalidRecipient(recipient);
        }
        received = abi.decode(poolManager.unlock(abi.encode(msg.sender, currency, amount, recipient)), (uint256));
        if (received < minReceived) revert TooLittleReceived(minReceived, received);
        emit ClaimsRedeemed(msg.sender, currency, recipient, amount, received);
    }

    /// @notice Burns the owner's claims and has the PoolManager pay the recipient.
    /// @dev The PoolManager calls back only the account that unlocked it, with that account's data, so a call from the
    ///      PoolManager is the redemption `redeem` opened, and `owner` is its caller.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address owner, Currency currency, uint256 amount, address recipient) =
            abi.decode(data, (address, Currency, uint256, address));
        poolManager.burn(owner, currency.toId(), amount);
        bool native = currency.isAddressZero();
        uint256 managerBefore = currency.balanceOf(address(poolManager));
        uint256 recipientBefore = native ? 0 : currency.balanceOf(recipient);
        poolManager.take(currency, recipient, amount);
        uint256 managerAfter = currency.balanceOf(address(poolManager));
        uint256 debited = managerAfter > managerBefore ? 0 : managerBefore - managerAfter;
        uint256 received = amount;
        if (!native) {
            uint256 recipientAfter = currency.balanceOf(recipient);
            received = recipientAfter > recipientBefore ? recipientAfter - recipientBefore : 0;
        }
        if (debited != amount || received > amount) revert DeliveryMismatch(amount, debited, received);
        return abi.encode(received);
    }
}
