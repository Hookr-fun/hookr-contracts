// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {AtomicSandwicher} from "./ZZSandwichVerify.t.sol";

/// Burn + Surge stack ONLY (the minimal builder stack that both contains a buyback block and
/// can actually graduate). Sweeps front-run size and reports net-of-gas extraction.
contract ZZSandwichVerify3 is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 3));
    uint256 constant LIVE_GAS_PRICE = 20_082_000;

    HookrLaunchpad pad;
    HookrHook hook;
    PoolSwapTest router;
    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.createSelectFork("robinhood");
        pad = new HookrLaunchpad(PM);
        bytes memory creation = abi.encodePacked(type(HookrHook).creationCode, abi.encode(PM, address(pad)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(PM, address(pad));
        assertEq(address(hook), predicted);
        pad.setHook(hook);
        router = new PoolSwapTest(PM);
        vm.deal(creator, 20000 ether);
        vm.deal(alice, 20000 ether);
        vm.deal(bob, 20000 ether);
    }

    function _run(uint96 target, uint96 trigger, uint256 frontRun) internal {
        HookrLaunchpad.HookParams memory p = HookrLaunchpad.HookParams({
            guardBlocks: 0,
            maxBuyBps: 0,
            snipeTaxPips: 0,
            baseFeePips: 3000, // builder default 0.3%
            maxFeePips: 30_000, // builder default 3% ceiling
            surgeSens: 5, // builder default
            burnBps: 100, // builder default 1%
            burnTriggerWei: trigger,
            lpBps: 0,
            potBps: 0,
            potOdds: 0,
            potMinBuyWei: 0
        });
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "SW";
        a.symbol = "SW";
        a.targetRaiseWei = target;
        a.blueprintId = 0;
        a.custom = p;
        vm.prank(creator);
        address token = pad.launch{value: pad.creationFeeWei()}(a);
        vm.prank(alice);
        pad.buy{value: uint256(target) * 3}(token, 0);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId id = key.toId();

        uint256 step = uint256(trigger) * 10; // 1% cut -> 10 buys fills the trigger
        while (hook.burnVaultWei(id) < trigger) {
            vm.prank(bob);
            router.swap{value: step}(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -int256(step), sqrtPriceLimitX96: 4295128740}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        uint256 vault = hook.burnVaultWei(id);
        (uint160 sp,,,) = PM.getSlot0(id);
        uint256 depth = (uint256(PM.getLiquidity(id)) << 96) / sp;

        uint256 snap = vm.snapshotState();
        hook.buybackAndBurn(key);
        uint256 honest = hook.totalBurnedTokens(id);
        vm.revertToState(snap);

        AtomicSandwicher s = new AtomicSandwicher(router, hook);
        vm.deal(address(s), 20000 ether);
        uint256 g0 = gasleft();
        int256 pnl = s.run(key, frontRun);
        uint256 gasUsed = g0 - gasleft();
        int256 net = pnl - int256(gasUsed * LIVE_GAS_PRICE);
        uint256 sand = hook.totalBurnedTokens(id);

        console2.log("vault:", vault, "depth:", depth);
        console2.log("  frontRun:", frontRun);
        console2.log("  net PnL (after live gas):");
        console2.logInt(net);
        console2.log("  burn lost (bps of honest):", honest > sand ? (honest - sand) * 10_000 / honest : 0);
    }

    function test_burnPlusSurge_sweep_smallPool() public {
        uint256[8] memory sizes = [
            uint256(0.002 ether),
            0.005 ether,
            0.01 ether,
            0.02 ether,
            0.04 ether,
            0.08 ether,
            0.16 ether,
            0.4 ether
        ];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            _run(0.01 ether, 0.02 ether, sizes[i]);
            vm.revertToState(snap);
        }
    }

    function test_burnPlusSurge_sweep_bigVault() public {
        // A vault that was allowed to grow well past the trigger: 0.5 ETH against ~5 ETH depth.
        uint256[6] memory sizes =
            [uint256(0.02 ether), 0.05 ether, 0.1 ether, 0.25 ether, 0.6 ether, 1.5 ether];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            _run(0.05 ether, 0.5 ether, sizes[i]);
            vm.revertToState(snap);
        }
    }
}
