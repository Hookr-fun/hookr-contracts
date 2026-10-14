// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRoot} from "../../src/interfaces/IHookrRoot.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {LaneRootFixture} from "./utils/LaneRootFixture.sol";

/// @notice A hostile executor that holds the pinned codehash and never breaks a frame check: in the before-phase it
///         buys the subject on the triggering pool (a base-fee leg, no rule), in the after-phase it sells it back (a
///         base-fee leg in a new frame, so the one-direction rule does not bind), reports zero profit and pushes
///         nothing. It cannot see the trade in the before-phase; it guesses a buy.
contract SandwichExecutor {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    uint160 internal constant MIN_PRICE = 4295128740;
    uint160 internal constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;
    IPoolManager public immutable manager;
    address public immutable root;
    uint256 public front;
    uint256 public held;
    uint256 public spent;
    int256 public pnl;
    uint256 public calls;

    constructor(IPoolManager _manager, address _root) {
        manager = _manager;
        root = _root;
    }

    function setFront(uint256 f) external {
        front = f;
    }

    function executeArbitrage(PoolKey calldata key, address) external returns (uint256) {
        require(msg.sender == root, "root");
        calls++;
        HookrTypes.PoolConfig memory pc = IHookrRoot(root).poolConfig(key.toId());
        bool quoteIs0 = pc.quote == key.currency0;
        if (held == 0) {
            if (front == 0) return 0;
            // Before-phase: buy the subject with `front` quote.
            bool z = quoteIs0;
            BalanceDelta d = manager.swap(key, SwapParams(z, -int256(front), z ? MIN_PRICE + 1 : MAX_PRICE - 1), "");
            (int128 qd, int128 sd) = quoteIs0 ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
            uint256 paid = uint256(uint128(-qd));
            _pay(pc.quote, paid);
            held = uint256(uint128(sd));
            spent = paid;
            manager.take(pc.subject, address(this), held);
        } else {
            // After-phase: sell it all back.
            bool z = !quoteIs0;
            BalanceDelta d = manager.swap(key, SwapParams(z, -int256(held), z ? MIN_PRICE + 1 : MAX_PRICE - 1), "");
            (int128 qd,) = quoteIs0 ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
            uint256 got = uint256(uint128(qd));
            _pay(pc.subject, held);
            manager.take(pc.quote, address(this), got);
            pnl = int256(got) - int256(spent);
            held = 0;
        }
        return 0;
    }

    function _pay(Currency c, uint256 a) internal {
        if (c.isAddressZero()) {
            manager.settle{value: a}();
        } else {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(manager), a);
            manager.settle();
        }
    }

    receive() external payable {}
}

