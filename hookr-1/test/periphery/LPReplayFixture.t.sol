// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";

/// @notice Independent real-PoolManager fixture. Exported JSON is test evidence, never live history.
contract LPReplayFixtureTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    string private eventsJson;
    uint256 private step;
    bytes32 private family;
    PoolKey private key;
    PoolModifyLiquidityTest private background;
    uint256[2] private oldOwnerNumerator;
    uint256[2] private newOwnerNumerator;

    function setUp() public {
        _setUpPeriphery();
    }

    function testExportIndependentMixedLPHistory() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[0].tickLower = -600;
        members[0].tickUpper = 600;
        members[0].rules.burnBps = 0;
        members[0].rules.lpBps = 0;
        members[0].rules.potBps = 0;
        members[0].rules.royaltyBps = 0;
        members[0].rules.royaltyTo = address(0);
        members[0].rules.potEveryNBuys = 0;
        members[0].rules.potMinBuyQuote = 0;
        members[0].rules.protocolShareBps = 0;
        _begin();
        (family,) = launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, block.timestamp
        );
        key = launcher.position(family, 0).key;
        _capture();
        background = new PoolModifyLiquidityTest(manager);
        tokenA.approve(address(background), type(uint256).max);
        tokenB.approve(address(background), type(uint256).max);
        _begin();
        background.modifyLiquidity(key, ModifyLiquidityParams(-60_000, 60_000, 1e24, bytes32(0)), "");
        _capture();
        _trade(true, true, 1e23, false);
        (, int24 crossed,,) = manager.getSlot0(key.toId());
        assertTrue(crossed < -600 || crossed > 600, "fixture must cross an initialized boundary");
        _trade(false, false, 7e22, false);
        PoolDonateTest donor = new PoolDonateTest(manager);
        tokenA.approve(address(donor), type(uint256).max);
        tokenB.approve(address(donor), type(uint256).max);
        _begin();
        donor.donate(key, 3e20, 5e20, "");
        _capture();
        _begin();
        launcher.addLiquidity(family, 0, 2e23, 1e24, 1e24, block.timestamp);
        _capture();
        _trade(true, true, 3e22, false);
        _begin();
        // Two-step transfer (L-13): FamilyTransferred is emitted when the new owner accepts.
        launcher.transferFamily(family, trader, 0);
        vm.prank(trader);
        launcher.acceptFamily(family);
        _capture();
        _trade(false, true, 6e22, true);
        _begin();
        vm.prank(trader);
        launcher.withdraw(family, 0, 3e23, 0, 0, trader, block.timestamp);
        _capture();
        _trade(true, false, 2e22, true);
        _begin();
        vm.prank(trader);
        launcher.withdraw(family, 0, 0, 0, 0, trader, block.timestamp);
        _capture();
        assertGt(oldOwnerNumerator[0] + oldOwnerNumerator[1], 0);
        assertGt(newOwnerNumerator[0] + newOwnerNumerator[1], 0);
        string memory result = string.concat(
            '{"schema":"hookr.lp-fixture.v1","chainId":"',
            vm.toString(block.chainid),
            '","kind":"local-solidity-real-poolmanager","manager":"',
            vm.toString(address(manager)),
            '","root":"',
            vm.toString(address(root)),
            '","launcher":"',
            vm.toString(address(launcher)),
            '","router":"',
            vm.toString(address(router)),
            '","familyId":"',
            vm.toString(family),
            '","poolId":"',
            vm.toString(PoolId.unwrap(key.toId())),
            '","events":[',
            eventsJson,
            '],"storage":',
            _storage(),
            ',"expectedAmounts":{"',
            vm.toString(address(this)),
            '":["',
            vm.toString(oldOwnerNumerator[0] >> 128),
            '","',
            vm.toString(oldOwnerNumerator[1] >> 128),
            '"],"',
            vm.toString(trader),
            '":["',
            vm.toString(newOwnerNumerator[0] >> 128),
            '","',
            vm.toString(newOwnerNumerator[1] >> 128),
            '"]}}'
        );
        emit log_named_string("LP_REPLAY_VECTOR", result);
    }

    function _trade(bool buy, bool exactInput, uint128 amount, bool newOwner) private {
        uint128 liq = launcher.position(family, 0).liquidity;
        (uint256 a, uint256 b) = manager.getFeeGrowthInside(key.toId(), -600, 600);
        _begin();
        IHookrRouter.Swap memory params = _swap(key, buy, exactInput, amount);
        vm.prank(trader);
        router.swap(params, address(0), new uint256[](0));
        _capture();
        (uint256 c, uint256 d) = manager.getFeeGrowthInside(key.toId(), -600, 600);
        if (newOwner) {
            newOwnerNumerator[0] += (c - a) * liq;
            newOwnerNumerator[1] += (d - b) * liq;
        } else {
            oldOwnerNumerator[0] += (c - a) * liq;
            oldOwnerNumerator[1] += (d - b) * liq;
        }
    }

    function _begin() private {
        ++step;
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        vm.recordLogs();
    }

    function _capture() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            string memory topics;
            for (uint256 j; j < logs[i].topics.length; ++j) {
                topics = string.concat(topics, j == 0 ? "" : ",", '"', vm.toString(logs[i].topics[j]), '"');
            }
            eventsJson = string.concat(
                eventsJson,
                bytes(eventsJson).length == 0 ? "" : ",",
                '{"address":"',
                vm.toString(logs[i].emitter),
                '","topics":[',
                topics,
                '],"data":"',
                vm.toString(logs[i].data),
                '","step":',
                vm.toString(step),
                ',"index":',
                vm.toString(i),
                ',"contractBlock":"',
                vm.toString(block.number),
                '","timestamp":',
                vm.toString(block.timestamp),
                "}"
            );
        }
    }

    function _storage() private view returns (string memory) {
        bytes32 pool = keccak256(abi.encode(key.toId(), uint256(6)));
        string memory data = _words(pool, 4);
        int24[4] memory ticks = [int24(-600), int24(600), int24(-60_000), int24(60_000)];
        for (uint256 i; i < ticks.length; ++i) {
            data = string.concat(
                data, ",", _words(keccak256(abi.encode(int256(ticks[i]), bytes32(uint256(pool) + 4))), 3)
            );
        }
        bytes32 familyPosition = keccak256(
            abi.encodePacked(address(launcher), int24(-600), int24(600), keccak256(abi.encode(family, uint8(0))))
        );
        bytes32 backgroundPosition =
            keccak256(abi.encodePacked(address(background), int24(-60_000), int24(60_000), bytes32(0)));
        data = string.concat(
            data,
            ",",
            _words(keccak256(abi.encode(familyPosition, bytes32(uint256(pool) + 6))), 3),
            ",",
            _words(keccak256(abi.encode(backgroundPosition, bytes32(uint256(pool) + 6))), 3)
        );
        return string.concat("{", data, "}");
    }

    function _words(bytes32 slot, uint256 count) private view returns (string memory result) {
        bytes32[] memory words = manager.extsload(slot, count);
        for (uint256 i; i < words.length; ++i) {
            result = string.concat(
                result,
                i == 0 ? "" : ",",
                '"',
                vm.toString(bytes32(uint256(slot) + i)),
                '":"',
                vm.toString(words[i]),
                '"'
            );
        }
    }
}
