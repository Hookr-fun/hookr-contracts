// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";
import {MockFeeOnTransferToken} from "../mocks/MockFeeOnTransferToken.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

/// @dev A destination that redeems the ERC-6909 claims it holds through a PoolManager unlock.
contract ClaimsRedeemer is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function redeem(Currency currency, uint256 amount) external {
        manager.unlock(abi.encode(currency, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        manager.burn(address(this), currency.toId(), amount);
        manager.take(currency, address(this), amount);
        return "";
    }
}

/// @dev A protocol destination that can move ERC-20 balances it holds and nothing else (a splitter or buyback).
contract TokenOnlyTarget {
    address internal immutable owner = msg.sender;

    function forward(ERC20 token, address to, uint256 amount) external {
        require(msg.sender == owner);
        token.transfer(to, amount);
    }
}

/// @dev A claims source that reports an ERC-6909 payment it never makes.
contract PhantomClaimsSource {
    IPoolManager public immutable poolManager;
    address public immutable protocolRecipient;

    constructor(IPoolManager manager, address recipient) {
        poolManager = manager;
        protocolRecipient = recipient;
    }

    function claimable(Currency, address) external pure returns (uint256) {
        return 7;
    }

    function claimAsClaims(Currency, address) external pure returns (uint256) {
        return 7;
    }
}

/// @notice `HookrTreasury.collectAsClaims`: a quote that stops delivering exact amounts no longer freezes the
///         protocol's claims in it.
contract HookrTreasuryAsClaimsTest is GovernanceSecurityBase {
    MockFeeOnTransferToken internal usd;
    HookrTreasury internal treasury;
    HookrRules internal r2;
    ClaimsRedeemer internal target;
    PoolKey internal key;

    function setUp() public {
        _setUpPeriphery();
        // A quote whose issuer can switch on a transfer fee at any time; the fee is burned.
        usd = new MockFeeOnTransferToken("Switchable USD", "SUSD", 1e30, 0, address(0));
        _catalogQuote(address(usd));
        target = new ClaimsRedeemer(manager);
        treasury = new HookrTreasury(address(this), address(target), manager);
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
        key = launcher.position(fam, 0).key;
        usd.transfer(trader, 1e24);
        vm.prank(trader);
        usd.approve(address(router), type(uint256).max);
        _buy();
    }

    function _buy() internal {
        IHookrRouter.Swap memory buy = _swap(key, true, true, 1e22);
        vm.prank(trader);
        router.swap(buy, address(0), new uint256[](0));
    }

    function testFeeOnTransferSwitchedOnMidLifeNoLongerFreezesProtocolClaims() public {
        Currency q = Currency.wrap(address(usd));
        // While the quote delivers exact amounts, the token path works.
        uint256 first = r2.claimable(q, address(treasury));
        assertGt(first, 0);
        assertEq(treasury.collect(address(r2), q), first);
        assertEq(usd.balanceOf(address(target)), first);

        // More protocol claims accrue, then the issuer switches a transfer fee on.
        _buy();
        uint256 owed = r2.claimable(q, address(treasury));
        assertGt(owed, 0);
        usd.setFeeBps(100);

        // Both token paths revert: the Rules claim refuses a short delivery.
        vm.expectRevert();
        treasury.collect(address(r2), q);
        vm.expectRevert();
        treasury.collectTo(address(r2), q);
        assertEq(r2.claimable(q, address(treasury)), owed);

        // The ERC-6909 path pays the whole claim to the target, emitting the canonical collection event.
        vm.expectEmit(true, true, true, true, address(r2));
        emit IHookrRulesState.Claimed(q, address(treasury), address(target), owed);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit IHookrTreasury.ProtocolCollected(address(r2), q, address(target), owed);
        assertEq(treasury.collectAsClaims(address(r2), q), owed);
        assertEq(manager.balanceOf(address(target), q.toId()), owed);
        assertEq(r2.claimable(q, address(treasury)), 0);
        assertEq(usd.balanceOf(address(treasury)), 0);
        assertTrue(r2.accountingInvariant(q));
        // Nothing left: a second call is a no-op.
        assertEq(treasury.collectAsClaims(address(r2), q), 0);

        // Once the token delivers exact amounts again, the target redeems its ERC-6909 claims in full.
        usd.setFeeBps(0);
        target.redeem(q, owed);
        assertEq(manager.balanceOf(address(target), q.toId()), 0);
        assertEq(usd.balanceOf(address(target)), first + owed);
    }

    function testCollectAsClaimsNativeQuote() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        members[0].config.rules = address(r2);
        (bytes32 fam,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        PoolKey memory nativeKey = launcher.position(fam, 0).key;
        IHookrRouter.Swap memory buy = _swap(nativeKey, true, true, 1e21);
        vm.prank(trader);
        router.swap{value: 1e21}(buy, address(0), new uint256[](0));
        Currency native = Currency.wrap(address(0));
        uint256 owed = r2.claimable(native, address(treasury));
        assertGt(owed, 0);
        assertEq(treasury.collectAsClaims(address(r2), native), owed);
        assertEq(manager.balanceOf(address(target), native.toId()), owed);
        assertTrue(r2.accountingInvariant(native));
        uint256 before = address(target).balance;
        target.redeem(native, owed);
        assertEq(address(target).balance - before, owed);
    }

    function testCollectAsClaimsFollowsTheAcceptedTarget() public {
        Currency q = Currency.wrap(address(usd));
        uint256 owed = r2.claimable(q, address(treasury));
        address next = address(0x7A8);
        treasury.proposeTarget(next);
        vm.warp(vm.getBlockTimestamp() + treasury.TARGET_DELAY());
        treasury.acceptTarget();
        assertEq(treasury.collectAsClaims(address(r2), q), owed);
        assertEq(manager.balanceOf(next, q.toId()), owed);
        assertEq(manager.balanceOf(address(target), q.toId()), 0);
    }

    function testCollectAsClaimsRefusesUnadmittedAndChangedSources() public {
        Currency q = Currency.wrap(address(usd));
        HookrRules stranger = new HookrRules(manager, registry, address(treasury), address(root), 0);
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        treasury.collectAsClaims(address(stranger), q);
        // Naming the owned-root registry admits no Rules of a root that is not an owned root.
        treasury.setOwnedRootRegistry(address(registry));
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        treasury.collectAsClaims(address(stranger), q);
        vm.etch(address(r2), address(new PhantomClaimsSource(manager, address(treasury))).code);
        vm.expectRevert(IHookrTreasury.SourceCodeChanged.selector);
        treasury.collectAsClaims(address(r2), q);
    }

    function testCollectAsClaimsRefusesAPhantomReport() public {
        PhantomClaimsSource phantom = new PhantomClaimsSource(manager, address(treasury));
        treasury.admitSource(address(phantom));
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.ReceiptMismatch.selector, 7, 0));
        treasury.collectAsClaims(address(phantom), Currency.wrap(address(usd)));
    }

    /// A stranger cannot move a claim into ERC-6909 at the target while the token still delivers exact amounts:
    /// a token-only target could never redeem it. The token path then pays the target in tokens.
    function testCollectAsClaimsRefusesAStrangerOnAHealthyQuote() public {
        TokenOnlyTarget tokenOnly = new TokenOnlyTarget();
        treasury.proposeTarget(address(tokenOnly));
        vm.warp(vm.getBlockTimestamp() + treasury.TARGET_DELAY());
        treasury.acceptTarget();
        Currency q = Currency.wrap(address(usd));
        uint256 owed = r2.claimable(q, address(treasury));
        assertGt(owed, 0);

        vm.prank(address(0xBAD));
        vm.expectRevert(IHookrTreasury.NotOwner.selector);
        treasury.collectAsClaims(address(r2), q);
        assertEq(r2.claimable(q, address(treasury)), owed);
        assertEq(manager.balanceOf(address(tokenOnly), q.toId()), 0);

        vm.prank(address(0xBAD));
        assertEq(treasury.collectTo(address(r2), q), owed);
        assertEq(usd.balanceOf(address(tokenOnly)), owed);
        assertEq(manager.balanceOf(address(tokenOnly), q.toId()), 0);
    }

    /// The current target may take its own claim as ERC-6909; the owner may too; nobody else can.
    function testCollectAsClaimsCallers() public {
        Currency q = Currency.wrap(address(usd));
        uint256 owed = r2.claimable(q, address(treasury));
        address[3] memory refused = [address(0xBAD), address(r2), address(launcher)];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(refused[i]);
            vm.expectRevert(IHookrTreasury.NotOwner.selector);
            treasury.collectAsClaims(address(r2), q);
        }
        vm.prank(address(target));
        assertEq(treasury.collectAsClaims(address(r2), q), owed);
        assertEq(manager.balanceOf(address(target), q.toId()), owed);

        _buy();
        uint256 more = r2.claimable(q, address(treasury));
        assertGt(more, 0);
        assertEq(treasury.collectAsClaims(address(r2), q), more);
        assertEq(manager.balanceOf(address(target), q.toId()), owed + more);
    }
}
