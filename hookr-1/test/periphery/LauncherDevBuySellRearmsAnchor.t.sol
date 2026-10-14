// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {DevBuyFixture} from "./DevBuyFixture.sol";

/// @notice DB-04. When the dev buy left the reference and anchor at the launch price, a small creator sell right after
///         it paid no dynamic fee (it moved toward the reference) and carried the anchor from the launch price to the
///         post-buy price, so the next buyer was charged from the dev buy's end and most of that fee reached the
///         creator's own position. The dev buy now leaves the state unstarted: the sell starts it at the post-buy price
///         and is charged for its own move, and the follower is charged no more than without the sell.
contract LauncherDevBuySellRearmsAnchorTest is DevBuyFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Currency internal constant ETH = Currency.wrap(address(0));
    uint128 internal constant DEV = 4e22;
    uint128 internal constant FOLLOW = 1e22;

    function setUp() public {
        _setUpPeriphery();
    }

    /// @dev DB-01's dynamic fee member: sensitivity 10, 5% ceiling, 20% share, a 1-pip Snipe for one parent block and
    ///      no LP Rewards, burn or royalty.
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
        return m;
    }

    function _devPool() internal returns (bytes32 family, PoolKey memory key, uint256 out) {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        members[0] = _dynamic(members[0]);
        (family,, out) = _launchWithBuy(t, members, IHookrLauncher.DevBuy(0, DEV, 1, 0));
        key = launcher.position(family, 0).key;
    }

    /// @dev The same member launched at `price` with `liquidity`, without a dev buy.
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

    function _lpFee(PoolKey memory key, uint128 amount) internal returns (uint256) {
        return quoter.quote(_swap(key, true, true, amount), trader).lpFeePips;
    }

    function _dyn(uint256 lpFee) internal pure returns (uint256) {
        return (lpFee - 3000) * 10_000 / 8000;
    }

    function _sell(PoolKey memory key, uint256 amount) internal {
        IERC20(Currency.unwrap(key.currency1)).approve(address(router), amount);
        IHookrRouter.Swap memory sell = _swap(key, false, true, uint128(amount));
        sell.recipient = address(this);
        router.swap(sell, address(0), new uint256[](0));
    }

    /// @dev The follower's buy, then the creator's fee collection on the member: the quote fees the creator gains.
    function _followAndCollect(bytes32 family, PoolKey memory key) internal returns (uint256 creatorFees) {
        IHookrRouter.Swap memory p = _swap(key, true, true, FOLLOW);
        vm.prank(trader);
        router.swap{value: FOLLOW}(p, address(0), new uint256[](0));
        (creatorFees,) = launcher.withdraw(family, 0, 0, 0, 0, address(this), vm.getBlockTimestamp());
    }

    /// @notice The DB-04 sequence on the dev pool and on a control launched at the post-dev-buy price with the same
    ///         band and liquidity: a 1% creator sell in the launch parent block, then a follower in the next one.
    function test_smallSellAfterDevBuyDoesNotRestoreThePreheat() public {
        (bytes32 family, PoolKey memory key, uint256 out) = _devPool();
        (uint160 p1, int24 priceTick,,) = manager.getSlot0(key.toId());
        PoolKey memory ctl = _plainPool(p1, launcher.position(family, 0).liquidity);
        (, int24 ref0, int24 anchor0, uint40 movedAt0,,) = rules.referenceState(key.toId());
        assertEq(movedAt0, 0, "the dev buy left the dynamic fee state unstarted");
        // The creator collects the dev buy's own LP fees first, so later collections measure only what follows.
        launcher.withdraw(family, 0, 0, 0, 0, address(this), vm.getBlockTimestamp());
        uint256 snap = vm.snapshotState();

        // A: no sell. The next parent block's follower pays for its own move only.
        vm.roll(vm.getBlockNumber() + 1);
        uint256 feeClean = _dyn(_lpFee(key, FOLLOW));
        uint256 ctlClean = _dyn(_lpFee(ctl, FOLLOW));
        uint256 creatorClean = _followAndCollect(family, key);
        vm.revertToState(snap);

        // B: in the launch parent block the creator sells 1% of its dev-bought subject back into each pool.
        uint256 sold = out / 100;
        uint256 ethBefore = address(this).balance;
        _sell(key, sold);
        uint256 ethFromSell = address(this).balance - ethBefore;
        _sell(ctl, sold);
        (, int24 ref1, int24 anchor1,,,) = rules.referenceState(key.toId());
        (, int24 tickAfterSell,,) = manager.getSlot0(key.toId());
        vm.roll(vm.getBlockNumber() + 1);
        uint256 feeAfterSell = _dyn(_lpFee(key, FOLLOW));
        uint256 ctlAfterSell = _dyn(_lpFee(ctl, FOLLOW));
        uint256 creatorAfterSell = _followAndCollect(family, key);

        console2.log("dev buy subject out", out);
        console2.log("price tick after the dev buy", int256(priceTick));
        console2.log("reference tick after the dev buy", int256(ref0));
        console2.log("anchor tick after the dev buy", int256(anchor0));
        console2.log("creator sell, subject / quote back", sold, ethFromSell);
        console2.log("price tick after the sell", int256(tickAfterSell));
        console2.log("reference tick after the sell", int256(ref1));
        console2.log("anchor tick after the sell", int256(anchor1));
        console2.log("follower dynamic fee, no sell: dev / control", feeClean, ctlClean);
        console2.log("follower dynamic fee after the 1% sell: dev / control", feeAfterSell, ctlAfterSell);
        console2.log("creator LP fees from the follower, no sell / after the sell", creatorClean, creatorAfterSell);

        assertEq(ref1, priceTick, "the sell started the reference at the post-buy price");
        assertGe(anchor1, ref1, "the anchor moved only on the sell's side of the reference");
        assertApproxEqAbs(feeClean, ctlClean, ctlClean / 100 + 2, "no sell: the control's fee");
        assertApproxEqAbs(feeAfterSell, ctlAfterSell, ctlAfterSell / 100 + 2, "after the sell: the control's fee");
        assertLe(feeAfterSell, ctlClean + ctlClean / 100 + 2, "the sell cannot raise the follower above the control");
        assertLe(creatorAfterSell, creatorClean + creatorClean / 100, "the creator earns no more from the follower");
    }
}
