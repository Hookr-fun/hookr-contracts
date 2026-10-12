// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm, console2} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {GasBenchFixture, IUniversalRouter, IPermit2Bench} from "../utils/GasBenchFixture.sol";
import {Chain4663Code} from "../bench/Chain4663Code.sol";

/// Hookr dynamic fee pools through the 4663 PoolManager and Universal Router 2.1.1: multi-hop exact input and exact
/// output equal the chained HookrQuoter quotes, a round trip through one pool in one unlock equals two router swaps,
/// every shape's quote equals its execution under a v4 protocol fee, and only the root reaches its fallback. Runs on
/// the etched runtimes, and on a live 4663 fork in `HookrDynamicFeeIntegrationFork`.
contract HookrDynamicFeeIntegrationTest is GasBenchFixture {
    using PoolIdLibrary for PoolKey;

    struct PathKey {
        Currency intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        IHooks hooks;
        bytes hookData;
    }

    struct ExactInputParams {
        Currency currencyIn;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    struct ExactOutputParams {
        Currency currencyOut;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountOut;
        uint128 amountInMaximum;
    }

    PoolKey internal key2; // (subject, quotes[0]) dynamic fee pool
    PoolKey internal rulesOnlyKey; // (subject, quotes[1]) Rules pool without dynamic fee

    function setUp() public virtual override {
        super.setUp();
        bytes32 f2 = _launchOne(Currency.wrap(address(quotes[0])), 60, true);
        key2 = launcher.position(f2, 0).key;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(quotes[1])), 60, true);
        members[0].rules.maxFeePips = 3000;
        members[0].rules.dynamicFeeSens = 0;
        (bytes32 f3,) = launcher.launch(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        rulesOnlyKey = launcher.position(f3, 0).key;
        for (uint256 i; i < 2; ++i) {
            quotes[i].transfer(trader, 1e27);
            vm.startPrank(trader);
            quotes[i].approve(address(router), type(uint256).max);
            quotes[i].approve(permit2, type(uint256).max);
            IPermit2Bench(permit2).approve(address(quotes[i]), ur, type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }
        // Give every dynamic fee pool a history: two swaps in different blocks.
        _warm2(fullKey);
        _warm2(key2);
        _warm2(rulesOnlyKey);
    }

    /// @dev A variant without the fork's RPC skips every test.
    function _skipped() internal virtual returns (bool) {
        return false;
    }

    function _warm2(PoolKey memory key) internal {
        _routerSwap(key, true, 1e21);
        _nextBlock();
        _routerSwap(key, false, 5e20);
        _nextBlock();
    }

    function _pk(Currency c, PoolKey memory k) internal pure returns (PathKey memory) {
        return PathKey(c, k.fee, k.tickSpacing, k.hooks, "");
    }

    function _bal(HookrToken t) internal view returns (uint256) {
        return t.balanceOf(trader);
    }

    function _q(PoolKey memory key, bool buy, int128 amountSpecified)
        internal
        returns (HookrTypes.ExecutionReceipt memory)
    {
        bool zfo = _zeroForOne(key, buy);
        IHookrRouter.Swap memory p = IHookrRouter.Swap(
            key,
            zfo,
            amountSpecified,
            amountSpecified < 0 ? 1 : type(uint128).max,
            zfo ? MIN_PRICE : MAX_PRICE,
            trader,
            vm.getBlockTimestamp() + 1000
        );
        return quoter.quote(p, trader);
    }

    /// Universal Router SWAP_EXACT_IN quoteFull -> subject -> quotes[0] through two dynamic fee pools equals the chained quoter.
    function testURMultiHopExactInEqualsChainedQuote() public {
        if (_skipped()) return;
        uint128 amountIn = 3e22;
        HookrTypes.ExecutionReceipt memory h1 = _q(fullKey, true, -int128(amountIn));
        HookrTypes.ExecutionReceipt memory h2 = _q(key2, false, -int128(uint128(h1.outputAmount)));
        console2.log("hop1 lpFeePips", h1.lpFeePips, "hop2 lpFeePips", h2.lpFeePips);
        assertGt(h1.lpFeePips, 3000 + 2000 - 500, "hop1 carries a dynamic fee");

        PathKey[] memory path = new PathKey[](2);
        path[0] = _pk(Currency.wrap(address(subject)), fullKey);
        path[1] = _pk(Currency.wrap(address(quotes[0])), key2);
        bytes memory actions = abi.encodePacked(uint8(0x07), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputParams(
                Currency.wrap(address(quoteFull)), path, new uint256[](0), amountIn, uint128(h2.outputAmount)
            )
        );
        params[1] = abi.encode(Currency.wrap(address(quoteFull)), uint256(amountIn));
        params[2] = abi.encode(Currency.wrap(address(quotes[0])), uint256(1));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 in0 = _bal(quoteFull);
        uint256 out0 = _bal(quotes[0]);
        vm.prank(trader, trader);
        IUniversalRouter(ur).execute(hex"10", inputs, vm.getBlockTimestamp() + 1000);
        Vm.Gas memory g = vm.lastCallGas();
        console2.log("UR 2-hop exact-in gas (non-isolated)", g.gasTotalUsed);
        assertEq(in0 - _bal(quoteFull), amountIn, "input");
        assertEq(_bal(quotes[0]) - out0, h2.outputAmount, "UR multi-hop output equals chained quote");
    }

    /// Universal Router SWAP_EXACT_OUT through the same two pools (executed in reverse order) equals the chained quoter.
    function testURMultiHopExactOutEqualsChainedQuote() public {
        if (_skipped()) return;
        uint128 amountOut = 2e22;
        HookrTypes.ExecutionReceipt memory h2 = _q(key2, false, int128(amountOut));
        HookrTypes.ExecutionReceipt memory h1 = _q(fullKey, true, int128(uint128(h2.inputAmount)));
        console2.log("hop1 lpFeePips", h1.lpFeePips, "hop2 lpFeePips", h2.lpFeePips);

        PathKey[] memory path = new PathKey[](2);
        path[0] = _pk(Currency.wrap(address(quoteFull)), fullKey);
        path[1] = _pk(Currency.wrap(address(subject)), key2);
        bytes memory actions = abi.encodePacked(uint8(0x09), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactOutputParams(
                Currency.wrap(address(quotes[0])), path, new uint256[](0), amountOut, uint128(h1.inputAmount)
            )
        );
        params[1] = abi.encode(Currency.wrap(address(quoteFull)), uint256(h1.inputAmount));
        params[2] = abi.encode(Currency.wrap(address(quotes[0])), uint256(amountOut));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 in0 = _bal(quoteFull);
        uint256 out0 = _bal(quotes[0]);
        vm.prank(trader, trader);
        IUniversalRouter(ur).execute(hex"10", inputs, vm.getBlockTimestamp() + 1000);
        assertEq(in0 - _bal(quoteFull), h1.inputAmount, "UR multi-hop input equals chained quote");
        assertEq(_bal(quotes[0]) - out0, amountOut, "output");
    }

    /// A Universal Router round trip through the same dynamic fee pool twice (buy then sell in one unlock) equals two
    /// sequential Hookr router swaps in the same block and timestamp.
    function testURSamePoolRoundTripEqualsSequential() public {
        if (_skipped()) return;
        uint128 amountIn = 3e22;
        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        (, uint256 s) = router.swap(_params(fullKey, true, amountIn), address(0), new uint256[](0));
        vm.prank(trader);
        (, uint256 y) = router.swap(_params(fullKey, false, uint128(s)), address(0), new uint256[](0));
        vm.revertToState(snap);

        PathKey[] memory path = new PathKey[](2);
        path[0] = _pk(Currency.wrap(address(subject)), fullKey);
        path[1] = _pk(Currency.wrap(address(quoteFull)), fullKey);
        bytes memory actions = abi.encodePacked(uint8(0x07), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputParams(Currency.wrap(address(quoteFull)), path, new uint256[](0), amountIn, 1));
        params[1] = abi.encode(Currency.wrap(address(quoteFull)), uint256(amountIn));
        params[2] = abi.encode(Currency.wrap(address(quoteFull)), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 b0 = _bal(quoteFull);
        vm.prank(trader, trader);
        IUniversalRouter(ur).execute(hex"10", inputs, vm.getBlockTimestamp() + 1000);
        uint256 b1 = _bal(quoteFull);
        console2.log("router round trip returns", y, "UR round trip returns", b1 + amountIn - b0);
        assertEq(b1 + amountIn - b0, y, "UR same-pool round trip equals sequential router swaps");
    }

    /// With a v4 protocol fee on the pool (1,000 pips each way), quote equals execution in all four shapes.
    function testProtocolFeeQuoteEqualsExecution() public {
        if (_skipped()) return;
        address controller = address(uint160(uint256(vm.load(address(manager), bytes32(uint256(1))))));
        (bool okc, bytes memory outc) = address(manager).staticcall(abi.encodeWithSignature("protocolFeeController()"));
        if (okc && outc.length == 32) controller = abi.decode(outc, (address));
        vm.prank(controller);
        (bool ok,) = address(manager)
            .call(
                abi.encodeWithSignature(
                    "setProtocolFee((address,address,uint24,int24,address),uint24)",
                    fullKey,
                    uint24(1000 | (1000 << 12))
                )
            );
        require(ok, "setProtocolFee");
        (,, uint24 pf,) = StateLibrary.getSlot0(manager, fullKey.toId());
        console2.log("protocol fee word", pf);
        bool[2] memory flags = [true, false];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                bool buy = flags[i];
                bool exactInput = flags[j];
                bool zfo = _zeroForOne(fullKey, buy);
                IHookrRouter.Swap memory p = IHookrRouter.Swap(
                    fullKey,
                    zfo,
                    exactInput ? -int128(5e22) : int128(5e22),
                    exactInput ? 1 : type(uint128).max,
                    zfo ? MIN_PRICE : MAX_PRICE,
                    trader,
                    vm.getBlockTimestamp() + 1000
                );
                HookrTypes.ExecutionReceipt memory q = quoter.quote(p, trader);
                vm.prank(trader);
                (uint256 input, uint256 output) = router.swap(p, address(0), new uint256[](0));
                console2.log(buy ? "buy" : "sell", exactInput ? "exact in" : "exact out", q.lpFeePips);
                assertEq(q.inputAmount, input, "quote input");
                assertEq(q.outputAmount, output, "quote output");
                _nextBlock();
            }
        }
    }

    /// The root fallback: an empty call returns 1, any foreign call with data reverts Unauthorized, value reverts.
    function testRootFallbackSurface() public {
        if (_skipped()) return;
        (bool ok, bytes memory out) = address(root).staticcall("");
        assertTrue(ok);
        assertEq(abi.decode(out, (uint256)), 1);
        (ok, out) = address(root).call(abi.encodeWithSignature("lane()"));
        assertFalse(ok);
        console2.logBytes(out);
        (ok,) = address(root).call(new bytes(288));
        assertFalse(ok, "simulation input from outside");
        (ok,) = address(root).call(new bytes(704));
        assertFalse(ok, "quote input from outside");
        (ok,) = address(root).call{value: 1}("");
        assertFalse(ok, "no receive");
        assertTrue(rules.rootSimulates());
    }
}

