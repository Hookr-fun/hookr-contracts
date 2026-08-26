// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {LeverageHook} from "../src/LeverageHook.sol";
import {LeverageFactory} from "../src/LeverageFactory.sol";
import {LeverageMarket} from "../src/LeverageMarket.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {LeverageOracleLib} from "../src/libraries/LeverageOracleLib.sol";
import {ILeverage} from "../src/interfaces/ILeverage.sol";
import {HookMiner} from "./utils/HookMiner.sol";

interface IERC20I {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Drives the market with random-ish traffic so the invariants below are tested against
///         states nobody thought to write a directed test for.
contract Handler is Test {
    LeverageMarket public market;
    LeverageRouter public router;
    IERC20I public token;
    PoolKey public key;

    address[] public actors;
    address[] public traders;
    uint256 public ghostDeposited;
    uint256 public ghostRedeemed;

    // Success counters. Every action below is wrapped in try/catch so the fuzzer can explore
    // freely — which also means a contract that reverts everything looks identical to one
    // that works. `afterInvariant` gates on these so a starved run fails instead of passing.
    uint256 public opens;
    uint256 public closes;
    uint256 public liquidations;
    uint256 public deposits;

    uint160 constant MIN_LIMIT = 4295128739 + 1;
    uint160 constant MAX_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;
    uint256 constant WAD = 1e18;

    constructor(LeverageMarket m, LeverageRouter r, IERC20I t, PoolKey memory k) {
        market = m;
        router = r;
        token = t;
        key = k;
        for (uint256 i = 0; i < 4; i++) {
            address a = address(uint160(0x1000 + i));
            actors.push(a);
            vm.deal(a, 10_000 ether);
        }
        for (uint256 i = 0; i < 3; i++) {
            address a = address(uint160(0x2000 + i));
            traders.push(a);
            vm.deal(a, 10_000 ether);
        }
    }

    receive() external payable {}

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _trader(uint256 seed) internal view returns (address) {
        return traders[seed % traders.length];
    }

    function deposit(uint256 seed, uint256 amount) public {
        amount = bound(amount, 0.01 ether, 100 ether);
        address a = _actor(seed);
        vm.deal(a, amount + 1 ether);
        vm.prank(a);
        try market.deposit{value: amount}() {
            ghostDeposited += amount;
            deposits++;
        } catch {}
    }

    function redeem(uint256 seed, uint256 pct) public {
        address a = _actor(seed);
        uint256 bal = market.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = (bal * bound(pct, 1, 100)) / 100;
        vm.prank(a);
        try market.redeem(shares) returns (uint256 paid) {
            ghostRedeemed += paid;
        } catch {}
    }

    function open(uint256 seed, uint256 equity, uint256 lev) public {
        address t = _trader(seed);

        // A trader may hold only one position now, so make room instead of letting the open
        // revert into the catch below. Without this every open after a trader's first is a
        // silent no-op and the invariants stop exercising the credit path altogether —
        // green across a hundred thousand calls that never reached the code.
        (uint128 held,) = market.positions(t);
        if (held != 0) {
            vm.prank(t);
            try market.closePosition(0) {}
            catch {
                return;
            }
        }

        equity = bound(equity, 0.01 ether, 20 ether);
        uint256 leverage = bound(lev, WAD, 3 * WAD);
        vm.deal(t, equity + 1 ether);
        vm.prank(t);
        try market.openPosition{value: equity}(leverage, 0) {
            opens++;
        } catch {}
    }

    function close(uint256 seed) public {
        address t = _trader(seed);
        vm.prank(t);
        try market.closePosition(0) {
            closes++;
        } catch {}
    }

    function liquidate(uint256 seed) public {
        address t = _trader(seed);
        vm.prank(address(0xBEEF));
        try market.liquidate(t, 0) {
            liquidations++;
        } catch {}
    }

    function swap(uint256 seed, uint256 amount, bool buy) public {
        amount = bound(amount, 0.01 ether, 50 ether);
        address a = _actor(seed);
        vm.deal(a, amount + 1 ether);
        if (buy) {
            vm.prank(a);
            try router.swap{value: amount}(
                LeverageRouter.SwapArgs({
                    key: key,
                    zeroForOne: true,
                    amountSpecified: -int256(amount),
                    sqrtPriceLimitX96: MIN_LIMIT,
                    amountBound: 0,
                    recipient: a,
                    deadline: type(uint256).max
                })
            ) {}
                catch {}
        } else {
            uint256 bal = token.balanceOf(a);
            if (bal == 0) return;
            vm.prank(a);
            token.approve(address(router), type(uint256).max);
            vm.prank(a);
            try router.swap(
                LeverageRouter.SwapArgs({
                    key: key,
                    zeroForOne: false,
                    amountSpecified: -int256(bal / 2),
                    sqrtPriceLimitX96: MAX_LIMIT,
                    amountBound: 0,
                    recipient: a,
                    deadline: type(uint256).max
                })
            ) {}
                catch {}
        }
    }

    function warp(uint256 secs) public {
        vm.warp(block.timestamp + bound(secs, 1, 30 days));
        try market.accrue() {} catch {}
        _rewarm();
    }

    /// Push the observation ring back over its window. Without this the first warp turns
    /// `isProtected` on permanently and every deposit and open after it reverts — which is
    /// exactly how this suite came to run 128,000 calls against an empty book.
    function _rewarm() internal {
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 24; i++) {
            t += 46;
            vm.warp(t);
            vm.deal(address(this), 1_000 ether);
            try router.swap{value: 0.01 ether}(
                LeverageRouter.SwapArgs({
                    key: key,
                    zeroForOne: true,
                    amountSpecified: -int256(0.01 ether),
                    sqrtPriceLimitX96: MIN_LIMIT,
                    amountBound: 0,
                    recipient: address(this),
                    deadline: type(uint256).max
                })
            ) {}
                catch {}
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function traderCount() external view returns (uint256) {
        return traders.length;
    }
}

/// @notice Properties that must hold no matter what order anything happens in.
///
///         Directed tests prove the paths someone thought of. These prove the ledger cannot be
///         put into a state that contradicts itself — which is the failure mode a credit
///         system actually dies of.
contract LeverageInvariantTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant WAD = 1e18;

    IPoolManager manager;
    LeverageHook hook;
    LeverageFactory factory;
    LeverageRouter router;
    LeverageMarket market;
    IERC20I token;
    PoolKey key;
    PoolId id;
    Handler handler;

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        router = new LeverageRouter(manager);

        uint160 flags = uint160((1 << 13) | (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6));
        bytes memory creation = abi.encodePacked(type(LeverageHook).creationCode, abi.encode(manager, address(this)));
        (, bytes32 salt) = HookMiner.find(address(this), flags, creation);
        hook = new LeverageHook{salt: salt}(manager, address(this));
        factory = new LeverageFactory(manager, hook);
        hook.setFactory(address(factory));

        ILeverage.MarketConfig memory cfg = ILeverage.MarketConfig({
            ltvBps: 6_000,
            liqThresholdBps: 8_000,
            liqBonusBps: 500,
            reserveFactorBps: 1_000,
            kinkWad: uint64(WAD * 8 / 10),
            maxUtilisationWad: uint64(WAD * 9 / 10),
            protocolCapWei: 1_000 ether,
            minPoolQuoteWei: 0
        });

        vm.deal(address(this), 100_000 ether);
        (address tokenAddr, address marketAddr) = factory.createMarket{value: 100 ether}(
            "Node", "NODE", "", "", 1_000_000 ether, SQRT_PRICE_1_1, 50 ether, cfg
        );
        token = IERC20I(tokenAddr);
        market = LeverageMarket(payable(marketAddr));
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(tokenAddr),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();

        // Warm the observation ring BEFORE handing the market to the fuzzer. Without this
        // `isProtected` is true for most of the run, deposit/openPosition revert `Protected`,
        // and the invariants are checked against an empty book: measured over 500 sequenced
        // calls, one open succeeded and the liquidation path never ran once. The suite was
        // green across 128,000 calls because it was not reaching the code.
        _warmRing();

        // Seed real LP cash. `openPosition` can only lend what the market holds, so with an
        // empty book every leveraged open reverts and the credit path is never reached.
        market.deposit{value: 200 ether}();

        handler = new Handler(market, router, token, key);
        // Seed the handler's actors with tokens so sells are possible.
        token.transfer(address(handler), token.balanceOf(address(this)) / 2);

        targetContract(address(handler));
    }

