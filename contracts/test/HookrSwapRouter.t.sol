// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrSwapRouter} from "../src/HookrSwapRouter.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract ReenteringRefundPayer {
    HookrSwapRouter public router;
    HookrSwapRouter.ExactInputParams private params;
    bool public attempted;
    bytes4 public observedSelector;

    function execute(HookrSwapRouter router_, HookrSwapRouter.ExactInputParams calldata params_) external payable {
        router = router_;
        params = params_;
        router_.exactInput{value: msg.value}(params_);
    }

    receive() external payable {
        if (attempted) return;
        attempted = true;
        try router.exactInput(params) {}
        catch (bytes memory reason) {
            if (reason.length >= 4) {
                bytes4 selector;
                assembly ("memory-safe") {
                    selector := mload(add(reason, 32))
                }
                observedSelector = selector;
            }
        }
    }
}

/// @notice Robinhood fork integration tests for the production router candidate. Release runs
///         pin `ROBINHOOD_FORK_BLOCK`; local runs fall back to the endpoint's latest block.
contract HookrSwapRouterTest is Test {
    /// @dev The hook's flywheel recipient. address(0) = flywheel dormant (pre-flywheel semantics).
    address constant FLYWHEEL_RECIPIENT = address(0);

    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint160 constant MIN_LIMIT = 4295128739 + 1;
    uint160 constant MAX_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 constant SWAP_EVENT_SIGNATURE =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    IPoolManager constant ROBINHOOD_PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    IPoolManager manager;
    HookrLaunchpad pad;
    HookrHook hook;
    HookrSwapRouter router;
    PoolSwapTest rawRouter;
    HookrToken token;
    PoolKey key;
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
        manager = ROBINHOOD_PM;
        pad = new HookrLaunchpad(manager);
        bytes memory creation =
            abi.encodePacked(type(HookrHook).creationCode, abi.encode(manager, address(pad), FLYWHEEL_RECIPIENT));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(manager, address(pad), FLYWHEEL_RECIPIENT);
        assertEq(address(hook), predicted);
        pad.setHook(hook);
        router = new HookrSwapRouter(manager, hook, address(0));
        rawRouter = new PoolSwapTest(manager);
        assertEq(vm.getBlockNumber(), selectedForkBlock, "local deployments changed fork block");

        vm.deal(creator, 10 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        HookrLaunchpad.HookParams memory p = HookrLaunchpad.HookParams({
            guardBlocks: 0,
            maxBuyBps: 0,
            snipeTaxPips: 0,
            baseFeePips: 3000,
            maxFeePips: 30_000,
            surgeSens: 5,
            burnBps: 100,
            burnTriggerWei: 0,
            lpBps: 25,
            potBps: 50,
            potEveryNBuys: 2,
            potMinBuyWei: 0.001 ether
        });
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Router Fish";
        a.symbol = "ROUTE";
        a.expectedCreator = creator;
        a.targetRaiseWei = 0.01 ether;
        a.custom = p;
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        token = HookrToken(pad.launch{value: fee}(a));
        vm.prank(alice);
        pad.buy{value: 0.02 ether}(address(token), 0);
        assertTrue(pad.getLaunch(address(token)).graduated);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _buyParams(uint128 amountIn, uint128 minOut, address recipient)
        internal
        view
        returns (HookrSwapRouter.ExactInputParams memory p)
    {
        p = HookrSwapRouter.ExactInputParams({
            key: key,
            zeroForOne: true,
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: MIN_LIMIT,
            recipient: recipient,
            deadline: block.timestamp + 1
        });
    }

    function _routerBuy(address payer, address recipient, uint128 amountIn) internal returns (uint256 out) {
        HookrSwapRouter.ExactInputParams memory p = _buyParams(amountIn, 1, recipient);
        vm.prank(payer);
        out = router.exactInput{value: amountIn}(p);
    }

    function _graduateBurnOnly() internal returns (HookrToken burnToken, PoolKey memory burnKey) {
        HookrLaunchpad.HookParams memory p = HookrLaunchpad.HookParams({
            guardBlocks: 0,
            maxBuyBps: 0,
            snipeTaxPips: 0,
            baseFeePips: 3000,
            maxFeePips: 3000,
            surgeSens: 0,
            burnBps: 100,
            burnTriggerWei: 0,
            lpBps: 0,
            potBps: 0,
            potEveryNBuys: 0,
            potMinBuyWei: 0
        });
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Partial Fill Fish";
        a.symbol = "PART";
        a.expectedCreator = creator;
        a.targetRaiseWei = 0.01 ether;
        a.custom = p;
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        burnToken = HookrToken(pad.launch{value: fee}(a));
        vm.prank(alice);
        pad.buy{value: 0.02 ether}(address(burnToken), 0);
        burnKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(burnToken)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _graduateFeePool(string memory name, string memory symbol, uint24 maxFeePips, uint16 surgeSens)
        internal
        returns (HookrToken feeToken, PoolKey memory feeKey)
    {
        HookrLaunchpad.HookParams memory p = HookrLaunchpad.HookParams({
            guardBlocks: 0,
            maxBuyBps: 0,
            snipeTaxPips: 0,
            baseFeePips: 3000,
            maxFeePips: maxFeePips,
            surgeSens: surgeSens,
            burnBps: 0,
            burnTriggerWei: 0,
            lpBps: 0,
            potBps: 0,
            potEveryNBuys: 0,
            potMinBuyWei: 0
        });
        HookrLaunchpad.LaunchArgs memory a;
        a.name = name;
        a.symbol = symbol;
        a.expectedCreator = creator;
        a.targetRaiseWei = 0.01 ether;
        a.custom = p;
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        feeToken = HookrToken(pad.launch{value: fee}(a));
        vm.prank(alice);
        pad.buy{value: 0.02 ether}(address(feeToken), 0);
        assertTrue(pad.getLaunch(address(feeToken)).graduated);
        feeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(feeToken)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _recordedSwapFee(PoolId id) internal returns (uint24 feePips) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 rawId = PoolId.unwrap(id);
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == address(manager) && entries[i].topics.length == 3
                    && entries[i].topics[0] == SWAP_EVENT_SIGNATURE && entries[i].topics[1] == rawId
            ) {
                (,,,,, feePips) = abi.decode(entries[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return feePips;
            }
        }
        fail("PoolManager Swap event missing");
    }

    function test_identityReadbacks() public view {
        assertEq(router.contractName(), "HookrSwapRouter");
        assertEq(router.contractVersion(), "1.0.0");
        assertEq(address(router.poolManager()), address(manager));
        assertEq(address(router.hook()), address(hook));
        assertEq(hook.contractName(), "HookrHook");
        assertEq(pad.contractName(), "HookrLaunchpad");
    }

    function test_exactInputBuy_enforcesMinOut_andBindsRecipientToHookData() public {
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);
        uint256 deadBefore = token.balanceOf(DEAD);
        uint256 out = _routerBuy(bob, alice, 0.001 ether);

        assertEq(token.balanceOf(alice) - aliceBefore, out, "output delivered only to recipient");
        assertEq(token.balanceOf(bob), bobBefore, "payer is not implicitly the recipient");
        assertGt(token.balanceOf(DEAD), deadBefore, "auto-burn executed");
        assertEq(hook.potBuyCount(key.toId()), 1, "bound hookData names the output recipient");
        assertEq(address(router).balance, 0, "router retains no native input");
        assertEq(token.balanceOf(address(router)), 0, "router retains no output");
    }

    function test_exactInputBuy_unsatisfiedMinOutRevertsAtomically() public {
        HookrSwapRouter.ExactInputParams memory p = _buyParams(0.001 ether, type(uint128).max, alice);
        uint256 potBefore = hook.potWei(key.toId());
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(bob);
        vm.expectPartialRevert(HookrSwapRouter.TooLittleReceived.selector);
        router.exactInput{value: p.amountIn}(p);
        assertEq(hook.potWei(key.toId()), potBefore);
        assertEq(token.balanceOf(DEAD), deadBefore);
    }

    function test_exactInputBuy_zeroMinOutRejectedBeforeSettlement() public {
        HookrSwapRouter.ExactInputParams memory p = _buyParams(0.001 ether, 0, alice);
        PoolId id = key.toId();
        uint256 potBefore = hook.potWei(id);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(bob);
        vm.expectRevert(HookrSwapRouter.InvalidAmount.selector);
        router.exactInput{value: p.amountIn}(p);
        assertEq(hook.potWei(id), potBefore);
        assertEq(token.balanceOf(DEAD), deadBefore);
    }

    function test_surgeFee_equivalentPoolsChargesMoreAndClampsAtCeiling() public {
        (, PoolKey memory baseKey) = _graduateFeePool("Base Fee Fish", "BASEF", 3000, 0);
        (, PoolKey memory surgeKey) = _graduateFeePool("Surge Fee Fish", "SURGF", 30_000, 10);
        PoolId baseId = baseKey.toId();
        PoolId surgeId = surgeKey.toId();

        (uint160 baseSqrtPriceX96,,,) = manager.getSlot0(baseId);
        (uint160 surgeSqrtPriceX96,,,) = manager.getSlot0(surgeId);
        uint128 baseLiquidity = manager.getLiquidity(baseId);
        uint128 surgeLiquidity = manager.getLiquidity(surgeId);
        assertEq(surgeSqrtPriceX96, baseSqrtPriceX96, "starting price differs");
        assertEq(surgeLiquidity, baseLiquidity, "starting liquidity differs");

        // At sensitivity 10, ceil(reserve/10) makes the ratio at least 100%, forcing the configured
        // 3% ceiling without taking the pool anywhere near its finite full-range boundary.
        uint256 reserveIn = (uint256(baseLiquidity) << 96) / baseSqrtPriceX96;
        uint256 rawAmountIn = (reserveIn + 9) / 10;
        assertGt(rawAmountIn, 0);
        assertLe(rawAmountIn, uint256(uint128(type(int128).max)));
        uint128 amountIn = uint128(rawAmountIn);

        HookrSwapRouter.ExactInputParams memory p = HookrSwapRouter.ExactInputParams({
            key: baseKey,
            zeroForOne: true,
            amountIn: amountIn,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: MIN_LIMIT,
            recipient: bob,
            deadline: block.timestamp + 1
        });
        vm.recordLogs();
        vm.prank(bob);
        uint256 baseOut = router.exactInput{value: amountIn}(p);
        uint24 baseFee = _recordedSwapFee(baseId);

        p.key = surgeKey;
        vm.recordLogs();
        vm.prank(bob);
        uint256 surgeOut = router.exactInput{value: amountIn}(p);
        uint24 surgeFee = _recordedSwapFee(surgeId);

        assertEq(baseFee, 3000, "base-only pool fee changed");
        assertEq(surgeFee, 30_000, "surge did not clamp at configured ceiling");
        assertLt(surgeOut, baseOut, "higher surge fee did not reduce output");
    }

    function test_exactInputSell_usesApproval_measuresSettlement_andPaysRecipient() public {
        uint256 bought = _routerBuy(bob, bob, 0.002 ether);
        uint128 amountIn = uint128(bought / 3);
        vm.prank(bob);
        token.approve(address(router), amountIn);
        HookrSwapRouter.ExactInputParams memory p = HookrSwapRouter.ExactInputParams({
            key: key,
            zeroForOne: false,
            amountIn: amountIn,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: MAX_LIMIT,
            recipient: alice,
            deadline: block.timestamp + 1
        });
        uint256 aliceBefore = alice.balance;
        uint256 bobTokensBefore = token.balanceOf(bob);
        vm.prank(bob);
        uint256 ethOut = router.exactInput(p);
        assertEq(alice.balance, aliceBefore + ethOut);
        assertEq(token.balanceOf(bob), bobTokensBefore - amountIn);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
    }

    function test_exactInputSell_withoutApprovalRevertsAndSettlesNothing() public {
        uint256 bought = _routerBuy(bob, bob, 0.001 ether);
        HookrSwapRouter.ExactInputParams memory p = HookrSwapRouter.ExactInputParams({
            key: key,
            zeroForOne: false,
            amountIn: uint128(bought / 4),
            amountOutMinimum: 1,
            sqrtPriceLimitX96: MAX_LIMIT,
            recipient: alice,
            deadline: block.timestamp + 1
        });
        uint256 beforeBalance = token.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(HookrSwapRouter.TransferFailed.selector);
        router.exactInput(p);
        assertEq(token.balanceOf(bob), beforeBalance);
    }

    function test_exactOutputBuy_enforcesMaxIn_andRefundsUnusedNative() public {
        uint128 desired = 1e18;
        uint128 maximum = 0.001 ether;
        HookrSwapRouter.ExactOutputParams memory p = HookrSwapRouter.ExactOutputParams({
            key: key,
            zeroForOne: true,
            amountOut: desired,
            amountInMaximum: maximum,
            sqrtPriceLimitX96: MIN_LIMIT,
            recipient: alice,
            deadline: block.timestamp + 1
        });
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = bob.balance;
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(bob);
        uint256 used = router.exactOutput{value: maximum}(p);
        assertLe(used, maximum);
        assertEq(bob.balance, bobBefore - used, "unused native maximum refunded");
        assertEq(token.balanceOf(alice), aliceBefore + desired);
        assertEq(token.balanceOf(DEAD), deadBefore, "exact-output buys do not auto-burn");
        assertEq(address(router).balance, 0);
    }

    function test_exactOutputBuy_revertsAboveMaxIn() public {
        HookrSwapRouter.ExactOutputParams memory p = HookrSwapRouter.ExactOutputParams({
            key: key,
            zeroForOne: true,
            amountOut: 1e18,
            amountInMaximum: 1,
            sqrtPriceLimitX96: MIN_LIMIT,
            recipient: alice,
            deadline: block.timestamp + 1
        });
        vm.prank(bob);
        vm.expectPartialRevert(HookrSwapRouter.TooMuchRequested.selector);
        router.exactOutput{value: 1}(p);
    }

    function test_exactOutputSell_enforcesTokenMaxIn_andPaysBoundRecipient() public {
        uint256 bought = _routerBuy(bob, bob, 0.002 ether);
        uint128 maximum = uint128(bought / 2);
        vm.prank(bob);
        token.approve(address(router), maximum);
        HookrSwapRouter.ExactOutputParams memory p = HookrSwapRouter.ExactOutputParams({
            key: key,
            zeroForOne: false,
            amountOut: 0.0001 ether,
            amountInMaximum: maximum,
            sqrtPriceLimitX96: MAX_LIMIT,
            recipient: alice,
            deadline: block.timestamp + 1
        });
        uint256 bobBefore = token.balanceOf(bob);
        uint256 aliceBefore = alice.balance;
        vm.prank(bob);
        uint256 used = router.exactOutput(p);
        assertLe(used, maximum);
        assertEq(token.balanceOf(bob), bobBefore - used);
        assertEq(alice.balance, aliceBefore + p.amountOut);
    }

    function test_deadlineRecipientNativeValueAndMalformedKey_failClosed() public {
        HookrSwapRouter.ExactInputParams memory p = _buyParams(0.001 ether, 1, alice);

        p.deadline = block.timestamp - 1;
        vm.prank(bob);
        vm.expectPartialRevert(HookrSwapRouter.DeadlineExpired.selector);
        router.exactInput{value: p.amountIn}(p);

        p.deadline = block.timestamp + 1;
        p.recipient = address(0);
        vm.prank(bob);
        vm.expectRevert(HookrSwapRouter.InvalidRecipient.selector);
        router.exactInput{value: p.amountIn}(p);

        p.recipient = alice;
        vm.prank(bob);
        vm.expectPartialRevert(HookrSwapRouter.InvalidNativeValue.selector);
        router.exactInput{value: p.amountIn - 1}(p);

        p.key.currency0 = Currency.wrap(address(token));
        vm.prank(bob);
        vm.expectRevert(HookrSwapRouter.InvalidPoolKey.selector);
        router.exactInput(p);

        p = _buyParams(0.001 ether, 1, alice);
        p.key.hooks = IHooks(address(0x1234));
        vm.prank(bob);
        vm.expectRevert(HookrSwapRouter.InvalidPoolKey.selector);
        router.exactInput{value: p.amountIn}(p);

        p = _buyParams(0.001 ether, 1, alice);
        p.key.fee = 3000;
        vm.prank(bob);
        vm.expectRevert(HookrSwapRouter.InvalidPoolKey.selector);
        router.exactInput{value: p.amountIn}(p);

        p = _buyParams(0.001 ether, 1, alice);
        p.key.tickSpacing = 30;
        vm.prank(bob);
        vm.expectRevert(HookrSwapRouter.InvalidPoolKey.selector);
        router.exactInput{value: p.amountIn}(p);
    }

    function test_partialNativeInput_atPriceLimit_refundsExactRemainder() public {
        (, PoolKey memory burnKey) = _graduateBurnOnly();
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(burnKey.toId());
        HookrSwapRouter.ExactInputParams memory p = HookrSwapRouter.ExactInputParams({
            key: burnKey,
            zeroForOne: true,
            amountIn: 0.01 ether,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: 0,
            recipient: alice,
            deadline: block.timestamp + 1
        });
        p.sqrtPriceLimitX96 = sqrtPriceX96 - (sqrtPriceX96 / 1_000_000);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        uint256 out = router.exactInput{value: p.amountIn}(p);
        uint256 used = bobBefore - bob.balance;
        assertGt(out, 0);
        assertGt(used, 0);
        assertLt(used, p.amountIn, "price limit left part of exact input unused");
        assertEq(address(router).balance, 0, "only this call's remainder was refunded");
    }

    function test_inputCutPool_rejectsPartialFillPriceLimit() public {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        HookrSwapRouter.ExactInputParams memory p = _buyParams(0.01 ether, 1, alice);
        p.sqrtPriceLimitX96 = sqrtPriceX96 - (sqrtPriceX96 / 1_000_000);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(HookrHook.PartialFillUnsupportedWithInputCuts.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.exactInput{value: p.amountIn}(p);
    }

    function test_inputCutPool_liquidityExhaustionRevertsAtomicallyWithoutFee() public {
        uint128 enormousInput = uint128(type(int128).max);
        PoolId id = key.toId();
        SwapParams memory rawParams = SwapParams({
            zeroForOne: true, amountSpecified: -int256(uint256(enormousInput)), sqrtPriceLimitX96: MIN_LIMIT
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        bytes memory expectedRevert = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(HookrHook.PartialFillUnsupportedWithInputCuts.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        (uint160 startingSqrtPriceX96,,,) = manager.getSlot0(id);
        uint160 lowerSqrtPriceX96 = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(key.tickSpacing));
        uint256 principalCapacity =
            SqrtPriceMath.getAmount0Delta(lowerSqrtPriceX96, startingSqrtPriceX96, manager.getLiquidity(id), false);
        // Add headroom for LP fees: raw input consumed by the pool includes fees while the
        // principal-capacity formula does not. The asserted cap keeps this regression bounded.
        uint256 maxAttempts = (principalCapacity / uint256(enormousInput)) + 16;
        assertLt(maxAttempts, 512, "unexpectedly large exhaustion regression");
        bool exhausted;
        uint256 completed;
        for (uint256 i = 0; i < maxAttempts; i++) {
            uint256 potBefore = hook.potWei(id);
            uint256 claimsBefore = hook.nativeClaimBalance();
            uint256 deadBefore = token.balanceOf(DEAD);
            uint256 feesBefore = hook.totalHookFeesWei(id);
            vm.deal(bob, enormousInput);
            vm.prank(bob);
            (bool ok, bytes memory reason) = address(rawRouter).call{value: enormousInput}(
                abi.encodeCall(PoolSwapTest.swap, (key, rawParams, settings, abi.encode(alice)))
            );
            if (!ok) {
                assertEq(reason, expectedRevert, "liquidity boundary returned unexpected error");
                assertEq(hook.potWei(id), potBefore, "partial fill did not fund pot");
                assertEq(hook.nativeClaimBalance(), claimsBefore, "partial fill minted no claim");
                assertEq(token.balanceOf(DEAD), deadBefore, "partial fill burned no output");
                assertEq(hook.totalHookFeesWei(id), feesBefore, "partial fill accrued no hook fee");
                exhausted = true;
                break;
            }
            completed++;
            vm.roll(vm.getBlockNumber() + 1);
        }
        assertGt(completed, 0, "test must first consume real in-range liquidity");
        assertTrue(exhausted, "bounded input type must reach the finite POL boundary");
    }

    function test_refundCallbackCannotReenter_andDirectCallbackIsRejected() public {
        vm.expectRevert(HookrSwapRouter.NotPoolManager.selector);
        router.unlockCallback("");

        (, PoolKey memory burnKey) = _graduateBurnOnly();
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(burnKey.toId());
        HookrSwapRouter.ExactInputParams memory p = HookrSwapRouter.ExactInputParams({
            key: burnKey,
            zeroForOne: true,
            amountIn: 0.01 ether,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: 0,
            recipient: alice,
            deadline: block.timestamp + 1
        });
        p.sqrtPriceLimitX96 = sqrtPriceX96 - (sqrtPriceX96 / 1_000_000);
        ReenteringRefundPayer attacker = new ReenteringRefundPayer();
        attacker.execute{value: p.amountIn}(router, p);
        assertTrue(attacker.attempted(), "native refund invoked payer fallback");
        assertEq(attacker.observedSelector(), HookrSwapRouter.Reentrancy.selector);
    }
}
