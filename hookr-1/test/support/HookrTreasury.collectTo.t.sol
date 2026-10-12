// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";
import {MockRestrictedToken} from "../mocks/MockRestrictedToken.sol";

contract Forwarder {
    receive() external payable {
        payable(address(0xF0F0)).transfer(msg.value);
    }
}

/// @notice L-10 (treasury side): the treasury could only claim Rules protocol claims to its own address, so an issuer
///         restriction on the treasury locked that currency's protocol revenue even after a target change.
/// @dev Original exploit (base b7aeae64, ReproGovernance.testL10_TreasuryRestrictedByIssuer): a 125e18 protocol claim
///      stayed locked while the issuer blocked the treasury; collect reverted before and after setTarget.
contract HookrTreasuryCollectToTest is GovernanceSecurityBase {
    MockRestrictedToken internal usd;
    HookrTreasury internal treasury;
    HookrRules internal r2;
    address internal constant TARGET = address(0x7A7);

    function setUp() public {
        _setUpPeriphery();
        // An issuer dollar whose block list reverts "restricted".
        usd = new MockRestrictedToken("Regulated USD", "RUSD", 1e30, "restricted");
        _catalogQuote(address(usd));
        treasury = new HookrTreasury(address(this), TARGET, manager);
        r2 = new HookrRules(manager, registry, address(treasury), address(root), 0);
        IHookrRegistry.Admission memory a = _rulesAdmission(address(r2), address(r2).codehash, r2.configSchemaHash());
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        treasury.admitSource(address(r2));
        usd.approve(address(launcher), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(usd)));
        members[0].config.rules = address(r2);
        (bytes32 fam,) = launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        PoolKey memory key = launcher.position(fam, 0).key;
        usd.transfer(trader, 1e24);
        IHookrRouter.Swap memory buy = _swap(key, true, true, 1e22);
        vm.startPrank(trader);
        usd.approve(address(router), type(uint256).max);
        router.swap(buy, address(0), new uint256[](0));
        vm.stopPrank();
    }

    function testIssuerRestrictionOnTreasuryNoLongerLocksRevenue() public {
        Currency q = Currency.wrap(address(usd));
        uint256 owed = r2.claimable(q, address(treasury));
        // Was 125e18 before the economics fix: the fixture pot is now refused (OD-1, potBps 0) and LP Rewards moved into
        // the LP fee, which changes the protocol amount. The property is that the whole claim is collectable, not its size.
        assertGt(owed, 0);
        usd.setBlocked(address(treasury), true);
        vm.expectRevert();
        treasury.collect(address(r2), q);
        // Old: every path reverted until the issuer lifted the restriction.
        vm.prank(address(0xCAFE));
        uint256 received = treasury.collectTo(address(r2), q);
        assertEq(received, owed);
        assertEq(usd.balanceOf(TARGET), owed);
        assertEq(usd.balanceOf(address(treasury)), 0);
        assertEq(r2.claimable(q, address(treasury)), 0);
        assertTrue(r2.accountingInvariant(q));
        assertEq(treasury.collectTo(address(r2), q), 0);
    }

    function testCollectToFollowsTheAcceptedTarget() public {
        Currency q = Currency.wrap(address(usd));
        uint256 owed = r2.claimable(q, address(treasury));
        usd.setBlocked(address(treasury), true);
        usd.setBlocked(TARGET, true);
        vm.expectRevert();
        treasury.collectTo(address(r2), q);
        treasury.proposeTarget(address(0x7A8));
        // Until the new target matures, collection still goes to the current one.
        vm.expectRevert();
        treasury.collectTo(address(r2), q);
        vm.warp(vm.getBlockTimestamp() + treasury.TARGET_DELAY());
        treasury.acceptTarget();
        assertEq(treasury.collectTo(address(r2), q), owed);
        assertEq(usd.balanceOf(address(0x7A8)), owed);
    }

    function testCollectToNativeQuoteAndForwardingTargetFailsClosed() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        members[0].config.rules = address(r2);
        (bytes32 fam,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        PoolKey memory key = launcher.position(fam, 0).key;
        IHookrRouter.Swap memory buy = _swap(key, true, true, 1e21);
        vm.prank(trader);
        router.swap{value: 1e21}(buy, address(0), new uint256[](0));
        Currency native = Currency.wrap(address(0));
        uint256 owed = r2.claimable(native, address(treasury));
        assertGt(owed, 0);
        // A target that passes received ETH on cannot be credited with an amount it did not keep.
        Forwarder forwarder = new Forwarder();
        treasury.proposeTarget(address(forwarder));
        vm.warp(vm.getBlockTimestamp() + treasury.TARGET_DELAY());
        treasury.acceptTarget();
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.ReceiptMismatch.selector, owed, 0));
        treasury.collectTo(address(r2), native);
        assertEq(r2.claimable(native, address(treasury)), owed);
        treasury.proposeTarget(TARGET);
        vm.warp(vm.getBlockTimestamp() + treasury.TARGET_DELAY());
        treasury.acceptTarget();
        uint256 before = TARGET.balance;
        assertEq(treasury.collectTo(address(r2), native), owed);
        assertEq(TARGET.balance - before, owed);
        assertTrue(r2.accountingInvariant(native));
    }

    function testCollectToRefusesUnadmittedSources() public {
        HookrRules stranger = new HookrRules(manager, registry, address(treasury), address(root), 0);
        Currency q = Currency.wrap(address(usd));
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        treasury.collectTo(address(stranger), q);
        // Naming the owned-root registry admits no Rules of a root that is not an owned root.
        treasury.setOwnedRootRegistry(address(registry));
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        treasury.collectTo(address(stranger), q);
    }
}
