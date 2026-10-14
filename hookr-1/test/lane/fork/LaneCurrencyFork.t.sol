// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookrLauncher} from "../../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../../src/support/HookrToken.sol";
import {IHookrLaneRoot} from "../../../src/interfaces/IHookrLaneRoot.sol";
import {LaneFixture} from "../LaneFixture.sol";
import {ScriptedExecutor} from "../mocks/ScriptedExecutor.sol";
import {Actor} from "../mocks/Actors.sol";
import {ArbSysKit} from "../../kit/ArbSysMock.sol";
import {IHookrLaneEvents} from "../../../src/interfaces/IHookrLaneEvents.sol";
import {IHookrRecaptureEvents} from "../../../src/interfaces/IHookrRecaptureEvents.sol";
import {IHookrRootEvents} from "../../../src/interfaces/IHookrRootEvents.sol";

interface IWETH9 {
    function deposit() external payable;
}

/// @notice A partner-shaped executor that recaptures along one configured cycle per triggering pool and pushes its
///         profit in the currency the cycle starts and ends in, whatever the triggering pool's quote. While the cycle
///         returns more than it spends it runs another chunk; a losing chunk unwinds alone and the chunk halves.
contract RouteExecutor {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for IPoolManager;

    struct Hop {
        PoolKey key;
        bool zeroForOne;
    }

    error NotProfitable(uint256 spent, uint256 got);

    /// @notice The partner's share of each profit, kept before the push: WTH's production share, 25%, the share the
    ///         fixture's lane pins (LaneFixture.PARTNER_BPS).
    uint256 public constant KEEP_BPS = 2_500;

    IPoolManager public immutable manager;
    address public immutable root;
    address public immutable partner;
    mapping(PoolId => Hop[]) internal _routes;
    mapping(PoolId => Currency) public startOf;
    mapping(PoolId => uint256) public firstChunk;
    uint256 public lastProfit;
    uint256 public lastPushed;

    constructor(IPoolManager m, address r, address p) {
        (manager, root, partner) = (m, r, p);
    }

    function setRoute(PoolKey calldata trigger, Hop[] calldata hops, Currency start, uint256 chunk) external {
        PoolId id = trigger.toId();
        delete _routes[id];
        for (uint256 i; i < hops.length; ++i) {
            _routes[id].push(hops[i]);
        }
        (startOf[id], firstChunk[id]) = (start, chunk);
    }

    function executeArbitrage(PoolKey calldata key, address) external returns (uint256 profit) {
        require(msg.sender == root, "root");
        PoolId id = key.toId();
        if (_routes[id].length == 0) return 0;
        Currency start = startOf[id];
        int256 before = manager.currencyDelta(address(this), start);
        uint256 chunk = firstChunk[id];
        for (uint256 i; i < 16 && chunk >= 1e9 && gasleft() > 600_000; ++i) {
            try this.cycle(id, chunk) {}
            catch {
                chunk /= 2;
            }
        }
        int256 end = manager.currencyDelta(address(this), start);
        if (end <= before) return 0;
        profit = uint256(end - before);
        uint256 keep = profit * KEEP_BPS / 10_000;
        uint256 pushed = profit - keep;
        manager.take(start, partner, keep);
        // Mint to the root right before settling, after the last leg.
        manager.mint(root, start.toId(), pushed);
        IHookrLaneRoot(root).settleRecapture(key, start, pushed);
        (lastProfit, lastPushed) = (profit, pushed);
    }

    /// @notice One chunk around the cycle, reverting unless it returns more than it spent. Only this contract.
    function cycle(PoolId id, uint256 amount) external {
        require(msg.sender == address(this), "self");
        Hop[] storage hops = _routes[id];
        uint256 a = amount;
        for (uint256 i; i < hops.length; ++i) {
            bool z = hops[i].zeroForOne;
            BalanceDelta d = manager.swap(
                hops[i].key,
                SwapParams(z, -int256(a), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                ""
            );
            a = uint256(uint128(z ? d.amount1() : d.amount0()));
        }
        if (a <= amount) revert NotProfitable(amount, a);
    }
}

/// @notice The push currency on a Robinhood Chain 4663 fork, against the real PoolManager, WETH and USDG (both in the
///         registry's settlement set at genesis): an ETH push on a USDG-quoted King of the Pool pool through a
///         triangular path, a USDG push with the trader leg and the pot, a WETH push, a subject push, a stray mint, a
///         mixed-currency frame, the sweep inside and outside a swap, the owner's exit and zero in-range liquidity.
///         Skipped unless ALCHEMY_RPC_URL is set (the `robinhood` alias in foundry.toml).
contract LaneCurrencyForkTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @dev The block every fork run of this lane reads (foundry.toml's fork_block_number) and its l1BlockNumber:
    ///      what `block.number` returns inside a contract on Nitro.
    uint256 internal constant FORK_BLOCK = 74_062_645;
    uint256 internal constant FORK_L1_BLOCK = 26_069_826;
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    Currency internal constant CUSDG = Currency.wrap(USDG);
    Currency internal constant CWETH = Currency.wrap(WETH);
    bool internal live;

    RouteExecutor internal rx;
    ScriptedExecutor internal sx;
    PoolKey internal a;
    PoolKey internal b;
    PoolKey internal c;
    bytes32 internal family;
    HookrToken internal subject;

    function setUp() public {
        if (bytes(vm.envOr("ALCHEMY_RPC_URL", string(""))).length == 0) return;
        vm.createSelectFork("robinhood", FORK_BLOCK);
        vm.roll(FORK_L1_BLOCK);
        // 0x64 on a fork holds the Nitro placeholder 0xfe, which reverts: ArbSys stands in with the header pair
        // measured on chain, L2 FORK_BLOCK at parent FORK_L1_BLOCK.
        ArbSysKit.install(vm, FORK_BLOCK, FORK_L1_BLOCK);
        _setUpLaneOn(PM);
        assertTrue(address(100).code.length > 1 && ArbSysKit.l2() == FORK_BLOCK, "ArbSys answers the fork's L2 height");
        live = true;
        // USDG keeps balances in 64 bits: amounts here stay far below 1.8e19 raw units (USDG has 6 decimals).
        _dealUsdg(address(this), 1e18);
        _catalogQuote(USDG);
        address[5] memory people = [creator, whale, minnow, attacker, address(mover)];
        for (uint256 i; i < people.length; ++i) {
            IERC20(USDG).transfer(people[i], 1e17);
            vm.startPrank(people[i]);
            IERC20(USDG).approve(address(router), type(uint256).max);
            IERC20(USDG).approve(address(launcher), type(uint256).max);
            vm.stopPrank();
        }
        IERC20(USDG).approve(address(seeder), type(uint256).max);
        // The ETH / USDG connector, hookless.
        c = PoolKey(ETH, CUSDG, 7777, 60, IHooks(address(0)));
        (uint160 cp,,,) = manager.getSlot0(c.toId());
        require(cp == 0, "connector key taken");
        seeder.seed{value: 1e17}(c, SQRT_ONE, -60_000, 60_000, 1e16);
    }

    /// @dev Writes `amount` into the USDG balance slot of `to` that `balanceOf` reads (USDG is a proxy that stdStorage
    ///      cannot write through).
    function _dealUsdg(address to, uint256 amount) internal {
        vm.record();
        IERC20(USDG).balanceOf(to);
        (bytes32[] memory reads,) = vm.accesses(USDG);
        // The last slot read is the balance; the proxy's implementation slot is read first.
        for (uint256 i = reads.length; i > 0; --i) {
            bytes32 prev = vm.load(USDG, reads[i - 1]);
            vm.store(USDG, reads[i - 1], bytes32(amount));
            try IERC20(USDG).balanceOf(to) returns (uint256 v) {
                if (v == amount) return;
            } catch {}
            vm.store(USDG, reads[i - 1], prev);
        }
        revert("no USDG balance slot");
    }

    /// @dev A family of A (ETH / S) and B (USDG / S, King of the Pool with the trader leg) under executor `ex`.
    function _family(address ex) internal {
        _openLane(ex, 3_000_000);
        subject = _newSubject();
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _laneMember(ETH, _laneRules(false), _recaptureOnlyRc());
        members[1] = _laneMember(CUSDG, _laneRules(true), _kothRc());
        members[1].liquidity = 1e16;
        (members[1].amount0Max, members[1].amount1Max) = (5e16, 5e16);
        PoolKey[] memory keys;
        (family, keys) = _launchAs(creator, subject, members);
        (a, b) = (keys[0], keys[1]);
        _nextBlock();
    }

    function _route(RouteExecutor ex, Currency start) internal {
        RouteExecutor.Hop[] memory hops = new RouteExecutor.Hop[](3);
        Currency s = Currency.wrap(address(subject));
        if (start == ETH) {
            // ETH -> S on A, S -> USDG on B (against a buy on B), USDG -> ETH on C.
            hops[0] = RouteExecutor.Hop(a, a.currency0 == ETH);
            hops[1] = RouteExecutor.Hop(b, b.currency0 == s);
            hops[2] = RouteExecutor.Hop(c, c.currency0 == CUSDG);
        } else {
            // USDG -> ETH on C, ETH -> S on A, S -> USDG on B.
            hops[0] = RouteExecutor.Hop(c, c.currency0 == CUSDG);
            hops[1] = RouteExecutor.Hop(a, a.currency0 == ETH);
            hops[2] = RouteExecutor.Hop(b, b.currency0 == s);
        }
        ex.setRoute(b, hops, start, 1e13);
    }

    function _routeFamily(Currency start) internal {
        rx = new RouteExecutor(manager, address(root), partner);
        assertEq(rx.KEEP_BPS(), PARTNER_BPS, "the executor keeps the share the lane pins");
        _family(address(rx));
        _route(rx, start);
    }

    function _scriptedFamily() internal {
        sx = new ScriptedExecutor(manager);
        vm.deal(address(sx), 1e28);
        sx.setRoot(address(root));
        _family(address(sx));
        IERC20(USDG).transfer(address(sx), 1e17);
        subject.transfer(address(sx), 1e26);
        vm.prank(address(sx));
        IWETH9(WETH).deposit{value: 1e24}();
    }

    function test_fork_theGenesisSettlementSetHoldsEthWethAndUsdg() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        assertGt(WETH.code.length, 0);
        assertGt(USDG.code.length, 0);
        address[] memory set = registry.settlementCurrencies();
        assertEq(set.length, 3);
        assertEq(set[0], address(0));
        assertEq(set[1], WETH);
        assertEq(set[2], USDG);
    }

    /// A buy on the USDG-quoted member opens a gap the executor closes through A and the ETH / USDG connector, making
    /// its profit in ETH: it pushes ETH on B. The protocol takes its share in ETH; the trader leg and the pot are
    /// USDG units, so they join the LP share, which is not one of B's currencies and goes to the owner's ETH accrual.
    function test_fork_anEthPushOnAUsdgPoolThroughATriangle() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        _routeFamily(ETH);
        (,,, uint128 pot0) = _hill(b);
        uint256 pro0 = rules.claimable(ETH, protocol);
        vm.recordLogs();
        _buy(b, CUSDG, whale, 1e15);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertGt(o.pushedAfter, 0, "the after-phase pushed ETH");
        uint256 pushed = o.pushedAfter + o.pushedBefore;
        uint256 pro = rules.claimable(ETH, protocol) - pro0;
        assertEq(_recap().poolAccrued(b.toId(), ETH) + pro, pushed, "protocol cut, and the rest to the ETH accrual");
        assertEq(pro, _cut(o.profitBefore, o.pushedBefore) + _cut(o.profitAfter, o.pushedAfter), "25% of each profit");
        (,,, uint128 pot1) = _hill(b);
        assertEq(pot1, pot0, "no pot from an ETH push");
        assertEq(rules.claimable(CUSDG, whale), 0, "no trader leg outside the quote");
        assertEq(manager.balanceOf(address(root), ETH.toId()), 0);
        assertTrue(rules.accountingInvariant(ETH));
        console2.log("ETH pushed on the USDG pool, protocol cut", pushed, pro);
        vm.prank(creator);
        assertEq(launcher.claimRecapture(family, 1, creator), 1);
    }

    /// The same cycle started in USDG pushes the quote: the trader leg goes to the buyer and the pot fills.
    function test_fork_aUsdgPushPaysTheTraderAndThePot() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        _routeFamily(CUSDG);
        (,,, uint128 pot0) = _hill(b);
        vm.recordLogs();
        _buy(b, CUSDG, whale, 1e15);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        Splits memory t = _splits(logs);
        assertGt(o.pushedAfter, 0);
        assertEq(t.reported, o.profitBefore + o.profitAfter, "the splits report the root's profits");
        assertGt(t.trader, 0, "the trader leg");
        assertEq(rules.claimable(CUSDG, whale), t.trader);
        (,,, uint128 pot1) = _hill(b);
        assertEq(uint256(pot1 - pot0), t.pot);
        assertGt(t.pot, 0, "King of the Pool pot");
        assertEq(_accrued(b), t.lp, "the LP share pending");
        assertTrue(rules.accountingInvariant(CUSDG));
        // Released to B's in-range liquidity from the next block, all of it a full release period later.
        vm.prank(creator);
        launcher.withdraw(family, 1, 0, 0, 0, creator, vm.getBlockTimestamp());
        ArbSysKit.nextParent(vm, RELEASE_PARENTS);
        _buy(b, CUSDG, minnow, 1e9);
        (uint256 d0, uint256 d1,,,) = _recap().pendingDonation(b.toId());
        assertEq(d0 + d1, 0, "the first lane swap a full release period later donated it");
    }

    /// A WETH push (settlement set) on the ETH-quoted member: the owner's WETH accrual.
    function test_fork_aWethPush() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        _scriptedFamily();
        sx.setPushCurrency(CWETH);
        sx.set(ScriptedExecutor.Mode.PUSH, 1e18);
        vm.recordLogs();
        _buy(a, ETH, whale, 1e20);
        assertEq(_outcome(vm.getRecordedLogs()).succeeded, 2);
        uint256 pro = _cut(_profitOf(1e18), 1e18);
        assertEq(rules.claimable(CWETH, protocol), 2 * pro);
        assertEq(_recap().poolAccrued(a.toId(), CWETH), 2 * (1e18 - pro));
        assertTrue(rules.accountingInvariant(CWETH));
        vm.prank(creator);
        launcher.claimRecapture(family, 0, creator);
        vm.prank(creator);
        rules.claim(CWETH);
        assertEq(IERC20(WETH).balanceOf(creator), 2 * (1e18 - pro), "paid in WETH");
    }

    /// A push in the subject on the USDG member: no pot, no trader leg, donated in the subject.
    function test_fork_aSubjectPush() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        _scriptedFamily();
        Currency s = Currency.wrap(address(subject));
        sx.setPushCurrency(s);
        sx.set(ScriptedExecutor.Mode.PUSH, 1e18);
        (,,, uint128 pot0) = _hill(b);
        _buy(b, CUSDG, whale, 1e14);
        (,,, uint128 pot1) = _hill(b);
        assertEq(pot1, pot0);
        (,, uint256 f0, uint256 f1,) = _recap().pendingDonation(b.toId());
        uint256 pro = _cut(_profitOf(1e18), 1e18);
        assertEq(f0 + f1, 2 * (1e18 - pro), "pending in the subject");
        assertTrue(rules.accountingInvariant(s));
    }

    /// A stray mint in USDG reverts the arb recapture; the swap goes on and nothing stays at the root.
    function test_fork_aStrayMint() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        _scriptedFamily();
        sx.setPushCurrency(CUSDG);
        sx.set(ScriptedExecutor.Mode.STRAY_MINT, 1e15);
        vm.recordLogs();
        _buy(a, ETH, whale, 1e20);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.failed, 2);
        assertEq(o.lastReason, IHookrLaneEvents.LaneStrayClaims.selector);
        assertEq(manager.balanceOf(address(root), CUSDG.toId()), 0);
    }

    /// A USDG push then a WETH push in one frame: each lands and splits in its own currency, nothing stays at the
    /// root.
    function test_fork_aMixedCurrencyFrame() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        _scriptedFamily();
        sx.setPushCurrency(CWETH);
        sx.set(ScriptedExecutor.Mode.MIXED, 1e15);
        uint256 pUsdg = rules.claimable(CUSDG, protocol);
        uint256 pWeth = rules.claimable(CWETH, protocol);
        vm.recordLogs();
        _buy(b, CUSDG, whale, 1e14);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        assertEq(o.failed, 0);
        assertEq(o.succeeded, 4, "USDG and WETH in each phase");
        uint256 pro = _cut(_profitOf(1e15), 1e15);
        (uint256 splitUsdg, uint256 splitWeth) = (0, 0);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rules) || logs[i].topics[0] != IHookrRecaptureEvents.RecaptureSplit.selector)
            {
                continue;
            }
            (,,, uint256 cut, Currency c, uint256 reported) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, Currency, uint256));
            assertEq(reported, _profitOf(1e15), "each push's own profit");
            if (c == CUSDG) splitUsdg += cut;
            else if (c == CWETH) splitWeth += cut;
        }
        assertEq(splitUsdg, 2 * pro, "the protocol's cut of each USDG push");
        assertEq(splitWeth, 2 * pro, "and of each WETH push");
        // The USDG claim also carries the buy's own protocol fee, in the pool's quote.
        assertGe(rules.claimable(CUSDG, protocol) - pUsdg, 2 * pro);
        assertEq(rules.claimable(CWETH, protocol) - pWeth, 2 * pro);
        assertEq(manager.balanceOf(address(root), CUSDG.toId()), 0);
        assertEq(manager.balanceOf(address(root), CWETH.toId()), 0);
        assertTrue(rules.accountingInvariant(CUSDG));
        assertTrue(rules.accountingInvariant(CWETH));
    }

    /// The sweep inside a swap is refused; outside it moves stray USDG claims to the protocol recipient.
    function test_fork_theSweepInsideAndOutsideASwap() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        _scriptedFamily();
        sx.set(ScriptedExecutor.Mode.SWEEP_INSIDE, 1e15);
        _buy(b, CUSDG, whale, 1e14);
        assertEq(bytes4(sx.lastSweepError()), IHookrRootEvents.ReentrantCallback.selector);
        // A stray mint outside any swap: USDG claims minted to the root and never pushed.
        StrayMinter m = new StrayMinter(manager);
        IERC20(USDG).transfer(address(m), 5e14);
        m.mintTo(address(root), CUSDG, 5e14);
        uint256 before = rules.claimable(CUSDG, protocol);
        vm.prank(attacker);
        assertEq(IHookrLaneRoot(address(root)).sweepClaims(b.toId(), CUSDG), 5e14);
        assertEq(rules.claimable(CUSDG, protocol) - before, 5e14);
        assertEq(manager.balanceOf(address(root), CUSDG.toId()), 0);
        assertTrue(rules.accountingInvariant(CUSDG));
    }

    /// The owner exits B in the block of an arb recapture: the pending share finds no liquidity at the next block's add
    /// and becomes the owner's accrual, which a zero withdraw on the empty member moves. With zero in-range liquidity
    /// at accrual time the share goes to the owner at once.
    function test_fork_theOwnerExitAndZeroInRangeLiquidity() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        _scriptedFamily();
        sx.set(ScriptedExecutor.Mode.PUSH, 1e15);
        _buy(b, CUSDG, whale, 1e14);
        uint256 leg = _accrued(b);
        assertGt(leg, 0);
        Actor lp = _pendingToOwner(b, family, 1, creator);
        assertEq(_ownerAccrued(b), leg, "the pending share became the owner's accrual");
        vm.prank(creator);
        launcher.withdraw(family, 1, 0, 0, 0, creator, vm.getBlockTimestamp());
        assertEq(rules.claimable(CUSDG, creator), leg, "moved by a zero withdraw on the empty member");
        // lp's liquidity sits out of range: a push now finds no in-range liquidity.
        lp.modify(b, -600, 600, -1e18);
        lp.modify(b, 800_040, 800_100, 1e18);
        _nextBlock();
        vm.recordLogs();
        // A small unauthenticated sell (a buy with nothing to fill would leave an unauthenticated refund).
        bool sell0 = b.currency0 == Currency.wrap(address(subject));
        lp.directSwap(b, sell0, -1e6, sell0 ? SQRT_ONE / 2 : SQRT_ONE * 2);
        assertGt(_outcome(vm.getRecordedLogs()).succeeded, 0);
        (uint256 d0, uint256 d1, uint256 f0, uint256 f1,) = _recap().pendingDonation(b.toId());
        assertEq(d0 + d1 + f0 + f1, 0, "nothing pending");
        assertGt(_ownerAccrued(b), 0, "straight to the owner");
    }
}

/// @notice Mints PoolManager claims of an ERC-20 to any account outside a swap.
contract StrayMinter {
    using CurrencyLibrary for Currency;

    IPoolManager internal immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function mintTo(address to, Currency c, uint256 amount) external {
        manager.unlock(abi.encode(to, c, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address to, Currency c, uint256 amount) = abi.decode(data, (address, Currency, uint256));
        manager.sync(c);
        IERC20(Currency.unwrap(c)).transfer(address(manager), amount);
        manager.settle();
        manager.mint(to, c.toId(), amount);
        return "";
    }
}
