// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";

/// @notice RR-A1: the protocol's share of an LP Rewards or Auto Burn slice is taken in pips of the gross buyer spend,
///         rounded up, so a slice of 1 to 4 bps pays it; the burn left after it is whole bps, rounded down. The buyer
///         is never charged more than lpBps + burnBps.
contract ProtocolSharePipsTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    Currency internal constant NATIVE = Currency.wrap(address(0));
    address internal constant DEAD = address(0xdead);

    function _minProtocolShareBps() internal pure override returns (uint16) {
        return 2_000;
    }

    function setUp() public {
        _setUpPeriphery();
        vm.deal(trader, 1_000 ether);
    }

    function _launchWith(uint16 lpBps, uint16 burnBps, uint16 share, bytes32 salt)
        internal
        returns (PoolKey memory key, HookrToken s)
    {
        s = new HookrToken{salt: salt}("S", "S", 1e30, address(this));
        s.approve(address(launcher), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(NATIVE);
        members[0].rules.lpBps = lpBps;
        members[0].rules.burnBps = burnBps;
        members[0].rules.protocolShareBps = share;
        members[0].rules.royaltyBps = 0;
        members[0].rules.royaltyTo = address(0);
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function _buy(PoolKey memory key, uint128 amount) internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        IHookrRouter.Swap memory p = _swap(key, true, true, amount);
        vm.prank(trader);
        router.swap{value: amount}(p, address(0), new uint256[](0));
    }

    /// lpBps 4 at a 2,000 share pays the protocol 80 pips of a 10 ETH buy, 8e14 (at HEAD, 4 x 2,000 / 10,000 rounded
    /// down to 0 bps, nothing).
    function test_pips_lpBpsFourAtTwentyPercent_paysEightyPips() public {
        (PoolKey memory key,) = _launchWith(4, 0, 2_000, "lp4");
        uint256 before = rules.claimable(NATIVE, protocol);
        _buy(key, 10 ether);
        assertEq(rules.claimable(NATIVE, protocol) - before, 8e14, "80 pips of the spend");
    }

    /// burnBps 4 at a 2,000 share pays the protocol 80 pips and burns 3 whole bps of the subject out.
    function test_pips_burnBpsFourAtTwentyPercent_paysEightyPipsAndBurnsThreeBps() public {
        (PoolKey memory key, HookrToken s) = _launchWith(0, 4, 2_000, "burn4");
        uint256 before = rules.claimable(NATIVE, protocol);
        uint256 deadBefore = s.balanceOf(DEAD);
        uint256 traderBefore = s.balanceOf(trader);
        _buy(key, 10 ether);
        assertEq(rules.claimable(NATIVE, protocol) - before, 8e14, "80 pips of the spend");
        uint256 burned = s.balanceOf(DEAD) - deadBefore;
        uint256 received = s.balanceOf(trader) - traderBefore;
        assertEq(burned, (received + burned) * 3 / 10_000, "3 whole bps of the subject out");
    }

    /// Terms whose share divides them pay what they paid: 5/5 at 2,000, 1 bps of each slice, 2e15.
    function test_pips_dividingTermsUnchanged() public {
        (PoolKey memory key,) = _launchWith(5, 5, 2_000, "lp5burn5");
        uint256 before = rules.claimable(NATIVE, protocol);
        _buy(key, 10 ether);
        assertEq(rules.claimable(NATIVE, protocol) - before, 2e15, "1 bps of each slice");
    }

    /// The revenue-router proof of concept, flipped: lpBps 4 at the share floor, ten buys of 10 ETH, pays the protocol
    /// 8e15 where it paid nothing.
    function test_pips_revenueRouterSmallSliceNowPays() public {
        (PoolKey memory key,) = _launchWith(4, 0, 2_000, "rr");
        uint256 before = rules.claimable(NATIVE, protocol);
        for (uint256 i; i < 10; ++i) {
            _buy(key, 10 ether);
        }
        assertEq(rules.claimable(NATIVE, protocol) - before, 8e15, "80 pips of every buy");
    }

    /// For any share in [2,000, 5,000] and slices in [0, 1,000] the Rules quote the protocol ceil(bps x share / 100)
    /// pips of each slice, burn what is left in whole bps, and charge the buyer at most lpBps + burnBps.
    function testFuzz_pips_protocolShareRoundsUpAndTheBuyerPaysAtMostTheTerms(uint16 share, uint16 lp, uint16 burn)
        public
    {
        share = uint16(bound(share, 2_000, 5_000));
        lp = uint16(bound(lp, 0, 1_000));
        burn = uint16(bound(burn, 0, 1_000 - lp));
        (PoolKey memory key, HookrToken s) = _launchWith(lp, burn, share, keccak256(abi.encode(share, lp, burn)));
        HookrTypes.FeeQuote memory q = _quoteBuy(key, s);
        uint256 lpSlice = (uint256(lp) * share + 99) / 100;
        uint256 burnSlice = (uint256(burn) * share + 99) / 100;
        assertEq(q.quoteTakePips, lpSlice + burnSlice, "the protocol's pips, rounded up");
        assertGe(uint256(q.quoteTakePips) * 10_000, (uint256(lp) + burn) * share * 100, "never under its share");
        assertEq(q.subjectBurnBps, (uint256(burn) * 100 - burnSlice) / 100, "the burn left, in whole bps");
        assertLe(
            uint256(q.lpFeeSurchargePips) + q.quoteTakePips + uint256(q.subjectBurnBps) * 100,
            (uint256(lp) + burn) * 100,
            "the buyer pays at most the terms"
        );
    }

    /// @dev The Rules' quote of a 1e18 exact-input buy of `s` on `key`, asked as the root.
    function _quoteBuy(PoolKey memory key, HookrToken s) internal returns (HookrTypes.FeeQuote memory q) {
        HookrTypes.SwapContext memory x = HookrTypes.SwapContext({
            id: key.toId(),
            sender: trader,
            payer: trader,
            beneficiary: trader,
            subject: Currency.wrap(address(s)),
            quote: NATIVE,
            authenticated: false,
            isBuy: true,
            exactInput: true,
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: MIN_PRICE,
            baseLpFeePips: 3000
        });
        // The Rules answer their quote to the root alone.
        vm.prank(address(root));
        q = rules.simulationQuote(x);
    }
}
