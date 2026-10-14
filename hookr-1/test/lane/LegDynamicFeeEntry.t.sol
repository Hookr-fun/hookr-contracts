// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrLane} from "../../src/core/HookrLane.sol";
import {DynamicLegReads} from "./utils/DynamicLegReads.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice A lane executor that runs the legs it is given in each phase and, when armed, tries to call the root's
///         `updateLegDynamicFee` itself from inside its open frame, right after its last leg, with exactly the
///         afterSwap calldata the PoolManager sent for that leg (the leg's own carry, a second time). It records what
///         the root answered and goes on.
contract LegEntryProbe {
    using CurrencyLibrary for Currency;

    struct Leg {
        PoolKey key;
        SwapParams params;
    }

    IPoolManager public immutable manager;
    address public root;
    Leg[] internal _before;
    Leg[] internal _after;
    bool public probing;
    bool public probed;
    bool public probeOk;
    bytes public probeOut;

    constructor(IPoolManager m) {
        manager = m;
    }

    receive() external payable {}

    function setUp(address root_) external {
        root = root_;
    }

    function clear() external {
        delete _before;
        delete _after;
        probed = false;
        probeOk = false;
        delete probeOut;
    }

    function add(bool afterPhase, PoolKey calldata key, bool zeroForOne, int256 amount, uint160 limit) external {
        (afterPhase ? _after : _before).push(Leg(key, SwapParams(zeroForOne, amount, limit)));
    }

    function setProbing(bool on) external {
        probing = on;
    }

    function executeArbitrage(PoolKey calldata, address trader) external returns (uint256) {
        require(msg.sender == root, "root");
        Leg[] storage list = trader == address(0) ? _before : _after;
        for (uint256 i; i < list.length; ++i) {
            Leg memory l = list[i];
            BalanceDelta d = manager.swap(l.key, l.params, "");
            _settle(l.key.currency0, d.amount0());
            _settle(l.key.currency1, d.amount1());
            if (probing && i == list.length - 1) {
                // The leg's afterSwap calldata under updateLegDynamicFee's selector, with a zero LP fee appended, as
                // HookrRoot._carryLeg forwards it.
                bytes memory data = abi.encodePacked(
                    abi.encodeWithSelector(
                        HookrLane.updateLegDynamicFee.selector, address(this), l.key, l.params, d, bytes("")
                    ),
                    uint256(0)
                );
                probed = true;
                (probeOk, probeOut) = root.call(data);
            }
        }
        return 0;
    }

    function _settle(Currency c, int128 v) internal {
        if (v < 0) {
            uint256 owed = uint256(uint128(-v));
            if (c.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(c);
                IERC20(Currency.unwrap(c)).transfer(address(manager), owed);
                manager.settle();
            }
        } else if (v > 0) {
            manager.take(c, address(this), uint256(uint128(v)));
        }
    }
}

