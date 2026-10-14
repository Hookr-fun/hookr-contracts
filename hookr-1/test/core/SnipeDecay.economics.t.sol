// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";

/// @notice Sniper economics of the decaying Anti-Snipe tax on a launch-shaped pool: a new 1e9 token, all of it
///         single-sided above a 3 ETH virtual quote reserve, native ETH quote, 1% base LP fee, 25% protocol share,
///         a 100 parent-block guard. A sniper buys at `entry` seconds, organic buyers arrive after the guard, and the
///         sniper sells into them. Parent blocks advance one per 12 s, as the 4663 sequencer reports its parent.
///         The tax falls linearly, and the per-parent-block cap grows as it falls (maxBuyQuoteAmount * start / tax).
contract SnipeDecayEconomicsTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant BASE = 10_000;
    uint24 internal constant START = 500_000;
    uint24 internal constant FLOOR = 10_000;
    uint16 internal constant SHARE = 2500;
    uint256 internal constant GUARD = 100;
    uint256 internal constant SUPPLY = 1e27;
    int24 internal constant SPACING = 60;
    // ln(1e27 / 3e18) / ln(1.0001), rounded to the spacing: about 3 ETH of virtual quote at launch.
    int24 internal constant LAUNCH_TICK = 196_260;

    address internal sniper = address(0x5A1);
    address internal organic = address(0x0A1);
    address internal honest = address(0x0B1);

    uint256 internal t0;
    uint256 internal b0;
    uint256 internal salt;

    function setUp() public {
        _setUpPeriphery();
        vm.deal(sniper, 1e24);
        vm.deal(organic, 1e24);
        vm.deal(honest, 1e24);
    }

    function _launchPool(uint16 decay, uint128 cap) internal returns (PoolKey memory key, address subject) {
        IHookrLauncher.Member memory m = _member(Currency.wrap(address(0)));
        m.tickSpacing = SPACING;
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(LAUNCH_TICK);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(SPACING));
        m.sqrtPriceX96 = sqrtUpper;
        m.tickLower = TickMath.minUsableTick(SPACING);
        m.tickUpper = LAUNCH_TICK;
        m.liquidity = uint128(FullMath.mulDiv(SUPPLY * 99 / 100, 1 << 96, sqrtUpper - sqrtLower));
        m.amount0Max = 0;
        m.amount1Max = uint128(SUPPLY);
        m.config.baseLpFeePips = BASE;
        m.rules.maxFeePips = BASE;
        m.rules.burnBps = 0;
        m.rules.lpBps = 0;
        m.rules.royaltyBps = 0;
        m.rules.royaltyTo = address(0);
        m.rules.protocolShareBps = SHARE;
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + GUARD);
        m.rules.snipeTaxPips = START;
        m.rules.snipeFloorPips = decay == 0 ? 0 : FLOOR;
        m.rules.snipeDecaySeconds = decay;
        m.rules.maxBuyQuoteAmount = cap;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        t0 = vm.getBlockTimestamp();
        b0 = vm.getBlockNumber();
        bytes32 family;
        (family, subject) = launcher.launch(
            IHookrLauncher.Token(address(0), "Launch", "LNCH", SUPPLY, bytes32(++salt)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
        _family = family;
    }

    bytes32 internal _family;

    /// @dev Moves to `secs` after launch, advancing the parent block by one per 12 s.
    function _at(uint256 secs) internal {
        vm.warp(t0 + secs);
        vm.roll(b0 + secs / 12);
    }

    function _buy(address who, PoolKey memory key, uint256 amount) internal returns (uint256 out) {
        IHookrRouter.Swap memory p = _swap(key, true, true, uint128(amount));
        p.recipient = who;
        vm.prank(who);
        (, out) = router.swap{value: amount}(p, address(0), new uint256[](0));
    }

    function _trySell(address who, PoolKey memory key, address subject, uint256 amount) internal returns (uint256) {
        IHookrRouter.Swap memory p = _swap(key, false, true, uint128(amount));
        p.recipient = who;
        vm.startPrank(who);
        IERC20(subject).approve(address(router), amount);
        (, uint256 out) = router.swap(p, address(0), new uint256[](0));
        vm.stopPrank();
        return out;
    }

    /// @dev Sniper buys `spend` at `entry` s; after the guard organic buyers bring `demand`; the sniper sells all.
    function _roundTrip(uint16 decay, uint256 entry, uint256 spend, uint256 demand) internal returns (int256 pnl) {
        uint256 snap = vm.snapshotState();
        (PoolKey memory key, address subject) = _launchPool(decay, 1e18);
        _at(entry);
        uint256 got = _buy(sniper, key, spend);
        _at((GUARD + 1) * 12);
        _buy(organic, key, demand);
        uint256 back = _trySell(sniper, key, subject, got);
        pnl = int256(back) - int256(spend);
        vm.revertToState(snap);
    }

    function _pct(int256 pnl, uint256 spend) internal pure returns (int256) {
        return pnl * 10_000 / int256(spend);
    }

    /// @notice Table: sniper ROI (bps) by entry second, flat 50% vs 50% -> 1% over 120 s and over 300 s, for organic
    ///         demand of 0.68 / 1.26 / 2.22 ETH after the guard (about 1.5x / 2x / 3x the launch price).
    function testSniperRoiByEntrySecond() public {
        uint256[3] memory demand = [uint256(0.68 ether), 1.26 ether, 2.22 ether];
        uint256[8] memory entry = [uint256(0), 1, 5, 15, 30, 60, 120, 300];
        uint16[3] memory decays = [uint16(0), 120, 300];
        uint256 spend = 0.1 ether;
        for (uint256 d; d < decays.length; ++d) {
            for (uint256 j; j < demand.length; ++j) {
                string memory row = "";
                for (uint256 i; i < entry.length; ++i) {
                    int256 bps = _pct(_roundTrip(decays[d], entry[i], spend, demand[j]), spend);
                    row = string.concat(row, " | ", vm.toString(bps));
                }
                console2.log(string.concat("decay ", vm.toString(decays[d]), " demand ", vm.toString(demand[j]), row));
            }
        }
        // Flat: a 0.1 ETH snipe loses at 1.5x demand whatever the entry second.
        assertLt(_roundTrip(0, 300, spend, 0.68 ether), 0, "flat 1.5x: loses");
        // Decaying 50% -> 1% over 120 s: the same trade at 120 s is profitable, and more so than at 0 s.
        assertGt(_roundTrip(120, 120, spend, 0.68 ether), 0, "decay 1.5x at 120 s: profits");
        assertLt(_roundTrip(120, 0, spend, 0.68 ether), 0, "decay 1.5x at 0 s: loses");
        // The linear decay still charges a quarter of the way in: waiting 30 s does not make the 1.5x trade pay.
        assertLt(_roundTrip(120, 30, spend, 0.68 ether), 0, "decay 1.5x at 30 s: loses");
        // Buying at the guard end pays no Snipe: the flat guard-end cliff, documented.
        uint256 snap = vm.snapshotState();
        (PoolKey memory key, address subject) = _launchPool(0, 1e18);
        _at(GUARD * 12);
        uint256 got = _buy(sniper, key, spend);
        _at((GUARD + 1) * 12);
        _buy(organic, key, 0.68 ether);
        int256 cliff = int256(_trySell(sniper, key, subject, got)) - int256(spend);
        vm.revertToState(snap);
        console2.log("flat, entry at guardEndBlock, 1.5x demand, ROI bps", _pct(cliff, spend));
        assertGt(cliff, 0, "guard-end cliff profits");
    }

    /// @dev Linear reference tax at `secs` after launch.
    function _rate(uint16 decay, uint256 secs) internal pure returns (uint256) {
        if (decay == 0) return START;
        if (secs >= decay) return FLOOR;
        return FLOOR + (uint256(START) - FLOOR) * (decay - secs) / decay;
    }

    /// @dev A bot fills the whole cap in each of the first `blocks` parent blocks; returns the protocol take per block.
    function _fillEveryBlock(uint16 decay, uint128 cap, uint256 blocks) internal returns (uint256[] memory takes) {
        uint256 snap = vm.snapshotState();
        (PoolKey memory key,) = _launchPool(decay, cap);
        takes = new uint256[](blocks);
        for (uint256 w; w < blocks; ++w) {
            _at(w * 12);
            uint256 before = rules.claimable(Currency.wrap(address(0)), protocol);
            _buy(sniper, key, uint256(cap) * START / _rate(decay, w * 12));
            takes[w] = rules.claimable(Currency.wrap(address(0)), protocol) - before;
        }
        vm.revertToState(snap);
    }

    /// @notice When the cap binds, every parent block that fills it pays the same Snipe as a flat pool's block, at
    ///         every point of the decay and after it: the cap grows as the tax falls, so the decay gives no discount on
    ///         capped flow. Fifteen parent blocks cover the 120 s decay and three floor blocks.
    function testFilledCapPaysTheFlatSnipeEveryParentBlock() public {
        uint128 cap = 0.01 ether;
        uint256[] memory flat = _fillEveryBlock(0, cap, 15);
        uint256[] memory decaying = _fillEveryBlock(120, cap, 15);
        for (uint256 w; w < 15; ++w) {
            assertApproxEqRel(decaying[w], flat[w], 0.0005e18, "same Snipe per filled parent block");
        }
        // 25% of 50% on 0.01 ETH.
        assertEq(flat[0], 0.00125 ether, "flat take per block");
    }

    /// @notice After the decay reaches its floor, a parent block is no longer a rationed sale that the first
    ///         transaction takes: after a first buyer spends the old per-block cap, an honest buy in the same parent
    ///         block still fills, in every floor block of the guard.
    function testFloorWindowsStayOpenAfterTheFirstBuyer() public {
        uint128 cap = 0.05 ether;
        (PoolKey memory key,) = _launchPool(120, cap);
        uint256 honestFails;
        for (uint256 w = 11; w < GUARD; ++w) {
            _at(w * 12);
            _buy(sniper, key, cap);
            IHookrRouter.Swap memory p = _swap(key, true, true, 0.01 ether);
            p.recipient = honest;
            vm.prank(honest);
            (bool ok,) = address(router).call{value: 0.01 ether}(
                abi.encodeCall(HookrRouter.swap, (p, address(0), new uint256[](0)))
            );
            if (!ok) ++honestFails;
        }
        console2.log("honest buys refused after the first buyer, floor blocks", honestFails, GUARD - 11);
        assertEq(honestFails, 0, "no honest buy is refused behind the first buyer");
    }

    /// @notice The whole curve lives in block.timestamp: a sequencer timestamp jump of snipeDecaySeconds collapses
    ///         even the longest (3,600 s) decay in one block; Arbitrum-style sequencers may run up to 1 h ahead.
    function testTimestampJumpCollapsesTheCurve() public {
        (PoolKey memory key,) = _launchPool(3600, 0);
        vm.warp(t0 + 3600);
        HookrTypes.SwapContext memory x;
        x.id = key.toId();
        x.sender = sniper;
        x.payer = sniper;
        x.beneficiary = sniper;
        x.subject = root.poolConfig(key.toId()).subject;
        x.quote = Currency.wrap(address(0));
        x.authenticated = true;
        x.isBuy = true;
        x.exactInput = true;
        x.zeroForOne = true;
        x.amountSpecified = -1e18;
        x.sqrtPriceLimitX96 = MIN_PRICE;
        x.baseLpFeePips = BASE;
        vm.prank(address(root));
        HookrTypes.FeeQuote memory q = rules.beforeSwap(x);
        assertEq(uint256(q.lpFeeSurchargePips) + q.quoteTakePips, FLOOR, "floor in the same parent block as launch");
        assertEq(vm.getBlockNumber(), b0, "no parent block passed");
    }

    /// @notice The family owner is the only LP during the guard, so it gets back the LP part of its own Snipe. A
    ///         launch-second self-buy costs it the protocol share of the tax, not the tax: flat or decaying alike.
    function testCreatorSelfBuyPaysOnlyTheProtocolShare() public {
        (PoolKey memory key,) = _launchPool(120, 0);
        uint256 spend = 0.25 ether;
        uint256 before = address(this).balance;
        IHookrRouter.Swap memory p = _swap(key, true, true, uint128(spend));
        p.recipient = address(this);
        router.swap{value: spend}(p, address(0), new uint256[](0));
        launcher.withdraw(_family, 0, 0, 0, 0, address(this), vm.getBlockTimestamp());
        uint256 netCost = before - address(this).balance;
        console2.log("creator gross spend", spend);
        console2.log("creator net ETH after collecting its LP fees", netCost);
        uint256 feesBack = spend - netCost;
        // The take (25% of 50%) leaves first; the LP fee (1% base + 37.5% Snipe LP part) is charged on the rest.
        uint256 take = spend * (uint256(START) * SHARE / 10_000) / 1_000_000;
        uint256 lpFee = (spend - take) * (BASE + uint256(START) * (10_000 - SHARE) / 10_000) / 1_000_000;
        console2.log("LP fees back to the creator (wei)", feesBack);
        console2.log("creator's cost of the launch-second tax (protocol take, wei)", take);
        console2.log("an outsider's cost of the same buy (take + LP fee, wei)", take + lpFee);
        assertApproxEqAbs(feesBack, lpFee, 1e9, "every LP fee of the self-buy returns to the creator");
    }

    /// @notice The same self-buy made as the launch's dev buy: it runs at the launch second and pays the full tax, and
    ///         again only the protocol share of it costs the creator; the LP part returns as fees and the net quote
    ///         sits in the creator's own locked position. A dev-buy member must carry a Snipe, and the protocol takes
    ///         its share of it at whatever share the member binds with.
    function testCreatorDevBuyPaysOnlyTheProtocolShare() public {
        uint256 spend = 0.05 ether;
        IHookrLauncher.Member memory m = _member(Currency.wrap(address(0)));
        m.tickSpacing = SPACING;
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(LAUNCH_TICK);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(SPACING));
        m.sqrtPriceX96 = sqrtUpper;
        m.tickLower = TickMath.minUsableTick(SPACING);
        m.tickUpper = LAUNCH_TICK;
        m.liquidity = uint128(FullMath.mulDiv(SUPPLY * 99 / 100, 1 << 96, sqrtUpper - sqrtLower));
        m.amount0Max = 0;
        m.amount1Max = uint128(SUPPLY);
        m.config.baseLpFeePips = BASE;
        m.rules.maxFeePips = BASE;
        m.rules.burnBps = 0;
        m.rules.lpBps = 0;
        m.rules.royaltyBps = 0;
        m.rules.royaltyTo = address(0);
        m.rules.protocolShareBps = SHARE;
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + GUARD);
        m.rules.snipeTaxPips = START;
        m.rules.snipeFloorPips = FLOOR;
        m.rules.snipeDecaySeconds = 120;
        m.rules.maxBuyQuoteAmount = uint128(spend);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        uint256 before = address(this).balance;
        (bytes32 family,, uint256 out) = launcher.launchWithBuy{value: spend}(
            IHookrLauncher.Token(address(0), "Launch", "LNCH", SUPPLY, bytes32(++salt)),
            address(root),
            members,
            new bytes[](1),
            IHookrLauncher.DevBuy(0, uint128(spend), 1, 0),
            vm.getBlockTimestamp()
        );
        launcher.withdraw(family, 0, 0, 0, 0, address(this), vm.getBlockTimestamp());
        uint256 netCost = before - address(this).balance;
        uint256 take = spend * (uint256(START) * SHARE / 10_000) / 1_000_000;
        uint256 lpFee = (spend - take) * (BASE + uint256(START) * (10_000 - SHARE) / 10_000) / 1_000_000;
        console2.log("dev buy gross spend", spend);
        console2.log("dev buy subject out", out);
        console2.log("creator net ETH after collecting its LP fees", netCost);
        assertEq(rules.claimable(Currency.wrap(address(0)), protocol), take, "the full launch tax's protocol share");
        assertApproxEqAbs(spend - netCost, lpFee, 1e9, "every LP fee of the dev buy returns to the creator");
        // The rest of the net cost is the quote paid into the creator's own position, which leaves with the
        // principal once principalLockedUntil passes; the tax itself costs only the protocol's take.
        console2.log("quote paid into the creator's own position (wei)", netCost - take);
        console2.log("the creator's cost of the launch-second tax (protocol take, wei)", take);
    }
}
