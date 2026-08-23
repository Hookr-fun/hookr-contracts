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
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {HookrBlueprints} from "../src/HookrBlueprints.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLaunchpadLib} from "../src/libraries/HookrLaunchpadLib.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {BlueprintSeeds} from "./utils/BlueprintSeeds.sol";

uint160 constant MIN_LIMIT = 4295128739 + 1;
uint160 constant MAX_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;

/// @notice One-transaction jackpot farmer: walks the public counter to the payout slot with
///         minimum-size buys, dumps the tokens straight back, and claims the pot — all atomically,
///         so it can be simulated and abandoned if it is not profitable.
contract JackpotFarmer {
    PoolSwapTest public immutable router;
    HookrHook public immutable hook;

    constructor(PoolSwapTest router_, HookrHook hook_) {
        router = router_;
        hook = hook_;
    }

    receive() external payable {}

    function farm(PoolKey memory key, uint256 buys, uint256 sizeWei) external payable {
        for (uint256 i = 0; i < buys; i++) {
            router.swap{value: sizeWei}(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -int256(sizeWei), sqrtPriceLimitX96: MIN_LIMIT}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                abi.encode(address(this))
            );
        }
        HookrToken t = HookrToken(Currency.unwrap(key.currency1));
        uint256 bal = t.balanceOf(address(this));
        if (bal > 0) {
            t.approve(address(router), bal);
            router.swap(
                key,
                SwapParams({zeroForOne: false, amountSpecified: -int256(bal), sqrtPriceLimitX96: MAX_LIMIT}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        if (hook.claimableWei(address(this)) > 0) hook.claim();
    }
}

/// @notice A blueprint author / jackpot recipient that cannot receive ETH.
contract NonPayableAccount {
    function saveBlueprint(HookrBlueprints reg, HookrLaunchpadLib.HookParams memory p, uint16 royaltyBps)
        external
        returns (uint32)
    {
        return reg.saveBlueprint("nonpayable-bp", p, royaltyBps);
    }

    function claimFromHook(HookrHook hook) external {
        hook.claim();
    }

    function claimToFromHook(HookrHook hook, address payable to) external {
        hook.claimTo(to);
    }
    // deliberately no receive()/fallback()
}

/// @notice Independent adversarial verification of the eight "fixed" audit findings.
///         Nothing here is copied from the engineer's own regression suite; every assertion is
///         re-derived from the contract source and from Uniswap v4-core's actual settlement rules.
contract AdversarialAuditTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint24 constant DYN = 0x800000;
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
    address mev = address(0xBADBAD);
    address lp = address(0x11FE);

    uint256 nonce;

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
        BlueprintSeeds.seed(pad.blueprints());
        bytes memory creation = abi.encodePacked(type(HookrHook).creationCode, abi.encode(PM, address(pad)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(PM, address(pad));
        assertEq(address(hook), predicted);
        pad.setHook(hook);

        router = new PoolSwapTest(PM);
        lpRouter = new PoolModifyLiquidityTest(PM);
        assertEq(vm.getBlockNumber(), selectedForkBlock, "local deployments changed fork block");

        vm.deal(creator, 10_000 ether);
        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 10_000 ether);
        vm.deal(mev, 10_000 ether);
        vm.deal(lp, 10_000 ether);
    }

    // ------------------------------------------------------------------ harness

    function _p() internal pure returns (HookrLaunchpadLib.HookParams memory p) {
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

    function _key(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: DYN,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _grad(HookrLaunchpadLib.HookParams memory p, uint96 target)
        internal
        returns (address token, PoolKey memory key)
    {
        nonce++;
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Adversarial";
        a.symbol = string(abi.encodePacked("ADV", vm.toString(nonce)));
        a.expectedCreator = creator;
        a.targetRaiseWei = target;
        a.blueprintId = 0;
        a.custom = p;

        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        token = pad.launch{value: fee}(a, bytes32(0));

        uint256 buyout = (uint256(target) * 13) / 10 + 0.001 ether;
        vm.deal(alice, buyout + 10_000 ether);
        vm.prank(alice);
        pad.buy{value: buyout}(token, 0);
        assertTrue(pad.getLaunch(token).graduated, "must graduate");
        key = _key(token);
    }

    function _buy(address who, PoolKey memory key, uint256 ethIn, bytes memory hd) internal returns (BalanceDelta d) {
        vm.prank(who);
        d = router.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: MIN_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hd
        );
    }

    function _buyExactOut(address who, PoolKey memory key, uint256 tokensOut, uint256 maxEth)
        internal
        returns (BalanceDelta d)
    {
        vm.prank(who);
        d = router.swap{value: maxEth}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: int256(tokensOut), sqrtPriceLimitX96: MIN_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _sell(address who, PoolKey memory key, uint256 tokensIn) internal returns (BalanceDelta d) {
        vm.startPrank(who);
        HookrToken(Currency.unwrap(key.currency1)).approve(address(router), type(uint256).max);
        d = router.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(tokensIn), sqrtPriceLimitX96: MAX_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function _sellExactOut(address who, PoolKey memory key, uint256 ethOut) internal returns (BalanceDelta d) {
        vm.startPrank(who);
        HookrToken(Currency.unwrap(key.currency1)).approve(address(router), type(uint256).max);
        d = router.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: int256(ethOut), sqrtPriceLimitX96: MAX_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// @dev Global solvency: every wei the hook holds must be spoken for by a vault or a claim.
    function _assertHookSolvent(PoolId id, address[] memory claimants, string memory tag) internal view {
        uint256 owed = hook.burnVaultWei(id) + hook.potWei(id);
        for (uint256 i = 0; i < claimants.length; i++) {
            owed += hook.claimableWei(claimants[i]);
        }
        assertEq(hook.nativeClaimBalance(), owed, tag);
        assertEq(address(hook).balance, 0, "hook must not custody physical ETH");
    }

    function _claimants() internal view returns (address[] memory a) {
        a = new address[](6);
        a[0] = alice;
        a[1] = bob;
        a[2] = mev;
        a[3] = creator;
        a[4] = lp;
        a[5] = address(this);
    }

    // ==================================================================
    // #1  maxFee divergence — real end-to-end pipeline, not just preview
    // ==================================================================

    /// @dev Fuzz the whole fee surface through launch -> full curve buyout -> graduation -> swap.
    ///      Anything the launchpad accepts must graduate, and the resulting pool must be sane.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_adv1_anyAcceptedFeeStack_graduatesAndTrades(
        uint24 baseRaw,
        uint24 maxRaw,
        uint24 snipeRaw,
        uint16 sensRaw,
        uint32 guardRaw,
        bool zeroMax
    ) public {
        uint24 base = uint24(bound(baseRaw, 0, 500_000));
        uint24 maxF = zeroMax ? 0 : uint24(bound(maxRaw, base, 500_000));
        uint24 snipe = uint24(bound(snipeRaw, 0, 500_000 - base));
        uint16 sens = uint16(bound(sensRaw, 0, 10));
        uint32 guard = uint32(bound(guardRaw, 0, 100_000));

        HookrLaunchpadLib.HookParams memory p = _p();
        p.baseFeePips = base;
        p.maxFeePips = maxF;
        p.snipeTaxPips = snipe;
        p.surgeSens = sens;
        p.guardBlocks = guard;

        (address token, PoolKey memory key) = _grad(p, TARGET);
        PoolId id = key.toId();

        assertTrue(pad.getLaunch(token).graduated, "graduation must never brick");
        assertEq(pad.getLaunch(token).reserveWei, 0, "raise not stranded");

        (uint160 sp,,, uint24 cachedFee) = PM.getSlot0(id);
        assertGt(sp, 0, "pool live");
        assertEq(cachedFee, base, "cached LP fee == baseFeePips");
        assertGt(PM.getLiquidity(id), 0, "POL seeded");

        (, uint40 guardEnd, uint24 cfgBase, uint24 cfgMax,,,,,,,,,,,,,,,,,) = hook.poolConfig(id);
        assertEq(cfgBase, base);
        assertGe(cfgMax, cfgBase, "hook ceiling never below the floor");
        assertEq(cfgMax, maxF == 0 ? base : maxF, "ceiling is the normalized value");
        if (guard == 0) assertEq(guardEnd, 0);

        // The pool must actually trade, both directions, at any accepted fee stack.
        BalanceDelta b = _buy(bob, key, 0.0005 ether, abi.encode(bob));
        uint256 got = uint256(uint128(b.amount1()));
        assertGt(got, 0, "buy must produce tokens even at a 50% fee");
        _sell(bob, key, got / 2);
    }

    /// @dev The strongest form of "cannot diverge": every param bounded into the range the
    ///      launchpad documents as legal (so the accept path is exercised on EVERY run — no silent
    ///      skips), then the exact previewed config is fed to the REAL hook. `saveBlueprint`
    ///      reverting would mean the bound is wrong; `configurePool` reverting IS the brick.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_adv1_launchpadAccept_impliesRealHookAccept(
        uint24 baseRaw,
        uint24 maxRaw,
        uint24 snipeRaw,
        uint16 burnRaw,
        uint16 lpRaw,
        uint16 potRaw,
        uint32 everyNRaw,
        uint96,
        uint96 minBuyRaw,
        uint16 sensRaw,
        uint16 maxBuyBpsRaw,
        uint32 guardRaw,
        uint256 pFinalRaw,
        bool zeroMax
    ) public {
        uint24 base = uint24(bound(baseRaw, 0, 500_000));
        uint16 burn = uint16(bound(burnRaw, 0, 1000));
        uint16 lpB = uint16(bound(lpRaw, 0, 1000 - burn));
        uint16 potB = uint16(bound(potRaw, 0, 1000 - burn - lpB));

        HookrLaunchpadLib.HookParams memory p = HookrLaunchpadLib.HookParams({
            guardBlocks: uint32(bound(guardRaw, 0, 100_000)),
            maxBuyBps: uint16(bound(maxBuyBpsRaw, 0, 10_000)),
            snipeTaxPips: uint24(bound(snipeRaw, 0, 500_000 - base)),
            baseFeePips: base,
            maxFeePips: zeroMax ? 0 : uint24(bound(maxRaw, base, 500_000)),
            surgeSens: uint16(bound(sensRaw, 0, 10)),
            burnBps: burn,
            burnTriggerWei: 0,
            lpBps: lpB,
            potBps: potB,
            potEveryNBuys: potB > 0
                ? uint32(bound(everyNRaw, 2, 100_000))
                : uint32(bound(everyNRaw, 0, type(uint32).max)),
            potMinBuyWei: potB > 0
                ? uint96(bound(minBuyRaw, hook.MIN_POT_BUY_WEI(), type(uint96).max))
                : uint96(bound(minBuyRaw, 0, type(uint96).max)),
            buybackBps: 0,
            buybackDrawdownBps: 0,
            buybackCooldownBlocks: 0,
            buybackMinSpendWei: 0,
            buybackMaxSpendWei: 0
        });
        uint256 pFinal = bound(pFinalRaw, 1e5, 1e13); // the real graduation range for 1e-4..1e3 ETH

        // Every one of these MUST be accepted by the launchpad; a revert here is a bad bound.
        uint16 royaltyBps = lpB + potB > 0 ? 1000 : 0;
        bpReg.saveBlueprint("probe", p, royaltyBps);

        HookrHook.PoolConfig memory cfg = HookrLaunchpadLib.previewPoolConfig(p, pFinal, pad.SUPPLY());
        assertGe(cfg.maxFeePips, cfg.baseFeePips, "normalized ceiling never below the floor");
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(uint160(uint256(keccak256(abi.encode(p, pFinal)))))),
            fee: DYN,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.prank(address(pad));
        hook.configurePool(k, cfg); // must not revert — a revert here IS the graduation brick
    }

    // ==================================================================
    // #2  jackpot — try hard to steal the pot
    // ==================================================================

    function _potParams(uint32 everyN, uint96 minBuy, uint16 potBps)
        internal
        pure
        returns (HookrLaunchpadLib.HookParams memory p)
    {
        p = _p();
        p.potBps = potBps;
        p.potEveryNBuys = everyN;
        p.potMinBuyWei = minBuy;
    }

    /// @dev Both validators enforce the same protocol-wide qualifying-buy floor. A blueprint
    ///      cannot create free schedule slots, and previewed data cannot bypass the hook itself.
    function test_adv2_potMinBelowProtocolFloor_rejectedByLaunchpadAndHook() public {
        HookrLaunchpadLib.HookParams memory p = _potParams(5, 0, 100);
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        bpReg.saveBlueprint("free-pot-trap", p, 0);

        HookrHook.PoolConfig memory cfg = HookrLaunchpadLib.previewPoolConfig(p, 5.18e9, pad.SUPPLY());
        PoolKey memory k = _key(address(0xDEAD1));
        vm.prank(address(pad));
        vm.expectRevert(HookrHook.BadConfig.selector);
        hook.configurePool(k, cfg);
    }

    /// @dev A pool consumes at most one qualifying counter slot per block. A one-transaction loop
    ///      can trade repeatedly, but it cannot atomically manufacture every remaining slot.
    function test_adv2_atomicSingleTxFarm_cannotWalkTheCounter() public {
        HookrLaunchpadLib.HookParams memory p = _potParams(20, 0.001 ether, 1000); // 10% of buys -> pot
        (, PoolKey memory key) = _grad(p, 1 ether);
        PoolId id = key.toId();

        // Organic volume funds the pot. These are real buyers naming themselves in hookData.
        for (uint256 i = 0; i < 5; i++) {
            _buy(bob, key, 1 ether, abi.encode(bob));
            if (i < 4) vm.roll(vm.getBlockNumber() + 1);
        }
        uint256 pot = hook.potWei(id);
        uint256 count = hook.potBuyCount(id);
        assertEq(count, 5);
        assertGt(pot, 0.4 ether, "pot is worth taking");

        JackpotFarmer farmer = new JackpotFarmer(router, hook);
        uint256 need = 20 - (count % 20); // 15 buys to reach slot 20
        uint256 size = 0.001 ether; // exactly potMinBuyWei
        vm.deal(address(farmer), need * size);
        uint256 spent = address(farmer).balance;

        vm.roll(vm.getBlockNumber() + 1);
        farmer.farm{value: 0}(key, need, size);

        assertEq(hook.potBuyCount(id), 6, "the whole loop consumes only this block's one slot");
        assertEq(hook.claimableWei(address(farmer)), 0, "farmer cannot reach the payout");
        assertLe(address(farmer).balance, spent, "round-trip trading cannot capture the pot");
        emit log_named_uint("farmer outlay (wei)", spent);
        emit log_named_uint("farmer end balance (wei)", address(farmer).balance);
        emit log_named_uint("pot captured (wei)", pot);
        // The honest buyer who supplied ~all of the pot walks away with nothing.
        assertEq(hook.claimableWei(bob), 0);
    }

    /// @dev Positive control for the parts of #2 that DID land: hookData is no longer an input to
    ///      the schedule, so no amount of recipient grinding wins a slot that is not the Nth.
    function test_adv2_recipientGrinding_cannotWinOutOfTurn() public {
        (, PoolKey memory key) = _grad(_potParams(7, 0.001 ether, 100), TARGET);
        PoolId id = key.toId();
        _buy(bob, key, 0.002 ether, abi.encode(bob));

        vm.roll(vm.getBlockNumber() + 1);
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < 256; i++) {
            address ground = address(uint160(uint256(keccak256(abi.encode("adv-grind", i)))));
            _buy(mev, key, 0.002 ether, abi.encode(ground));
            assertEq(hook.potBuyCount(id), 2);
            assertEq(hook.claimableWei(ground), 0, "grinding cannot buy a win");
            assertEq(hook.totalPotPaidWei(id), 0);
            vm.revertToState(snap);
        }
    }

    /// @dev Splitting the same input into many swaps within one block still consumes one slot.
    ///      Separate blocks consume separate slots, which is the deliberately public schedule.
    function test_adv2_splittingBuys_sameBlockConsumesOneSlot() public {
        (, PoolKey memory key) = _grad(_potParams(50, 0.001 ether, 100), TARGET);
        PoolId id = key.toId();

        uint256 snap = vm.snapshotState();
        _buy(bob, key, 0.01 ether, abi.encode(bob));
        assertEq(hook.potBuyCount(id), 1, "one big buy == one slot");
        vm.revertToState(snap);

        for (uint256 i = 0; i < 10; i++) {
            _buy(bob, key, 0.001 ether, abi.encode(bob));
        }
        assertEq(hook.potBuyCount(id), 1, "same-block splitting cannot manufacture slots");

        for (uint256 i = 0; i < 9; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            _buy(bob, key, 0.001 ether, abi.encode(bob));
        }
        assertEq(hook.potBuyCount(id), 10, "ten distinct blocks consume ten public slots");
    }

    /// @dev A failed swap cannot leave the counter advanced (state is rolled back with the tx).
    function test_adv2_revertedAttempt_doesNotAdvanceTheCounter() public {
        HookrLaunchpadLib.HookParams memory p = _potParams(3, 0.001 ether, 100);
        p.guardBlocks = 100;
        p.maxBuyBps = 1; // tiny per-swap cap during the guard
        (, PoolKey memory key) = _grad(p, TARGET);
        PoolId id = key.toId();

        uint256 before = hook.potBuyCount(id);
        vm.expectRevert();
        _buy(mev, key, 5 ether, abi.encode(mev)); // exceeds maxBuyWei -> whole tx reverts
        assertEq(hook.potBuyCount(id), before, "reverted attempts leave no trace");
    }

    // ==================================================================
    // #3  snipe tax must never touch a sell
    // ==================================================================

    /// @dev Compare identical sells inside and outside the guard, with the surge block stacked too
    ///      (so a regression that leaks the tax into the surge path is also caught). Exact-input
    ///      and exact-output sells are both checked.
    function test_adv3_sellsDuringGuard_payExactlyTheUnguardedFee() public {
        HookrLaunchpadLib.HookParams memory p = _p();
        p.guardBlocks = 200;
        p.snipeTaxPips = 450_000; // +45%, the legal max on top of a 0.5% base
        p.baseFeePips = 5000;
        p.maxFeePips = 100_000; // surge stacked as well
        p.surgeSens = 10;

        (address token, PoolKey memory key) = _grad(p, TARGET);
        uint256 slice = HookrToken(token).balanceOf(alice) / 500;
        assertGt(slice, 0);

        uint256 snap = vm.snapshotState();
        uint256 guardedIn = uint256(uint128(_sell(alice, key, slice).amount0()));
        vm.revertToState(snap);
        vm.roll(vm.getBlockNumber() + 201);
        uint256 openIn = uint256(uint128(_sell(alice, key, slice).amount0()));
        assertGt(guardedIn, 0);
        assertEq(guardedIn, openIn, "exact-input sell must be identical inside the guard");

        // exact-output sell (asks for a fixed amount of ETH) — also never taxed, and never blocked.
        vm.revertToState(snap);
        uint256 wantEth = openIn / 2;
        uint256 guardedTokensPaid = uint256(uint128(-_sellExactOut(alice, key, wantEth).amount1()));
        vm.revertToState(snap);
        vm.roll(vm.getBlockNumber() + 201);
        uint256 openTokensPaid = uint256(uint128(-_sellExactOut(alice, key, wantEth).amount1()));
        assertGt(guardedTokensPaid, 0);
        assertEq(guardedTokensPaid, openTokensPaid, "exact-output sell must be identical too");

        // ...while a guarded BUY really is taxed.
        vm.revertToState(snap);
        uint256 guardedOut = uint256(uint128(_buy(bob, key, 0.0002 ether, abi.encode(bob)).amount1()));
        vm.revertToState(snap);
        vm.roll(vm.getBlockNumber() + 201);
        uint256 openOut = uint256(uint128(_buy(bob, key, 0.0002 ether, abi.encode(bob)).amount1()));
        assertLt(guardedOut, (openOut * 60) / 100, "guarded buys still pay the snipe tax");
    }

    // ==================================================================
    // #4 / new-bug hunt: settlement across every swap shape
    // ==================================================================

    /// @dev Drive every path that touches the new in-swap `donate` and assert, after each one,
    ///      (a) exact ETH conservation across the PoolManager and (b) that the hook holds nothing
    ///      that is not owed to a vault or a claimant.
    function test_adv4_allSwapShapes_settleExactly_andLeaveNothingStuck() public {
        HookrLaunchpadLib.HookParams memory p = _p();
        p.lpBps = 300;
        p.burnBps = 400;
        p.potBps = 300;
        p.potEveryNBuys = 4;
        p.potMinBuyWei = 0.001 ether;
        p.burnTriggerWei = 0;
        p.baseFeePips = 3000;
        p.maxFeePips = 50_000;
        p.surgeSens = 5;
        p.guardBlocks = 30;
        p.maxBuyBps = 500;

        (address token, PoolKey memory key) = _grad(p, 1 ether);
        PoolId id = key.toId();
        address[] memory who = _claimants();

        _assertHookSolvent(id, who, "post-graduation");

        // ---- 1. exact-input buy inside the guard
        uint256 pm = address(PM).balance;
        uint256 claimsBefore = hook.nativeClaimBalance();
        uint256 burnedBefore = HookrToken(token).balanceOf(DEAD);
        _buy(bob, key, 0.05 ether, abi.encode(bob));
        assertEq(address(PM).balance, pm + 0.05 ether, "guarded buy settles full native input");
        assertGt(hook.nativeClaimBalance(), claimsBefore, "pot obligation minted as native claim");
        assertGt(HookrToken(token).balanceOf(DEAD), burnedBefore, "auto-burn took actual output");
        assertEq(hook.burnVaultWei(id), 0, "no ETH burn vault");
        _assertHookSolvent(id, who, "after guarded buy");

        // ---- 2. exact-input sell inside the guard (hook must not move at all)
        uint256 slice = HookrToken(token).balanceOf(bob) / 4;
        pm = address(PM).balance;
        claimsBefore = hook.nativeClaimBalance();
        uint256 out = uint256(uint128(_sell(bob, key, slice).amount0()));
        assertEq(hook.nativeClaimBalance(), claimsBefore, "sells pay no hook cut");
        assertEq(address(PM).balance, pm - out, "sell settles exactly");
        _assertHookSolvent(id, who, "after guarded sell");

        // ---- 3. exact-output buy is blocked while guarded, allowed after
        vm.expectRevert();
        _buyExactOut(bob, key, 1e18, 1 ether);

        vm.roll(vm.getBlockNumber() + 31);

        // ---- 4. exact-output buy after the guard: no cuts, still settles
        pm = address(PM).balance;
        claimsBefore = hook.nativeClaimBalance();
        uint256 mevBefore = mev.balance;
        _buyExactOut(mev, key, 1e18, 1 ether);
        uint256 paid = mevBefore - mev.balance;
        assertGt(paid, 0);
        assertEq(hook.nativeClaimBalance(), claimsBefore, "exact-output buys take no cut");
        assertEq(address(PM).balance, pm + paid, "exact-output buy settles exactly");
        _assertHookSolvent(id, who, "after exact-output buy");

        // ---- 5. exact-output sell
        pm = address(PM).balance;
        claimsBefore = hook.nativeClaimBalance();
        _sellExactOut(bob, key, 0.001 ether);
        assertEq(hook.nativeClaimBalance(), claimsBefore, "exact-output sell takes no cut");
        assertEq(address(PM).balance, pm - 0.001 ether, "exact-output sell settles exactly");
        _assertHookSolvent(id, who, "after exact-output sell");

        // ---- 6. a jackpot-paying buy
        for (uint256 i = 0; i < 4; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            _buy(bob, key, 0.02 ether, abi.encode(bob));
        }
        assertGt(hook.claimableWei(bob), 0, "jackpot paid");
        _assertHookSolvent(id, who, "after jackpot payout");

        // ---- 7. third-party LP joins mid-stream, then a buy donates to it, then it leaves
        uint256 stake = HookrToken(token).balanceOf(alice) / 20;
        vm.prank(alice);
        HookrToken(token).transfer(lp, stake);
        vm.startPrank(lp);
        HookrToken(token).approve(address(lpRouter), type(uint256).max);
        vm.stopPrank();
        vm.prank(lp);
        lpRouter.modifyLiquidity{value: 5 ether}(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e12, salt: bytes32(0)}),
            ""
        );
        _buy(bob, key, 0.05 ether, abi.encode(bob));
        _assertHookSolvent(id, who, "after LP joined");
        vm.prank(lp);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: -1e12, salt: bytes32(0)}),
            ""
        );
        _assertHookSolvent(id, who, "after LP left");

        // ---- 8. no out-of-band buyback market order exists
        assertGt(hook.totalBurnedTokens(id), 0, "buys already burned their configured output cut");
        assertEq(hook.burnVaultWei(id), 0);
        vm.expectRevert(HookrHook.BuybackDisabled.selector);
        hook.buybackAndBurn(key, 1);
        _assertHookSolvent(id, who, "after disabled legacy buyback");

        // ---- 9. POL fee collection still works and the donated ETH is reachable
        pad.collectPoolFees(token);
        _assertHookSolvent(id, who, "after collectPoolFees");

        // ---- 10. everyone drains their claims; the hook is left holding only its vaults
        for (uint256 i = 0; i < who.length; i++) {
            if (hook.claimableWei(who[i]) > 0) {
                vm.prank(who[i]);
                hook.claim();
            }
        }
        assertEq(hook.nativeClaimBalance(), hook.potWei(id), "no unbacked claim dust left behind");
        assertEq(address(hook).balance, 0);
    }

    /// @dev Auto-burn executes inside guarded buys without a recursive swap or ETH-side vault.
    function test_adv4_autoBurnDuringGuard_hasNoRecursiveCutOrVault() public {
        HookrLaunchpadLib.HookParams memory p = _p();
        p.burnBps = 1000;
        p.burnTriggerWei = 0;
        p.guardBlocks = 10_000;
        p.maxBuyBps = 100; // cap ~0.0518 ETH per pool per block; we will build a vault well above it
        (address token, PoolKey memory key) = _grad(p, 1 ether);
        PoolId id = key.toId();

        uint256 deadBefore = HookrToken(token).balanceOf(DEAD);
        for (uint256 i = 0; i < 15; i++) {
            // One buy per block: the guard budget is cumulative per (pool, block), so accumulating
            // 15 buys' worth of volume now takes 15 blocks. The guard runs for 10,000 of them, so
            // every one of these is still a GUARDED buy, which is what this test is about.
            vm.roll(vm.getBlockNumber() + 1);
            _buy(bob, key, 0.05 ether, abi.encode(bob));
        }
        assertGt(HookrToken(token).balanceOf(DEAD), deadBefore, "guarded buys burned actual output");
        assertGt(hook.totalBurnedTokens(id), 0);
        assertEq(hook.burnVaultWei(id), 0, "no recursive or standing burn vault");
        assertEq(address(hook).balance, 0, "burn-only pool holds no ETH");
    }

    /// @dev A latecomer LP must not be able to reach value donated before it was in range.
    function test_adv4_jitLp_roundTripIsNonPositive() public {
        HookrLaunchpadLib.HookParams memory p = _p();
        p.lpBps = 1000;
        (address token, PoolKey memory key) = _grad(p, 1 ether);
        PoolId id = key.toId();

        for (uint256 i = 0; i < 5; i++) {
            _buy(bob, key, 0.2 ether, abi.encode(bob));
        }
        assertGt(hook.totalLpDonatedWei(id), 0);
        assertEq(address(hook).balance, 0, "the LP cut never becomes a hook balance");

        uint256 stake = HookrToken(token).balanceOf(alice) / 10;
        vm.prank(alice);
        HookrToken(token).transfer(mev, stake);
        vm.startPrank(mev);
        HookrToken(token).approve(address(lpRouter), type(uint256).max);
        vm.stopPrank();

        uint256 e0 = mev.balance;
        uint256 t0 = HookrToken(token).balanceOf(mev);
        vm.prank(mev);
        lpRouter.modifyLiquidity{value: 10 ether}(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e13, salt: bytes32(0)}),
            ""
        );
        vm.prank(mev);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: -1e13, salt: bytes32(0)}),
            ""
        );
        assertLe(mev.balance, e0, "JIT LP extracts no ETH");
        assertLe(HookrToken(token).balanceOf(mev), t0, "and no tokens");
    }

    /// @dev The vault is gone, but the donation still lands on whoever is in range at the moment
    ///      the buy executes. Measure whether a JIT LP can profitably sandwich a single large buy
    ///      and walk away with the donation, fully unwinding back to ETH so the number is real.
    function test_adv4_jitLp_sandwichingOneLargeBuy() public {
        HookrLaunchpadLib.HookParams memory p = _p();
        p.lpBps = 1000; // the maximum LP cut: 10% of every buy
        p.baseFeePips = 3000;
        (address token, PoolKey memory key) = _grad(p, 1 ether);
        PoolId id = key.toId();

        uint256 stake = (HookrToken(token).balanceOf(alice) * 9) / 10;
        vm.prank(alice);
        HookrToken(token).transfer(mev, stake);
        vm.startPrank(mev);
        HookrToken(token).approve(address(lpRouter), type(uint256).max);
        HookrToken(token).approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.deal(mev, 1000 ether);

        uint256 eth0 = mev.balance;
        uint256 tok0 = HookrToken(token).balanceOf(mev);
        uint256 polL = PM.getLiquidity(id);

        int256 jitL = int256(uint256(polL) * 3);
        vm.prank(mev);
        lpRouter.modifyLiquidity{value: 500 ether}(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: jitL, salt: bytes32(0)}),
            ""
        );
        _buy(bob, key, 1 ether, abi.encode(bob)); // the whale buy being sandwiched
        vm.prank(mev);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: -jitL, salt: bytes32(0)}),
            ""
        );

        // Unwind the token side back to the starting inventory so the PnL is pure ETH.
        uint256 tokNow = HookrToken(token).balanceOf(mev);
        if (tokNow > tok0) {
            _sell(mev, key, tokNow - tok0);
        } else if (tokNow < tok0) {
            _buyExactOut(mev, key, tok0 - tokNow, 100 ether);
        }
        assertEq(HookrToken(token).balanceOf(mev), tok0, "token inventory restored");

        emit log_named_int("JIT LP net ETH PnL (wei)", int256(mev.balance) - int256(eth0));
        emit log_named_uint("donated by that buy (wei)", hook.totalLpDonatedWei(id));
    }

    /// @dev There is no separate burn market order to sandwich. The burn is a direct cut of each
    ///      buy's actual output and the legacy permissionless trigger always reverts.
    function test_adv6_autoBurn_hasNoPermissionlessMarketOrder() public {
        HookrLaunchpadLib.HookParams memory p = _p();
        p.burnBps = 1000; // 10% of actual token output
        p.burnTriggerWei = 0;
        p.baseFeePips = 3000;
        (address token, PoolKey memory key) = _grad(p, 1 ether);
        PoolId id = key.toId();

        uint256 deadBefore = HookrToken(token).balanceOf(DEAD);
        for (uint256 i = 0; i < 5; i++) {
            _buy(bob, key, 1 ether, abi.encode(bob));
        }
        assertGt(HookrToken(token).balanceOf(DEAD), deadBefore, "burn happened inline");
        assertEq(hook.burnVaultWei(id), 0, "there is no ETH market-order inventory");
        vm.expectRevert(HookrHook.BuybackDisabled.selector);
        hook.buybackAndBurn(key, 1);
    }

    /// @dev A burn-only pool takes no native ETH from the PoolManager in beforeSwap. The entire
    ///      exact input settles into the pool while the output-token cut goes straight to 0xdEaD.
    function test_adv_misc_autoBurnDoesNotTakeNativeEthFromPoolManager() public {
        HookrLaunchpadLib.HookParams memory p = _p();
        p.burnBps = 1000;
        p.burnTriggerWei = 0;
        (address token, PoolKey memory key) = _grad(p, TARGET);
        PoolId id = key.toId();

        uint256 pmBefore = address(PM).balance;
        uint256 deadBefore = HookrToken(token).balanceOf(DEAD);
        _buy(bob, key, 0.002 ether, abi.encode(bob));
        assertEq(address(PM).balance, pmBefore + 0.002 ether);
        assertGt(HookrToken(token).balanceOf(DEAD), deadBefore);
        assertEq(hook.burnVaultWei(id), 0);
        assertEq(address(hook).balance, 0);
    }

    function externalBuy(address who, PoolKey memory key, uint256 ethIn) external {
        require(msg.sender == address(this));
        _buy(who, key, ethIn, abi.encode(who));
    }

    // ==================================================================
    // #7  creator payout — was the SAME lockup fixed on the hook side?
    // ==================================================================

    /// @dev A non-payable blueprint author can redirect its own claim to a payable recipient.
    function test_adv7_hookSideClaimTo_recoversNonPayableRoyalty() public {
        NonPayableAccount author = new NonPayableAccount();
        HookrLaunchpadLib.HookParams memory bpParams = _p();
        bpParams.lpBps = 500;
        uint32 bpId = author.saveBlueprint(bpReg, bpParams, 1000); // 10% royalty on the cuts

        nonce++;
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Royalty";
        a.symbol = "ROY";
        a.expectedCreator = creator;
        a.targetRaiseWei = TARGET;
        a.blueprintId = bpId;
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        address token = pad.launch{value: fee}(a, bytes32(0));
        vm.prank(alice);
        pad.buy{value: 0.02 ether}(token, 0);
        assertTrue(pad.getLaunch(token).graduated);

        PoolKey memory key = _key(token);
        _buy(bob, key, 0.01 ether, abi.encode(bob));

        uint256 owed = hook.claimableWei(address(author));
        assertGt(owed, 0, "royalties accrued to a contract that cannot take ETH");

        vm.expectRevert(HookrHook.EthTransferFailed.selector);
        author.claimFromHook(hook);

        uint256 aliceBefore = alice.balance;
        author.claimToFromHook(hook, payable(alice));
        assertEq(alice.balance, aliceBefore + owed, "redirected claim received");
        assertEq(hook.claimableWei(address(author)), 0, "claim cleared");
    }

    /// @dev The same payout redirect recovers a deterministic-pot win.
    function test_adv7_jackpotWonByANonReceivingRecipient_canRedirect() public {
        (, PoolKey memory key) = _grad(_potParams(2, 0.001 ether, 500), TARGET);
        PoolId id = key.toId();
        NonPayableAccount winner = new NonPayableAccount();

        _buy(bob, key, 0.005 ether, abi.encode(bob));
        vm.roll(vm.getBlockNumber() + 1);
        _buy(mev, key, 0.005 ether, abi.encode(address(winner))); // slot 2 -> pays `winner`

        uint256 won = hook.claimableWei(address(winner));
        assertGt(won, 0);
        assertEq(hook.potWei(id), 0);
        vm.expectRevert(HookrHook.EthTransferFailed.selector);
        winner.claimFromHook(hook);
        uint256 bobBefore = bob.balance;
        winner.claimToFromHook(hook, payable(bob));
        assertEq(bob.balance, bobBefore + won);
        assertEq(hook.claimableWei(address(winner)), 0);
    }

    // ==================================================================
    // #8  ownership
    // ==================================================================

    function test_adv8_ownershipHandover_isTwoStepAndCannotBeHijacked() public {
        assertEq(pad.owner(), address(this));
        vm.expectRevert(HookrLaunchpad.ZeroAddress.selector);
        pad.proposeOwner(address(0));

        pad.proposeOwner(alice);
        assertEq(pad.owner(), address(this), "owner unchanged until accepted");
        vm.expectRevert(HookrLaunchpad.NotOwner.selector);
        vm.prank(bob);
        pad.acceptOwnership();

        // Re-proposing replaces the nominee; the old one can no longer claim.
        pad.proposeOwner(bob);
        vm.expectRevert(HookrLaunchpad.NotOwner.selector);
        vm.prank(alice);
        pad.acceptOwnership();

        vm.prank(bob);
        pad.acceptOwnership();
        assertEq(pad.owner(), bob);
        assertEq(pad.pendingOwner(), address(0));
        vm.expectRevert(HookrLaunchpad.NotOwner.selector);
        pad.setCreationFee(0);
    }

    // ==================================================================
    // misc: new-bug sweep
    // ==================================================================

    /// @dev A qualifying pot buy must bind a canonical, nonzero recipient. Dirty or wrong-length
    ///      data reverts the whole swap, including its cut, rather than funding the pot while
    ///      silently suppressing the public Nth-buy counter.
    function test_adv_misc_invalidPotRecipient_failsClosedAndDoesNotFundPot() public {
        (, PoolKey memory key) = _grad(_potParams(5, 0.001 ether, 100), TARGET);
        PoolId id = key.toId();
        bytes memory dirty = abi.encodePacked(bytes32(uint256(type(uint256).max)));
        assertEq(dirty.length, 32);

        bytes memory expectedRevert = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(HookrHook.InvalidPotRecipient.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        uint256 potBefore = hook.potWei(id);
        uint256 claimsBefore = hook.nativeClaimBalance();
        uint256 feesBefore = hook.totalHookFeesWei(id);

        vm.expectRevert(expectedRevert);
        _buy(bob, key, 0.001 ether, dirty);
        assertEq(hook.potWei(id), potBefore, "dirty payload funded pot");
        assertEq(hook.nativeClaimBalance(), claimsBefore, "dirty payload minted claims");
        assertEq(hook.totalHookFeesWei(id), feesBefore, "dirty payload accrued hook fees");

        vm.expectRevert(expectedRevert);
        _buy(bob, key, 0.001 ether, hex"00");
        assertEq(hook.potBuyCount(id), 0, "invalid payload advanced counter");
        assertEq(hook.potWei(id), potBefore, "wrong-length payload funded pot");
        assertEq(hook.nativeClaimBalance(), claimsBefore, "wrong-length payload minted claims");

        vm.expectRevert(expectedRevert);
        _buy(bob, key, 0.001 ether, abi.encode(address(0)));
        assertEq(hook.potBuyCount(id), 0, "zero recipient advanced counter");

        _buy(bob, key, 0.001 ether, abi.encode(bob));
        assertEq(hook.potBuyCount(id), 1, "canonical address still qualifies");
    }

    /// @dev The new in-swap `donate` is only re-entrancy-safe because the hook holds no donate
    ///      flags. Pin the address bits down so a future re-mine cannot silently open that door.
    function test_adv_misc_hookAddressHasNoDonateFlags() public view {
        uint160 bits = uint160(address(hook)) & 0x3FFF;
        assertEq(bits, hook.REQUIRED_FLAGS(), "exactly reviewed guard/swap callbacks and return deltas");
        assertEq(bits & uint160(1 << 5), 0, "no BEFORE_DONATE flag");
        assertEq(bits & uint160(1 << 4), 0, "no AFTER_DONATE flag");
        assertEq(bits & uint160(1 << 6), uint160(1 << 6), "AFTER_SWAP auto-burn flag set");
        assertEq(bits & uint160(1 << 2), uint160(1 << 2), "AFTER_SWAP_RETURNS_DELTA flag set");
        assertEq(bits & uint160(1 << 11), uint160(1 << 11), "BEFORE_ADD guard-attribution flag set");
        assertEq(bits & uint160((1 << 10) | (1 << 9) | (1 << 8)), 0, "no other liquidity flags");
    }

    /// @dev A malicious blueprint cannot publish a dust-slot stack, and direct hook configuration
    ///      independently enforces the same floor.
    function test_adv2_zeroMinBuyIsRejectedByEveryValidator() public {
        HookrLaunchpadLib.HookParams memory p = _potParams(2, 0, 1000);
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        bpReg.saveBlueprint("free-pot-trap", p, 1000);
        HookrHook.PoolConfig memory cfg = HookrLaunchpadLib.previewPoolConfig(p, 5.18e9, pad.SUPPLY());
        PoolKey memory k = _key(address(0xDEAD1));
        vm.prank(address(pad));
        vm.expectRevert(HookrHook.BadConfig.selector);
        hook.configurePool(k, cfg);
    }

    /// @dev Even if a future launchpad regression bypasses saveBlueprint validation, the hook
    ///      independently rejects a royalty with no native LP/pot cut backing it.
    function test_adv_misc_hookRejectsPhantomRoyaltyWithoutNativeCut() public {
        HookrLaunchpadLib.HookParams memory p = _p();
        p.burnBps = 100;
        p.lpBps = 0;
        p.potBps = 0;
        p.potEveryNBuys = 0;
        p.potMinBuyWei = 0;
        HookrHook.PoolConfig memory cfg = HookrLaunchpadLib.previewPoolConfig(p, 5.18e9, pad.SUPPLY());
        cfg.royaltyBps = 1;
        cfg.royaltyTo = bob;
        PoolKey memory k = _key(address(0xDEAD2));
        vm.prank(address(pad));
        vm.expectRevert(HookrHook.BadConfig.selector);
        hook.configurePool(k, cfg);
    }

    /// @dev There is no permissionless stale-pot flush. Advancing arbitrarily far cannot create a
    ///      JIT-capture path; the funded pot remains assigned to its public Nth-buy schedule.
    function test_adv_misc_noPermissionlessStalePotFlush_potRemainsForNextWinner() public {
        (, PoolKey memory key) = _grad(_potParams(100_000, 0.001 ether, 1000), TARGET);
        PoolId id = key.toId();
        for (uint256 i = 0; i < 3; i++) {
            _buy(bob, key, 0.002 ether, abi.encode(bob));
            if (i < 2) vm.roll(vm.getBlockNumber() + 1);
        }
        uint256 pot = hook.potWei(id);
        assertGt(pot, 0);
        assertEq(hook.potBuyCount(id), 3);
        assertEq(hook.claimableWei(bob), 0);

        uint256 donatedBefore = hook.totalLpDonatedWei(id);
        uint256 claimsBefore = hook.nativeClaimBalance();
        uint256 feesBefore = hook.totalHookFeesWei(id);
        vm.roll(vm.getBlockNumber() + 10_000_000);

        bytes4 removedSelector = bytes4(keccak256("releaseStalePot((address,address,uint24,int24,address))"));
        (bool ok,) = address(hook).call(abi.encodeWithSelector(removedSelector, key));
        assertFalse(ok, "removed stale-pot selector unexpectedly callable");
        assertEq(hook.potWei(id), pot, "pot escaped public schedule");
        assertEq(hook.potBuyCount(id), 3, "counter changed without a buy");
        assertEq(hook.totalLpDonatedWei(id), donatedBefore, "pot was redirected to LPs");
        assertEq(hook.nativeClaimBalance(), claimsBefore, "pot backing changed");
        assertEq(hook.totalHookFeesWei(id), feesBefore, "fees changed");
        assertEq(address(hook).balance, 0);
    }
}
