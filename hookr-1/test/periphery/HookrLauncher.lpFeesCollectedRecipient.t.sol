// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";

/// @notice I-09 regression. Original PoC (B13Verify testC3, unfixed source): one zero-amount LPFeesCollected per
/// launched member (and per add); withdraw(..., recipient = 0xBEEF) emitted owner = family owner with fees
/// 14.999999999999999999 token0 / 171.224999999999999999 token1 while 0xBEEF received them, and nothing in the
/// event named 0xBEEF. Fixed: the event carries the actual recipient and fires only for non-zero fees.
contract HookrLauncherLpFeesCollectedRecipientTest is PeripheryFixture {
    bytes32 internal constant OLD_TOPIC = keccak256("LPFeesCollected(bytes32,uint8,bytes32,address,uint256,uint256)");
    bytes32 internal constant TOPIC =
        keccak256("LPFeesCollected(bytes32,uint8,bytes32,address,address,uint256,uint256)");

    function setUp() public {
        _setUpPeriphery();
    }

    function _count(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(launcher)) continue;
            assertTrue(logs[i].topics[0] != OLD_TOPIC);
            if (logs[i].topics[0] == TOPIC) ++n;
        }
    }

    function testEventNamesRecipientAndSkipsZeroFees() public {
        assertEq(IHookrLauncher.LPFeesCollected.selector, TOPIC);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        vm.recordLogs();
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, block.timestamp
        );
        assertEq(_count(vm.getRecordedLogs()), 0, "was 1 zero-amount event per member");

        vm.recordLogs();
        launcher.addLiquidity(family, 0, 1e20, 1e22, 1e22, block.timestamp);
        assertEq(_count(vm.getRecordedLogs()), 0, "no fees yet, no event");

        PoolKey memory k = launcher.position(family, 0).key;
        IHookrRouter.Swap memory buy = _swap(k, true, true, 1e22);
        IHookrRouter.Swap memory sell = _swap(k, false, true, 5e21);
        vm.startPrank(trader);
        router.swap(buy, address(0), new uint256[](0));
        router.swap(sell, address(0), new uint256[](0));
        vm.stopPrank();

        address other = address(0xBEEF);
        vm.recordLogs();
        (uint256 a0, uint256 a1) = launcher.withdraw(family, 0, 0, 0, 0, other, block.timestamp);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs), 1);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(launcher) || logs[i].topics[0] != TOPIC) continue;
            assertEq(address(uint160(uint256(logs[i].topics[3]))), address(this), "owner");
            (uint8 member, address recipient, uint256 f0, uint256 f1) =
                abi.decode(logs[i].data, (uint8, address, uint256, uint256));
            assertEq(member, 0);
            assertEq(recipient, other, "actual recipient");
            assertEq(f0, a0);
            assertEq(f1, a1);
        }
        assertGt(a0 + a1, 0);
        assertEq(IERC20(Currency.unwrap(k.currency0)).balanceOf(other), a0);
        assertEq(IERC20(Currency.unwrap(k.currency1)).balanceOf(other), a1);

        // A second collect with nothing accrued emits nothing.
        vm.recordLogs();
        launcher.withdraw(family, 0, 0, 0, 0, other, block.timestamp);
        assertEq(_count(vm.getRecordedLogs()), 0);
    }
}
