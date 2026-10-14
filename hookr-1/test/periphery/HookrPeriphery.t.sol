// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";

contract FailingSink {
    error ReceiptRejected();

    fallback() external {
        revert ReceiptRejected();
    }
}

contract SenderTaxToken is ERC20 {
    constructor() ERC20("Taxed", "TAX") {
        _mint(msg.sender, 1e30);
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from != address(0) && to != address(0) && amount != 0) super._update(from, address(0), 1);
    }
}

contract HookrPeripheryTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public virtual {
        _setUpPeriphery();
    }

    function testLaunchFundsThreeMemberFamilyAndOwnerCanExit() public {
        HookrToken third = new HookrToken("Third", "TH", 1e30, address(this));
        third.approve(address(launcher), type(uint256).max);
        _catalogQuote(address(third));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](3);
        members[0] = _member(Currency.wrap(address(0)));
        members[1] = _member(Currency.wrap(address(tokenB)));
        members[2] = _member(Currency.wrap(address(third)));
        (bytes32 family, address subject) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        assertEq(subject, address(tokenA));
        assertEq(launcher.familyOwner(family), address(this));
        assertEq(launcher.memberCount(family), 3);
        for (uint8 i; i < 3; ++i) {
            IHookrLauncher.Position memory p = launcher.position(family, i);
            assertTrue(root.knownPool(p.key.toId()));
            assertEq(launcher.poolFamily(p.key.toId()), family);
            assertEq(p.liquidity, 1e24);
            (uint256 amount0, uint256 amount1) =
                launcher.withdraw(family, i, 1e24, 1, 1, address(this), vm.getBlockTimestamp());
            assertGt(amount0, 0);
            assertGt(amount1, 0);
            assertEq(launcher.position(family, i).liquidity, 0);
        }
        assertEq(address(launcher).balance, 0);
        assertEq(tokenA.balanceOf(address(launcher)), 0);
        assertEq(tokenB.balanceOf(address(launcher)), 0);
        assertEq(third.balanceOf(address(launcher)), 0);
    }

    function testLaunchNewTokenAllocatesSupplyOnceAndReturnsRemainder() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(Currency.wrap(address(0)));
        members[1] = _member(Currency.wrap(address(tokenB)));
        (bytes32 family, address subject) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(0), "Family", "FAM", 1e25, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        HookrToken created = HookrToken(subject);
        assertEq(created.totalSupply(), 1e25);
        assertEq(created.balanceOf(address(launcher)), 0);
        assertGt(created.balanceOf(address(this)), 8e24);
        assertEq(Currency.unwrap(root.poolConfig(launcher.position(family, 0).key.toId()).subject), subject);
    }

    function testLaunchPreservesStrayBalances() public {
        tokenA.transfer(address(launcher), 13);
        tokenB.transfer(address(launcher), 17);
        vm.deal(address(launcher), 19);
        _launch(true, false);
        assertEq(tokenA.balanceOf(address(launcher)), 13);
        assertEq(tokenB.balanceOf(address(launcher)), 17);
        assertEq(address(launcher).balance, 19);
    }

    function testDuplicateQuotesRevertWholeFamily() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[1] = members[0];
        uint256 beforeBalance = tokenA.balanceOf(address(this));
        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        assertEq(tokenA.balanceOf(address(this)), beforeBalance);
    }

    function testBadFinalMemberRollsBackAllPoolsAndFunding() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[1] = _member(Currency.wrap(address(0)));
        members[1].tickLower = -59999;
        uint256 beforeBalance = tokenA.balanceOf(address(this));
        vm.expectRevert();
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        assertEq(tokenA.balanceOf(address(this)), beforeBalance);
        // A subsequent valid launch of the same first key succeeds only if initialization rolled back.
        _launch(address(tokenA) < address(tokenB), false);
    }

    function testExistingKeyRejectsDifferentProfile() public {
        (, PoolKey memory key, HookrToken subject, Currency quote) = _launch(true, false);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(quote);
        members[0].config.policyId = keccak256("different-profile");
        // L-12: the error names the taken member and its pool id.
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.PoolExists.selector, uint8(0), key.toId()));
        launcher.launch(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        assertTrue(root.knownPool(key.toId()));
    }

    function testOnlyFamilyOwnerCanWithdrawOrTransfer() public {
        (bytes32 family,,,) = _launch(true, false);
        vm.startPrank(trader);
        vm.expectRevert(IHookrLauncher.NotOwner.selector);
        launcher.withdraw(family, 0, 1e24, 0, 0, trader, vm.getBlockTimestamp());
        vm.expectRevert(IHookrLauncher.NotOwner.selector);
        launcher.transferFamily(family, trader, 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.NotPendingOwner.selector, family, trader));
        launcher.acceptFamily(family);
        vm.stopPrank();
        // Two-step transfer (L-13): control moves only when the named owner accepts.
        launcher.transferFamily(family, trader, 0);
        vm.prank(trader);
        launcher.acceptFamily(family);
        vm.expectRevert(IHookrLauncher.NotOwner.selector);
        launcher.withdraw(family, 0, 1e24, 0, 0, address(this), vm.getBlockTimestamp());
        vm.prank(trader);
        launcher.withdraw(family, 0, 1e24, 1, 1, trader, vm.getBlockTimestamp());
    }

    function testSenderTaxFundingRejectedBeforePoolCreation() public {
        SenderTaxToken taxed = new SenderTaxToken();
        taxed.approve(address(launcher), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
        launcher.launch(
            IHookrLauncher.Token(address(taxed), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    function testFuzzQuoteMatchesSwapBothDirectionsAndModes(bool first, bool buy, bool exactInput, uint128 raw) public {
        (, PoolKey memory key,,) = _launch(first, false);
        uint128 amount = uint128(bound(raw, 1e9, 1e21));
        IHookrRouter.Swap memory p = _swap(key, buy, exactInput, amount);
        HookrTypes.ExecutionReceipt memory quoted = quoter.quote(p, trader);
        assertEq(rules.claimable(root.poolConfig(key.toId()).quote, trader), 0);
        vm.prank(trader);
        (uint256 input, uint256 output) = router.swap(p, address(0), new uint256[](0));
        assertEq(input, quoted.inputAmount);
        assertEq(output, quoted.outputAmount);
        assertTrue(rules.accountingInvariant(root.poolConfig(key.toId()).quote));
        assertEq(tokenA.balanceOf(address(router)), 0);
        assertEq(tokenB.balanceOf(address(router)), 0);
    }

    function testPartialFillRefundIsBackedAndClaimable() public {
        (, PoolKey memory key,, Currency quote) = _launch(false, false);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e23);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(p.zeroForOne ? int24(-1) : int24(1));
        HookrTypes.ExecutionReceipt memory quoted = quoter.quote(p, trader);
        assertGt(quoted.quoteRefund, 0);
        assertLt(quoted.inputAmount, 1e23);
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
        assertEq(rules.claimable(quote, trader), quoted.quoteRefund);
        uint256 beforeBalance = HookrToken(Currency.unwrap(quote)).balanceOf(trader);
        vm.prank(trader);
        uint256 refund = rules.claim(quote);
        assertEq(refund, quoted.quoteRefund);
        assertEq(HookrToken(Currency.unwrap(quote)).balanceOf(trader), beforeBalance + refund);
        assertTrue(rules.accountingInvariant(quote));
    }

    function testNativeInputRefundAndNativeOutputLeaveNoRouterDust() public {
        (, PoolKey memory key,,) = _launch(false, true);
        IHookrRouter.Swap memory buy = _swap(key, true, false, 10 ether);
        buy.amountBound = 12 ether;
        uint256 beforeBalance = trader.balance;
        vm.prank(trader);
        (uint256 input, uint256 output) = router.swap{value: 12 ether}(buy, address(0), new uint256[](0));
        assertEq(output, 10 ether);
        assertEq(trader.balance, beforeBalance - input);
        IHookrRouter.Swap memory sell = _swap(key, false, true, 2 ether);
        vm.prank(trader);
        router.swap(sell, address(0), new uint256[](0));
        assertEq(address(router).balance, 0);
    }

    function testExactOutputPartialFillReverts() public {
        (, PoolKey memory key,,) = _launch(true, false);
        IHookrRouter.Swap memory p = _swap(key, true, false, 1e23);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(p.zeroForOne ? int24(-1) : int24(1));
        // Economics fix (OD-6, §7.3): with Auto Burn on, an exact-output partial fill now reverts in Root's afterSwap with
        // ExactOutputShortfall (wrapped by the PoolManager) before the Router's Slippage check can run.
        vm.prank(trader);
        try router.swap(p, address(0), new uint256[](0)) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), CustomRevert.WrappedError.selector);
            assertEq(_wrappedReasonSelector(err), IHookrRootState.ExactOutputShortfall.selector);
        }
    }

    /// @dev WrappedError(address target, bytes4 selector, bytes reason, bytes details): returns reason's selector.
    function _wrappedReasonSelector(bytes memory err) internal pure returns (bytes4) {
        bytes32 w;
        assembly {
            let args := add(err, 36)
            let reasonOffset := mload(add(args, 64))
            w := mload(add(add(args, reasonOffset), 32))
        }
        return bytes4(w);
    }

    function testCallbackCannotBeInvokedOutsideUnlock() public {
        vm.expectRevert(IHookrRouter.InvalidCallback.selector);
        router.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(IHookrRouter.InvalidCallback.selector);
        router.unlockCallback("");
        vm.expectRevert(IHookrLauncher.InvalidCallback.selector);
        launcher.unlockCallback("");
    }

    function testRewardUsesExecutedQuoteAndCreditsPayer() public {
        (, PoolKey memory key,, Currency quote) = _launch(true, false);
        (HookrPrograms programs, uint256 campaign) = _campaign(key, quote);
        IHookrRouter.Swap memory p = _swap(key, true, true, 10 ether);
        p.recipient = address(0xCAFE);
        HookrTypes.ExecutionReceipt memory quoted = quoter.quote(p, trader);
        uint256[] memory ids = new uint256[](1);
        ids[0] = campaign;
        vm.prank(trader);
        router.swap(p, address(programs), ids);
        assertEq(programs.points(campaign, trader), quoted.actualQuote);
        assertEq(programs.points(campaign, p.recipient), 0);
        // Immediate programs are points-only (L-04): the receipt credits the payer and nothing else.
        assertEq(programs.claimableCash(campaign, trader), 0);
    }

    function testPlainSwapNeverTouchesCampaign() public {
        (, PoolKey memory key,, Currency quote) = _launch(true, false);
        (HookrPrograms programs, uint256 campaign) = _campaign(key, quote);
        IHookrRouter.Swap memory params = _swap(key, true, true, 10 ether);
        vm.prank(trader);
        router.swap(params, address(0), new uint256[](0));
        assertEq(programs.points(campaign, trader), 0);
        assertEq(programs.claimableCash(campaign, trader), 0);
    }

    function testOptInRewardFailureRevertsSwapAndCanBeOmitted() public {
        (, PoolKey memory key,,) = _launch(true, false);
        IHookrRouter.Swap memory p = _swap(key, true, true, 10 ether);
        FailingSink sink = new FailingSink();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256 beforeA = tokenA.balanceOf(trader);
        uint256 beforeB = tokenB.balanceOf(trader);
        vm.prank(trader);
        vm.expectRevert(FailingSink.ReceiptRejected.selector);
        router.swap(p, address(sink), ids);
        assertEq(tokenA.balanceOf(trader), beforeA);
        assertEq(tokenB.balanceOf(trader), beforeB);
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
    }

    /// @dev An Immediate points program on `key`'s pool, one point per unit of quote volume, in a fresh HookrPrograms
    ///      that trusts the router.
    function _campaign(PoolKey memory key, Currency quote) private returns (HookrPrograms programs, uint256 id) {
        programs =
            new HookrPrograms(manager, address(router), address(this), 1e30, address(new HookrReferralRegistry()));
        P.Terms memory t;
        t.mode = P.Mode.Immediate;
        t.start = uint64(vm.getBlockTimestamp());
        t.end = uint64(vm.getBlockTimestamp() + 1 days);
        t.pointBudget = 1e30;
        t.walletPointCap = 1e30;
        t.pointNumerator = 1;
        t.pointDenominator = 1;
        t.sourcePolicyHash = keccak256("authenticated-router-user-swap");
        t.name = "Receipts";
        t.pointDecimals = 18;
        P.Scope[] memory s = new P.Scope[](1);
        s[0] = P.Scope(
            address(root), PoolId.unwrap(key.toId()), root.policyHash(key.toId()), Currency.unwrap(quote), 1, 1, 0, 0
        );
        id = programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
    }
}
