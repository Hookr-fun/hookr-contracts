// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {HookrPriceLog} from "../../price-log/src/HookrPriceLog.sol";
import {HookrBuybackBurn} from "../src/HookrBuybackBurn.sol";

// ---------------------------------------------------------------------------------------------------------------------
// The live Hookr 1 surface this run touches, copied by ABI from hookr-1/src (HookrTypes, IHookrLauncher), as the
// Drawdown Burn fork run copies it.
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
    function launch(Token calldata token, address rootAddress, Member[] calldata members, uint256 deadline)
        external
        payable
        returns (bytes32 familyId, address subject);
    function launchAdvised(
        Token calldata token,
        address rootAddress,
        Member[] calldata members,
        bytes[] calldata advisoryConfigs,
        uint256 deadline
    ) external payable returns (bytes32 familyId, address subject);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

/// @dev ArbSys stand-in at 0x64, as the release suites install it: arbBlockNumber() = l2Base + 120 x parent blocks.
contract ForkArbSys {
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
contract ForkTrader is IUnlockCallback {
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

/// @title BuybackFork
/// @notice The buyback and the shared price log on a real Hookr 1 pool on Robinhood Chain 4663 at a pinned block: a
///         stand-in for HOOKR launched through the live Launcher on the live root (no Auto Burn, no tax: a plain
///         reference pool), the log opened and the buyback deployed before the pool exists (SL-1), then real trades,
///         records, and a buyback through the live HookrRouter and root that burns what it buys.
/// @dev    Runs only on a 4663 fork; the RPC comes from the environment (FOUNDRY_ETH_RPC_URL), never a command line:
///         `FOUNDRY_ETH_RPC_URL=... FOUNDRY_FORK_BLOCK_NUMBER=91088307 forge test --root labs --match-contract Fork`.
contract BuybackFork is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Pin: L2 block 91,088,307, parent (L1) block 26,213,644, the Drawdown Burn fork run's pin.
    uint256 internal constant L2_BLOCK = 91_088_307;
    uint256 internal constant L1_BLOCK = 26_213_644;

    IPoolManager internal constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    ILauncher internal constant LAUNCHER = ILauncher(0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4);
    address internal constant ROOT = 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc;
    address internal constant RULES = 0x4a71c270b1520F94064268102AebD744b0DE7942;
    address internal constant ROUTER = 0xC2Bc9a3fe6c4Ce8C2F7EB4655b0869b01D8c93C9; // HookrRouter, hookr-1 deployments
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes32 internal constant LAUNCHER_RUNTIME = 0x96b8c338c38a072ceef8b947ad93d3d7a46d2d7c70189d2b4ee92efb2a5e1d5d;
    bytes32 internal constant ROOT_RUNTIME = 0xd336de325837e60a74cea11d87b5ebd1cc8961911f611f38de0508d23b6e779f;
    bytes32 internal constant RULES_RUNTIME = 0x4b6d50b40981b8082f3ee5a7ebf57e48489f71c94c2a3b94032a1d1a382b515b;
    bytes32 internal constant MANAGER_RUNTIME = 0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;

    address internal constant CREATOR = address(0xC0FFEE);
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    int24 internal constant SPACING = 60;
    int24 internal constant OPEN_TICK = 177_240; // pool tick (token per ETH): a 20 ETH opening valuation
    int24 internal constant RANGE = 60_000;
    uint24 internal constant BASE_FEE = 3000;
    /// @notice The deploy-day cap of the Treasury Buyback's HANDOFF: 0.01 ETH per 1,800 s.
    uint128 internal constant CAP = 0.01 ether;

    PoolKey internal key;
    PoolId internal id;
    address internal token;
    HookrPriceLog internal plog;
    bytes32 internal logId;
    HookrBuybackBurn internal buyback;
    ForkTrader internal trader;
    ForkTrader internal attacker;
    bool internal onFork;

    function setUp() public {
        onFork = block.chainid == 4663;
        if (!onFork) return;
        require(block.number == L2_BLOCK, "pin: FOUNDRY_FORK_BLOCK_NUMBER=91088307");
        assertEq(address(LAUNCHER).codehash, LAUNCHER_RUNTIME);
        assertEq(ROOT.codehash, ROOT_RUNTIME);
        assertEq(RULES.codehash, RULES_RUNTIME);
        assertEq(address(MANAGER).codehash, MANAGER_RUNTIME);
        (bool ok, bytes memory r) = ROOT.staticcall(abi.encodeWithSignature("router()"));
        require(ok && abi.decode(r, (address)) == ROUTER, "the live root names the live router");
        vm.roll(L1_BLOCK);
        vm.etch(address(100), type(ForkArbSys).runtimeCode);
        vm.store(address(100), bytes32(0), bytes32(L2_BLOCK | (L1_BLOCK << 128)));

        trader = new ForkTrader(MANAGER);
        attacker = new ForkTrader(MANAGER);
        vm.deal(address(trader), 1000 ether);
        vm.deal(address(attacker), 1000 ether);

        // The key the Launcher will open, read from a launch that is then rolled back.
        uint256 snap = vm.snapshotState();
        _launch();
        PoolKey memory k = key;
        address predicted = token;
        vm.revertToState(snap);

        // SL-1 on chain: the log and the buyback exist before the pool does.
        plog = new HookrPriceLog(MANAGER);
        logId = plog.open(
            k.toId(),
            HookrPriceLog.Params({
                interval: 300, maxMoveTicks: 500, minLiquidity: 1e18, hasSeedTick: true, seedTick: OPEN_TICK
            })
        );
        buyback = new HookrBuybackBurn(address(this), predicted, ROUTER, plog, k, logId, CAP);
        vm.deal(address(buyback), 0.05 ether);
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.NoHealthyReference.selector, k.toId(), 1800));
        buyback.buyback(0.01 ether);

        _launch();
        assertEq(keccak256(abi.encode(key)), keccak256(abi.encode(k)));
        assertEq(token, predicted);
        trader.setKey(key);
        attacker.setKey(key);
        // A fresh launch is token-only just past the opening price: no in-range liquidity until the first buy, so the
        // log refuses its first record until then.
        vm.expectRevert(HookrPriceLog.ThinStart.selector);
        plog.record(logId);
        buy(trader, 0.01 ether);
        plog.record(logId);
        console2.log("first record (pool tick)", int256(plog.latest(logId).tick));
        console2.log("spot (pool tick)", int256(spot()));
        deal(token, address(trader), 300_000_000e18);
    }

    receive() external payable {}

    function _launch() internal {
        ILauncher.Token memory t = ILauncher.Token(address(0), "HOOKR stand-in", "HOOKRX", SUPPLY, keccak256("buyback"));
        require(LAUNCHER.predictToken(CREATOR, t) > address(0), "token sorts after ETH");
        int24 lower = OPEN_TICK - RANGE;
        int24 upper = OPEN_TICK;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), SUPPLY
        ) - 1;
        ILauncher.Member[] memory m = new ILauncher.Member[](1);
        m[0].quote = Currency.wrap(address(0));
        m[0].tickSpacing = SPACING;
        m[0].sqrtPriceX96 = TickMath.getSqrtPriceAtTick(upper);
        m[0].tickLower = lower;
        m[0].tickUpper = upper;
        m[0].liquidity = liquidity;
        m[0].amount1Max = uint128(SUPPLY);
        m[0].config.rules = RULES;
        m[0].config.baseLpFeePips = BASE_FEE;
        m[0].config.caps = Caps(600_000, 350_000, 1_000);
        m[0].config.rulesGasLimit = 2_000_000;
        m[0].rules.maxFeePips = BASE_FEE;
        m[0].rules.protocolShareBps = 2000;
        vm.prank(CREATOR, CREATOR);
        (bytes32 family, address subject) = LAUNCHER.launch(t, ROOT, m, vm.getBlockTimestamp() + 1 hours);
        token = subject;
        key = LAUNCHER.position(family, 0).key;
        id = key.toId();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    function spot() internal view returns (int24 t) {
        (, t,,) = MANAGER.getSlot0(id);
    }

    function buy(ForkTrader who, uint256 ethIn) internal returns (uint256 tokensOut) {
        (, tokensOut) = who.swap(true, ethIn, 0);
    }

    function wait(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + secs / 12);
    }

    /// @dev Records until the newest record has caught up with spot (the clamp walks it 500 ticks a record), then
    ///      `extra` more.
    function settle(uint256 extra) internal returns (uint256 n) {
        while (plog.latest(logId).tick != spot() && n < 60) {
            wait(300);
            plog.record(logId);
            ++n;
        }
        for (uint256 i; i < extra; ++i) {
            wait(300);
            plog.record(logId);
        }
    }

    /// @dev HOOKR (currency1) that `amount` ETH buys at pool tick `t`.
    function expectedAt(uint256 amount, int24 t) internal pure returns (uint256) {
        uint256 sp = TickMath.getSqrtPriceAtTick(t);
        return FullMath.mulDiv(FullMath.mulDiv(sp, sp, 1 << 64), amount, 1 << 128);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // The run
    // -----------------------------------------------------------------------------------------------------------------

    function test_fork_buybackThroughTheLiveRouterAndRoot() public {
        if (!onFork) vm.skip(true);
        console2.log("token (HOOKR stand-in)", token);
        console2.log("pool id");
        console2.logBytes32(PoolId.unwrap(id));

        // Trading, then the log catches up and covers a reference window.
        for (uint256 i; i < 5; ++i) {
            buy(trader, 0.2 ether);
        }
        uint256 lag = settle(7);
        console2.log("records the clamp took to reach the traded price", lag);

        // Gas of the log on the live pool: a record, then the buyback's two reads, cold and warm.
        wait(300);
        vm.cool(address(plog));
        vm.cool(address(MANAGER));
        uint256 g = gasleft();
        plog.record(logId);
        console2.log("gas: record on the live pool (cold slots)", g - gasleft());
        wait(60);
        uint32[2] memory windows = [uint32(1800), 60];
        for (uint256 i; i < 2; ++i) {
            vm.cool(address(plog));
            g = gasleft();
            plog.mean(logId, windows[i]);
            uint256 cold = g - gasleft();
            g = gasleft();
            plog.mean(logId, windows[i]);
            console2.log("gas: mean window / cold / warm", windows[i], cold, g - gasleft());
        }

        (, int24 ref) = plog.mean(logId, 1800);
        uint256 fair = expectedAt(0.01 ether, ref);
        uint256 deadBefore = IERC20Min(token).balanceOf(DEAD);
        vm.cool(address(plog));
        g = gasleft();
        uint256 out = buyback.buyback(0.01 ether);
        console2.log("gas: buyback through the live router (log slots cold)", g - gasleft());
        console2.log("reference pool tick", int256(ref));
        console2.log("HOOKR bought and burned / fair at the reference", out, fair);
        console2.log("short of fair (bps)", fair > out ? (fair - out) * 10_000 / fair : 0);
        assertEq(IERC20Min(token).balanceOf(DEAD) - deadBefore, out, "every token bought went to the dead address");
        assertGe(out, fair - fair * 300 / 10_000, "at the 300 bps floor or better");
        assertEq(IERC20Min(token).balanceOf(address(buyback)), 0);
        assertEq(address(buyback).balance, 0.04 ether);

        // The deploy-day cap: one 0.01 ETH chunk now, the next as it refills.
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.SpendLimitExceeded.selector, 0.01 ether, 0));
        buyback.buyback(0.01 ether);
        wait(1800);
        settle(0);
        assertGt(buyback.buyback(0.01 ether), 0, "a period later");
    }

    /// @notice A pump through the live root just before the buyback, in the same transaction: the floor refuses it.
    function test_fork_sameTransactionPumpIsRefused() public {
        if (!onFork) vm.skip(true);
        for (uint256 i; i < 5; ++i) {
            buy(trader, 0.2 ether);
        }
        settle(7);
        // Push the token's price up about 5% (the pool tick down 500).
        int24 before = spot();
        uint256 lo;
        uint256 hi = 5 ether;
        for (uint256 i; i < 40; ++i) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            buy(attacker, mid);
            bool far = spot() <= before - 500;
            vm.revertToState(snap);
            if (far) hi = mid;
            else lo = mid;
        }
        buy(attacker, hi);
        console2.log("pump: ETH in", hi);
        console2.log("pump: pool ticks moved", int256(spot()) - before);
        uint256 deadBefore = IERC20Min(token).balanceOf(DEAD);
        vm.expectRevert();
        buyback.buyback(0.01 ether);
        assertEq(IERC20Min(token).balanceOf(DEAD), deadBefore);
    }
}
