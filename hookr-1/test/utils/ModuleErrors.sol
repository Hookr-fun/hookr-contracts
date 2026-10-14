// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice Reads the error the root raises for a module call it requires, inside the PoolManager's WrappedError when
///         the root raised it in a hook call: ModuleCallReverted(module, selector, reason) for a module that reverted
///         with data, `reason` that data cut to its first 132 bytes; ModuleCallFailed(module, selector) otherwise.
library ModuleErrors {
    /// @dev `data` without its first four bytes.
    function body(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }

    /// @dev The hook, the hook callback and the inner error of a PoolManager WrappedError; `wrapped` false, and the
    ///      rest empty, for any other revert.
    function unwrap(bytes memory err)
        internal
        pure
        returns (bool wrapped, address hook, bytes4 callback, bytes memory inner)
    {
        if (err.length < 4 || bytes4(err) != CustomRevert.WrappedError.selector) return (false, address(0), 0, "");
        (hook, callback, inner,) = abi.decode(body(err), (address, bytes4, bytes, bytes));
        wrapped = true;
    }

    /// @dev The module, the call's selector and the module's reason of a ModuleCallReverted; `found` false, and the
    ///      rest empty, for any other error.
    function reverted(bytes memory err)
        internal
        pure
        returns (bool found, address module, bytes4 selector, bytes memory reason)
    {
        if (err.length < 4 || bytes4(err) != IHookrRootEvents.ModuleCallReverted.selector) {
            return (false, address(0), 0, "");
        }
        (module, selector, reason) = abi.decode(body(err), (address, bytes4, bytes));
        found = true;
    }
}
