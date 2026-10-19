// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Hookr forward
/// @notice The three calls a door, an adapter or the forwarder makes into an asset it does not trust: read a balance,
///         transfer, approve. Each one carries a gas cap and copies at most one word of return data, so an asset
///         whose `balanceOf` reverts or burns gas, or whose `transfer` answers with a bomb, costs the caller its cap
///         and nothing more and never reverts the caller.
/// @dev Internal, so every user inlines it. `call` is for `transfer` and `approve`: a token that returns nothing
///      counts as success only when it has code; a returned word must be nonzero. `balanceOf` must answer exactly one
///      word. `send` is a native transfer into an empty `receive`.
library HookrForward {
    /// @notice `IERC20.transfer(to, amount)` on `asset` with `cap` gas.
    /// @return ok Whether the transfer went through.
    function transfer(address asset, address to, uint256 amount, uint256 cap) internal returns (bool ok) {
        return call(asset, abi.encodeCall(IERC20.transfer, (to, amount)), cap);
    }

    /// @notice `IERC20.approve(spender, amount)` on `asset` with `cap` gas.
    /// @return ok Whether the approval went through.
    function approve(address asset, address spender, uint256 amount, uint256 cap) internal returns (bool ok) {
        return call(asset, abi.encodeCall(IERC20.approve, (spender, amount)), cap);
    }

    /// @notice `data` on `target` with `cap` gas, judged as an ERC-20 answer: success with no return data counts only
    ///         when `target` has code; a returned word must be nonzero. Copies one word at most.
    /// @return ok Whether the call went through and answered yes.
    function call(address target, bytes memory data, uint256 cap) internal returns (bool ok) {
        uint256 size;
        assembly ("memory-safe") {
            ok := call(cap, target, 0, add(data, 0x20), mload(data), 0, 0x20)
            size := returndatasize()
            ok := and(ok, or(iszero(size), and(gt(size, 31), iszero(iszero(mload(0))))))
        }
        if (ok && size == 0 && target.code.length == 0) ok = false;
    }

    /// @notice `amount` of native ETH to `to` with `cap` gas.
    /// @return ok Whether the send went through.
    function send(address to, uint256 amount, uint256 cap) internal returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(cap, to, amount, 0, 0, 0, 0)
        }
    }

    /// @notice `IERC20.balanceOf(who)` on `asset` with `cap` gas, read from scratch space.
    /// @return ok Whether the read answered exactly one word.
    /// @return amount The balance when `ok`, zero otherwise.
    function balanceOf(address asset, address who, uint256 cap) internal view returns (bool ok, uint256 amount) {
        bytes memory data = abi.encodeCall(IERC20.balanceOf, (who));
        assembly ("memory-safe") {
            ok := staticcall(cap, asset, add(data, 0x20), mload(data), 0, 0x20)
            ok := and(ok, eq(returndatasize(), 0x20))
            amount := mul(mload(0), ok)
        }
    }
}