/// @notice ATK-EX-2, pinned known limit (the executor trust class): an executor with the pinned code can sandwich a lane
///         swap inside the trader's slippage at the pool's base LP fee, with both frames "succeeded", zero pushed, and
///         no frame check that can tell it from an honest idle call. The root cannot check the executor's intent; the
///         partner obligations, the codehash review, the fork rehearsal and a watchdog on the guardian's brake guard
///         it (the release's executor guide). These tests pin its size.
contract ExecutorSandwichTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    SandwichExecutor internal sw;
    PoolKey internal key;
    HookrToken internal subject;

    function setUp() public {
        _setUpLane();
        sw = new SandwichExecutor(manager, address(root));
        vm.deal(address(sw), 1e27);
        _openLane(address(sw), 3_000_000);
        subject = _newSubject();
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        // A 0.3% base fee pool with 2% LP Rewards: an outside sandwicher's buy leg pays the LP Rewards, a lane leg does not.
        members[0] = _member(ETH, true, false, 200);
        members[0].config.baseLpFeePips = 3000;
        members[0].rules.maxFeePips = 3000;
        PoolKey[] memory keys;
        (, keys) = _launch(subject, members);
        key = keys[0];
        _nextBlock();
    }

    function _buyWithMin(uint256 quoteIn, uint256 minOut) internal returns (uint256 out) {
        IHookrRouter.Swap memory p = _swapParams(key, ETH, true, true, quoteIn, whale);
        p.amountBound = uint128(minOut);
        vm.prank(whale);
        (, out) = router.swap{value: quoteIn}(p, address(0), new uint256[](0));
    }

    function buyWithMin(uint256 quoteIn, uint256 minOut) external returns (uint256) {
        require(msg.sender == address(this));
        return _buyWithMin(quoteIn, minOut);
    }

    function test_pinned_hostileExecutorSandwichesWithinSlippage_pushingNothing() public {
        uint256 tradeIn = 1e22;
        // The trader's quote: the same buy with the executor idle.
        uint256 snap = vm.snapshotState();
        uint256 quoted = _buyWithMin(tradeIn, 1);
        vm.revertToState(snap);
        uint256 minOut = quoted * 99 / 100; // 1% slippage
        console2.log("trader buy (ETH), quoted subject out, minOut (1%)", tradeIn, quoted, minOut);

        // The largest front-run that keeps the trader inside 1% slippage.
        uint256[6] memory fronts = [uint256(1e21), 2e21, 3e21, 4e21, 5e21, 6e21];
        uint256 best;
        for (uint256 i; i < fronts.length; ++i) {
            uint256 s2 = vm.snapshotState();
            sw.setFront(fronts[i]);
            try this.buyWithMin(tradeIn, minOut) returns (uint256) {
                best = fronts[i];
            } catch {}
            vm.revertToState(s2);
        }
        assertGt(best, 0, "some front-run fits inside the trader's slippage");

        sw.setFront(best);
        uint256 lpBefore = _accrued(key);
        uint256 protocolBefore = rules.claimable(ETH, protocol);
        vm.recordLogs();
        uint256 got = _buyWithMin(tradeIn, minOut);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        console2.log("front-run (ETH) and trader subject out", best, got);
        console2.log("trader shortfall vs quote (subject), bps", quoted - got, (quoted - got) * 10_000 / quoted);
        console2.log("executor profit (ETH wei)", uint256(sw.pnl()));
        assertEq(o.succeeded, 2, "both frames succeeded");
        assertEq(o.failed, 0, "no frame check tripped");
        assertEq(o.pushedBefore + o.pushedAfter, 0, "nothing pushed");
        assertEq(_accrued(key), lpBefore, "the LP accrual got nothing");
        assertEq(_splits(logs).count, 0, "no arb recapture split: the protocol, trader and LP legs got nothing");
        // The protocol's claim grew only by its share of the trader's own LP Rewards (25% of 2% of the buy).
        assertEq(rules.claimable(ETH, protocol) - protocolBefore, tradeIn * 200 / 10_000 * 2500 / 10_000);
        assertGt(sw.pnl(), 0, "the executor kept a profit taken from the trader");
        assertGe(got, minOut, "the trader's slippage check passed");
        assertLt(got, quoted, "the trader got less than quoted");
    }

    /// The same sandwich by an outside party, in three transactions around the trader's (the best case for it): its
    /// buy pays the pool's Rules, so the same 5e21 front-run loses.
    function test_pinned_theSameSandwichByAnOutsiderLoses() public {
        uint256 tradeIn = 1e22;
        uint256 front = 5e21;
        uint256 snap = vm.snapshotState();
        uint256 quoted = _buyWithMin(tradeIn, 1);
        vm.revertToState(snap);
        uint256 ethBefore = attacker.balance;
        uint256 s = _buy(key, ETH, attacker, front);
        _nextBlock();
        uint256 got = _buyWithMin(tradeIn, quoted * 99 / 100);
        _nextBlock();
        _sell(key, ETH, attacker, s);
        int256 pnl = int256(attacker.balance) - int256(ethBefore);
        console2.log("outsider front-run (ETH), trader out", front, got);
        console2.logInt(pnl);
        assertLt(pnl, 0, "an outsider paying the Rules loses on the same sandwich");
    }
}
