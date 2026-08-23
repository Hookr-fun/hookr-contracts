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
import {HookrToken} from "../src/HookrToken.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {AtomicSandwicher} from "./ZZSandwichVerify.t.sol";

contract ZZSandwichVerify2 is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 3));
    uint256 constant LIVE_GAS_PRICE = 20_082_000; // cast gas-price on chain 4663

    HookrLaunchpad pad;
    HookrHook hook;
    PoolSwapTest router;

    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBADBAD);

    function setUp() public {
        vm.createSelectFork("robinhood");
        pad = new HookrLaunchpad(PM);
        bytes memory creation = abi.encodePacked(type(HookrHook).creationCode, abi.encode(PM, address(pad)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(PM, address(pad));
        assertEq(address(hook), predicted);
        pad.setHook(hook);
        router = new PoolSwapTest(PM);
        vm.deal(creator, 5000 ether);
        vm.deal(alice, 5000 ether);
        vm.deal(bob, 5000 ether);
        vm.deal(attacker, 5000 ether);
    }

    function _launch(HookrLaunchpad.HookParams memory p, uint96 target)
        internal
        returns (address token, PoolKey memory key)
    {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "SW";
        a.symbol = "SW";
        a.targetRaiseWei = target;
        a.blueprintId = 0;
        a.custom = p;
        vm.prank(creator);
        token = pad.launch{value: pad.creationFeeWei()}(a);
        vm.prank(alice);
        pad.buy{value: uint256(target) * 3}(token, 0);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _buy(address who, PoolKey memory key, uint256 ethIn) internal {
        vm.prank(who);
        router.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: 4295128740}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// The exact hook config of the ONE live graduated pool on chain 4663
    /// (0x8cfabCC5bd46A3421c49171232fD366490Be6b0F), read with cast getLaunch().
    function _liveParams() internal pure returns (HookrLaunchpad.HookParams memory p) {
        p = HookrLaunchpad.HookParams({
            guardBlocks: 20,
            maxBuyBps: 200,
            snipeTaxPips: 200_000,
            baseFeePips: 3000,
            maxFeePips: 30_000,
            surgeSens: 5,
            burnBps: 100,
            burnTriggerWei: 1e12,
            lpBps: 25,
            potBps: 50,
            potOdds: 10,
            potMinBuyWei: 1e13
        });
    }

    /// Fine sweep with the live pool's own hook config, a realistic vault, and the real
    /// live gas price netted out. Reports the best net-of-gas extraction.
    function test_liveConfig_netOfGas_sweep() public {
        uint256[10] memory sizes = [
            uint256(0.002 ether),
            0.005 ether,
            0.01 ether,
            0.015 ether,
            0.02 ether,
            0.03 ether,
            0.05 ether,
            0.08 ether,
            0.15 ether,
            0.4 ether
        ];
        for (uint256 s = 0; s < sizes.length; s++) {
            uint256 outer = vm.snapshotState();
            HookrLaunchpad.HookParams memory p = _liveParams();
            p.burnTriggerWei = 0.02 ether; // builder default trigger
            (, PoolKey memory key) = _launch(p, 0.01 ether);
            PoolId id = key.toId();
            vm.roll(block.number + 100); // past the anti-snipe guard
            // build a real vault from real volume
            while (hook.burnVaultWei(id) < 0.02 ether) {
                _buy(bob, key, 0.1 ether);
            }
            uint256 vault = hook.burnVaultWei(id);
            (uint160 sp,,,) = PM.getSlot0(id);
            uint256 ethDepth = (uint256(PM.getLiquidity(id)) << 96) / sp;

            uint256 snap = vm.snapshotState();
            hook.buybackAndBurn(key);
            uint256 honest = hook.totalBurnedTokens(id);
            vm.revertToState(snap);

            AtomicSandwicher a = new AtomicSandwicher(router, hook);
            vm.deal(address(a), 1000 ether);
            uint256 g0 = gasleft();
            int256 pnl = a.run(key, sizes[s]);
            uint256 gasUsed = g0 - gasleft();
            int256 net = pnl - int256(gasUsed * LIVE_GAS_PRICE);

            console2.log("front-run:", sizes[s], "vault:", vault);
            console2.log("  eth depth:", ethDepth, "gas:", gasUsed);
            console2.log("  gross PnL:");
            console2.logInt(pnl);
            console2.log("  net of gas @0.020082 gwei:");
            console2.logInt(net);
            console2.log("  burn honest/sandwiched:", honest, hook.totalBurnedTokens(id));
            vm.revertToState(outer);
        }
    }

    /// Same, but on a deeper pool (1 ETH target) to check the result is not an artifact of
    /// the 0.01 ETH default raise.
    function test_liveConfig_deepPool() public {
        uint256[6] memory sizes =
            [uint256(0.05 ether), 0.1 ether, 0.2 ether, 0.4 ether, 1 ether, 3 ether];
        for (uint256 s = 0; s < sizes.length; s++) {
            uint256 outer = vm.snapshotState();
            HookrLaunchpad.HookParams memory p = _liveParams();
            p.burnTriggerWei = 0.5 ether;
            (, PoolKey memory key) = _launch(p, 1 ether);
            PoolId id = key.toId();
            vm.roll(block.number + 100);
            while (hook.burnVaultWei(id) < 0.5 ether) {
                _buy(bob, key, 2 ether);
            }
            uint256 vault = hook.burnVaultWei(id);
            (uint160 sp,,,) = PM.getSlot0(id);
            uint256 ethDepth = (uint256(PM.getLiquidity(id)) << 96) / sp;

            uint256 snap = vm.snapshotState();
            hook.buybackAndBurn(key);
            uint256 honest = hook.totalBurnedTokens(id);
            vm.revertToState(snap);

            AtomicSandwicher a = new AtomicSandwicher(router, hook);
            vm.deal(address(a), 5000 ether);
            uint256 g0 = gasleft();
            int256 pnl = a.run(key, sizes[s]);
            uint256 gasUsed = g0 - gasleft();

            console2.log("DEEP front-run:", sizes[s], "vault:", vault);
            console2.log("  eth depth:", ethDepth);
            console2.log("  gross PnL:");
            console2.logInt(pnl);
            console2.log("  net of gas:");
            console2.logInt(pnl - int256(gasUsed * LIVE_GAS_PRICE));
            console2.log("  burn honest/sandwiched:", honest, hook.totalBurnedTokens(id));
            vm.revertToState(outer);
        }
    }
}
