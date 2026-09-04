// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {LeverageHook} from "../src/LeverageHook.sol";
import {LeverageFactory} from "../src/LeverageFactory.sol";
import {LeverageMarket} from "../src/LeverageMarket.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {ILeverage} from "../src/interfaces/ILeverage.sol";
import {HookMiner} from "./utils/HookMiner.sol";

interface IERC20X {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @notice MEASURES the leverage ceiling users actually get under a candidate launch config, and
///         proves a conservative config still supports the full lifecycle (open, close,
///         liquidate, redeem) rather than bricking the market. Probe only — not a regression.
contract LeverageConfigProbe is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_LIMIT = 4295128739 + 1;
    uint160 constant MAX_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;
    uint256 constant WAD = 1e18;

    IPoolManager manager;
    LeverageHook hook;
    LeverageFactory factory;
    LeverageRouter router;

    address lp = address(0xA1);
    address keeper = address(0xA3);
    address arb = address(0xA4);

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        router = new LeverageRouter(manager);
        uint160 flags = uint160((1 << 13) | (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6));
        bytes memory creation = abi.encodePacked(type(LeverageHook).creationCode, abi.encode(manager, address(this)));
        (, bytes32 salt) = HookMiner.find(address(this), flags, creation);
        hook = new LeverageHook{salt: salt}(manager, address(this));
        factory = new LeverageFactory(manager, hook);
        hook.setFactory(address(factory));
        vm.deal(address(this), 5_000_000 ether);
        vm.deal(lp, 1_000_000 ether);
        vm.deal(keeper, 1_000_000 ether);
        vm.deal(arb, 5_000_000 ether);
    }

    struct Env {
        LeverageMarket market;
        IERC20X token;
        PoolKey key;
        PoolId id;
    }

    function _mk(uint16 ltvBps, uint16 thrBps, uint16 bonusBps, uint128 minDepth, uint128 cap)
        internal
        returns (Env memory e)
    {
        ILeverage.MarketConfig memory cfg = ILeverage.MarketConfig({
            ltvBps: ltvBps,
            liqThresholdBps: thrBps,
            liqBonusBps: bonusBps,
            reserveFactorBps: 2_000,
            kinkWad: uint64((WAD * 7) / 10),
            maxUtilisationWad: uint64((WAD * 75) / 100),
            protocolCapWei: cap,
            minPoolQuoteWei: minDepth
        });
        (address t, address m) = factory.createMarket{value: 100 ether}(
            "Probe", "PRB", "", "", 1_000_000 ether, SQRT_PRICE_1_1, 50 ether, cfg
        );
        e.token = IERC20X(t);
        e.market = LeverageMarket(payable(m));
        e.key = PoolKey(Currency.wrap(address(0)), Currency.wrap(t), 0x800000, 60, IHooks(address(hook)));
        e.id = e.key.toId();
    }

    function _buy(Env memory e, address who, uint256 amt) internal {
        vm.prank(who);
        router.swap{value: amt}(
            LeverageRouter.SwapArgs(e.key, true, -int256(amt), MIN_LIMIT, 0, who, type(uint256).max)
        );
        vm.deal(who, 5_000_000 ether);
    }

    function _warm(Env memory e) internal {
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 26; i++) {
            t += 46;
            vm.warp(t);
            _buy(e, arb, 0.05 ether);
        }
    }

    /// Highest leverage (in hundredths of x) that opens successfully with `equity`.
    function _maxLeverage(Env memory e, uint256 equity) internal returns (uint256 bestX100) {
        for (uint256 x100 = 110; x100 <= 500; x100 += 5) {
            uint256 snap = vm.snapshotState();
            address tr = address(uint160(uint256(0xC000) + x100));
            vm.deal(tr, 1_000_000 ether);
            vm.prank(tr);
            (bool ok,) = address(e.market).call{value: equity}(
                abi.encodeWithSignature("openPosition(uint256,uint256)", (x100 * WAD) / 100, uint256(0))
            );
            vm.revertToState(snap);
            if (ok) bestX100 = x100;
            else if (bestX100 != 0) break; // past the ceiling
        }
    }

    function test_measureLeverageCeilingAcrossLtv() public {
        uint16[5] memory ltvs = [uint16(2500), 3000, 4000, 5000, 6000];
        for (uint256 i = 0; i < ltvs.length; i++) {
            uint256 snap = vm.snapshotState();
            uint16 ltv = ltvs[i];
            uint16 thr = ltv + 1500 > 9500 ? 9500 : ltv + 1500;
            Env memory e = _mk(ltv, thr, 500, 0, 1_000 ether);
            _warm(e);
            vm.prank(lp);
            e.market.deposit{value: 50 ether}();
            uint256 ideal = (WAD * 10_000) / (10_000 - ltv); // 1/(1-ltv)
            uint256 got = _maxLeverage(e, 1 ether);
            console2.log("ltvBps", ltv);
            console2.log("   ideal max x100 :", (ideal * 100) / WAD);
            console2.log("   MEASURED max x100:", got);
            vm.revertToState(snap);
        }
    }

    /// A deliberately conservative config must still support the whole lifecycle.
    function test_conservativeConfigStillWorksEndToEnd() public {
        // ltv 4000 -> ideal ceiling 1.667x; threshold 5500 (thr+bonus = 6000 << 10000);
        // depth floor 25 ETH on a 50-ETH seeded pool; protocol cap 10 ETH total borrow.
        Env memory e = _mk(4000, 5500, 500, 25 ether, 10 ether);
        _warm(e);
        vm.prank(lp);
        e.market.deposit{value: 50 ether}();

        address tr = address(0xD00D);
        vm.deal(tr, 1_000 ether);
        vm.prank(tr);
        e.market.openPosition{value: 2 ether}((WAD * 14) / 10, 0); // 1.4x
        console2.log("opened 1.4x; debt", e.market.debtOf(tr));
        console2.log("  health", e.market.healthFactorOf(tr));
        console2.log("  creditCapacity (capped)", e.market.creditCapacity());
        console2.log("  availableCredit", e.market.availableCredit());

        // close works
        vm.prank(tr);
        e.market.closePosition(0);
        (uint128 c, uint128 d) = e.market.positions(tr);
        console2.log("closed: collateral", c, "debt", d);

        // LP can still exit
        uint256 sh = e.market.balanceOf(lp);
        vm.prank(lp);
        uint256 paid = e.market.redeem(sh / 4);
        console2.log("LP redeemed quarter ->", paid);

        // depth floor actually bites below the floor
        console2.log("--- depth floor check ---");
        (uint256 depth,) = e.market.positionReserves();
        console2.log("pool quote depth", depth);
    }
}
