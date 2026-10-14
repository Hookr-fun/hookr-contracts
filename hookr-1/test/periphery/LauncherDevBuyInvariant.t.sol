// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {DevBuyFixture} from "./DevBuyFixture.sol";

interface IMemberSource {
    function memberFor(address subject, Currency quote, bool dynamic)
        external
        view
        returns (IHookrLauncher.Member memory);
}

/// @dev Launches new-token families with and without a dev buy, buys and sells on them through the router in later
///      parent blocks, and collects the owner's fees. Every call settles; nothing here reverts by design.
contract DevBuyHandler is Test {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant MIN_LIMIT = 4295128740;
    uint160 internal constant MAX_LIMIT = 1461446703485210103287273052203988822378723970341;

    HookrLauncher internal immutable launcher;
    HookrRouter internal immutable router;
    address internal immutable root;
    IMemberSource internal immutable source;
    IERC20 internal immutable token;
    IPoolManager internal immutable manager;

    struct Launched {
        bytes32 family;
        PoolKey key;
        address subject;
        bool devBuy;
        bool dynamic;
        bool publicSwap;
        uint256 bought;
    }

    Launched[] internal launched;
    uint256 internal salt;
    uint256 public devBuys;
    uint256 public plainLaunches;
    uint256 public publicTrades;
    uint256 public collects;
    uint256 public launcherSwapsInDevBuys;
    uint256 public launcherSwapsElsewhere;
    uint256 public maxDevBuyLogsPerLaunch;

    constructor(
        HookrLauncher launcher_,
        HookrRouter router_,
        address root_,
        IMemberSource source_,
        IERC20 token_,
        IPoolManager manager_
    ) {
        launcher = launcher_;
        router = router_;
        root = root_;
        source = source_;
        token = token_;
        manager = manager_;
        token_.approve(address(launcher_), type(uint256).max);
        token_.approve(address(router_), type(uint256).max);
    }

    function count() external view returns (uint256) {
        return launched.length;
    }

    function launchAt(uint256 i) external view returns (Launched memory) {
        return launched[i];
    }

    function _launch(uint256 seed, uint128 quoteIn) internal {
        bool native = seed & 1 == 0;
        bool dynamic = seed & 2 == 0;
        Currency quote = native ? Currency.wrap(address(0)) : Currency.wrap(address(token));
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Inv", "INV", 1e24, bytes32(++salt));
        address subject = launcher.predictToken(address(this), t);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = source.memberFor(subject, quote, dynamic);
        vm.recordLogs();
        bytes32 family;
        uint256 out;
        if (quoteIn == 0) {
            (family,) = launcher.launch(t, root, members, block.timestamp);
            ++plainLaunches;
        } else {
            (family,, out) = launcher.launchWithBuy{value: native ? quoteIn : 0}(
                t,
                root,
                members,
                new bytes[](1),
                IHookrLauncher.DevBuy(0, quoteIn, 1, uint32(seed % 500)),
                block.timestamp
            );
            ++devBuys;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 devLogs, uint256 swaps) = _scan(logs);
        if (devLogs > maxDevBuyLogsPerLaunch) maxDevBuyLogsPerLaunch = devLogs;
        if (quoteIn == 0) launcherSwapsElsewhere += swaps;
        else launcherSwapsInDevBuys += swaps;
        launched.push(Launched(family, launcher.position(family, 0).key, subject, quoteIn != 0, dynamic, false, out));
    }

    function _scan(Vm.Log[] memory logs) internal view returns (uint256 devLogs, uint256 swaps) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(launcher) && logs[i].topics[0] == IHookrLauncher.DevBuyExecuted.selector) {
                ++devLogs;
            }
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == IPoolManager.Swap.selector
                    && address(uint160(uint256(logs[i].topics[2]))) == address(launcher)
            ) ++swaps;
        }
    }

    function launchPlain(uint8 seed) external {
        _launch(seed, 0);
    }

    function launchWithBuy(uint8 seed, uint96 raw) external {
        _launch(seed, uint128(bound(raw, 1e18, 2e22)));
    }

    function trade(uint8 which, uint96 raw, bool buy) external {
        if (launched.length == 0) return;
        Launched storage l = launched[bound(which, 0, launched.length - 1)];
        // A dev buy closes its launch parent block to other buys; every trade here runs in a later one.
        vm.roll(vm.getBlockNumber() + 1);
        bool quoteIs0 = Currency.unwrap(l.key.currency0) != l.subject;
        bool native = Currency.unwrap(l.key.currency0) == address(0);
        uint128 amount;
        if (buy) {
            amount = uint128(bound(raw, 1e15, 1e21));
        } else {
            // Sell at most what was bought on this pool, so the sell stays inside the band.
            if (l.bought < 1e12) return;
            amount = uint128(bound(raw, 1e12, l.bought));
            IERC20(l.subject).approve(address(router), amount);
        }
        bool zeroForOne = buy == quoteIs0;
        IHookrRouter.Swap memory p = IHookrRouter.Swap(
            l.key, zeroForOne, -int128(amount), 1, zeroForOne ? MIN_LIMIT : MAX_LIMIT, address(this), block.timestamp
        );
        vm.recordLogs();
        (, uint256 amountOut) = router.swap{value: buy && native ? amount : 0}(p, address(0), new uint256[](0));
        if (buy) l.bought += amountOut;
        else l.bought -= amount;
        (, uint256 swaps) = _scan(vm.getRecordedLogs());
        launcherSwapsElsewhere += swaps;
        l.publicSwap = true;
        ++publicTrades;
    }

    function collect(uint8 which) external {
        if (launched.length == 0) return;
        Launched storage l = launched[bound(which, 0, launched.length - 1)];
        vm.recordLogs();
        launcher.withdraw(l.family, 0, 0, 0, 0, address(this), block.timestamp);
        (, uint256 swaps) = _scan(vm.getRecordedLogs());
        launcherSwapsElsewhere += swaps;
        ++collects;
    }

    receive() external payable {}
}

