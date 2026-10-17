// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {HookrDrawdownBurn} from "../src/HookrDrawdownBurn.sol";

// ---------------------------------------------------------------------------------------------------------------------
// The live Hookr 1 surface this run touches, copied by ABI from hookr-1/src (HookrTypes, IHookrLauncher) and
// hookr-1/hook-blocks/directional-tax (HookrDirectionalTax.Leg/Config/Terms) on hookr-contracts main.
// ---------------------------------------------------------------------------------------------------------------------

struct Caps {
    uint24 maxLpFeePips;
    uint24 maxQuoteTakePips;
    uint16 maxSubjectTakeBps;
}

struct PoolConfig {
    Currency subject;
    Currency quote;
    address rules;
    address advisory;
    address liquidityOwner;
    uint24 baseLpFeePips;
    Caps caps;
    uint32 rulesGasLimit;
    uint32 advisoryGasLimit;
    uint8 advisoryPhases;
    bool advisoryFailOpen;
    bytes32 policyId;
}

struct RulesConfig {
    uint40 guardEndBlock;
    uint24 maxFeePips;
    uint24 snipeTaxPips;
    uint24 snipeFloorPips;
    uint16 snipeDecaySeconds;
    uint16 dynamicFeeSens;
    uint16 burnBps;
    uint16 lpBps;
    uint16 potBps;
    uint16 royaltyBps;
    uint16 protocolShareBps;
    uint32 potEveryNBuys;
    uint128 maxBuyQuoteAmount;
    uint128 potMinBuyQuote;
    address royaltyTo;
    address integrator;
}

struct RecaptureConfig {
    bool on;
    uint16 traderBps;
    uint16 lpBps;
    uint32 period;
    uint16 maxPrizeBps;
    uint16 potReleaseBps;
    uint128 minBuyQuote;
    uint32 releaseBlocks;
}

interface ILauncher {
    struct Token {
        address existing;
        string name;
        string symbol;
        uint256 supply;
        bytes32 salt;
    }

    struct Member {
        Currency quote;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        PoolConfig config;
        RulesConfig rules;
        RecaptureConfig recapture;
    }

    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    function predictToken(address creator, Token calldata token) external view returns (address);
    function position(bytes32 familyId, uint8 member) external view returns (Position memory);
    function launchAdvised(
        Token calldata token,
        address rootAddress,
        Member[] calldata members,
        bytes[] calldata advisoryConfigs,
        uint256 deadline
    ) external payable returns (bytes32 familyId, address subject);
}

interface IDirectionalTax {
    struct Leg {
        uint24 taxPips;
        bytes32 routeId;
        address assetRecipient;
        address recoveryRecipient;
        uint32 staleRecoveryDelay;
    }

    struct Config {
        Leg buy;
        Leg sell;
    }

    struct Terms {
        address buyQueue;
        uint24 buyTaxPips;
        bool bound;
        bool tiered;
        bool decaying;
        address sellQueue;
        uint24 sellTaxPips;
    }

    function terms(address root, PoolId id) external view returns (Terms memory);
}

interface ITaxQueueView {
    function pending() external view returns (uint256);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

/// @dev ArbSys stand-in at 0x64, as the release suites install it: arbBlockNumber() = l2Base + 120 x parent blocks.
contract ArbSysMock {
    function arbBlockNumber() external view returns (uint256) {
        uint256 w;
        assembly {
            w := sload(0)
        }
        uint256 l1Base = uint64(w >> 128);
        return uint128(w) + (block.number > l1Base ? (block.number - l1Base) * 120 : 0);
    }
}

/// @dev A plain trader: exact-input swaps straight on the PoolManager with empty hookData, as any contract may.
contract Trader is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager internal immutable manager;
    PoolKey internal key;

    constructor(IPoolManager m) {
        manager = m;
    }

    function setKey(PoolKey memory k) external {
        key = k;
    }

