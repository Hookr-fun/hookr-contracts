// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookrForwarder} from "../../src/gasless/HookrForwarder.sol";
import {IHookrForwarder} from "../../src/interfaces/IHookrForwarder.sol";
import {GaslessToken, MockRegistry, MockRoot, MockPermit2, MockRouter} from "./GaslessMocks.sol";

contract HookrForwarderTest is Test {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant PARITY_FORWARDER = 0x27a3A6997778f7F4D7E9D1fdCfBfFA252C678126;
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
        i.relayer = RELAYER; // a nonzero fee binds the relayer
        i.relayerFee = fee;
        i.nonce = 3;
        i.deadline = block.timestamp + 60;
    }

    /// @dev §5.3 parity vector (viem digest 0xe969…1af0): witness hash and type hash constants.
    function test_witnessParityVector() public {
        vm.chainId(4663);
        HookrForwarder f = new HookrForwarder(PERMIT2, address(registry), PARITY_FORWARDER);
        IHookrForwarder.HookrSwapIntent memory i;
        i.key = PoolKey(
            Currency.wrap(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73),
            Currency.wrap(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168),
            0x800000,
            60,
            IHooks(0x00000000000000000000000000000000000028cC)
        );
        i.amountSpecified = -1000000;
        i.amountBound = 1;
        i.recipient = address(0x1002);
        i.relayerFee = 5000;
        i.campaigns = new uint256[](2);
        i.campaigns[0] = 7;
        i.campaigns[1] = 9;
        i.nonce = 3;
        i.deadline = 1900000000;
        assertEq(f.INTENT_TYPEHASH(), 0x8a1d63440958dad57e09e33e2a72a054d01c8f16d5e2a88bf731f94a2f6a6302);
        assertEq(f.hashIntent(i), 0x6c80ff3c4efaefeddff7ed45c4ab716343922e78defa64a82dbd03b6883bdec7);
        assertEq(
            keccak256(
                bytes(
                    string.concat(
                        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                        f.WITNESS_TYPE_STRING()
                    )
                )
            ),
            0x0cb0aa37b0abe084e6b7619bb8b8cdd65e2111a5bf0758314eae62645fbfc95f
        );
    }

    function test_buy_exactInput_feeFromInput() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(true, -1000, 10);
        root.setQuote(i.key.currency0); // input is quote → buy, fee from input
        GaslessToken input = GaslessToken(Currency.unwrap(i.key.currency0));
        input.mint(OWNER, 1010);
        vm.prank(OWNER);
        input.approve(PERMIT2, type(uint256).max);
        router.set(1000, 500);
        (address tok, uint256 amt, bool fromInput) = fwd.pullOf(i);
        assertEq(tok, address(input));
        assertEq(amt, 1010);
        assertTrue(fromInput);
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
        assertEq(input.balanceOf(RELAYER), 10);
        assertEq(input.balanceOf(address(fwd)), 0);
        assertEq(input.allowance(address(fwd), address(router)), 0);
        assertEq(router.lastPayer(), OWNER);
        assertEq(router.lastFee(), 0);
        assertTrue(fwd.isNonceUsed(OWNER, 3));
        assertEq(MockPermit2(PERMIT2).lastWitness(), fwd.hashIntent(i));
    }

    function test_sell_exactOutput_refund_feeFromOutput() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(true, 500, 20);
        i.amountBound = 1000; // max input
        root.setQuote(i.key.currency1); // output is quote → sell, fee from output
        GaslessToken input = GaslessToken(Currency.unwrap(i.key.currency0));
        input.mint(OWNER, 1000);
        vm.prank(OWNER);
        input.approve(PERMIT2, type(uint256).max);
        router.set(700, 500);
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
        assertEq(input.balanceOf(OWNER), 300); // refund of maxIn - amountIn
        assertEq(router.lastFee(), 20);
        assertEq(router.lastFeeRecipient(), RELAYER);
        assertEq(input.balanceOf(address(fwd)), 0);
    }

    function test_errors() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(true, -1000, 0);
        root.setQuote(i.key.currency0);
        i.relayer = address(0xBAD);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.WrongRelayer.selector, address(0xBAD), RELAYER));
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
        i.relayer = address(0);
        i.relayerFee = 1;
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.InvalidIntent.selector, 6));
        fwd.execute(i, OWNER, "");
        i.relayerFee = 0;
        i.amountSpecified = 0;
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.InvalidIntent.selector, 1));
        fwd.execute(i, OWNER, "");
        i.amountSpecified = -1000;
        i.recipient = address(router);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.InvalidIntent.selector, 3));
        fwd.execute(i, OWNER, "");
        i.recipient = address(0x1002);
        i.campaigns = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.InvalidIntent.selector, 4));
        fwd.execute(i, OWNER, "");
        i.campaigns = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.InvalidIntent.selector, 5));
        fwd.execute(i, address(0), "");
        i.deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.IntentExpired.selector, i.deadline, block.timestamp));
        fwd.execute(i, OWNER, "");
    }

    function test_unsupportedPool_and_nativeInput() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(true, -1000, 0);
        i.key.hooks = IHooks(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.UnsupportedPool.selector, address(0xDEAD)));
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
        i = _intent(true, -1000, 0);
        i.key.currency0 = Currency.wrap(address(0));
        vm.expectRevert(IHookrForwarder.NativeInputUnsupported.selector);
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
    }

    function test_nonceDerivation() public view {
        uint256 n = fwd.permit2Nonce(0x1ff);
        uint248 word =
            uint248(uint256(keccak256(abi.encode(keccak256("hookr.forwarder.nonce"), address(fwd), uint256(1)))));
        assertEq(n, (uint256(word) << 8) | 0xff);
        (uint256 pos, uint256 mask) = fwd.nonceWord(0x1ff);
        assertEq(pos, uint256(word));
        assertEq(mask, uint256(1) << 0xff);
        assertEq(fwd.releaseId(), 1);
    }
}
