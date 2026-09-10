// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {HookrLaunchpadLib} from "../src/libraries/HookrLaunchpadLib.sol";
import {V4PoolMath} from "../src/libraries/V4PoolMath.sol";

/// @notice Cheap, high-run arithmetic properties for the instant-launch preview. The end-to-end
///         fuzz test deliberately runs fewer cases because each accepted input deploys a token and
///         opens a v4 pool; this suite exercises the shared launch/preview plan without that cost.
contract InstantPlanPropertiesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant MIN_ETH_IN = 0.0001 ether;
    uint256 internal constant MAX_ETH_IN = 1000 ether;
    uint16 internal constant MIN_POOL_SUPPLY_BPS = 2000;
    uint16 internal constant BPS = 10_000;
    uint96 internal constant MIN_OPEN_PRICE_WEI = 1e6;
    int24 internal constant TICK_SPACING = 60;

    /// forge-config: default.fuzz.runs = 20000
    function testFuzz_acceptedPlanExactlyBacksPriceAndStaysInsideFullRange(uint256 rawEth, uint16 rawShare)
        public
        pure
    {
        uint256 ethIn = bound(rawEth, MIN_ETH_IN, MAX_ETH_IN);
        uint16 poolSupplyBps = uint16(bound(uint256(rawShare), MIN_POOL_SUPPLY_BPS, BPS));

        (uint256 tokensInPool, uint96 openPriceWei, uint160 sqrtPriceX96, uint256 openFdvWei, uint8 err) =
            HookrLaunchpadLib.instantPlan(ethIn, poolSupplyBps, SUPPLY, TICK_SPACING);

        uint256 expectedTokens = (SUPPLY * poolSupplyBps) / BPS;
        assertEq(tokensInPool, expectedTokens, "pool float drifted");

        uint256 numerator = ethIn * 1e18;
        uint256 expectedPrice = (numerator - 1) / expectedTokens + 1;
        if (expectedPrice < MIN_OPEN_PRICE_WEI || expectedPrice > type(uint96).max) {
            assertEq(err, 3, "bad price accepted or misclassified");
            assertEq(openPriceWei, 0, "rejected price was exposed as usable");
            return;
        }

        assertEq(err, 0, "legal representable plan rejected");
        assertEq(uint256(openPriceWei), expectedPrice, "price is not the ceiling ratio");
        assertGe(uint256(openPriceWei) * tokensInPool, numerator, "price is not fully ETH-backed");
        assertLt((uint256(openPriceWei) - 1) * tokensInPool, numerator, "price rounded by more than one wei");
        assertEq(openFdvWei, (SUPPLY * uint256(openPriceWei)) / 1e18, "FDV does not use quoted price");

        uint256 idealFdvFloor = (ethIn * BPS) / poolSupplyBps;
        assertGe(openFdvWei, idealFdvFloor, "rounding opened below the selected valuation");
        assertLe(openFdvWei, idealFdvFloor + (SUPPLY / 1e18), "rounding error exceeds one price quantum");

        (int24 tickLower, int24 tickUpper) = V4PoolMath.usableTickRange(TICK_SPACING);
        assertGt(sqrtPriceX96, V4PoolMath.getSqrtPriceAtTick(tickLower), "price is below the usable range");
        assertLt(sqrtPriceX96, V4PoolMath.getSqrtPriceAtTick(tickUpper), "price is above the usable range");
    }

    function test_planRejectsEachBoundaryBeforeReturningAUsablePrice() public pure {
        (,,, uint256 lowEthFdv, uint8 lowEthErr) =
            HookrLaunchpadLib.instantPlan(MIN_ETH_IN - 1, 5000, SUPPLY, TICK_SPACING);
        (,,, uint256 highEthFdv, uint8 highEthErr) =
            HookrLaunchpadLib.instantPlan(MAX_ETH_IN + 1, 5000, SUPPLY, TICK_SPACING);
        (,,, uint256 lowShareFdv, uint8 lowShareErr) =
            HookrLaunchpadLib.instantPlan(1 ether, MIN_POOL_SUPPLY_BPS - 1, SUPPLY, TICK_SPACING);
        (,,, uint256 highShareFdv, uint8 highShareErr) =
            HookrLaunchpadLib.instantPlan(1 ether, BPS + 1, SUPPLY, TICK_SPACING);

        assertEq(lowEthErr, 1);
        assertEq(highEthErr, 1);
        assertEq(lowShareErr, 2);
        assertEq(highShareErr, 2);
        assertEq(lowEthFdv, 0);
        assertEq(highEthFdv, 0);
        assertEq(lowShareFdv, 0);
        assertEq(highShareFdv, 0);
    }
}
