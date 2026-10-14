// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";

/// @notice L-12 regression. Original PoC (B12Verify test_c3, unfixed source): a dust squat on the existing-token
/// key (tokenA / native / spacing 60) cost 3 wei and 853,568 gas; the squatter withdrew everything, recovering
/// 2 wei (net cost 1 wei); the victim's two-member family then reverted with a bare PoolExists() that named neither
/// the member nor the key. A PoolKey cannot be un-initialized and keys carry no creator or role, so the squat still
/// occupies that exact key. Mitigated: memberKey() lets the SDK/app detect a taken key and pick a free spacing
/// before signing, and PoolExists(member, id) names the member that collided.
contract HookrLauncherPoolKeySquatTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    address internal squatter = address(0x5A5A);

    function setUp() public {
        _setUpPeriphery();
        vm.deal(squatter, 1 ether);
    }

    function _squat(address subject, Currency quote, int24 spacing, uint256 value) internal returns (bytes32 family) {
        IHookrLauncher.Member[] memory squat = new IHookrLauncher.Member[](1);
        squat[0] = _member(quote);
        squat[0].tickSpacing = spacing;
        squat[0].tickLower = spacing;
        squat[0].tickUpper = spacing * 2;
        squat[0].liquidity = 1000;
        squat[0].amount0Max = 100;
        squat[0].amount1Max = Currency.unwrap(quote) == address(0) ? 0 : 100;
        squat[0].rules.royaltyTo = squatter;
        squat[0].rules.royaltyBps = 1000;
        vm.prank(squatter);
        (family,) = launcher.launch{value: value}(
            IHookrLauncher.Token(subject, "", "", 0, bytes32(0)), address(root), squat, block.timestamp
        );
    }

    function testSquattedKeyIsDetectableAndNamedAndAFreeSpacingLaunches() public {
        Currency native = Currency.wrap(address(0));
        (PoolKey memory expected, bool freeBefore) = launcher.memberKey(address(tokenA), native, 60, address(root));
        assertTrue(freeBefore);

        bytes32 family = _squat(address(tokenA), native, 60, 100);
        uint128 liq = launcher.position(family, 0).liquidity;
        vm.prank(squatter);
        launcher.withdraw(family, 0, liq, 0, 0, squatter, block.timestamp);
        assertEq(1 ether - squatter.balance, 1, "squat still costs about 1 wei net");

        // The SDK/app can see the key is taken before asking anyone to sign.
        (PoolKey memory key, bool free) = launcher.memberKey(address(tokenA), native, 60, address(root));
        assertFalse(free);
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(expected.toId()));
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(launcher.position(family, 0).key.toId()));

        // A family that still names the taken key reverts with the member index and PoolId.
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[1] = _member(native);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.PoolExists.selector, uint8(1), key.toId()));
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, block.timestamp
        );

        // memberKey finds the next free spacing, and the same family launches there.
        (, bool free64) = launcher.memberKey(address(tokenA), native, 64, address(root));
        assertTrue(free64);
        members[1].tickSpacing = 64;
        members[1].tickLower = -59_968;
        members[1].tickUpper = 59_968;
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, block.timestamp
        );
        (, free64) = launcher.memberKey(address(tokenA), native, 64, address(root));
        assertFalse(free64);
    }

    function testRoleInvertedSquatIsReportedForBothRoleOrders() public {
        tokenA.transfer(squatter, 1e20);
        tokenB.transfer(squatter, 1e20);
        vm.startPrank(squatter);
        tokenA.approve(address(launcher), type(uint256).max);
        tokenB.approve(address(launcher), type(uint256).max);
        vm.stopPrank();
        // subject tokenB / quote tokenA occupies the subject tokenA / quote tokenB key: keys ignore roles.
        _squat(address(tokenB), Currency.wrap(address(tokenA)), 60, 0);
        (PoolKey memory a, bool freeA) =
            launcher.memberKey(address(tokenA), Currency.wrap(address(tokenB)), 60, address(root));
        (PoolKey memory b, bool freeB) =
            launcher.memberKey(address(tokenB), Currency.wrap(address(tokenA)), 60, address(root));
        assertEq(PoolId.unwrap(a.toId()), PoolId.unwrap(b.toId()));
        assertFalse(freeA);
        assertFalse(freeB);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.PoolExists.selector, uint8(0), a.toId()));
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, block.timestamp
        );
    }
}
