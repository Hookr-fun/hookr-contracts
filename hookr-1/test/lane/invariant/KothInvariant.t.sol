// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookrRules} from "../../../src/core/HookrRules.sol";
import {HookrRouter} from "../../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../../src/interfaces/IHookrRouter.sol";
import {HookrLauncher} from "../../../src/periphery/HookrLauncher.sol";
import {HookrTypes} from "../../../src/types/HookrTypes.sol";
import {IHookrRecaptureRules} from "../../../src/interfaces/IHookrRecaptureRules.sol";
import {LaneFixture} from "../LaneFixture.sol";
import {ScriptedExecutor} from "../mocks/ScriptedExecutor.sol";
import {Actor} from "../mocks/Actors.sol";
import {ArbSysKit} from "../../kit/ArbSysMock.sol";
import {IHookrRecaptureEvents} from "../../../src/interfaces/IHookrRecaptureEvents.sol";

/// @notice Drives buys, sells, unauthenticated swaps, JIT swaps, pushes, time, rollovers and claims on a King of the
///         Pool pool of HookrRoot.
contract KothHandler is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint160 internal constant MIN_PRICE = 4295128740;
    uint160 internal constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;
    Currency internal constant ETH = Currency.wrap(address(0));

    HookrRouter internal immutable router;
    HookrRules internal immutable rules;
    ScriptedExecutor internal immutable exec;
    HookrLauncher internal immutable launcher;
    PoolKey internal key;
    bytes32 internal family;
    Actor[] internal actors;
    address internal immutable owner;

    uint256 public ghostClaimed;
    uint256 public ghostMaxBuy;
    uint256 public calls;
    /// @dev Pot flows from the Rules' events: split legs in, prizes and releases out.
    uint256 public ghostPotIn;
    uint256 public ghostPrizes;
    uint256 public ghostReleased;
    /// @dev Set when a rollover reports a carried pot other than its inflow less its prizes and releases.
    bool public ghostCarryMismatch;

    constructor(
        HookrRouter _router,
        HookrRules _rules,
        ScriptedExecutor _exec,
        HookrLauncher _launcher,
        PoolKey memory _key,
        bytes32 _family,
        Actor[] memory _actors,
        address _owner
    ) {
        router = _router;
        rules = _rules;
        exec = _exec;
        launcher = _launcher;
        key = _key;
        family = _family;
        for (uint256 i; i < _actors.length; ++i) {
            actors.push(_actors[i]);
        }
        owner = _owner;
    }

    /// @dev Records the Rules' logs around every action and tallies the pot's inflow and outflow.
    modifier tally() {
        vm.recordLogs();
        _;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rules)) continue;
            bytes32 t = logs[i].topics[0];
            if (t == IHookrRecaptureEvents.RecaptureSplit.selector) {
                (,, uint256 pot,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, Currency, uint256));
                ghostPotIn += pot;
            } else if (t == IHookrRecaptureEvents.KingCrowned.selector) {
                (uint256 amount,) = abi.decode(logs[i].data, (uint256, uint64));
                ghostPrizes += amount;
            } else if (t == IHookrRecaptureEvents.PotReleased.selector) {
                ghostReleased += abi.decode(logs[i].data, (uint256));
            } else if (t == IHookrRecaptureEvents.EpochRolled.selector) {
                (,, uint256 carried) = abi.decode(logs[i].data, (uint64, uint64, uint256));
                if (carried != ghostPotIn - ghostPrizes - ghostReleased) ghostCarryMismatch = true;
            }
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return address(actors[i]);
    }

    function _swap(Actor a, bool buy, uint256 amount) internal view returns (IHookrRouter.Swap memory p) {
        bool zeroForOne = buy; // quote (ETH) is currency0
        p = IHookrRouter.Swap(
            key, zeroForOne, -int128(int256(amount)), 1, zeroForOne ? MIN_PRICE : MAX_PRICE, address(a), block.timestamp
        );
    }

    function buy(uint256 who, uint256 amount) external tally {
        calls++;
        Actor a = actors[who % actors.length];
        amount = bound(amount, 1e9, 5e21);
        a.routerSwap(_swap(a, true, amount), amount);
        if (amount > ghostMaxBuy) ghostMaxBuy = amount;
    }

    function sell(uint256 who, uint256 amount) external tally {
        calls++;
        Actor a = actors[who % actors.length];
        uint256 held = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(a));
        amount = bound(amount, 1e9, held > 5e21 ? 5e21 : (held < 1e9 ? 1e9 : held));
        a.routerSwap(_swap(a, false, amount), 0);
    }

    function directBuy(uint256 who, uint256 amount) external tally {
        calls++;
        Actor a = actors[who % actors.length];
        a.directSwap(key, true, -int256(bound(amount, 1e9, 5e21)), MIN_PRICE);
    }

    function jitBuy(uint256 who, uint256 amount) external tally {
        calls++;
        Actor a = actors[who % actors.length];
        a.jitSwap(key, true, -int256(bound(amount, 1e9, 5e21)), MIN_PRICE, -600, 600, 1e24);
    }

    function washPair(uint256 who, uint256 amount) external tally {
        calls++;
        Actor a = actors[who % actors.length];
        amount = bound(amount, 1e18, 5e21);
        a.routerPair(_swap(a, true, amount), amount, _swap(a, false, 1e12), 0);
    }

    function setPush(uint256 amount, uint256 mode) external {
        calls++;
        uint256 m = mode % 4;
        exec.set(
            m == 0
                ? ScriptedExecutor.Mode.PUSH
                : m == 1
                    ? ScriptedExecutor.Mode.REVERT
                    : m == 2 ? ScriptedExecutor.Mode.NOTHING : ScriptedExecutor.Mode.SINK_SWALLOW,
            bound(amount, 1, 1e22)
        );
    }

    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
    }

    /// @dev Robinhood Chain's two clocks: an even `k` is the next parent block (120 L2 blocks, 12 seconds), an odd one
    ///      1 to 119 L2 blocks inside the current parent block, which only the recapture release sees.
    function clock(uint256 k) external {
        calls++;
        if (k % 2 == 0) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
        } else {
            ArbSysKit.stepL2(vm, bound(k >> 1, 1, 119));
        }
    }

    function settle() external tally {
        calls++;
        try IHookrRecaptureRules(address(rules)).settleEpoch(key.toId()) {} catch {}
    }

    function claimPool() external {
        calls++;
        uint256 accrued = IHookrRecaptureRules(address(rules)).poolAccrued(key.toId(), key.currency0);
        if (accrued == 0) return;
        vm.prank(owner);
        launcher.claimRecapture(family, 0, owner);
        ghostClaimed += accrued;
    }

    function claim(uint256 who) external {
        calls++;
        Actor a = actors[who % actors.length];
        uint256 owed = rules.claimable(ETH, address(a));
        if (owed == 0) return;
        vm.prank(address(a));
        rules.claim(ETH);
        ghostClaimed += owed;
    }
}

