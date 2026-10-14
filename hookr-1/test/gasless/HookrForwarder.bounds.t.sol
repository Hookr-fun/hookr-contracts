// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookrForwarder} from "../../src/gasless/HookrForwarder.sol";
import {IHookrForwarder} from "../../src/interfaces/IHookrForwarder.sol";
import {GaslessToken, MockRegistry, MockRoot, MockPermit2, MockRouter} from "./GaslessMocks.sol";

/// @notice The forwarder's intent bounds at their edges, each with a mutation-gate id: the campaign limit (FW-3), the
///         exact pull (FW-5), the relayer fee against the minimum output (FW-6) and the one amount an int128 cannot
///         negate (FW-7).
contract HookrForwarderBoundsTest is Test {
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

    /// FW-3: eight campaigns are the most an intent may name, nine are refused.
    function test_nineCampaignsAreRefused() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(true, -1000, 0);
        root.setQuote(i.key.currency0);
        i.engagement = address(0xE6A6);
        i.campaigns = new uint256[](9);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.InvalidIntent.selector, 4));
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
        i.campaigns = new uint256[](8);
        _fund(i, 1000);
        router.set(1000, 500);
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
    }

    /// FW-5: the Permit2 pull must deliver exactly what the intent needs; a unit short is refused, the whole not.
    function test_aShortPullIsRefused() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(true, -1000, 0);
        root.setQuote(i.key.currency0);
        _fund(i, 1000);
        router.set(1000, 500);
        MockPermit2(PERMIT2).setShort(1);
        address input = Currency.unwrap(i.key.currency0);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.InexactPull.selector, input, 1000, 999));
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
        MockPermit2(PERMIT2).setShort(0);
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
    }

    /// FW-6: an output-side relayer fee may equal the exact-output amount (the recipient's minimum is then zero) and
    /// not a unit more.
    function test_aRelayerFeeEqualToTheOutputIsAccepted() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(true, 500, 500);
        i.amountBound = 1000;
        root.setQuote(i.key.currency1);
        _fund(i, 1000);
        router.set(700, 500);
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
        assertEq(router.lastFee(), 500);
        i = _intent(true, 500, 501);
        i.amountBound = 1000;
        i.nonce = 4;
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.InvalidIntent.selector, 7));
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
    }

    /// FW-7: int128.min cannot be negated to an input amount: refused with the amount-field code.
    function test_int128MinAmountIsRefused() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(true, type(int128).min, 0);
        root.setQuote(i.key.currency0);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.InvalidIntent.selector, 1));
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
    }
}
