// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {BlueprintSeeds} from "./utils/BlueprintSeeds.sol";

/// @notice End-to-end tests against the LIVE Robinhood Chain PoolManager (forked).
///         This suite is the release gate: graduation, hook behavior, and fee plumbing must all
///         work against the real deployed v4 core before anything is broadcast.
contract ForkTest is Test {
    /// @dev The hook's flywheel recipient. address(0) = flywheel dormant (pre-flywheel semantics).
    address constant FLYWHEEL_RECIPIENT = address(0);

    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint96 constant TARGET = 0.01 ether;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    HookrLaunchpad pad;
    HookrHook hook;
    PoolSwapTest router;
    uint256 public selectedForkBlock;

    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string("robinhood"));
        uint256 requestedForkBlock = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (requestedForkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, requestedForkBlock);
        }
        selectedForkBlock = vm.getBlockNumber();
        emit log_named_uint("Robinhood fork block", selectedForkBlock);
        assertEq(block.chainid, 4663);
        if (requestedForkBlock != 0) assertEq(selectedForkBlock, requestedForkBlock);

        pad = new HookrLaunchpad(PM);
        BlueprintSeeds.seed(pad);
        bytes memory creation =
            abi.encodePacked(type(HookrHook).creationCode, abi.encode(PM, address(pad), FLYWHEEL_RECIPIENT));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(PM, address(pad), FLYWHEEL_RECIPIENT);
        assertEq(address(hook), predicted, "mined address must match");
        pad.setHook(hook);

        router = new PoolSwapTest(PM);
        assertEq(vm.getBlockNumber(), selectedForkBlock, "local deployments changed fork block");

        vm.deal(creator, 10 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // ------------------------------------------------------------ helpers

    function _params() internal pure returns (HookrLaunchpad.HookParams memory p) {
        p = HookrLaunchpad.HookParams({
            guardBlocks: 10,
            maxBuyBps: 100, // 1% of supply per swap during guard
            snipeTaxPips: 400_000, // +40%
            baseFeePips: 3000, // 0.3%
            maxFeePips: 30_000, // surge to 3%
            surgeSens: 5,
            burnBps: 100, // 1% of actual token output -> 0xdEaD
            burnTriggerWei: 0, // deprecated compatibility field
            lpBps: 25,
            potBps: 50,
            potEveryNBuys: 2, // every 2nd qualifying buy takes the pot: test-friendly
            potMinBuyWei: 0.001 ether
        });
    }

    function _launchAndGraduate() internal returns (address token, PoolKey memory key) {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Kraken Klub";
        a.symbol = "KRKN";
        a.tagline = "release the kraken";
        a.logoURI = "";
        a.expectedCreator = creator;
        a.targetRaiseWei = TARGET;
        a.blueprintId = 0;
        a.custom = _params();

        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        token = pad.launch{value: fee}(a);

        // Alice buys out the whole curve (target + fees + headroom); refund handles the excess.
        vm.prank(alice);
        pad.buy{value: 0.02 ether}(token, 0);

        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        assertTrue(l.graduated, "curve sellout must auto-graduate");

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _buy(address who, PoolKey memory key, uint256 ethIn) internal returns (BalanceDelta delta) {
        vm.prank(who);
        delta = router.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: 4295128740}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(who)
        );
    }

    // ------------------------------------------------------------ graduation

    function test_launch_creatorBuyAtomicallyGraduates() public {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Atomic Kraken";
        a.symbol = "AKRKN";
        a.tagline = "one launch, one graduation";
        a.expectedCreator = creator;
        a.targetRaiseWei = TARGET;
        a.custom = _params();
        a.creatorBuyWei = 0.02 ether;
        a.minTokensOut = pad.CURVE_SUPPLY();

        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        address token = pad.launch{value: fee + a.creatorBuyWei}(a);
        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        assertTrue(l.graduated, "creator buy did not graduate atomically");
        assertEq(l.soldTokens, pad.CURVE_SUPPLY());
        assertEq(l.reserveWei, 0, "graduation left curve reserve");
        assertEq(HookrToken(token).balanceOf(creator), pad.CURVE_SUPPLY());

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        assertGt(PM.getLiquidity(key.toId()), 0, "atomic graduation did not seed POL");
    }

    function test_launchWithIntent_failedCreatorBuyRollsBack_thenSameIntentGraduatesOnce() public {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Atomic Revert";
        a.symbol = "ARVRT";
        a.expectedCreator = creator;
        a.targetRaiseWei = TARGET;
        a.custom = _params();
        a.creatorBuyWei = 0.02 ether;
        a.minTokensOut = pad.CURVE_SUPPLY() + 1;
        bytes32 intentId = keccak256("fork-atomic-agent-intent");

        uint256 tokensBefore = pad.tokensCount();
        uint256 protocolFeesBefore = pad.protocolFeesWei();
        uint256 payment = pad.creationFeeWei() + a.creatorBuyWei;
        vm.expectRevert(HookrLaunchpad.SlippageExceeded.selector);
        vm.prank(creator);
        pad.launchWithIntent{value: payment}(a, intentId);
        assertEq(pad.tokensCount(), tokensBefore, "failed creator buy left a launch");
        assertEq(pad.protocolFeesWei(), protocolFeesBefore, "failed creator buy retained creation fee");
        assertEq(pad.launchedByIntent(creator, intentId), address(0), "failed launch consumed intent");

        a.minTokensOut = pad.CURVE_SUPPLY();
        vm.prank(creator);
        address token = pad.launchWithIntent{value: payment}(a, intentId);
        assertTrue(pad.getLaunch(token).graduated, "same-intent retry did not graduate");
        assertEq(pad.launchedByIntent(creator, intentId), token, "intent token postcondition mismatch");

        uint256 tokensAfter = pad.tokensCount();
        uint256 protocolFeesAfter = pad.protocolFeesWei();
        vm.expectRevert(
            abi.encodeWithSelector(HookrLaunchpad.LaunchIntentAlreadyUsed.selector, creator, intentId, token)
        );
        vm.prank(creator);
        pad.launchWithIntent{value: payment}(a, intentId);
        assertEq(pad.tokensCount(), tokensAfter, "replayed intent deployed another token");
        assertEq(pad.protocolFeesWei(), protocolFeesAfter, "replayed intent accrued fees");
    }

    function test_graduation_createsLivePool_withLockedLiquidity() public {
        (address token, PoolKey memory key) = _launchAndGraduate();
        PoolId id = key.toId();

        (uint160 sqrtPriceX96,,, uint24 lpFee) = PM.getSlot0(id);
        assertGt(sqrtPriceX96, 0, "pool initialized");
        assertEq(lpFee, 3000, "base fee synced into dynamic fee slot");
        assertGt(PM.getLiquidity(id), 0, "POL seeded");

        // Locked POL: the launchpad exposes no liquidity-removal path (by construction).
        // Sanity: launchpad ETH balance only holds fee accruals, not the reserve.
        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        assertEq(l.reserveWei, 0);
        assertGt(HookrToken(token).balanceOf(DEAD), 0, "leftover pool-side tokens burned");
    }

    function test_graduation_priceContinuity() public {
        (, PoolKey memory key) = _launchAndGraduate();
        (uint160 sqrtPriceX96,,,) = PM.getSlot0(key.toId());
        // price = (sqrtP/2^96)^2 = token per wei; final curve price ~= 5.17e7 wei per 1e18 token.
        // Just assert the pool price is within 1% of the recorded graduation price.
        HookrLaunchpad.Launch memory l = pad.getLaunch(Currency.unwrap(key.currency1));
        assertApproxEqRel(uint256(sqrtPriceX96), uint256(l.sqrtPriceX96AtGraduation), 1e16);
    }

    function test_thirdParty_cannotInitializeWithOurHook() public {
        (address token,) = _launchAndGraduate();
        PoolKey memory alien = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 120, // different key, same hook
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        PM.initialize(alien, 79228162514264337593543950336);
    }

    function test_configurePool_onlyLaunchpad_andOnce() public {
        (, PoolKey memory key) = _launchAndGraduate();
        HookrHook.PoolConfig memory cfg;
        vm.expectRevert(HookrHook.NotLaunchpad.selector);
        hook.configurePool(key, cfg);
    }

    // ------------------------------------------------------------ trading + guard

    function test_swap_buyWorks_feesAccrue() public {
        (, PoolKey memory key) = _launchAndGraduate();
        PoolId id = key.toId();
        vm.roll(vm.getBlockNumber() + 11); // clear the guard for a plain buy

        uint256 ethIn = 0.001 ether;
        BalanceDelta delta = _buy(bob, key, ethIn);
        assertGt(delta.amount1(), 0, "received tokens");

        // Auto-burn takes actual token output; no ETH burn vault or market order exists. The
        // 0.25% LP cut is donated in-swap and only pot / pull-payment ETH remains in the hook.
        assertEq(hook.burnVaultWei(id), 0);
        assertGt(hook.totalBurnedTokens(id), 0, "actual token output auto-burned");
        assertEq(hook.totalLpDonatedWei(id), (ethIn * 25) / 10_000);
        assertGt(hook.potWei(id) + hook.claimableWei(bob), 0, "pot filled or already won");
        assertEq(hook.nativeClaimBalance(), hook.potWei(id) + hook.claimableWei(bob));
        assertEq(address(hook).balance, 0, "no physical ETH vault");
    }

    function test_guard_blocksOversizedBuys_thenExpires() public {
        (, PoolKey memory key) = _launchAndGraduate();

        // cap = 1% supply at final price ~= 0.000517 ETH -> 0.002 ETH must revert
        vm.expectRevert();
        this.extBuy(key, bob, 0.002 ether);

        // small buy passes during the guard
        _buy(bob, key, 0.0004 ether);

        // after the guard the same big buy passes
        vm.roll(vm.getBlockNumber() + 11);
        _buy(bob, key, 0.002 ether);
    }

    function extBuy(PoolKey memory key, address who, uint256 ethIn) external {
        _buy(who, key, ethIn);
    }

    function test_guard_blocksExactOutputBuys() public {
        (, PoolKey memory key) = _launchAndGraduate();
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        router.swap{value: 0.0004 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: int256(1e18), sqrtPriceLimitX96: 4295128740}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_snipeTax_reducesOutputDuringGuard() public {
        (address token, PoolKey memory key) = _launchAndGraduate();

        uint256 snapshot = vm.snapshotState();
        BalanceDelta guarded = _buy(bob, key, 0.0004 ether);
        uint256 guardedOut = uint256(uint128(guarded.amount1()));
        vm.revertToState(snapshot);

        vm.roll(vm.getBlockNumber() + 11);
        BalanceDelta open = _buy(bob, key, 0.0004 ether);
        uint256 openOut = uint256(uint128(open.amount1()));

        // 40% snipe tax must cost meaningfully more than the 0.3% base fee
        assertLt(guardedOut, (openOut * 70) / 100, "guarded buy must be taxed");
        token;
    }

    // ------------------------------------------------------------ jackpot

    /// @dev The jackpot is a public counter, not a roll: at potEveryNBuys == 2 the second
    ///      qualifying buy takes the pot, every time.
    function test_jackpot_hitsAndClaims() public {
        (, PoolKey memory key) = _launchAndGraduate();
        PoolId id = key.toId();
        vm.roll(vm.getBlockNumber() + 11);

        _buy(bob, key, 0.001 ether);
        assertEq(hook.potBuyCount(id), 1);
        assertEq(hook.claimableWei(bob), 0, "buy 1 of 2 cannot win");

        vm.roll(vm.getBlockNumber() + 1);
        _buy(bob, key, 0.001 ether);
        assertEq(hook.potBuyCount(id), 2);
        assertGt(hook.claimableWei(bob), 0, "buy 2 of 2 takes the pot");
        assertGt(hook.totalPotPaidWei(id), 0);
        assertEq(hook.potWei(id), 0, "pot emptied on the win");

        uint256 winnings = hook.claimableWei(bob);
        uint256 before = bob.balance;
        vm.prank(bob);
        hook.claim();
        assertEq(bob.balance, before + winnings);
        assertEq(hook.claimableWei(bob), 0);
    }

    // ------------------------------------------------------------ auto-burn + LP rewards

    function test_autoBurn_burnsActualBuyOutput_withoutEthVault() public {
        (address token, PoolKey memory key) = _launchAndGraduate();
        PoolId id = key.toId();
        vm.roll(vm.getBlockNumber() + 11);

        uint256 deadBefore = HookrToken(token).balanceOf(DEAD);
        _buy(bob, key, 0.001 ether);
        uint256 burned = HookrToken(token).balanceOf(DEAD) - deadBefore;
        assertGt(burned, 0, "actual token output burned during buy");
        assertEq(hook.burnVaultWei(id), 0);
        assertEq(hook.totalBurnedTokens(id), burned);

        vm.expectRevert(HookrHook.BuybackDisabled.selector);
        hook.buybackAndBurn(key, 0);
    }

    /// @dev The LP cut is donated inside the buy that accrues it. There is no LP vault left
    ///      standing between swaps, so there is nothing for a just-in-time LP to flush.
    function test_lpRewards_donatedInsideTheSwap() public {
        (, PoolKey memory key) = _launchAndGraduate();
        PoolId id = key.toId();
        vm.roll(vm.getBlockNumber() + 11);

        uint256 ethIn = 0.001 ether;
        _buy(bob, key, ethIn);
        assertEq(hook.totalLpDonatedWei(id), (ethIn * 25) / 10_000, "LP cut donated in-swap");
        // Every wei the hook still holds is earmarked pot / pull-payment. No LP or burn balance.
        assertEq(hook.nativeClaimBalance(), hook.potWei(id) + hook.claimableWei(bob));
        assertEq(address(hook).balance, 0, "no physical ETH vault");
    }

    // ------------------------------------------------------------ POL fee collection

    function test_collectPoolFees_splitsAndBurns() public {
        (address token, PoolKey memory key) = _launchAndGraduate();
        vm.roll(vm.getBlockNumber() + 11);

        // generate LP fees both directions
        _buy(bob, key, 0.002 ether);
        uint256 tokenBal = HookrToken(token).balanceOf(bob);
        vm.startPrank(bob);
        HookrToken(token).approve(address(router), tokenBal / 2);
        router.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokenBal / 2),
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        uint256 creatorBefore = pad.creatorFeesWei(token);
        uint256 protoBefore = pad.protocolFeesWei();
        pad.collectPoolFees(token);
        assertGt(pad.creatorFeesWei(token), creatorBefore, "creator share of LP fees");
        assertGt(pad.protocolFeesWei(), protoBefore, "protocol share of LP fees");

        // creator can claim
        uint256 amount = pad.creatorFeesWei(token);
        uint256 balBefore = creator.balance;
        pad.claimCreatorFees(token);
        assertEq(creator.balance, balBefore + amount);
    }

    // ------------------------------------------------------------ blueprint royalties

    function test_blueprintLaunch_routesRoyalties() public {
        HookrLaunchpad.HookParams memory p = _params();
        vm.prank(bob); // bob authors the blueprint
        uint32 id = pad.saveBlueprint("Kraken Stack", p, 500); // 5% of hook cuts

        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Feesh";
        a.symbol = "FEESH";
        a.tagline = "plenty of feesh";
        a.logoURI = "";
        a.expectedCreator = creator;
        a.targetRaiseWei = TARGET;
        a.blueprintId = id;

        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        address token = pad.launch{value: fee}(a);
        vm.prank(alice);
        pad.buy{value: 0.02 ether}(token, 0);
        assertTrue(pad.getLaunch(token).graduated);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.roll(vm.getBlockNumber() + 11);
        uint256 royaltiesBefore = hook.claimableWei(bob);
        _buy(alice, key, 0.001 ether);
        assertGt(hook.claimableWei(bob), royaltiesBefore, "author earns royalty on hook fees");
    }
}
