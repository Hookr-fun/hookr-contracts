// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrQuoter} from "../../src/interfaces/IHookrQuoter.sol";
import {IHookrSwapGate} from "../../src/interfaces/IHookrSwapGate.sol";
import {IHookrFamilyRouter} from "../../src/interfaces/IHookrFamilyRouter.sol";
import {IHookrLauncherView} from "../../src/interfaces/IHookrLauncherView.sol";
import {HookrFamilyRouter} from "../../src/periphery/HookrFamilyRouter.sol";
import {ReferenceLP} from "../utils/ReferenceLP.sol";
import {HookrQuoter} from "../../src/lens/HookrQuoter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {FixedAdvice} from "../utils/FixedAdvice.sol";
import {GasBenchFixture, IUniversalRouter, IPermit2Bench} from "../utils/GasBenchFixture.sol";
import {ReleaseWiring} from "../utils/ReleaseWiring.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @dev A direct PoolManager locker that passes its own hook data with the swap, the way a quote-mode flag would
///      travel.
contract HookDataLocker is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData) external {
        manager.unlock(abi.encode(key, params, hookData));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, SwapParams memory params, bytes memory hookData) =
            abi.decode(data, (PoolKey, SwapParams, bytes));
        manager.swap(key, params, hookData);
        return "";
    }
}

/// @dev An admitted advisory that reverts every swap with `forged`, a payload shaped as a quote's own result.
contract ForgingAdvice is IHookrAdvisory {
    bytes internal forged;

    constructor(bytes memory forged_) {
        forged = forged_;
    }

    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("test.forging.advice");
    }

    function bind(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata data)
        external
        pure
        returns (bytes32)
    {
        return keccak256(data);
    }

    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    function beforeSwap(HookrTypes.SwapContext calldata) external view returns (HookrTypes.Advice memory) {
        _forge();
    }

    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        view
        returns (HookrTypes.Advice memory)
    {
        _forge();
    }

    function _forge() internal view {
        bytes memory f = forged;
        assembly ("memory-safe") {
            revert(add(f, 32), mload(f))
        }
    }
}

/// @dev An admitted gate that vouches for every swap and keeps the data it was handed, the way a quote-mode flag would
///      travel through a gated swap.
contract QuoteModeGate is IHookrSwapGate {
    bytes public lastData;

    function beforeUnlock(address, address, PoolKey calldata, bool, int256, bytes calldata data)
        external
        returns (bytes4)
    {
        lastData = data;
        return IHookrSwapGate.beforeUnlock.selector;
    }
}

