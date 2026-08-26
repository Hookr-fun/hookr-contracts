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
}

/// @notice The operator's real launch scenario: 1B supply, pool seeded with 10 ETH + 300M tokens.
///         Measures what leverage a trader can ACTUALLY get at that depth, and how the built-in
///         depth term already scales the aggregate ceiling as the pool grows.
contract LeverageLaunchScenario is Test {
    // 10 ETH : 300M tokens  ->  price 3e7 token/ETH
    uint160 constant SQRT_PRICE = 433950517987477978532631585751040;
    uint128 constant SEED_L = 54772255750516618821632;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint160 constant MIN_LIMIT = 4295128739 + 1;
    uint256 constant WAD = 1e18;

    IPoolManager manager;
    LeverageHook hook;
    LeverageFactory factory;
    LeverageRouter router;
    LeverageMarket market;
    IERC20X token;
    PoolKey key;
    PoolId id;

    address lp = address(0xA1);
    address arb = address(0xA4);

    receive() external payable {}

    function _cfg(uint16 ltvBps, uint128 floorWei, uint128 capWei)
        internal
        pure
        returns (ILeverage.MarketConfig memory)
    {
        return ILeverage.MarketConfig({
            ltvBps: ltvBps,
            liqThresholdBps: ltvBps + 2000,
            liqBonusBps: 500,
            reserveFactorBps: 2000,
            kinkWad: uint64((WAD * 7) / 10),
            maxUtilisationWad: uint64((WAD * 75) / 100),
            protocolCapWei: capWei,
            minPoolQuoteWei: floorWei
        });
    }

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
        vm.deal(arb, 5_000_000 ether);
    }

    function _launch(uint16 ltvBps, uint128 floorWei, uint128 capWei) internal {
        (address t, address m) = factory.createMarket{value: 10 ether}(
            "Launch", "LNCH", "", "", SUPPLY, SQRT_PRICE, SEED_L, _cfg(ltvBps, floorWei, capWei)
        );
        token = IERC20X(t);
        market = LeverageMarket(payable(m));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(t), 0x800000, 60, IHooks(address(hook)));
        id = key.toId();
    }

    function _buy(address who, uint256 amt) internal {
        vm.prank(who);
        router.swap{value: amt}(LeverageRouter.SwapArgs(key, true, -int256(amt), MIN_LIMIT, 0, who, type(uint256).max));
        vm.deal(who, 5_000_000 ether);
    }

    function _warm() internal {
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 26; i++) {
            t += 46;
            vm.warp(t);
            _buy(arb, 0.01 ether);
        }
    }

    function _maxLev(uint256 equity) internal returns (uint256 bestX100) {
        for (uint256 x = 105; x <= 300; x += 5) {
            uint256 snap = vm.snapshotState();
            address tr = address(uint160(uint256(0xE000) + x));
            vm.deal(tr, 100_000 ether);
            vm.prank(tr);
            (bool ok,) = address(market).call{value: equity}(
                abi.encodeWithSignature("openPosition(uint256,uint256)", (x * WAD) / 100, uint256(0))
            );
            vm.revertToState(snap);
            if (ok) bestX100 = x;
            else if (bestX100 != 0) break;
        }
    }

    function test_launchBreakdown() public {
        _launch(4000, 0, 1_000 ether); // ltv 4000 (ideal 1.66x), no floor, high cap: isolate depth
        _warm();

        (uint256 poolQuote, uint256 poolTok) = market.positionReserves();
        console2.log("=== POOL AT LAUNCH ===");
        console2.log("  quote side (ETH wei) ", poolQuote);
        console2.log("  token side           ", poolTok / 1e18);
        console2.log("  total supply (tokens)", SUPPLY / 1e18);
        console2.log("  pct of supply in pool", (poolTok * 100) / SUPPLY);

        // LPs must fund the credit side; the pool seed mints no shares.
        vm.prank(lp);
        market.deposit{value: 20 ether}();
        console2.log("=== AFTER 20 ETH LP DEPOSIT ===");
        console2.log("  idleQuote (lendable) ", market.idleQuote());
        console2.log("  creditCapacity       ", market.creditCapacity());
        console2.log("  availableCredit      ", market.availableCredit());
        console2.log("  (depthTerm = poolQuote/2 =", poolQuote / 2, ")");

        console2.log("=== MAX LEVERAGE A TRADER ACTUALLY GETS (ltvBps 4000, ideal 1.66x) ===");
        uint256[4] memory eq = [uint256(0.05 ether), 0.1 ether, 0.5 ether, 1 ether];
        for (uint256 i = 0; i < eq.length; i++) {
            console2.log("  equity(wei)", eq[i], "-> max x100:", _maxLev(eq[i]));
        }
    }

    /// What ltvBps do you need for a user to ACTUALLY reach 2.00x, in the real 10-ETH launch pool?
    function test_whatLtvGivesATrueTwoX() public {
        uint16[4] memory ltvs = [uint16(5000), 5500, 6000, 6500];
        for (uint256 i = 0; i < ltvs.length; i++) {
            uint256 snap = vm.snapshotState();
            uint16 ltv = ltvs[i];
            _launch(ltv, 0, 1_000 ether);
            _warm();
            vm.prank(lp);
            market.deposit{value: 20 ether}();
            uint256 ideal = (10_000 * 100) / (10_000 - ltv); // x100
            console2.log("ltvBps", ltv);
            console2.log("   ideal x100      :", ideal);
            console2.log("   0.1 ETH equity  :", _maxLev(0.1 ether));
            console2.log("   0.5 ETH equity  :", _maxLev(0.5 ether));
            console2.log("   1.0 ETH equity  :", _maxLev(1 ether));
            vm.revertToState(snap);
        }
    }

    /// At a chosen leverage, what does the trader actually END UP holding? Exposure vs equity.
    function test_exposureBreakdownAtTwoX() public {
        _launch(6000, 0, 1_000 ether); // ideal 2.5x so 2.00x is comfortably reachable
        _warm();
        vm.prank(lp);
        market.deposit{value: 20 ether}();

        address tr = address(0xD00D);
        vm.deal(tr, 1_000 ether);
        uint256 equity = 0.5 ether;
        vm.prank(tr);
        market.openPosition{value: equity}(2 * WAD, 0);

        (uint128 coll,) = market.positions(tr);
        uint256 debt = market.debtOf(tr);
        console2.log("=== 0.5 ETH equity at 2.00x, ltvBps 6000 ===");
        console2.log("  equity posted (wei)   ", equity);
        console2.log("  borrowed (wei)        ", debt);
        console2.log("  collateral (tokens)   ", uint256(coll) / 1e18);
        console2.log("  health                ", market.healthFactorOf(tr));
        console2.log("  liquidation health    ", market.liquidationHealthOf(tr));
    }

    /// The one depth tier that IS enforceable on the deployed contracts today.
    function test_minPoolQuoteFloorGivesTheNoLeverageTier() public {
        _launch(4000, 15 ether, 1_000 ether); // floor 15 ETH on a 10 ETH pool -> shut
        _warm();
        vm.prank(lp);
        market.deposit{value: 20 ether}();

        address tr = address(0xD00D);
        vm.deal(tr, 1_000 ether);
        (uint256 depth,) = market.positionReserves();
        console2.log("pool depth", depth, "floor 15 ETH -> opens refused?");
        vm.prank(tr);
        (bool ok,) = address(market).call{value: 0.1 ether}(
            abi.encodeWithSignature("openPosition(uint256,uint256)", (WAD * 13) / 10, uint256(0))
        );
        console2.log("  open succeeded?", ok ? 1 : 0);

        // Grow the pool past the floor with real buying, then it opens.
        for (uint256 i = 0; i < 10; i++) {
            _buy(arb, 2 ether);
        }
        _warm();
        (uint256 depth2,) = market.positionReserves();
        console2.log("after buying, depth", depth2);
        vm.prank(tr);
        (bool ok2,) = address(market).call{value: 0.1 ether}(
            abi.encodeWithSignature("openPosition(uint256,uint256)", (WAD * 13) / 10, uint256(0))
        );
        console2.log("  open succeeded now?", ok2 ? 1 : 0);
    }
}
