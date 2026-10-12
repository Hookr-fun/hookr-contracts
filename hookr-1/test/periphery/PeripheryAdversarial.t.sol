// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrQuoter} from "../../src/lens/HookrQuoter.sol";
import {IHookrQuoter} from "../../src/interfaces/IHookrQuoter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrSettlement} from "../../src/libraries/HookrSettlement.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";
import {IHookrEngagementReceiptSink} from "../../src/interfaces/IHookrEngagementReceiptSink.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

abstract contract RouterReentryProbe {
    address internal _router;
    bytes internal _attack;
    uint256 public attempts;
    bool public blocked;
    error UnexpectedReentryResult();

    function setAttack(address router_, bytes calldata attack_) external {
        _router = router_;
        _attack = attack_;
    }

    function _probe() internal {
        ++attempts;
        (bool ok, bytes memory result) = _router.call(_attack);
        blocked = !ok && result.length == 4 && bytes4(result) == IHookrRouter.Reentered.selector;
        if (!blocked) revert UnexpectedReentryResult();
    }
}

contract CallbackAsset is ERC20, RouterReentryProbe {
    address public callbackFrom;
    address public callbackTo;
    address public taxedFrom;
    address public taxedTo;

    constructor() ERC20("Callback Asset", "CB") {
        _mint(msg.sender, 1e30);
    }

    function armCallback(address from, address to) external {
        callbackFrom = from;
        callbackTo = to;
    }

    function armTax(address from, address to) external {
        taxedFrom = from;
        taxedTo = to;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from != address(0) && amount != 0) {
            if (from == callbackFrom && to == callbackTo) _probe();
            if (from == taxedFrom && to == taxedTo) super._update(from, address(0), 1);
        }
    }
}

contract NativeReentryRecipient is RouterReentryProbe {
    uint256 public received;

    receive() external payable {
        received += msg.value;
        _probe();
    }
}