/// @notice HookrQuoter's aggregator quote mode on the real 4663 PoolManager, Universal Router 2.1.1 and Permit2
///         runtimes: Uniswap IV4Quoter's single-pool shape and the detailed quote equal HookrRouter's execution to the
///         wei in every shape on a plain pool, a dynamic fee pool and an advised pool; the single-pool shape quoted
///         from the Universal Router's address equals a Universal Router execution; a quote leaves no state; the frame's
///         helpers refuse outside a quote; and the root has no quote mode, so a locker's hook data is refused, a gated
///         swap's data reaches only its gate and a family trade's legs carry none. The lane pool cases, where both arb
///         recapture phases run, are test/lane/QuoterAggregatorModeLane.t.sol.
contract QuoterAggregatorModeTest is GasBenchFixture {
    using PoolIdLibrary for PoolKey;
    using stdJson for string;

    struct PathKey {
        Currency intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        IHooks hooks;
        bytes hookData;
    }

    struct ExactOutputParams {
        Currency currencyOut;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountOut;
        uint128 amountInMaximum;
    }

    /// @dev One quote shape on one pool.
    struct Shape {
        PoolKey key;
        bool buy;
        bool exactInput;
        uint128 amount;
    }

    /// @dev What the quotes and the execution of one shape returned.
    struct Observed {
        HookrTypes.ExecutionReceipt receipt;
        uint256 claim;
        uint256 detailedGas;
        uint256 single;
        uint256 singleGas;
        uint256 amountIn;
        uint256 amountOut;
        uint256 executionGas;
    }

    address internal constant ADVISORY_RECIPIENT = address(0xADD5);

    FixedAdvice internal advice;
    PoolKey internal advisedKey;

    function setUp() public override {
        super.setUp();
        advice = new FixedAdvice(
            HookrTypes.Advice(500, 1000, ADVISORY_RECIPIENT, false),
            HookrTypes.Advice(0, 0, address(0), false),
            false,
            false
        );
        _admitAdvisory(address(advice));
        advisedKey = _launchAdvised(address(advice), Currency.wrap(address(quotes[0])));
        quotes[0].transfer(trader, 1e27);
        vm.startPrank(trader);
        quotes[0].approve(address(router), type(uint256).max);
        quotes[0].approve(permit2, type(uint256).max);
        IPermit2Bench(permit2).approve(address(quotes[0]), ur, type(uint160).max, type(uint48).max);
        vm.stopPrank();
        _warm(feeKey);
        _warmAgain(fullKey, 2);
        _routerSwap(advisedKey, true, 1e21);
        _nextBlock();
    }

    /// @dev GasBenchFixture._warm with its own relayed-intent nonce, for a second pool in one setUp.
    function _warmAgain(PoolKey memory key, uint256 nonce) internal {
        _routerSwap(key, true, 1e21);
        _nextBlock();
        _routerSwap(key, false, 5e20);
        _nextBlock();
        _relayed(key, true, 1e20, nonce);
        _nextBlock();
    }

    /// @dev Admits `impl` on the root as an advisory with a quote take.
    function _admitAdvisory(address impl) internal {
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: impl,
            codeHash: impl.codehash,
            schemaHash: IHookrAdvisory(impl).configSchemaHash(),
            caps: HookrTypes.Caps(10_000, 20_000, 0),
            gasLimit: 200_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    /// @dev A fee-only member of `quote` with the advisory `impl` in both phases; with the fixture's advisory, a
    ///      500-pip LP surcharge and a 1,000-pip quote take credited to ADVISORY_RECIPIENT before the swap.
    function _launchAdvised(address impl, Currency quote) internal returns (PoolKey memory) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(quote, 60, false);
        members[0].config.advisory = impl;
        members[0].config.advisoryGasLimit = 200_000;
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP | HookrTypes.AFTER_SWAP;
        bytes[] memory configs = new bytes[](1);
        configs[0] = hex"01";
        (bytes32 family,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        );
        return launcher.position(family, 0).key;
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev Shape `c` of four on `key`: bit 0 a sell, bit 1 an exact output.
    function _shape(PoolKey memory key, uint256 c, uint128 amount) internal pure returns (Shape memory) {
        return Shape(key, c & 1 == 0, c & 2 == 0, amount);
    }

    /// @dev The router-shaped swap of the shape for the trader, with no bound that binds and no price limit.
    function _swapOf(Shape memory s) internal view returns (IHookrRouter.Swap memory p) {
        p = _params(s.key, s.buy, s.amount);
        if (!s.exactInput) {
            p.amountSpecified = int128(s.amount);
            p.amountBound = type(uint128).max;
        }
    }

    function _single(Shape memory s) internal view returns (IHookrQuoter.QuoteExactSingleParams memory) {
        return IHookrQuoter.QuoteExactSingleParams(s.key, _zeroForOne(s.key, s.buy), s.amount, "");
    }

    /// @dev Uniswap's V4Quoter shape from `from`: the output of an exact input or the input of an exact output.
    function _v4(address from, Shape memory s) internal returns (uint256 amount, uint256 gasEstimate) {
        vm.prank(from);
        return s.exactInput ? quoter.quoteExactInputSingle(_single(s)) : quoter.quoteExactOutputSingle(_single(s));
    }

    /// @dev The detailed quote, `quote` and the V4Quoter shape from the trader, then the trader's router execution, all
    ///      at one state; `quote` must return the detailed quote's receipt.
    function _observe(Shape memory s) internal returns (Observed memory o) {
        IHookrRouter.Swap memory p = _swapOf(s);
        (o.receipt, o.claim, o.detailedGas) = quoter.quoteDetailed(p, trader);
        assertEq(keccak256(abi.encode(quoter.quote(p, trader))), keccak256(abi.encode(o.receipt)), "one receipt");
        (o.single, o.singleGas) = _v4(trader, s);
        vm.prank(trader);
        (o.amountIn, o.amountOut) = router.swap(p, address(0), new uint256[](0));
        o.executionGas = vm.lastCallGas().gasTotalUsed;
    }

    /// @dev Shape `c` on `key` equals execution to the wei; logs its gasEstimate beside execution's gas.
    function _compareShape(PoolKey memory key, string memory label, uint256 c, uint128 amount) internal {
        Shape memory s = _shape(key, c, amount);
        uint256 snap = vm.snapshotState();
        Observed memory o = _observe(s);
        assertEq(o.receipt.inputAmount, o.amountIn, "quoted input");
        assertEq(o.receipt.outputAmount, o.amountOut, "quoted output");
        assertEq(o.single, s.exactInput ? o.amountOut : o.amountIn, "V4Quoter shape");
        assertEq(o.claim, 0, "no arb recapture lane, no trader claim");
        assertEq(o.receipt.payer, trader);
        assertEq(o.receipt.beneficiary, trader);
        assertGt(o.singleGas, 0);
        assertGt(o.detailedGas, o.singleGas, "the detailed quote also reads the claim");
        console2.log(label, s.buy ? "buy" : "sell", s.exactInput ? "exact in" : "exact out");
        console2.log("  gasEstimate detailed, single; router execution", o.detailedGas, o.singleGas, o.executionGas);
        vm.revertToState(snap);
    }

    function _compareAllShapes(PoolKey memory key, string memory label, uint128 amount) internal {
        for (uint256 c; c < 4; ++c) {
            _compareShape(key, label, c, amount);
        }
    }

    /// @dev The Universal Router 2.1.1 V4_SWAP inputs: SWAP_EXACT_IN_SINGLE, or a one-hop SWAP_EXACT_OUT with
    ///      `maxIn`, settled and taken in full.
    function _urInputs(Shape memory s, uint128 maxIn)
        internal
        view
        returns (bytes[] memory inputs, Currency input, Currency output)
    {
        bool zeroForOne = _zeroForOne(s.key, s.buy);
        (input, output) = zeroForOne ? (s.key.currency0, s.key.currency1) : (s.key.currency1, s.key.currency0);
        bytes[] memory params = new bytes[](3);
        bytes memory actions;
        if (s.exactInput) {
            actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
            params[0] = abi.encode(ExactInputSingleParams(s.key, zeroForOne, s.amount, 1, 0, ""));
            params[1] = abi.encode(input, uint256(s.amount));
            params[2] = abi.encode(output, uint256(1));
        } else {
            actions = abi.encodePacked(uint8(0x09), uint8(0x0c), uint8(0x0f));
            PathKey[] memory path = new PathKey[](1);
            path[0] = PathKey(input, s.key.fee, s.key.tickSpacing, s.key.hooks, "");
            params[0] = abi.encode(ExactOutputParams(output, path, new uint256[](0), s.amount, maxIn));
            params[1] = abi.encode(input, uint256(maxIn));
            params[2] = abi.encode(output, uint256(s.amount));
        }
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    /// @dev Executes the shape through the Universal Router as the trader; returns what the trader paid and received.
    function _urExecute(Shape memory s, uint128 maxIn) internal returns (uint256 paid, uint256 received) {
        (bytes[] memory inputs, Currency input, Currency output) = _urInputs(s, maxIn);
        HookrToken tokenIn = HookrToken(Currency.unwrap(input));
        HookrToken tokenOut = HookrToken(Currency.unwrap(output));
        uint256 inBefore = tokenIn.balanceOf(trader);
        uint256 outBefore = tokenOut.balanceOf(trader);
        vm.prank(trader, trader);
        IUniversalRouter(ur).execute(hex"10", inputs, vm.getBlockTimestamp() + 1000);
        paid = inBefore - tokenIn.balanceOf(trader);
        received = tokenOut.balanceOf(trader) - outBefore;
    }

    /// @dev Shape `c` quoted from the Universal Router's address equals its execution through the Universal Router.
    function _urCase(PoolKey memory key, uint256 c, uint128 amount) internal {
        Shape memory s = _shape(key, c, amount);
        uint256 snap = vm.snapshotState();
        (uint256 quoted,) = _v4(ur, s);
        (uint256 paid, uint256 received) = _urExecute(s, s.exactInput ? 0 : uint128(quoted));
        if (s.exactInput) {
            assertEq(paid, s.amount, "the whole input");
            assertEq(received, quoted, "Universal Router output equals the quote");
        } else {
            assertEq(received, s.amount, "the whole output");
            assertEq(paid, quoted, "Universal Router input equals the quote");
        }
        vm.revertToState(snap);
    }

    function _wrapped(bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(root),
            IHooks.beforeSwap.selector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev The selector of `signature` in HookrQuoter's compiled artifact equals `pinned`, its keccak and `declared`.
    function _checkSelector(string memory artifact, string memory signature, bytes4 pinned, bytes4 declared)
        internal
        pure
    {
        string memory hexSelector = artifact.readString(string.concat(".methodIdentifiers.['", signature, "']"));
        assertEq(vm.parseBytes(hexSelector), abi.encodePacked(pinned), signature);
        assertEq(bytes4(keccak256(bytes(signature))), pinned, signature);
        assertEq(declared, pinned, signature);
    }

    /// @dev No storage write in `accesses` outlived its frame, no call moved value, and at least one write was
    ///      reverted (the simulated swap's).
    function _assertNoSurvivingWrite(Vm.AccountAccess[] memory accesses) internal pure {
        uint256 reverted;
        for (uint256 i; i < accesses.length; ++i) {
            Vm.AccountAccess memory a = accesses[i];
            if (!a.reverted) assertEq(a.value, 0, "no value moved");
            for (uint256 j; j < a.storageAccesses.length; ++j) {
                Vm.StorageAccess memory w = a.storageAccesses[j];
                if (!w.isWrite) continue;
                if (w.reverted) {
                    ++reverted;
                } else {
                    assertEq(w.newValue, w.previousValue, "a storage write survived a quote");
                }
            }
        }
        assertGt(reverted, 0, "the simulated swap wrote state that its frame reverted");
    }

    // ───────────────────────────── the surface ─────────────────────────────

    /// The aggregator functions keep Uniswap IV4Quoter's selectors, read from the compiled artifact; `quote`,
    /// `simulate` and `unlockCallback` keep theirs; IHookrQuoter declares every function HookrQuoter has.
    function test_selectorsAreTheArtifactsAndUniswapsAndQuoteKeepsItsOwn() public view {
        string memory artifact = vm.readFile("out/HookrQuoter.sol/HookrQuoter.json");
        _checkSelector(
            artifact,
            "quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))",
            0xaa9d21cb,
            IHookrQuoter.quoteExactInputSingle.selector
        );
        _checkSelector(
            artifact,
            "quoteExactOutputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))",
            0x58733073,
            IHookrQuoter.quoteExactOutputSingle.selector
        );
        _checkSelector(
            artifact,
            "quote(((address,address,uint24,int24,address),bool,int128,uint128,uint160,address,uint256),address)",
            0x55f5bdd3,
            IHookrQuoter.quote.selector
        );
        _checkSelector(
            artifact,
            "quoteDetailed(((address,address,uint24,int24,address),bool,int128,uint128,uint160,address,uint256),address)",
            0x3d8d5b2a,
            IHookrQuoter.quoteDetailed.selector
        );
        _checkSelector(
            artifact,
            "simulate((((address,address,uint24,int24,address),bool,int128,uint128,uint160,address,uint256),address))",
            0x74d3cd90,
            IHookrQuoter.simulate.selector
        );
        _checkSelector(artifact, "unlockCallback(bytes)", 0x91dd7346, IUnlockCallback.unlockCallback.selector);
        assertEq(HookrQuoter.quoteExactInputSingle.selector, IHookrQuoter.quoteExactInputSingle.selector);
        assertEq(HookrQuoter.quote.selector, IHookrQuoter.quote.selector);
        assertEq(IHookrQuoter.NotEnoughLiquidity.selector, bytes4(keccak256("NotEnoughLiquidity(bytes32)")));
        assertEq(
            IHookrQuoter.InvalidHookData.selector, IHookrRootEvents.InvalidHookData.selector, "the root's own error"
        );
    }

    // ───────────────────────────── (1) quotes equal execution ─────────────────────────────

    /// A plain (fee-only) pool: every shape equals execution to the wei.
    function test_plainPoolEveryShapeEqualsRouterExecution() public {
        _compareAllShapes(feeKey, "plain", 3e21);
    }

    /// A dynamic fee pool with Auto Burn, LP Rewards and a royalty: every shape equals execution, dynamic fee included.
    function test_dynamicFeePoolEveryShapeEqualsRouterExecution() public {
        _compareAllShapes(fullKey, "dynamic fee", 3e22);
    }

    /// An advised pool (a 500-pip LP surcharge and a 1,000-pip quote take): every shape equals execution, and the
    /// advisory's take is the advisory recipient's claim, never the trader's.
    function test_advisedPoolEveryShapeEqualsRouterExecution() public {
        _compareAllShapes(advisedKey, "advised", 3e21);
        Currency quote = Currency.wrap(address(quotes[0]));
        uint256 before = rules.claimable(quote, ADVISORY_RECIPIENT);
        (HookrTypes.ExecutionReceipt memory r, uint256 claim,) =
            quoter.quoteDetailed(_swapOf(_shape(advisedKey, 0, 3e21)), trader);
        _routerSwap(advisedKey, true, 3e21);
        assertGt(rules.claimable(quote, ADVISORY_RECIPIENT) - before, 0, "the advisory's take is its recipient's claim");
        assertGt(r.quoteFee, 0);
        assertEq(claim, 0);
    }

    /// The trader claim of a detailed quote is the payer's claim rise less its refund: a payer that is also a fee
    /// recipient sees its own fee share there (here the advisory recipient quoting its own buy), as its claim rises by
    /// it in execution.
    function test_aPayerThatIsAFeeRecipientSeesItsShareInTheClaim() public {
        Currency quote = Currency.wrap(address(quotes[0]));
        quotes[0].transfer(ADVISORY_RECIPIENT, 1e24);
        vm.prank(ADVISORY_RECIPIENT);
        quotes[0].approve(address(router), type(uint256).max);
        IHookrRouter.Swap memory p = _swapOf(_shape(advisedKey, 0, 3e21));
        p.recipient = ADVISORY_RECIPIENT;
        (, uint256 claim,) = quoter.quoteDetailed(p, ADVISORY_RECIPIENT);
        uint256 before = rules.claimable(quote, ADVISORY_RECIPIENT);
        vm.prank(ADVISORY_RECIPIENT);
        router.swap(p, address(0), new uint256[](0));
        assertGt(claim, 0);
        assertEq(rules.claimable(quote, ADVISORY_RECIPIENT) - before, claim);
    }

    /// The V4Quoter shape quoted from the Universal Router's address (the address that locks the PoolManager there)
    /// equals a Universal Router execution, for full fills, in all four shapes on the plain and the dynamic fee pool.
    function test_singleQuoteFromTheUniversalRouterEqualsItsExecution() public {
        for (uint256 c; c < 4; ++c) {
            _urCase(feeKey, c, 2e21);
            _urCase(fullKey, c, 2e22);
        }
    }

    /// A partial fill: the single-pool exact input refuses it as Uniswap's V4Quoter does, while `quote` and
    /// `quoteDetailed` report the partial fill HookrRouter makes, its refund credited to the payer as a claim and kept
    /// out of the trader claim.
    function test_partialFillIsNotEnoughLiquidityForTheSingleShape() public {
        Shape memory s = _shape(fullKey, 0, 1e26);
        vm.expectRevert(abi.encodeWithSelector(IHookrQuoter.NotEnoughLiquidity.selector, fullKey.toId()));
        _v4(trader, s);
        IHookrRouter.Swap memory p = _swapOf(s);
        (HookrTypes.ExecutionReceipt memory r, uint256 claim,) = quoter.quoteDetailed(p, trader);
        assertLt(r.inputAmount, s.amount, "a partial fill");
        assertGt(r.quoteRefund, 0, "the unused reserved take is refunded");
        assertEq(claim, 0, "the refund is not a trader claim");
        Currency quote = Currency.wrap(address(quoteFull));
        uint256 before = rules.claimable(quote, trader);
        vm.prank(trader);
        (uint256 amountIn, uint256 amountOut) = router.swap(p, address(0), new uint256[](0));
        assertEq(amountIn, r.inputAmount);
        assertEq(amountOut, r.outputAmount);
        assertEq(rules.claimable(quote, trader) - before, r.quoteRefund, "execution credits the refund as a claim");
    }

    /// An exact output the pool cannot deliver reverts in the single shape, as the router's swap does.
    function test_exactOutputBeyondTheLiquidityReverts() public {
        Shape memory s = _shape(feeKey, 3, 1e26);
        vm.expectRevert();
        _v4(trader, s);
        vm.prank(trader);
        vm.expectRevert();
        router.swap(_swapOf(s), address(0), new uint256[](0));
    }

    // ───────────────────────────── (3) no state, and the frame ─────────────────────────────

    /// Every quote shape leaves every account's storage and balances as they were (no storage write outside a reverted
    /// frame, no value moved) and the quoter's frame back at idle.
    function test_aQuoteLeavesNoState() public {
        PoolKey[3] memory keys = [feeKey, fullKey, advisedKey];
        for (uint256 k; k < 3; ++k) {
            vm.startStateDiffRecording();
            quoter.quote(_swapOf(_shape(keys[k], 0, 3e21)), trader);
            quoter.quoteDetailed(_swapOf(_shape(keys[k], 3, 1e21)), trader);
            _v4(trader, _shape(keys[k], 2, 1e21));
            _v4(ur, _shape(keys[k], 1, 3e21));
            _assertNoSurvivingWrite(vm.stopAndReturnStateDiff());
        }
        assertGt(quoter.quote(_swapOf(_shape(feeKey, 0, 1e21)), trader).outputAmount, 0, "the frame is idle again");
    }

    /// The frame's helpers refuse every call outside a quote's own frame.
    function test_unlockCallbackAndSimulateRefuseOutsideTheFrame() public {
        IHookrQuoter.Request memory request = IHookrQuoter.Request(_swapOf(_shape(feeKey, 0, 1e21)), trader);
        vm.expectRevert(IHookrQuoter.InvalidCallback.selector);
        quoter.simulate(request);
        vm.prank(address(quoter));
        vm.expectRevert(IHookrQuoter.InvalidCallback.selector);
        quoter.simulate(request);
        vm.prank(address(manager));
        vm.expectRevert(IHookrQuoter.InvalidCallback.selector);
        quoter.unlockCallback(abi.encode(request));
        vm.expectRevert(IHookrQuoter.InvalidCallback.selector);
        quoter.unlockCallback(abi.encode(request));
    }

    /// A module that reverts with a payload shaped as a detailed result cannot forge one: every failure inside the
    /// simulation leaves the frame wrapped in SimulationFailed, in the detailed and the single-pool shapes alike.
    function test_aForgedDetailedResultIsRejected() public {
        HookrTypes.ExecutionReceipt memory fake;
        fake.payer = trader;
        fake.inputAmount = 1;
        fake.outputAmount = type(uint128).max;
        bytes memory forged = abi.encodeWithSelector(IHookrQuoter.QuoteDetail.selector, fake, uint256(1e30));
        ForgingAdvice forger = new ForgingAdvice(forged);
        _admitAdvisory(address(forger));
        Shape memory s = _shape(_launchAdvised(address(forger), Currency.wrap(address(quotes[1]))), 0, 1e18);
        (bool ok, bytes memory reason) =
            address(quoter).call(abi.encodeCall(IHookrQuoter.quoteDetailed, (_swapOf(s), trader)));
        assertFalse(ok);
        assertEq(bytes4(reason), IHookrQuoter.SimulationFailed.selector);
        assertNotEq(keccak256(reason), keccak256(forged));
        vm.prank(trader);
        (ok, reason) = address(quoter).call(abi.encodeCall(IHookrQuoter.quoteExactInputSingle, (_single(s))));
        assertFalse(ok);
        assertEq(bytes4(reason), IHookrQuoter.SimulationFailed.selector);
    }

    /// The single-pool shape refuses hook data (there is no flag), whatever its encoding.
    function test_singleShapeRefusesHookData() public {
        bytes[3] memory flags = [bytes(hex"01"), abi.encode(true), abi.encode(keccak256("hookr.quote.mode"))];
        for (uint256 i; i < 3; ++i) {
            IHookrQuoter.QuoteExactSingleParams memory s = _single(_shape(feeKey, 0, 1e21));
            s.hookData = flags[i];
            vm.expectRevert(IHookrQuoter.InvalidHookData.selector);
            quoter.quoteExactInputSingle(s);
            vm.expectRevert(IHookrQuoter.InvalidHookData.selector);
            quoter.quoteExactOutputSingle(s);
        }
    }

    /// The single-pool shape refuses a zero amount, an amount above int128's maximum, a pool that is not a known pool
    /// of a registered root pinning this quoter, and a caller the root's router could never pay (the router itself,
    /// its forwarder, the PoolManager); int128's maximum itself is quoted.
    function test_singleShapeRefusesWhatTheRouterWould() public {
        vm.expectRevert(IHookrQuoter.InvalidQuote.selector);
        quoter.quoteExactInputSingle(_single(_shape(feeKey, 0, 0)));
        vm.expectRevert(IHookrQuoter.InvalidQuote.selector);
        quoter.quoteExactOutputSingle(_single(_shape(feeKey, 2, uint128(type(int128).max) + 1)));
        PoolKey memory unknown = feeKey;
        unknown.tickSpacing = 1;
        vm.expectRevert(IHookrQuoter.InvalidQuote.selector);
        quoter.quoteExactInputSingle(_single(_shape(unknown, 0, 1e21)));
        PoolKey memory hookless = feeKey;
        hookless.hooks = IHooks(address(0));
        vm.expectRevert(IHookrQuoter.InvalidQuote.selector);
        quoter.quoteExactInputSingle(_single(_shape(hookless, 0, 1e21)));
        address[3] memory unpayable = [address(router), address(fwd), address(manager)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(unpayable[i]);
            vm.expectRevert(IHookrQuoter.InvalidQuote.selector);
            quoter.quoteExactInputSingle(_single(_shape(feeKey, 0, 1e21)));
        }
        vm.expectRevert(abi.encodeWithSelector(IHookrQuoter.NotEnoughLiquidity.selector, feeKey.toId()));
        _v4(trader, _shape(feeKey, 0, uint128(type(int128).max)));
    }

    // ───────────────────────────── (4) the root has no quote mode ─────────────────────────────

    /// A direct PoolManager locker carrying hook data, whatever its encoding (a flag byte, a true word, a tagged word),
    /// is refused by the root with InvalidHookData before any charge, so no executing swap can signal a quote mode;
    /// with empty hook data the same locker reaches the swap.
    function test_aLockersQuoteFlagIsRefusedByTheRoot() public {
        HookDataLocker locker = new HookDataLocker(manager);
        bool zeroForOne = _zeroForOne(feeKey, true);
        SwapParams memory params = SwapParams(zeroForOne, -1e20, zeroForOne ? MIN_PRICE : MAX_PRICE);
        bytes[3] memory flags = [bytes(hex"01"), abi.encode(true), abi.encode(keccak256("hookr.quote.mode"))];
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(_wrapped(abi.encodeWithSelector(IHookrRootEvents.InvalidHookData.selector)));
            locker.swap(feeKey, params, flags[i]);
        }
        // Without hook data the swap runs and the locker then owes the PoolManager its input.
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        locker.swap(feeKey, params, "");
    }

    /// The Universal Router passes a route's hook data to the hook: a quote-mode flag there is refused the same way, so
    /// an aggregator's executing route cannot carry one either.
    function test_aUniversalRouterRoutesQuoteFlagIsRefusedByTheRoot() public {
        Shape memory s = _shape(feeKey, 0, 1e21);
        bool zeroForOne = _zeroForOne(s.key, s.buy);
        (Currency input, Currency output) =
            zeroForOne ? (s.key.currency0, s.key.currency1) : (s.key.currency1, s.key.currency0);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(s.key, zeroForOne, s.amount, 1, 0, hex"01"));
        params[1] = abi.encode(input, uint256(s.amount));
        params[2] = abi.encode(output, uint256(1));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params);
        vm.prank(trader, trader);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(IHookrRootEvents.InvalidHookData.selector)));
        IUniversalRouter(ur).execute(hex"10", inputs, vm.getBlockTimestamp() + 1000);
        // The same route without hook data executes.
        (, uint256 received) = _urExecute(s, 0);
        assertGt(received, 0);
    }

    /// HookrRouter.swapGated carries its data to the gate only: whatever flag the data holds, the root receives the
    /// router's own hook data, and the gated swap equals the detailed quote for its payer and a plain swap to the wei.
    function test_aGatedSwapsDataNeverReachesTheRoot() public {
        QuoteModeGate gate = new QuoteModeGate();
        ReleaseWiring.admitAfterDelay(registry, address(root), ReleaseWiring.gateAdmission(address(gate), 200_000));
        bytes[3] memory flags = [bytes(hex"01"), abi.encode(true), abi.encode(keccak256("hookr.quote.mode"))];
        PoolKey[2] memory keys = [feeKey, fullKey];
        for (uint256 k; k < 2; ++k) {
            for (uint256 i; i < 3; ++i) {
                IHookrRouter.Swap memory p = _swapOf(_shape(keys[k], i % 2, 1e21));
                (HookrTypes.ExecutionReceipt memory quoted,,) = quoter.quoteDetailed(p, trader);
                uint256 snap = vm.snapshotState();
                vm.prank(trader);
                (uint256 plainIn, uint256 plainOut) = router.swap(p, address(0), new uint256[](0));
                vm.revertToState(snap);
                vm.prank(trader);
                (uint256 amountIn, uint256 amountOut) =
                    router.swapGated(p, trader, address(gate), flags[i], address(0), new uint256[](0));
                assertEq(gate.lastData(), flags[i], "the gate saw the data");
                assertEq(amountIn, quoted.inputAmount, "quoted input");
                assertEq(amountOut, quoted.outputAmount, "quoted output");
                assertEq(amountIn, plainIn);
                assertEq(amountOut, plainOut);
                _nextBlock();
            }
        }
    }

    /// HookrFamilyRouter passes no data to its legs' gated swaps, so no leg can carry a quote mode: on a two-member
    /// family bought in one quote, one leg direct and one converting through a hookless pool, every member swap equals
    /// the detailed quote for the trader of the same input (a leg's conversion moves only its own hookless pool).
    function test_aFamilyTradesLegsEqualTheirQuotes() public {
        HookrFamilyRouter fam = new HookrFamilyRouter(router, IHookrLauncherView(address(launcher)), permit2);
        ReleaseWiring.admitAfterDelay(registry, address(root), ReleaseWiring.gateAdmission(address(fam), 100_000));
        HookrToken famSubject = new HookrToken("Family", "FAM", 1e30, address(this));
        famSubject.approve(address(launcher), type(uint256).max);
        (HookrToken q3, HookrToken q4) = (quotes[3], quotes[4]);
        IHookrLauncher.Member[] memory m = new IHookrLauncher.Member[](2);
        m[0] = _member(Currency.wrap(address(q3)), 60, true);
        m[1] = _member(Currency.wrap(address(q4)), 60, false);
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(address(famSubject), "", "", 0, bytes32(0)), address(root), m, vm.getBlockTimestamp()
        );
        PoolKey[2] memory members = [launcher.position(family, 0).key, launcher.position(family, 1).key];
        (Currency c0, Currency c1) = address(q3) < address(q4)
            ? (Currency.wrap(address(q3)), Currency.wrap(address(q4)))
            : (Currency.wrap(address(q4)), Currency.wrap(address(q3)));
        PoolKey memory conversion = PoolKey(c0, c1, 3000, 60, IHooks(address(0)));
        ReferenceLP lp = new ReferenceLP(manager);
        q3.transfer(address(lp), 1e25);
        q4.transfer(address(lp), 1e25);
        manager.initialize(conversion, SQRT_ONE);
        lp.modify(conversion, -60_000, 60_000, 1e24);
        q3.transfer(trader, 1e24);
        vm.prank(trader);
        q3.approve(address(fam), type(uint256).max);
        _nextBlock();

        IHookrFamilyRouter.FamilyTrade memory t;
        t.familyId = family;
        t.input = Currency.wrap(address(q3));
        t.output = Currency.wrap(address(famSubject));
        t.legs = new IHookrFamilyRouter.Leg[](2);
        t.legs[0].key = members[0];
        t.legs[0].amountIn = 3e20;
        t.legs[0].minOut = 1;
        t.legs[1].key = members[1];
        t.legs[1].conversion = conversion;
        t.legs[1].amountIn = 2e20;
        t.legs[1].minOut = 1;
        t.recipient = trader;
        t.deadline = vm.getBlockTimestamp() + 1000;
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(trader);
        fam.trade(t, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Each member swap's amounts as HookrRouter executed them for the trader (SwapExecuted): the PoolManager's own
        // Swap event leaves out what the root takes around the pool's swap.
        uint256[2] memory input;
        uint256[2] memory output;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != IHookrRouter.SwapExecuted.selector) {
                continue;
            }
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(trader))), "every member swap is the trader's");
            for (uint256 k; k < 2; ++k) {
                if (logs[i].topics[1] != PoolId.unwrap(members[k].toId())) continue;
                (input[k], output[k]) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        assertEq(input[0], 3e20, "the direct leg swapped its whole input");
        assertGt(input[1], 0, "the converting leg swapped what its conversion delivered");
        vm.revertToState(snap);
        for (uint256 k; k < 2; ++k) {
            PoolKey memory key = members[k];
            bool zeroForOne = Currency.unwrap(key.currency0) != address(famSubject);
            IHookrRouter.Swap memory p = IHookrRouter.Swap(
                key,
                zeroForOne,
                -int128(int256(input[k])),
                1,
                zeroForOne ? MIN_PRICE : MAX_PRICE,
                trader,
                vm.getBlockTimestamp() + 1000
            );
            (HookrTypes.ExecutionReceipt memory quoted,,) = quoter.quoteDetailed(p, trader);
            assertEq(quoted.inputAmount, input[k], "quoted input");
            assertEq(quoted.outputAmount, output[k], "quoted output");
        }
    }
}
