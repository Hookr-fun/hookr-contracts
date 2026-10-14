// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {GasBenchFixture} from "../utils/GasBenchFixture.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";

/// @notice Advisory that never advises anything.
contract ZeroAdvice is IHookrAdvisory {
    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("test.zero.advice");
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

    function beforeSwap(HookrTypes.SwapContext calldata) external pure returns (HookrTypes.Advice memory a) {}

    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory a)
    {}
}

/// @notice Advisory whose advice and failure the test sets between swaps.
contract SettableAdvice is IHookrAdvisory {
    HookrTypes.Advice private _before;
    HookrTypes.Advice private _after;
    bool private _fail;

    function set(HookrTypes.Advice memory before_, HookrTypes.Advice memory after_, bool fail_) external {
        _before = before_;
        _after = after_;
        _fail = fail_;
    }

    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("test.settable.advice");
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
        if (_fail) revert();
        return _before;
    }

    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        view
        returns (HookrTypes.Advice memory)
    {
        if (_fail) revert();
        return _after;
    }
}

/// @notice A pool whose Rules have no per-swap add-on never calls the Rules module on a swap, charges exactly the
///         base LP fee, and keeps identity, receipts and accounting.
contract FeeOnlyPathTest is GasBenchFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    bytes32 internal constant HOOK_FEE = keccak256("HookFee(bytes32,address,uint256,uint256,uint256)");
    bytes32 internal constant FEES_ALLOCATED = keccak256("FeesAllocated(bytes32,address,uint256,uint256,uint256)");

    function _expectNoRulesSwapCalls() internal {
        vm.expectCall(address(rules), abi.encodeWithSelector(IHookrRules.beforeSwap.selector), 0);
        vm.expectCall(address(rules), abi.encodeWithSelector(IHookrRules.settleSwap.selector), 0);
    }

    function _noFeeEvents(Vm.Log[] memory logs) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && (logs[i].topics[0] == HOOK_FEE || logs[i].topics[0] == FEES_ALLOCATED)) {
                return false;
            }
        }
        return true;
    }

    function _launchWith(IHookrLauncher.Member memory m) internal returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function test_feeOnlyFromDeclaredOnlyWithoutAddOns() public {
        assertEq(root.feeOnlyFrom(feeKey.toId()), 1);
        assertEq(rules.feeOnlyFrom(feeKey.toId()), 1);
        assertEq(root.feeOnlyFrom(fullKey.toId()), 0);
        assertEq(rules.feeOnlyFrom(fullKey.toId()), 0);
        // Each add-on alone keeps the pool on the full path.
        int24[3] memory spacings = [int24(120), 240, 600];
        for (uint256 addOn; addOn < 3; ++addOn) {
            IHookrLauncher.Member memory m = _member(Currency.wrap(address(quoteFee)), spacings[addOn], false);
            if (addOn == 0) {
                m.rules.maxFeePips = 50_000;
                m.rules.dynamicFeeSens = 5;
            } else if (addOn == 1) {
                m.rules.lpBps = 200;
            } else {
                m.rules.burnBps = 100;
            }
            PoolKey memory key = _launchWith(m);
            assertEq(root.feeOnlyFrom(key.toId()), 0);
        }
        assertEq(rules.feeOnlyFrom(PoolId.wrap(bytes32(uint256(1)))), 0, "unbound pool");
    }

    function test_feeOnlySwapsNeverCallRules() public {
        uint256 liability = rules.totalLiability(Currency.wrap(address(quoteFee)));
        uint256 subjectBefore = subject.balanceOf(trader);
        uint256 quoteBefore = quoteFee.balanceOf(trader);
        _expectNoRulesSwapCalls();
        vm.recordLogs();
        _routerSwap(feeKey, true, 1e21);
        _routerSwap(feeKey, false, 5e20);
        _urSwap(feeKey, true, 1e21);
        _urSwap(feeKey, false, 5e20);
        _relayed(feeKey, true, 1e20, 5);
        assertTrue(_noFeeEvents(vm.getRecordedLogs()), "no zero fee events");
        assertGt(subject.balanceOf(trader), subjectBefore);
        assertLt(quoteFee.balanceOf(trader), quoteBefore);
        assertEq(rules.totalLiability(Currency.wrap(address(quoteFee))), liability, "nothing credited");
        assertTrue(rules.accountingInvariant(Currency.wrap(address(quoteFee))));
        assertEq(quoteFee.balanceOf(address(router)), 0);
        assertEq(subject.balanceOf(address(router)), 0);
    }

    function test_feeOnlySwapKeepsCuratedRouterIdentity() public {
        vm.expectCall(ur, abi.encodeWithSignature("msgSender()"));
        _urSwap(feeKey, true, 1e21);
    }

    /// @dev Two identical pools guarded until block G with no Snipe and no buy cap. Before G the Rules module is called
    ///      and quotes zero; from G it is skipped. Both paths fill the same amounts at the same fee.
    function test_feeOnlyMatchesFullPathAndStartsAtGuardEnd() public {
        uint256 guardEnd = vm.getBlockNumber() + 10;
        IHookrLauncher.Member memory m = _member(Currency.wrap(address(quoteFee)), 120, false);
        m.rules.guardEndBlock = uint40(guardEnd);
        PoolKey memory a = _launchWith(m);
        m.tickSpacing = 240;
        PoolKey memory b = _launchWith(m);
        assertEq(root.feeOnlyFrom(a.toId()), guardEnd);

        // Guard: Rules are called and still refuse exact-output buys.
        IHookrRouter.Swap memory exactOut = _params(a, true, 1e20);
        exactOut.amountSpecified = int128(1e20);
        exactOut.amountBound = type(uint128).max;
        vm.prank(trader);
        vm.expectRevert();
        router.swap(exactOut, address(0), new uint256[](0));
        vm.recordLogs();
        vm.prank(trader);
        (uint256 inA, uint256 outA) = router.swap(_params(a, true, 1e21), address(0), new uint256[](0));
        assertFalse(_noFeeEvents(vm.getRecordedLogs()), "Rules settled the guarded swap");

        vm.roll(guardEnd);
        vm.recordLogs();
        vm.prank(trader);
        (uint256 inB, uint256 outB) = router.swap(_params(b, true, 1e21), address(0), new uint256[](0));
        assertTrue(_noFeeEvents(vm.getRecordedLogs()), "Rules skipped from the guard end");
        assertEq(inA, inB, "same input");
        assertEq(outA, outB, "same output");
        (,,, uint24 lpFeeA) = manager.getSlot0(a.toId());
        (,,, uint24 lpFeeB) = manager.getSlot0(b.toId());
        assertEq(lpFeeA, 3000);
        assertEq(lpFeeB, 3000);

        // After the guard the same pool takes exact-output buys on the fee-only path.
        vm.prank(trader);
        (, uint256 out) = router.swap(exactOut, address(0), new uint256[](0));
        assertEq(out, 1e20);
    }

    function test_feeOnlyReceiptsMatchExecution() public {
        IHookrRouter.Swap memory p = _params(feeKey, true, 1e21);
        HookrTypes.ExecutionReceipt memory q = quoter.quote(p, trader);
        vm.prank(trader);
        (uint256 amountIn, uint256 amountOut) = router.swap(p, address(0), new uint256[](0));
        assertEq(q.inputAmount, amountIn);
        assertEq(q.outputAmount, amountOut);
        assertEq(q.actualQuote, amountIn);
        assertEq(q.quoteFee, 0);
        assertEq(q.quoteRefund, 0);
        assertEq(q.subjectBurn, 0);
        assertEq(q.lpFeePips, 3000);
        assertEq(q.payer, trader);
        assertEq(q.beneficiary, trader);
        assertEq(q.policyHash, root.policyHash(feeKey.toId()));

        IHookrRouter.Swap memory s = _params(feeKey, false, 1e20);
        s.amountSpecified = int128(1e20);
        s.amountBound = type(uint128).max;
        q = quoter.quote(s, trader);
        vm.prank(trader);
        (amountIn, amountOut) = router.swap(s, address(0), new uint256[](0));
        assertEq(amountOut, 1e20);
        assertEq(q.inputAmount, amountIn);
        assertEq(q.outputAmount, amountOut);
        assertEq(q.actualQuote, amountOut);
    }

    function test_quoteTakingAdvisoryKeepsRulesPath() public {
        ZeroAdvice advice = new ZeroAdvice();
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(advice),
            codeHash: address(advice).codehash,
            schemaHash: advice.configSchemaHash(),
            caps: HookrTypes.Caps(10_000, 20_000, 0),
            gasLimit: 200_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(quoteFee)), 120, false);
        members[0].config.advisory = address(advice);
        members[0].config.advisoryGasLimit = 200_000;
        members[0].config.advisoryPhases = 3;
        bytes[] memory configs = new bytes[](1);
        configs[0] = hex"01";
        (bytes32 family,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        );
        PoolKey memory key = launcher.position(family, 0).key;
        assertEq(rules.feeOnlyFrom(key.toId()), 1, "the Rules alone are fee-only");
        assertEq(root.feeOnlyFrom(key.toId()), 0, "the advisory keeps the full path");
        vm.expectCall(address(rules), abi.encodeWithSelector(IHookrRules.beforeSwap.selector), 1);
        _routerSwap(key, true, 1e21);
    }

    // ───────────────────────────── advised fee-only pools ─────────────────────────────

    function _none() internal pure returns (HookrTypes.Advice memory) {}

    function _surcharge(uint24 pips) internal pure returns (HookrTypes.Advice memory a) {
        a.lpFeeSurchargePips = pips;
    }

    /// @dev Admits `impl` as an advisory without a quote take; a fail-open admission is fee-only.
    function _admitTakeless(address impl, uint24 capLp, bool failOpen) internal {
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: impl,
            codeHash: impl.codehash,
            schemaHash: IHookrAdvisory(impl).configSchemaHash(),
            caps: HookrTypes.Caps(capLp, 0, 0),
            gasLimit: 200_000,
            phaseMask: 3,
            feeOnly: failOpen,
            failOpen: failOpen
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    function _launchAdvised(IHookrLauncher.Member memory m, address advice, bool failOpen)
        internal
        returns (PoolKey memory key)
    {
        m.config.advisory = advice;
        m.config.advisoryGasLimit = 200_000;
        m.config.advisoryPhases = HookrTypes.BEFORE_SWAP | HookrTypes.AFTER_SWAP;
        m.config.advisoryFailOpen = failOpen;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        bytes[] memory configs = new bytes[](1);
        configs[0] = hex"01";
        (bytes32 family,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function _takelessPool(bool failOpen) internal returns (SettableAdvice advice, PoolKey memory key) {
        advice = new SettableAdvice();
        _admitTakeless(address(advice), 10_000, failOpen);
        advice.set(_surcharge(500), _none(), false);
        key = _launchAdvised(_member(Currency.wrap(address(quoteFee)), 120, false), address(advice), failOpen);
    }

    function _wrapped(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(root),
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev An advisory admitted without a quote take leaves the pool fee-only: every route calls the advisory in
    ///      both phases and never the Rules module, and nothing is credited.
    function test_takelessAdvisoryPoolSkipsRules() public {
        (SettableAdvice advice, PoolKey memory key) = _takelessPool(false);
        assertEq(root.feeOnlyFrom(key.toId()), 1);
        Currency q = Currency.wrap(address(quoteFee));
        uint256 liability = rules.totalLiability(q);
        _expectNoRulesSwapCalls();
        vm.expectCall(address(advice), abi.encodeWithSelector(IHookrAdvisory.beforeSwap.selector), 5);
        vm.expectCall(address(advice), abi.encodeWithSelector(IHookrAdvisory.afterSwap.selector), 5);
        vm.recordLogs();
        _routerSwap(key, true, 1e21);
        _routerSwap(key, false, 5e20);
        _urSwap(key, true, 1e21);
        _urSwap(key, false, 5e20);
        _relayed(key, true, 1e20, 5);
        assertTrue(_noFeeEvents(vm.getRecordedLogs()), "no zero fee events");
        assertEq(rules.totalLiability(q), liability, "nothing credited");
        assertTrue(rules.accountingInvariant(q));
        (,,, uint24 stored) = manager.getSlot0(key.toId());
        assertEq(stored, 3000, "the surcharge overrides per swap only");
    }

    /// @dev Receipts on the fast path carry the advised LP fee and the authenticated identity.
    function test_takelessAdvisoryReceipts() public {
        (SettableAdvice advice, PoolKey memory key) = _takelessPool(false);
        IHookrRouter.Swap memory p = _params(key, true, 1e21);
        HookrTypes.ExecutionReceipt memory q = quoter.quote(p, trader);
        vm.prank(trader);
        (uint256 amountIn, uint256 amountOut) = router.swap(p, address(0), new uint256[](0));
        assertEq(q.inputAmount, amountIn);
        assertEq(q.outputAmount, amountOut);
        assertEq(q.lpFeePips, 3500);
        assertEq(q.quoteFee, 0);
        assertEq(q.quoteRefund, 0);
        assertEq(q.subjectBurn, 0);
        assertEq(q.payer, trader);
        assertEq(q.policyHash, root.policyHash(key.toId()));
        // A zero surcharge leaves the stored base fee in force.
        advice.set(_none(), _none(), false);
        assertEq(quoter.quote(_params(key, false, 1e20), trader).lpFeePips, 3000);
    }

    /// @dev Two identical advised pools guarded until G. Before G the Rules module quotes zero and settles nothing;
    ///      from G it is skipped. Both paths fill the same amounts at the same advised fee.
    function test_takelessAdvisoryMatchesRulesPath() public {
        SettableAdvice advice = new SettableAdvice();
        _admitTakeless(address(advice), 10_000, false);
        advice.set(_surcharge(700), _none(), false);
        uint256 guardEnd = vm.getBlockNumber() + 10;
        IHookrLauncher.Member memory m = _member(Currency.wrap(address(quoteFee)), 120, false);
        m.rules.guardEndBlock = uint40(guardEnd);
        PoolKey memory a = _launchAdvised(m, address(advice), false);
        m.tickSpacing = 240;
        PoolKey memory b = _launchAdvised(m, address(advice), false);
        assertEq(root.feeOnlyFrom(a.toId()), guardEnd);

        IHookrRouter.Swap memory sellOut = _params(a, false, 1e20);
        sellOut.amountSpecified = int128(1e20);
        sellOut.amountBound = type(uint128).max;
        vm.recordLogs();
        vm.startPrank(trader);
        (uint256 inA, uint256 outA) = router.swap(_params(a, true, 1e21), address(0), new uint256[](0));
        (uint256 sellInA, uint256 sellOutA) = router.swap(sellOut, address(0), new uint256[](0));
        vm.stopPrank();
        assertFalse(_noFeeEvents(vm.getRecordedLogs()), "Rules settled the guarded swaps");

        vm.roll(guardEnd);
        sellOut.key = b;
        assertEq(quoter.quote(_params(b, true, 1e21), trader).lpFeePips, 3700);
        vm.recordLogs();
        vm.startPrank(trader);
        (uint256 inB, uint256 outB) = router.swap(_params(b, true, 1e21), address(0), new uint256[](0));
        (uint256 sellInB, uint256 sellOutB) = router.swap(sellOut, address(0), new uint256[](0));
        vm.stopPrank();
        assertTrue(_noFeeEvents(vm.getRecordedLogs()), "Rules skipped from the guard end");
        assertEq(inA, inB, "same buy input");
        assertEq(outA, outB, "same buy output");
        assertEq(sellInA, sellInB, "same sell input");
        assertEq(sellOutA, sellOutB, "same sell output");
        assertEq(sellOutB, 1e20);
    }

    /// @dev The fast path keeps the advisory's bounds: rejection, the admitted LP cap, no quote take, no after-phase
    ///      surcharge or rejection, and a fail-closed failure.
    function test_takelessAdvisoryBoundsHoldOnFastPath() public {
        (SettableAdvice advice, PoolKey memory key) = _takelessPool(false);
        IHookrRouter.Swap memory p = _params(key, true, 1e20);
        HookrTypes.Advice memory before_;

        before_.reject = true;
        advice.set(before_, _none(), false);
        vm.prank(trader);
        vm.expectRevert(
            _wrapped(IHooks.beforeSwap.selector, abi.encodeWithSelector(IHookrRootState.SwapRejected.selector))
        );
        router.swap(p, address(0), new uint256[](0));

        bytes memory invalid = abi.encodeWithSelector(IHookrRootEvents.InvalidModuleResult.selector, address(advice));
        advice.set(_surcharge(10_001), _none(), false);
        vm.prank(trader);
        vm.expectRevert(_wrapped(IHooks.beforeSwap.selector, invalid));
        router.swap(p, address(0), new uint256[](0));

        before_ = _none();
        before_.quoteTakePips = 1;
        before_.recipient = address(0xADF);
        advice.set(before_, _none(), false);
        vm.prank(trader);
        vm.expectRevert(_wrapped(IHooks.beforeSwap.selector, invalid));
        router.swap(p, address(0), new uint256[](0));

        advice.set(_none(), before_, false);
        vm.prank(trader);
        vm.expectRevert(_wrapped(IHooks.afterSwap.selector, invalid));
        router.swap(p, address(0), new uint256[](0));

        advice.set(_none(), _surcharge(1), false);
        vm.prank(trader);
        vm.expectRevert(_wrapped(IHooks.afterSwap.selector, invalid));
        router.swap(p, address(0), new uint256[](0));

        HookrTypes.Advice memory late;
        late.reject = true;
        advice.set(_none(), late, false);
        vm.prank(trader);
        vm.expectRevert(_wrapped(IHooks.afterSwap.selector, invalid));
        router.swap(p, address(0), new uint256[](0));

        advice.set(_none(), _none(), true);
        vm.prank(trader);
        vm.expectRevert(
            _wrapped(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(
                    IHookrRootEvents.ModuleCallFailed.selector, address(advice), IHookrAdvisory.beforeSwap.selector
                )
            )
        );
        router.swap(p, address(0), new uint256[](0));
    }

    /// @dev A failing fail-open advisory charges its admitted LP cap on the fast path and the swap completes.
    function test_takelessFailOpenAdvisoryChargesCap() public {
        (SettableAdvice advice, PoolKey memory key) = _takelessPool(true);
        assertEq(root.feeOnlyFrom(key.toId()), 1);
        advice.set(_none(), _none(), true);
        _expectNoRulesSwapCalls();
        assertEq(quoter.quote(_params(key, true, 1e20), trader).lpFeePips, 13_000);
        _routerSwap(key, true, 1e20);
    }
}
