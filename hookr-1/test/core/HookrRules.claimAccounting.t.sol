// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {EconomicsSecurityBase} from "../utils/EconomicsSecurityBase.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";

/// @notice What a claim leaves behind and what backs it, each with a mutation-gate id: claiming as ERC-6909 claims zeroes
///         the claim and the liability exactly (RL-9), the backing check fails by a single wei (RL-10), and the royalty
///         of a buy is the floored share of its gross spend (RL-1).
contract HookrRulesClaimAccountingTest is EconomicsSecurityBase {
    using CurrencyLibrary for Currency;

    uint256 internal constant PIPS = 1_000_000;

    function _owed() internal returns (PoolKey memory key, Currency quote, uint256 owed) {
        (key,, quote) = _launchMember(_member(Currency.wrap(address(0))), true);
        _buyAs(trader, key, 1e21);
        owed = rules.claimable(quote, protocol);
        assertGt(owed, 0);
    }

    /// RL-9: claimAsClaims moves the whole claim: afterwards the claim is zero, the liability fell by exactly it, and a
    /// second claim has nothing to claim.
    function test_claimAsClaimsZeroesTheClaimAndTheLiability() public {
        (, Currency quote, uint256 owed) = _owed();
        uint256 liabilityBefore = rules.totalLiability(quote);
        address alt = address(0x7777);
        vm.prank(protocol);
        assertEq(rules.claimAsClaims(quote, alt), owed);
        assertEq(rules.claimable(quote, protocol), 0, "the claim is spent whole");
        assertEq(rules.totalLiability(quote), liabilityBefore - owed, "the liability fell by exactly the claim");
        assertEq(manager.balanceOf(alt, quote.toId()), owed);
        assertTrue(rules.accountingInvariant(quote));
        vm.prank(protocol);
        vm.expectRevert(IHookrRulesState.NothingToClaim.selector);
        rules.claimAsClaims(quote, alt);
    }

    /// RL-10: the backing check is exact. The Rules own the claims that back every liability; one unit of them gone makes
    /// the check false.
    function test_theBackingCheckFailsByOneWei() public {
        (, Currency quote,) = _owed();
        assertTrue(rules.accountingInvariant(quote));
        vm.prank(address(rules));
        manager.transfer(address(0xBEEF), quote.toId(), 1);
        assertFalse(rules.accountingInvariant(quote), "one unit short of its liabilities");
    }

    /// RL-1: a buy's royalty is floor(spend x royaltyPips / 1,000,000) of the gross spend, never rounded up: the pool's
    /// native rules pay the royalty address 750 pips (500 bps of the 15,000 pips of LP Rewards left after Hookr's
    /// share).
    function testFuzz_theRoyaltyIsTheFlooredShareOfTheSpend(uint128 raw) public {
        uint128 amount = uint128(bound(raw, 1e12, 1e21));
        (PoolKey memory key,, Currency quote) = _launchMember(_member(Currency.wrap(address(0))), true);
        IHookrRouter.Swap memory p = _swap(key, true, true, amount);
        HookrTypes.ExecutionReceipt memory r = quoter.quote(p, trader);
        uint256 basis = r.actualQuote + r.quoteFee;
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
        assertEq(rules.claimable(quote, royalty), basis * 750 / PIPS, "the royalty is the floored share");
    }
}
