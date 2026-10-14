// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookrForwarder} from "../../src/gasless/HookrForwarder.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrForwarder} from "../../src/interfaces/IHookrForwarder.sol";
import {GaslessToken, MockRegistry, MockRoot, MockPermit2, MockRouter} from "./GaslessMocks.sol";

/// @notice A registered root without the narrow route read (a lane root): the Forwarder falls back to poolConfig.
contract PoolConfigOnlyRoot {
    Currency public quote;
    address public advisory;

    function set(Currency q, address a) external {
        quote = q;
        advisory = a;
    }

    function poolConfig(bytes32) external view returns (HookrTypes.PoolConfig memory pc) {
        pc.quote = quote;
        pc.advisory = advisory;
    }
}

/// @notice F-055: a nonzero relayer fee requires a bound relayer. F-058: an output-side relayer fee is refused on a
///         pool with an advisory. F-044: the Forwarder has no sweep; stray tokens are never spent by an intent.
contract HookrForwarderFeesTest is Test {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant OWNER = address(0xA11CE);
    address constant RELAYER = address(0xFEE);

    MockRegistry registry = new MockRegistry();
    MockRoot root = new MockRoot();
    MockRouter router = new MockRouter();
    GaslessToken t0 = new GaslessToken();
    GaslessToken t1 = new GaslessToken();
    HookrForwarder fwd;

    function setUp() public {
        vm.etch(PERMIT2, address(new MockPermit2()).code);
        fwd = new HookrForwarder(PERMIT2, address(registry), address(router));
        registry.set(address(root));
    }

    function _intent(bool zeroForOne, int128 amt, uint256 fee)
        internal
        view
        returns (IHookrForwarder.HookrSwapIntent memory i)
    {
        (address a, address b) = address(t0) < address(t1) ? (address(t0), address(t1)) : (address(t1), address(t0));
        i.key = PoolKey(Currency.wrap(a), Currency.wrap(b), 0x800000, 60, IHooks(address(root)));
        i.zeroForOne = zeroForOne;
        i.amountSpecified = amt;
        i.amountBound = 1;
        i.recipient = address(0x1002);
        i.relayer = RELAYER;
        i.relayerFee = fee;
        i.nonce = 3;
        i.deadline = block.timestamp + 60;
    }

    function _fund(IHookrForwarder.HookrSwapIntent memory i, uint256 amount) internal {
        GaslessToken input = GaslessToken(Currency.unwrap(i.zeroForOne ? i.key.currency0 : i.key.currency1));
        input.mint(OWNER, amount);
        vm.prank(OWNER);
        input.approve(PERMIT2, type(uint256).max);
    }

    function test_openRelayWithFeeRefused() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(true, -1000, 10);
        root.setQuote(i.key.currency0);
        i.relayer = address(0);
        _fund(i, 1010);
        router.set(1000, 500);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.InvalidIntent.selector, 6));
        fwd.execute(i, OWNER, "");
        // An open intent without a fee, and a bound intent with one, still execute.
        i.relayerFee = 0;
        vm.prank(address(0xBEEF));
        fwd.execute(i, OWNER, "");
        IHookrForwarder.HookrSwapIntent memory bound = _intent(true, -1000, 10);
        bound.nonce = 4;
        _fund(bound, 1010);
        vm.prank(RELAYER);
        fwd.execute(bound, OWNER, "");
        assertEq(GaslessToken(Currency.unwrap(bound.key.currency0)).balanceOf(RELAYER), 10);
    }

    function test_outputFeeOnAdvisedPoolRefused() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(true, -1000, 20);
        root.setQuote(i.key.currency1); // output is the quote: a sell with an output-side fee
        root.setAdvisory(address(0xAD));
        _fund(i, 1000);
        router.set(1000, 500);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.OutputFeeOnAdvisedPool.selector, address(0xAD)));
        fwd.pullOf(i);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.OutputFeeOnAdvisedPool.selector, address(0xAD)));
        fwd.execute(i, OWNER, "");
        // No fee, or an input-side fee, is still allowed on the advised pool.
        i.relayerFee = 0;
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
        IHookrForwarder.HookrSwapIntent memory buy = _intent(true, -1000, 10);
        buy.nonce = 5;
        root.setQuote(buy.key.currency0);
        _fund(buy, 1010);
        vm.prank(RELAYER);
        fwd.execute(buy, OWNER, "");
        // Without an advisory the output-side fee is paid.
        root.setAdvisory(address(0));
        root.setQuote(i.key.currency1);
        IHookrForwarder.HookrSwapIntent memory sell = _intent(true, -1000, 20);
        sell.nonce = 6;
        _fund(sell, 1000);
        vm.prank(RELAYER);
        fwd.execute(sell, OWNER, "");
        assertEq(router.lastFee(), 20);
        assertEq(router.lastFeeRecipient(), RELAYER);
    }

    function test_poolConfigFallbackForRootsWithoutRouteRead() public {
        PoolConfigOnlyRoot legacy = new PoolConfigOnlyRoot();
        registry.set(address(legacy));
        IHookrForwarder.HookrSwapIntent memory i = _intent(true, -1000, 20);
        i.key.hooks = IHooks(address(legacy));
        legacy.set(i.key.currency1, address(0xAD));
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.OutputFeeOnAdvisedPool.selector, address(0xAD)));
        fwd.pullOf(i);
        legacy.set(i.key.currency1, address(0));
        (, uint256 amount, bool fromInput) = fwd.pullOf(i);
        assertEq(amount, 1000);
        assertFalse(fromInput);
        legacy.set(i.key.currency0, address(0xAD));
        (, amount, fromInput) = fwd.pullOf(i);
        assertEq(amount, 1020, "input-side fee allowed on an advised pool");
        assertTrue(fromInput);
    }

    function test_strayTokensAreNeverSpentOrSwept() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(true, -1000, 0);
        root.setQuote(i.key.currency0);
        GaslessToken input = GaslessToken(Currency.unwrap(i.key.currency0));
        input.mint(address(fwd), 5000); // a mistaken direct transfer
        _fund(i, 1000);
        router.set(1000, 500);
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
        assertEq(input.balanceOf(address(fwd)), 5000, "stray balance untouched");
        assertEq(input.balanceOf(OWNER), 0, "the intent spent only the signer's pull");
        (bool ok,) = address(fwd).call(abi.encodeWithSignature("sweep(address,address)", address(input), OWNER));
        assertFalse(ok, "no sweep");
        (ok,) = address(fwd).call(abi.encodeWithSignature("sweep(address)", address(input)));
        assertFalse(ok, "no sweep");
    }
}