    /// @dev zeroForOne = true sells currency0 (ETH here) for currency1 (the token): a buy.
    function swap(bool zeroForOne, uint256 amountIn, uint160 limit)
        external
        payable
        returns (uint256 inUsed, uint256 out)
    {
        (inUsed, out) = abi.decode(manager.unlock(abi.encode(zeroForOne, amountIn, limit)), (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool zeroForOne, uint256 amountIn, uint160 limit) = abi.decode(data, (bool, uint256, uint160));
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = manager.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        int128 din = zeroForOne ? d.amount0() : d.amount1();
        int128 dout = zeroForOne ? d.amount1() : d.amount0();
        uint256 paid = uint256(uint128(-din));
        uint256 got = uint256(uint128(dout));
        if (cin.isAddressZero()) {
            manager.settle{value: paid}();
        } else {
            manager.sync(cin);
            cin.transfer(address(manager), paid);
            manager.settle();
        }
        manager.take(cout, address(this), got);
        return abi.encode(paid, got);
    }

    receive() external payable {}
}

/// @title DrawdownBurnFork
/// @notice The engine on a real Hookr 1 pool on Robinhood Chain 4663 at a pinned block: a new token launched through
///         the live Launcher on the live root, with Auto Burn 3.3% on buys (Rules burnBps 330) and Tax + Conversion
///         3.3% on sells paying the engine. Trades push the price up, down and through the wall; the engine collects
///         the tax from the live queue, buys back through the live root and burns. Then the attacks with real fees.
/// @dev    Runs only on a 4663 fork; the RPC comes from the environment (FOUNDRY_ETH_RPC_URL), never a command line:
///         `FOUNDRY_ETH_RPC_URL=... FOUNDRY_FORK_BLOCK_NUMBER=91088307 forge test --root labs --match-contract Fork`.
contract DrawdownBurnFork is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Pin: L2 block 91,088,307, parent (L1) block 26,213,644, read 2026-10-17 through Alchemy.
    uint256 internal constant L2_BLOCK = 91_088_307;
    uint256 internal constant L1_BLOCK = 26_213_644;