/// @notice Accounting and leader invariants under random interleavings, run at the default pot release by
///         `LaneSystemInvariantsTest` and at the two extremes below.
abstract contract KothInvariantBase is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ScriptedExecutor internal exec;
    PoolKey internal key;
    KothHandler internal handler;
    uint64 internal bindTime;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e32);
        exec.setRoot(address(root));
        _openLane(address(exec));
        bytes32 family;
        (key, family) = _openPoolWithFamily(ETH, _laneRules(true), _kothRc());
        (bindTime,,,) = _hill(key);
        exec.set(ScriptedExecutor.Mode.PUSH, 1e20);
        Actor[] memory actors = new Actor[](3);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = _newActor(key);
        }
        handler = new KothHandler(router, rules, exec, launcher, key, family, actors, creator);
        targetContract(address(handler));
        _targetPlainSender();
    }

    /// Every liability (claims, pot and accrual) is exactly backed by ERC-6909 the Rules hold; the root holds none.
    function invariant_liabilitiesExactlyBacked() public view {
        assertEq(manager.balanceOf(address(rules), ETH.toId()), rules.totalLiability(ETH));
        assertTrue(rules.accountingInvariant(ETH));
        assertEq(manager.balanceOf(address(root), ETH.toId()), 0);
    }

    /// Liabilities are exactly the claims of the accounts that can be credited, the pot and the pool accrual.
    function invariant_liabilitiesAreClaimsPotAndAccruals() public view {
        uint256 sum = rules.claimable(ETH, protocol) + rules.claimable(ETH, creator);
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += rules.claimable(ETH, handler.actorAt(i));
        }
        (,,, uint128 pot) = _hill(key);
        assertEq(sum + pot + _accrued(key), rules.totalLiability(ETH));
    }

    /// A leader is always an authenticated buyer with a qualifying buy no larger than any buy seen.
    function invariant_leaderIsQualifiedActor() public view {
        (, address leader, uint128 amount,) = _hill(key);
        if (leader == address(0)) {
            assertEq(amount, 0);
            return;
        }
        bool known;
        for (uint256 i; i < handler.actorCount(); ++i) {
            if (handler.actorAt(i) == leader) known = true;
        }
        assertTrue(known);
        assertGe(amount, MIN_BUY);
        assertLe(amount, handler.ghostMaxBuy());
    }

    /// The pot is exactly its inflow less prizes and releases, so it never exceeds what flowed in, and every rollover
    /// reports that same pot as carried.
    function invariant_potBoundedByInflow() public view {
        (,,, uint128 pot) = _hill(key);
        assertEq(uint256(pot) + handler.ghostPrizes() + handler.ghostReleased(), handler.ghostPotIn());
        assertLe(pot, handler.ghostPotIn());
        assertFalse(handler.ghostCarryMismatch());
        (HookrTypes.RecaptureConfig memory c,,) = _recap().recaptureConfig(key.toId());
        assertEq(c.potReleaseBps, _potReleaseBps());
    }

    /// Epochs stay aligned to the bind time and never start in the future.
    function invariant_epochAligned() public view {
        (uint64 start,,,) = _hill(key);
        assertLe(start, vm.getBlockTimestamp());
        assertEq((uint256(start) - bindTime) % PERIOD, 0);
    }
}

/// @notice The same invariants with the smallest pot release, 2,500 per closed epoch.
contract KothInvariantMinReleaseTest is KothInvariantBase {
    function _potReleaseBps() internal pure override returns (uint16) {
        return 2_500;
    }
}

/// @notice The same invariants with the largest pot release: the whole pot at every rollover.
contract KothInvariantMaxReleaseTest is KothInvariantBase {
    function _potReleaseBps() internal pure override returns (uint16) {
        return 10_000;
    }
}
