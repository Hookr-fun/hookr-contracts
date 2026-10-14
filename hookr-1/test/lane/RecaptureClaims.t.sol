// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {MockRestrictedToken} from "../mocks/MockRestrictedToken.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

/// @notice The launch position's recapture accrual (here the LP share of an arb recapture whose pool had no in-range
///         liquidity when it was flushed): HookrLauncher.claimRecapture moves it, for the family owner only, into a
///         Rules claim of the recipient the owner names, and every recapture leg (LP accrual, trader, protocol)
///         leaves the Rules as tokens or, when the quote stops delivering exact amounts (a fee switched on, a freeze),
///         as PoolManager ERC-6909 claims, so nothing locks it in the Rules.
contract RecaptureClaimsTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ScriptedExecutor internal exec;
    MockRestrictedToken internal rst;
    PoolKey internal key;
    Currency internal q;
    PoolId internal id;
    bytes32 internal family;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        exec.setRoot(address(root));
        _openLane(address(exec));
        // Issuer-controlled asset: a freeze list ("frozen") and a switchable transfer fee.
        rst = new MockRestrictedToken("Restricted", "RST", 1e30, "frozen");
        _catalogQuote(address(rst));
        rst.transfer(creator, 1e27);
        rst.transfer(whale, 1e27);
        rst.transfer(address(exec), 1e27);
        vm.prank(creator);
        rst.approve(address(launcher), type(uint256).max);
        vm.prank(whale);
        rst.approve(address(router), type(uint256).max);
        q = Currency.wrap(address(rst));
        (key, family) = _openPoolWithFamily(q, _laneRules(false), _recaptureOnlyRc());
        id = key.toId();
        // Each phase sells a little subject on the pool, against the whale's buy, then pushes 75% of 1e19: the
        // after-phase undoes part of the whale's move, so it credits the whale the trader leg of what its buy
        // accounts for.
        address subject = Currency.unwrap(_subjectOf(key));
        ERC20(subject).transfer(address(exec), 1e24);
        ScriptedExecutor.Step[] memory steps = new ScriptedExecutor.Step[](1);
        steps[0] = ScriptedExecutor.Step(key, Currency.unwrap(key.currency0) == subject, 1e15);
        exec.setPlan(steps, false, false, q);
        exec.set(ScriptedExecutor.Mode.PLAN, 1e19);
        _buy(key, q, whale, 1e20);
        // The LP share is pending; the creator exits in this block, so it becomes the creator's accrual at its flush.
        _pendingToOwner(key, family, 0, creator);
    }

    function test_claimRecaptureMovesTheAccrualIntoTheRecipientsClaim() public {
        uint256 owed = _ownerAccrued(key);
        assertGt(owed, 0, "the accrual exists");
        assertEq(_accrued(key), owed, "nothing left pending");
        uint256 liabilities = rules.totalLiability(q);
        vm.expectEmit(true, true, true, true, address(rules));
        emit IHookrRecaptureEvents.PoolClaimed(id, creator, q, owed);
        vm.prank(creator);
        assertEq(launcher.claimRecapture(family, 0, creator), 1, "one currency moved");
        assertEq(_accrued(key), 0);
        assertEq(rules.claimable(q, creator), owed);
        assertEq(rules.totalLiability(q), liabilities, "a move between ledgers, still backed");
        vm.prank(creator);
        assertEq(launcher.claimRecapture(family, 0, creator), 0, "nothing left to move");
    }

    function test_claimPaysTokensWhileTheQuoteDelivers() public {
        uint256 owed = _ownerAccrued(key);
        vm.prank(creator);
        launcher.claimRecapture(family, 0, creator);
        uint256 before = rst.balanceOf(creator);
        vm.prank(creator);
        rules.claim(q);
        assertEq(rst.balanceOf(creator) - before, owed);
        assertEq(manager.balanceOf(creator, q.toId()), 0);
    }

    /// A fee on the quote makes exact delivery fail; the claim leaves as ERC-6909 claims instead.
    function test_aFeeQuoteLeavesAsClaims() public {
        uint256 owed = _ownerAccrued(key);
        vm.prank(creator);
        launcher.claimRecapture(family, 0, creator);
        rst.setFee(100);
        vm.prank(creator);
        vm.expectRevert();
        rules.claim(q);
        vm.prank(creator);
        assertEq(rules.claimAsClaims(q, creator), owed);
        assertEq(manager.balanceOf(creator, q.toId()), owed, "paid as ERC-6909");
        assertEq(rules.claimable(q, creator), 0);
        assertTrue(rules.accountingInvariant(q));
    }

    /// A frozen recipient still gets its claim: the owner names it, and it leaves as ERC-6909 claims.
    function test_aFrozenRecipientLeavesAsClaims() public {
        uint256 owed = _ownerAccrued(key);
        rst.freeze(address(0xBEEF), true);
        vm.prank(creator);
        launcher.claimRecapture(family, 0, address(0xBEEF));
        vm.prank(address(0xBEEF));
        rules.claimAsClaims(q, address(0xBEEF));
        assertEq(manager.balanceOf(address(0xBEEF), q.toId()), owed);
        assertEq(rst.balanceOf(address(0xBEEF)), 0);
    }

    /// Only the family owner moves the accrual, only through the launcher, and never to the Rules themselves; a member
    /// that does not exist is refused.
    function test_accrualExitsAreOwnerOnly() public {
        vm.prank(attacker);
        vm.expectRevert(IHookrLauncher.NotOwner.selector);
        launcher.claimRecapture(family, 0, attacker);
        vm.prank(attacker);
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        _recap().claimPool(id, attacker);
        vm.prank(creator);
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        launcher.claimRecapture(family, 0, address(rules));
        vm.prank(creator);
        vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
        launcher.claimRecapture(family, 0, address(0));
        vm.prank(creator);
        vm.expectRevert(IHookrRootEvents.InvalidPool.selector);
        launcher.claimRecapture(family, 1, creator);
    }

    /// The trader and protocol legs are claims in the same Rules and leave the same way.
    function test_traderAndProtocolLegsLeaveAsClaimsOnAFeeQuote() public {
        uint256 protocolOwed = rules.claimable(q, protocol);
        assertGt(protocolOwed, 0, "protocol leg credited");
        rst.setFee(100);
        vm.prank(protocol);
        vm.expectRevert();
        rules.claim(q);
        vm.expectEmit(true, true, true, true, address(rules));
        emit IHookrRulesState.Claimed(q, protocol, protocol, protocolOwed);
        vm.prank(protocol);
        assertEq(rules.claimAsClaims(q, protocol), protocolOwed);
        assertEq(manager.balanceOf(protocol, q.toId()), protocolOwed);
        assertEq(rules.claimable(q, protocol), 0);
        uint256 traderOwed = rules.claimable(q, whale);
        assertGt(traderOwed, 0, "the after-phase credited the trader");
        vm.prank(whale);
        assertEq(rules.claimAsClaims(q, address(0xBEEF)), traderOwed);
        assertEq(manager.balanceOf(address(0xBEEF), q.toId()), traderOwed);
        assertTrue(rules.accountingInvariant(q));
        vm.prank(protocol);
        vm.expectRevert(IHookrRulesState.NothingToClaim.selector);
        rules.claimAsClaims(q, protocol);
    }
}
