// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {IHookrRules} from "hookr/interfaces/IHookrRules.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {HookrRouter} from "hookr/periphery/HookrRouter.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {ZapRelayTypes} from "zap-relay/types/ZapRelayTypes.sol";
import {IZapRulesProtocol} from "zap-relay/interfaces/IZapRulesProtocol.sol";
import {ZapMeshTypes} from "./types/ZapMeshTypes.sol";
import {IHookrZapMeshVault} from "./interfaces/IHookrZapMeshVault.sol";
import {IHookrZapMeshAccrual} from "./interfaces/IHookrZapMeshAccrual.sol";
import {IZapMeshLeg} from "./interfaces/IZapMeshLeg.sol";

/// @notice The deployer that creates a mesh: it names the accrual the mesh belongs to and the leg deployer whose
///         CREATE2 addresses the mesh's legs take.
interface IZapMeshDeployerView {
    function accrual() external view returns (address);
    function legDeployer() external view returns (address);
}

/// @notice The leg deployer's address prediction.
interface IZapMeshLegPredict {
    function predict(address mesh, uint8 index) external view returns (address);
}

/// @title Hookr zap mesh vault
/// @notice Many-to-many Zap Relay. Source pools credit a frozen buy cut to this mesh as a HookrRules claim; anyone may
///         call zap() to claim it and spend it on buys of up to four gated target pools, one leg per target. With
///         SPLIT_WEIGHTS every zap splits its budget across the routes that can still buy, by weight. With
///         SPLIT_FILL_GAP every zap sends its budget to the one route whose target's quote depth sits furthest below
///         its weight, so buy flow becomes depth where the family is thin. A route counts as thin only if it was thin
///         in the newest snapshot from an earlier block and is thin now (each route is judged on the larger of the
///         two), so moving depth inside the zap's own transaction steers nothing. A target with no quote depth is
///         never chosen, and whatever the chosen route fails to spend goes to the other routes by weight in the same
///         zap.
/// @dev No owner, no admin, no rescue: every parameter is immutable. Each target's gate is the deployed
///      HookrGatedRelay, which admits a leg as a feeder because this mesh's accrual records it (`vaultRecord`) and is
///      admitted on the root with the zap accrual's schema; each leg keeps the zap vault's impact window. What the
///      caller passes steers no funds: only the reward recipient, paid rewardBps of the quote the zap deployed. Hookr's
///      share (protocolShareBps, at least the 2,000 bps release floor) is set aside on every source cut the mesh claims
///      and on any leg credit that was not that leg's own refund, and paid to the Rules' protocol recipient by the
///      permissionless payProtocol(). A route whose leg fails keeps its quote idle and never blocks the others. Every
///      leg run gets exactly LEG_GAS, and a zap reverts rather than start a run it cannot give that much, so the
///      caller's gas limit never decides which routes run. The mesh accepts plain native sends (a token-quoted mesh
///      counts any balance anyway), so it can be named as a royalty payee or tax recipient; such quote spends like a
///      source cut but carries no protocol share: a share-free funding path, by design.
contract HookrZapMeshVault is HookrReleased, IHookrZapMeshVault {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Same bounds as the zap vault (HookrZapVault).
    uint16 public constant MIN_IMPACT_BPS = 1;
    uint16 public constant MAX_IMPACT_BPS = 2_000;
    uint16 public constant DEFAULT_IMPACT_BPS = 500;
    uint16 public constant MAX_REWARD_BPS = 100;
    uint16 public constant DEFAULT_REWARD_BPS = 50;
    uint128 public constant MIN_THRESHOLD = 1_000;
    uint32 public constant MIN_WINDOW_BLOCKS = 1;
    uint32 public constant MAX_WINDOW_BLOCKS = 300;
    uint32 public constant DEFAULT_WINDOW_BLOCKS = 1;
    uint8 public constant DEFAULT_WINDOW_SCOPE = ZapRelayTypes.WINDOW_POOL_WIDE;
    uint8 public constant DEFAULT_SPLIT = ZapMeshTypes.SPLIT_WEIGHTS;
    /// @notice Gas every leg run is given, exactly: about twice the heaviest cold run measured (716,362: buy and add
    ///         with an ERC-20 quote on a dynamic-fee target behind a tiered gate, its first swap and first add).
    uint256 public constant LEG_GAS = 1_400_000;

    uint256 private constant BPS = 10_000;
    /// @dev Least gas left before a run: LEG_GAS forwarded whole under EIP-150's 63/64 rule, plus the call's own cost.
    uint256 private constant RUN_FLOOR = LEG_GAS * 64 / 63 + 20_000;
    uint8 private constant IDLE = 1;
    uint8 private constant BUSY = 2;

    /// @inheritdoc IHookrZapMeshVault
    address public immutable factory;
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrZapMeshVault
    address public immutable rules;
    /// @inheritdoc IHookrZapMeshVault
    address public immutable router;
    /// @inheritdoc IHookrZapMeshVault
    address public immutable root;
    /// @inheritdoc IHookrZapMeshVault
    address public immutable gate;
    /// @inheritdoc IHookrZapMeshVault
    address public immutable sink;
    /// @inheritdoc IHookrZapMeshVault
    Currency public immutable quote;
    /// @inheritdoc IHookrZapMeshVault
    uint8 public immutable mode;
    /// @inheritdoc IHookrZapMeshVault
    uint8 public immutable split;
    /// @inheritdoc IHookrZapMeshVault
    uint16 public immutable impactBps;
    /// @inheritdoc IHookrZapMeshVault
    uint16 public immutable rewardBps;
    /// @inheritdoc IHookrZapMeshVault
    uint128 public immutable threshold;
    /// @inheritdoc IHookrZapMeshVault
    uint128 public immutable maxPerZap;
    /// @inheritdoc IHookrZapMeshVault
    uint32 public immutable windowBlocks;
    /// @inheritdoc IHookrZapMeshVault
    uint8 public immutable windowScope;
    /// @inheritdoc IHookrZapMeshVault
    uint16 public immutable protocolShareBps;
    /// @inheritdoc IHookrZapMeshVault
    address public immutable protocolRecipient;
    /// @inheritdoc IHookrZapMeshVault
    uint256 public immutable routeCount;

    address private immutable _leg0;
    address private immutable _leg1;
    address private immutable _leg2;
    address private immutable _leg3;
    /// @dev The four weights packed 16 bits each, route 0 lowest.
    uint64 private immutable _weights;

    uint8 private _lock = IDLE;
    /// @dev Quote set aside for protocolRecipient.
    uint128 private _protocolOwed;
    /// @dev Two depth snapshots and the blocks they were taken in. A record overwrites the older one, so the newest
    ///      snapshot from an earlier block survives any record made in the current block.
    uint64[2] private _depthBlocks;
    uint256[4][2] private _depths;
    PoolKey[4] private _targets;

    /// @param m The mesh. Deployed only through HookrZapMeshAccrual.createMesh (by the accrual's ZapMeshDeployer), which
    ///        deploys the legs right after at the addresses predicted here and records them for the gate.
    constructor(ZapMeshTypes.Mesh memory m) {
        IZapMeshDeployerView deployer = IZapMeshDeployerView(msg.sender);
        factory = deployer.accrual();
        (IPoolManager manager, address pinnedRouter) = _validate(m);
        poolManager = manager;
        rules = m.rules;
        router = pinnedRouter;
        root = address(m.targets[0].hooks);
        gate = m.gate;
        sink = m.sink;
        quote = m.quote;
        mode = m.mode;
        split = m.split;
        impactBps = m.impactBps;
        rewardBps = m.rewardBps;
        threshold = m.threshold;
        maxPerZap = m.maxPerZap;
        windowBlocks = m.windowBlocks;
        windowScope = m.windowScope;
        uint16 share = IHookrZapMeshAccrual(factory).protocolShareBps();
        uint16 floor = IZapRulesProtocol(m.rules).minProtocolShareBps();
        protocolShareBps = share > floor ? share : floor;
        protocolRecipient = IZapRulesProtocol(m.rules).protocolRecipient();
        if (protocolRecipient == address(0) || protocolRecipient == address(this)) revert InvalidMesh(13);
        uint256 n = m.targets.length;
        routeCount = n;
        IZapMeshLegPredict legs_ = IZapMeshLegPredict(deployer.legDeployer());
        address[4] memory l;
        uint64 packed;
        for (uint256 i; i < n; ++i) {
            _targets[i] = m.targets[i];
            // i < MAX_ROUTES (4), checked in _validate.
            // forge-lint: disable-next-line(unsafe-typecast)
            l[i] = legs_.predict(address(this), uint8(i));
            if (l[i] == m.sink) revert InvalidMesh(7);
            packed |= uint64(uint256(m.weights[i]) << (16 * i));
        }
        (_leg0, _leg1, _leg2, _leg3) = (l[0], l[1], l[2], l[3]);
        _weights = packed;
    }

    /// @dev Mesh checks, run once in the constructor. Codes: 1 missing code; 2 root/Rules/PoolManager mismatch or
    ///      unregistered root; 3 not a Hookr dynamic-fee key, a second root, or a repeated target; 4 quote not a side of
    ///      a target; 5 gate schema; 6 router; 7 sink for the mode; 8 impact; 9 reward; 10 threshold/maxPerZap; 11 window
    ///      length; 12 window scope; 13 the Rules' protocol recipient (checked in the constructor); 14 route count or
    ///      weights; 15 split.
    function _validate(ZapMeshTypes.Mesh memory m) private view returns (IPoolManager manager, address pinnedRouter) {
        uint256 n = m.targets.length;
        if (n == 0 || n > ZapMeshTypes.MAX_ROUTES || m.weights.length != n) revert InvalidMesh(14);
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            if (m.weights[i] == 0) revert InvalidMesh(14);
            sum += m.weights[i];
        }
        if (sum != BPS) revert InvalidMesh(14);
        address rootAddress = address(m.targets[0].hooks);
        if (rootAddress.code.length == 0 || m.rules.code.length == 0 || m.gate.code.length == 0) revert InvalidMesh(1);
        manager = IHookrRoot(rootAddress).poolManager();
        if (
            !IHookrRoot(rootAddress).registry().isRoot(rootAddress) || IHookrRules(m.rules).trustedRoot() != rootAddress
                || address(IHookrRules(m.rules).poolManager()) != address(manager)
        ) revert InvalidMesh(2);
        for (uint256 i; i < n; ++i) {
            PoolKey memory t = m.targets[i];
            if (
                address(t.hooks) != rootAddress || t.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG
                    || t.tickSpacing < TickMath.MIN_TICK_SPACING || t.tickSpacing > TickMath.MAX_TICK_SPACING
                    || Currency.unwrap(t.currency0) >= Currency.unwrap(t.currency1)
            ) revert InvalidMesh(3);
            if (
                Currency.unwrap(m.quote) != Currency.unwrap(t.currency0)
                    && Currency.unwrap(m.quote) != Currency.unwrap(t.currency1)
            ) revert InvalidMesh(4);
            PoolId id = t.toId();
            for (uint256 j; j < i; ++j) {
                if (PoolId.unwrap(m.targets[j].toId()) == PoolId.unwrap(id)) revert InvalidMesh(3);
            }
        }
        if (IHookrAdvisory(m.gate).configSchemaHash() != ZapRelayTypes.GATE_SCHEMA) revert InvalidMesh(5);
        pinnedRouter = IHookrRoot(rootAddress).router();
        if (pinnedRouter.code.length == 0) revert InvalidMesh(6);
        if (m.mode == ZapRelayTypes.MODE_BUY) {
            if (
                m.sink == address(0) || m.sink == address(this) || m.sink == pinnedRouter || m.sink == address(manager)
                    || m.sink == HookrRouter(payable(pinnedRouter)).forwarder()
            ) revert InvalidMesh(7);
        } else if (m.mode != ZapRelayTypes.MODE_BUY_AND_ADD || m.sink != address(0)) {
            revert InvalidMesh(7);
        }
        if (m.impactBps < MIN_IMPACT_BPS || m.impactBps > MAX_IMPACT_BPS) revert InvalidMesh(8);
        if (m.rewardBps > MAX_REWARD_BPS) revert InvalidMesh(9);
        if (m.threshold < MIN_THRESHOLD || (m.maxPerZap != 0 && m.maxPerZap < m.threshold)) revert InvalidMesh(10);
        if (m.windowBlocks < MIN_WINDOW_BLOCKS || m.windowBlocks > MAX_WINDOW_BLOCKS) revert InvalidMesh(11);
        if (m.windowScope > ZapRelayTypes.WINDOW_POOL_WIDE) revert InvalidMesh(12);
        if (m.split > ZapMeshTypes.SPLIT_FILL_GAP) revert InvalidMesh(15);
    }

    // ---------------------------------------------------------------- views

    /// @inheritdoc IHookrZapMeshVault
    function route(uint256 i) public view returns (address leg, uint16 weight, PoolId target, PoolKey memory key) {
        if (i >= routeCount) revert InvalidMesh(14);
        key = _targets[i];
        return (_leg(i), _weight(i), key.toId(), key);
    }

    /// @inheritdoc IHookrZapMeshVault
    function legs() external view returns (address[] memory list) {
        list = new address[](routeCount);
        for (uint256 i; i < routeCount; ++i) {
            list[i] = _leg(i);
        }
    }

    /// @inheritdoc IHookrZapMeshVault
    function legSpec(uint256 i) external view returns (ZapMeshTypes.LegSpec memory) {
        if (i >= routeCount) revert InvalidMesh(14);
        return ZapMeshTypes.LegSpec({
            target: _targets[i],
            quote: quote,
            rules: rules,
            gate: gate,
            router: router,
            sink: sink,
            mode: mode,
            impactBps: impactBps,
            windowBlocks: windowBlocks,
            windowScope: windowScope
        });
    }

    /// @inheritdoc IHookrZapMeshVault
    function depthSnapshot() external view returns (uint64 blockNumber, uint256[4] memory snapshot) {
        (bool has, uint256 k) = _earlier();
        if (has) return (_depthBlocks[k], _depths[k]);
    }

    /// @inheritdoc IHookrZapMeshVault
    function depths() public view returns (uint256[4] memory d) {
        for (uint256 i; i < routeCount; ++i) {
            d[i] = _depth(i);
        }
    }

    /// @inheritdoc IHookrZapMeshVault
    function protocolOwed() external view returns (uint256) {
        return _protocolOwed;
    }

    /// @inheritdoc IHookrZapMeshVault
    function pending() external view returns (uint256 claimable, uint256 legClaims, uint256 idleQuote) {
        claimable = IHookrRules(rules).claimable(quote, address(this));
        legClaims = _legClaims();
        idleQuote = _idle();
    }

    /// @inheritdoc IHookrZapMeshVault
    function ready() external view returns (bool) {
        if (_lock != IDLE) return false;
        bool gap = split == ZapMeshTypes.SPLIT_FILL_GAP;
        bool any;
        for (uint256 i; i < routeCount; ++i) {
            if (IZapMeshLeg(_leg(i)).impactLeft() && (!gap || _depth(i) != 0)) {
                any = true;
                break;
            }
        }
        if (!any) return false;
        return IHookrRules(rules).claimable(quote, address(this)) + _legClaims() + _idle() >= threshold;
    }

    /// @inheritdoc IHookrZapMeshVault
    function routeLive() external view returns (bool) {
        for (uint256 i; i < routeCount; ++i) {
            if (IZapMeshLeg(_leg(i)).routeLive()) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- actions

    /// @inheritdoc IHookrZapMeshVault
    function recordDepths() external returns (bool recorded) {
        if (_lock != IDLE) revert Reentered();
        return _record(depths());
    }

    /// @dev Records `d` once per block, over the older of the two snapshots.
    function _record(uint256[4] memory d) private returns (bool) {
        uint64 b0 = _depthBlocks[0];
        uint64 b1 = _depthBlocks[1];
        if (b0 == block.number || b1 == block.number) return false;
        uint256 k = b0 <= b1 ? 0 : 1;
        _depths[k] = d;
        // block.number fits uint64 for the life of any chain.
        // forge-lint: disable-next-line(unsafe-typecast)
        _depthBlocks[k] = uint64(block.number);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit DepthsRecorded(uint64(block.number), d);
        return true;
    }

    /// @dev The newest snapshot taken in a block before this one, if there is one.
    function _earlier() private view returns (bool has, uint256 k) {
        uint64 b0 = _depthBlocks[0];
        uint64 b1 = _depthBlocks[1];
        if (b0 >= block.number) b0 = 0;
        if (b1 >= block.number) b1 = 0;
        return (b0 != 0 || b1 != 0, b1 > b0 ? 1 : 0);
    }

    /// @inheritdoc IHookrZapMeshVault
    /// @dev Pull, not push: a recipient that refuses the transfer fails only this call, never a zap.
    function payProtocol() external returns (uint256 amount) {
        if (_lock != IDLE) revert Reentered();
        amount = _protocolOwed;
        if (amount == 0) return 0;
        _lock = BUSY;
        _protocolOwed = 0;
        HookrSettlement.send(quote, protocolRecipient, amount);
        emit ProtocolPaid(protocolRecipient, amount);
        _lock = IDLE;
    }

    /// @inheritdoc IHookrZapMeshVault
    /// @dev Order: live routes, depth record (SPLIT_FILL_GAP, before any call that pays anyone), threshold, the legs'
    ///      claims pulled, the mesh's claim, protocol set-aside, cap, reward hold-back, allocation, one run per route
    ///      (each isolated: a failing leg keeps its quote here; under SPLIT_FILL_GAP what the chosen route leaves goes
    ///      to the other open routes by weight), reward. The reward is rewardBps of the quote deployed, never of the
    ///      unspent balance, and goes out last.
    function zap(address rewardTo) external returns (ZapMeshTypes.ZapResult memory z) {
        if (_lock != IDLE) revert Reentered();
        _lock = BUSY;
        if (rewardBps != 0 && (rewardTo == address(0) || rewardTo == address(this))) {
            revert InvalidRewardRecipient(rewardTo);
        }
        uint256 n = routeCount;
        uint256 live;
        for (uint256 i; i < n; ++i) {
            if (IZapMeshLeg(_leg(i)).routeLive()) live |= _bit(i);
        }
        if (live == 0) revert NoLiveRoute();
        bool gap = split == ZapMeshTypes.SPLIT_FILL_GAP;
        uint256[4] memory d;
        if (gap) {
            d = depths();
            _record(d);
        }

        uint256 claimable = IHookrRules(rules).claimable(quote, address(this));
        uint256 available = claimable + _legClaims() + _idle();
        if (available < threshold) revert BelowThreshold(available, threshold);
        for (uint256 i; i < n; ++i) {
            uint256 held = HookrSettlement.balance(quote, address(this));
            (uint256 amount, uint256 extra) = IZapMeshLeg(_leg(i)).pull();
            if (amount == 0) continue;
            if (HookrSettlement.balance(quote, address(this)) < held + amount) revert BalanceMismatch();
            z.pulled += amount;
            z.protocolShare += extra * protocolShareBps / BPS;
        }
        if (claimable != 0) {
            uint256 held = HookrSettlement.balance(quote, address(this));
            z.claimed = IHookrRules(rules).claim(quote);
            if (HookrSettlement.balance(quote, address(this)) < held + z.claimed) revert BalanceMismatch();
            z.protocolShare += z.claimed * protocolShareBps / BPS;
        }
        // The share is at most half of quote the mesh now holds, a Rules balance of one currency.
        // forge-lint: disable-next-line(unsafe-typecast)
        _protocolOwed += uint128(z.protocolShare);

        uint256 amount_ = _idle();
        if (maxPerZap != 0 && amount_ > maxPerZap) amount_ = maxPerZap;
        z.consumed = amount_;
        // Hold back the largest reward this zap could owe: budget * (1 + rewardBps / BPS) <= amount.
        uint256 budget = amount_ * BPS / (BPS + rewardBps);

        // Open: live, room left in the impact window and, under SPLIT_FILL_GAP, quote depth to buy against.
        uint256 open;
        for (uint256 i; i < n; ++i) {
            if (live & _bit(i) != 0 && (!gap || d[i] != 0) && IZapMeshLeg(_leg(i)).impactLeft()) open |= _bit(i);
        }
        if (open == 0) revert NoRouteCanBuy();

        bool native = quote.isAddressZero();
        (bool chosen, uint256 best) = gap ? _gapRoute(open, d) : (false, 0);
        if (chosen) {
            z.allocated[best] = budget;
            uint256 rest = _run(z, best, budget, native);
            open &= ~_bit(best);
            if (rest != 0 && open != 0) _runEach(z, _byWeight(rest, open), native);
        } else {
            _runEach(z, _byWeight(budget, open), native);
        }
        if (z.deployed == 0) revert NothingDeployed();
        // deployed <= the quote the routes used <= budget, so the reward never exceeds the quote held back for it.
        z.reward = z.deployed * rewardBps / BPS;
        if (z.reward != 0) HookrSettlement.send(quote, rewardTo, z.reward);

        emit MeshZapped(msg.sender, rewardTo, z);
        _lock = IDLE;
    }

    /// @notice Accepts native from anyone: claims and leg returns mid-zap, and plain sends from a royalty or tax that
    ///         names this mesh, which count toward the next zap. Writes nothing.
    receive() external payable {}

    // ---------------------------------------------------------------- internals

    /// @dev The SPLIT_FILL_GAP choice among the routes in `open`: the one furthest below its weight's share of their
    ///      quote depth, each judged on the larger of its depth in the newest snapshot from an earlier block and its
    ///      depth `now`. None (split by weight) before the first such snapshot.
    function _gapRoute(uint256 open, uint256[4] memory now_) private view returns (bool chosen, uint256 best) {
        (bool has, uint256 k) = _earlier();
        if (!has) return (false, 0);
        uint256 n = routeCount;
        uint256[4] memory d;
        uint256 total;
        uint256 weightSum;
        for (uint256 i; i < n; ++i) {
            if (open & _bit(i) == 0) continue;
            uint256 snap = _depths[k][i];
            d[i] = snap > now_[i] ? snap : now_[i];
            total += d[i];
            weightSum += _weight(i);
        }
        int256 bestGap;
        for (uint256 i; i < n; ++i) {
            if (open & _bit(i) == 0) continue;
            // How far route i sits below its weight's share of the open routes' depth, in depth x weight units. A
            // depth is at most 2^192 (L < 2^128 over a sqrt price of at least 2^32) and weights below 2^14, so these
            // fit.
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 gap = int256(total * _weight(i)) - int256(d[i] * weightSum);
            if (!chosen || gap > bestGap) {
                (chosen, best, bestGap) = (true, i, gap);
            }
        }
    }

    /// @dev Splits `amount` over the routes in `mask` by weight, the last of them taking the remainder.
    function _byWeight(uint256 amount, uint256 mask) private view returns (uint256[4] memory a) {
        uint256 n = routeCount;
        uint256 sum;
        uint256 last;
        for (uint256 i; i < n; ++i) {
            if (mask & _bit(i) != 0) {
                sum += _weight(i);
                last = i;
            }
        }
        uint256 given;
        for (uint256 i; i < n; ++i) {
            if (mask & _bit(i) == 0) continue;
            a[i] = i == last ? amount - given : amount * _weight(i) / sum;
            given += a[i];
        }
    }

    /// @dev Runs every route `a` hands quote to, in route order.
    function _runEach(ZapMeshTypes.ZapResult memory z, uint256[4] memory a, bool native) private {
        for (uint256 i; i < routeCount; ++i) {
            if (a[i] == 0) continue;
            z.allocated[i] += a[i];
            _run(z, i, a[i], native);
        }
    }

    /// @dev Runs route i's leg with `a` quote and exactly LEG_GAS, and counts what it deployed. Reverts GasTooLow
    ///      rather than start a run it cannot give LEG_GAS. Returns what the route left of `a`: all of it when the leg
    ///      failed (the quote stays here), what its buy could not spend when the buy stopped at the impact limit, and
    ///      zero otherwise.
    function _run(ZapMeshTypes.ZapResult memory z, uint256 i, uint256 a, bool native) private returns (uint256 rest) {
        address leg = _leg(i);
        if (!native) IERC20(Currency.unwrap(quote)).forceApprove(leg, a);
        uint256 left = gasleft();
        if (left < RUN_FLOOR) revert GasTooLow(RUN_FLOOR, left);
        try IZapMeshLeg(leg).run{value: native ? a : 0, gas: LEG_GAS}(a) returns (ZapMeshTypes.LegResult memory r) {
            // i < 4.
            // forge-lint: disable-next-line(unsafe-typecast)
            z.ran |= uint8(_bit(i));
            z.deployed += (r.spent > r.refund ? r.spent - r.refund : 0) + r.addedQuote;
            uint256 used = r.spent + r.addedQuote;
            if (r.spent < (mode == ZapRelayTypes.MODE_BUY_AND_ADD ? a / 2 : a) && used < a) rest = a - used;
        } catch (bytes memory reason) {
            // forge-lint: disable-next-line(unsafe-typecast)
            emit RouteSkipped(uint8(i), reason);
            rest = a;
        }
        if (!native) IERC20(Currency.unwrap(quote)).forceApprove(leg, 0);
    }

    /// @dev Route i's quote depth: the quote side of the target's in-range liquidity at its current price, as if that
    ///      liquidity were spread over the whole range (quote = L / sqrtP as currency0, L * sqrtP as currency1). Zero
    ///      for a target that does not exist yet.
    function _depth(uint256 i) private view returns (uint256) {
        PoolKey memory key = _targets[i];
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) return 0;
        uint128 liquidity = poolManager.getLiquidity(id);
        if (Currency.unwrap(quote) == Currency.unwrap(key.currency0)) {
            return FullMath.mulDiv(liquidity, FixedPoint96.Q96, sqrtPriceX96);
        }
        return FullMath.mulDiv(liquidity, sqrtPriceX96, FixedPoint96.Q96);
    }

    /// @dev Quote the legs hold as Rules claims (their refunds, and any other credit made to them).
    function _legClaims() private view returns (uint256 sum) {
        for (uint256 i; i < routeCount; ++i) {
            sum += IHookrRules(rules).claimable(quote, _leg(i));
        }
    }

    /// @dev Quote the mesh holds that a zap may spend: its balance less the protocol's set-aside.
    function _idle() private view returns (uint256) {
        return HookrSettlement.balance(quote, address(this)) - _protocolOwed;
    }

    function _leg(uint256 i) private view returns (address) {
        if (i == 0) return _leg0;
        if (i == 1) return _leg1;
        if (i == 2) return _leg2;
        return _leg3;
    }

    /// @dev Route i's bit in a route mask.
    function _bit(uint256 i) private pure returns (uint256) {
        return 2 ** i;
    }

    function _weight(uint256 i) private view returns (uint16) {
        // Masked to 16 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(_weights >> (16 * i));
    }
}
