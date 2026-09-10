// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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

/// @notice Bounded-return ERC-20 helper shared by Hookr custody and routing contracts.
library HookrTokenTransfer {
    uint256 private constant TOKEN_QUERY_GAS = 50_000;

    error TokenCallFailed();
    error UnsupportedTokenBehavior();
    error PermitUnavailable();

    function safeTransfer(IHookrUtilityToken token, address to, uint256 amount) internal {
        if (!_callOptionalBool(address(token), abi.encodeCall(IHookrUtilityToken.transfer, (to, amount)))) {
            revert TokenCallFailed();
        }
    }

    function safeTransferFrom(IHookrUtilityToken token, address from, address to, uint256 amount) internal {
        if (!_callOptionalBool(address(token), abi.encodeCall(IHookrUtilityToken.transferFrom, (from, to, amount)))) {
            revert TokenCallFailed();
        }
    }

    function safeBalanceOf(IHookrUtilityToken token, address account) internal view returns (uint256 balance) {
        (bool ok, uint256 result) =
            _staticcallWord(address(token), TOKEN_QUERY_GAS, abi.encodeCall(IHookrUtilityToken.balanceOf, (account)));
        if (!ok) revert TokenCallFailed();
        balance = result;
    }

    function safeAllowance(IHookrUtilityToken token, address owner, address spender)
        internal
        view
        returns (uint256 allowance_)
    {
        (bool ok, uint256 result) = _staticcallWord(
            address(token), TOKEN_QUERY_GAS, abi.encodeCall(IHookrUtilityToken.allowance, (owner, spender))
        );
        if (!ok) revert TokenCallFailed();
        allowance_ = result;
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
        if (safeAllowance(token, owner, spender) >= amount) return;
        (bool ok, uint256 returnSize) = _callNoReturn(
            address(token), abi.encodeCall(IHookrUtilityToken.permit, (owner, spender, amount, deadline, v, r, s))
        );
        if (!ok || returnSize != 0) {
            if (safeAllowance(token, owner, spender) < amount) revert PermitUnavailable();
        }
        if (safeAllowance(token, owner, spender) < amount) revert PermitUnavailable();
    }

    /// @notice Pull an exact amount and reject inexact balance changes during the transfer.
    /// @dev Rebasing tokens remain unsupported even when a transfer itself settles exactly.
    function pullExact(IHookrUtilityToken token, address from, uint256 amount) internal {
        uint256 beforeBalance = safeBalanceOf(token, address(this));
        safeTransferFrom(token, from, address(this), amount);
        uint256 afterBalance = safeBalanceOf(token, address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert UnsupportedTokenBehavior();
        }
    }

    function _staticcallWord(address target, uint256 gasLimit, bytes memory input)
        private
        view
        returns (bool ok, uint256 word)
    {
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(gasLimit, target, add(input, 0x20), mload(input), 0, 0x20)
            if iszero(eq(returndatasize(), 0x20)) { ok := 0 }
            word := mload(0)
        }
    }

    function _callOptionalBool(address target, bytes memory input) private returns (bool valid) {
        bool ok;
        uint256 returnSize;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := call(gas(), target, 0, add(input, 0x20), mload(input), 0, 0x20)
            returnSize := returndatasize()
            word := mload(0)
        }
        return ok && (returnSize == 0 || (returnSize == 32 && word == 1));
    }

    function _callNoReturn(address target, bytes memory input) private returns (bool ok, uint256 returnSize) {
        assembly ("memory-safe") {
            ok := call(gas(), target, 0, add(input, 0x20), mload(input), 0, 0)
            returnSize := returndatasize()
        }
    }
}
