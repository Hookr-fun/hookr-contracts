// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {DevBuyFixture} from "./DevBuyFixture.sol";

/// @notice EC-01 and EC-02. A dev buy that left the dynamic fee reference at the launch price measured every later swap
///         from there: followers paid (sqrtLaunch / sqrtNow)^2 times the fee of the same buy on a pool launched at the
///         post-buy price, a multiple the creator set with the dev-buy member's share of supply, and it did not decay;
///         the creator's own exit back toward the launch price paid no dynamic fee and no protocol share. The dev buy
///         now leaves the state unstarted, so every later swap is charged as on a pool launched at the post-buy price.
///         Each case compares three pools: the dev pool, a control launched at the post-buy price with the same band and
///         liquidity, and a pool at the launch price whose first buy is an ordinary router buy of the same size.
contract LauncherDevBuyFollowerFeeTest is DevBuyFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Currency internal constant ETH = Currency.wrap(address(0));
    uint128 internal constant FOLLOW = 1e21;

    function setUp() public {
        _setUpPeriphery();
    }

    /// @dev DB-01's dynamic member: sensitivity 10, 5% ceiling, 20% protocol share, a 1-pip Snipe for one parent block
    ///      and no LP Rewards, burn or royalty.
    function _dynamic(IHookrLauncher.Member memory m) internal view returns (IHookrLauncher.Member memory) {
        m.rules.maxFeePips = 50_000;
        m.rules.dynamicFeeSens = 10;
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 1);
        m.rules.snipeTaxPips = 1;
        m.rules.burnBps = 0;
        m.rules.lpBps = 0;
        m.rules.royaltyBps = 0;
        m.rules.royaltyTo = address(0);
        m.rules.protocolShareBps = 2000;
        m.rules.maxBuyQuoteAmount = 1e24;
        return m;
    }

    /// @dev A two-member family: the ETH member (dev buy) holds `share` of supply, a tokenA member the rest.
    function _devFamily(uint256 share, uint128 quoteIn)
        internal
        returns (bytes32 family, PoolKey memory key, uint256 out)
    {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](share == SUPPLY ? 1 : 2);
        members[0] = _dynamic(_devMember(subject, ETH, share));
        if (share != SUPPLY) members[1] = _devMember(subject, Currency.wrap(address(tokenA)), SUPPLY - share);
        (family,, out) = _launchWithBuy(t, members, IHookrLauncher.DevBuy(0, quoteIn, 1, 0));
        key = launcher.position(family, 0).key;
    }

    /// @dev One dynamic member at `price` with `liquidity`, launched without a dev buy.
    function _plainPool(uint160 price, uint128 liquidity) internal returns (PoolKey memory key) {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        members[0] = _dynamic(members[0]);
        members[0].sqrtPriceX96 = price;
        members[0].liquidity = liquidity;
        members[0].amount0Max = 1e24;
        (bytes32 family,) = launcher.launch{value: 1e24}(t, address(root), members, vm.getBlockTimestamp());
        key = launcher.position(family, 0).key;
    }

    /// @dev The dynamic fee in pips and the LP fee of a swap of `amount` on `key`.
    function _q(PoolKey memory key, bool buy, uint128 amount) internal returns (uint256 dyn, uint256 fee) {
        uint256 lpFee = quoter.quote(_swap(key, buy, true, amount), trader).lpFeePips;
        // LP fee = base 3,000 + 80% of the dynamic fee.
        dyn = (lpFee - 3000) * 10_000 / 8000;
        fee = lpFee;
    }

    function _buy(PoolKey memory key, uint128 amount) internal {
        IHookrRouter.Swap memory p = _swap(key, true, true, amount);
        vm.prank(trader);
        router.swap{value: amount}(p, address(0), new uint256[](0));
    }

    function _later() internal {
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.roll(vm.getBlockNumber() + 50);
    }

    struct Pools {
        PoolKey dev;
        PoolKey ctl;
        PoolKey old;
        uint256 d;
        uint256 out;
    }

    function _setUpPools(uint256 share, uint128 quoteIn) internal returns (Pools memory s) {
        bytes32 family;
        (family, s.dev, s.out) = _devFamily(share, quoteIn);
        (uint160 p1,,,) = manager.getSlot0(s.dev.toId());
        uint128 liquidity = launcher.position(family, 0).liquidity;
        s.d = FullMath.mulDiv(SQRT_ONE, 1e18, p1) - 1e18;
        // Control: the same band and liquidity launched at the post-dev-buy price.
        s.ctl = _plainPool(p1, liquidity);
        // Ordinary first buy: the same pool at the launch price, first bought through the router for the same amount.
        s.old = _plainPool(SQRT_ONE, liquidity);
        _buy(s.old, quoteIn);
        (uint160 pOld,,,) = manager.getSlot0(s.old.toId());
        assertApproxEqRel(pOld, p1, 1e15, "the ordinary first buy reached the dev buy's price");
    }

    /// @notice A dev buy on a member holding 10% of supply moves the sqrt price ~72%. The next buyer pays the control's
    ///         dynamic fee at once, ten minutes later and after another buy on each pool, with no (1 + d)^2 on top.
    function test_followerPaysTheControlFeeAtEveryAge() public {
        Pools memory s = _setUpPools(SUPPLY / 10, 8e22);
        console2.log("dev buy subject out (share of supply, bps)", s.out * 10_000 / SUPPLY);
        console2.log("dev buy sqrt-price distance d (1e18)", s.d);
        assertGt(s.d, 0.5e18, "a large dev buy move");
        vm.roll(vm.getBlockNumber() + 1);
        (uint256 dev0,) = _q(s.dev, true, FOLLOW);
        (uint256 ctl0,) = _q(s.ctl, true, FOLLOW);
        (uint256 old0,) = _q(s.old, true, FOLLOW);
        console2.log("t+0   follower dynamic fee: dev / control / ordinary", dev0, ctl0, old0);
        assertApproxEqRel(dev0, ctl0, 0.01e18, "t+0: the control's fee");
        assertGt(old0, 10 * dev0, "an ordinary first buy still heats the next buyer's fee");

        _later();
        (uint256 dev600,) = _q(s.dev, true, FOLLOW);
        (uint256 ctl600,) = _q(s.ctl, true, FOLLOW);
        (uint256 old600,) = _q(s.old, true, FOLLOW);
        console2.log("t+600 follower dynamic fee: dev / control / ordinary", dev600, ctl600, old600);
        assertApproxEqRel(dev600, ctl600, 0.01e18, "t+600: the control's fee");
        assertApproxEqRel(old600, ctl600, 0.02e18, "the ordinary first buy's pool converged to the control");

        _buy(s.dev, FOLLOW);
        _buy(s.ctl, FOLLOW);
        _buy(s.old, FOLLOW);
        _later();
        (uint256 dev1200,) = _q(s.dev, true, FOLLOW);
        (uint256 ctl1200,) = _q(s.ctl, true, FOLLOW);
        (uint256 old1200,) = _q(s.old, true, FOLLOW);
        console2.log("t+1200 after one more buy each: dev / control / ordinary", dev1200, ctl1200, old1200);
        assertApproxEqRel(dev1200, ctl1200, 0.01e18, "t+1200: the control's fee");
    }

    /// @notice The one-member family (DB-01's case): after the reset the dev pool charges the follower what the control
    ///         and the ordinary first buy's pool charge.
    function test_oneMemberFamilyMatchesTheControlAfterTheReset() public {
        Pools memory s = _setUpPools(SUPPLY, 4e22);
        _later();
        (uint256 dev600,) = _q(s.dev, true, 1e22);
        (uint256 ctl600,) = _q(s.ctl, true, 1e22);
        (uint256 old600,) = _q(s.old, true, 1e22);
        console2.log("one member, t+600: dev / control / ordinary", dev600, ctl600, old600);
        assertApproxEqRel(dev600, ctl600, 0.01e18, "the control's fee");
        assertLe(dev600, old600 + old600 / 50, "not above the ordinary first buy's pool");
    }

    /// @notice A creator sell of 2% of its dev buy, ten minutes on, leaves the dev pool charging like the ordinary one.
    function test_afterASellTheDevPoolChargesLikeTheOrdinaryOne() public {
        Pools memory s = _setUpPools(SUPPLY / 10, 8e22);
        _later();
        // The creator sells 2% of its dev buy on both pools (it holds the dev pool's subject; the trader, the other).
        uint128 small = uint128(s.out / 50);
        IERC20(Currency.unwrap(s.dev.currency1)).approve(address(router), type(uint256).max);
        IHookrRouter.Swap memory p = _swap(s.dev, false, true, small);
        p.recipient = address(this);
        router.swap(p, address(0), new uint256[](0));
        vm.startPrank(trader);
        IERC20(Currency.unwrap(s.old.currency1)).approve(address(router), type(uint256).max);
        router.swap(_swap(s.old, false, true, small), address(0), new uint256[](0));
        vm.stopPrank();
        _later();
        (uint256 dev,) = _q(s.dev, true, FOLLOW);
        (uint256 old,) = _q(s.old, true, FOLLOW);
        console2.log("after a 2% sell and ten minutes: dev / ordinary", dev, old);
        assertApproxEqRel(dev, old, 0.05e18, "the dev pool charges like the ordinary one");
    }

    /// @notice The dev-buy member's share of supply no longer sets a multiple: at every share the follower pays the
    ///         control's fee ten minutes after the dev buy.
    function test_noMultipleAtAnySharePlaced() public {
        uint256[4] memory shares = [SUPPLY / 4, SUPPLY / 10, SUPPLY * 7 / 100, SUPPLY * 6 / 100];
        uint128[4] memory ins = [uint128(5e22), 8e22, 1.2e23, 1.75e23];
        for (uint256 i; i < 4; ++i) {
            Pools memory s = _setUpPools(shares[i], ins[i]);
            _later();
            (uint256 dev,) = _q(s.dev, true, FOLLOW);
            (uint256 ctl,) = _q(s.ctl, true, FOLLOW);
            (uint256 old,) = _q(s.old, true, FOLLOW);
            console2.log("share bps / out bps", shares[i] * 10_000 / SUPPLY, s.out * 10_000 / SUPPLY);
            console2.log("  t+600 follower dynamic fee dev / control / ordinary", dev, ctl, old);
            assertApproxEqRel(dev, ctl, 0.01e18, "the control's fee");
        }
    }

    /// @notice EC-02. The creator's exit: selling 90% of the dev-bought subject pays the dynamic fee, with its protocol
    ///         share, in the next parent block and ten minutes later, as the same sell does after an ordinary first
    ///         buy once its reference has joined the price.
    function test_devBuyExitPaysTheDynamicFee() public {
        Pools memory s = _setUpPools(SUPPLY / 10, 8e22);
        uint128 sell = uint128(s.out * 9 / 10);
        vm.roll(vm.getBlockNumber() + 1);
        {
            (, uint256 dev0) = _q(s.dev, false, sell);
            (, uint256 ctl0) = _q(s.ctl, false, sell);
            (, uint256 old0) = _q(s.old, false, sell);
            console2.log("same sell in the next parent block, LP fee pips: dev / control / ordinary", dev0, ctl0, old0);
            assertApproxEqRel(dev0, ctl0, 0.01e18, "next parent block: the control's fee");
            assertGt(dev0, 3000 + 10_000, "a dynamic fee on the exit");
        }
        _later();
        (, uint256 devFee) = _q(s.dev, false, sell);
        (, uint256 ctlFee) = _q(s.ctl, false, sell);
        (, uint256 oldFee) = _q(s.old, false, sell);
        console2.log(
            "sell of 90% of the dev buy at t+600, LP fee pips: dev / control / ordinary", devFee, ctlFee, oldFee
        );
        IHookrRouter.Swap memory p = _swap(s.dev, false, true, sell);
        uint256 protoDev = quoter.quote(p, address(this)).quoteFee;
        uint256 protoOld = quoter.quote(_swap(s.old, false, true, sell), address(this)).quoteFee;
        console2.log("protocol quote take on that sell: dev / ordinary", protoDev, protoOld);
        assertApproxEqRel(devFee, ctlFee, 0.01e18, "t+600: the control's fee");
        assertApproxEqRel(devFee, oldFee, 0.05e18, "and the ordinary first buy's");
        assertApproxEqRel(protoDev, protoOld, 0.05e18, "the protocol share of it");

        IERC20 subject = IERC20(Currency.unwrap(s.dev.currency1));
        subject.approve(address(router), type(uint256).max);
        uint256 claimed = rules.claimable(ETH, protocol);
        p.recipient = address(this);
        router.swap(p, address(0), new uint256[](0));
        assertApproxEqAbs(rules.claimable(ETH, protocol) - claimed, protoDev, 1, "the exit paid the protocol");
    }

    /// @dev One swap by the trader on `key`: a buy of `amount` quote or a sell of `amount` subject, exact input.
    function _trade(PoolKey memory key, bool buy, uint128 amount) internal {
        IHookrRouter.Swap memory p = _swap(key, buy, true, amount);
        vm.prank(trader);
        router.swap{value: buy ? amount : 0}(p, address(0), new uint256[](0));
    }

    /// @notice Any short run of buys and sells right after the dev buy (a sell may come in the launch parent block,
    ///         buys from the next one, spread over up to ten minutes) leaves the dev pool charging the next buyer and
    ///         seller what the same run leaves a control launched at the post-buy price charging.
    function testFuzz_anyRunAfterTheDevBuyMatchesTheControl(uint256 seed) public {
        (bytes32 family, PoolKey memory dev, uint256 out) = _devFamily(SUPPLY / 10, 8e22);
        (uint160 p1,,,) = manager.getSlot0(dev.toId());
        PoolKey memory ctl = _plainPool(p1, launcher.position(family, 0).liquidity);
        IERC20(Currency.unwrap(dev.currency1)).transfer(trader, out / 2);
        IERC20(Currency.unwrap(ctl.currency1)).transfer(trader, out / 2);
        vm.startPrank(trader);
        IERC20(Currency.unwrap(dev.currency1)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(ctl.currency1)).approve(address(router), type(uint256).max);
        vm.stopPrank();
        uint256 steps = 1 + seed % 4;
        for (uint256 i; i < steps; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bool buy = r & 1 == 1;
            // The dev buy closed the launch parent block to buys, so only a first sell may stay in it.
            if (buy || i != 0 || r & 2 == 0) {
                vm.roll(vm.getBlockNumber() + 1);
                vm.warp(vm.getBlockTimestamp() + (r >> 16) % 151);
            }
            uint128 amount = uint128(1e18 + (r >> 64) % (buy ? 1e22 : out / 10));
            _trade(dev, buy, amount);
            _trade(ctl, buy, amount);
        }
        vm.roll(vm.getBlockNumber() + 1);
        (, uint256 devBuy) = _q(dev, true, FOLLOW);
        (, uint256 ctlBuy) = _q(ctl, true, FOLLOW);
        (, uint256 devSell) = _q(dev, false, uint128(out / 20));
        (, uint256 ctlSell) = _q(ctl, false, uint128(out / 20));
        assertApproxEqAbs(devBuy, ctlBuy, ctlBuy / 100 + 2, "the next buyer pays the control's fee");
        assertApproxEqAbs(devSell, ctlSell, ctlSell / 100 + 2, "the next seller pays the control's fee");
    }
}
