// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

// L-10 old numbers: protocol collection reverted while the issuer blocked the recipient, even after
// setTarget. Rules side: claimTo already pays the caller's own claim to any target; it now also
// refuses this contract as a target (no sweep exists, funds would strand).

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {EconomicsSecurityBase} from "../utils/EconomicsSecurityBase.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";

/// @notice Audit finding L-10.
contract HookrRulesClaimToTargetTest is EconomicsSecurityBase {
    using CurrencyLibrary for Currency;

    function testProtocolClaimToAlternateTarget() public {
        (PoolKey memory key,, Currency quote) = _launchMember(_member(Currency.wrap(address(0))), true);
        _buyAs(trader, key, 1e21);
        uint256 owed = rules.claimable(quote, protocol);
        assertGt(owed, 0);
        vm.prank(protocol);
        vm.expectRevert(IHookrRulesEvents.InvalidConfig.selector);
        rules.claimTo(quote, address(rules));
        address alt = address(0x7777);
        uint256 before = quote.balanceOf(alt);
        vm.prank(protocol);
        assertEq(rules.claimTo(quote, alt), owed);
        assertEq(quote.balanceOf(alt) - before, owed);
        assertEq(rules.claimable(quote, protocol), 0);
        assertTrue(rules.accountingInvariant(quote));
    }
}
