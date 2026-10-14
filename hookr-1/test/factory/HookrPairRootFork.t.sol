// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookrRootFactory} from "../../src/factory/HookrRootFactory.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {MockPairAdvisory, mineSalt} from "./PairRootFixture.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {IHookrFactoryRegistry} from "../../src/interfaces/IHookrRootFactory.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {IHookrSessionAdvisory} from "../../src/interfaces/IHookrSessionAdvisory.sol";
import {HookrMarketCalendar} from "../../src/libraries/HookrMarketCalendar.sol";

interface IForkUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IForkPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IForkPositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IForkERC20 {
    function approve(address, uint256) external returns (bool);
}

/// @dev Universal Router 2.1.1 V4_SWAP gas on a Robinhood Chain 4663 fork, same block, packet and pool setup as the
///      Fables comparison harness: hookless static 700-pip pool, pair root (base 700, no advisory), pair root with a
///      constant advisory, pair root with HookrFeeAdvisory (300-pip default), pair root with HookrSessionAdvisory, and
///      the live Fables ETH/USDG pool. Each new pool gets the Fables price and liquidity in one
///      +-100 tick band through the v4 PositionManager, one warm-up swap each way at L1-1, measurement at L1.
///      Skipped unless ALCHEMY_RPC_URL is set. Run with `--isolate` for per-transaction gasUsed.
contract HookrPairRootForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 71_811_725;
    uint256 internal constant FORK_L1_BLOCK = 26_050_989;
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant FX_ETH_HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    bytes32 internal constant FX_ETH_ID = 0xbac3aa3b91584a53a579b3c999a56756e954e59247e497bad1d25a4334bde551;
    int24 internal constant BAND = 100;

    address internal trader = address(0xA11CE);
    address internal warmer = address(0xBEEF);
    address internal lp = address(0x1b);
    bool internal live;

    struct URSingleSwap {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amount;
        uint128 bound;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    function setUp() public {
        string memory url = vm.envOr("ALCHEMY_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url, FORK_BLOCK);
        vm.roll(FORK_L1_BLOCK);
        live = true;
    }

    function _fxKey() internal pure returns (PoolKey memory) {
        return
            PoolKey(
                Currency.wrap(address(0)), Currency.wrap(USDG), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(FX_ETH_HOOK)
            );
    }

    function _holder(address who) internal {
        vm.deal(who, 1_000 ether);
        deal(USDG, who, 1e12);
    }

    function _permit(address who, address spender) internal {
        vm.startPrank(who);
        IForkERC20(USDG).approve(PERMIT2, type(uint256).max);
        IForkPermit2(PERMIT2).approve(USDG, spender, type(uint160).max, uint48(vm.getBlockTimestamp() + 30 days));
        vm.stopPrank();
    }

    function _urSwap(address who, PoolKey memory key, bool zeroForOne, uint128 amountIn) internal {
        bytes[] memory actions = new bytes[](3);
        actions[0] = abi.encode(URSingleSwap(key, zeroForOne, amountIn, 1, 0, ""));
        actions[1] = abi.encode(zeroForOne ? key.currency0 : key.currency1, uint256(amountIn));
        actions[2] = abi.encode(zeroForOne ? key.currency1 : key.currency0, uint256(1));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060c0f", actions);
        vm.prank(who);
        IForkUniversalRouter(UNIVERSAL_ROUTER).execute{value: zeroForOne ? amountIn : 0}(
            hex"10", inputs, vm.getBlockTimestamp() + 600
        );
    }

    function _mint(PoolKey memory key, uint160 sp, uint128 liq) internal {
        int24 c = TickMath.getTickAtSqrtPrice(sp);
        c = (c < 0 && c % 10 != 0 ? c / 10 - 1 : c / 10) * 10;
        vm.deal(lp, 200_000 ether);
        deal(USDG, lp, 50_000_000e6);
        _permit(lp, POSM);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key, c - BAND, c + BAND, uint256(liq), uint128(100_000 ether), type(uint128).max / 2, lp, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, lp);
        bytes memory unlockData = abi.encode(abi.encodePacked(uint8(0x02), uint8(0x0d), uint8(0x14)), params);
        vm.prank(lp);
        IForkPositionManager(POSM).modifyLiquidities{value: 100_000 ether}(unlockData, vm.getBlockTimestamp() + 600);
    }

    /// @dev Admits `module` for `factory` through the ADMIT timelock and restores the block timestamp.
    function _admit(HookrRegistry registry, address factory, address module) internal {
        uint256 t = vm.getBlockTimestamp();
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: module,
            codeHash: module.codehash,
            schemaHash: keccak256("hookr.pair.advisory"),
            caps: HookrTypes.Caps(1_000, 0, 0),
            gasLimit: 60_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(factory, a));
        vm.warp(t + registry.delay());
        registry.admit(factory, a);
        vm.warp(t);
    }

    /// kind 0: hookless static 700; 1: pair root base 700; 2: pair root base 700 + constant 300-pip advisory;
    /// 3: pair root base 700 + HookrFeeAdvisory, 300-pip default, 1,000-pip cap; 4: pair root base 700 +
    /// HookrSessionAdvisory, tiers 300 to 1,000 pips.
    function _pool(uint256 kind) internal returns (PoolKey memory key) {
        (uint160 sp,,,) = PM.getSlot0(PoolId.wrap(FX_ETH_ID));
        uint128 liq = PM.getLiquidity(PoolId.wrap(FX_ETH_ID));
        vm.roll(FORK_L1_BLOCK - 2);
        if (kind == 0) {
            key = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 700, 10, IHooks(address(0)));
            PM.initialize(key, sp);
        } else {
            HookrRegistry registry = new HookrRegistry(address(this), PM, 30 minutes);
            HookrRootFactory factory = new HookrRootFactory(PM, IHookrFactoryRegistry(address(registry)));
            registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), address(factory).codehash, true));
            vm.warp(vm.getBlockTimestamp() + registry.delay());
            registry.setRootFactory(address(factory), address(factory).codehash, true);
            IHookrPairRoot.Params memory p;
            p.currency0 = Currency.wrap(address(0));
            p.currency1 = Currency.wrap(USDG);
            p.tickSpacing = 10;
            p.baseLpFeePips = 700;
            p.maxLpFeePips = 700;
            bytes memory data;
            if (kind >= 2) {
                p.advisoryCapPips = 1_000;
                p.advisoryGasLimit = 60_000;
                p.maxLpFeePips = 1_700;
            }
            if (kind == 2) {
                MockPairAdvisory advisory = new MockPairAdvisory();
                advisory.set(0, 300);
                p.advisory = address(advisory);
            } else if (kind == 3) {
                p.advisory = address(
                    new HookrFeeAdvisory(address(this), 30 minutes, IHookrRegistry(address(registry)), address(0))
                );
                data = abi.encode(IHookrFeeAdvisory.Config(1_000, 300, 0, 0, 100, 60, 1 hours));
            } else if (kind == 4) {
                p.advisory = address(new HookrSessionAdvisory(address(this), 30 minutes));
                data = abi.encode(IHookrSessionAdvisory.Schedule(300, 600, 600, 800, 1_000, 0, 0, 0));
            }
            if (p.advisory != address(0)) _admit(registry, address(factory), p.advisory);
            bytes32 salt = mineSalt(address(factory), address(this), factory.initCodeHash(p), 0);
            (address root,) = factory.deploy(salt, p, sp, data);
            key = IHookrPairRoot(root).poolKey();
        }
        _mint(key, sp, liq);
        _holder(warmer);
        _holder(trader);
        vm.roll(FORK_L1_BLOCK - 1);
        _permit(warmer, UNIVERSAL_ROUTER);
        _urSwap(warmer, key, true, 0.01 ether);
        _urSwap(warmer, key, false, 25e6);
        vm.roll(FORK_L1_BLOCK);
    }

    function _measure(string memory label, PoolKey memory key, bool zeroForOne, uint128 amountIn) internal {
        _permit(trader, UNIVERSAL_ROUTER);
        _urSwap(trader, key, zeroForOne, amountIn);
        console2.log(label, uint256(vm.lastCallGas().gasTotalUsed));
    }

    function _skip() internal returns (bool) {
        if (!live) vm.skip(true);
        return !live;
    }

    function test_fork_hookless_ethIn() public {
        if (_skip()) return;
        _measure("UR hookless ETH->USDG 0.01 ETH", _pool(0), true, 0.01 ether);
    }

    function test_fork_hookless_usdgIn() public {
        if (_skip()) return;
        _measure("UR hookless USDG->ETH 25 USDG", _pool(0), false, 25e6);
    }

    function test_fork_pairRoot_ethIn() public {
        if (_skip()) return;
        _measure("UR pairRoot ETH->USDG 0.01 ETH", _pool(1), true, 0.01 ether);
    }

    function test_fork_pairRoot_usdgIn() public {
        if (_skip()) return;
        _measure("UR pairRoot USDG->ETH 25 USDG", _pool(1), false, 25e6);
    }

    function test_fork_pairRootAdvised_ethIn() public {
        if (_skip()) return;
        _measure("UR pairRoot+advisory ETH->USDG 0.01 ETH", _pool(2), true, 0.01 ether);
    }

    function test_fork_pairRootAdvised_usdgIn() public {
        if (_skip()) return;
        _measure("UR pairRoot+advisory USDG->ETH 25 USDG", _pool(2), false, 25e6);
    }

    function test_fork_pairRootFee_ethIn() public {
        if (_skip()) return;
        _measure("UR pairRoot+fee ETH->USDG 0.01 ETH", _pool(3), true, 0.01 ether);
    }

    function test_fork_pairRootFee_usdgIn() public {
        if (_skip()) return;
        _measure("UR pairRoot+fee USDG->ETH 25 USDG", _pool(3), false, 25e6);
    }

    function test_fork_pairRootSession_ethIn() public {
        if (_skip()) return;
        _measure("UR pairRoot+session ETH->USDG 0.01 ETH", _pool(4), true, 0.01 ether);
        _logSession();
    }

    function test_fork_pairRootSession_usdgIn() public {
        if (_skip()) return;
        _measure("UR pairRoot+session USDG->ETH 25 USDG", _pool(4), false, 25e6);
        _logSession();
    }

    function _logSession() internal {
        HookrSessionAdvisory probe = new HookrSessionAdvisory(address(this), 30 minutes);
        HookrMarketCalendar.Session memory s = probe.sessionAt(vm.getBlockTimestamp());
        console2.log("  session tier (0 regular .. 4 closed)", uint256(s.tier));
    }

    function test_fork_fables_ethIn() public {
        if (_skip()) return;
        _holder(trader);
        _measure("UR Fables ETH->USDG 0.01 ETH", _fxKey(), true, 0.01 ether);
    }

    function test_fork_fables_usdgIn() public {
        if (_skip()) return;
        _holder(trader);
        _measure("UR Fables USDG->ETH 25 USDG", _fxKey(), false, 25e6);
    }
}
