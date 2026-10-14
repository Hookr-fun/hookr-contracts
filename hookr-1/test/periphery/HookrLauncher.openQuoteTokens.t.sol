// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrSettlement} from "../../src/libraries/HookrSettlement.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";
import {MockFeeOnTransferToken} from "../mocks/MockFeeOnTransferToken.sol";
import {MockRestrictedToken} from "../mocks/MockRestrictedToken.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

/// @dev Balances are shares times an index the issuer moves: a rebase changes every holder's balance at once,
///      the PoolManager's included. Transfers at a fixed index are exact.
contract RebaseToken {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    string public constant name = "Rebase";
    string public constant symbol = "RBS";
    uint8 public constant decimals = 18;
    address internal immutable issuer;
    uint256 public index = 1e18;
    uint256 internal totalShares;
    mapping(address => uint256) internal shares;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        issuer = msg.sender;
        shares[msg.sender] = 1e30;
        totalShares = 1e30;
    }

    function rebase(uint256 newIndex) external {
        require(msg.sender == issuer);
        index = newIndex;
    }

    function balanceOf(address account) external view returns (uint256) {
        return shares[account] * index / 1e18;
    }

    function totalSupply() external view returns (uint256) {
        return totalShares * index / 1e18;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 moved = amount * 1e18 / index;
        shares[from] -= moved;
        shares[to] += moved;
        emit Transfer(from, to, amount);
    }
}

/// @dev A hostile quote: once armed, every transfer it makes tries to take another currency's Rules claims (its own
///      ETH royalty, paid or as ERC-6909) and to swap on another pool. It records what each attempt returned.
contract ReentrantToken is ERC20 {
    HookrRules internal immutable rules;
    HookrRouter internal immutable router;
    bool public armed;
    bool public claimEntered;
    bool public claimAsClaimsEntered;
    bool public swapEntered;
    bytes public claimError;
    bytes public claimAsClaimsError;
    IHookrRouter.Swap internal ethSwap;

    constructor(HookrRules rules_, HookrRouter router_) ERC20("Hostile", "HST") {
        rules = rules_;
        router = router_;
        _mint(msg.sender, 1e30);
    }

    function arm(IHookrRouter.Swap calldata s) external {
        armed = true;
        ethSwap = s;
    }

    function claimOwn() external returns (uint256) {
        return rules.claim(Currency.wrap(address(this)));
    }

    function claimEth() external returns (uint256) {
        return rules.claim(Currency.wrap(address(0)));
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (!armed) return;
        armed = false;
        try rules.claim(Currency.wrap(address(0))) {
            claimEntered = true;
        } catch (bytes memory reason) {
            claimError = reason;
        }
        try rules.claimAsClaims(Currency.wrap(address(0)), address(this)) {
            claimAsClaimsEntered = true;
        } catch (bytes memory reason) {
            claimAsClaimsError = reason;
        }
        try router.swap{value: 1e15}(ethSwap, address(0), new uint256[](0)) {
            swapEntered = true;
        } catch {}
    }

    receive() external payable {}
}

