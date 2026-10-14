// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";
import {MockRestrictedToken} from "../mocks/MockRestrictedToken.sol";

/// @notice I-03, Launcher side. Original PoC (B1Batch testC3, unfixed source): with an existing issuer subject and
/// burnBps 100, the issuer blacklisting 0xdead made every exact-input buy revert (Auto Burn moves subject to DEAD
/// inside the root) while exact-output buys and both sells kept working; unblocking restored buys. Since the
/// economics fix (OD-5, M-04) exact-output buys burn too, so the block halts every buy; sells keep working. That halt lives
/// in the root's Auto Burn and is qualification scope; the Launcher keeps the existing lane permissionless and
/// documents the dependency. What the Launcher does guarantee, pinned here: the halt never reaches LP exits. Fees
/// and principal still leave to a clean recipient straight from the PoolManager, even if the same issuer also
/// freezes the shared Launcher.
contract HookrLauncherDeadBlacklistTest is PeripheryFixture {
    function setUp() public {
        _setUpPeriphery();
    }

    function testDeadBlacklistHaltsAllBuysButNeverLPExits() public {
        // An issuer token whose blacklist reverts "blacklisted".
        MockRestrictedToken iss = new MockRestrictedToken("Issuer Token", "ISS", 1e30, "blacklisted");
        iss.approve(address(launcher), type(uint256).max);
        iss.transfer(trader, 1e27);
        vm.prank(trader);
        iss.approve(address(router), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        assertGt(members[0].rules.burnBps, 0);
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(address(iss), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        PoolKey memory key = launcher.position(family, 0).key;
        IHookrRouter.Swap memory buyIn = _swap(key, true, true, 1e18);
        IHookrRouter.Swap memory buyOut = _swap(key, true, false, 1e18);
        IHookrRouter.Swap memory sellIn = _swap(key, false, true, 1e18);
        vm.prank(trader);
        router.swap(buyIn, address(0), new uint256[](0));

        iss.setBlocked(address(0xdead), true);
        vm.prank(trader);
        vm.expectRevert();
        router.swap(buyIn, address(0), new uint256[](0));
        // OD-5: exact-output buys now burn too (gross-up), so the same issuer block halts them as well.
        vm.prank(trader);
        vm.expectRevert();
        router.swap(buyOut, address(0), new uint256[](0));
        vm.prank(trader);
        router.swap(sellIn, address(0), new uint256[](0));

        // The same issuer also freezes the shared Launcher: exits still work.
        iss.setBlocked(address(launcher), true);
        address clean = address(0xC1EA);
        (uint256 f0, uint256 f1) = launcher.withdraw(family, 0, 0, 0, 0, clean, vm.getBlockTimestamp());
        assertGt(f0 + f1, 0);
        uint128 liq = launcher.position(family, 0).liquidity;
        (uint256 a0, uint256 a1) = launcher.withdraw(family, 0, liq, 0, 0, clean, vm.getBlockTimestamp());
        bool issIs0 = Currency.unwrap(key.currency0) == address(iss);
        assertEq(iss.balanceOf(clean), issIs0 ? f0 + a0 : f1 + a1);
        assertEq(tokenB.balanceOf(clean), issIs0 ? f1 + a1 : f0 + a0);
        assertEq(iss.balanceOf(address(launcher)), 0);
    }
}
