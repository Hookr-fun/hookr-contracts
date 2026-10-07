// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRules} from "hookr/interfaces/IHookrRules.sol";

/// @title HookrModuleFeeAccount
/// @notice The advisory recipient of one module version. HookrRules credits the module's quote takes here as
///         claims; only the router can have them paid out, and only to itself.
/// @dev One account per version gives exact attribution: HookrRules keeps claims per recipient
///      address, so a shared recipient could not tell which module earned what. CREATE2-deployed by the
///      router with the module address as salt, so the module can name it in its constructor.
contract HookrModuleFeeAccount {
    /// @notice The router that deployed this account and alone may pull from it.
    address public immutable router;

    error Unauthorized(address caller);

    constructor() {
        router = msg.sender;
    }

    /// @notice Pays this account's whole HookrRules claim in `currency` to the router.
    function pull(IHookrRules rules, Currency currency) external returns (uint256) {
        if (msg.sender != router) revert Unauthorized(msg.sender);
        return rules.claimTo(currency, router);
    }
}
