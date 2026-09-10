// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The project $HOOKR surface used by the utility contracts.
/// @dev This is deliberately separate from HookrToken, which is the token implementation minted
///      for launchpad launches. The project token also implements the standard EIP-2612 surface.
interface IHookrUtilityToken {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}

/// @notice Small optional-return ERC-20 transfer helper shared by the two utility contracts.
library HookrTokenTransfer {
    error TokenCallFailed();
    error UnsupportedTokenBehavior();
    error PermitUnavailable();

    function safeTransfer(IHookrUtilityToken token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(IHookrUtilityToken.transfer, (to, amount)));
        if (!ok || (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool))))) {
            revert TokenCallFailed();
        }
    }

    function safeTransferFrom(IHookrUtilityToken token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeCall(IHookrUtilityToken.transferFrom, (from, to, amount)));
        if (!ok || (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool))))) {
            revert TokenCallFailed();
        }
    }

    /// @dev A permit can be consumed by a third party before this transaction lands. That is not
    ///      a failure if it left the exact owner-to-spender allowance needed by the bounded action.
    function permitIfNeeded(
        IHookrUtilityToken token,
        address owner,
        address spender,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        if (token.allowance(owner, spender) >= amount) return;
        try token.permit(owner, spender, amount, deadline, v, r, s) {}
        catch {
            if (token.allowance(owner, spender) < amount) revert PermitUnavailable();
        }
        if (token.allowance(owner, spender) < amount) revert PermitUnavailable();
    }

    /// @notice Pull an exact amount and reject fee-on-transfer/rebasing behavior.
    function pullExact(IHookrUtilityToken token, address from, uint256 amount) internal {
        uint256 beforeBalance = token.balanceOf(address(this));
        safeTransferFrom(token, from, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert UnsupportedTokenBehavior();
        }
    }
}
