// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title HookrAsset
/// @notice Balance reads and exact transfers for native ETH (the zero address) and ERC-20 assets.
/// @dev Every outbound transfer is measured. `send` requires the recipient to receive exactly the requested amount
///      (fee-on-transfer, blocked recipient, rebasing revert the caller's operation, never a swap). `sendDebit`, for
///      quote payouts to frozen recipients, requires the sender's balance to fall by exactly the amount and lets the
///      recipient bear an issuer transfer fee.
library HookrAsset {
    using SafeERC20 for IERC20;

    error NativeTransferFailed(address to, uint256 amount);
    error DeliveryMismatch(address asset, address to, uint256 expected, uint256 received);

    /// @notice Returns `account`'s balance of `asset`.
    function balanceOf(address asset, address account) internal view returns (uint256) {
        return asset == address(0) ? account.balance : IERC20(asset).balanceOf(account);
    }

    /// @notice Sends exactly `amount` of `asset` to `to` and checks that `to` received exactly that much.
    function send(address asset, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (asset == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed(to, amount);
            return;
        }
        uint256 before = IERC20(asset).balanceOf(to);
        IERC20(asset).safeTransfer(to, amount);
        uint256 afterBalance = IERC20(asset).balanceOf(to);
        if (afterBalance < before || afterBalance - before != amount) {
            revert DeliveryMismatch(asset, to, amount, afterBalance < before ? 0 : afterBalance - before);
        }
    }

    /// @notice Sends `amount` of `asset` to `to`, requiring only that this contract's balance falls by exactly
    ///         `amount`.
    /// @dev For payouts to a fixed recipient of an asset whose issuer can switch on a transfer fee: the recipient
    ///      bears the fee and the sender's books stay exact. An asset that moves more or less than `amount` out of this
    ///      contract, or credits the recipient more than `amount`, still reverts. Returns what the recipient received.
    function sendDebit(address asset, address to, uint256 amount) internal returns (uint256 received) {
        if (amount == 0) return 0;
        if (asset == address(0)) {
            send(asset, to, amount);
            return amount;
        }
        uint256 senderBefore = IERC20(asset).balanceOf(address(this));
        uint256 before = IERC20(asset).balanceOf(to);
        IERC20(asset).safeTransfer(to, amount);
        uint256 senderAfter = IERC20(asset).balanceOf(address(this));
        uint256 afterBalance = IERC20(asset).balanceOf(to);
        received = afterBalance > before ? afterBalance - before : 0;
        if (senderAfter > senderBefore || senderBefore - senderAfter != amount || received > amount) {
            revert DeliveryMismatch(asset, to, amount, received);
        }
    }

    /// @notice Pulls exactly `amount` of ERC-20 `asset` from `from` and checks this contract received exactly that much.
    function pullExact(address asset, address from, uint256 amount) internal {
        uint256 before = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = IERC20(asset).balanceOf(address(this));
        if (afterBalance < before || afterBalance - before != amount) {
            revert DeliveryMismatch(asset, address(this), amount, afterBalance < before ? 0 : afterBalance - before);
        }
    }

    /// @notice Sets an exact ERC-20 allowance, tolerating tokens that require a zero reset first.
    function approveExact(address asset, address spender, uint256 amount) internal {
        IERC20(asset).forceApprove(spender, amount);
    }
}
