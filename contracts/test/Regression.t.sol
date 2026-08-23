// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {HookrBlueprints} from "../src/HookrBlueprints.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLaunchpadLib} from "../src/libraries/HookrLaunchpadLib.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Regression suite for the audit findings that only reproduce against a real
///         PoolManager: the maxFee==0 graduation brick (#1), the deterministic-pot farming
///         boundary (#2), the snipe tax charged on sells (#3), the snipable LP-rewards vault (#4),
///         stranded burn ETH (#5), and the permissionless buyback market order (#6).
///
///         Every test here fails against the pre-fix contracts and passes against the fixed ones.
contract RegressionTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint160 constant MIN_LIMIT = 4295128739 + 1;
    uint160 constant MAX_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint96 constant TARGET = 0.01 ether;

    HookrLaunchpad pad;

    HookrBlueprints bpReg;
    HookrHook hook;
    PoolSwapTest router;
    PoolModifyLiquidityTest lpRouter;
    uint256 public selectedForkBlock;

    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBADBAD);

    function setUp() public {
        uint256 requestedForkBlock = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (requestedForkBlock == 0) {
            vm.createSelectFork("robinhood");
        } else {
            vm.createSelectFork("robinhood", requestedForkBlock);
        }
        selectedForkBlock = vm.getBlockNumber();
        emit log_named_uint("Robinhood fork block", selectedForkBlock);
        assertEq(block.chainid, 4663);
        if (requestedForkBlock != 0) assertEq(selectedForkBlock, requestedForkBlock);

        pad = new HookrLaunchpad(PM, new HookrBlueprints(address(this)));
        bpReg = pad.blueprints();
        bytes memory creation = abi.encodePacked(type(HookrHook).creationCode, abi.encode(PM, address(pad)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(PM, address(pad));
        assertEq(address(hook), predicted, "mined address must match");
        pad.setHook(hook);

        router = new PoolSwapTest(PM);
        lpRouter = new PoolModifyLiquidityTest(PM);
        assertEq(vm.getBlockNumber(), selectedForkBlock, "local deployments changed fork block");

        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(attacker, 100 ether);
    }

    // ------------------------------------------------------------ helpers

    function _baseParams() internal pure returns (HookrLaunchpadLib.HookParams memory p) {
        p = HookrLaunchpadLib.HookParams({
            guardBlocks: 0,
            maxBuyBps: 0,
            snipeTaxPips: 0,
            baseFeePips: 3000,
            maxFeePips: 0,
            surgeSens: 0,
            burnBps: 0,
            burnTriggerWei: 0,
            lpBps: 0,
            potBps: 0,
            potEveryNBuys: 0,
            potMinBuyWei: 0,
            buybackBps: 0,
            buybackDrawdownBps: 0,
            buybackCooldownBlocks: 0,
            buybackMinSpendWei: 0,
            buybackMaxSpendWei: 0
        });
    }

    function _launchAndGraduate(HookrLaunchpadLib.HookParams memory p, string memory symbol, uint96 target)
        internal
        returns (address token, PoolKey memory key)
    {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Regression Fish";
        a.symbol = symbol;
        a.tagline = "";
        a.logoURI = "";
        a.expectedCreator = creator;
        a.targetRaiseWei = target;
        a.blueprintId = 0;
        a.custom = p;

        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        token = pad.launch{value: fee}(a, bytes32(0));

        // Buy out the whole curve with headroom; the excess is refunded.
        uint256 buyout = (uint256(target) * 12) / 10 + 0.001 ether;
        vm.deal(alice, buyout + 10 ether);
        vm.prank(alice);
        pad.buy{value: buyout}(token, 0);
        assertTrue(pad.getLaunch(token).graduated, "curve sellout must graduate");

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _buy(address who, PoolKey memory key, uint256 ethIn, bytes memory hookData)
        internal
        returns (BalanceDelta delta)
    {
        vm.prank(who);
        delta = router.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: MIN_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _sell(address who, PoolKey memory key, uint256 tokensIn) internal returns (BalanceDelta delta) {
        vm.startPrank(who);
        HookrToken(Currency.unwrap(key.currency1)).approve(address(router), tokensIn);
        delta = router.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(tokensIn), sqrtPriceLimitX96: MAX_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    // ============================================================ #1 maxFeePips == 0

    /// @dev Pre-fix: the launchpad accepted maxFeePips == 0 but the hook rejected it, so the
    ///      launch sold out its entire curve and then reverted forever at graduation, stranding
    ///      the raise. Post-fix the launchpad normalizes the ceiling to baseFeePips.
    function test_fix1_maxFeeZero_graduatesAndPoolChargesBaseFee() public {
        HookrLaunchpadLib.HookParams memory p = _baseParams();
        p.baseFeePips = 3000;
        p.maxFeePips = 0; // "no surge block stacked" — exactly what the UI emits

        (address token, PoolKey memory key) = _launchAndGraduate(p, "MAXZ", TARGET);

        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        assertTrue(l.graduated, "graduation must not brick on maxFeePips == 0");
        assertEq(l.reserveWei, 0, "raise must not be stranded on the curve");

        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,, uint24 lpFee) = PM.getSlot0(id);
        assertGt(sqrtPriceX96, 0, "pool live");
        assertEq(lpFee, 3000, "pool fee == baseFeePips");
        assertGt(PM.getLiquidity(id), 0, "POL seeded");

        // And the pool actually trades at the base fee with no surge headroom.
        // PoolConfig: initialized, guardEndBlock, baseFeePips, maxFeePips, ...
        (,,, uint24 cfgMaxFee,,,,,,,,,,,,,,,,,) = hook.poolConfig(id);
        assertEq(cfgMaxFee, 3000, "maxFee normalized to base, surge disabled");
        _buy(bob, key, 0.001 ether, abi.encode(bob));
    }

    // ============================================================ #2 jackpot RNG

    function _jackpotParams(uint32 everyN, uint96 minBuy)
        internal
        pure
        returns (HookrLaunchpadLib.HookParams memory p)
    {
        p = _baseParams();
        p.potBps = 100;
        p.potEveryNBuys = everyN;
        p.potMinBuyWei = minBuy;
    }

    /// @dev The pot is now a public schedule: buy N takes it, buys 1..N-1 never do.
    function test_fix2_nthQualifyingBuyWins_earlierOnesDoNot() public {
        (, PoolKey memory key) = _launchAndGraduate(_jackpotParams(5, 0.001 ether), "POT5", TARGET);
        PoolId id = key.toId();

        for (uint256 i = 1; i < 5; i++) {
            _buy(bob, key, 0.001 ether, abi.encode(bob));
            assertEq(hook.potBuyCount(id), i, "counter tracks qualifying buys");
            assertEq(hook.claimableWei(bob), 0, "no payout before the Nth buy");
            assertGt(hook.potWei(id), 0, "pot keeps filling");
            vm.roll(vm.getBlockNumber() + 1);
        }

        uint256 potBefore = hook.potWei(id);
        _buy(bob, key, 0.001 ether, abi.encode(bob));
        assertEq(hook.potBuyCount(id), 5);
        assertGt(hook.claimableWei(bob), potBefore, "the 5th qualifying buy takes the whole pot");
        assertEq(hook.potWei(id), 0, "pot emptied");
        assertEq(hook.totalPotPaidWei(id), hook.claimableWei(bob));
    }

    /// @dev Buys under potMinBuyWei are not qualifying buys: they must not advance the schedule
    ///      (otherwise dust buys would walk the counter to the payout slot for free).
    function test_fix2_belowMinBuy_doesNotAdvanceTheCounter() public {
        uint96 minBuy = 0.001 ether;
        (, PoolKey memory key) = _launchAndGraduate(_jackpotParams(2, minBuy), "POTM", TARGET);
        PoolId id = key.toId();

        for (uint256 i = 0; i < 6; i++) {
            _buy(attacker, key, uint256(minBuy) - 1, abi.encode(attacker));
        }
        assertEq(hook.potBuyCount(id), 0, "dust buys must not count");
        assertEq(hook.claimableWei(attacker), 0, "and must never win");

        _buy(bob, key, minBuy, abi.encode(bob));
        assertEq(hook.potBuyCount(id), 1);
        vm.roll(vm.getBlockNumber() + 1);
        _buy(bob, key, minBuy, abi.encode(bob));
        assertEq(hook.potBuyCount(id), 2);
        assertGt(hook.claimableWei(bob), 0);
    }

    /// @dev Pre-fix the roll hashed the caller-supplied `recipient`, so an attacker ground CREATE2
    ///      addresses off-chain and took the pot with one ordinary swap. Post-fix the recipient is
    ///      an input to nothing: no choice of recipient can win a slot that is not the Nth.
    function test_fix2_attackerCannotWinOutOfTurn_byGrindingTheRecipient() public {
        (, PoolKey memory key) = _launchAndGraduate(_jackpotParams(5, 0.001 ether), "POTG", TARGET);
        PoolId id = key.toId();

        // Park the counter at 1 of 5 and let the pot build.
        _buy(bob, key, 0.001 ether, abi.encode(bob));
        assertEq(hook.potBuyCount(id), 1);
        assertGt(hook.potWei(id), 0);

        // `recipient` is caller-supplied through hookData, so grind it: 512 candidate winners,
        // each tried from the same swap position. Pre-fix, one of these would have hit.
        vm.roll(vm.getBlockNumber() + 1);
        for (uint256 i = 0; i < 512; i++) {
            address ground = address(uint160(uint256(keccak256(abi.encode("grind", i)))));
            _buy(attacker, key, 0.001 ether, abi.encode(ground));
            assertEq(hook.potBuyCount(id), 2, "one buy, one increment");
            assertEq(hook.claimableWei(ground), 0, "recipient grinding cannot buy a win");
            assertEq(hook.totalPotPaidWei(id), 0, "pot never paid out of turn");
        }

        // The pot is only ever taken by whoever occupies slot 5, whatever address they name.
        _buy(attacker, key, 0.001 ether, abi.encode(attacker)); // 2
        vm.roll(vm.getBlockNumber() + 1);
        _buy(attacker, key, 0.001 ether, abi.encode(attacker)); // 3
        vm.roll(vm.getBlockNumber() + 1);
        _buy(attacker, key, 0.001 ether, abi.encode(attacker)); // 4
        assertEq(hook.claimableWei(attacker), 0);
        vm.roll(vm.getBlockNumber() + 1);
        _buy(attacker, key, 0.001 ether, abi.encode(attacker)); // 5 -> wins
        assertGt(hook.claimableWei(attacker), 0);
    }

    // ============================================================ #3 snipe tax on sells

    /// @dev Pre-fix the guard's snipe tax sat outside the isBuy branch, so a seller paid up to
    ///      +45% LP fee during the guard window. The product only ever claimed to tax buys.
    function test_fix3_snipeTaxHitsBuysOnly_sellsAreUntaxed() public {
        HookrLaunchpadLib.HookParams memory p = _baseParams();
        p.guardBlocks = 50;
        p.snipeTaxPips = 400_000; // +40%
        p.baseFeePips = 3000;

        (address token, PoolKey memory key) = _launchAndGraduate(p, "GUARD", TARGET);

        // Alice holds curve tokens. Sell the same slice inside and outside the guard window.
        uint256 slice = HookrToken(token).balanceOf(alice) / 200;
        assertGt(slice, 0);

        uint256 snap = vm.snapshotState();
        BalanceDelta guardedSell = _sell(alice, key, slice);
        uint256 guardedOut = uint256(uint128(guardedSell.amount0()));
        vm.revertToState(snap);

        vm.roll(vm.getBlockNumber() + 51); // guard expired
        BalanceDelta openSell = _sell(alice, key, slice);
        uint256 openOut = uint256(uint128(openSell.amount0()));

        assertGt(guardedOut, 0);
        assertEq(guardedOut, openOut, "a sell during the guard must pay exactly the base fee");

        // Meanwhile a buy in the same window IS taxed.
        vm.revertToState(snap);
        uint256 buySnap = vm.snapshotState();
        BalanceDelta guardedBuy = _buy(bob, key, 0.0005 ether, abi.encode(bob));
        uint256 guardedTokens = uint256(uint128(guardedBuy.amount1()));
        vm.revertToState(buySnap);
        vm.roll(vm.getBlockNumber() + 51);
        BalanceDelta openBuy = _buy(bob, key, 0.0005 ether, abi.encode(bob));
        uint256 openTokens = uint256(uint128(openBuy.amount1()));
        assertLt(guardedTokens, (openTokens * 70) / 100, "a guarded buy must pay the snipe tax");
    }

    // ============================================================ #4 LP rewards / JIT LP

    function _lpParams() internal pure returns (HookrLaunchpadLib.HookParams memory p) {
        p = _baseParams();
        p.lpBps = 100; // 1% of every buy to LPs
    }

    /// @dev Pre-fix the LP cut piled up in a vault that anyone could flush with permissionless
    ///      donate(), so a JIT LP added full-range liquidity, flushed, and removed — capturing
    ///      nearly the whole vault. Post-fix the cut is donated inside the accruing swap, so a
    ///      latecomer LP can only ever earn on volume that happens after it is in range.
    function test_fix4_jitLp_cannotCaptureAlreadyAccruedLpRewards() public {
        (address token, PoolKey memory key) = _launchAndGraduate(_lpParams(), "JITLP", TARGET);
        PoolId id = key.toId();

        // Organic volume accrues (and immediately donates) LP rewards.
        for (uint256 i = 0; i < 5; i++) {
            _buy(bob, key, 0.002 ether, abi.encode(bob));
        }
        uint256 donated = hook.totalLpDonatedWei(id);
        assertGt(donated, 0, "LP cut was donated");

        // There is no standing LP balance anywhere for a latecomer to take.
        assertEq(
            hook.nativeClaimBalance(),
            hook.burnVaultWei(id) + hook.potWei(id),
            "the hook holds only native claims backing pots"
        );

        // The JIT attacker now shows up: add full-range liquidity, try to harvest, remove.
        // Stake it with tokens bought from the pool so the position is genuinely two-sided.
        // NOTE: read the balance first — an external call in the argument list would consume the
        // pending vm.prank instead of the transfer.
        uint256 stake = HookrToken(token).balanceOf(alice) / 10;
        vm.prank(alice);
        HookrToken(token).transfer(attacker, stake);
        vm.startPrank(attacker);
        HookrToken(token).approve(address(lpRouter), type(uint256).max);
        vm.stopPrank();

        uint256 ethBefore = attacker.balance;
        uint256 tokensBefore = HookrToken(token).balanceOf(attacker);

        (int24 tickLower, int24 tickUpper) = (int24(-887220), int24(887220));
        int256 liq = 1e10;
        vm.prank(attacker);
        lpRouter.modifyLiquidity{value: 1 ether}(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liq, salt: bytes32(0)}),
            ""
        );
        // Immediately pull back out, in the same block, harvesting whatever fees are owed.
        vm.prank(attacker);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -liq, salt: bytes32(0)}),
            ""
        );

        // Round-trip PnL must be non-positive: nothing accrued before the attacker was in range
        // is reachable, and no vault exists to flush.
        assertLe(attacker.balance, ethBefore, "a JIT LP must not extract ETH it never earned");
        assertLe(HookrToken(token).balanceOf(attacker), tokensBefore, "nor tokens");
        assertEq(hook.totalLpDonatedWei(id), donated, "no extra donation was triggered");
    }

    /// @dev The donated ETH really lands in the pool's fee growth: the locked POL — which owns
    ///      essentially all in-range liquidity — can collect it.
    function test_fix4_donationReachesLps_collectableByThePol() public {
        (address token, PoolKey memory key) = _launchAndGraduate(_lpParams(), "LPCOL", TARGET);
        PoolId id = key.toId();

        for (uint256 i = 0; i < 5; i++) {
            _buy(bob, key, 0.002 ether, abi.encode(bob));
        }
        uint256 donated = hook.totalLpDonatedWei(id);
        assertGt(donated, 0);

        uint256 creatorBefore = pad.creatorFeesWei(token);
        uint256 protoBefore = pad.protocolFeesByQuote(address(0));
        pad.collectPoolFees(token);
        uint256 collected =
            (pad.creatorFeesWei(token) - creatorBefore) + (pad.protocolFeesByQuote(address(0)) - protoBefore);
        assertGe(collected, donated, "POL collects at least the donated ETH, plus swap LP fees");
    }

    /// @dev Donating inside beforeSwap must leave the unlock perfectly settled. Assert the exact
    ///      ETH movement in both directions: on a buy the PoolManager keeps everything except the
    ///      slice the hook takes (so the donated wei provably stayed in the pool), and on a sell
    ///      the hook's balance does not move at all.
    function test_fix4_deltasSettleExactly_bothDirections() public {
        HookrLaunchpadLib.HookParams memory p = _lpParams();
        p.burnBps = 100;
        p.burnTriggerWei = 0;
        p.potBps = 100;
        p.potEveryNBuys = 1000;
        p.potMinBuyWei = 0.001 ether;

        (address token, PoolKey memory key) = _launchAndGraduate(p, "DELTA", TARGET);
        PoolId id = key.toId();

        for (uint256 round = 0; round < 3; round++) {
            // ---- buy
            uint256 pmBefore = address(PM).balance;
            uint256 claimsBefore = hook.nativeClaimBalance();
            uint256 donatedBefore = hook.totalLpDonatedWei(id);

            uint256 ethIn = 0.002 ether;
            _buy(bob, key, ethIn, abi.encode(bob));

            uint256 claimsMinted = hook.nativeClaimBalance() - claimsBefore;
            uint256 donated = hook.totalLpDonatedWei(id) - donatedBefore;
            assertGt(donated, 0, "LP cut donated in-swap");
            assertEq(
                address(PM).balance,
                pmBefore + ethIn,
                "the pool receives the full native input; obligations are ERC-6909 claims"
            );
            assertGt(claimsMinted, 0, "pot obligation minted as a native claim");
            assertEq(
                hook.nativeClaimBalance(),
                hook.potWei(id) + hook.claimableWei(bob),
                "native claims are fully accounted; nothing stuck"
            );
            assertEq(address(hook).balance, 0, "no physical ETH vault");

            // ---- sell straight back
            uint256 slice = HookrToken(token).balanceOf(bob) / 4;
            uint256 pmBeforeSell = address(PM).balance;
            uint256 claimsBeforeSell = hook.nativeClaimBalance();
            BalanceDelta d = _sell(bob, key, slice);
            uint256 ethOut = uint256(uint128(d.amount0()));
            assertGt(ethOut, 0);
            assertEq(hook.nativeClaimBalance(), claimsBeforeSell, "sells pay no hook cut");
            assertEq(address(PM).balance, pmBeforeSell - ethOut, "sell settles exactly");
        }

        // Auto-burn happened inside every buy and never created an ETH-side vault.
        assertGt(hook.totalBurnedTokens(id), 0);
        assertEq(hook.burnVaultWei(id), 0);
        assertEq(
            hook.nativeClaimBalance(), hook.potWei(id) + hook.claimableWei(bob), "only pot and pull payments remain"
        );
    }

    // ============================================================ #5 no stranded burn ETH

    /// @dev The legacy trigger is ignored: burn happens against actual token output in every
    ///      qualifying buy, and no buyer-paid ETH can accumulate in a burn vault.
    function test_fix5_autoBurn_neverCreatesAStrandedEthVault() public {
        HookrLaunchpadLib.HookParams memory p = _baseParams();
        p.burnBps = 1000; // 10% of actual token output, the maximum
        p.burnTriggerWei = 0; // compatibility-only field must remain zero
        p.baseFeePips = 3000;

        (address token, PoolKey memory key) = _launchAndGraduate(p, "AUTOB", TARGET);
        PoolId id = key.toId();

        uint256 deadBefore = HookrToken(token).balanceOf(DEAD);
        for (uint256 i = 0; i < 4; i++) {
            _buy(bob, key, 0.002 ether, abi.encode(bob));
        }
        uint256 burned = HookrToken(token).balanceOf(DEAD) - deadBefore;
        assertGt(burned, 0, "every buy burns actual output immediately");
        assertEq(hook.totalBurnedTokens(id), burned);
        assertEq(hook.burnVaultWei(id), 0);
        assertEq(address(hook).balance, 0, "burn-only pools never take buyer ETH");
    }

    // ============================================================ #6 no permissionless buyback order

    /// @dev Auto-burn is a deterministic cut of the buy's actual output. The legacy entrypoint is
    ///      disabled, so there is no separate, publicly triggerable market order to sandwich.
    function test_fix6_autoBurnExactOutputCut_andLegacyEntrypointDisabled() public {
        HookrLaunchpadLib.HookParams memory p = _baseParams();
        p.burnBps = 100;
        p.burnTriggerWei = 0;

        (address token, PoolKey memory key) = _launchAndGraduate(p, "SLIP", TARGET);
        PoolId id = key.toId();

        uint256 deadBefore = HookrToken(token).balanceOf(DEAD);
        BalanceDelta delta = _buy(bob, key, 0.002 ether, abi.encode(bob));
        uint256 burned = HookrToken(token).balanceOf(DEAD) - deadBefore;
        assertGt(burned, 0);
        uint256 received = uint256(uint128(delta.amount1()));
        uint256 grossOutput = received + burned;
        assertEq(burned, (grossOutput * p.burnBps) / 10_000, "burn is the configured output cut");
        assertEq(hook.burnVaultWei(id), 0);
        vm.expectRevert(HookrHook.BuybackDisabled.selector);
        hook.buybackAndBurn(key, 1);
    }
}
