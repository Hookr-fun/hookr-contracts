// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRules} from "hookr/interfaces/IHookrRules.sol";

/// @title Hookr swap reward account
/// @notice The per-beneficiary claim address of one reward programme. HookrRules credits reward slices to this
///         address; only the minter that created it can move them, and only to itself.
/// @dev The advisory is STATICCALLed by the root, so it cannot pass a trader's identity to a singleton minter. The
///      trader's identity is therefore the address the Rules credit: CREATE2(minter, salt = beneficiary, this code).
///      There are no constructor arguments, so every account of a minter shares one init-code hash and the address
///      is derivable inside a view. Claims can accrue to the address before it has code; the minter deploys it on
///      the first settlement. The account holds nothing between calls and has no other function.
contract HookrSwapRewardAccount {
    /// @notice The only caller of `pull`, fixed at creation.
    address public immutable minter;

    error Unauthorized();

    constructor() {
        minter = msg.sender;
    }

    /// @notice Moves this account's whole backed claim in `quote` from `rules` to the minter.
    /// @dev Returns zero without calling `claimTo` when nothing is claimable. HookrRules caps one claim at the
    ///      PoolManager's int128 limit; any remainder stays claimable for the next pull.
    /// @param rules The HookrRules instance that credited the claim. Supplied by the trusted minter.
    /// @param quote The claim currency. Supplied by the trusted minter.
    /// @return amount The amount paid to the minter.
    function pull(address rules, Currency quote) external returns (uint256 amount) {
        if (msg.sender != minter) revert Unauthorized();
        if (IHookrRules(rules).claimable(quote, address(this)) == 0) return 0;
        amount = IHookrRules(rules).claimTo(quote, msg.sender);
    }
}
