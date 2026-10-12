// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrPairRoot} from "../../src/factory/HookrPairRoot.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {IHookrSessionAdvisory} from "../../src/interfaces/IHookrSessionAdvisory.sol";
import {HookrSessionTiers} from "../../src/libraries/HookrSessionTiers.sol";
import {HookrMarketCalendar} from "../../src/libraries/HookrMarketCalendar.sol";
import {PairRootFixture} from "./PairRootFixture.sol";
import {GasMeasure} from "../utils/GasMeasure.sol";

/// @dev Swap gas through a plain unlock-callback router against the real PoolManager: hookless static-fee pool vs a
///      pair root without an advisory vs a pair root with a constant mock advisory, HookrFeeAdvisory (500-pip default,
///      1,000-pip cap), HookrSessionAdvisory, or HookrFeeAdvisory with session tiers (200-pip default plus a 300-pip
///      tier), all in regular hours (Tuesday 2026-09-29 11:00 New York). Every pool has the same price, range and
///      liquidity and was swapped both ways one block earlier. Run with `--isolate` for per-transaction gasUsed
///      (the top-level call, through GasMeasure); the totals are committed in snapshots/HookrPairRootGasTest.json.
contract HookrPairRootGasTest is PairRootFixture, GasMeasure {
    PoolKey internal ercPlain;
    PoolKey internal ercRoot;
    PoolKey internal ercAdvised;
    PoolKey internal ethPlain;
    PoolKey internal ethRoot;
    PoolKey internal ethAdvised;
    PoolKey internal ercFee;
    PoolKey internal ethFee;
    PoolKey internal ercSession;
    PoolKey internal ethSession;
    PoolKey internal ercFeeTiers;
    PoolKey internal ethFeeTiers;

    /// @dev The release's registry delay.
    function _registryDelay() internal pure override returns (uint48) {
        return 30 minutes;
    }

    function setUp() public {
        _setUpFactory();
        HookrFeeAdvisory fee =
            new HookrFeeAdvisory(address(this), 30 minutes, IHookrRegistry(address(registry)), address(0));
        HookrSessionAdvisory session = new HookrSessionAdvisory(address(this), 30 minutes);
        HookrFeeAdvisory feeTiers =
            new HookrFeeAdvisory(address(this), 30 minutes, IHookrRegistry(address(registry)), address(session));
        advisory.set(0, 500);
        vm.roll(100);
        (Currency a0, Currency a1) = _erc();
        (Currency e0, Currency e1) = _eth();
        ercPlain = PoolKey(a0, a1, 3_000, 60, IHooks(address(0)));
        ethPlain = PoolKey(e0, e1, 3_000, 60, IHooks(address(0)));
        manager.initialize(ercPlain, SQRT_ONE);
        manager.initialize(ethPlain, SQRT_ONE);
        (, ercRoot) = _deploy(_plain(a0, a1, 3_000));
        (, ethRoot) = _deploy(_plain(e0, e1, 3_000));
        (, ercAdvised) = _deploy(_advised(a0, a1, 3_000, 1_000, false));
        (, ethAdvised) = _deploy(_advised(e0, e1, 3_000, 1_000, false));
        bytes memory feeData = abi.encode(IHookrFeeAdvisory.Config(1_000, 500, 0, 0, 100, 60, 1 hours));
        bytes memory sessionData = abi.encode(IHookrSessionAdvisory.Schedule(500, 800, 800, 1_000, 1_000, 0, 0, 0));
        (, ercFee) = _deploy(_with(_advised(a0, a1, 3_000, 1_000, false), address(fee), 50_000), feeData);
        (, ethFee) = _deploy(_with(_advised(e0, e1, 3_000, 1_000, false), address(fee), 50_000), feeData);
        (, ercSession) = _deploy(_with(_advised(a0, a1, 3_000, 1_000, false), address(session), 60_000), sessionData);
        (, ethSession) = _deploy(_with(_advised(e0, e1, 3_000, 1_000, false), address(session), 60_000), sessionData);
        // 200 keeper default + 300 regular-hours tier: the same 500-pip surcharge.
        bytes memory tieredData = abi.encode(
            IHookrFeeAdvisory.Config(1_000, 200, 0, 0, 100, 60, 1 hours),
            HookrSessionTiers.Tiers(300, 600, 600, 800, 800, 0, 0, 0)
        );
        (, ercFeeTiers) = _deploy(_with(_advised(a0, a1, 3_000, 1_000, false), address(feeTiers), 60_000), tieredData);
        (, ethFeeTiers) = _deploy(_with(_advised(e0, e1, 3_000, 1_000, false), address(feeTiers), 60_000), tieredData);
        vm.warp(HookrMarketCalendar.dayOf(2026, 9, 29) * 1 days + 15 hours);
        PoolKey[12] memory all = [
            ercPlain,
            ercRoot,
            ercAdvised,
            ethPlain,
            ethRoot,
            ethAdvised,
            ercFee,
            ethFee,
            ercSession,
            ethSession,
            ercFeeTiers,
            ethFeeTiers
        ];
        vm.roll(101);
        for (uint256 i; i < all.length; ++i) {
            _fund(all[i]);
            _swap(all[i], true, -1e16, "");
            _swap(all[i], false, -1e16, "");
        }
        vm.roll(102);
    }

    function _with(IHookrPairRoot.Params memory p, address module, uint32 gasLimit)
        internal
        pure
        returns (IHookrPairRoot.Params memory)
    {
        p.advisory = module;
        p.advisoryGasLimit = gasLimit;
        return p;
    }

    function _measure(string memory label, PoolKey memory key, bool zeroForOne) internal returns (uint256 used) {
        _swap(key, zeroForOne, -1e17, "");
        used = _measure(label);
    }

    function test_gas_erc20_hookless_zeroForOne() public {
        _measure("erc20 hookless 0->1", ercPlain, true);
    }

    function test_gas_erc20_hookless_oneForZero() public {
        _measure("erc20 hookless 1->0", ercPlain, false);
    }

    function test_gas_erc20_pairRoot_zeroForOne() public {
        _measure("erc20 pairRoot 0->1", ercRoot, true);
    }

    function test_gas_erc20_pairRoot_oneForZero() public {
        _measure("erc20 pairRoot 1->0", ercRoot, false);
    }

    function test_gas_erc20_pairRootAdvised_zeroForOne() public {
        _measure("erc20 pairRoot+advisory 0->1", ercAdvised, true);
    }

    function test_gas_erc20_pairRootAdvised_oneForZero() public {
        _measure("erc20 pairRoot+advisory 1->0", ercAdvised, false);
    }

    function test_gas_native_hookless_ethIn() public {
        _measure("native hookless ETH->token", ethPlain, true);
    }

    function test_gas_native_hookless_tokenIn() public {
        _measure("native hookless token->ETH", ethPlain, false);
    }

    function test_gas_native_pairRoot_ethIn() public {
        _measure("native pairRoot ETH->token", ethRoot, true);
    }

    function test_gas_native_pairRoot_tokenIn() public {
        _measure("native pairRoot token->ETH", ethRoot, false);
    }

    function test_gas_native_pairRootAdvised_ethIn() public {
        _measure("native pairRoot+advisory ETH->token", ethAdvised, true);
    }

    function test_gas_native_pairRootAdvised_tokenIn() public {
        _measure("native pairRoot+advisory token->ETH", ethAdvised, false);
    }

    function test_gas_erc20_pairRootFee_zeroForOne() public {
        _measure("erc20 pairRoot+fee 0->1", ercFee, true);
    }

    function test_gas_erc20_pairRootFee_oneForZero() public {
        _measure("erc20 pairRoot+fee 1->0", ercFee, false);
    }

    function test_gas_native_pairRootFee_ethIn() public {
        _measure("native pairRoot+fee ETH->token", ethFee, true);
    }

    function test_gas_native_pairRootFee_tokenIn() public {
        _measure("native pairRoot+fee token->ETH", ethFee, false);
    }

    function test_gas_erc20_pairRootSession_zeroForOne() public {
        _measure("erc20 pairRoot+session 0->1", ercSession, true);
    }

    function test_gas_erc20_pairRootSession_oneForZero() public {
        _measure("erc20 pairRoot+session 1->0", ercSession, false);
    }

    function test_gas_native_pairRootSession_ethIn() public {
        _measure("native pairRoot+session ETH->token", ethSession, true);
    }

    function test_gas_native_pairRootSession_tokenIn() public {
        _measure("native pairRoot+session token->ETH", ethSession, false);
    }

    function test_gas_erc20_pairRootFeeTiers_zeroForOne() public {
        _measure("erc20 pairRoot+fee+tiers 0->1", ercFeeTiers, true);
    }

    function test_gas_erc20_pairRootFeeTiers_oneForZero() public {
        _measure("erc20 pairRoot+fee+tiers 1->0", ercFeeTiers, false);
    }

    function test_gas_native_pairRootFeeTiers_ethIn() public {
        _measure("native pairRoot+fee+tiers ETH->token", ethFeeTiers, true);
    }

    function test_gas_native_pairRootFeeTiers_tokenIn() public {
        _measure("native pairRoot+fee+tiers token->ETH", ethFeeTiers, false);
    }

    /// The beforeSwap call alone, cold, as the PoolManager makes it: the arguments are read into memory before the
    /// window opens, so it holds the cold account access, the call with its calldata, the frame (with the advisory's
    /// cold call inside it) and the returned values, and none of this test's own storage. It is measured with gasleft
    /// around the call, so the figure is the same with and without --isolate (vm.cool empties the warm set in both).
    function test_gas_beforeSwapFrame() public {
        SwapParams memory sp = SwapParams(true, -1e17, TickMath.MIN_SQRT_PRICE + 1);
        PoolKey memory plainKey = ethRoot;
        PoolKey memory advisedKey = ethAdvised;
        address sender = address(router);
        address poolManager = address(manager);
        HookrPairRoot plain = HookrPairRoot(address(plainKey.hooks));
        HookrPairRoot advised = HookrPairRoot(address(advisedKey.hooks));
        vm.cool(address(plain));
        vm.prank(poolManager);
        uint256 start = gasleft();
        plain.beforeSwap(sender, plainKey, sp, "");
        _record("beforeSwap frame pairRoot", start - gasleft());
        vm.cool(address(advised));
        vm.cool(address(advisory));
        vm.prank(poolManager);
        start = gasleft();
        (,, uint24 fee) = advised.beforeSwap(sender, advisedKey, sp, "");
        _record("beforeSwap frame pairRoot+advisory", start - gasleft());
        assertEq(fee, 3_500 | 0x400000);
    }
}
