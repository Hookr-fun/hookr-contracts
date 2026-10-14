// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrSettlement} from "../../src/libraries/HookrSettlement.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";
import {MockRestrictedToken} from "../mocks/MockRestrictedToken.sol";

/// @notice L-02 regression. Original PoC (v1_issuer_freeze_pause_or_later_transfer_fe_7, unfixed source):
///  - Launcher frozen by the IUSD issuer: family A member 0 locked 949,251.75e18 tokenA + 951,177.21e18 IUSD,
///    unrelated family B locked 951,177.21e18 IUSD + 949,251.75e18 tokenB; fee collect, transferFamily and
///    addLiquidity all reverted; transferFamily stayed blocked after the healthy ETH member was emptied.
///  - Subject issuer freezing the Launcher locked every member (ETH member 951,177.21e18 wei + 949,251.75e18).
///  - A 1 bps fee or a pause on IUSD locked both currencies of the member (949,251.75e18 / 951,177.21e18).
///  - An owner-only freeze blocked transferFamily again after any buy that followed a sweep.
/// Fixed: the PoolManager pays the recipient directly, either side can leave as ERC-6909 claims, and the old owner
/// can choose in transferFamily to take its accrued fees as claims on acceptance.
contract HookrLauncherIssuerRestrictedExitTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    MockRestrictedToken internal usd;
    address internal creatorB = address(0xB0B);
    address internal cleanRecipient = address(0xC1EA);

    function setUp() public {
        _setUpPeriphery();
        // USDG/USDC-style issuer asset: freeze list ("frozen"), global pause and a switchable transfer fee.
        usd = new MockRestrictedToken("Issuer Dollar", "IUSD", 1e30, "frozen");
        _catalogQuote(address(usd));
        usd.approve(address(launcher), type(uint256).max);
        usd.transfer(trader, 1e27);
        usd.transfer(creatorB, 1e25);
        tokenB.transfer(creatorB, 1e25);
        vm.prank(trader);
        usd.approve(address(router), type(uint256).max);
        vm.startPrank(creatorB);
        usd.approve(address(launcher), type(uint256).max);
        tokenB.approve(address(launcher), type(uint256).max);
        vm.stopPrank();
    }

    function _familyA() internal returns (bytes32 family) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(Currency.wrap(address(usd)));
        members[1] = _member(Currency.wrap(address(0)));
        (family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, block.timestamp
        );
    }

    function _familyB() internal returns (bytes32 family) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(usd)));
        vm.prank(creatorB);
        (family,) = launcher.launch(
            IHookrLauncher.Token(address(tokenB), "", "", 0, bytes32(0)), address(root), members, block.timestamp
        );
    }

    function _buy(bytes32 family, uint8 member, uint128 amountIn) internal {
        PoolKey memory key = launcher.position(family, member).key;
        IHookrRouter.Swap memory s = _swap(key, true, true, amountIn);
        uint256 value = Currency.unwrap(root.poolConfig(key.toId()).quote) == address(0) ? amountIn : 0;
        vm.prank(trader);
        router.swap{value: value}(s, address(0), new uint256[](0));
    }

    function _quoteExit(address owner, bytes32 family, uint8 member)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        uint128 liq = launcher.position(family, member).liquidity;
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        (amount0, amount1) = launcher.withdraw(family, member, liq, 0, 0, cleanRecipient, block.timestamp);
        vm.revertToState(snap);
    }

    function _bal(Currency c, address a) internal view returns (uint256) {
        return Currency.unwrap(c) == address(0) ? a.balance : ERC20(Currency.unwrap(c)).balanceOf(a);
    }

    function testLauncherFreezeNoLongerLocksAnyExit() public {
        bytes32 famA = _familyA();
        bytes32 famB = _familyB();
        _buy(famA, 0, 1e21);
        _buy(famA, 1, 1e21);
        _buy(famB, 0, 1e21);
        (uint256 a0, uint256 a1) = _quoteExit(address(this), famA, 0);
        (uint256 b0, uint256 b1) = _quoteExit(creatorB, famB, 0);
        // Original PoC position: 949251746454184748733730 / 951177213509656376492401. The economics fix charges LP
        // Rewards in the LP fee instead of donating them (OD-2), so this position now also carries the 2% LP Reward of
        // the 1e21 buy as fees: a1 is exactly +20e18 and the fill moves a0 by -1.998e19 (21 ppm). Same scenario.
        assertEq(a0, 949231770199855506591157, "same position as the original PoC, LP Rewards in the LP fee");
        assertEq(a1, 951177213509656376492401 + 20e18, "same position as the original PoC, LP Rewards in the LP fee");

        usd.freeze(address(launcher), true);

        // Ownership handover works while the Launcher is frozen.
        uint256 snap = vm.snapshotState();
        launcher.transferFamily(famA, cleanRecipient, 0);
        vm.prank(cleanRecipient);
        launcher.acceptFamily(famA);
        assertEq(launcher.familyOwner(famA), cleanRecipient);
        vm.revertToState(snap);

        // Fee-only collect and the full exit both reach a clean recipient with exact amounts.
        launcher.withdraw(famA, 0, 0, 0, 0, cleanRecipient, block.timestamp);
        (a0, a1) = _quoteExit(address(this), famA, 0);
        PoolKey memory kA = launcher.position(famA, 0).key;
        uint256 r0 = _bal(kA.currency0, cleanRecipient);
        uint256 r1 = _bal(kA.currency1, cleanRecipient);
        uint128 liqA = launcher.position(famA, 0).liquidity;
        (uint256 o0, uint256 o1) = launcher.withdraw(famA, 0, liqA, 0, 0, cleanRecipient, block.timestamp);
        assertEq(o0, a0);
        assertEq(o1, a1);
        assertEq(_bal(kA.currency0, cleanRecipient) - r0, a0);
        assertEq(_bal(kA.currency1, cleanRecipient) - r1, a1);

        // The unrelated family on the same asset exits too.
        uint128 liqB = launcher.position(famB, 0).liquidity;
        vm.prank(creatorB);
        (o0, o1) = launcher.withdraw(famB, 0, liqB, 0, 0, creatorB, block.timestamp);
        assertEq(o0, b0);
        assertEq(o1, b1);

        // The Launcher never held any of it.
        assertEq(usd.balanceOf(address(launcher)), 0);
        assertEq(tokenA.balanceOf(address(launcher)), 0);
        assertEq(tokenB.balanceOf(address(launcher)), 0);

        // New funding in a frozen asset is still refused: the freeze can stop new activity, not exits.
        vm.expectRevert();
        launcher.addLiquidity(famA, 0, 1e18, 1e20, 1e20, block.timestamp);
    }

    function testSubjectIssuerFreezeNoLongerLocksMembers() public {
        MockRestrictedToken sub = new MockRestrictedToken("Issuer Stock", "ISTK", 1e30, "frozen");
        sub.approve(address(launcher), type(uint256).max);
        sub.transfer(trader, 1e27);
        vm.prank(trader);
        sub.approve(address(router), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(Currency.wrap(address(0)));
        members[1] = _member(Currency.wrap(address(tokenB)));
        (bytes32 fam,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(sub), "", "", 0, bytes32(0)), address(root), members, block.timestamp
        );
        _buy(fam, 0, 1e21);
        _buy(fam, 1, 1e21);
        // One sell accrues subject-side fees (this used to make the whole family non-transferable).
        PoolKey memory k0 = launcher.position(fam, 0).key;
        IHookrRouter.Swap memory s = _swap(k0, false, true, 1e21);
        vm.prank(trader);
        router.swap(s, address(0), new uint256[](0));
        (uint256 e0, uint256 e1) = _quoteExit(address(this), fam, 0);
        (uint256 t0, uint256 t1) = _quoteExit(address(this), fam, 1);

        sub.freeze(address(launcher), true);
        uint256 snap = vm.snapshotState();
        launcher.transferFamily(fam, cleanRecipient, 0);
        vm.prank(cleanRecipient);
        launcher.acceptFamily(fam);
        assertEq(launcher.familyOwner(fam), cleanRecipient);
        vm.revertToState(snap);

        (uint256 o0, uint256 o1) =
            launcher.withdraw(fam, 0, launcher.position(fam, 0).liquidity, 0, 0, cleanRecipient, block.timestamp);
        assertEq(o0, e0);
        assertEq(o1, e1);
        (o0, o1) = launcher.withdraw(fam, 1, launcher.position(fam, 1).liquidity, 0, 0, cleanRecipient, block.timestamp);
        assertEq(o0, t0);
        assertEq(o1, t1);
    }

    function testFeeOrPauseReleasesUnaffectedSideAsTokensAndRestrictedSideAsClaims() public {
        bytes32 famA = _familyA();
        _buy(famA, 0, 1e21);
        (uint256 a0, uint256 a1) = _quoteExit(address(this), famA, 0);
        PoolKey memory kA = launcher.position(famA, 0).key;
        bool usdIs0 = Currency.unwrap(kA.currency0) == address(usd);
        uint8 usdBit = usdIs0 ? 1 : 2;
        uint128 liqA = launcher.position(famA, 0).liquidity;
        uint256 usdId = uint256(uint160(address(usd)));

        // A later 1 bps fee: token delivery of IUSD still fails the exact-balance check (kept on purpose)...
        usd.setFee(1);
        vm.expectRevert();
        launcher.withdraw(famA, 0, liqA, 0, 0, cleanRecipient, block.timestamp);
        // ...but the subject leaves as tokens and IUSD as an exact ERC-6909 claim.
        uint256 snap = vm.snapshotState();
        (uint256 o0, uint256 o1) =
            launcher.withdrawWithClaims(famA, 0, liqA, 0, 0, cleanRecipient, usdBit, block.timestamp);
        assertEq(o0, a0);
        assertEq(o1, a1);
        assertEq(tokenA.balanceOf(cleanRecipient), usdIs0 ? o1 : o0);
        assertEq(manager.balanceOf(cleanRecipient, usdId), usdIs0 ? o0 : o1);
        // Documented limit: redeem is exact too, so while the fee lasts the claim cannot become tokens through the
        // Launcher; it needs a non-exact PoolManager unlock helper (the holder's own contract or an EIP-7702
        // delegation calling unlock, burn and take), or the fee to be lifted.
        uint256 feeClaim = usdIs0 ? o0 : o1;
        vm.prank(cleanRecipient);
        manager.approve(address(launcher), usdId, feeClaim);
        vm.prank(cleanRecipient);
        vm.expectRevert(HookrSettlement.BalanceMismatch.selector);
        launcher.redeem(Currency.wrap(address(usd)), feeClaim, cleanRecipient);
        assertEq(manager.balanceOf(cleanRecipient, usdId), feeClaim, "claim intact");
        vm.revertToState(snap);
        usd.setFee(0);

        // A pause behaves the same way.
        usd.setPaused(true);
        vm.expectRevert();
        launcher.withdraw(famA, 0, liqA, 0, 0, cleanRecipient, block.timestamp);
        (o0, o1) = launcher.withdrawWithClaims(famA, 0, liqA, 0, 0, cleanRecipient, usdBit, block.timestamp);
        uint256 claim = usdIs0 ? o0 : o1;
        assertEq(tokenA.balanceOf(cleanRecipient), usdIs0 ? o1 : o0);
        assertEq(manager.balanceOf(cleanRecipient, usdId), claim);
        assertEq(launcher.position(famA, 0).liquidity, 0);

        // The claim is redeemed through the Launcher once the issuer lifts the pause; no third party needed.
        vm.prank(cleanRecipient);
        manager.approve(address(launcher), usdId, claim);
        vm.prank(cleanRecipient);
        vm.expectRevert();
        launcher.redeem(Currency.wrap(address(usd)), claim, cleanRecipient);
        usd.setPaused(false);
        vm.prank(cleanRecipient);
        launcher.redeem(Currency.wrap(address(usd)), claim, cleanRecipient);
        assertEq(usd.balanceOf(cleanRecipient), claim);
        assertEq(manager.balanceOf(cleanRecipient, usdId), 0);
    }

    function testOwnerFreezeCannotBlockAcceptance() public {
        bytes32 famA = _familyA();
        _buy(famA, 0, 1e21);
        usd.freeze(address(this), true);
        // Starting the transfer moves no tokens, so a frozen owner can always start it.
        launcher.transferFamily(famA, cleanRecipient, 0);
        _buy(famA, 0, 1e18); // a buy after the transfer started accrues more IUSD fees for the old owner
        PoolKey memory kA = launcher.position(famA, 0).key;
        uint16 mask = Currency.unwrap(kA.currency0) == address(usd) ? 1 : 2;
        // Token delivery to the frozen old owner fails; the old owner (not the new one) re-targets with claims.
        vm.prank(cleanRecipient);
        vm.expectRevert();
        launcher.acceptFamily(famA);
        launcher.transferFamily(famA, cleanRecipient, mask);
        vm.prank(cleanRecipient);
        launcher.acceptFamily(famA);
        assertEq(launcher.familyOwner(famA), cleanRecipient);
        assertGt(manager.balanceOf(address(this), uint256(uint160(address(usd)))), 0, "old owner keeps its fees");
    }
}
