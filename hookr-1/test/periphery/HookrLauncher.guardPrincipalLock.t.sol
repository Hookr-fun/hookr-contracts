// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

/// @dev Bare PoolManager LP standing in for any third party (PositionManager, market maker, holder).
contract RescueLP is IUnlockCallback {
    IPoolManager internal immutable m;

    constructor(IPoolManager _m) {
        m = _m;
    }

    function add(PoolKey memory key, int24 lo, int24 hi, int256 liq) external {
        m.unlock(abi.encode(key, lo, hi, liq));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, int24 lo, int24 hi, int256 liq) = abi.decode(data, (PoolKey, int24, int24, int256));
        (BalanceDelta d,) = m.modifyLiquidity(key, ModifyLiquidityParams(lo, hi, liq, 0), "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 amt) internal {
        if (amt >= 0) return;
        uint256 a = uint256(uint128(-amt));
        if (Currency.unwrap(c) == address(0)) {
            m.settle{value: a}();
        } else {
            m.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(m), a);
            m.settle();
        }
    }

    receive() external payable {}
}

/// @notice L-06 regression. Original PoC (v1_family_owner_can_pull_100_of_liquidity_d_11, unfixed source): a
/// creator launched RUG with 0 ETH and a 100,000-block guard; three buyers paid 17 ETH; in the same parent block as
/// the last buy the owner withdrew all liquidity for 16.09475 ETH (9,467 bps of buyers' ETH) + 950,190.85 RUG, the
/// pool was left at zero liquidity, the trader's sell reverted InvalidSwap, and Rules refused any third-party add
/// until guardEndBlock 100,001.
/// Fixed: while Rules make the Launcher the only LP, the Launcher refuses LP principal withdrawals from every member
/// of the family (PrincipalLocked) until the family's latest guardEndBlock, and still pays fees.
/// What the fix does NOT do (pinned below as residual behaviour, from the independent review): the lock is not a
/// supply lock. A creator holding subject outside the pools can still sell it into a guarded pool in the same
/// parent block as the last buy and take most of the buyers' quote:
///  - retained new-token supply: 14.616 ETH, 8,597 bps of the buyers' 17 ETH, with zero capital;
///  - an unguarded sibling's principal: was withdrawable (8,597 bps); now locked family-wide, so the creator must
///    buy the sibling's subject and its payment stays in its own locked sibling position, where buyers can reach
///    it by selling into that sibling;
///  - a guarded sibling priced by the creator at ~1e-6 tokenB per subject: 88,702.93 RUG for 1 tokenB, 8,597 bps.
/// Guarantees therefore depend on creator-held subject and every sibling's quote and price being shown to buyers.
contract HookrLauncherGuardPrincipalLockTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal buyer2 = address(0xB002);
    address internal buyer3 = address(0xB003);
    Currency internal constant ETH = Currency.wrap(address(0));

    function setUp() public {
        _setUpPeriphery();
        vm.deal(buyer2, 100 ether);
        vm.deal(buyer3, 100 ether);
    }

    function _ethMember(uint256 guardEnd) internal view returns (IHookrLauncher.Member memory m) {
        m = _member(ETH);
        m.tickLower = -60_000;
        m.tickUpper = 0;
        m.liquidity = 1e24;
        m.amount0Max = 0;
        m.amount1Max = 1e24;
        m.rules.guardEndBlock = uint40(guardEnd);
        m.rules.snipeTaxPips = 100_000;
    }

    function _rugLaunch(uint256 guardLength)
        internal
        returns (bytes32 family, PoolKey memory key, address subject, uint256 guardEnd)
    {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        // vm.getBlockNumber(): via-IR may rematerialize block.number after vm.roll.
        uint256 expectedEnd = vm.getBlockNumber() + guardLength;
        members[0] = _ethMember(expectedEnd);
        IHookrLauncher.Token memory token = IHookrLauncher.Token(address(0), "Rug", "RUG", 1e27, bytes32(uint256(7)));
        (family, subject) = launcher.launch{value: 0}(token, address(root), members, block.timestamp);
        key = launcher.position(family, 0).key;
        guardEnd = launcher.principalLockedUntil(family);
        assertEq(guardEnd, expectedEnd);
        IERC20(subject).approve(address(launcher), type(uint256).max);
    }

    function _buy(address who, PoolKey memory key, uint128 amount, address subject) internal returns (uint256 got) {
        IHookrRouter.Swap memory p = _swap(key, true, true, amount);
        p.recipient = who;
        uint256 b = IERC20(subject).balanceOf(who);
        vm.prank(who);
        router.swap{value: amount}(p, address(0), new uint256[](0));
        got = IERC20(subject).balanceOf(who) - b;
    }

    /// @dev The original PoC's buys: 10, 5 and 2 ETH in three consecutive parent blocks.
    function _threeBuys(PoolKey memory key, address subject) internal returns (uint256 paid, uint256 got1) {
        uint256 t0 = trader.balance;
        uint256 t2 = buyer2.balance;
        uint256 t3 = buyer3.balance;
        got1 = _buy(trader, key, 10 ether, subject);
        vm.roll(vm.getBlockNumber() + 1);
        _buy(buyer2, key, 5 ether, subject);
        vm.roll(vm.getBlockNumber() + 1);
        _buy(buyer3, key, 2 ether, subject);
        paid = (t0 - trader.balance) + (t2 - buyer2.balance) + (t3 - buyer3.balance);
    }

    /// @dev Sells `amount` subject for ETH as the test contract (the creator) and returns the ETH received.
    function _dump(PoolKey memory key, uint256 amount, address subject) internal returns (uint256 eth) {
        IERC20(subject).approve(address(router), type(uint256).max);
        IHookrRouter.Swap memory p = _swap(key, false, true, uint128(amount));
        p.recipient = address(this);
        uint256 b = address(this).balance;
        router.swap(p, address(0), new uint256[](0));
        eth = address(this).balance - b;
    }

    function _lockedError(bytes32 family, uint8 member, uint256 until) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHookrLauncher.PrincipalLocked.selector, family, member, until);
    }

    function testGuardRugIsRefusedAndBuyersKeepTheirExit() public {
        (bytes32 family, PoolKey memory key, address subject, uint256 guardEnd) = _rugLaunch(100_000);
        PoolId id = key.toId();
        uint256 got1 = _buy(trader, key, 10 ether, subject);
        vm.roll(vm.getBlockNumber() + 1);
        _buy(buyer2, key, 5 ether, subject);
        vm.roll(vm.getBlockNumber() + 1);
        _buy(buyer3, key, 2 ether, subject);
        uint128 liq = launcher.position(family, 0).liquidity;
        uint128 poolLiquidity = manager.getLiquidity(id);

        // The original exploit: withdraw everything in the same parent block as the last buy.
        vm.expectRevert(_lockedError(family, 0, guardEnd));
        launcher.withdraw(family, 0, liq, 0, 0, address(this), block.timestamp);
        // Even one unit of principal, and through the claims path, is refused.
        vm.expectRevert(_lockedError(family, 0, guardEnd));
        launcher.withdrawWithClaims(family, 0, 1, 0, 0, address(this), 3, block.timestamp);

        // Fee collection stays available. This bounds what the LP position pays out during the guard, not what a
        // creator holding subject elsewhere can take by selling it (see the residual tests below).
        uint256 ethBefore = address(this).balance;
        (uint256 fee0,) = launcher.withdraw(family, 0, 0, 0, 0, address(this), block.timestamp);
        assertEq(address(this).balance - ethBefore, fee0);
        assertLt(fee0, 17 ether / 10, "LP fees only through the position (the withdrawal took 16.09475 ETH)");
        console2.log("owner fees collectable during guard (wei ETH)", fee0);
        assertEq(manager.getLiquidity(id), poolLiquidity, "pool keeps its liquidity");

        // Buyers can still sell into the pool.
        vm.startPrank(trader);
        IERC20(subject).approve(address(router), type(uint256).max);
        vm.stopPrank();
        IHookrRouter.Swap memory sell = _swap(key, false, true, uint128(got1));
        uint256 traderEth = trader.balance;
        vm.prank(trader);
        router.swap(sell, address(0), new uint256[](0));
        assertGt(trader.balance, traderEth, "sell into the guarded pool works");

        // Rules still refuse third-party adds during the guard (unchanged; it protects the snipe tax).
        RescueLP lp = new RescueLP(manager);
        vm.deal(address(lp), 1_000 ether);
        IERC20(subject).transfer(address(lp), 1e24);
        bytes memory refused = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(root),
            IHooks.beforeAddLiquidity.selector,
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector,
                address(rules),
                IHookrRules.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IHookrRulesState.GuardLiquidity.selector)
            ),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        vm.expectRevert(refused);
        lp.add(key, -60_000, 60_000, 1e18);

        // One block before the end, still locked.
        vm.roll(guardEnd - 1);
        vm.expectRevert(_lockedError(family, 0, guardEnd));
        launcher.withdraw(family, 0, liq, 0, 0, address(this), block.timestamp);

        // At guardEndBlock the owner's exit and third-party adds open together.
        vm.roll(guardEnd);
        lp.add(key, -60_000, 60_000, 1e18);
        launcher.withdraw(family, 0, liq, 0, 0, address(this), block.timestamp);
        assertEq(launcher.position(family, 0).liquidity, 0);
    }

    function testUnguardedFamilyIsNotLocked() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(ETH);
        IHookrLauncher.Token memory token = IHookrLauncher.Token(address(0), "Ok", "OK", 1e27, bytes32(uint256(8)));
        (bytes32 family,) = launcher.launch{value: 1e24}(token, address(root), members, block.timestamp);
        assertEq(launcher.principalLockedUntil(family), 0);
        uint128 liq = launcher.position(family, 0).liquidity;
        launcher.withdraw(family, 0, liq, 0, 0, address(this), block.timestamp);
        assertEq(launcher.position(family, 0).liquidity, 0);
    }

    function testLockCoversToppedUpLiquidityAndSurvivesTransfer() public {
        (bytes32 family,,, uint256 guardEnd) = _rugLaunch(50);
        launcher.addLiquidity(family, 0, 1e20, 0, 1e24, block.timestamp);
        vm.expectRevert(_lockedError(family, 0, guardEnd));
        launcher.withdraw(family, 0, 1e20, 0, 0, address(this), block.timestamp);
        launcher.transferFamily(family, trader, 0);
        vm.prank(trader);
        launcher.acceptFamily(family);
        vm.prank(trader);
        vm.expectRevert(_lockedError(family, 0, guardEnd));
        launcher.withdraw(family, 0, 1e20, 0, 0, trader, block.timestamp);
        vm.roll(guardEnd);
        vm.prank(trader);
        launcher.withdraw(family, 0, 1e20, 0, 0, trader, block.timestamp);
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzzLockEndsExactlyAtGuardEnd(uint256 length) public {
        length = bound(length, 1, 100_000);
        (bytes32 family,,, uint256 guardEnd) = _rugLaunch(length);
        assertEq(launcher.principalLockedUntil(family), guardEnd);
        vm.roll(guardEnd - 1);
        vm.expectRevert(_lockedError(family, 0, guardEnd));
        launcher.withdraw(family, 0, 1, 0, 0, address(this), block.timestamp);
        vm.roll(guardEnd);
        launcher.withdraw(family, 0, 1, 0, 0, address(this), block.timestamp);
    }

    /// Family-wide lock: every member (guarded, shorter-guarded or unguarded) keeps its principal until the
    /// family's latest guardEndBlock; fees stay collectable from every member.
    function testFamilyLockIsTheLatestGuardAndCoversEveryMember() public {
        uint256 now_ = vm.getBlockNumber();
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](3);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[0].rules.guardEndBlock = uint40(now_ + 50);
        members[0].rules.snipeTaxPips = 100_000;
        members[1] = _member(ETH);
        members[1].rules.guardEndBlock = uint40(now_ + 200);
        members[1].rules.snipeTaxPips = 100_000;
        members[2] = _member(Currency.wrap(address(tokenA))); // unguarded
        IHookrLauncher.Token memory token = IHookrLauncher.Token(address(0), "Fam", "FAM", 1e27, bytes32(uint256(21)));
        (bytes32 family,) = launcher.launch{value: 1e24}(token, address(root), members, block.timestamp);
        uint256 until = now_ + 200;
        assertEq(launcher.principalLockedUntil(family), until);
        vm.roll(now_ + 50); // member 0's own guard has ended, member 2 never had one
        for (uint8 i; i < 3; ++i) {
            vm.expectRevert(_lockedError(family, i, until));
            launcher.withdraw(family, i, 1, 0, 0, address(this), block.timestamp);
            launcher.withdraw(family, i, 0, 0, 0, address(this), block.timestamp); // fee collection
        }
        vm.roll(until);
        for (uint8 i; i < 3; ++i) {
            uint128 liq = launcher.position(family, i).liquidity;
            launcher.withdraw(family, i, liq, 0, 0, address(this), block.timestamp);
        }
    }

    /// A guard beyond HookrRules' own 100,000-block bound fails closed in the Launcher, whatever Rules module is
    /// named, so a family can never be locked for longer than that.
    function testGuardBeyondRulesBoundFailsClosed() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        uint256 tooLong = vm.getBlockNumber() + 100_001;
        members[0] = _ethMember(tooLong);
        IHookrLauncher.Token memory token = IHookrLauncher.Token(address(0), "Rug", "RUG", 1e27, bytes32(uint256(7)));
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.GuardTooLong.selector, uint8(0), tooLong));
        launcher.launch{value: 0}(token, address(root), members, block.timestamp);
        members[0].rules.guardEndBlock = uint40(tooLong - 1);
        (bytes32 family,) = launcher.launch{value: 0}(token, address(root), members, block.timestamp);
        assertEq(launcher.principalLockedUntil(family), tooLong - 1);
    }

    // ---- Residual behaviour (independent review, variants A1-A3), pinned so a change is noticed. ----

    /// A1: the lock holds, but the creator keeps the unallocated new-token supply and sells it into the guarded
    /// pool in the same parent block as the last buy. Not prevented: the lock is not a supply lock.
    function testResidualRetainedSupplyDumpDuringGuard() public {
        (bytes32 family, PoolKey memory key, address subject, uint256 guardEnd) = _rugLaunch(100_000);
        uint256 retained = IERC20(subject).balanceOf(address(this));
        console2.log("creator retained RUG", retained);
        (uint256 paid, uint256 got1) = _threeBuys(key, subject);
        vm.expectRevert(_lockedError(family, 0, guardEnd));
        launcher.withdraw(family, 0, 1, 0, 0, address(this), block.timestamp);
        uint256 creatorEth = _dump(key, 1e24, subject);
        console2.log("buyers paid (wei)", paid);
        console2.log("creator ETH from dumping retained supply (wei)", creatorEth);
        console2.log("bps of buyers' ETH", creatorEth * 10_000 / paid);
        assertGt(creatorEth, paid * 8_000 / 10_000, "residual: retained supply still drains the guarded pool");
        // The trader's own sell of its 10 ETH purchase cannot fill: the quote side is gone.
        IHookrRouter.Swap memory ts = _swap(key, false, true, uint128(got1));
        vm.startPrank(trader);
        IERC20(subject).approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.swap(ts, address(0), new uint256[](0));
        vm.stopPrank();
    }

    /// A2: a second member with no guard held subject. Its principal used to be withdrawable and dumped into the
    /// guarded member (8,597 bps). The family-wide lock now refuses that withdrawal; the remaining path is buying
    /// the sibling's subject, whose payment stays in the creator's own locked sibling position.
    function testUnguardedSiblingPrincipalIsLockedFamilyWide() public {
        IHookrLauncher.Token memory token = IHookrLauncher.Token(address(0), "Rug", "RUG", 1e27, bytes32(uint256(9)));
        address predicted = launcher.predictToken(address(this), token);
        uint256 guardEnd = vm.getBlockNumber() + 100_000;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _ethMember(guardEnd);
        members[1] = _member(Currency.wrap(address(tokenB)));
        bool rugFirst = predicted < address(tokenB);
        members[1].tickLower = rugFirst ? int24(0) : int24(-60_000);
        members[1].tickUpper = rugFirst ? int24(60_000) : int24(0);
        members[1].amount0Max = rugFirst ? 1e24 : 0;
        members[1].amount1Max = rugFirst ? 0 : 1e24;
        (bytes32 family, address subject) = launcher.launch{value: 0}(token, address(root), members, block.timestamp);
        assertEq(launcher.principalLockedUntil(family), guardEnd, "the unguarded sibling shares the family lock");
        IERC20(subject).transfer(address(0xdEaD), IERC20(subject).balanceOf(address(this)));
        PoolKey memory key0 = launcher.position(family, 0).key;
        PoolKey memory key1 = launcher.position(family, 1).key;
        (uint256 paid, uint256 got1) = _threeBuys(key0, subject);
        uint128 liq1 = launcher.position(family, 1).liquidity;
        vm.expectRevert(_lockedError(family, 1, guardEnd));
        launcher.withdraw(family, 1, liq1, 0, 0, address(this), block.timestamp);
        // Residual: buy the sibling's subject at the creator's own sibling price, then dump it.
        tokenB.approve(address(router), type(uint256).max);
        uint256 bBefore = tokenB.balanceOf(address(this));
        IHookrRouter.Swap memory buy = _swap(key1, true, true, 20e18);
        buy.recipient = address(this);
        router.swap(buy, address(0), new uint256[](0));
        uint256 spentB = bBefore - tokenB.balanceOf(address(this));
        uint256 creatorEth = _dump(key0, IERC20(subject).balanceOf(address(this)), subject);
        console2.log("buyers paid (wei)", paid);
        console2.log("creator ETH via bought sibling subject (wei)", creatorEth);
        console2.log("bps of buyers' ETH", creatorEth * 10_000 / paid);
        assertEq(spentB, 20e18, "the drain now costs sibling quote, held in the locked sibling position");
        // Was (withdraw route): 1e24 RUG principal for free, same 14.616 ETH, 8,597 bps, nothing left behind.
        // Now the creator's payment stays in its locked sibling, and a buyer can reach it by selling there.
        IHookrRouter.Swap memory exit = _swap(key1, false, true, uint128(got1));
        vm.startPrank(trader);
        IERC20(subject).approve(address(router), type(uint256).max);
        uint256 traderB = tokenB.balanceOf(trader);
        router.swap(exit, address(0), new uint256[](0));
        vm.stopPrank();
        uint256 recovered = tokenB.balanceOf(trader) - traderB;
        console2.log("trader's 10 ETH purchase sold into the sibling for tokenB", recovered);
        assertGt(recovered, 0, "buyers keep an exit into the creator's locked payment");
    }

    /// A3: every member guarded and locked, but the creator prices the sibling at ~1e-6 tokenB per subject, buys
    /// its subject for 1 tokenB and dumps it into the ETH member. Not prevented without a cross-member price check
    /// (I-07) or quote qualification; the family-wide lock does not change it.
    function testResidualMispricedGuardedSiblingDrainsDuringGuard() public {
        IHookrLauncher.Token memory token = IHookrLauncher.Token(address(0), "Rug", "RUG", 1e27, bytes32(uint256(11)));
        address predicted = launcher.predictToken(address(this), token);
        uint256 guardEnd = vm.getBlockNumber() + 100_000;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _ethMember(guardEnd);
        members[1] = _member(Currency.wrap(address(tokenB)));
        members[1].rules.guardEndBlock = uint40(guardEnd);
        members[1].rules.snipeTaxPips = 100_000;
        members[1].liquidity = 1e20;
        bool rugFirst = predicted < address(tokenB);
        // RUG priced at ~1e-6 tokenB; single-sided RUG range on the far side of the price.
        if (rugFirst) {
            members[1].sqrtPriceX96 = uint160(uint256(SQRT_ONE) / 1000);
            members[1].tickLower = -138_120;
            members[1].tickUpper = -78_120;
            members[1].amount0Max = 1e24;
            members[1].amount1Max = 0;
        } else {
            members[1].sqrtPriceX96 = uint160(uint256(SQRT_ONE) * 1000);
            members[1].tickLower = 78_120;
            members[1].tickUpper = 138_120;
            members[1].amount0Max = 0;
            members[1].amount1Max = 1e24;
        }
        (bytes32 family, address subject) = launcher.launch{value: 0}(token, address(root), members, block.timestamp);
        assertEq(launcher.principalLockedUntil(family), guardEnd);
        IERC20(subject).transfer(address(0xdEaD), IERC20(subject).balanceOf(address(this)));
        PoolKey memory key0 = launcher.position(family, 0).key;
        PoolKey memory key1 = launcher.position(family, 1).key;
        (uint256 paid,) = _threeBuys(key0, subject);
        tokenB.approve(address(router), type(uint256).max);
        uint256 bBefore = tokenB.balanceOf(address(this));
        IHookrRouter.Swap memory cheap = _swap(key1, true, true, 1e18); // 1 tokenB
        cheap.recipient = address(this);
        router.swap(cheap, address(0), new uint256[](0));
        uint256 rug = IERC20(subject).balanceOf(address(this));
        console2.log("tokenB spent (locked in creator's own member 1)", bBefore - tokenB.balanceOf(address(this)));
        console2.log("RUG obtained from locked sibling", rug);
        uint256 creatorEth = _dump(key0, rug, subject);
        console2.log("buyers paid (wei)", paid);
        console2.log("creator ETH via mispriced locked sibling (wei)", creatorEth);
        console2.log("bps of buyers' ETH", creatorEth * 10_000 / paid);
        assertGt(creatorEth, paid * 8_000 / 10_000, "residual: a creator-priced sibling still drains");
    }
}