/// @notice Launcher dev buy invariants over launches with and without a dev buy, public buys and sells, and fee
///         collection: the Launcher holds nothing at rest, Rules claims stay backed, a launch emits at most one
///         DevBuyExecuted, the Launcher's only swaps are dev buys, and a dev-bought dynamic fee pool keeps its
///         dynamic fee state unstarted until a public swap.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 32
contract LauncherDevBuyInvariantTest is DevBuyFixture, IMemberSource {
    using PoolIdLibrary for PoolKey;

    DevBuyHandler internal handler;

    function setUp() public {
        _setUpPeriphery();
        handler = new DevBuyHandler(launcher, router, address(root), this, tokenB, manager);
        tokenB.transfer(address(handler), 1e27);
        vm.deal(address(handler), 1e27);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = DevBuyHandler.launchPlain.selector;
        selectors[1] = DevBuyHandler.launchWithBuy.selector;
        selectors[2] = DevBuyHandler.trade.selector;
        selectors[3] = DevBuyHandler.trade.selector;
        selectors[4] = DevBuyHandler.collect.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
        // Every fuzzed call comes from one account no invariant reads: on a fork, whose base fee is not zero, a call's
        // sender is left holding ETH for its gas, which would read as a balance of a checked contract.
        targetSender(address(uint160(uint256(keccak256("hookr.invariant.sender")))));
    }

    /// @dev A guarded member holding the whole supply; with `dynamic`, sensitivity 5 and a 5% ceiling.
    function memberFor(address subject, Currency quote, bool dynamic)
        external
        view
        returns (IHookrLauncher.Member memory m)
    {
        m = _devMember(subject, quote, SUPPLY);
        if (dynamic) {
            m.rules.maxFeePips = 50_000;
            m.rules.dynamicFeeSens = 5;
        }
    }

    /// Every path runs once, so the invariants below are never vacuous.
    function testEveryHandlerPathRuns() public {
        handler.launchPlain(0);
        handler.launchWithBuy(1, 1e22);
        handler.launchWithBuy(2, 1e22);
        handler.trade(0, 1e20, true);
        handler.trade(1, 1e18, false);
        handler.trade(2, 1e18, true);
        handler.collect(1);
        assertEq(handler.devBuys(), 2);
        assertEq(handler.launcherSwapsInDevBuys(), 2);
        assertEq(handler.publicTrades(), 3);
        invariant_launcherHoldsNothing();
        invariant_rulesClaimsBacked();
        invariant_oneDevBuyPerLaunch();
        invariant_launcherSwapsOnlyInDevBuys();
        invariant_devBuyLeavesDynamicFeeUnstarted();
    }

    function invariant_launcherHoldsNothing() public view {
        assertEq(address(launcher).balance, 0, "native");
        assertEq(tokenB.balanceOf(address(launcher)), 0, "quote");
        for (uint256 i; i < handler.count(); ++i) {
            assertEq(IERC20(handler.launchAt(i).subject).balanceOf(address(launcher)), 0, "subject");
        }
    }

    function invariant_rulesClaimsBacked() public view {
        assertTrue(rules.accountingInvariant(Currency.wrap(address(0))), "native claims");
        assertTrue(rules.accountingInvariant(Currency.wrap(address(tokenB))), "quote claims");
    }

    function invariant_oneDevBuyPerLaunch() public view {
        assertLe(handler.maxDevBuyLogsPerLaunch(), 1);
    }

    function invariant_launcherSwapsOnlyInDevBuys() public view {
        assertEq(handler.launcherSwapsElsewhere(), 0, "a Launcher swap outside launchWithBuy");
        assertEq(handler.launcherSwapsInDevBuys(), handler.devBuys(), "one swap per dev buy");
    }

    function invariant_devBuyLeavesDynamicFeeUnstarted() public view {
        for (uint256 i; i < handler.count(); ++i) {
            DevBuyHandler.Launched memory l = handler.launchAt(i);
            if (!l.devBuy || !l.dynamic || l.publicSwap) continue;
            (, int24 ref, int24 anchor, uint40 movedAt, uint40 referenceAt, int24 moved) =
                rules.referenceState(l.key.toId());
            assertEq(movedAt, 0, "not started");
            assertEq(referenceAt, 0, "not started");
            assertEq(ref, 0, "no reference");
            assertEq(anchor, 0, "no anchor");
            assertEq(moved, 0, "no moved tick");
        }
    }
}
