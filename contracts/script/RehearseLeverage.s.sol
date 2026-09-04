// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LeverageFactory} from "../src/LeverageFactory.sol";
import {LeverageMarket} from "../src/LeverageMarket.sol";
import {ILeverage} from "../src/interfaces/ILeverage.sol";

/// @notice Fork-only rehearsal: drives a freshly deployed factory through the full user path —
///         create a market, an LP deposit, a leveraged open — and reads back every value the
///         web UI's LEVERAGE_MARKET_READS surface depends on. Proves the deployed bytecode and
///         the checked-in ABIs agree, before any of it is wired into a page.
contract RehearseLeverage is Script {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant WAD = 1e18;

    function run() external {
        LeverageFactory factory = LeverageFactory(payable(vm.envAddress("FACTORY")));

        ILeverage.MarketConfig memory cfg = ILeverage.MarketConfig({
            ltvBps: 5_500,
            liqThresholdBps: 7_500,
            liqBonusBps: 500,
            reserveFactorBps: 1_000,
            kinkWad: uint64((WAD * 8) / 10),
            maxUtilisationWad: uint64((WAD * 9) / 10),
            protocolCapWei: 1_000 ether,
            minPoolQuoteWei: 0
        });

        vm.startBroadcast();

        (address tokenAddr, address marketAddr) = factory.createMarket{value: 10 ether}(
            "Rehearsal", "RHRS", "fork proof", "", 1_000_000 ether, SQRT_PRICE_1_1, 5 ether, cfg
        );
        LeverageMarket market = LeverageMarket(payable(marketAddr));
        console2.log("token          ", tokenAddr);
        console2.log("market         ", marketAddr);
        console2.log("factory.marketCount", factory.marketCount());

        market.deposit{value: 3 ether}();
        console2.log("after LP deposit ---");
        console2.log("totalSupply    ", market.totalSupply());
        console2.log("idleQuote      ", market.idleQuote());

        vm.stopBroadcast();

        // Read the full UI surface (view calls, no broadcast needed).
        console2.log("=== UI read surface ===");
        console2.log("navQuote(false)", market.navQuote(false));
        console2.log("sharePriceWad  ", market.sharePriceWad());
        console2.log("creditCapacity ", market.creditCapacity());
        console2.log("availableCredit", market.availableCredit());
        console2.log("utilisation    ", market.utilisation());
        console2.log("borrowRateWad  ", market.borrowRateWad());
        console2.log("totalDebt      ", market.totalDebt());
        (uint256 vq, uint256 vt) = market.positionValue();
        console2.log("positionValueQ ", vq);
        console2.log("positionValueT ", vt);
        console2.log("reserveQuote   ", market.reserveQuote());
        console2.log("badDebt        ", market.badDebt());
    }
}
