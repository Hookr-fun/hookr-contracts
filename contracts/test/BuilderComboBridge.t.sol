// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {HookrBlueprints} from "../src/HookrBlueprints.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLaunchpadLib} from "../src/libraries/HookrLaunchpadLib.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrSwapRouter} from "../src/HookrSwapRouter.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice UI->contract bridge: every builder combo the app can produce (2^5 stacks at
///         default, minimum, and maximum slider positions, compiled by the real TypeScript
///         compileStack into test/fixtures/builder-combos.json) must launch, graduate, and
///         configure the pool with exactly the values the builder promised. The fixture is
///         drift-guarded by src/lib/builder-combo-matrix.test.ts.
contract BuilderComboBridgeTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    IPoolManager manager;
    HookrLaunchpad pad;

    HookrBlueprints bpReg;
    HookrHook hook;
    HookrSwapRouter router;
    address creator = address(0xC0FFEE);

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        pad = new HookrLaunchpad(manager, new HookrBlueprints(address(this)));
        bpReg = pad.blueprints();
        bytes memory creation = abi.encodePacked(type(HookrHook).creationCode, abi.encode(manager, address(pad)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(manager, address(pad));
        assertEq(address(hook), predicted);
        pad.setHook(hook);
        router = new HookrSwapRouter(manager, hook);
        vm.deal(creator, 100 ether);
    }

    function _readParams(string memory json, string memory base)
        internal
        view
        returns (HookrLaunchpadLib.HookParams memory p)
    {
        p = HookrLaunchpadLib.HookParams({
            guardBlocks: uint32(vm.parseJsonUint(json, string.concat(base, ".params.guardBlocks"))),
            maxBuyBps: uint16(vm.parseJsonUint(json, string.concat(base, ".params.maxBuyBps"))),
            snipeTaxPips: uint24(vm.parseJsonUint(json, string.concat(base, ".params.snipeTaxPips"))),
            baseFeePips: uint24(vm.parseJsonUint(json, string.concat(base, ".params.baseFeePips"))),
            maxFeePips: uint24(vm.parseJsonUint(json, string.concat(base, ".params.maxFeePips"))),
            surgeSens: uint16(vm.parseJsonUint(json, string.concat(base, ".params.surgeSens"))),
            burnBps: uint16(vm.parseJsonUint(json, string.concat(base, ".params.burnBps"))),
            burnTriggerWei: uint96(vm.parseJsonUint(json, string.concat(base, ".params.burnTriggerWei"))),
            lpBps: uint16(vm.parseJsonUint(json, string.concat(base, ".params.lpBps"))),
            potBps: uint16(vm.parseJsonUint(json, string.concat(base, ".params.potBps"))),
            potEveryNBuys: uint32(vm.parseJsonUint(json, string.concat(base, ".params.potEveryNBuys"))),
            potMinBuyWei: uint96(vm.parseJsonUint(json, string.concat(base, ".params.potMinBuyWei"))),
            buybackBps: uint16(vm.parseJsonUint(json, string.concat(base, ".params.buybackBps"))),
            buybackDrawdownBps: uint16(vm.parseJsonUint(json, string.concat(base, ".params.buybackDrawdownBps"))),
            buybackCooldownBlocks: uint32(vm.parseJsonUint(json, string.concat(base, ".params.buybackCooldownBlocks"))),
            buybackMinSpendWei: uint96(vm.parseJsonUint(json, string.concat(base, ".params.buybackMinSpendWei"))),
            buybackMaxSpendWei: uint96(vm.parseJsonUint(json, string.concat(base, ".params.buybackMaxSpendWei")))
        });
    }

    function test_everyBuilderCombo_launchesGraduatesAndMatchesPromisedConfig() public {
        string memory json = vm.readFile("test/fixtures/builder-combos.json");
        uint256 i = 0;
        uint256 launched = 0;
        while (true) {
            string memory base = string.concat(".combos[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, string.concat(base, ".name"))) break;
            string memory name = vm.parseJsonString(json, string.concat(base, ".name"));
            HookrLaunchpadLib.HookParams memory p = _readParams(json, base);

            HookrLaunchpad.LaunchArgs memory a;
            a.name = name;
            a.symbol = string.concat("C", vm.toString(i));
            a.expectedCreator = creator;
            a.targetRaiseWei = 0.01 ether;
            a.custom = p;
            uint256 fee = pad.creationFeeWei();

            vm.prank(creator);
            address token = pad.launch{value: fee}(a, bytes32(0));
            vm.prank(creator);
            pad.buy{value: 0.02 ether}(token, 0);
            HookrLaunchpad.Launch memory l = pad.getLaunch(token);
            assertTrue(l.graduated, string.concat(name, ": did not graduate"));

            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(token),
                fee: 0x800000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            PoolId id = key.toId();
            (uint160 sqrtPriceX96,,, uint24 lpFee) = manager.getSlot0(id);
            assertGt(sqrtPriceX96, 0, string.concat(name, ": pool not initialized"));
            assertEq(lpFee, p.baseFeePips, string.concat(name, ": base fee not synced"));
            assertGt(manager.getLiquidity(id), 0, string.concat(name, ": no POL"));

            _assertPromisedConfig(name, token, id, p, l.graduatedAtBlock);
            launched++;
            i++;
        }
        assertEq(launched, 190, "fixture entry count changed - regenerate and re-review");
    }

    function _assertPromisedConfig(
        string memory name,
        address token,
        PoolId id,
        HookrLaunchpadLib.HookParams memory p,
        uint256 graduatedAtBlock
    ) internal view {
        (
            bool initialized,
            uint40 guardEndBlock,
            uint24 baseFeePips,
            uint24 maxFeePips,
            uint24 snipeTaxPips,
            uint16 surgeSens,
            uint16 burnBps,
            uint16 lpBps,
            uint16 potBps,, // royaltyBps: custom stacks route no blueprint royalty
            uint32 potEveryNBuys,
            uint96 maxBuyWei,
            uint96 potMinBuyWei,
            uint96 burnTriggerWei,,,,,,, // buyback block + royaltyTo
            address configuredToken
        ) = hook.poolConfig(id);

        assertTrue(initialized, string.concat(name, ": config missing"));
        assertEq(configuredToken, token, string.concat(name, ": token mismatch"));
        assertEq(baseFeePips, p.baseFeePips, string.concat(name, ": baseFee"));
        assertEq(maxFeePips, p.maxFeePips, string.concat(name, ": maxFee"));
        assertEq(surgeSens, p.surgeSens, string.concat(name, ": surgeSens"));
        assertEq(burnBps, p.burnBps, string.concat(name, ": burnBps"));
        assertEq(lpBps, p.lpBps, string.concat(name, ": lpBps"));
        assertEq(potBps, p.potBps, string.concat(name, ": potBps"));
        assertEq(potEveryNBuys, p.potEveryNBuys, string.concat(name, ": potEveryN"));
        assertEq(potMinBuyWei, p.potMinBuyWei, string.concat(name, ": potMinBuy"));
        assertEq(burnTriggerWei, 0, string.concat(name, ": legacy trigger nonzero"));
        if (p.guardBlocks > 0) {
            assertEq(uint256(guardEndBlock), graduatedAtBlock + p.guardBlocks, string.concat(name, ": guard window"));
            assertEq(snipeTaxPips, p.snipeTaxPips, string.concat(name, ": snipeTax"));
            assertEq(maxBuyWei > 0, p.maxBuyBps > 0, string.concat(name, ": maxBuy presence"));
        } else {
            assertEq(guardEndBlock, 0, string.concat(name, ": phantom guard"));
        }
    }
}