    function _warmRing() internal {
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < LeverageOracleLib.MAX_WALK + 3; i++) {
            t += LeverageOracleLib.MIN_SPACING_SEC + 1;
            vm.warp(t);
            vm.deal(address(this), 10_000 ether);
            router.swap{value: 0.05 ether}(
                LeverageRouter.SwapArgs({
                    key: key,
                    zeroForOne: true,
                    amountSpecified: -int256(0.05 ether),
                    sqrtPriceLimitX96: 4295128739 + 1,
                    amountBound: 0,
                    recipient: address(this),
                    deadline: type(uint256).max
                })
            );
        }
    }

    /// The suite must reach the code it claims to cover. These are not properties of the
    /// market; they are properties of the test, and they exist because the invariants above
    /// passed 128,000 calls against a book that was almost always empty.
    function afterInvariant() public view {
        assertGt(handler.deposits(), 0, "no deposit ever succeeded");
        assertGt(handler.opens(), 0, "no position was ever opened");
    }

    // ------------------------------------------------------------------ invariants

    /// The ledger's aggregate must equal the sum of its parts. If these drift, every number
    /// downstream — health, capacity, NAV — is quoting a book that does not exist.
    function invariant_collateralMatchesPositions() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.traderCount(); i++) {
            (uint128 c,) = market.positions(handler.traders(i));
            sum += c;
        }
        assertEq(market.collateralHeld(), sum, "collateralHeld drifted from the positions");
    }

    function invariant_debtMatchesPositions() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.traderCount(); i++) {
            (, uint128 d) = market.positions(handler.traders(i));
            sum += d;
        }
        assertEq(market.totalScaledDebt(), sum, "totalScaledDebt drifted from the positions");
    }

    /// The bucketed credit book must stay in lockstep with `positions`. Five call sites mutate
    /// a position, and a book that misses one drifts SILENTLY — no revert, just a mark that is
    /// quietly wrong, which is the same class of defect the book was added to fix. Both sides
    /// are maintained aggregates, so this is O(1) and a missed site fails on the first test
    /// that exercises it.
    function invariant_bookMatchesTotalScaledDebt() public view {
        assertEq(market.bookedScaled(), market.totalScaledDebt(), "credit book drifted from totalScaledDebt");
    }

    /// Collateral the market says it holds must actually be there. Anything less means a
    /// position cannot be closed or liquidated at all.
    function invariant_collateralIsActuallyHeld() public view {
        assertGe(token.balanceOf(address(market)), market.collateralHeld(), "market owes more collateral than it holds");
    }

    /// A position with debt must have collateral behind it. Debt with nothing pledged is bad
    /// debt that has not been written down.
    function invariant_noNakedDebt() public view {
        for (uint256 i = 0; i < handler.traderCount(); i++) {
            (uint128 c, uint128 d) = market.positions(handler.traders(i));
            if (d > 0) assertGt(c, 0, "debt with no collateral");
        }
    }

    /// The borrow index only moves forward. A backward step would retroactively forgive debt.
    uint256 private lastIndex;

    function invariant_borrowIndexNeverDecreases() public {
        uint256 idx = market.borrowIndex();
        assertGe(idx, lastIndex == 0 ? WAD : lastIndex, "borrow index went backwards");
        lastIndex = idx;
    }

    /// Shares outstanding and the share ledger must agree.
    function invariant_shareSupplyMatchesHolders() public view {
        // The seed deposit in setUp is held by this contract, not by a handler actor, so it
        // has to be counted or the sum is short by exactly the seed.
        uint256 sum = market.balanceOf(address(this));
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += market.balanceOf(handler.actors(i));
        }
        assertEq(market.totalSupply(), sum, "share supply drifted from holders");
    }

    /// Shares are never left backed by nothing.
    ///
    /// This replaces an aggregate "redemptions <= deposits" cap, which looked like a solvency
    /// property and was not one: the market earns swap fees on its own position, so paying out
    /// more than was deposited is correct rather than evidence of a leak. The real failure is
    /// the one the audit found — shares surviving against a market that cannot pay them, which
    /// is what an unreachable pool position produced.
    function invariant_sharesAreNeverBackedByNothing() public view {
        if (market.totalSupply() == 0) return;
        // `idle + poolQuote + totalDebt > 0` cannot fail in practice: the seeded position is
        // never fully removable (`_unwindForRedemption` caps at liq/4). navQuote CAN reach
        // zero — it clamps at `assets > reserveQuote ? assets - reserveQuote : 0` — so it is
        // the quantity that actually expresses "backed by nothing".
        assertGt(market.navQuote(false), 0, "shares outstanding against a market worth nothing");
    }

    /// The market must never hold less ETH than it has promised to hold back for the credit
    /// book — the reserve is the LPs' first-loss cover and cannot be spent by a withdrawal.
    /// Was `assertGe(market.idleQuote(), 0)` — unfalsifiable on a uint256, so this invariant
    /// could never have failed. The property actually worth holding is that the market's cash
    /// covers what it has already promised away: the reserve is the LPs' first-loss cover and
    /// the claimable balances are other people's money.
    function invariant_reserveIsNotPaidOut() public view {
        uint256 owed = market.reserveQuote();
        if (owed == 0) return;
        (uint256 poolQuote,) = market.positionReserves();
        assertGe(market.idleQuote() + poolQuote, owed, "market cannot cover the reserve it has booked");
    }
}
