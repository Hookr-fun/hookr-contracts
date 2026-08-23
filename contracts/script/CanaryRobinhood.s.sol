// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLaunchpadLib} from "../src/libraries/HookrLaunchpadLib.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrSwapRouter} from "../src/HookrSwapRouter.sol";
import {HookrToken} from "../src/HookrToken.sol";

/// @notice Production canary: consumes the fixed replay-safe instant-launch intent, opens a real
///         pool without a curve, then exercises all five hook blocks through the production router.
///         The later buy, approval, and sell are separate broadcasts: each receipt and readback
///         must be verified independently.
contract CanaryRobinhood is Script {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant EXPECTED_DEPLOYER = 0x5a52D4B820Ae7F02880d270562950918ACb14aA2;
    bytes32 constant PM_RUNTIME_CODEHASH = 0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    bytes32 constant CANARY_INTENT_ID = keccak256("hookr.v4.canary.instant.all-five.1");
    uint16 constant CANARY_POOL_SUPPLY_BPS = 5000;
    uint256 constant CANARY_DEPOSIT_WEI = 0.01 ether;
    uint256 constant CANARY_BUY_WEI = 0.001 ether;
    uint256 constant PIPS = 1_000_000;
    uint256 constant MAX_PROTOCOL_FEE_PIPS = 1000;
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function run() external {
        require(block.chainid == 4663, "wrong chain");
        require(address(PM).codehash == PM_RUNTIME_CODEHASH, "PoolManager runtime codehash wrong");
        HookrLaunchpad pad = HookrLaunchpad(payable(vm.envAddress("HOOKR_LAUNCHPAD_ADDRESS")));
        HookrHook hook = HookrHook(payable(vm.envAddress("HOOKR_HOOK_ADDRESS")));
        HookrSwapRouter router = HookrSwapRouter(vm.envAddress("HOOKR_SWAP_ROUTER_ADDRESS"));
        require(address(pad).code.length > 0 && address(hook).code.length > 0, "release code missing");
        require(address(router).code.length > 0, "router code missing");
        // Runtime bytecode is the release authority. Identity strings below are useful readbacks,
        // but arbitrary contracts can spoof them. Fail before loading a key unless all three
        // addresses match hashes copied from the reviewed deployment artifact.
        bytes32 expectedPadCodehash = vm.envBytes32("HOOKR_LAUNCHPAD_RUNTIME_CODEHASH");
        bytes32 expectedHookCodehash = vm.envBytes32("HOOKR_HOOK_RUNTIME_CODEHASH");
        bytes32 expectedRouterCodehash = vm.envBytes32("HOOKR_SWAP_ROUTER_RUNTIME_CODEHASH");
        require(
            expectedPadCodehash != bytes32(0) && expectedHookCodehash != bytes32(0)
                && expectedRouterCodehash != bytes32(0),
            "runtime codehash missing"
        );
        require(address(pad).codehash == expectedPadCodehash, "pad runtime codehash wrong");
        require(address(hook).codehash == expectedHookCodehash, "hook runtime codehash wrong");
        require(address(router).codehash == expectedRouterCodehash, "router runtime codehash wrong");
        // Fail before loading a key or broadcasting unless all env addresses identify the release.
        require(hook.REQUIRED_FLAGS() == HOOK_FLAGS, "release hook flags not deployed");
        require(keccak256(bytes(hook.contractName())) == keccak256(bytes("HookrHook")), "hook identity wrong");
        require(keccak256(bytes(pad.contractName())) == keccak256(bytes("HookrLaunchpad")), "pad identity wrong");
        require(keccak256(bytes(router.contractName())) == keccak256(bytes("HookrSwapRouter")), "router identity wrong");
        require(keccak256(bytes(hook.contractVersion())) == keccak256(bytes("1.0.0")), "hook version wrong");
        require(keccak256(bytes(pad.contractVersion())) == keccak256(bytes("1.0.0")), "pad version wrong");
        require(keccak256(bytes(router.contractVersion())) == keccak256(bytes("1.0.0")), "router version wrong");
        require(address(pad.hook()) == address(hook), "hook not wired");
        require(hook.launchpad() == address(pad), "hook launchpad wrong");
        require(address(pad.poolManager()) == address(PM), "pad PM wrong");
        require(address(hook.poolManager()) == address(PM), "hook PM wrong");
        require(address(router.poolManager()) == address(PM), "router PM wrong");
        require(address(router.hook()) == address(hook), "router hook wrong");
        require(uint160(address(hook)) & 0x3FFF == HOOK_FLAGS, "hook address flags wrong");
        uint256 buyMinRaw = vm.envUint("CANARY_BUY_MIN_TOKENS_OUT");
        uint256 sellMinRaw = vm.envUint("CANARY_SELL_MIN_WEI_OUT");
        require(buyMinRaw > 0 && buyMinRaw <= uint256(uint128(type(int128).max)), "buy bound invalid");
        require(sellMinRaw > 0 && sellMinRaw <= uint256(uint128(type(int128).max)), "sell bound invalid");
        uint128 buyMinTokensOut = uint128(buyMinRaw);
        uint128 sellMinWeiOut = uint128(sellMinRaw);
        address me = EXPECTED_DEPLOYER;
        uint256 creationFee = pad.creationFeeWei();
        require(pad.launchedByIntent(me, CANARY_INTENT_ID) == address(0), "canary intent already consumed");

        // The preview is the exact library plan the launch uses, not an estimate. Verify it before
        // loading a signer or collecting any transaction for broadcast.
        (
            uint256 previewPoolTokens,
            uint96 previewOpenPriceWei,
            uint160 previewSqrtPriceX96,
            uint256 previewOpenFdvWei,
            uint8 previewErr
        ) = pad.previewInstantLaunch(CANARY_DEPOSIT_WEI, CANARY_POOL_SUPPLY_BPS);
        require(previewErr == 0, "instant preview rejected");
        require(
            previewPoolTokens == (pad.SUPPLY() * CANARY_POOL_SUPPLY_BPS) / 10_000, "instant preview pool supply wrong"
        );
        require(previewOpenPriceWei == 20_000_000, "instant preview price wrong");
        require(previewSqrtPriceX96 > 0, "instant preview sqrt price missing");
        require(
            previewOpenFdvWei == (CANARY_DEPOSIT_WEI * 10_000) / CANARY_POOL_SUPPLY_BPS, "instant preview FDV wrong"
        );

        // Address-based broadcast keeps simulation secret-free. A live run must explicitly select
        // the reviewed Foundry account or hardware wallet for EXPECTED_DEPLOYER.
        vm.startBroadcast(me);

        // 1. Launch a custom all-five stack directly into its locked pool. blueprintId=0 is
        // required or `custom` is ignored. The two curve-only arguments are explicitly zero.
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Hookr Instant Five-Block Canary";
        a.symbol = "HICAN";
        a.tagline = "release proof: instant pool and all five Hookr blocks";
        a.logoURI = "";
        a.expectedCreator = me;
        a.targetRaiseWei = 0;
        a.blueprintId = 0;
        a.custom = HookrLaunchpadLib.HookParams({
            // Recovery budget for the separately-mined canary buy. Promotion still proves from
            // that buy's own PoolManager Swap log that it landed while the guard/surge fee was on.
            guardBlocks: 200,
            // On the instant path this is 10% of the actual pool float, which corresponds to
            // 10% of the opening ETH depth. The 0.01 deposit therefore admits the guarded 0.001
            // qualifying buy exactly at the cap while preserving a meaningful anti-snipe proof.
            maxBuyBps: 1000,
            snipeTaxPips: 200_000, // +20%
            baseFeePips: 3000,
            maxFeePips: 30_000,
            surgeSens: 5,
            burnBps: 100,
            burnTriggerWei: 0,
            lpBps: 25,
            potBps: 50,
            potEveryNBuys: 10,
            potMinBuyWei: 0.001 ether, // protocol floor: MIN_POT_BUY_WEI
            buybackBps: 0,
            buybackDrawdownBps: 0,
            buybackCooldownBlocks: 0,
            buybackMinSpendWei: 0,
            buybackMaxSpendWei: 0
        });
        a.creatorBuyWei = CANARY_DEPOSIT_WEI;
        a.minTokensOut = 0;
        // Intent consumption + token creation + pool initialization + locked liquidity are one
        // transaction. If any step fails, the intent marker, token, and payment revert together.
        address token =
            pad.launchInstant{value: creationFee + CANARY_DEPOSIT_WEI}(a, CANARY_POOL_SUPPLY_BPS, CANARY_INTENT_ID);

        // 2. Buy through the bounded production router during the guard window.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        uint256 deadBefore = HookrToken(token).balanceOf(DEAD);
        router.exactInput{value: CANARY_BUY_WEI}(
            HookrSwapRouter.ExactInputParams({
                key: key,
                zeroForOne: true,
                amountIn: uint128(CANARY_BUY_WEI),
                amountOutMinimum: buyMinTokensOut,
                sqrtPriceLimitX96: hook.MIN_SQRT_PRICE_LIMIT(),
                recipient: me,
                deadline: block.timestamp + 10 minutes
            })
        );

        // 3. Approve, then sell a slice through the same bounded router (sells are guard-free).
        // These are distinct mined transactions from launch and the router buy. A later failure
        // cannot roll back an earlier successful receipt.
        uint256 tokenBal = HookrToken(token).balanceOf(me);
        HookrToken(token).approve(address(router), tokenBal / 100);
        router.exactInput(
            HookrSwapRouter.ExactInputParams({
                key: key,
                zeroForOne: false,
                amountIn: uint128(tokenBal / 100),
                amountOutMinimum: sellMinWeiOut,
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341,
                recipient: me,
                deadline: block.timestamp + 10 minutes
            })
        );

        vm.stopBroadcast();

        // Replay protection is a simulation-only fifth call. Keeping it outside startBroadcast is
        // load-bearing: the live canary artifact must contain exactly launch/buy/approve/sell, and
        // an intentionally reverting replay must never be signed or submitted.
        bytes memory replayCall =
            abi.encodeCall(HookrLaunchpad.launchInstant, (a, CANARY_POOL_SUPPLY_BPS, CANARY_INTENT_ID));
        vm.prank(me);
        (bool replayOk, bytes memory replayResult) =
            address(pad).call{value: creationFee + CANARY_DEPOSIT_WEI}(replayCall);
        require(!replayOk, "instant replay unexpectedly accepted");
        require(
            keccak256(replayResult)
                == keccak256(
                    abi.encodeWithSelector(HookrLaunchpad.LaunchIntentAlreadyUsed.selector, me, CANARY_INTENT_ID, token)
                ),
            "instant replay rejection wrong"
        );

        // ------------------------------------------------------- simulation postconditions
        // These assertions protect the complete Forge simulation. After `--broadcast`, verify
        // every individual receipt and repeat the corresponding onchain readback; assertions here
        // cannot undo an earlier transaction that has already been mined.
        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        require(l.graduated, "instant launch not live");
        require(l.graduatedAtBlock == l.launchBlock, "instant pool not opened in launch block");
        require(l.soldTokens == 0 && l.reserveWei == 0, "instant launch touched curve state");
        require(l.targetWei == CANARY_DEPOSIT_WEI, "instant deposit record wrong");
        require(l.basePriceWei == previewOpenPriceWei, "instant opening price wrong");
        require(l.sqrtPriceX96AtGraduation == previewSqrtPriceX96, "instant sqrt price wrong");
        address intentToken = pad.launchedByIntent(me, CANARY_INTENT_ID);
        require(intentToken == token, "launch intent postcondition wrong");
        PoolId id = key.toId();
        require(PoolId.unwrap(l.poolId) == PoolId.unwrap(id), "instant pool record wrong");
        (uint160 sqrtPriceX96,, uint24 packedProtocolFee, uint24 lpFee) = PM.getSlot0(id);
        // The buy/sell round trip has intentionally moved spot since opening. The immutable
        // opening value is the launch record checked above; current slot0 only proves the same
        // pool remains initialized and live after both guarded routes.
        require(sqrtPriceX96 > 0, "instant pool not initialized");
        require(lpFee == 3000, "base fee not synced");
        require(PM.getLiquidity(id) > 0, "no POL liquidity");
        require(HookrToken(token).balanceOf(address(PM)) > 0, "pool received no canary supply");
        require(hook.totalHookFeesWei(id) > 0, "no hook fees");
        require(HookrToken(token).balanceOf(me) > 0, "no tokens held");
        require(HookrToken(token).balanceOf(DEAD) > deadBefore, "auto burn inactive");
        require(hook.totalBurnedTokens(id) > 0, "burn aggregate empty");
        require(hook.burnVaultWei(id) == 0, "legacy burn vault nonzero");
        require(hook.totalLpDonatedWei(id) > 0, "no lp donation");
        // A later permissionless qualifying buy can advance the pool counter and the Nth one can
        // legitimately pay the pot before post-broadcast reads. Promotion binds the canary's own
        // HookFeesAccrued event; mutable aggregate state is only a monotonic/backing check.
        require(hook.potBuyCount(id) >= 1, "pot count below canary buy");
        // nativeClaimBalance is hook-global while potWei is pool-scoped. Other permissionless
        // pools may add valid native claims, while a canary-pool jackpot may reduce potWei to zero;
        // only under-backing of the current pool-scoped pot is invalid.
        require(hook.nativeClaimBalance() >= hook.potWei(id), "native claims do not back pot");
        require(address(hook).balance == 0, "hook custodies physical ETH");
        require(address(router).balance == 0, "router retained ETH");
        require(HookrToken(token).balanceOf(address(router)) == 0, "router retained tokens");

        (
            ,
            uint40 guardEnd,
            uint24 baseFee,
            uint24 maxFee,
            uint24 snipeTax,
            uint16 surgeSens,
            uint16 burnBps,
            uint16 lpBps,
            uint16 potBps,,,
            uint96 maxBuyWei,
            uint96 potMinBuyWei,
            uint96 burnTrigger,,,,,,, // buyback block + royaltyTo + token
        ) = hook.poolConfig(id);
        require(guardEnd > l.graduatedAtBlock, "guard inactive");
        require(maxBuyWei >= CANARY_BUY_WEI, "guard cap did not admit canary buy");
        require(snipeTax == 200_000, "snipe tax inactive");
        require(maxFee > baseFee && surgeSens == 5, "surge inactive");
        require(burnBps == 100 && lpBps == 25 && potBps == 50, "custom blocks ignored");
        require(potMinBuyWei == CANARY_BUY_WEI, "pot minimum wrong");
        require(burnTrigger == 0, "legacy trigger nonzero");

        // `guardLpEarnedWei` includes base + snipe + surge LP fee and the LP donation. Prove the
        // actual guarded buy earned more than the same transaction would without the surge
        // component, rather than accepting a merely configured but inert surge block.
        uint256 hookFeeWei = (CANARY_BUY_WEI * (uint256(lpBps) + potBps)) / 10_000;
        uint256 swapInWei = CANARY_BUY_WEI - hookFeeWei;
        uint256 protocolFeePips = uint256(packedProtocolFee & 0x0FFF); // zeroForOne / native -> token
        require(protocolFeePips <= MAX_PROTOCOL_FEE_PIPS, "PoolManager protocol fee invalid");
        uint256 expectedLpDonationWei = (hookFeeWei * lpBps) / (uint256(lpBps) + potBps);
        uint256 noSurgeGuardEarnings =
            _lpFeeAfterProtocol(swapInWei, uint256(baseFee) + snipeTax, protocolFeePips) + expectedLpDonationWei;
        require(hook.guardLpEarnedWei(id) > noSurgeGuardEarnings, "surge did not charge guarded buy");

        console2.log("CANARY OK");
        console2.log("token   ", token);
        console2.log("intentToken", intentToken);
        console2.log("intentId:");
        console2.logBytes32(CANARY_INTENT_ID);
        console2.log("poolSupplyBps", CANARY_POOL_SUPPLY_BPS);
        console2.log("depositWei", CANARY_DEPOSIT_WEI);
        console2.log("openPriceWei", previewOpenPriceWei);
        console2.log("openFdvWei", previewOpenFdvWei);
        console2.log("router  ", address(router));
        console2.log("poolId:");
        console2.logBytes32(PoolId.unwrap(id));
        console2.log("sqrtP   ", sqrtPriceX96);
        console2.log("liq     ", PM.getLiquidity(id));
        console2.log("burned    ", hook.totalBurnedTokens(id));
        console2.log("lpDonated", hook.totalLpDonatedWei(id));
        console2.log("pot      ", hook.potWei(id));
        console2.log("potBuys  ", hook.potBuyCount(id));
        console2.log("nativeClaims", hook.nativeClaimBalance());
    }

    /// @dev Mirrors Pool.sol's combined-fee and protocol-allocation arithmetic for the aggregate
    ///      exact-input canary. If lpFeePips is zero, Pool.sol assigns the entire combined fee to
    ///      the protocol; returning zero here preserves that special case.
    function _lpFeeAfterProtocol(uint256 grossInputWei, uint256 lpFeePips, uint256 protocolFeePips)
        internal
        pure
        returns (uint256)
    {
        if (lpFeePips == 0 || grossInputWei == 0) return 0;
        if (protocolFeePips == 0) return (grossInputWei * lpFeePips + PIPS - 1) / PIPS;
        uint256 combinedFeePips = protocolFeePips + lpFeePips - (protocolFeePips * lpFeePips) / PIPS;
        uint256 totalFeeWei = (grossInputWei * combinedFeePips + PIPS - 1) / PIPS;
        if (combinedFeePips == protocolFeePips) return 0;
        uint256 protocolFeeWei = (grossInputWei * protocolFeePips) / PIPS;
        return totalFeeWei - protocolFeeWei;
    }
}
