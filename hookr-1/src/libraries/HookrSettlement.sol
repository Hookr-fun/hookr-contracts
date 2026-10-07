// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title HookrSettlement
/// @notice Exact native and ERC20 transfers for Hookr periphery contracts.
library HookrSettlement {
    using SafeERC20 for IERC20;

    error BalanceMismatch();
    error NativeTransferFailed();

    /// @notice Returns a native or ERC20 balance in raw currency units.
    function balance(Currency currency, address account) internal view returns (uint256) {
        return Currency.unwrap(currency) == address(0)
            ? account.balance
            : IERC20(Currency.unwrap(currency)).balanceOf(account);
    }

    /// @notice Settles an exact input amount. Rejects transfer taxes and balance mismatches.
    function pay(IPoolManager manager, Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;
        manager.sync(currency);
        uint256 paid;
        if (Currency.unwrap(currency) == address(0)) {
            paid = manager.settle{value: amount}();
        } else {
            uint256 beforeBalance = balance(currency, payer);
            IERC20 token = IERC20(Currency.unwrap(currency));
            if (payer == address(this)) token.safeTransfer(address(manager), amount);
            else token.safeTransferFrom(payer, address(manager), amount);
            uint256 afterBalance = balance(currency, payer);
            if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) revert BalanceMismatch();
            paid = manager.settle();
        }
        if (paid != amount) revert BalanceMismatch();
    }

    /// @notice Takes an exact output amount from PoolManager into the caller.
    function take(IPoolManager manager, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        uint256 beforeBalance = balance(currency, address(this));
        uint256 managerBefore = balance(currency, address(manager));
        manager.take(currency, address(this), amount);
        if (
            balance(currency, address(this)) != beforeBalance + amount
                || balance(currency, address(manager)) != managerBefore - amount
        ) revert BalanceMismatch();
    }

    /// @notice Pays an exact output amount from PoolManager straight to `to`, without passing through the caller.
    /// @dev ERC20 recipients must receive exactly `amount`, so a transfer fee reverts. Native recipients run code
    ///      while the caller's unlock is open; they can only make their own delivery fail.
    function takeTo(IPoolManager manager, Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        bool native = Currency.unwrap(currency) == address(0);
        uint256 theirs = native ? 0 : balance(currency, to);
        uint256 managerBefore = balance(currency, address(manager));
        manager.take(currency, to, amount);
        if (
            balance(currency, address(manager)) != managerBefore - amount
                || (!native && balance(currency, to) != theirs + amount)
        ) revert BalanceMismatch();
    }

    /// @notice Settles an exact output amount as PoolManager ERC-6909 claims for `to`. Moves no tokens.
    function mintTo(IPoolManager manager, Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 id = currency.toId();
        uint256 beforeClaims = manager.balanceOf(to, id);
        manager.mint(to, id, amount);
        if (manager.balanceOf(to, id) != beforeClaims + amount) revert BalanceMismatch();
    }

    /// @notice Delivers an exact amount to the recipient.
    function send(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (Currency.unwrap(currency) == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            uint256 ours = balance(currency, address(this));
            uint256 theirs = balance(currency, to);
            IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
            if (balance(currency, address(this)) != ours - amount || balance(currency, to) != theirs + amount) {
                revert BalanceMismatch();
            }
        }
    }
}