/// @notice Q-01: in any-quote mode, a fee-on-transfer, a rebasing, a pausable and a blocklisting token can each be a
///         quote. None of them can reach a claim, a balance or an exit in any other currency: HookrRules keeps every
///         claim and liability per currency, the Hookr router and Launcher move exact amounts or revert, and an LP can
///         leave the affected side as PoolManager ERC-6909 claims. What Uniswap v4 itself cannot carry (a transfer fee,
///         a rebase of the PoolManager's balance) stays inside the token that causes it.
contract HookrLauncherOpenQuoteTokensTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant ANY_QUOTE = keccak256("ANY_QUOTE");
    address internal clean = address(0xC1EA);

    MockFeeOnTransferToken internal fot;
    RebaseToken internal reb;
    MockRestrictedToken internal pau;
    MockRestrictedToken internal blk;
    /// @dev One tokenA family: members 0 ETH, 1 tokenB (catalog), 2 rebasing, 3 pausable, 4 blocklisting.
    bytes32 internal family;
    Currency internal constant ETH = Currency.wrap(address(0));

    function setUp() public {
        _setUpPeriphery();
        registry.queue(ANY_QUOTE, "");
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.authorizeAnyQuote();
        // Takes 1% of every transfer for its issuer, this test contract.
        fot = new MockFeeOnTransferToken("Fee", "FEE", 1e30, 100, address(this));
        reb = new RebaseToken();
        // An issuer pause and an issuer block list ("blocked"), as a regulated dollar or stock token carries.
        pau = new MockRestrictedToken("PAUSE", "PAUSE", 1e30, "blocked");
        blk = new MockRestrictedToken("BLOCK", "BLOCK", 1e30, "blocked");
        address[4] memory odd = [address(fot), address(reb), address(pau), address(blk)];
        for (uint256 i; i < odd.length; ++i) {
            assertTrue(registry.isQuote(odd[i]));
            assertEq(uint8(registry.badgeForQuote(odd[i])), uint8(IHookrRegistry.QuoteBadge.UNREVIEWED));
            ERC20(odd[i]).approve(address(launcher), type(uint256).max);
            ERC20(odd[i]).transfer(trader, 1e27);
            vm.prank(trader);
            ERC20(odd[i]).approve(address(router), type(uint256).max);
        }
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](5);
        members[0] = _member(ETH);
        members[1] = _member(Currency.wrap(address(tokenB)));
        members[2] = _member(Currency.wrap(address(reb)));
        members[3] = _member(Currency.wrap(address(pau)));
        members[4] = _member(Currency.wrap(address(blk)));
        (family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        for (uint8 m; m < 5; ++m) {
            _buy(m, 1e21);
        }
        for (uint8 m; m < 5; ++m) {
            assertGt(rules.claimable(_quote(m), protocol), 0, "every quote accrued a protocol claim");
        }
    }

    function _key(uint8 member) internal view returns (PoolKey memory) {
        return launcher.position(family, member).key;
    }

    function _quote(uint8 member) internal view returns (Currency) {
        return root.poolConfig(_key(member).toId()).quote;
    }

    function _buy(uint8 member, uint128 amountIn) internal returns (uint256 amountOut) {
        PoolKey memory key = _key(member);
        IHookrRouter.Swap memory s = _swap(key, true, true, amountIn);
        uint256 value = Currency.unwrap(_quote(member)) == address(0) ? amountIn : 0;
        vm.prank(trader);
        (, amountOut) = router.swap{value: value}(s, address(0), new uint256[](0));
    }

    function buyExternal(uint8 member, uint128 amountIn) external returns (uint256) {
        return _buy(member, amountIn);
    }

    /// @dev Claims bits that deliver `member`'s quote side as ERC-6909 claims.
    function _quoteSide(uint8 member) internal view returns (uint8) {
        PoolKey memory key = _key(member);
        return Currency.unwrap(key.currency0) == Currency.unwrap(_quote(member)) ? 1 : 2;
    }

    /// @dev Every currency but the odd one keeps its whole Hookr state: the invariant holds, the protocol claim pays
    ///      exactly, and that member's LP exits in tokens.
    function _othersUnaffected(uint8 odd) internal {
        for (uint8 m; m < 5; ++m) {
            assertTrue(rules.accountingInvariant(_quote(m)), "every currency stays backed in claims");
        }
        for (uint8 m; m < 2; ++m) {
            if (m == odd) continue;
            Currency q = _quote(m);
            uint256 owed = rules.claimable(q, protocol);
            uint256 before = _balance(q, clean);
            vm.prank(protocol);
            assertEq(rules.claimTo(q, clean), owed);
            assertEq(_balance(q, clean) - before, owed, "exact payout in an unaffected currency");
            assertGt(_buy(m, 1e20), 0, "unaffected pools keep trading");
            uint128 liq = launcher.position(family, m).liquidity;
            launcher.withdraw(family, m, liq, 0, 0, clean, vm.getBlockTimestamp());
            assertEq(launcher.position(family, m).liquidity, 0);
        }
    }

    function _balance(Currency c, address a) internal view returns (uint256) {
        return Currency.unwrap(c) == address(0) ? a.balance : ERC20(Currency.unwrap(c)).balanceOf(a);
    }

    function test_feeOnTransferQuote_cannotFundOrTrade() public {
        // Funded with the transfer fee: the Launcher sees an inexact pull and refuses.
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(fot)));
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Fee Subject", "FSUB", 1e27, bytes32("fot"));
        vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
        launcher.launch(t, address(root), members, vm.getBlockTimestamp());
        // Single-sided, the pool opens (any-quote mode admits the token), but no exact route can pay into it.
        address subject = launcher.predictToken(address(this), t);
        bool subjectFirst = subject < address(fot);
        IHookrLauncher.Member memory m = members[0];
        m.sqrtPriceX96 = SQRT_ONE;
        // Subject-only band: above the opening tick when the subject is currency0, below it otherwise.
        if (subjectFirst) (m.tickLower, m.tickUpper, m.amount0Max, m.amount1Max) = (60, 60_000, 1e27, 0);
        else (m.tickLower, m.tickUpper, m.amount0Max, m.amount1Max) = (-60_000, -60, 0, 1e27);
        m.liquidity = 1e22;
        members[0] = m;
        (bytes32 fam,) = launcher.launch(t, address(root), members, vm.getBlockTimestamp());
        PoolKey memory key = launcher.position(fam, 0).key;
        assertTrue(root.knownPool(key.toId()));
        IHookrRouter.Swap memory s = _swap(key, true, true, 1e18);
        vm.prank(trader);
        vm.expectRevert(HookrSettlement.BalanceMismatch.selector);
        router.swap(s, address(0), new uint256[](0));
        assertEq(rules.totalLiability(Currency.wrap(address(fot))), 0, "nothing accrued in the fee token");
        _othersUnaffected(type(uint8).max);
    }

    function test_rebasingQuote_shortfallStaysInItsOwnCurrency() public {
        Currency r = Currency.wrap(address(reb));
        uint256 managerBefore = reb.balanceOf(address(manager));
        reb.rebase(0.5e18);
        assertEq(reb.balanceOf(address(manager)), managerBefore / 2, "the PoolManager lost half its balance");
        // Claims are ERC-6909 units: the rebase cannot make them unbacked in Hookr's books.
        assertTrue(rules.accountingInvariant(r));
        // The LP's token exit on the rebased member would need what the PoolManager no longer holds...
        uint128 liq = launcher.position(family, 2).liquidity;
        vm.expectRevert();
        launcher.withdraw(family, 2, liq, 0, 0, clean, vm.getBlockTimestamp());
        // ...so it takes the rebased side as claims and the subject side in tokens.
        uint256 subjectBefore = tokenA.balanceOf(clean);
        launcher.withdrawWithClaims(family, 2, liq, 0, 0, clean, _quoteSide(2), vm.getBlockTimestamp());
        assertGt(manager.balanceOf(clean, r.toId()), 0);
        assertGt(tokenA.balanceOf(clean), subjectBefore);
        _othersUnaffected(2);
    }

    function test_pausableQuote_pauseStopsOnlyItsCurrency() public {
        Currency p = Currency.wrap(address(pau));
        pau.setPaused(true);
        vm.expectRevert();
        this.buyExternal(3, 1e20);
        uint256 owed = rules.claimable(p, protocol);
        vm.prank(protocol);
        vm.expectRevert();
        rules.claim(p);
        // The paused claim leaves as ERC-6909, which moves no token.
        vm.prank(protocol);
        assertEq(rules.claimAsClaims(p, clean), owed);
        assertEq(manager.balanceOf(clean, p.toId()), owed);
        uint128 liq = launcher.position(family, 3).liquidity;
        launcher.withdrawWithClaims(family, 3, liq, 0, 0, clean, _quoteSide(3), vm.getBlockTimestamp());
        assertTrue(rules.accountingInvariant(p));
        _othersUnaffected(3);
    }

    function test_blocklistingQuote_blockBindsOnlyTheBlockedAccount() public {
        Currency b = Currency.wrap(address(blk));
        // A blocked beneficiary pays its claim to any clean recipient.
        blk.setBlocked(protocol, true);
        vm.prank(protocol);
        vm.expectRevert();
        rules.claim(b);
        uint256 owed = rules.claimable(b, protocol);
        vm.prank(protocol);
        assertEq(rules.claimTo(b, clean), owed);
        assertEq(blk.balanceOf(clean), owed);
        // A blocked trader cannot trade that pool; every other pool still serves it.
        blk.setBlocked(trader, true);
        vm.expectRevert();
        this.buyExternal(4, 1e20);
        // The issuer blocks the PoolManager itself: every pool in the token freezes, its LP leaves in claims.
        blk.setBlocked(address(manager), true);
        uint128 liq = launcher.position(family, 4).liquidity;
        vm.expectRevert();
        launcher.withdraw(family, 4, liq, 0, 0, clean, vm.getBlockTimestamp());
        launcher.withdrawWithClaims(family, 4, liq, 0, 0, clean, _quoteSide(4), vm.getBlockTimestamp());
        assertGt(manager.balanceOf(clean, b.toId()), 0);
        assertTrue(rules.accountingInvariant(b));
        _othersUnaffected(4);
    }

    /// @dev A quote whose transfers call back into Hookr: the family's royalty goes to the token itself in ETH and in
    ///      its own currency. While Rules pays its own claim it tries to take its ETH claim (paid and as ERC-6909) and
    ///      to swap on the ETH pool: every attempt fails and the ETH claim then pays exactly. While the router pulls it
    ///      into a swap, the paid claim and the swap fail on the PoolManager lock; the ERC-6909 exit of its own ETH
    ///      claim, which moves no token, is all it can do. Both currencies stay backed throughout.
    function test_reentrantQuote_cannotReachAnotherCurrency() public {
        ReentrantToken hst = new ReentrantToken(rules, router);
        hst.approve(address(launcher), type(uint256).max);
        hst.transfer(trader, 1e27);
        vm.prank(trader);
        hst.approve(address(router), type(uint256).max);
        vm.deal(address(hst), 1e18);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(ETH);
        members[1] = _member(Currency.wrap(address(hst)));
        members[0].rules.royaltyTo = address(hst);
        members[1].rules.royaltyTo = address(hst);
        (bytes32 fam,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(0), "Hostile Subject", "HSUB", 1e30, bytes32("hst")),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        PoolKey memory ethKey = launcher.position(fam, 0).key;
        PoolKey memory hstKey = launcher.position(fam, 1).key;
        Currency h = Currency.wrap(address(hst));
        IHookrRouter.Swap memory ethBuy = _swap(ethKey, true, true, 1e20);
        IHookrRouter.Swap memory hstBuy = _swap(hstKey, true, true, 1e20);
        vm.startPrank(trader);
        router.swap{value: 1e20}(ethBuy, address(0), new uint256[](0));
        router.swap(hstBuy, address(0), new uint256[](0));
        vm.stopPrank();
        uint256 ethOwed = rules.claimable(ETH, address(hst));
        uint256 ownOwed = rules.claimable(h, address(hst));
        assertGt(ethOwed, 0);
        assertGt(ownOwed, 0);
        // Rules pays the token its own claim: the PoolManager's transfer runs the hostile hook mid-claim.
        IHookrRouter.Swap memory nested = _swap(ethKey, true, true, 1e15);
        nested.recipient = address(hst);
        hst.arm(nested);
        assertEq(hst.claimOwn(), ownOwed);
        assertFalse(hst.claimEntered() || hst.claimAsClaimsEntered() || hst.swapEntered());
        assertEq(bytes4(hst.claimError()), IHookrRulesState.ReentrantClaim.selector);
        assertEq(bytes4(hst.claimAsClaimsError()), IHookrRulesState.ReentrantClaim.selector);
        assertEq(rules.claimable(ETH, address(hst)), ethOwed, "the ETH claim is untouched");
        uint256 before = address(hst).balance;
        assertEq(hst.claimEth(), ethOwed);
        assertEq(address(hst).balance - before, ethOwed, "then it pays exactly");
        // The router pulls the token into a swap: the same attempts, from inside the router's unlock.
        vm.prank(trader);
        router.swap{value: 1e20}(ethBuy, address(0), new uint256[](0));
        ethOwed = rules.claimable(ETH, address(hst));
        assertGt(ethOwed, 0);
        hst.arm(nested);
        vm.prank(trader);
        router.swap(hstBuy, address(0), new uint256[](0));
        assertFalse(hst.claimEntered() || hst.swapEntered(), "the PoolManager lock refuses both");
        assertTrue(hst.claimAsClaimsEntered());
        assertEq(manager.balanceOf(address(hst), ETH.toId()), ethOwed, "only its own claim, as ERC-6909");
        assertEq(rules.claimable(ETH, address(hst)), 0);
        assertTrue(rules.accountingInvariant(ETH) && rules.accountingInvariant(h));
        _othersUnaffected(type(uint8).max);
    }

    /// @dev The four tokens together: all misbehave at once and the ETH and catalog currencies are still whole.
    function test_allFourAtOnce_ethAndCatalogUntouched() public {
        reb.rebase(0.25e18);
        pau.setPaused(true);
        blk.setBlocked(address(manager), true);
        _othersUnaffected(type(uint8).max);
    }
}
