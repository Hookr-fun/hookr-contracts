// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {ModuleErrors} from "../utils/ModuleErrors.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

/// @notice Anti-Snipe decay: the tax falls from snipeTaxPips to snipeFloorPips over snipeDecaySeconds of
///         block.timestamp after launch, on floor + span * left / duration. The per-block buy cap grows as the tax
///         falls; the cap, the exact-output refusal and the outside-liquidity refusal follow the block-number guard.
contract SnipeDecayTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant START = 500_000;
    uint24 internal constant FLOOR = 10_000;
    uint16 internal constant DECAY = 120;
    uint16 internal constant SHARE = 2500;
    uint256 internal constant GUARD = 100;

    function setUp() public {
        _setUpPeriphery();
    }

    /// @dev A native-quote member with only Anti-Snipe and the protocol share: no dynamic fee, LP Rewards, burn or royalty.
    function _snipeMember(uint24 start, uint24 floor, uint16 decay, uint128 cap, int24 spacing)
        internal
        view
        returns (IHookrLauncher.Member memory m)
    {
        m = _member(Currency.wrap(address(0)));
        m.tickSpacing = spacing;
        m.rules.burnBps = 0;
        m.rules.lpBps = 0;
        m.rules.royaltyBps = 0;
        m.rules.royaltyTo = address(0);
        m.rules.protocolShareBps = SHARE;
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + GUARD);
        m.rules.snipeTaxPips = start;
        m.rules.snipeFloorPips = floor;
        m.rules.snipeDecaySeconds = decay;
        m.rules.maxBuyQuoteAmount = cap;
    }

    function _launchMember(IHookrLauncher.Member memory m) internal returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function _launchSnipe(uint24 start, uint24 floor, uint16 decay, uint128 cap, int24 spacing)
        internal
        returns (PoolKey memory)
    {
        return _launchMember(_snipeMember(start, floor, decay, cap, spacing));
    }

    /// @dev Reference curve, written independently of HookrRules.
    function _curve(uint256 start, uint256 floor, uint256 duration, uint256 elapsed) internal pure returns (uint256) {
        if (duration == 0) return start;
        if (elapsed >= duration) return floor;
        return floor + (start - floor) * (duration - elapsed) / duration;
    }

    function _context(PoolKey memory key, bool buy, bool exactInput)
        internal
        view
        returns (HookrTypes.SwapContext memory x)
    {
        x.id = key.toId();
        x.sender = trader;
        x.payer = trader;
        x.beneficiary = trader;
        x.subject = Currency.wrap(address(tokenA));
        x.quote = Currency.wrap(address(0));
        x.authenticated = true;
        x.isBuy = buy;
        x.exactInput = exactInput;
        // The native quote is currency0, so a buy is zeroForOne.
        x.zeroForOne = buy;
        x.amountSpecified = exactInput ? -1e18 : int256(1e18);
        x.sqrtPriceLimitX96 = buy ? MIN_PRICE : MAX_PRICE;
        x.baseLpFeePips = 3000;
    }

    /// @dev The Rules quote for a 1 ETH exact-input buy, as the root sees it.
    function _buyQuote(PoolKey memory key) internal returns (HookrTypes.FeeQuote memory q) {
        vm.prank(address(root));
        q = rules.beforeSwap(_context(key, true, true));
    }

    /// @dev Asserts the quote is exactly `snipe` pips of Snipe split by the protocol share.
    function _assertSnipe(HookrTypes.FeeQuote memory q, uint256 snipe, string memory label) internal pure {
        uint256 protocolPips = snipe * SHARE / 10_000;
        assertEq(q.lpFeeSurchargePips, snipe - protocolPips, label);
        assertEq(q.quoteTakePips, protocolPips, label);
        assertEq(q.subjectBurnBps, 0, label);
    }

    function _warpTo(uint256 launchedAt, uint256 elapsed) internal {
        vm.warp(launchedAt + elapsed);
    }

    function testCurveAtKeyTimes() public {
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey memory key = _launchSnipe(START, FLOOR, DECAY, 0, 60);
        uint256[9] memory times = [uint256(0), 1, 2, 5, 10, 30, 60, 119, 120];
        // 50% to 1% over 120 s: floor + 490,000 * (120 - t) / 120, rounded down.
        uint256[9] memory pips =
            [uint256(500_000), 495_916, 491_833, 479_583, 459_166, 377_500, 255_000, 14_083, 10_000];
        for (uint256 i; i < times.length; ++i) {
            _warpTo(t0, times[i]);
            assertEq(_curve(START, FLOOR, DECAY, times[i]), pips[i], "reference curve");
            _assertSnipe(_buyQuote(key), pips[i], "decayed snipe");
        }
    }

    function testLaunchBlockPaysTheFullTax() public {
        PoolKey memory key = _launchSnipe(START, FLOOR, DECAY, 0, 60);
        _assertSnipe(_buyQuote(key), START, "same block as the launch");
    }

    function testBoundarySeconds() public {
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey memory key = _launchSnipe(START, FLOOR, DECAY, 0, 60);
        _warpTo(t0, DECAY - 1);
        _assertSnipe(_buyQuote(key), FLOOR + (START - FLOOR) / uint256(DECAY), "last decaying second");
        _warpTo(t0, DECAY);
        _assertSnipe(_buyQuote(key), FLOOR, "decay ends exactly at snipeDecaySeconds");
        _warpTo(t0, DECAY + 1);
        _assertSnipe(_buyQuote(key), FLOOR, "floor after the decay");
        _warpTo(t0, 1 days);
        _assertSnipe(_buyQuote(key), FLOOR, "floor holds for the rest of the guard");
    }

    function testFuzzCurveMatchesReferenceAndNeverRises(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 2 * uint256(DECAY));
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey memory key = _launchSnipe(START, FLOOR, DECAY, 0, 60);
        _warpTo(t0, elapsed);
        HookrTypes.FeeQuote memory now_ = _buyQuote(key);
        uint256 snipe = _curve(START, FLOOR, DECAY, elapsed);
        _assertSnipe(now_, snipe, "reference");
        assertLe(snipe, START, "at most the start");
        assertGe(snipe, FLOOR, "at least the floor");
        _warpTo(t0, elapsed + 1);
        HookrTypes.FeeQuote memory next = _buyQuote(key);
        assertLe(next.lpFeeSurchargePips, now_.lpFeeSurchargePips, "LP part never rises");
        assertLe(next.quoteTakePips, now_.quoteTakePips, "protocol part never rises");
    }

    function testFlatModeUnchanged() public {
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey memory flat = _launchSnipe(START, 0, 0, 0, 60);
        uint256[4] memory times = [uint256(0), 1, 3600, 30 days];
        for (uint256 i; i < times.length; ++i) {
            _warpTo(t0, times[i]);
            HookrTypes.FeeQuote memory q = _buyQuote(flat);
            // The pre-decay formula: 500,000 pips of Snipe, 25% of it as the protocol's quote take.
            assertEq(q.lpFeeSurchargePips, 375_000, "flat LP part");
            assertEq(q.quoteTakePips, 125_000, "flat protocol part");
        }
    }

    /// @dev A decay needs a span: a floor equal to the start is refused, and the flat form (no decay) charges it.
    function testFloorEqualToStartIsRefusedAndFlatChargesIt() public {
        _expectBindRefused(_snipeMember(START, START, DECAY, 0, 60));
        _expectBindRefused(_snipeMember(0, 0, DECAY, 0, 60));
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey memory key = _launchSnipe(START, 0, 0, 0, 60);
        for (uint256 t; t <= DECAY + 1; t += 11) {
            _warpTo(t0, t);
            _assertSnipe(_buyQuote(key), START, "flat never decays");
        }
    }

    function testSellsPayNoSnipeAndGuardEndStopsIt() public {
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey memory key = _launchSnipe(START, FLOOR, 3600, 0, 60);
        _warpTo(t0, 10);
        vm.prank(address(root));
        HookrTypes.FeeQuote memory sell = rules.beforeSwap(_context(key, false, true));
        assertEq(sell.lpFeeSurchargePips, 0, "sell LP surcharge");
        assertEq(sell.quoteTakePips, 0, "sell take");
        // The block-number guard ends while the tax is still decaying: buys stop paying Snipe at once.
        vm.roll(vm.getBlockNumber() + GUARD);
        _assertSnipe(_buyQuote(key), 0, "no Snipe once the guard ends");
    }

    /// @dev A decaying pool at `elapsed` charges exactly what a flat pool at the decayed tax charges: the same
    ///      output for the trader and the same protocol claim.
    function testProtocolShareOfDecayedSnipe() public {
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey memory decaying = _launchSnipe(START, FLOOR, DECAY, 0, 60);
        uint24 at30 = uint24(_curve(START, FLOOR, DECAY, 30));
        assertEq(at30, 377_500);
        PoolKey memory flat = _launchSnipe(at30, 0, 0, 0, 120);
        _warpTo(t0, 30);
        Currency eth = Currency.wrap(address(0));
        (uint256 claimDecaying, uint256 outDecaying) = _buy(decaying, eth);
        (uint256 claimFlat, uint256 outFlat) = _buy(flat, eth);
        assertGt(claimDecaying, 0, "protocol paid");
        assertEq(claimDecaying, claimFlat, "protocol share of the decayed Snipe");
        assertEq(outDecaying, outFlat, "trader output");
        // 1 ETH gross spend, 25% of 377,500 pips as the quote take.
        assertApproxEqAbs(
            claimDecaying, uint256(1e18) * (377_500 * uint256(SHARE) / 10_000) / 1e6, 1, "take on gross spend"
        );
        assertTrue(rules.accountingInvariant(eth));
    }

    function _buy(PoolKey memory key, Currency eth) internal returns (uint256 claim, uint256 out) {
        uint256 claimBefore = rules.claimable(eth, protocol);
        uint256 balanceBefore = tokenA.balanceOf(trader);
        vm.prank(trader);
        router.swap{value: 1e18}(_swap(key, true, true, 1e18), address(0), new uint256[](0));
        claim = rules.claimable(eth, protocol) - claimBefore;
        out = tokenA.balanceOf(trader) - balanceBefore;
    }

    /// @dev After the tax reaches its floor, the guard's other rules still hold until guardEndBlock, and the buy cap
    ///      holds at cap * start / floor.
    function testGuardRulesOutliveTheDecay() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint128 cap = 1e16;
        PoolKey memory key = _launchSnipe(START, FLOOR, 60, cap, 60);
        _warpTo(t0, 600);
        _assertSnipe(_buyQuote(key), FLOOR, "floor");

        uint128 limit = uint128(uint256(cap) * START / FLOOR);
        vm.startPrank(trader);
        router.swap{value: cap}(_swap(key, true, true, cap), address(0), new uint256[](0));
        router.swap{value: limit - cap}(_swap(key, true, true, limit - cap), address(0), new uint256[](0));
        (bool ok, bytes memory ret) = address(router).call{value: 1e15}(
            abi.encodeCall(HookrRouter.swap, (_swap(key, true, true, 1e15), address(0), new uint256[](0)))
        );
        vm.stopPrank();
        assertFalse(ok, "buy cap");
        (,,, bytes memory inner) = ModuleErrors.unwrap(ret);
        (bool found, address module, bytes4 selector, bytes memory reason) = ModuleErrors.reverted(inner);
        assertTrue(found && module == address(rules) && selector == IHookrRules.settleSwap.selector, "in settleSwap");
        assertEq(bytes4(reason), IHookrRulesState.GuardBuyLimit.selector, "refused by GuardBuyLimit");
        (uint256 spent, uint256 capAt) = abi.decode(ModuleErrors.body(reason), (uint256, uint256));
        assertEq(capAt, limit, "the cap at cap * start / floor");
        assertGt(spent, limit);

        PoolId id = key.toId();
        vm.prank(address(root));
        vm.expectRevert(IHookrRulesState.GuardExactOutput.selector);
        rules.beforeSwap(_context(key, true, false));
        vm.prank(address(root));
        vm.expectRevert(IHookrRulesState.GuardLiquidity.selector);
        rules.beforeAddLiquidity(id, address(0xBEEF));

        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(trader);
        router.swap{value: 1e15}(_swap(key, true, true, 1e15), address(0), new uint256[](0));
    }

    function _tryBuy(PoolKey memory key, uint128 amount) internal returns (bool ok) {
        vm.prank(trader);
        (ok,) = address(router).call{value: amount}(
            abi.encodeCall(HookrRouter.swap, (_swap(key, true, true, amount), address(0), new uint256[](0)))
        );
    }

    /// @dev At every point of the decay a parent block admits exactly cap * start / tax of net buys: the exact limit
    ///      passes and one more buy is refused. A flat pool keeps the fixed cap.
    function testCapScalesWithTheDecayedTax() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint128 cap = 1e16;
        PoolKey memory key = _launchSnipe(START, FLOOR, DECAY, cap, 60);
        PoolKey memory flat = _launchSnipe(START, 0, 0, cap, 120);
        uint256[7] memory times = [uint256(0), 1, 30, 60, 119, 120, 3600];
        for (uint256 i; i < times.length; ++i) {
            _warpTo(t0, times[i]);
            vm.roll(vm.getBlockNumber() + 1);
            uint128 limit = uint128(uint256(cap) * START / _curve(START, FLOOR, DECAY, times[i]));
            assertTrue(_tryBuy(key, limit), "the scaled limit");
            assertFalse(_tryBuy(key, 1e9), "one more buy in the same parent block");
            assertTrue(_tryBuy(flat, cap), "flat cap");
            assertFalse(_tryBuy(flat, 1e9), "flat cap is fixed");
        }
        assertEq(uint256(cap) * START / FLOOR, 5e17, "at the floor the cap is start / floor times maxBuyQuoteAmount");
    }

    /// @dev For any decaying config and second, a parent block admits exactly cap * start / tax of buys, or any amount
    ///      once the tax is zero.
    function testFuzzCapIsMaxBuyTimesStartOverTax(uint24 start, uint24 floor, uint16 decay, uint16 elapsed, uint64 cap)
        public
    {
        start = uint24(bound(start, 1, 500_000));
        floor = uint24(bound(floor, 0, start - 1));
        decay = uint16(bound(decay, 1, 3600));
        uint256 age = bound(elapsed, 0, 2 * uint256(decay));
        cap = uint64(bound(cap, 1e12, 1e18));
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey memory key = _launchSnipe(start, floor, decay, cap, 60);
        _warpTo(t0, age);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 rate = _curve(start, floor, decay, age);
        if (rate == 0) {
            assertTrue(_tryBuy(key, 1e21), "no cap at a zero tax");
            assertTrue(_tryBuy(key, 1e21), "still no cap");
            return;
        }
        uint256 limit = uint256(cap) * start / rate;
        vm.assume(limit <= 1e21);
        assertTrue(_tryBuy(key, uint128(limit)), "the exact limit");
        assertFalse(_tryBuy(key, 1e9), "one more buy");
    }

    /// @dev With a zero floor the cap lifts once the tax reaches zero; exact-output buys and outside liquidity stay
    ///      refused until guardEndBlock.
    function testZeroFloorLiftsTheCapWithTheTax() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint128 cap = 1e16;
        PoolKey memory key = _launchSnipe(START, 0, DECAY, cap, 60);
        _warpTo(t0, DECAY - 1);
        assertFalse(_tryBuy(key, 1e20), "capped while any tax is left");
        _warpTo(t0, DECAY);
        _assertSnipe(_buyQuote(key), 0, "no tax");
        assertTrue(_tryBuy(key, 1e20), "no cap");
        assertTrue(_tryBuy(key, 1e20), "still no cap");
        vm.prank(address(root));
        vm.expectRevert(IHookrRulesState.GuardExactOutput.selector);
        rules.beforeSwap(_context(key, true, false));
        vm.prank(address(root));
        vm.expectRevert(IHookrRulesState.GuardLiquidity.selector);
        rules.beforeAddLiquidity(key.toId(), address(0xBEEF));
    }

    /// @dev The launch of `m` reverts with the Rules' InvalidConfig from bind, carried in ModuleCallReverted.
    function _expectBindRefused(IHookrLauncher.Member memory m) internal {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector,
                address(rules),
                IHookrRules.bind.selector,
                abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector)
            )
        );
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    function testConfigBounds() public {
        // Floor above the start.
        _expectBindRefused(_snipeMember(START, START + 1, DECAY, 0, 60));
        // Duration above the cap.
        _expectBindRefused(_snipeMember(START, FLOOR, 3601, 0, 60));
        // A floor without a decay.
        _expectBindRefused(_snipeMember(START, FLOOR, 0, 0, 60));
        // A decay without a guard.
        IHookrLauncher.Member memory m = _snipeMember(0, 0, DECAY, 0, 60);
        m.rules.guardEndBlock = 0;
        _expectBindRefused(m);
        // Start + base above the 600,000 ceiling, decaying or not.
        _expectBindRefused(_snipeMember(597_001, FLOOR, DECAY, 0, 60));

        // A floor equal to the start, with a decay.
        _expectBindRefused(_snipeMember(START, START, DECAY, 0, 60));

        // The edges bind.
        _launchSnipe(START, START - 1, DECAY, 0, 60);
        _launchSnipe(START, FLOOR, 3600, 0, 120);
        _launchSnipe(597_000, 0, 1, 0, 200);
        _launchSnipe(START, 0, 0, 0, 240);
        HookrTypes.RulesConfig memory stored = rules.config(_launchSnipe(START, FLOOR, DECAY, 0, 300).toId());
        assertEq(stored.snipeTaxPips, START);
        assertEq(stored.snipeFloorPips, FLOOR);
        assertEq(stored.snipeDecaySeconds, DECAY);
    }
}
