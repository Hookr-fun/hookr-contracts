// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console} from "forge-std/console.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {Actor} from "./mocks/Actors.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {KothWashFixture} from "./utils/KothWashFixture.sol";

/// @notice One transaction: an authenticated buy on the King of the Pool pool, then a sale of everything it bought
///         on another venue of the same pair (here the hookless reference pool).
contract CrossVenueWasher {
    uint160 internal constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;

    function run(Actor a, IHookrRouter.Swap memory buy, uint256 value, PoolKey memory exitVenue)
        external
        returns (uint256 spent, uint256 got)
    {
        (spent, got) = a.routerSwap(buy, value);
        // Subject is currency1 (the quote is native ETH, currency0): selling it is oneForZero.
        a.directSwap(exitVenue, false, -int256(got), MAX_PRICE - 1);
    }
}

/// @notice One transaction carrying two unrelated parties' router swaps, as a batching relayer or a bundled
///         ERC-4337 transaction would: `buyer` buys, then `seller` sells.
contract SameTxBundler {
    function run(Actor buyer, IHookrRouter.Swap memory buy, uint256 value, Actor seller, IHookrRouter.Swap memory sell)
        external
    {
        buyer.routerSwap(buy, value);
        seller.routerSwap(sell, 0);
    }
}

/// @notice The King of the Pool creator wash (review finding M-1, fixed: a prize ceiling above half the protocol's
///         share of the pool's LP Rewards and Auto Burn cannot bind, so every prize is at most half the protocol fee
///         its own winning buy paid) and a crown voided by another party's sell (L-2, pinned as the current
///         behaviour; a later fix must flip the assertion it targets).
contract KothCreatorWashTest is KothWashFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// REVIEW M-1, the mechanism (kept). The same-transaction voiding rule only watches sells on the King of the
    /// Pool pool itself, so an atomic round trip that exits on another venue of the pair keeps the crown and holds no
    /// inventory at the end of the transaction. What changed is its price: the round trip costs more than the prize
    /// the crown can earn.
    function test_crossVenueAtomicExitKeepsCrown_butCostsMoreThanThePrize() public {
        _buy(key, ETH, minnow, 5e21);
        uint256 snap = vm.snapshotState();

        // Same-pool atomic round trip (PoC 1's shape): voided.
        Actor a = _newActor(key);
        uint256 before = address(a).balance;
        a.routerRoundTrip(
            _swapParams(key, ETH, true, true, 2e23, address(a)), 2e23, _swapParams(key, ETH, false, true, 1, address(a))
        );
        uint256 samePoolCost = before - address(a).balance - rules.claimable(ETH, address(a));
        (, address leader,,) = _hill(key);
        assertEq(leader, minnow, "same-pool exit voids the crown");

        // Cross-venue atomic round trip from the same state: the crown is kept.
        vm.revertToState(snap);
        Actor b = _newActor(key);
        CrossVenueWasher w = new CrossVenueWasher();
        uint256 subjectBefore = subject.balanceOf(address(b));
        before = address(b).balance;
        w.run(b, _swapParams(key, ETH, true, true, 2e23, address(b)), 2e23, ref);
        assertEq(subject.balanceOf(address(b)), subjectBefore, "no inventory held after the transaction");
        uint256 crossVenueCost = before - address(b).balance - rules.claimable(ETH, address(b));
        uint128 amount;
        (, leader, amount,) = _hill(key);
        console.log("same-pool atomic round trip, net cost (wei)  ", samePoolCost);
        console.log("cross-venue atomic round trip, net cost (wei)", crossVenueCost);
        console.log("prize cap earned by the 2e23 crown (wei)     ", uint256(amount) / 100);
        assertEq(leader, address(b), "cross-venue exit keeps the crown");
        assertEq(amount, 2e23);
        assertGt(crossVenueCost, uint256(amount) / 100, "the wash costs more than the prize");
    }

    /// Cost by size, two-transaction same-pool wash and one-transaction cross-venue wash: both keep the crown, and
    /// both cost a washer that owns no liquidity more than the prize ceiling at every size.
    function test_costBySize() public {
        uint256[3] memory sizes = [uint256(2e20), 2e21, 2e22];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 x = sizes[i];
            Actor a = _newActor(key);
            uint256 before = address(a).balance;
            (, uint256 got) = a.routerSwap(_swapParams(key, ETH, true, true, x, address(a)), x);
            a.routerSwap(_swapParams(key, ETH, false, true, got, address(a)), 0);
            uint256 twoTx = before - address(a).balance - rules.claimable(ETH, address(a));
            (, address l1,,) = _hill(key);
            vm.revertToState(snap);
            Actor b = _newActor(key);
            CrossVenueWasher w = new CrossVenueWasher();
            before = address(b).balance;
            w.run(b, _swapParams(key, ETH, true, true, x, address(b)), x, ref);
            uint256 oneTx = before - address(b).balance - rules.claimable(ETH, address(b));
            (, address l2,,) = _hill(key);
            vm.revertToState(snap);
            console.log("buy size (wei)", x);
            console.log("  two-tx same-pool net cost (bps of buy)", twoTx * 10_000 / x);
            console.log("  one-tx cross-venue net cost (bps of buy)", oneTx * 10_000 / x);
            console.log("  prize cap (bps of buy)", uint256(100));
            assertEq(l1, address(a));
            assertEq(l2, address(b));
            assertGt(twoTx, x / 100, "the two-transaction wash costs more than the prize");
            assertGt(oneTx, x / 100, "the cross-venue wash costs more than the prize");
        }
    }

    /// An attacker that already holds standing liquidity (added in an earlier transaction) gets the pool's LP fees
    /// back pro rata. With 2/3 of in-range liquidity the one-transaction cross-venue wash still costs more than the
    /// prize the crown earns: the protocol's 1% of the buy never comes back. Fees only; the position's principal is
    /// not re-marked (see the creator test below for full accounting).
    function test_lpOwnerCrossVenueWashCostsMoreThanThePrize() public {
        uint256 x = 2e21;
        Actor b = _newActor(key);
        b.modify(key, -60_000, 60_000, 2e24); // the creator holds 1e24 over the same range: b owns 2/3
        _buy(key, ETH, minnow, 5e20); // an honest leader
        CrossVenueWasher w = new CrossVenueWasher();
        uint256 before = address(b).balance;
        uint256 subjectBefore = subject.balanceOf(address(b));
        w.run(b, _swapParams(key, ETH, true, true, x, address(b)), x, ref);
        (, address leader, uint128 amount,) = _hill(key);
        assertEq(leader, address(b), "the LP-owner washer holds the crown");
        b.modify(key, -60_000, 60_000, 0); // collect fees only
        int256 dEth = int256(address(b).balance) - int256(before) + int256(rules.claimable(ETH, address(b)));
        int256 dSub = int256(subject.balanceOf(address(b))) - int256(subjectBefore);
        int256 net = dEth + dSub; // subject valued at the opening price of 1 (both venues opened at 1:1)
        console.log("LP-owner (2/3) cross-venue wash: net cost bps of buy", uint256(-net) * 10_000 / x);
        console.log("prize cap bps of buy", uint256(amount) * 50 / x);
        assertGt(-net, int256(uint256(amount) / 100), "net cost above the prize the crown earns");
    }

    /// REVIEW M-1, the default case, FIXED (regression). A new pool's creator holds all of its in-range liquidity
    /// through the launch position. With a pot already carried, an honest leader, and the other venue at the pool's
    /// price (so no gap is left for anyone to arbitrage), the creator runs the cross-venue wash from a contract it
    /// controls, collects the prize at rollover, takes the pool's recapture accrual through the launcher and
    /// withdraws, and is compared with rolling, taking the accrual and withdrawing from the same starting state.
    /// Before the fix the prize ceiling was the base LP fee, which the creator's own position returns, and the
    /// creator ended ahead (+2.46, +16.5 and +3.2 ETH on 2e20, 2e21 and 1e22 in the lab). Now the ceiling is half the
    /// protocol's share of LP Rewards and Auto Burn, which the winning buy pays and never gets back, and the creator
    /// ends behind at every size, marked at the price before the wash and at either venue's close.
    function test_creatorWashNowEndsBehindAtEverySizeAndMark() public {
        _fillPotWithUnauthenticatedTraffic(14);
        _buy(key, ETH, minnow, 1e20); // an honest leader for the epoch
        _alignReference();
        uint256[3] memory sizes = [uint256(2e20), 2e21, 1e22];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            (uint256 claims, int256 atMarket, int256 atKoth, int256 atRef, int256 atOne) = _creatorWash(sizes[i]);
            vm.revertToState(snap);
            console.log("creator wash: buy (wei)              ", sizes[i]);
            console.log("  washer claims: prize + trader leg  ", claims);
            console.log("  net vs plain withdrawal, at the pre-wash price");
            console.logInt(atMarket);
            console.log("  net, at the KOTH close");
            console.logInt(atKoth);
            console.log("  net, at the ref close");
            console.logInt(atRef);
            console.log("  net, at the opening price 1 (stale: the pool has moved)");
            console.logInt(atOne);
            assertGe(claims, sizes[i] * 50 / 10_000, "the capped prize was paid");
            assertLt(atMarket, 0, "behind at the market price before the wash");
            assertLt(atKoth, 0, "behind at the KOTH close");
            assertLt(atRef, 0, "behind at the reference close");
        }
    }

    /// REVIEW M-1: the ceiling the lab allowed (1% of the winning buy on a pool whose rules take nothing for the
    /// protocol on a buy) no longer binds: the Rules refuse the 50 bps prize against a bound of zero.
    function test_theLabsPrizeCeilingNoLongerBinds() public {
        HookrTypes.RulesConfig memory r = _laneRules(true);
        r.lpBps = 0;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(ETH, r, _kothRc());
        HookrToken s = _newSubject();
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector,
                address(rules),
                IHookrRules.bind.selector,
                abi.encodeWithSelector(IHookrRecaptureEvents.PrizeAboveBound.selector, 50, 0)
            )
        );
        vm.prank(creator);
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    /// @dev Moves the hookless reference venue to the King of the Pool pool's price, so no gap is left.
    function _alignReference() internal {
        (uint160 k,,,) = manager.getSlot0(key.toId());
        (uint160 r,,,) = manager.getSlot0(ref.toId());
        if (r != k) mover.directSwap(ref, r > k, -int256(1e26), k);
        (r,,,) = manager.getSlot0(ref.toId());
        assertEq(r, k, "the venues agree");
    }

    /// @dev From the current state: path A washes `x`, rolls, claims and withdraws; path B rolls, claims the accrual
    ///      and withdraws. Returns the washer's claims (the prize plus any trader leg) and path A minus path B in ETH
    ///      with the subject difference marked at the KOTH price before the wash, at the KOTH pool's closing price, at
    ///      the reference venue's closing price and at the opening 1. Leaves the chain in path B's state.
    function _creatorWash(uint256 x)
        internal
        returns (uint256 prize, int256 atMarket, int256 atKoth, int256 atRef, int256 atOne)
    {
        (uint64 start,,, uint128 potBefore) = _hill(key);
        uint128 liquidity = launcher.position(family, 0).liquidity;
        assertGe(potBefore, x / 100, "the carried pot covers the capped prize");
        (uint160 sqrtMarket,,,) = manager.getSlot0(key.toId());
        uint256 snap = vm.snapshotState();

        // Path A: wash, roll, claim, withdraw.
        Actor b = _newActor(key);
        CrossVenueWasher w = new CrossVenueWasher();
        uint256 bEth = address(b).balance;
        uint256 bSub = subject.balanceOf(address(b));
        w.run(b, _swapParams(key, ETH, true, true, x, address(b)), x, ref);
        (, address leader,,) = _hill(key);
        assertEq(leader, address(b), "the creator's washer leads");
        vm.warp(uint256(start) + PERIOD);
        _recap().settleEpoch(key.toId());
        prize = rules.claimable(ETH, address(b));
        int256 pathEth = int256(address(b).balance) - int256(bEth) + int256(prize) + int256(_claimAccrual());
        (uint256 aEth, uint256 aSub) = _withdrawAll(liquidity);
        pathEth += int256(aEth);
        int256 pathSub = int256(subject.balanceOf(address(b))) - int256(bSub) + int256(aSub);
        (uint160 sqrtKoth,,,) = manager.getSlot0(key.toId());
        (uint160 sqrtRef,,,) = manager.getSlot0(ref.toId());

        // Path B: from the same state, roll the epoch and withdraw without washing.
        vm.revertToState(snap);
        vm.warp(uint256(start) + PERIOD);
        _recap().settleEpoch(key.toId());
        pathEth -= int256(_claimAccrual());
        (uint256 cEth, uint256 cSub) = _withdrawAll(liquidity);
        int256 dEth = pathEth - int256(cEth);
        int256 dSub = pathSub - int256(cSub);
        atMarket = dEth + _markEth(dSub, sqrtMarket);
        atKoth = dEth + _markEth(dSub, sqrtKoth);
        atRef = dEth + _markEth(dSub, sqrtRef);
        atOne = dEth + dSub;
    }

    /// @dev The family owner moves the pool's recapture accrual into its Rules claim; returns the amount.
    function _claimAccrual() internal returns (uint256) {
        if (_accrued(key) == 0) return 0;
        vm.prank(creator);
        return launcher.claimRecapture(family, 0, creator);
    }

    /// @dev The family owner withdraws the whole position; returns (ETH, subject). ETH is currency0.
    function _withdrawAll(uint128 liquidity) internal returns (uint256 eth, uint256 sub) {
        vm.prank(creator);
        (eth, sub) = launcher.withdraw(family, 0, liquidity, 0, 0, creator, vm.getBlockTimestamp());
    }

    /// @dev Values a signed subject amount in ETH at a pool price (subject is currency1, ETH currency0).
    function _markEth(int256 amount, uint160 sqrtPriceX96) internal pure returns (int256) {
        uint256 m = amount < 0 ? uint256(-amount) : uint256(amount);
        uint256 v = FullMath.mulDiv(FullMath.mulDiv(m, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
        return amount < 0 ? -int256(v) : int256(v);
    }

    /// REVIEW L-2. The voiding rule does not compare the seller with the leader: any sell on the pool later in the
    /// same transaction voids a crown taken in it. A relayer or bundle that carries an honest buy and someone else's
    /// sell voids the honest buyer. Control: the same two swaps in separate transactions keep the honest crown.
    /// Deliberate: a seller-equals-leader rule would let a washer buy from one address and sell from another in one
    /// transaction.
    function test_anotherPartysSellInTheSameTxVoidsAnHonestCrown() public {
        _buy(key, ETH, minnow, 5e20);
        Actor honest = _newActor(key);
        Actor other = _newActor(key);
        IHookrRouter.Swap memory buy = _swapParams(key, ETH, true, true, 2e21, address(honest));
        IHookrRouter.Swap memory sell = _swapParams(key, ETH, false, true, 1e20, address(other));
        uint256 snap = vm.snapshotState();

        honest.routerSwap(buy, 2e21);
        other.routerSwap(sell, 0);
        (, address leader,,) = _hill(key);
        assertEq(leader, address(honest), "separate transactions: the honest buyer leads");

        vm.revertToState(snap);
        SameTxBundler bundler = new SameTxBundler();
        bundler.run(honest, buy, 2e21, other, sell);
        uint128 amount;
        (, leader, amount,) = _hill(key);
        assertEq(leader, minnow, "one transaction: an unrelated sell voided the honest crown");
        assertEq(amount, 5e20);
    }
}