    IPoolManager internal constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    ILauncher internal constant LAUNCHER = ILauncher(0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4);
    address internal constant ROOT = 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc;
    address internal constant RULES = 0x4a71c270b1520F94064268102AebD744b0DE7942;
    IDirectionalTax internal constant TAX = IDirectionalTax(0xE73fAD0d773b9571a7a9d2A1edc01132fF5f1e1F);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Runtime keccaks read from chain at the pin (the first four equal the release manifest's pins).
    bytes32 internal constant LAUNCHER_RUNTIME = 0x96b8c338c38a072ceef8b947ad93d3d7a46d2d7c70189d2b4ee92efb2a5e1d5d;
    bytes32 internal constant ROOT_RUNTIME = 0xd336de325837e60a74cea11d87b5ebd1cc8961911f611f38de0508d23b6e779f;
    bytes32 internal constant RULES_RUNTIME = 0x4b6d50b40981b8082f3ee5a7ebf57e48489f71c94c2a3b94032a1d1a382b515b;
    bytes32 internal constant MANAGER_RUNTIME = 0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    bytes32 internal constant TAX_RUNTIME = 0x6254520c3725b5dca036d52e8adbe1a69a6bf9aae2a1e401a151dcee00e210cd;

    address internal constant CREATOR = address(0xC0FFEE);
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    int24 internal constant SPACING = 60;
    int24 internal constant OPEN_TICK = 177_240; // ~5.0e7 tokens per ETH: a 20 ETH opening valuation
    int24 internal constant RANGE = 60_000;
    uint24 internal constant BASE_FEE = 3000;
    uint16 internal constant AUTO_BURN_BPS = 330;
    uint24 internal constant SELL_TAX_PIPS = 33_000;

    PoolKey internal key;
    PoolId internal id;
    address internal token;
    HookrDrawdownBurn internal engine;
    Trader internal trader;
    Trader internal attacker;
    uint128 internal launchLiquidity;

    bool internal onFork;

    function setUp() public {
        onFork = block.chainid == 4663;
        if (!onFork) return;
        require(block.number == L2_BLOCK, "pin: FOUNDRY_FORK_BLOCK_NUMBER=91088307");
        assertEq(address(LAUNCHER).codehash, LAUNCHER_RUNTIME);
        assertEq(ROOT.codehash, ROOT_RUNTIME);
        assertEq(RULES.codehash, RULES_RUNTIME);
        assertEq(address(MANAGER).codehash, MANAGER_RUNTIME);
        assertEq(address(TAX).codehash, TAX_RUNTIME);
        // Inside a contract on Robinhood Chain, block.number is the parent (L1) height.
        vm.roll(L1_BLOCK);
        vm.etch(address(100), type(ArbSysMock).runtimeCode);
        vm.store(address(100), bytes32(0), bytes32(L2_BLOCK | (L1_BLOCK << 128)));

        trader = new Trader(MANAGER);
        attacker = new Trader(MANAGER);
        vm.deal(address(trader), 1000 ether);
        vm.deal(address(attacker), 1000 ether);

        // The key the Launcher will open, read from a launch that is then rolled back.
        uint256 snap = vm.snapshotState();
        _launch(address(0xBEEF));
        PoolKey memory k = key;
        vm.revertToState(snap);

        engine = new HookrDrawdownBurn(_config(k));
        assertEq(engine.count(), 0, "deployed before its pool");
        _launch(address(engine));
        assertEq(keccak256(abi.encode(key)), keccak256(abi.encode(k)));
        engine.start();
        trader.setKey(key);
        attacker.setKey(key);
        // Sellers' inventory: tokens held from before this run (a storage write on the token's balance).
        deal(token, address(trader), 300_000_000e18);
    }

    receive() external payable {}

    function _config(PoolKey memory k) internal view returns (HookrDrawdownBurn.Config memory c) {
        c.manager = MANAGER;
        c.key = k;
        c.subjectIsCurrency0 = false; // native ETH sorts first
        c.taxAdvisory = address(TAX);
        c.checkpointInterval = 300;
        c.maxMoveTicks = 500;
        c.minLiquidity = 1e18;
        c.athWindow = 3600;
        c.athMinCheckpoints = 6;
        c.measure = HookrDrawdownBurn.Reference.PRICE;
        c.tierEdgesBps = [uint16(2000), 4000, 6000];
        c.tierBurnBps = [uint16(0), 2500, 5000, 7500, 10_000];
        c.refWindow = 900;
        c.spendCap = 0.05 ether;
        c.refillSeconds = 12;
        c.maxSlippageBps = 300;
        c.wall = HookrDrawdownBurn.Wall.RESERVE;
        c.wallOffsetBps = 6000;
        c.epochLength = 1 days;
        c.deadBandBps = 100;
        c.tipBps = 10;
    }

    function _launch(address taxRecipient) internal {
        ILauncher.Token memory t = ILauncher.Token(address(0), "RHUB stand-in", "RHUBX", SUPPLY, keccak256("drawdown"));
        address predicted = LAUNCHER.predictToken(CREATOR, t);
        require(predicted > address(0), "token sorts after ETH");
        int24 lower = -OPEN_TICK - RANGE; // the token is currency1: its liquidity sits under the opening tick
        int24 upper = -OPEN_TICK;
        // Pool tick = log(token per ETH): opening at +OPEN_TICK, token-only range below it.
        lower = OPEN_TICK - RANGE;
        upper = OPEN_TICK;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), SUPPLY
        ) - 1;
        launchLiquidity = liquidity;

        ILauncher.Member[] memory m = new ILauncher.Member[](1);
        m[0].quote = Currency.wrap(address(0));
        m[0].tickSpacing = SPACING;
        m[0].sqrtPriceX96 = TickMath.getSqrtPriceAtTick(upper);
        m[0].tickLower = lower;
        m[0].tickUpper = upper;
        m[0].liquidity = liquidity;
        m[0].amount1Max = uint128(SUPPLY);
        m[0].config.rules = RULES;
        m[0].config.advisory = address(TAX);
        m[0].config.baseLpFeePips = BASE_FEE;
        m[0].config.caps = Caps(600_000, 350_000, 1_000);
        m[0].config.rulesGasLimit = 2_000_000;
        m[0].config.advisoryGasLimit = 1_000_000;
        m[0].config.advisoryPhases = 3;
        m[0].rules.maxFeePips = BASE_FEE;
        m[0].rules.burnBps = AUTO_BURN_BPS;
        m[0].rules.protocolShareBps = 2000;

        bytes[] memory c = new bytes[](1);
        IDirectionalTax.Leg memory none;
        c[0] = abi.encode(
            IDirectionalTax.Config(none, IDirectionalTax.Leg(SELL_TAX_PIPS, 0, taxRecipient, address(0), 0))
        );