/// The same checks on a live 4663 fork (the PoolManager, Universal Router and Permit2 with their storage). Skipped
/// unless ALCHEMY_RPC_URL is set.
contract HookrDynamicFeeIntegrationFork is HookrDynamicFeeIntegrationTest {
    uint256 internal constant FORK_BLOCK = 72_107_166;
    bool internal live;
    bytes32 internal liveManagerHash;
    bytes32 internal liveRouterHash;

    function setUp() public override {
        string memory url = vm.envOr("ALCHEMY_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url, FORK_BLOCK);
        live = true;
        liveManagerHash = Chain4663Code.POOL_MANAGER_ADDRESS.codehash;
        liveRouterHash = Chain4663Code.UNIVERSAL_ROUTER_ADDRESS.codehash;
        super.setUp();
    }

    function _skipped() internal override returns (bool) {
        if (!live) vm.skip(true);
        return !live;
    }

    /// The etched runtimes the other suites run on are the live ones.
    function testEtchedRuntimesEqualLiveCode() public {
        if (_skipped()) return;
        assertEq(liveManagerHash, keccak256(Chain4663Code.POOL_MANAGER), "live PoolManager runtime");
        assertEq(liveRouterHash, keccak256(Chain4663Code.UNIVERSAL_ROUTER), "live Universal Router runtime");
    }
}
