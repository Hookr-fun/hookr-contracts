// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrSwapRouter} from "../src/HookrSwapRouter.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Deterministic 2^5 composition gate against a locally deployed canonical PoolManager.
///         Bits are SNIPE | SURGE | AUTO_BURN | LP_REWARDS | DETERMINISTIC_POT.
contract HookCombinationMatrixTest is Test {
    /// @dev The hook's flywheel recipient. address(0) = flywheel dormant (pre-flywheel semantics).
    address constant FLYWHEEL_RECIPIENT = address(0);

    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint160 constant MIN_LIMIT = 4295128739 + 1;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint8 constant SNIPE = 1 << 0;
    uint8 constant SURGE = 1 << 1;
    uint8 constant BURN = 1 << 2;
    uint8 constant LP = 1 << 3;
    uint8 constant POT = 1 << 4;

    IPoolManager manager;
    HookrLaunchpad pad;
    HookrHook hook;
    HookrSwapRouter router;
    address creator = address(0xC0FFEE);
    address trader = address(0xB0B);

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        pad = new HookrLaunchpad(manager);
        bytes memory creation =
            abi.encodePacked(type(HookrHook).creationCode, abi.encode(manager, address(pad), FLYWHEEL_RECIPIENT));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(manager, address(pad), FLYWHEEL_RECIPIENT);
        assertEq(address(hook), predicted);
        pad.setHook(hook);
        router = new HookrSwapRouter(manager, hook, address(0));

        vm.deal(creator, 100 ether);
        vm.deal(trader, 100 ether);
    }

    function _params(uint8 mask, uint32 potEveryN) internal pure returns (HookrLaunchpad.HookParams memory p) {
        bool snipe = mask & SNIPE != 0;
        bool surge = mask & SURGE != 0;
        bool burn = mask & BURN != 0;
        bool lp = mask & LP != 0;
        bool pot = mask & POT != 0;
        p = HookrLaunchpad.HookParams({
            guardBlocks: snipe ? 100 : 0,
            maxBuyBps: snipe ? 50 : 0,
            snipeTaxPips: snipe ? 400_000 : 0,
            baseFeePips: 3000,
            maxFeePips: surge ? 30_000 : 3000,
            surgeSens: surge ? 5 : 0,
            burnBps: burn ? 100 : 0,
            burnTriggerWei: 0,
            lpBps: lp ? 25 : 0,
            potBps: pot ? 50 : 0,
            potEveryNBuys: pot ? potEveryN : 0,
            potMinBuyWei: pot ? 0.001 ether : 0
        });
    }

    function _graduate(uint8 mask, uint32 potEveryN) internal returns (address token, PoolKey memory key, PoolId id) {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = string(abi.encodePacked("Mask ", vm.toString(mask)));
        a.symbol = string(abi.encodePacked("M", vm.toString(mask)));
        a.expectedCreator = creator;
        a.targetRaiseWei = 0.01 ether;
        a.custom = _params(mask, potEveryN);
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        token = pad.launch{value: fee}(a);
        vm.prank(creator);
        pad.buy{value: 0.02 ether}(token, 0);
        HookrLaunchpad.Launch memory launch = pad.getLaunch(token);
        assertTrue(launch.graduated, "mask did not graduate");
        assertEq(launch.reserveWei, 0, "curve reserve stranded");

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();
        (uint160 sqrtPriceX96,,, uint24 feePips) = manager.getSlot0(id);
        assertGt(sqrtPriceX96, 0, "pool not initialized");
        assertEq(feePips, 3000, "base fee not synced");
        assertGt(manager.getLiquidity(id), 0, "POL not seeded");
    }

    function _assertConfig(uint8 mask, address token, PoolId id) internal view {
        (
            bool initialized,
            uint40 guardEndBlock,
            uint24 baseFeePips,
            uint24 maxFeePips,,
            uint16 surgeSens,
            uint16 burnBps,
            uint16 lpBps,
            uint16 potBps,,
            uint32 potEveryNBuys,,
            uint96 potMinBuyWei,
            uint96 burnTriggerWei,,
            address configuredToken,
        ) = hook.poolConfig(id);
        assertTrue(initialized);
        assertEq(configuredToken, token);
        assertEq(baseFeePips, 3000);
        assertEq(maxFeePips, mask & SURGE != 0 ? 30_000 : 3000);
        assertEq(surgeSens, mask & SURGE != 0 ? 5 : 0);
        assertEq(burnBps, mask & BURN != 0 ? 100 : 0);
        assertEq(lpBps, mask & LP != 0 ? 25 : 0);
        assertEq(potBps, mask & POT != 0 ? 50 : 0);
        assertEq(potEveryNBuys, mask & POT != 0 ? 500 : 0);
        assertEq(potMinBuyWei, mask & POT != 0 ? 0.001 ether : 0);
        assertEq(burnTriggerWei, 0, "compatibility-only trigger must stay zero");
        if (mask & SNIPE != 0) assertGt(guardEndBlock, 0);
        else assertEq(guardEndBlock, 0);
    }

    function _trade(PoolKey memory key, address recipient, uint128 amountIn) internal returns (uint256 out) {
        HookrSwapRouter.ExactInputParams memory p = HookrSwapRouter.ExactInputParams({
            key: key,
            zeroForOne: true,
            amountIn: amountIn,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: MIN_LIMIT,
            recipient: recipient,
            deadline: block.timestamp + 1
        });
        vm.prank(trader);
        out = router.exactInput{value: amountIn}(p);
    }

    function test_localCanonicalPoolManager_all32Masks_graduateAndTradeThroughProductionRouter() public {
        uint256 expectedNativeClaims;
        for (uint8 mask = 0; mask < 32; mask++) {
            (address token, PoolKey memory key, PoolId id) = _graduate(mask, 500);
            _assertConfig(mask, token, id);
            if (mask & SNIPE != 0) vm.roll(vm.getBlockNumber() + 101);

            uint256 deadBefore = HookrToken(token).balanceOf(DEAD);
            uint256 lpBefore = hook.totalLpDonatedWei(id);
            uint256 out = _trade(key, trader, 0.001 ether);
            assertGt(out, 0, "bounded router returned no output");

            uint256 burned = HookrToken(token).balanceOf(DEAD) - deadBefore;
            if (mask & BURN != 0) {
                assertGt(burned, 0, "auto-burn block inactive");
                assertEq(hook.totalBurnedTokens(id), burned);
            } else {
                assertEq(burned, 0, "burn occurred without block");
                assertEq(hook.totalBurnedTokens(id), 0);
            }
            if (mask & LP != 0) assertGt(hook.totalLpDonatedWei(id) - lpBefore, 0, "LP block inactive");
            else assertEq(hook.totalLpDonatedWei(id), lpBefore, "LP donation without block");

            if (mask & POT != 0) {
                assertEq(hook.potBuyCount(id), 1, "pot counter did not advance");
                assertGt(hook.potWei(id), 0, "pot did not accrue");
                expectedNativeClaims += hook.potWei(id);
            } else {
                assertEq(hook.potBuyCount(id), 0);
                assertEq(hook.potWei(id), 0);
            }
            assertEq(hook.burnVaultWei(id), 0, "legacy burn vault must stay empty");
            assertEq(hook.nativeClaimBalance(), expectedNativeClaims, "shared native claims not fully accounted");
            assertEq(address(hook).balance, 0, "shared hook must not custody physical ETH");
            assertEq(address(router).balance, 0, "router retained native value");
            assertEq(HookrToken(token).balanceOf(address(router)), 0, "router retained token output");
        }
    }

    function test_localCanonicalPoolManager_allFiveBlocks_composeAcrossBlocks() public {
        uint8 mask = SNIPE | SURGE | BURN | LP | POT;
        (address token, PoolKey memory key, PoolId id) = _graduate(mask, 2);
        vm.roll(vm.getBlockNumber() + 101);

        uint256 deadBefore = HookrToken(token).balanceOf(DEAD);
        uint256 first = _trade(key, trader, 0.001 ether);
        assertGt(first, 0);
        assertEq(hook.potBuyCount(id), 1);
        uint256 potAfterFirst = hook.potWei(id);
        assertGt(potAfterFirst, 0);

        _trade(key, trader, 0.001 ether);
        assertEq(hook.potBuyCount(id), 1, "same block manufactured another pot slot");
        assertGt(hook.potWei(id), potAfterFirst, "same-block buy still contributes value");

        vm.roll(vm.getBlockNumber() + 1);
        _trade(key, trader, 0.001 ether);
        assertEq(hook.potBuyCount(id), 2);
        assertGt(hook.claimableWei(trader), 0, "second distinct block won deterministic pot");
        assertGt(HookrToken(token).balanceOf(DEAD), deadBefore, "auto-burn composed");
        assertGt(hook.totalLpDonatedWei(id), 0, "LP donation composed");
        assertEq(hook.burnVaultWei(id), 0);
        assertEq(address(router).balance, 0);
    }
}