        vm.prank(CREATOR, CREATOR);
        (bytes32 family, address subject) = LAUNCHER.launchAdvised(t, ROOT, m, c, vm.getBlockTimestamp() + 1 hours);
        token = subject;
        key = LAUNCHER.position(family, 0).key;
        id = key.toId();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev The token's price as a tick (higher = pricier): minus the pool tick, since the token is currency1.
    function spot() internal view returns (int24) {
        (, int24 t,,) = MANAGER.getSlot0(id);
        return -t;
    }

    function buy(Trader who, uint256 ethIn) internal returns (uint256 tokensOut) {
        (, tokensOut) = who.swap(true, ethIn, 0);
    }

    function sell(Trader who, uint256 tokensIn) internal returns (uint256 ethOut) {
        (, ethOut) = who.swap(false, tokensIn, 0);
    }

    /// @dev Moves the token's price tick to `target` with one swap stopped by its price limit (an exact-input swap
    ///      big enough to reach it).
    function moveTo(Trader who, int24 target) internal {
        uint160 limit = TickMath.getSqrtPriceAtTick(-target);
        (uint160 now_,,,) = MANAGER.getSlot0(id);
        if (limit == now_) return;
        if (limit < now_) {
            // A buy that stops at its price limit has fees to refund, which the root refuses an unauthenticated
            // caller (UnauthenticatedRefund): find the exact input that reaches the target instead.
            uint256 lo;
            uint256 hi = address(who).balance;
            for (uint256 i; i < 48; ++i) {
                uint256 mid = (lo + hi) / 2;
                uint256 snap = vm.snapshotState();
                bool reached;
                // An input past the pool's liquidity stops short and reverts: count it as too much.
                try who.swap(true, mid, 0) {
                    reached = spot() >= target;
                } catch {
                    reached = true;
                }
                vm.revertToState(snap);
                if (reached) hi = mid;
                else lo = mid;
            }
            who.swap(true, hi, 0);
        } else {
            who.swap(false, IERC20Min(token).balanceOf(address(who)), limit); // sell
        }
    }

