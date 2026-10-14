// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";

/// @notice G-01 (phase-one review, Appendix A, Informational): HookrRules.claimTo accepted the Rules contract or the
///         root as recipient, so a claim sent there left the ledger and was stranded.
/// @dev Regression for the fix. `_claim` and `_debit` refuse zero, the PoolManager, the Rules themselves and the Rules'
///      `trustedRoot`. The root has no path that moves an ERC-20 balance, so a token claim paid to it was stranded for
///      good, and an ERC-6909 balance paid to it could leave only as a protocol claim (`sweepClaims` on one of its arb
///      recapture pools). Only the claimant picks `to`, so the loss was the claimant's own. Each test keeps the review's
///      scenario: a buy credits royalty and protocol claims, then the royalty claimant names the root.
contract HookrRulesClaimToRootTest is PeripheryFixture {
    PoolKey private key;
    Currency private quote;

    function setUp() public {
        _setUpPeriphery();
        (, key,, quote) = _launch(true, false);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e21);
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
        assertGt(rules.claimable(quote, royalty), 0, "the buy credited a royalty claim");
        assertGt(rules.claimable(quote, protocol), 0, "and a protocol claim");
        assertEq(rules.trustedRoot(), address(root), "the fixture root is the Rules' trusted root");
    }

    /// @dev Zero, the PoolManager, the Rules and their root are refused on both claim paths.
    function testZeroManagerRulesAndRootAreRefused() public {
        address[4] memory refused = [address(0), address(manager), address(rules), address(root)];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(royalty);
            vm.expectRevert(IHookrRulesEvents.InvalidConfig.selector);
            rules.claimTo(quote, refused[i]);
            vm.prank(royalty);
            vm.expectRevert(IHookrRulesEvents.InvalidConfig.selector);
            rules.claimAsClaims(quote, refused[i]);
        }
    }

    /// @dev A token claim to the root is refused: the claim and the ledger stay as they were and the root receives
    ///      nothing. The claimant then claims the whole amount to an account it controls.
    function testTokenClaimToTheRootIsRefused() public {
        uint256 amount = rules.claimable(quote, royalty);
        uint256 liabilities = rules.totalLiability(quote);
        uint256 rootBefore = quote.balanceOf(address(root));
        vm.prank(royalty);
        vm.expectRevert(IHookrRulesEvents.InvalidConfig.selector);
        rules.claimTo(quote, address(root));
        assertEq(rules.claimable(quote, royalty), amount, "the claim stays");
        assertEq(rules.totalLiability(quote), liabilities, "and stays on the Rules ledger");
        assertEq(quote.balanceOf(address(root)), rootBefore, "the root received nothing");

        address wallet = address(0xC1A1);
        vm.prank(royalty);
        assertEq(rules.claimTo(quote, wallet), amount, "the claimant claims it to its own wallet");
        assertEq(quote.balanceOf(wallet), amount, "which receives all of it");
        assertEq(rules.totalLiability(quote), liabilities - amount, "and the ledger drops by it");
        assertTrue(rules.accountingInvariant(quote), "the ledger stays backed");
    }

    /// @dev claimAsClaims to the root is refused too: the root's ERC-6909 balance does not move and the claimant keeps
    ///      its claim, which it then takes as ERC-6909 claims of its own.
    function testErc6909ClaimToTheRootIsRefused() public {
        uint256 id = quote.toId();
        uint256 amount = rules.claimable(quote, royalty);
        uint256 rootBefore = manager.balanceOf(address(root), id);
        vm.prank(royalty);
        vm.expectRevert(IHookrRulesEvents.InvalidConfig.selector);
        rules.claimAsClaims(quote, address(root));
        assertEq(manager.balanceOf(address(root), id), rootBefore, "the root's ERC-6909 balance is unchanged");
        assertEq(rules.claimable(quote, royalty), amount, "the claimant keeps its claim");

        vm.prank(royalty);
        assertEq(rules.claimAsClaims(quote, royalty), amount, "the claimant takes it as its own ERC-6909 claims");
        assertEq(manager.balanceOf(royalty, id), amount, "all of it");
        assertTrue(rules.accountingInvariant(quote), "the ledger stays backed");
    }
}
