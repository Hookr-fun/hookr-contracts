// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice VALUE-LOSS / ACCOUNTING audit harness. Uses a locally deployed real v4 PoolManager so
///         the graduation path (settle / modifyLiquidity) is exercised for real, not stubbed.
contract AuditVL is Test {
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 3));

    IPoolManager constant pm = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    HookrLaunchpad pad;
    HookrHook hook;

    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCAB01);

    function setUp() public {
        vm.createSelectFork("robinhood");
        pad = new HookrLaunchpad(pm);
        bytes memory creation = abi.encodePacked(type(HookrHook).creationCode, abi.encode(address(pm), address(pad)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(IPoolManager(address(pm)), address(pad));
        require(address(hook) == predicted, "mine");
        pad.setHook(hook);

        vm.deal(creator, 100_000 ether);
        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
        vm.deal(carol, 100_000 ether);
    }

    function _args(uint96 target) internal pure returns (HookrLaunchpad.LaunchArgs memory a) {
        a.name = "Audit";
        a.symbol = "AUD";
        a.tagline = "";
        a.logoURI = "";
        a.targetRaiseWei = target;
        a.blueprintId = 0;
        a.custom = HookrLaunchpad.HookParams({
            guardBlocks: 0,
            maxBuyBps: 0,
            snipeTaxPips: 0,
            baseFeePips: 3000,
            maxFeePips: 3000,
            surgeSens: 0,
            burnBps: 0,
            burnTriggerWei: 0,
            lpBps: 0,
            potBps: 0,
            potOdds: 0,
            potMinBuyWei: 0
        });
    }

    function _launch(uint96 target) internal returns (address token) {
        uint256 f = pad.creationFeeWei();
        vm.prank(creator);
        token = pad.launch{value: f}(_args(target));
    }

    /// @dev every wei the pad holds must be attributable
    function _assertSolvent(address token, string memory ctx) internal view {
        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        uint256 accounted = uint256(l.reserveWei) + pad.protocolFeesWei() + pad.creatorFeesWei(token);
        assertGe(address(pad).balance, accounted, ctx);
    }

    // ------------------------------------------------------------------ 1. graduation sweep

    function _gradAt(uint96 target) internal returns (address token) {
        token = _launch(target);
        // buy out with generous headroom; refunds handle the excess
        uint256 send = uint256(target) * 3 + 1 ether;
        vm.deal(alice, send + 1 ether);
        vm.prank(alice);
        pad.buy{value: send}(token, 0);
        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        assertTrue(l.graduated, "must graduate");
        assertEq(l.reserveWei, 0);
        assertEq(HookrToken(token).balanceOf(address(pad)), 0, "no stranded tokens");
    }

    function test_graduation_accounting_sweep() public {
        uint96[8] memory targets = [
            uint96(0.0001 ether),
            uint96(0.001 ether),
            uint96(0.01 ether),
            uint96(0.1 ether),
            uint96(1 ether),
            uint96(10 ether),
            uint96(100 ether),
            uint96(1000 ether)
        ];
        for (uint256 i = 0; i < targets.length; i++) {
            uint256 snap = vm.snapshotState();
            address token = _gradAt(targets[i]);
            uint256 accounted = pad.protocolFeesWei() + pad.creatorFeesWei(token);
            console2.log("target", targets[i]);
            console2.log("  balance ", address(pad).balance);
            console2.log("  accounted", accounted);
            assertGe(address(pad).balance, accounted, "INSOLVENT after graduation");
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------ 2. reserve solvency fuzz

    function testFuzz_reserveNeverUnderwater(uint96 target, uint96 a, uint96 b, uint96 c, uint16 sellPctA) public {
        target = uint96(bound(target, 0.0001 ether, 1000 ether));
        address token = _launch(target);

        a = uint96(bound(a, 1, uint256(target) / 2));
        b = uint96(bound(b, 1, uint256(target) / 2));
        c = uint96(bound(c, 1, uint256(target) / 2));
        sellPctA = uint16(bound(sellPctA, 1, 10_000));

        _tryBuy(alice, token, a);
        _tryBuy(bob, token, b);
        _assertSolvent(token, "after buys");

        uint256 balA = HookrToken(token).balanceOf(alice);
        if (balA > 0) {
            uint256 amt = (balA * sellPctA) / 10_000;
            if (amt > 0) _trySell(alice, token, amt);
        }
        _assertSolvent(token, "after sell");

        _tryBuy(carol, token, c);
        _assertSolvent(token, "after 3rd buy");

        // full unwind: everyone dumps everything
        _dump(alice, token);
        _dump(bob, token);
        _dump(carol, token);

        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        if (!l.graduated) {
            uint256 accounted = uint256(l.reserveWei) + pad.protocolFeesWei() + pad.creatorFeesWei(token);
            assertEq(address(pad).balance, accounted, "wei unaccounted after unwind");
            // reserve must still cover the sell-back value of every outstanding token
            if (l.soldTokens > 0) {
                assertGe(uint256(l.reserveWei), pad.quoteSell(token, l.soldTokens), "reserve underwater");
            }
        }
    }

    function _tryBuy(address who, address token, uint256 v) internal {
        if (pad.getLaunch(token).graduated) return;
        (uint256 out,) = pad.quoteBuy(token, v);
        if (out == 0) return;
        vm.prank(who);
        pad.buy{value: v}(token, 0);
    }

    function _trySell(address who, address token, uint256 amt) internal {
        if (pad.getLaunch(token).graduated) return;
        if (pad.quoteSell(token, amt) == 0) return;
        vm.startPrank(who);
        HookrToken(token).approve(address(pad), amt);
        pad.sell(token, amt, 0);
        vm.stopPrank();
    }

    function _dump(address who, address token) internal {
        uint256 bal = HookrToken(token).balanceOf(who);
        if (bal > 0) _trySell(who, token, bal);
    }

    // ------------------------------------------------------------------ 3. no free money

    /// @dev A buy immediately followed by a full sell must never return more ETH than was paid.
    function testFuzz_roundTripNeverProfitable(uint96 target, uint96 v) public {
        target = uint96(bound(target, 0.0001 ether, 1000 ether));
        v = uint96(bound(v, 1, uint256(target) * 2));
        address token = _launch(target);

        uint256 before = alice.balance;
        (uint256 quoted,) = pad.quoteBuy(token, v);
        if (quoted == 0) return;
        vm.prank(alice);
        pad.buy{value: v}(token, 0);
        if (pad.getLaunch(token).graduated) return;
        _dump(alice, token);
        assertLe(alice.balance, before, "round trip printed ETH");
    }

    /// @dev Splitting a buy into many small buys must not be cheaper than one big buy
    ///      (i.e. per-chunk ceil rounding must never favour the buyer).
    function test_manySmallBuys_notCheaperThanOneBig() public {
        uint96 target = 1 ether;
        address t1 = _launch(target);
        vm.prank(alice);
        pad.buy{value: 0.1 ether}(t1, 0);
        uint256 oneShot = HookrToken(t1).balanceOf(alice);

        address t2 = _launch(target);
        for (uint256 i = 0; i < 100; i++) {
            vm.prank(bob);
            pad.buy{value: 0.001 ether}(t2, 0);
        }
        uint256 split = HookrToken(t2).balanceOf(bob);
        assertLe(split, oneShot, "splitting buys gained tokens");
    }

    // ------------------------------------------------------------------ 4. dust / stuck curve

    /// @dev Can the curve reach a state where the last chunk is unbuyable (never graduates)?
    function test_lastChunkAlwaysBuyable() public {
        uint96 target = 0.0001 ether; // smallest curve = worst rounding
        address token = _launch(target);
        // buy 99.99% of the curve in one go, leaving a sliver
        vm.prank(alice);
        pad.buy{value: uint256(target) * 99 / 100}(token, 0);
        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        assertFalse(l.graduated);
        uint256 left = pad.CURVE_SUPPLY() - l.soldTokens;
        assertGt(left, 0);
        // now push it over with 1 wei increments until it graduates or we give up
        for (uint256 i = 0; i < 200 && !pad.getLaunch(token).graduated; i++) {
            vm.prank(bob);
            pad.buy{value: 1e10}(token, 0);
        }
        assertTrue(pad.getLaunch(token).graduated, "curve stuck: cannot graduate");
    }

    // ------------------------------------------------------------------ 5. reentrancy probe

    function test_refundReentrancyBlocked() public {
        uint96 target = 0.01 ether;
        address token = _launch(target);
        Reenter r = new Reenter(pad, token);
        vm.deal(address(r), 10 ether);
        // buy with a big overpay so a refund fires back into the attacker
        vm.expectRevert();
        r.attack(1 ether);
    }
}

contract Reenter {
    HookrLaunchpad pad;
    address token;
    bool armed;

    constructor(HookrLaunchpad p, address t) {
        pad = p;
        token = t;
    }

    function attack(uint256 v) external {
        armed = true;
        pad.buy{value: v}(token, 0);
    }

    receive() external payable {
        if (armed) {
            armed = false;
            pad.buy{value: 1 wei}(token, 0);
        }
    }
}