    function wait(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + secs / 12);
    }

    function hold(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            wait(300);
            engine.checkpoint();
        }
    }

    /// @dev Records until the newest record has caught up with the spot price (the clamp walks it 500 ticks a
    ///      record), then `extra` more. Returns how many records the catch-up took.
    function settle(uint256 extra) internal returns (uint256 n) {
        while (engine.checkpointAt(0).tick != spot() && n < 60) {
            wait(300);
            engine.checkpoint();
            ++n;
        }
        hold(extra);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // The run
    // -----------------------------------------------------------------------------------------------------------------

    function test_fork_engineOnALiveHookrPool() public {
        if (!onFork) vm.skip(true);
        console2.log("token (RHUBX stand-in)", token);
        console2.log("pool id");
        console2.logBytes32(PoolId.unwrap(id));
        console2.log("pool fee field", uint256(key.fee));
        console2.log("launch liquidity", uint256(launchLiquidity));
        console2.log("opening token price tick", int256(spot()));

        // Gas of a record on the live pool.
        wait(300);
        uint256 g = gasleft();
        engine.checkpoint();
        console2.log("gas: checkpoint()", g - gasleft());

        // Phase A: buys lift the price well above the opening (the launch position is single-sided, so the pool has
        // no liquidity under its opening price); held 2 hours, the high ratchets to it.
        for (uint256 i; i < 10; ++i) {
            uint256 got = buy(trader, 4 ether);
            console2.log("buy 4 ETH -> tokens", got);
        }
        int24 top = spot();
        console2.log("token price tick after buys", int256(top));
        uint256 lag = settle(13);
        console2.log("records the clamp took to reach the new price", lag);
        assertTrue(engine.athSet());
        console2.log("high (ticks) after a full hour at the new price", int256(engine.ath()));
        assertApproxEqAbs(int256(engine.ath()), int256(top), 1, "the high is the level held");

        // Phase B: sells take ~30% off; the sell tax accrues in ETH on the live queue for the engine.
        IDirectionalTax.Terms memory terms = TAX.terms(ROOT, id);
        assertTrue(terms.bound);
        assertEq(terms.sellTaxPips, SELL_TAX_PIPS);
        moveTo(trader, top - 3600);
        console2.log("token price tick after sells", int256(spot()));
        uint256 queued = ITaxQueueView(terms.sellQueue).pending();
        console2.log("sell queue pending (ETH wei)", queued);
        assertGt(queued, 0);
        settle(3);
        (bool ok,, uint256 ddBps, uint8 tier) = engine.drawdown();
        assertTrue(ok);
        console2.log("drawdown bps / tier", ddBps, uint256(tier));
        assertEq(tier, 2);

        uint256 deadBefore = IERC20Min(token).balanceOf(DEAD);
        uint256 ethBefore = address(engine).balance;
        g = gasleft();
        engine.run();
        uint256 runGas = g - gasleft();
        uint256 collected = address(engine).balance + 0; // after spending; logged below with the budgets
        console2.log("gas: run() with collect + buyback", runGas);
        console2.log("engine ETH before / after run", ethBefore, collected);
        console2.log("burn budget / wall reserve after run", engine.burnBudget(), engine.wallReserve());
        uint256 burned = IERC20Min(token).balanceOf(DEAD) - deadBefore;
        console2.log("tokens to the dead address in run() (buyback burn + Auto Burn on it)", burned);
        assertGt(burned, 0, "bought back through the live root and burned");
        assertGt(engine.wallReserve(), 0, "half held for the wall");
        assertEq(IERC20Min(token).balanceOf(address(engine)), 0);

        // Phase C: through the wall (60% under the high): the wall buys and burns.
        moveTo(trader, int24(engine.ath()) - 9500);
        settle(3);
        uint256 wallBefore = engine.wallReserve();
        deadBefore = IERC20Min(token).balanceOf(DEAD);
        for (uint256 i; i < 6 && engine.wallReserve() != 0; ++i) {
            wait(12);
            engine.run();
        }
        console2.log("wall reserve before / after", wallBefore, engine.wallReserve());
        console2.log("tokens burned by the wall", IERC20Min(token).balanceOf(DEAD) - deadBefore);
        assertLt(engine.wallReserve(), wallBefore, "the wall filled");
        assertLe(spot(), int24(engine.ath()) - 9163 + 1, "never above the wall price");
    }

    /// @notice The pump-poke-dump on the live pool, with its real fees: what one clamped record costs.
    function test_fork_pumpPokeDumpCost() public {
        if (!onFork) vm.skip(true);
        buy(trader, 10 ether);
        settle(13);
        int24 before = spot();
        uint256 ethBefore = address(attacker).balance;
        uint256 tokBefore = IERC20Min(token).balanceOf(address(attacker));
        wait(300);
        // Pump +5000 ticks (~65%), record, dump back: one transaction.
        moveTo(attacker, before + 5000);
        uint256 ethSpent = ethBefore - address(attacker).balance;
        engine.checkpoint();
        int24 recorded = engine.checkpointAt(0).tick;
        uint256 tokNow = IERC20Min(token).balanceOf(address(attacker));
        sell(attacker, tokNow - tokBefore);
        int256 ethLost = int256(ethBefore) - int256(address(attacker).balance);
        console2.log("pump ETH in", ethSpent);
        console2.log("record written (ticks over the pre-pump price)", int256(recorded) - int256(before));
        console2.log("round trip ETH lost", ethLost);
        console2.log("lost / pumped (bps)", uint256(ethLost) * 10_000 / ethSpent);
        assertEq(int256(recorded) - int256(before), 500, "clamped");
        assertGt(uint256(ethLost) * 10_000 / ethSpent, 600, "Auto Burn + sell tax + LP fee: over 6% a round trip");
    }

    /// @notice A pump just before a run buys nothing above the reference plus slippage, on the live root.
    function test_fork_sandwichedRunBuysNothing() public {
        if (!onFork) vm.skip(true);
        buy(trader, 10 ether);
        settle(13);
        moveTo(trader, int24(engine.ath()) - 3600);
        settle(3);
        // Pump 1,000 ticks over the reference in the same transaction as the run (its own Auto Burn counted first).
        moveTo(attacker, spot() + 1000);
        uint256 deadBefore = IERC20Min(token).balanceOf(DEAD);
        engine.run();
        assertEq(IERC20Min(token).balanceOf(DEAD), deadBefore, "no buyback above the limit");
        assertGt(engine.burnBudget(), 0, "the budget waits for the next run");
        console2.log("burn budget held through the pump (ETH wei)", engine.burnBudget());
    }
}
