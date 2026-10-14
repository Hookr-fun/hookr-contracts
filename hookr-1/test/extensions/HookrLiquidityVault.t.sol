// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {RootSecurityBase} from "../utils/RootSecurityBase.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {HookrLiquidityVault} from "../../src/extensions/HookrLiquidityVault.sol";
import {IHookrLiquidityVault} from "../../src/interfaces/IHookrLiquidityVault.sol";
import {ReferenceLP} from "../utils/ReferenceLP.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

/// @dev ETH recipient that tries to re-enter the vault while it is paid.
contract ReentrantRecipient {
    HookrLiquidityVault internal immutable vault;
    PoolKey internal key;
    bytes4 public reentryError;
    bool public attempted;

    constructor(HookrLiquidityVault v) {
        vault = v;
    }

    function arm(PoolKey memory k) external {
        key = k;
    }

    receive() external payable {
        if (attempted) return;
        attempted = true;
        try vault.claim(key, -600, 600, address(this)) {}
        catch (bytes memory reason) {
            reentryError = bytes4(reason);
        }
    }
}

/// @notice Audit finding NM-03.
contract HookrLiquidityVaultTest is RootSecurityBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    int24 internal constant LO = -600;
    int24 internal constant HI = 600;
    Currency internal constant ETH = Currency.wrap(address(0));

    HookrLiquidityVault internal vault;
    HookrTreasury internal treasury;
    address internal treasuryTarget = address(0x7A26E7);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA201);
    address internal mallory = address(0xBAD);
    PoolKey internal key;

    function setUp() public {
        _setUpRootSecurity();
        treasury = new HookrTreasury(address(this), treasuryTarget, manager);
        vault = new HookrLiquidityVault(manager, address(treasury), address(this), 1 days, 2_000);
        treasury.admitSource(address(vault));
        key = _open(_config(address(rules)), abi.encode(_rulesConfig()), 60);
        _addLiquidity(key, -6000, 6000, 1e22);
        address[4] memory actors = [alice, bob, carol, mallory];
        for (uint256 i; i < actors.length; ++i) {
            tokenA.transfer(actors[i], 1e25);
            tokenB.transfer(actors[i], 1e25);
            vm.deal(actors[i], 1e25);
            vm.startPrank(actors[i]);
            tokenA.approve(address(vault), type(uint256).max);
            tokenB.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _params(address who, PoolKey memory k, uint256 a0, uint256 a1)
        internal
        view
        returns (IHookrLiquidityVault.DepositParams memory)
    {
        return IHookrLiquidityVault.DepositParams(k, LO, HI, a0, a1, 0, 0, who, vm.getBlockTimestamp());
    }

    function _deposit(address who, PoolKey memory k, uint256 a0, uint256 a1)
        internal
        returns (uint256 id, uint128 liquidity, uint256 paid0, uint256 paid1)
    {
        vm.prank(who);
        return vault.deposit{value: k.currency0.isAddressZero() ? a0 : 0}(_params(who, k, a0, a1));
    }

    function _withdraw(address who, PoolKey memory k, uint128 liquidity)
        internal
        returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1)
    {
        vm.prank(who);
        return
            vault.withdraw(IHookrLiquidityVault.WithdrawParams(k, LO, HI, liquidity, 0, 0, who, vm.getBlockTimestamp()));
    }

    function _claim(address who, PoolKey memory k) internal returns (uint256, uint256) {
        vm.prank(who);
        return vault.claim(k, LO, HI, who);
    }

    function _ref() internal returns (ReferenceLP r) {
        r = new ReferenceLP(manager);
        tokenA.transfer(address(r), 1e25);
        tokenB.transfer(address(r), 1e25);
        vm.deal(address(r), 1e25);
    }

    function _refFees(ReferenceLP r, PoolKey memory k) internal returns (uint256 f0, uint256 f1) {
        (,, f0, f1) = r.modify(k, LO, HI, 0);
    }

    function _routerSwap(PoolKey memory k, bool buy, uint128 amount) internal {
        IHookrRouter.Swap memory p = _swap(k, buy, true, amount);
        bool nativeIn = p.zeroForOne && k.currency0.isAddressZero();
        vm.prank(trader);
        router.swap{value: nativeIn ? amount : 0}(p, address(0), new uint256[](0));
    }

    /// @dev Round trip of buys and sells that keeps the price inside [LO, HI].
    function _trade(PoolKey memory k, uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            _routerSwap(k, true, 5e19);
            _routerSwap(k, false, 5e19);
        }
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

    function _claimBalance(Currency c) internal view returns (uint256) {
        return manager.balanceOf(address(vault), c.toId());
    }

    function _raiseSkim(uint16 bps) internal {
        vault.queue(vault.SET_SKIM(), abi.encode(bps));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.setSkim(bps);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Shares and principal
    // ------------------------------------------------------------------------------------------------------------

    function testDepositMintsSharesEqualToLiquidity() public {
        uint256 a0 = tokenA.balanceOf(alice);
        uint256 b0 = tokenB.balanceOf(alice);
        (uint256 id, uint128 liquidity, uint256 paid0, uint256 paid1) = _deposit(alice, key, 1e20, 1e20);
        assertEq(id, vault.rangeId(key.toId(), LO, HI));
        assertGt(liquidity, 0);
        assertEq(vault.balanceOf(alice, id), liquidity);
        assertEq(vault.totalSupply(id), liquidity);
        (uint128 positionLiquidity,,) = manager.getPositionInfo(key.toId(), address(vault), LO, HI, bytes32(0));
        assertEq(positionLiquidity, liquidity);
        assertLe(paid0, 1e20);
        assertLe(paid1, 1e20);
        uint256 spentA = a0 - tokenA.balanceOf(alice);
        uint256 spentB = b0 - tokenB.balanceOf(alice);
        bool aIs0 = Currency.unwrap(key.currency0) == address(tokenA);
        assertEq(aIs0 ? spentA : spentB, paid0);
        assertEq(aIs0 ? spentB : spentA, paid1);
        // The vault holds no tokens: principal sits in the pool.
        assertEq(tokenA.balanceOf(address(vault)), 0);
        assertEq(tokenB.balanceOf(address(vault)), 0);
    }

    function testPrincipalMatchesDirectPosition() public {
        ReferenceLP ref = _ref();
        (, uint128 liquidity, uint256 paid0, uint256 paid1) = _deposit(alice, key, 1e20, 1e20);
        (int256 r0, int256 r1,,) = ref.modify(key, LO, HI, int256(uint256(liquidity)));
        assertEq(uint256(-r0), paid0);
        assertEq(uint256(-r1), paid1);
        (uint256 out0, uint256 out1, uint256 fees0, uint256 fees1) = _withdraw(alice, key, liquidity);
        (r0, r1,,) = ref.modify(key, LO, HI, -int256(uint256(liquidity)));
        assertEq(out0, uint256(r0));
        assertEq(out1, uint256(r1));
        assertEq(fees0 + fees1, 0);
    }

    function testDepositSlippageDeadlineAndRangeChecks() public {
        IHookrLiquidityVault.DepositParams memory p = _params(alice, key, 1e20, 1e20);
        p.amount0Min = 1e20 + 1;
        vm.prank(alice);
        vm.expectPartialRevert(IHookrLiquidityVault.Slippage.selector);
        vault.deposit(p);

        p = _params(alice, key, 1e20, 1e20);
        p.deadline = vm.getBlockTimestamp() - 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.DeadlinePassed.selector, p.deadline));
        vault.deposit(p);

        p = _params(alice, key, 1e20, 1e20);
        p.tickLower = HI;
        vm.prank(alice);
        vm.expectRevert(IHookrLiquidityVault.InvalidRange.selector);
        vault.deposit(p);

        p = _params(alice, key, 0, 0);
        vm.prank(alice);
        vm.expectRevert(IHookrLiquidityVault.InvalidLiquidity.selector);
        vault.deposit(p);

        p = _params(alice, key, 1e20, 1e20);
        vm.prank(alice);
        vm.expectRevert(IHookrLiquidityVault.InvalidValue.selector);
        vault.deposit{value: 1}(p);
    }

    function testWithdrawChecks() public {
        (, uint128 liquidity,,) = _deposit(alice, key, 1e20, 1e20);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.InsufficientShares.selector, 0, liquidity));
        vault.withdraw(IHookrLiquidityVault.WithdrawParams(key, LO, HI, liquidity, 0, 0, bob, vm.getBlockTimestamp()));

        vm.prank(alice);
        vm.expectPartialRevert(IHookrLiquidityVault.Slippage.selector);
        vault.withdraw(
            IHookrLiquidityVault.WithdrawParams(key, LO, HI, liquidity, 1e20, 0, alice, vm.getBlockTimestamp())
        );

        vm.prank(alice);
        vm.expectRevert(IHookrLiquidityVault.InvalidLiquidity.selector);
        vault.withdraw(IHookrLiquidityVault.WithdrawParams(key, LO, HI, 0, 0, 0, alice, vm.getBlockTimestamp()));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Fee fairness
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Two LPs entering at different times each earn exactly what an equal direct position earns.
    function testMultiLpFairnessOverTime() public {
        ReferenceLP refA = _ref();
        ReferenceLP refB = _ref();
        (, uint128 la,,) = _deposit(alice, key, 1e20, 1e20);
        refA.modify(key, LO, HI, int256(uint256(la)));
        _trade(key, 3);
        vm.roll(vm.getBlockNumber() + 5);
        (, uint128 lb,,) = _deposit(bob, key, 3e20, 3e20);
        refB.modify(key, LO, HI, int256(uint256(lb)));
        _trade(key, 3);

        (uint256 a0, uint256 a1) = _claim(alice, key);
        (uint256 b0, uint256 b1) = _claim(bob, key);
        (uint256 ra0, uint256 ra1) = _refFees(refA, key);
        (uint256 rb0, uint256 rb1) = _refFees(refB, key);
        assertGt(ra0 + ra1, 0);
        assertApproxEqAbs(a0, ra0, 2);
        assertApproxEqAbs(a1, ra1, 2);
        assertApproxEqAbs(b0, rb0, 2);
        assertApproxEqAbs(b1, rb1, 2);
        assertLe(a0, ra0);
        assertLe(a1, ra1);
        assertLe(b0, rb0);
        assertLe(b1, rb1);
        // Bob joined after the first trades and earned strictly less per share than Alice.
        assertLt((b0 + b1) * 1e18 / lb, (a0 + a1) * 1e18 / la);
    }

    /// @notice A depositor joining after fees accrued, but before they were realised, gets none of them.
    function testLateDepositorGetsNoEarlierFees() public {
        _deposit(alice, key, 1e20, 1e20);
        _trade(key, 4);
        _deposit(bob, key, 1e21, 1e21);
        (uint256 b0, uint256 b1) = _claim(bob, key);
        assertEq(b0 + b1, 0);
        (uint256 a0, uint256 a1) = _claim(alice, key);
        assertGt(a0 + a1, 0);
    }

    /// @notice A JIT deposit right before a swap earns only its pro-rata share of that swap.
    function testJitDepositRightBeforeFees() public {
        ReferenceLP refA = _ref();
        ReferenceLP refM = _ref();
        (, uint128 la,,) = _deposit(alice, key, 1e20, 1e20);
        refA.modify(key, LO, HI, int256(uint256(la)));
        _trade(key, 3);

        (, uint128 lm,,) = _deposit(mallory, key, 2e21, 2e21);
        refM.modify(key, LO, HI, int256(uint256(lm)));
        _routerSwap(key, true, 5e19);
        (,, uint256 m0, uint256 m1) = _withdraw(mallory, key, lm);
        (,, uint256 rm0, uint256 rm1) = refM.modify(key, LO, HI, -int256(uint256(lm)));

        assertApproxEqAbs(m0, rm0, 2);
        assertApproxEqAbs(m1, rm1, 2);
        assertLe(m0 + m1, rm0 + rm1);
        assertEq(vault.balanceOf(mallory, vault.rangeId(key.toId(), LO, HI)), 0);

        (uint256 a0, uint256 a1) = _claim(alice, key);
        (uint256 ra0, uint256 ra1) = _refFees(refA, key);
        assertApproxEqAbs(a0, ra0, 3);
        assertApproxEqAbs(a1, ra1, 3);
    }

    /// @notice Withdraw returns principal plus the holder's fees in one call and leaves nothing owed.
    function testWithdrawAndClaimInOneTx() public {
        ReferenceLP ref = _ref();
        (uint256 id, uint128 liquidity,,) = _deposit(alice, key, 1e20, 1e20);
        ref.modify(key, LO, HI, int256(uint256(liquidity)));
        _trade(key, 3);
        uint256 beforeA = tokenA.balanceOf(alice);
        uint256 beforeB = tokenB.balanceOf(alice);
        (uint256 out0, uint256 out1, uint256 fees0, uint256 fees1) = _withdraw(alice, key, liquidity);
        (int256 r0, int256 r1, uint256 rf0, uint256 rf1) = ref.modify(key, LO, HI, -int256(uint256(liquidity)));
        assertEq(out0, uint256(r0));
        assertEq(out1, uint256(r1));
        assertApproxEqAbs(fees0, rf0, 2);
        assertApproxEqAbs(fees1, rf1, 2);
        assertGt(fees0 + fees1, 0);
        bool aIs0 = Currency.unwrap(key.currency0) == address(tokenA);
        assertEq(tokenA.balanceOf(alice) - beforeA, aIs0 ? out0 + fees0 : out1 + fees1);
        assertEq(tokenB.balanceOf(alice) - beforeB, aIs0 ? out1 + fees1 : out0 + fees0);
        assertEq(vault.balanceOf(alice, id), 0);
        assertEq(vault.totalSupply(id), 0);
        IHookrLiquidityVault.Account memory acct = vault.account(id, alice);
        assertEq(acct.owed0 + acct.owed1, 0);
        (uint256 p0, uint256 p1) = vault.pendingFees(key, LO, HI, alice);
        assertEq(p0 + p1, 0);
        // Only rounding dust can remain as vault claims.
        assertLe(_claimBalance(key.currency0), 2);
        assertLe(_claimBalance(key.currency1), 2);
    }

    function testPartialWithdrawKeepsRemainingSharesEarning() public {
        (uint256 id, uint128 liquidity,,) = _deposit(alice, key, 1e20, 1e20);
        _trade(key, 2);
        (,, uint256 f0, uint256 f1) = _withdraw(alice, key, liquidity / 2);
        assertGt(f0 + f1, 0);
        assertEq(vault.balanceOf(alice, id), liquidity - liquidity / 2);
        _trade(key, 2);
        (uint256 g0, uint256 g1) = _claim(alice, key);
        assertGt(g0 + g1, 0);
    }

    function testPendingFeesMatchesClaim() public {
        _deposit(alice, key, 1e20, 1e20);
        _deposit(bob, key, 2e20, 2e20);
        _trade(key, 3);
        (uint256 p0, uint256 p1) = vault.pendingFees(key, LO, HI, alice);
        (uint256 c0, uint256 c1) = _claim(alice, key);
        assertEq(p0, c0);
        assertEq(p1, c1);
        (p0, p1) = vault.pendingFees(key, LO, HI, bob);
        (c0, c1) = _claim(bob, key);
        assertEq(p0, c0);
        assertEq(p1, c1);
    }

    /// @notice A transfer settles realised fees to the sender; fees realised afterwards follow the shares.
    function testShareTransferSettlesRealisedFees() public {
        ReferenceLP ref = _ref();
        (uint256 id, uint128 liquidity,,) = _deposit(alice, key, 1e20, 1e20);
        ref.modify(key, LO, HI, int256(uint256(liquidity)));
        _trade(key, 2);
        vault.poke(key, LO, HI);
        (uint256 r0, uint256 r1) = _refFees(ref, key);
        vm.prank(alice);
        vault.transfer(carol, id, liquidity);
        _trade(key, 2);
        (uint256 s0, uint256 s1) = _refFees(ref, key);
        (uint256 a0, uint256 a1) = _claim(alice, key);
        (uint256 c0, uint256 c1) = _claim(carol, key);
        assertApproxEqAbs(a0, r0, 2);
        assertApproxEqAbs(a1, r1, 2);
        assertApproxEqAbs(c0, s0, 2);
        assertApproxEqAbs(c1, s1, 2);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.InvalidAddress.selector, address(0)));
        vault.transfer(address(0), id, 1);
    }

    function testTransferFromUsesAllowanceAndSettles() public {
        (uint256 id, uint128 liquidity,,) = _deposit(alice, key, 1e20, 1e20);
        _trade(key, 2);
        vault.poke(key, LO, HI);
        vm.prank(alice);
        vault.approve(bob, id, liquidity);
        vm.prank(bob);
        vault.transferFrom(alice, carol, id, liquidity);
        assertEq(vault.balanceOf(carol, id), liquidity);
        (uint256 a0, uint256 a1) = _claim(alice, key);
        assertGt(a0 + a1, 0);
        (uint256 c0, uint256 c1) = _claim(carol, key);
        assertEq(c0 + c1, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Protocol skim
    // ------------------------------------------------------------------------------------------------------------

    function testSkimMath() public {
        _raiseSkim(2_000);
        ReferenceLP ref = _ref();
        (, uint128 liquidity,,) = _deposit(alice, key, 1e20, 1e20);
        ref.modify(key, LO, HI, int256(uint256(liquidity)));
        _trade(key, 3);
        (uint256 a0, uint256 a1) = _claim(alice, key);
        (uint256 r0, uint256 r1) = _refFees(ref, key);
        uint256 s0 = vault.protocolFees(key.currency0);
        uint256 s1 = vault.protocolFees(key.currency1);
        assertEq(s0, r0 * 2_000 / 10_000);
        assertEq(s1, r1 * 2_000 / 10_000);
        assertApproxEqAbs(a0 + s0, r0, 2);
        assertApproxEqAbs(a1 + s1, r1, 2);
        assertEq(vault.claimable(key.currency0, address(treasury)), s0);
        assertEq(vault.claimable(key.currency0, alice), 0);

        // The treasury pulls through the IHookrProtocolClaims surface and forwards to its target.
        Currency c = key.currency0;
        uint256 targetBefore = IERC20(Currency.unwrap(c)).balanceOf(treasuryTarget);
        assertEq(treasury.collect(address(vault), c), s0);
        assertEq(IERC20(Currency.unwrap(c)).balanceOf(treasuryTarget) - targetBefore, s0);
        assertEq(vault.protocolFees(c), 0);

        // Permissionless push always pays the pinned recipient.
        Currency d = key.currency1;
        uint256 treasuryBefore = IERC20(Currency.unwrap(d)).balanceOf(address(treasury));
        vm.prank(mallory);
        assertEq(vault.collectProtocolFees(d), s1);
        assertEq(IERC20(Currency.unwrap(d)).balanceOf(address(treasury)) - treasuryBefore, s1);
        assertEq(vault.collectProtocolFees(d), 0);
    }

    function testSkimNeverTouchesPrincipal() public {
        _raiseSkim(2_000);
        ReferenceLP ref = _ref();
        (, uint128 liquidity, uint256 paid0, uint256 paid1) = _deposit(alice, key, 1e20, 1e20);
        (int256 r0, int256 r1,,) = ref.modify(key, LO, HI, int256(uint256(liquidity)));
        assertEq(paid0, uint256(-r0));
        assertEq(paid1, uint256(-r1));
        (uint256 out0, uint256 out1,,) = _withdraw(alice, key, liquidity);
        (r0, r1,,) = ref.modify(key, LO, HI, -int256(uint256(liquidity)));
        assertEq(out0, uint256(r0));
        assertEq(out1, uint256(r1));
        assertEq(vault.protocolFees(key.currency0) + vault.protocolFees(key.currency1), 0);
    }

    /// NM-03: lowering the skim voids every raise queued before it.
    function testLoweringSkimVoidsQueuedRaise() public {
        _raiseSkim(500);
        vault.queue(vault.SET_SKIM(), abi.encode(uint16(1_000)));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.setSkim(100);
        vm.expectPartialRevert(IHookrGoverned.NotReady.selector);
        vault.setSkim(1_000);
        assertEq(vault.skimBps(), 100);
        _raiseSkim(1_000);
        assertEq(vault.skimBps(), 1_000);
    }

    function testSkimGovernance() public {
        vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.InvalidSkim.selector, uint16(2_001)));
        vault.setSkim(2_001);
        vm.expectPartialRevert(IHookrGoverned.NotReady.selector);
        vault.setSkim(1_000);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, mallory));
        vault.setSkim(0);
        _raiseSkim(1_000);
        assertEq(vault.skimBps(), 1_000);
        // Lowering is immediate.
        vault.setSkim(500);
        assertEq(vault.skimBps(), 500);
        // The immutable bound cannot exceed the hard ceiling.
        vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.InvalidSkim.selector, uint16(2_001)));
        new HookrLiquidityVault(manager, address(treasury), address(this), 1 days, 2_001);
    }

    function testProtocolClaimToOnlyRecipient() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, mallory));
        vault.claimTo(key.currency0, mallory);
        vm.prank(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.InvalidAddress.selector, address(manager)));
        vault.claimTo(key.currency0, address(manager));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Hookr launch guard
    // ------------------------------------------------------------------------------------------------------------

    function _guardedPool(address owner_) internal returns (PoolKey memory k, uint256 guardEnd) {
        HookrTypes.RulesConfig memory c = _rulesConfig();
        guardEnd = vm.getBlockNumber() + 100;
        c.guardEndBlock = uint40(guardEnd);
        HookrTypes.PoolConfig memory pc = _config(address(rules));
        pc.liquidityOwner = owner_;
        k = _open(pc, abi.encode(c), 10);
    }

    /// @notice With the vault as the guard's liquidity owner, principal is locked until guardEndBlock; fees are not.
    function testGuardLocksWithdrawButNotClaims() public {
        (PoolKey memory k, uint256 guardEnd) = _guardedPool(address(vault));
        (, uint128 liquidity,,) = _deposit(alice, k, 1e21, 1e21);
        _trade(k, 2);
        vm.prank(alice);
        vm.expectRevert(
            _wrapped(
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(IHookrRootState.LiquidityLocked.selector, k.toId(), guardEnd)
            )
        );
        vault.withdraw(IHookrLiquidityVault.WithdrawParams(k, LO, HI, liquidity, 0, 0, alice, vm.getBlockTimestamp()));

        (uint256 f0, uint256 f1) = _claim(alice, k);
        assertGt(f0 + f1, 0);
        vault.poke(k, LO, HI);

        vm.roll(guardEnd);
        (uint256 out0, uint256 out1,,) = _withdraw(alice, k, liquidity);
        assertGt(out0 + out1, 0);
    }

    /// @notice When the vault is not the guard's liquidity owner, deposits revert until the guard ends.
    function testGuardRefusesVaultDepositUntilEnd() public {
        (PoolKey memory k, uint256 guardEnd) = _guardedPool(address(lp));
        vm.prank(alice);
        vm.expectRevert(
            _wrapped(
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(
                    IHookrRootEvents.ModuleCallReverted.selector,
                    address(rules),
                    IHookrRules.beforeAddLiquidity.selector,
                    abi.encodeWithSelector(IHookrRulesState.GuardLiquidity.selector)
                )
            )
        );
        vault.deposit(_params(alice, k, 1e20, 1e20));
        vm.roll(guardEnd);
        (, uint128 liquidity,,) = _deposit(alice, k, 1e20, 1e20);
        assertGt(liquidity, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Native ETH and reentrancy
    // ------------------------------------------------------------------------------------------------------------

    function _nativePool() internal returns (PoolKey memory k) {
        k = PoolKey(ETH, Currency.wrap(address(tokenA)), 0x800000, 60, IHooks(address(root)));
        HookrTypes.PoolConfig memory pc = _config(address(rules));
        pc.quote = ETH;
        pc.subject = Currency.wrap(address(tokenA));
        root.initializePool(k, pc, abi.encode(_rulesConfig()), "", SQRT_ONE);
        _ref().modify(k, -6000, 6000, 1e22);
    }

    function testNativeEthDepositRefundWithdraw() public {
        PoolKey memory k = _nativePool();
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        (uint256 id, uint128 liquidity, uint256 paid0,) = vault.deposit{value: 3e20}(_params(alice, k, 1e20, 1e20));
        assertEq(ethBefore - alice.balance, paid0);
        assertEq(address(vault).balance, 0);
        ReferenceLP ref = _ref();
        (int256 r0,,,) = ref.modify(k, LO, HI, int256(uint256(liquidity)));
        assertEq(uint256(-r0), paid0);
        _trade(k, 3);
        ethBefore = alice.balance;
        (uint256 out0,, uint256 fees0,) = _withdraw(alice, k, liquidity);
        (int256 q0,, uint256 rf0,) = ref.modify(k, LO, HI, -int256(uint256(liquidity)));
        assertEq(alice.balance - ethBefore, out0 + fees0);
        assertGt(fees0, 0);
        assertEq(out0, uint256(q0));
        assertApproxEqAbs(fees0, rf0, 2);
        assertEq(vault.balanceOf(alice, id), 0);

        vm.prank(alice);
        vm.expectRevert(IHookrLiquidityVault.InvalidValue.selector);
        vault.deposit{value: 1e19}(_params(alice, k, 1e20, 1e20));
    }

    function testReentrantRecipientCannotReenter() public {
        PoolKey memory k = _nativePool();
        ReentrantRecipient bad = new ReentrantRecipient(vault);
        bad.arm(k);
        (, uint128 liquidity,,) = _deposit(alice, k, 1e20, 1e20);
        _trade(k, 1);
        vm.prank(alice);
        vault.withdraw(
            IHookrLiquidityVault.WithdrawParams(k, LO, HI, liquidity, 0, 0, address(bad), vm.getBlockTimestamp())
        );
        assertTrue(bad.attempted());
        assertEq(bad.reentryError(), IHookrLiquidityVault.Reentrancy.selector);
        assertGt(address(bad).balance, 0);
    }

    function testUnlockCallbackOnlyFromOwnUnlock() public {
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, address(this)));
        vault.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, address(manager)));
        vault.unlockCallback("");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Any v4 pool
    // ------------------------------------------------------------------------------------------------------------

    function testPlainPoolFairness() public {
        PoolKey memory k = _key(60);
        k.fee = 3000;
        k.hooks = IHooks(address(0));
        manager.initialize(k, SQRT_ONE);
        ReferenceLP refA = _ref();
        (, uint128 la,,) = _deposit(alice, k, 1e20, 1e20);
        refA.modify(k, LO, HI, int256(uint256(la)));
        for (uint256 i; i < 3; ++i) {
            generic.swap(k, SwapParams(true, -5e19, MIN_PRICE), PoolSwapTest.TestSettings(false, false), "");
            generic.swap(k, SwapParams(false, -5e19, MAX_PRICE), PoolSwapTest.TestSettings(false, false), "");
        }
        (,, uint256 a0, uint256 a1) = _withdraw(alice, k, la);
        (,, uint256 r0, uint256 r1) = refA.modify(k, LO, HI, -int256(uint256(la)));
        assertGt(r0 + r1, 0);
        assertApproxEqAbs(a0, r0, 2);
        assertApproxEqAbs(a1, r1, 2);
    }

    /// @notice A dust first deposit followed by a large donation cannot inflate later shares or capture their fees.
    function testFirstDepositDonationCannotInflateShares() public {
        PoolKey memory k = _key(60);
        k.fee = 3000;
        k.hooks = IHooks(address(0));
        manager.initialize(k, SQRT_ONE);
        PoolDonateTest donor = new PoolDonateTest(manager);
        tokenA.approve(address(donor), type(uint256).max);
        tokenB.approve(address(donor), type(uint256).max);

        (uint256 id, uint128 lm,,) = _deposit(mallory, k, 1e6, 1e6);
        assertEq(vault.balanceOf(mallory, id), lm);
        donor.donate(k, 1e20, 1e20, "");

        ReferenceLP ref = _ref();
        (, uint128 la, uint256 paid0, uint256 paid1) = _deposit(alice, k, 1e20, 1e20);
        (int256 r0, int256 r1,,) = ref.modify(k, LO, HI, int256(uint256(la)));
        assertEq(paid0, uint256(-r0));
        assertEq(paid1, uint256(-r1));
        assertEq(vault.balanceOf(alice, id), la);
        assertEq(vault.totalSupply(id), uint256(la) + lm);

        (uint256 a0, uint256 a1) = _claim(alice, k);
        assertEq(a0 + a1, 0);
        (uint256 out0, uint256 out1,,) = _withdraw(alice, k, la);
        (r0, r1,,) = ref.modify(k, LO, HI, -int256(uint256(la)));
        assertEq(out0, uint256(r0));
        assertEq(out1, uint256(r1));
        // The donation went to the only in-range liquidity when it was made, less pool and vault rounding.
        (,, uint256 m0, uint256 m1) = _withdraw(mallory, k, lm);
        assertApproxEqAbs(m0, 1e20, 3);
        assertApproxEqAbs(m1, 1e20, 3);
    }

    function testRecipientChecks() public {
        IHookrLiquidityVault.DepositParams memory p = _params(alice, key, 1e20, 1e20);
        p.recipient = address(vault);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.InvalidAddress.selector, address(vault)));
        vault.deposit(p);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.InvalidAddress.selector, address(manager)));
        vault.claim(key, LO, HI, address(manager));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Solvency
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Random deposit, trade and exit sequences never pay out more than was realised.
    function testFuzzSolvency(uint96[4] memory amounts, uint8 skim, uint8 order) public {
        uint16 bps = uint16(bound(skim, 0, 20)) * 100;
        if (bps != 0) _raiseSkim(bps);
        address[3] memory actors = [alice, bob, carol];
        uint128[3] memory shares;
        for (uint256 i; i < 3; ++i) {
            uint256 amount = bound(amounts[i], 1e15, 1e21);
            (, shares[i],,) = _deposit(actors[i], key, amount, amount);
            _trade(key, 1 + (uint256(order) >> i) % 2);
        }
        _routerSwap(key, true, uint128(bound(amounts[3], 1e15, 1e20)));
        uint256 out0;
        uint256 out1;
        for (uint256 j; j < 3; ++j) {
            uint256 i = (j + order) % 3;
            (,, uint256 f0, uint256 f1) = _withdraw(actors[i], key, shares[i]);
            out0 += f0;
            out1 += f1;
        }
        uint256 id = vault.rangeId(key.toId(), LO, HI);
        assertEq(vault.totalSupply(id), 0);
        uint256 held0 = _claimBalance(key.currency0);
        uint256 held1 = _claimBalance(key.currency1);
        uint256 s0 = vault.protocolFees(key.currency0);
        uint256 s1 = vault.protocolFees(key.currency1);
        assertGe(held0, s0);
        assertGe(held1, s1);
        // Rounding dust: at most one unit per realisation per holder.
        assertLe(held0 - s0, 12);
        assertLe(held1 - s1, 12);
        if (s0 != 0) assertEq(vault.collectProtocolFees(key.currency0), s0);
        if (s1 != 0) assertEq(vault.collectProtocolFees(key.currency1), s1);
    }
}