contract ReentryReceiptSink is RouterReentryProbe, IHookrEngagementReceiptSink {
    using TransientStateLibrary for IPoolManager;
    address public immutable override trustedRouter;
    address public immutable override poolManager;
    bool public managerWasLocked;
    address public participant;
    uint256 public volume;

    constructor(address router_, address manager_) {
        trustedRouter = router_;
        poolManager = manager_;
    }

    function recordExecution(EngagementReceipt calldata receipt, uint256[] calldata) external {
        if (msg.sender != trustedRouter) revert UnexpectedReentryResult();
        managerWasLocked = !IPoolManager(poolManager).isUnlocked();
        participant = receipt.participant;
        volume = receipt.quoteVolume;
        _probe();
    }
}

    contract ForgedQuoteAdvice is IHookrAdvisory {
        bytes private _forged;

        constructor(bytes memory forged) {
            _forged = forged;
        }

        function configSchemaHash() external pure returns (bytes32) {
            return keccak256("forged.quote.advice");
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
            bytes memory forged = _forged;
            assembly ("memory-safe") { revert(add(forged, 32), mload(forged)) }
        }

        function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
            external
            pure
            returns (HookrTypes.Advice memory advice)
        {
            return advice;
        }
    }

    contract PeripheryAdversarialTest is PeripheryFixture {
        using PoolIdLibrary for PoolKey;
        using CurrencyLibrary for Currency;
        using StateLibrary for IPoolManager;

        function setUp() public {
            _setUpPeriphery();
        }

        function testCollectOnlyPaysFeesWithoutRemovingLiquidity() public {
            (bytes32 family, PoolKey memory key,,) = _launch(true, false);
            IHookrRouter.Swap memory params = _swap(key, true, true, 10 ether);
            vm.prank(trader);
            router.swap(params, address(0), new uint256[](0));
            uint128 positionLiquidity = launcher.position(family, 0).liquidity;
            uint128 poolLiquidity = manager.getLiquidity(key.toId());
            uint256 before0 = key.currency0.balanceOf(address(this));
            uint256 before1 = key.currency1.balanceOf(address(this));
            (uint256 fees0, uint256 fees1) =
                launcher.withdraw(family, 0, 0, 0, 0, address(this), vm.getBlockTimestamp());
            assertGt(fees0 + fees1, 0);
            assertEq(key.currency0.balanceOf(address(this)), before0 + fees0);
            assertEq(key.currency1.balanceOf(address(this)), before1 + fees1);
            assertEq(launcher.position(family, 0).liquidity, positionLiquidity);
            assertEq(manager.getLiquidity(key.toId()), poolLiquidity);
            (fees0, fees1) = launcher.withdraw(family, 0, 0, 0, 0, address(this), vm.getBlockTimestamp());
            assertEq(fees0, 0);
            assertEq(fees1, 0);
            launcher.transferFamily(family, trader, 0);
            vm.prank(trader);
            launcher.acceptFamily(family);
            assertEq(rules.config(key.toId()).royaltyTo, royalty);
            vm.expectRevert(IHookrLauncher.NotOwner.selector);
            launcher.withdraw(family, 0, positionLiquidity, 0, 0, address(this), vm.getBlockTimestamp());
            vm.prank(trader);
            launcher.withdraw(family, 0, positionLiquidity, 1, 1, trader, vm.getBlockTimestamp());
            assertEq(launcher.position(family, 0).liquidity, 0);
            assertEq(manager.getLiquidity(key.toId()), 0);
        }

        function testInputTokenCannotReenterRouter() public {
            _tokenReentry(false);
        }

        function testOutputTokenCannotReenterRouter() public {
            _tokenReentry(true);
        }

        function _tokenReentry(bool buy) private {
            (CallbackAsset asset, PoolKey memory key) = _callbackPool();
            IHookrRouter.Swap memory p = _swap(key, buy, true, 1 ether);
            asset.setAttack(address(router), _attack(p));
            // ERC-20 output goes from the PoolManager straight to the recipient, inside the router's unlock.
            asset.armCallback(buy ? address(manager) : trader, buy ? p.recipient : address(manager));
            Currency input = p.zeroForOne ? key.currency0 : key.currency1;
            Currency output = p.zeroForOne ? key.currency1 : key.currency0;
            uint256 beforeIn = input.balanceOf(trader);
            uint256 beforeOut = output.balanceOf(trader);
            vm.prank(trader);
            (uint256 amountIn, uint256 amountOut) = router.swap(p, address(0), new uint256[](0));
            assertEq(asset.attempts(), 1);
            assertTrue(asset.blocked());
            assertEq(input.balanceOf(trader), beforeIn - amountIn);
            assertEq(output.balanceOf(trader), beforeOut + amountOut);
            assertEq(asset.balanceOf(address(router)), 0);
            assertEq(tokenB.balanceOf(address(router)), 0);
            assertTrue(rules.accountingInvariant(root.poolConfig(key.toId()).quote));
        }

        function testNativeOutputRecipientCannotReenterRouter() public {
            (, PoolKey memory key,,) = _launch(false, true);
            NativeReentryRecipient recipient = new NativeReentryRecipient();
            IHookrRouter.Swap memory p = _swap(key, false, true, 1 ether);
            p.recipient = address(recipient);
            recipient.setAttack(address(router), _attack(p));
            uint256 beforeIn = tokenA.balanceOf(trader);
            vm.prank(trader);
            (uint256 amountIn, uint256 amountOut) = router.swap(p, address(0), new uint256[](0));
            assertEq(recipient.attempts(), 1);
            assertTrue(recipient.blocked());
            assertEq(recipient.received(), amountOut);
            assertEq(address(recipient).balance, amountOut);
            assertEq(tokenA.balanceOf(trader), beforeIn - amountIn);
            assertEq(address(router).balance, 0);
            assertEq(tokenA.balanceOf(address(router)), 0);
        }

        function testPostUnlockEngagementCannotReenterRouter() public {
            (, PoolKey memory key,,) = _launch(true, false);
            IHookrRouter.Swap memory p = _swap(key, true, true, 1 ether);
            HookrTypes.ExecutionReceipt memory quoted = quoter.quote(p, trader);
            ReentryReceiptSink sink = new ReentryReceiptSink(address(router), address(manager));
            sink.setAttack(address(router), _attack(p));
            uint256[] memory ids = new uint256[](1);
            ids[0] = 1;
            Currency output = p.zeroForOne ? key.currency1 : key.currency0;
            uint256 beforeOut = output.balanceOf(trader);
            vm.prank(trader);
            (, uint256 amountOut) = router.swap(p, address(sink), ids);
            assertEq(sink.attempts(), 1);
            assertTrue(sink.blocked());
            assertTrue(sink.managerWasLocked());
            assertEq(sink.participant(), trader);
            assertEq(sink.volume(), quoted.actualQuote);
            assertEq(output.balanceOf(trader), beforeOut + amountOut);
            assertEq(tokenA.balanceOf(address(router)), 0);
            assertEq(tokenB.balanceOf(address(router)), 0);
        }

        function testSenderTaxOnManagerOutputFailsAndRollsBack() public {
            (CallbackAsset asset, PoolKey memory key) = _callbackPool();
            IHookrRouter.Swap memory p = _swap(key, true, true, 1 ether);
            asset.armTax(address(manager), p.recipient);
            // Quoting does not exercise the later output token transfer.
            HookrTypes.ExecutionReceipt memory quoted = quoter.quote(p, trader);
            assertGt(quoted.outputAmount, 0);
            uint256 beforeIn = tokenB.balanceOf(trader);
            uint256 beforeOut = asset.balanceOf(trader);
            uint256 beforeManager = asset.balanceOf(address(manager));
            uint256 beforeSupply = asset.totalSupply();
            (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
            vm.prank(trader);
            vm.expectRevert(HookrSettlement.BalanceMismatch.selector);
            router.swap(p, address(0), new uint256[](0));
            assertEq(tokenB.balanceOf(trader), beforeIn);
            assertEq(asset.balanceOf(trader), beforeOut);
            assertEq(asset.balanceOf(address(manager)), beforeManager);
            assertEq(asset.totalSupply(), beforeSupply);
            assertEq(asset.balanceOf(address(router)), 0);
            (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
            assertEq(priceAfter, priceBefore);
            asset.armTax(address(0), address(0));
            vm.prank(trader);
            router.swap(p, address(0), new uint256[](0));
            assertGt(asset.balanceOf(trader), beforeOut);
        }

        function testNativePartialFillRewardsActualQuoteAndSeparatesRefunds() public {
            (, PoolKey memory key,, Currency quote) = _launch(false, true);
            (HookrPrograms programs, uint256 campaign) = _nativeCampaign(key);
            IHookrRouter.Swap memory p = _swap(key, true, true, 1e23);
            p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(-1);
            HookrTypes.ExecutionReceipt memory quoted = quoter.quote(p, trader);
            assertLt(quoted.actualQuote, 1e23);
            assertLt(quoted.inputAmount, 1e23);
            assertGt(quoted.quoteRefund, 0);
            assertEq(rules.claimable(quote, trader), 0);
            uint256[] memory ids = new uint256[](1);
            ids[0] = campaign;
            uint256 nativeBefore = trader.balance;
            vm.prank(trader);
            (uint256 amountIn,) = router.swap{value: 1e23}(p, address(programs), ids);
            assertEq(amountIn, quoted.inputAmount);
            assertEq(trader.balance, nativeBefore - amountIn);
            assertEq(address(router).balance, 0);
            assertEq(programs.points(campaign, trader), quoted.actualQuote);
            assertEq(rules.claimable(quote, trader), quoted.quoteRefund);
            assertEq(manager.balanceOf(address(rules), quote.toId()), rules.totalLiability(quote));
            vm.prank(trader);
            uint256 refund = rules.claim(quote);
            assertEq(refund, quoted.quoteRefund);
            assertEq(trader.balance, nativeBefore - amountIn + quoted.quoteRefund);
            assertEq(amountIn - refund, quoted.actualQuote + quoted.quoteFee);
            assertEq(rules.claimable(quote, trader), 0);
            vm.prank(trader);
            vm.expectRevert(IHookrRulesState.NothingToClaim.selector);
            rules.claim(quote);
            assertEq(programs.claimableCash(campaign, trader), 0);
            assertEq(trader.balance, nativeBefore - amountIn + quoted.quoteRefund);
            assertTrue(rules.accountingInvariant(quote));
        }

        function testForgedAdvisoryQuoteResultIsRejected() public {
            HookrTypes.ExecutionReceipt memory fake;
            fake.payer = trader;
            fake.inputAmount = 1;
            fake.outputAmount = type(uint128).max;
            bytes memory forged = abi.encodeWithSelector(IHookrQuoter.QuoteResult.selector, fake);
            ForgedQuoteAdvice advice = new ForgedQuoteAdvice(forged);
            PoolKey memory key = _advisoryPool(advice);
            IHookrRouter.Swap memory p = _swap(key, true, true, 1 ether);
            vm.expectCall(address(advice), abi.encodeWithSelector(IHookrAdvisory.beforeSwap.selector));
            (bool ok, bytes memory reason) = address(quoter).call(abi.encodeCall(HookrQuoter.quote, (p, trader)));
            assertFalse(ok);
            assertEq(bytes4(reason), IHookrQuoter.SimulationFailed.selector);
            assertNotEq(keccak256(reason), keccak256(forged));
            (, PoolKey memory normal,,) = _launch(false, true);
            assertGt(quoter.quote(_swap(normal, true, true, 1 ether), trader).outputAmount, 0);
        }

        function testQuoterHelpersRejectCallsOutsideAuthenticatedUnlock() public {
            HookrQuoter.Request memory request;
            vm.expectRevert(IHookrQuoter.InvalidCallback.selector);
            quoter.simulate(request);
            vm.expectRevert(IHookrQuoter.InvalidCallback.selector);
            quoter.unlockCallback("");
            vm.prank(address(manager));
            vm.expectRevert(IHookrQuoter.InvalidCallback.selector);
            quoter.unlockCallback("");
        }

        function _callbackPool() private returns (CallbackAsset asset, PoolKey memory key) {
            asset = new CallbackAsset();
            asset.approve(address(launcher), type(uint256).max);
            asset.transfer(trader, 1e27);
            vm.prank(trader);
            asset.approve(address(router), type(uint256).max);
            IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
            members[0] = _member(Currency.wrap(address(tokenB)));
            (bytes32 family,) = launcher.launch(
                IHookrLauncher.Token(address(asset), "", "", 0, bytes32(0)),
                address(root),
                members,
                vm.getBlockTimestamp()
            );
            key = launcher.position(family, 0).key;
        }

        function _attack(IHookrRouter.Swap memory p) private pure returns (bytes memory) {
            return abi.encodeCall(HookrRouter.swap, (p, address(0), new uint256[](0)));
        }

        /// @dev An Immediate points program on `key`'s native-quote pool, one point per unit of quote volume.
        function _nativeCampaign(PoolKey memory key) private returns (HookrPrograms programs, uint256 id) {
            programs =
                new HookrPrograms(manager, address(router), address(this), 1e30, address(new HookrReferralRegistry()));
            P.Terms memory t;
            t.mode = P.Mode.Immediate;
            t.start = uint64(vm.getBlockTimestamp());
            t.end = uint64(vm.getBlockTimestamp() + 1 days);
            t.pointBudget = 1e30;
            t.walletPointCap = 1e30;
            t.pointNumerator = 1;
            t.pointDenominator = 1;
            t.sourcePolicyHash = keccak256("authenticated-router-user-swap");
            t.name = "Receipts";
            t.pointDecimals = 18;
            P.Scope[] memory s = new P.Scope[](1);
            s[0] = P.Scope(
                address(root), PoolId.unwrap(key.toId()), root.policyHash(key.toId()), address(0), 1, 1, 0, 0
            );
            id = programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
        }

        function _advisoryPool(ForgedQuoteAdvice advice) private returns (PoolKey memory key) {
            IHookrRegistry.Admission memory admission = IHookrRegistry.Admission(
                IHookrRegistry.Kind.ADVISORY,
                address(advice),
                address(advice).codehash,
                advice.configSchemaHash(),
                HookrTypes.Caps(0, 0, 0),
                2_000_000,
                1,
                false,
                false
            );
            registry.queue(registry.ADMIT(), abi.encode(address(root), admission));
            registry.queue(registry.SET_LAUNCHER(), abi.encode(address(this), true));
            vm.warp(vm.getBlockTimestamp() + registry.delay());
            registry.admit(address(root), admission);
            registry.setLauncher(address(this), true);
            bool first = address(tokenA) < address(tokenB);
            key = PoolKey(
                Currency.wrap(first ? address(tokenA) : address(tokenB)),
                Currency.wrap(first ? address(tokenB) : address(tokenA)),
                0x800000,
                60,
                IHooks(address(root))
            );
            IHookrLauncher.Member memory m = _member(Currency.wrap(address(tokenB)));
            m.config.subject = Currency.wrap(address(tokenA));
            m.config.quote = Currency.wrap(address(tokenB));
            m.config.liquidityOwner = address(this);
            m.config.advisory = address(advice);
            m.config.advisoryGasLimit = 2_000_000;
            m.config.advisoryPhases = 1;
            root.initializePool(key, m.config, abi.encode(m.rules), "", SQRT_ONE);
        }
    }
