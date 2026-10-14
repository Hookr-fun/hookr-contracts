// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookrTypes} from "../../../src/types/HookrTypes.sol";
import {IHookrRoot} from "../../../src/interfaces/IHookrRoot.sol";
import {IHookrLaneExecutor} from "../../../src/interfaces/callback/IHookrLaneExecutor.sol";
import {IHookrLaneRoot} from "../../../src/interfaces/IHookrLaneRoot.sol";

/// @notice Test-only executor with honest and hostile modes. Funds its pushes from its own balance.
contract ScriptedExecutor is IHookrLaneExecutor, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    enum Mode {
        NOTHING,
        PUSH,
        REVERT,
        LEAVE_DELTA,
        LEAVE_SYNC,
        BURN_GAS,
        SINK_UNBACKED,
        SINK_SWALLOW,
        SINK_TWICE,
        SINK_WRONG_POOL,
        LEG_OTHER_POOL,
        LEG_SAME_POOL,
        BAD_RETURN,
        GIFT_ROOT,
        SETTLE_EPOCH,
        PUSH_THEN_LEG,
        LEG_BOTH_WAYS,
        PUSH_THEN_LEAVE_DELTA,
        SKIM,
        LEG_OTHER_THEN_PUSH,
        PUSH_NET,
        PLAN,
        STRAY_MINT,
        MIXED,
        SWEEP_INSIDE,
        PUSH_LEG_PUSH
    }

    /// @notice One swap of a PLAN: exact input `amount` of the input side of `zeroForOne` on `key`, fully settled.
    struct Step {
        PoolKey key;
        bool zeroForOne;
        uint256 amount;
    }

    error Boom();

    uint160 internal constant MIN_PRICE = 4295128740;
    uint160 internal constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;
    IPoolManager public immutable manager;
    address public root;
    Mode public mode;
    uint256 public amount;
    uint256 public calls;
    uint256 public lastLegOut;
    uint256[] public legOuts;
    PoolKey internal _other;
    address internal _rules;
    bytes public lastLegError;
    /// @notice The partner rate this executor reports: WTH's 2,500, the share the fixture's lane opens at.
    uint16 public partnerBps = 2_500;
    /// @notice PUSH_NET and PLAN: the share of the profit the executor keeps for the partner before pushing the rest:
    ///         WTH's 2,500 unless a suite sets another.
    uint16 public keepBps = 2_500;
    /// @notice MIXED: when nonzero, after both pushes the executor burns gas until at most this much is left.
    uint256 public leaveGas;
    Step[] internal _plan;
    /// @notice PLAN: revert the whole call on the first refused step (true), or record it and go on (false).
    bool public planStrict;
    /// @notice PLAN: leave a one-unit open delta in `planLeaveDelta` after the steps.
    bool public planLeave;
    Currency public planLeaveDelta;
    /// @notice PLAN: output of each step (zero for a refused one) and the revert data of each refused step.
    uint256[] public planOuts;
    bytes[] public planErrors;
    /// @notice Pushes go in `pushAs` instead of the pool's quote once `setPushCurrency` was called.
    Currency public pushAs;
    bool public pushAsSet;
    /// @notice SWEEP_INSIDE: the revert data of the sweep it tried inside the frame.
    bytes public lastSweepError;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function setRoot(address r) external {
        root = r;
    }

    function set(Mode m, uint256 a) external {
        mode = m;
        amount = a;
    }

    function setPartnerBps(uint16 bps) external {
        partnerBps = bps;
    }

    function setKeepBps(uint16 bps) external {
        keepBps = bps;
    }

    function setLeaveGas(uint256 g) external {
        leaveGas = g;
    }

    function setOther(PoolKey calldata k) external {
        _other = k;
    }

    function setPushCurrency(Currency c) external {
        pushAs = c;
        pushAsSet = true;
    }

    function setRules(address rules) external {
        _rules = rules;
    }

    function setPlan(Step[] calldata steps, bool strict, bool leave, Currency leaveDelta) external {
        delete _plan;
        for (uint256 i; i < steps.length; ++i) {
            _plan.push(steps[i]);
        }
        planStrict = strict;
        planLeave = leave;
        planLeaveDelta = leaveDelta;
    }

    function planErrorCount() external view returns (uint256) {
        return planErrors.length;
    }

    function clearPlanRecord() external {
        delete planOuts;
        delete planErrors;
    }

    function executeArbitrage(PoolKey calldata key, address) external returns (uint256) {
        require(msg.sender == root, "root");
        calls++;
        HookrTypes.PoolConfig memory pc = IHookrRoot(root).poolConfig(key.toId());
        Mode m = mode;
        uint256 a = amount;
        if (m == Mode.PUSH) {
            _push(key, pc.quote, a);
            return a;
        }
        if (m == Mode.REVERT) revert Boom();
        if (m == Mode.STRAY_MINT) {
            // Mints twice what it pushes: the rest would strand at the root.
            Currency c = pushAsSet ? pushAs : pc.quote;
            _fund(c, 2 * a);
            manager.mint(root, c.toId(), 2 * a);
            IHookrLaneRoot(root).settleRecapture(key, c, a);
            return a;
        }
        if (m == Mode.MIXED) {
            // A push in the quote, then one in `pushAs`.
            _fund(pc.quote, a);
            manager.mint(root, pc.quote.toId(), a);
            IHookrLaneRoot(root).settleRecapture(key, pc.quote, a);
            _fund(pushAs, a);
            manager.mint(root, pushAs.toId(), a);
            IHookrLaneRoot(root).settleRecapture(key, pushAs, a);
            uint256 leave = leaveGas;
            if (leave != 0) {
                while (gasleft() > leave) {}
            }
            return a;
        }
        if (m == Mode.PUSH_LEG_PUSH) {
            // A push after each cycle: push, leg the pool, push again.
            _push(key, pc.quote, a);
            _tryLeg(key, a, true);
            _push(key, pc.quote, a);
            return 2 * a;
        }
        if (m == Mode.SWEEP_INSIDE) {
            try IHookrLaneRoot(root).sweepClaims(key.toId(), pc.quote) {}
            catch (bytes memory e) {
                lastSweepError = e;
            }
            _push(key, pc.quote, a);
            return a;
        }
        if (m == Mode.LEAVE_DELTA) {
            manager.take(pc.quote, address(this), 1);
            return 0;
        }
        if (m == Mode.LEAVE_SYNC) {
            manager.sync(pc.subject);
            return 0;
        }
        if (m == Mode.BURN_GAS) {
            uint256 i;
            while (true) {
                unchecked {
                    ++i;
                }
            }
        }
        if (m == Mode.SINK_UNBACKED) {
            IHookrLaneRoot(root).settleRecapture(key, pc.quote, a);
            return a;
        }
        if (m == Mode.SINK_SWALLOW) {
            try IHookrLaneRoot(root).settleRecapture(key, pc.quote, a) {} catch {}
            return a;
        }
        if (m == Mode.SINK_TWICE) {
            _push(key, pc.quote, a);
            _push(key, pc.quote, a);
            return 2 * a;
        }
        if (m == Mode.SINK_WRONG_POOL) {
            _fund(pc.quote, a);
            manager.mint(root, pc.quote.toId(), a);
            IHookrLaneRoot(root).settleRecapture(_other, pc.quote, a);
            return a;
        }
        if (m == Mode.LEG_OTHER_POOL) {
            _leg(_other, a);
            return 0;
        }
        if (m == Mode.LEG_SAME_POOL) {
            _leg(key, a);
            return 0;
        }
        if (m == Mode.BAD_RETURN) {
            assembly ("memory-safe") {
                mstore(0, 1)
                mstore(32, 2)
                return(0, 64)
            }
        }
        if (m == Mode.GIFT_ROOT) {
            manager.settleFor{value: a}(root);
            return 0;
        }
        if (m == Mode.PUSH_THEN_LEG) {
            _push(key, pc.quote, a);
            _tryLeg(key, a, true);
            return a;
        }
        if (m == Mode.LEG_BOTH_WAYS) {
            _leg(key, a);
            _tryLeg(key, lastLegOut, false);
            return 0;
        }
        if (m == Mode.PUSH_THEN_LEAVE_DELTA) {
            _push(key, pc.quote, a);
            manager.take(pc.quote, address(this), 1);
            return a;
        }
        if (m == Mode.SKIM) {
            _push(key, pc.quote, a / 2);
            return a;
        }
        if (m == Mode.PUSH_NET) {
            _push(key, pc.quote, a - a * keepBps / 10_000);
            return a;
        }
        if (m == Mode.LEG_OTHER_THEN_PUSH) {
            _leg(_other, a);
            _push(key, pc.quote, a);
            return a;
        }
        if (m == Mode.PLAN) {
            for (uint256 i; i < _plan.length; ++i) {
                Step memory st = _plan[i];
                if (planStrict) {
                    planOuts.push(_swap(st.key, st.zeroForOne, st.amount));
                } else {
                    try this.planStep(st.key, st.zeroForOne, st.amount) returns (uint256 out) {
                        planOuts.push(out);
                    } catch (bytes memory reason) {
                        planOuts.push(0);
                        planErrors.push(reason);
                    }
                }
            }
            if (planLeave) manager.take(planLeaveDelta, address(this), 1);
            if (a != 0) _push(key, pc.quote, a - a * keepBps / 10_000);
            return a;
        }
        if (m == Mode.SETTLE_EPOCH) {
            (bool ok,) = _rules.call(abi.encodeWithSignature("settleEpoch(bytes32)", key.toId()));
            ok;
            return 0;
        }
        return 0;
    }

    function checkV3PoolsMev(address, address, address, bool) external pure returns (bool) {
        return false;
    }

    /// @notice Swaps as an ordinary PoolManager caller, outside any arb recapture.
    function outsideSwap(PoolKey calldata key, uint256 a) external returns (uint256) {
        manager.unlock(abi.encode(key, a));
        return lastLegOut;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        (PoolKey memory key, uint256 a) = abi.decode(data, (PoolKey, uint256));
        _leg(key, a);
        return "";
    }

    /// @notice One PLAN step as its own call, so a refused step unwinds alone. Only this contract.
    function planStep(PoolKey calldata key, bool zeroForOne, uint256 a) external returns (uint256) {
        require(msg.sender == address(this), "self");
        return _swap(key, zeroForOne, a);
    }

    /// @dev Exact-input swap of `a` on `key` in direction `zeroForOne`, fully settled; returns the output.
    function _swap(PoolKey memory key, bool zeroForOne, uint256 a) internal returns (uint256 got) {
        BalanceDelta d =
            manager.swap(key, SwapParams(zeroForOne, -int256(a), zeroForOne ? MIN_PRICE + 1 : MAX_PRICE - 1), "");
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        (int128 pin, int128 pout) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        _fund(cin, uint256(uint128(-pin)));
        got = uint256(uint128(pout));
        manager.take(cout, address(this), got);
    }

    /// @dev A leg that may be refused: records the PoolManager's revert data instead of reverting.
    function _tryLeg(PoolKey memory key, uint256 a, bool zeroForOne) internal {
        try manager.swap(
            key, SwapParams(zeroForOne, -int256(a), zeroForOne ? MIN_PRICE + 1 : MAX_PRICE - 1), ""
        ) returns (
            BalanceDelta d
        ) {
            (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
            (int128 pin, int128 pout) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
            _fund(cin, uint256(uint128(-pin)));
            manager.take(cout, address(this), uint256(uint128(pout)));
        } catch (bytes memory reason) {
            lastLegError = reason;
        }
    }

    /// @dev Exact-input swap of `a` currency0 for currency1, fully settled.
    function _leg(PoolKey memory key, uint256 a) internal {
        BalanceDelta d = manager.swap(key, SwapParams(true, -int256(a), MIN_PRICE + 1), "");
        uint256 paid = uint256(uint128(-d.amount0()));
        uint256 got = uint256(uint128(d.amount1()));
        _fund(key.currency0, paid);
        manager.take(key.currency1, address(this), got);
        lastLegOut = got;
        legOuts.push(got);
    }

    function _fund(Currency c, uint256 a) internal {
        if (c.isAddressZero()) {
            manager.settle{value: a}();
        } else {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(manager), a);
            manager.settle();
        }
    }

    function _push(PoolKey calldata key, Currency quote, uint256 a) internal {
        if (pushAsSet) quote = pushAs;
        _fund(quote, a);
        manager.mint(root, quote.toId(), a);
        IHookrLaneRoot(root).settleRecapture(key, quote, a);
    }

    receive() external payable {}
}