/// @notice HookrLane.updateLegDynamicFee is reachable only inside a leg frame: the root's afterSwap for an executor leg
///         on a dynamic fee pool forwards it to the module by DELEGATECALL, with the PoolManager as the caller. Every
///         direct call is refused: on the module itself (it runs only as the root's DELEGATECALL), and through the
///         root's fallback from any caller but the PoolManager, the lane executor inside its own open frame included,
///         even with the exact calldata of the leg it just ran. A refused call leaves the pool's dynamic fee state as
///         the leg's own carry left it.
/// @dev The PoolManager is the one caller the module accepts, and it calls a hook only with the IHooks selectors
///      (v4-core's Hooks library builds every hook call with abi.encodeCall(IHooks.<hook>, ...)), so this selector
///      reaches the module from the PoolManager only through the root's own afterSwap for an executor leg.
contract LegDynamicFeeEntryTest is DynamicLegReads {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes4 internal constant UPDATE_LEG = HookrLane.updateLegDynamicFee.selector;

    LegEntryProbe internal probe;
    HookrToken internal subject;
    /// @dev The dynamic fee member (ETH quote, currency0) and its static sibling (tokenB quote).
    PoolKey internal dyn;
    PoolKey internal stat;

    function setUp() public {
        _setUpLane();
        probe = new LegEntryProbe(manager);
        probe.setUp(address(root));
        _openLane(address(probe), 3_000_000);
        vm.deal(address(probe), 1e28);
        tokenB.transfer(address(probe), 1e27);

        subject = _newSubject();
        subject.transfer(address(probe), 1e26);
        HookrTypes.RulesConfig memory dynamicRules = _laneRules(false);
        dynamicRules.maxFeePips = 50_000;
        dynamicRules.dynamicFeeSens = 5;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _laneMember(ETH, dynamicRules, _recaptureOnlyRc());
        members[1] = _laneMember(Currency.wrap(address(tokenB)), _laneRules(false), _recaptureOnlyRc());
        (, PoolKey[] memory keys) = _launchAs(creator, subject, members);
        (dyn, stat) = (keys[0], keys[1]);
        _nextBlock();
        _buy(dyn, ETH, minnow, 1e18); // starts the member's dynamic fee state at the launch price
        _nextBlock();
    }

    // ───────────────────────────── refused outside a leg frame ─────────────────────────────

    /// The module only runs as the root's DELEGATECALL: on its own address every caller is refused, the PoolManager
    /// included.
    function test_onTheModuleItself_everyCallerIsRefused() public {
        (address module,) = IHookrLaneRoot(address(root)).laneModule();
        assertGt(module.code.length, 0);
        address[3] memory callers = [address(this), address(manager), address(root)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            (bool ok, bytes memory err) = module.call(_carryInput(address(probe), true, -1e20));
            assertFalse(ok);
            assertEq(bytes4(err), IHookrRootEvents.Unauthorized.selector);
        }
        vm.expectRevert(IHookrRootEvents.Unauthorized.selector);
        HookrLane(module).updateLegDynamicFee();
    }

    /// Through the root's fallback (which forwards every unknown selector to the module) any caller but the PoolManager
    /// is refused, bare or with a well-formed carry of the dynamic fee pool, and the pool's dynamic fee state does not
    /// move.
    function test_throughTheRoot_everyCallerButThePoolManagerIsRefused() public {
        bytes32 word = _word(dyn);
        address[9] memory callers = [
            address(this),
            whale,
            creator,
            address(probe),
            address(rules),
            address(router),
            address(registry),
            address(launcher),
            address(root)
        ];
        bytes[3] memory inputs = [
            abi.encodePacked(UPDATE_LEG), _carryInput(address(probe), true, -3e22), _carryInput(callers[1], false, 2e22)
        ];
        for (uint256 i; i < callers.length; ++i) {
            for (uint256 j; j < inputs.length; ++j) {
                vm.prank(callers[i]);
                (bool ok, bytes memory err) = address(root).call(inputs[j]);
                assertFalse(ok, "refused");
                // The root itself reaches its own fallback's refusal; every other caller the module's.
                assertEq(bytes4(err), IHookrRootEvents.Unauthorized.selector);
            }
        }
        assertEq(_word(dyn), word, "the dynamic fee state did not move");
    }

    // ───────────────────────────── refused inside an open frame ─────────────────────────────

    /// Inside its own open frame, right after a real leg on the dynamic fee pool, the executor replays that leg's carry
    /// on the root: refused, the frame still completes, and the pool's dynamic fee state is exactly what the leg's own
    /// carry left, as in the same arb recapture without the replay.
    function test_insideAnOpenFrame_theExecutorIsRefused() public {
        uint256 snap = vm.snapshotState();
        probe.clear();
        probe.add(false, dyn, true, -3e22, MIN_PRICE + 1);
        assertEq(_trigger(), 0, "no frame failed");
        bytes32 alone = _word(dyn);

        vm.revertToState(snap);
        probe.clear();
        probe.add(false, dyn, true, -3e22, MIN_PRICE + 1);
        probe.setProbing(true);
        bytes32 before = _word(dyn);
        assertEq(_trigger(), 0, "no frame failed");
        assertTrue(probe.probed(), "the executor tried");
        assertFalse(probe.probeOk(), "refused");
        assertEq(bytes4(probe.probeOut()), IHookrRootEvents.Unauthorized.selector);
        assertTrue(_word(dyn) != before, "the leg's own carry moved the state");
        assertEq(_word(dyn), alone, "the replay added nothing");
    }

    // ───────────────────────────── reached only by an executor leg ─────────────────────────────

    /// A leg on the dynamic fee pool reaches the module once, and the module carries the state through the Rules'
    /// carryLeg, from the root.
    function test_aLegOnTheDynamicFeePool_isCarriedOnce() public {
        probe.clear();
        probe.add(false, dyn, true, -3e22, MIN_PRICE + 1);
        bytes32 before = _word(dyn);
        vm.expectCall(address(rules), abi.encodePacked(CARRY_LEG), 1);
        assertEq(_trigger(), 0, "no frame failed");
        assertTrue(_word(dyn) != before, "the state moved");
    }

    /// A leg on a pool without dynamic fees never reaches it.
    function test_aLegOnAStaticPool_isNotCarried() public {
        probe.clear();
        bool statSell = Currency.unwrap(stat.currency0) == address(subject);
        probe.add(false, stat, statSell, -1e20, statSell ? MIN_PRICE + 1 : MAX_PRICE - 1);
        (uint160 statBefore,,,) = manager.getSlot0(stat.toId());
        vm.expectCall(address(rules), abi.encodePacked(CARRY_LEG), 0);
        vm.recordLogs();
        _buy(dyn, ETH, whale, 1e18);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.failed, 0, "no frame failed");
        assertEq(o.succeeded, 2, "both frames ran");
        (uint160 statAfter,,,) = manager.getSlot0(stat.toId());
        assertTrue(statAfter != statBefore, "the leg on the static pool ran");
    }

    /// An ordinary swap on the dynamic fee pool, with the lane idle, prices the state on its own path and never
    /// reaches the leg carry.
    function test_anOrdinarySwap_isNotALegCarry() public {
        probe.clear();
        (uint160 priceBefore,,,) = manager.getSlot0(dyn.toId());
        vm.expectCall(address(rules), abi.encodePacked(CARRY_LEG), 0);
        _buy(dyn, ETH, whale, 1e18);
        (uint160 priceAfter,,,) = manager.getSlot0(dyn.toId());
        assertTrue(priceAfter != priceBefore, "the ordinary swap ran");
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev A whale buy on the static sibling, whose arb recapture runs the probe's armed legs; returns the number of
    ///      failed frames.
    function _trigger() internal returns (uint256 failed) {
        vm.recordLogs();
        _buy(stat, Currency.wrap(address(tokenB)), whale, 1e18);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded + o.failed, 2, "both frames ran");
        failed = o.failed;
    }

    /// @dev updateLegDynamicFee's input for a swap of `sender` on the dynamic fee pool: afterSwap's arguments with a
    ///      plausible delta for `amount`, and a zero LP fee appended.
    function _carryInput(address sender, bool zeroForOne, int256 amount) internal view returns (bytes memory) {
        PoolKey memory key = dyn;
        SwapParams memory params = SwapParams(zeroForOne, amount, zeroForOne ? MIN_PRICE + 1 : MAX_PRICE - 1);
        int128 a = int128(amount < 0 ? -amount : amount);
        BalanceDelta delta = BalanceDelta.wrap((int256(zeroForOne ? -a : a) << 128) | int256(uint256(uint128(a / 2))));
        return abi.encodePacked(abi.encodeWithSelector(UPDATE_LEG, sender, key, params, delta, bytes("")), uint256(0));
    }
}
