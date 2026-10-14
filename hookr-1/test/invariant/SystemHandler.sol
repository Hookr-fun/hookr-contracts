// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrDynamicFee} from "../../src/libraries/HookrDynamicFee.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrPaymaster} from "../../src/interfaces/IHookrPaymaster.sol";
import {IHookrForwarder} from "../../src/interfaces/IHookrForwarder.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {IHookrSessionAdvisory} from "../../src/interfaces/IHookrSessionAdvisory.sol";
import {IHookrLiquidityVault} from "../../src/interfaces/IHookrLiquidityVault.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {PackedUserOperation} from "../../src/interfaces/external/PackedUserOperation.sol";
import {SystemDeploy} from "./SystemDeploy.sol";
import {SysLocker, SysAccount, ISysEntryPoint, ISysPermit2Domain, SysProbe} from "./SystemHelpers.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

/// @notice Handler for the system invariant campaign. Every entry point is one fuzzer call (one transaction under
///         --isolate). Bundles compose 2..8 operations inside that one transaction. Checks that need the call's own
///         logs or pre-state run here and count as violations; the test contract asserts the violation count and the
///         state invariants after every call.
contract SystemHandler is SystemDeploy {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant BPS = 10_000;
    /// @dev Root pools the campaign trades on; later dev-buy launches beyond this are tracked as families only.
    uint256 internal constant MAX_POOLS = 13;
    uint256 internal constant MAX_FAMILIES = 24;
    /// @dev Pools in Programs scopes: the six launched at deployment.
    uint256 internal constant SCOPED = 6;
    uint256 internal constant DEV_SUPPLY = 1e24;
    /// @dev HookrLauncher.MAX_DEV_BUY_LOCK_BLOCKS.
    uint32 internal constant MAX_LOCK = 2_628_000;

    // ───────────── violations and coverage ─────────────
    uint256 public violations;
    string[] internal _violationLog;
    mapping(bytes32 => uint256) public hits;
    bytes32[] internal _hitKeys;
    mapping(bytes32 => string) internal _labels;

    // ───────────── ledgers rebuilt from committed logs ─────────────
    mapping(address => mapping(address => uint256)) public ghostCredited; // rules => currency: HookFee earned + refund
    mapping(address => mapping(address => uint256)) public ghostClaimed; // rules => currency: Claimed
    mapping(address => mapping(address => uint256)) public ghostProtocolCredited; // rules => currency
    /// @dev rules => currency => integrator: IntegratorPaid credited, and Claimed by the integrator.
    mapping(address => mapping(address => mapping(address => uint256))) public ghostIntegratorCredited;
    mapping(address => mapping(address => mapping(address => uint256))) public ghostIntegratorClaimed;
    mapping(address => mapping(address => uint256)) public ghostCollected; // treasury source => currency
    mapping(address => uint256) public ghostVaultSkim; // currency: FeesRealized skims
    mapping(address => uint256) public ghostVaultPaid; // currency: ProtocolFeesPaid
    mapping(bytes32 => bool) internal _seenExecution;
    uint256 public executions;

    // ───────────── parties ─────────────
    address[] public beneficiaries;
    mapping(address => bool) internal _isBeneficiary;
    address[] internal _claimHolders;
    mapping(address => bool) internal _isClaimHolder;
    mapping(address => uint256) internal _fwdNonce;

    // ───────────── positions ─────────────
    struct Dust {
        bool pair;
        uint8 pool;
        int24 lower;
        int24 upper;
        uint128 liquidity;
        bytes32 salt;
    }

    Dust[] internal _dust;
    uint256 internal _dustSalt;

    struct Range {
        bool pair;
        uint8 pool;
        int24 lower;
        int24 upper;
        uint256 id;
    }

    Range[] internal _ranges;
    mapping(uint256 => Currency[2]) internal _rangeCurrencies;

    // ───────────── families ─────────────
    bytes32[] internal _families;
    mapping(bytes32 => uint256) public familyLock;
    uint256 public devLaunches;
    uint256 internal _tokenSalt;
    address[] internal _devSubjects;

    // ───────────── pool timing and the guard counter ─────────────
    mapping(uint256 => uint256) internal _guardWord; // pool index => (block << 192) | spent
    mapping(uint256 => uint256) internal _closedBlock; // pool index => parent block closed by a dev buy, plus one

    // ───────────── per-call scratch filled by _ingest ─────────────
    mapping(address => mapping(address => uint256)) internal _callProtocol; // rules => quote
    address[] internal _callRules;
    bool internal _feeTouched;
    bool internal _inDevBuy;
    /// @dev The running handler, prefixed to every violation.
    string internal _ctx;
    uint256 internal _callDevBuyLogs;
    uint256 internal _callLauncherSwaps;
    uint256 internal _lastSwapPool; // root pool index + 1 of the last real PoolManager Swap, 0 if none
    bool internal _lastSwapZeroForOne;
    int128 internal _lastSwap0;
    int128 internal _lastSwap1;
    uint256 internal _lastProtocol;
    uint256 internal _lastRoyalty;
    uint256 internal _lastRefund;
    uint256 internal _lastAdvisoryFee;
    /// @dev Hookr's whole part (protocol recipient and integrator) of the swap whose HookFee was just read, or
    ///      type(uint256).max when no FeesAllocated of that pool preceded it.
    uint256 internal _lastHookr;
    /// @dev The integrator's part of the swap whose FeesAllocated follows (IntegratorPaid comes first).
    uint256 internal _pendingIntegratorPart;
    bytes32 internal _lastId;
    uint256 internal _execPool; // root pool index + 1 of the last committed PoolManager Swap this call, 0 if none
    uint24 internal _execFee; // that Swap's fee, the protocol fee included

    // ───────────── counters ─────────────
    uint256 public quoteMismatchAfterTrigger;
    uint256 public postOpReverts;
    uint256 public rebatesPaid;
    uint256 public rebateOps;
    mapping(address => uint256) internal _rebateOf;
    uint256 public dynamicChecks;
    uint256 public anchorChecks;
    uint256 public lpFeeChecks;
    /// @dev Exact S1 and PR2 checks of swaps that paid a Uniswap protocol fee.
    uint256 public protocolFeeChecks;
    uint256 public guardBuys;
    uint256 public pairDeltaChecks;
    uint256 public vaultPrincipalChecks;

    bytes32 internal constant PM_SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant UOE =
        keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    bytes32 internal constant BEFORE_EXEC = keccak256("BeforeExecution()");
    bytes32 internal constant POSTOP_REVERT = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");
    bytes32 internal constant OP_REVERT_REASON = keccak256("UserOperationRevertReason(bytes32,address,uint256,bytes)");

    constructor() {
        _deploySystem();
        curated.setAdmin(address(this));
        generic.setAdmin(address(this));
        for (uint256 i; i < 4; ++i) {
            _addBeneficiary(actors[i]);
        }
        _addBeneficiary(ROYALTY_A);
        _addBeneficiary(ROYALTY_B);
        _addBeneficiary(INTEGRATOR_A);
        _addBeneficiary(INTEGRATOR_B);
        _addBeneficiary(INTEGRATOR_C);
        _addBeneficiary(address(treasury));
        _addBeneficiary(address(multicall));
        _addBeneficiary(address(acct0));
        _addBeneficiary(address(acct1));
        _addBeneficiary(address(curated));
        _addBeneficiary(address(generic));
        _addBeneficiary(address(this));
        Q.approve(address(generic), type(uint256).max);
        Q.approve(address(curated), type(uint256).max);
        SB.approve(address(generic), type(uint256).max);
        SB.approve(address(curated), type(uint256).max);
        vm.prank(actors[0]);
        SA.transfer(address(this), 1e26);
        SA.approve(address(generic), type(uint256).max);
        SA.approve(address(curated), type(uint256).max);
        _families.push(famA);
        _families.push(famB);
        _families.push(famC);
        _families.push(famD);
        _families.push(famE);
        familyLock[famA] = rules1.config(keys[0].toId()).guardEndBlock;
        familyLock[famB] = rules1.config(keys[3].toId()).guardEndBlock;
        familyLock[famE] = rules1.config(keys[6].toId()).guardEndBlock;
        _devSubjects.push(address(SE));
        // Standing third-party liquidity in both pair pools, and the vault's ranges.
        for (uint256 i; i < pairKeys.length; ++i) {
            _addDust(true, i, -6000, 6000, 1e21);
        }
        _openRange(false, 1, -600, 600);
        _openRange(false, 4, -1200, 1200);
        _openRange(false, 5, -3000, 3000);
        _openRange(true, 0, -6000, 6000);
        for (uint256 i; i < 4; ++i) {
            _vaultDeposit(i, i % _ranges.length, 1e19, 1e19);
        }
        vm.getRecordedLogs();
    }

    // ═════════════════════════════ bookkeeping ═════════════════════════════

    function _addBeneficiary(address b) internal {
        if (!_isBeneficiary[b]) {
            _isBeneficiary[b] = true;
            beneficiaries.push(b);
        }
    }

    function _addClaimHolder(address h) internal {
        if (!_isClaimHolder[h]) {
            _isClaimHolder[h] = true;
            _claimHolders.push(h);
        }
    }

    function integratorA() external pure returns (address) {
        return INTEGRATOR_A;
    }

    function integratorB() external pure returns (address) {
        return INTEGRATOR_B;
    }

    function integratorC() external pure returns (address) {
        return INTEGRATOR_C;
    }

    function beneficiaryCount() external view returns (uint256) {
        return beneficiaries.length;
    }

    function familyCount() external view returns (uint256) {
        return _families.length;
    }

    function family(uint256 i) external view returns (bytes32) {
        return _families[i];
    }

    function rangeCount() external view returns (uint256) {
        return _ranges.length;
    }

    function rangeAt(uint256 i) external view returns (Range memory) {
        return _ranges[i];
    }

    function rangeCurrencies(uint256 id) external view returns (Currency[2] memory) {
        return _rangeCurrencies[id];
    }

    function devSubjectCount() external view returns (uint256) {
        return _devSubjects.length;
    }

    function devSubject(uint256 i) external view returns (address) {
        return _devSubjects[i];
    }

    function violationLog() external view returns (string[] memory) {
        return _violationLog;
    }

    function _flag(string memory why) internal {
        ++violations;
        if (_violationLog.length < 40) _violationLog.push(string.concat("[", _ctx, "] ", why));
    }

    function _hit(string memory label) internal {
        bytes32 k = keccak256(bytes(label));
        if (hits[k] == 0) {
            _hitKeys.push(k);
            _labels[k] = label;
        }
        ++hits[k];
    }

    /// @dev Every handler reads its settings from a hash of its fuzzed seed. forge's dictionary feeds values whose high
    ///      bits are zero, which would otherwise pin every setting read from those bits.
    function _mix(uint256 seed, string memory tag) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, tag)));
    }

    /// @dev A swap amount: one in eight is 1 to 1,000 wei (the rounding edges), the rest 1e14 to `max`.
    function _swapAmount(uint256 s, uint256 max) internal returns (uint128) {
        if (s % 8 == 0) {
            _hit("swap.tinyAmount");
            return uint128(bound(s >> 3, 1, 1000));
        }
        return uint128(bound(s >> 3, 1e14, max));
    }

    function coverage() external view returns (string[] memory labels, uint256[] memory counts) {
        labels = new string[](_hitKeys.length);
        counts = new uint256[](_hitKeys.length);
        for (uint256 i; i < _hitKeys.length; ++i) {
            labels[i] = _labels[_hitKeys[i]];
            counts[i] = hits[_hitKeys[i]];
        }
    }

    /// @dev The reason inside the PoolManager's WrappedError (0x90bfb865) or the Quoter's SimulationFailed.
    function _inner(bytes memory err) internal pure returns (bytes memory) {
        if (err.length < 4) return err;
        bytes4 sel = bytes4(err);
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = err[i + 4];
        }
        if (sel == 0x90bfb865) {
            (,, bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
            return reason;
        }
        if (sel == 0x614cbd8a) return abi.decode(body, (bytes));
        return err;
    }

    function _hitErr(string memory label, bytes memory err) internal {
        bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
        string memory tag = vm.toString(abi.encodePacked(sel));
        if (sel == 0x90bfb865 || sel == 0x614cbd8a) {
            bytes memory inner = _inner(err);
            if (inner.length >= 4 && (bytes4(inner) == 0x90bfb865 || bytes4(inner) == 0x614cbd8a)) {
                inner = _inner(inner);
            }
            tag = string.concat(tag, "/", vm.toString(abi.encodePacked(inner.length >= 4 ? bytes4(inner) : bytes4(0))));
        }
        _hit(string.concat(label, ":", tag));
    }

    /// @dev A Rules module call fails only for the launch guard (exact-output buys, the per-block buy cap): a module
    ///      call that fails with a reason (ModuleCallReverted) or without one (ModuleCallFailed) outside it is flagged.
    function _rulesFailure(uint256 p, bytes memory err) internal {
        bytes memory inner = _inner(err);
        if (inner.length >= 4 && bytes4(inner) == 0x90bfb865) inner = _inner(inner);
        if (
            inner.length >= 4
                && (bytes4(inner) == IHookrRootEvents.ModuleCallFailed.selector
                    || bytes4(inner) == IHookrRootEvents.ModuleCallReverted.selector) && p < keys.length
                && vm.getBlockNumber() >= _guardEnd(p)
        ) {
            _flag("R1 Rules module call failed outside the launch guard");
        }
    }

    // ═════════════════════════════ pool helpers ═════════════════════════════

    function _root(uint256 p) internal view returns (HookrRoot) {
        return HookrRoot(address(keys[p].hooks));
    }

    function _rules(uint256 p) internal view returns (HookrRules) {
        return address(keys[p].hooks) == address(root1) ? rules1 : rules2;
    }

    function _rulesOfRoot(address r) internal view returns (HookrRules) {
        return r == address(root1) ? rules1 : rules2;
    }

    function _quoteOf(uint256 p) internal view returns (Currency) {
        return _root(p).poolConfig(keys[p].toId()).quote;
    }

    /// @dev The pool's base LP fee, as its root froze it at launch.
    function _base(uint256 p) internal view returns (uint256) {
        return _root(p).poolConfig(keys[p].toId()).baseLpFeePips;
    }

    function _guardEnd(uint256 p) internal view returns (uint256) {
        return _rules(p).config(keys[p].toId()).guardEndBlock;
    }

    function _guardOver(uint256 p) internal view returns (bool) {
        return vm.getBlockNumber() >= _guardEnd(p);
    }

    function _zeroForOne(uint256 p, bool buy) internal view returns (bool) {
        return (Currency.unwrap(_quoteOf(p)) == Currency.unwrap(keys[p].currency0)) == buy;
    }

    function _limit(PoolKey memory k, bool zeroForOne, bool isPartial) internal view returns (uint160) {
        if (!isPartial) return zeroForOne ? MIN_PRICE + 1 : MAX_PRICE - 1;
        (uint160 price,,,) = manager.getSlot0(k.toId());
        uint256 l = zeroForOne ? uint256(price) - price / 800 : uint256(price) + price / 800;
        if (l <= MIN_PRICE) l = MIN_PRICE + 1;
        if (l >= MAX_PRICE) l = MAX_PRICE - 1;
        return uint160(l);
    }

    function _params(uint256 p, bool buy, bool exactIn, uint128 amount, bool isPartial, address recipient)
        internal
        view
        returns (IHookrRouter.Swap memory s)
    {
        bool z = _zeroForOne(p, buy);
        s = IHookrRouter.Swap(
            keys[p],
            z,
            exactIn ? -int128(amount) : int128(amount),
            exactIn ? uint128(1) : uint128(amount) * 4 + 1e18,
            _limit(keys[p], z, isPartial),
            recipient,
            vm.getBlockTimestamp() + 100
        );
    }

    function _nativeIn(IHookrRouter.Swap memory s) internal pure returns (bool) {
        return Currency.unwrap(s.zeroForOne ? s.key.currency0 : s.key.currency1) == address(0);
    }

    function _maxIn(IHookrRouter.Swap memory s) internal pure returns (uint256) {
        return s.amountSpecified < 0 ? uint256(uint128(-s.amountSpecified)) : s.amountBound;
    }

    function _campaigns(bool on, uint256 p) internal view returns (address engagement, uint256[] memory ids) {
        if (!on || p >= SCOPED) return (address(0), new uint256[](0));
        IHookrPrograms.Program memory im = programs.program(immediateId);
        IHookrPrograms.Program memory d = programs.program(dailyId);
        bool immediateLive = block.timestamp >= im.terms.start && block.timestamp < im.terms.end;
        bool dailyLive = block.timestamp >= d.terms.start && block.timestamp < d.terms.end;
        uint256 n = (immediateLive ? 1 : 0) + (dailyLive ? 1 : 0);
        if (n == 0) return (address(0), new uint256[](0));
        ids = new uint256[](n);
        uint256 k;
        if (immediateLive) ids[k++] = immediateId;
        if (dailyLive) ids[k] = dailyId;
        engagement = address(programs);
    }

    function _poolIndex(bytes32 id) internal view returns (uint256) {
        for (uint256 i; i < keys.length; ++i) {
            if (PoolId.unwrap(keys[i].toId()) == id) return i;
        }
        return type(uint256).max;
    }

    function _pairIndex(bytes32 id) internal view returns (uint256) {
        for (uint256 i; i < pairKeys.length; ++i) {
            if (PoolId.unwrap(pairKeys[i].toId()) == id) return i;
        }
        return type(uint256).max;
    }

    function _band(PoolKey memory k, uint256 w) internal view returns (int24 lower, int24 upper) {
        (, int24 tick,,) = manager.getSlot0(k.toId());
        int24 spacing = k.tickSpacing;
        int24 base = tick >= 0 ? (tick / spacing) * spacing : ((tick - spacing + 1) / spacing) * spacing;
        lower = base - spacing * int24(int256(w));
        upper = base + spacing * int24(int256(w + 1));
        int24 minT = TickMath.minUsableTick(spacing);
        int24 maxT = TickMath.maxUsableTick(spacing);
        if (lower < minT) lower = minT;
        if (upper > maxT) upper = maxT;
    }

    /// @dev Root pools whose launch guard is over (third-party liquidity is refused during a guard), or pair pools.
    function _openPool(uint256 seed) internal view returns (bool pair, uint256 p) {
        if (seed % 3 == 0) return (true, (seed >> 2) % pairKeys.length);
        uint256 n = keys.length;
        uint256 start = (seed >> 2) % n;
        for (uint256 i; i < n; ++i) {
            uint256 c = (start + i) % n;
            if (_guardOver(c)) return (false, c);
        }
        return (true, (seed >> 2) % pairKeys.length);
    }

    function _anyKey(bool pair, uint256 p) internal view returns (PoolKey memory) {
        return pair ? pairKeys[p] : keys[p];
    }

    // ═════════════════════════════ fee arithmetic (frozen config) ═════════════════════════════

    /// @dev LP Rewards pips of a buy, net of the protocol share and the royalty.
    function _lpReward(HookrTypes.RulesConfig memory c) internal pure returns (uint256) {
        uint256 lpNet = uint256(c.lpBps) * 100 - (uint256(c.lpBps) * c.protocolShareBps + 99) / 100;
        return lpNet - lpNet * c.royaltyBps / BPS;
    }

    /// @dev Snipe pips at this block's timestamp, before clipping, as HookrRules decays it.
    function _snipeNow(HookrTypes.RulesConfig memory c, uint256 launchedAt) internal view returns (uint256) {
        uint256 start = c.snipeTaxPips;
        if (c.snipeDecaySeconds == 0) return start;
        uint256 elapsed;
        unchecked {
            elapsed = uint32(uint32(block.timestamp) - uint32(launchedAt));
        }
        if (elapsed > (type(uint32).max >> 1)) elapsed = 0;
        if (elapsed >= c.snipeDecaySeconds) return c.snipeFloorPips;
        return c.snipeFloorPips + (start - c.snipeFloorPips) * (c.snipeDecaySeconds - elapsed) / c.snipeDecaySeconds;
    }

    /// @dev The guard's per-parent-block buy cap now: maxBuyQuoteAmount, grown by snipeTaxPips / the decayed tax on a
    ///      decaying Snipe, and lifted (the counter's width) at a zero tax.
    function _capNow(uint256 p, HookrTypes.RulesConfig memory c) internal view returns (uint256 limit) {
        limit = c.maxBuyQuoteAmount;
        if (c.snipeDecaySeconds != 0) {
            uint256 snipe = _snipeNow(c, metas[p].launchedAt);
            limit = snipe == 0 ? type(uint192).max : limit * c.snipeTaxPips / snipe;
        }
    }

    /// @dev The native LP fee of a swap without its dynamic fee: base, LP Rewards on buys, Snipe on guarded buys,
    ///      less the protocol share of the Snipe, clipped as HookrRules clips.
    function _nativeFloor(uint256 p, bool buy) internal view returns (uint256) {
        HookrTypes.RulesConfig memory c = _rules(p).config(keys[p].toId());
        uint256 base = _base(p);
        uint256 lpReward = buy ? _lpReward(c) : 0;
        uint256 snipe;
        if (buy && vm.getBlockNumber() < c.guardEndBlock) snipe = _snipeNow(c, metas[p].launchedAt);
        uint256 room = 600_000 - base - lpReward;
        if (snipe > room) snipe = room;
        return base + lpReward + snipe - snipe * c.protocolShareBps / BPS;
    }

    /// @dev The advisory surcharge a swap in this direction pays now.
    function _advice(uint256 p, bool zeroForOne) internal view returns (uint256) {
        if (!metas[p].advised) return 0;
        PoolId id = keys[p].toId();
        address adv = _root(p).poolConfig(id).advisory;
        if (adv == address(feeAdvisory)) return feeAdvisory.surcharge(id, zeroForOne);
        return sessionAdvisory.surchargeAt(address(_root(p)), id, block.timestamp);
    }

    /// @dev Largest LP fee and quote take the pool's frozen configuration allows (HookrRules._validate's maxima), with
    ///      the Snipe only while the guard lasts, plus the advisory's admitted cap. While the guard lasts this is
    ///      _validate line for line, including its test for the jointly rounded share on the unclipped snipeTaxPips: a
    ///      clipped Snipe fills the room exactly, so testing the clipped one never took the joint share, one pip below
    ///      what a guarded buy with a clipped Snipe and no dynamic fee pays.
    function _maxima(uint256 p) internal view returns (uint256 maxLp, uint256 maxQuote) {
        HookrTypes.RulesConfig memory c = _rules(p).config(keys[p].toId());
        uint256 base = _base(p);
        uint256 share = c.protocolShareBps;
        uint256 lpSlice = (uint256(c.lpBps) * share + 99) / 100;
        uint256 lpNet = uint256(c.lpBps) * 100 - lpSlice;
        uint256 royaltyPips = lpNet * c.royaltyBps / BPS;
        uint256 burnSlice = (uint256(c.burnBps) * share + 99) / 100;
        uint256 lpReward = lpNet - royaltyPips;
        uint256 take = lpSlice + royaltyPips + burnSlice;
        uint256 span = uint256(c.maxFeePips) - base;
        uint256 room = 600_000 - base - lpReward;
        uint256 dyn = span > room ? room : span;
        uint256 snipeTax = vm.getBlockNumber() < c.guardEndBlock ? c.snipeTaxPips : 0;
        uint256 snipe = snipeTax > room - dyn ? room - dyn : snipeTax;
        uint256 slice = dyn * share / BPS + snipe * share / BPS;
        maxLp = base + lpReward + dyn + snipe - slice;
        if (span + snipeTax > room && share != 0) {
            slice = (dyn + snipe) * share / BPS;
            maxLp = base + lpReward + dyn + snipe - (slice == 0 ? 0 : slice - 1);
        }
        if (maxLp < c.maxFeePips) maxLp = c.maxFeePips;
        maxQuote = slice + take;
        if (span * share / BPS > maxQuote) maxQuote = span * share / BPS;
        // A pool with a Hookr minimum has no rule share of Hookr's: royalty + minimum (HookrRules._validate).
        uint256 minimum = IHookrRecaptureRules(address(_rules(p))).minimumFee(keys[p].toId());
        if (royaltyPips + minimum > maxQuote) maxQuote = royaltyPips + minimum;
        if (metas[p].advised) {
            address adv = _root(p).poolConfig(keys[p].toId()).advisory;
            maxLp += registry.admission(address(_root(p)), adv).caps.maxLpFeePips;
        }
    }

    // ═════════════════════════════ log ingestion ═════════════════════════════

    function _begin(string memory ctx) internal {
        _ctx = ctx;
        vm.recordLogs();
        _feeTouched = false;
        _callDevBuyLogs = 0;
        _callLauncherSwaps = 0;
        _lastSwapPool = 0;
        _lastId = bytes32(0);
        _execPool = 0;
        for (uint256 i; i < _callRules.length; ++i) {
            delete _callProtocol[_callRules[i]][address(0)];
            delete _callProtocol[_callRules[i]][address(Q)];
        }
        delete _callRules;
    }

    function _discard() internal {
        vm.getRecordedLogs();
    }

    function _isRoot(address a) internal view returns (bool) {
        return a == address(root1) || a == address(root2);
    }

    function _isRules(address a) internal view returns (bool) {
        return a == address(rules1) || a == address(rules2);
    }

    /// @dev forge's recordLogs keeps logs of frames that later reverted. Marks them: every log of a 4337 execution
    ///      that reverted (before the paymaster's settlement), every log of an op whose postOp reverted, and every Rules
    ///      or root log of a Quoter simulation (after a PoolManager Swap whose sender is the Quoter, up to that
    ///      simulation's HookFee). A PoolManager Swap sent by a root is the root's own reverted simulation.
    function _phantoms(Vm.Log[] memory logs) internal view returns (bool[] memory phantom) {
        phantom = new bool[](logs.length);
        uint256 segStart;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != EP || l.topics.length == 0) continue;
            if (l.topics[0] == BEFORE_EXEC) {
                segStart = i + 1;
                continue;
            }
            if (l.topics[0] != UOE) continue;
            (, bool success,,) = abi.decode(l.data, (uint256, bool, uint256, uint256));
            uint256 cut = type(uint256).max;
            for (uint256 j = segStart; j < i; ++j) {
                if (logs[j].emitter == EP && logs[j].topics.length != 0 && logs[j].topics[0] == POSTOP_REVERT) {
                    cut = j;
                    break;
                }
            }
            if (cut == type(uint256).max && !success) {
                cut = i;
                for (uint256 j = segStart; j < i; ++j) {
                    if (logs[j].topics.length == 0) continue;
                    if (
                        (logs[j].emitter == EP && logs[j].topics[0] == OP_REVERT_REASON)
                            || (logs[j].emitter == address(paymaster)
                                && logs[j].topics[0] == IHookrPaymaster.UserOperationSettled.selector)
                    ) {
                        cut = j;
                        break;
                    }
                }
            }
            if (cut != type(uint256).max) {
                for (uint256 j = segStart; j < cut; ++j) {
                    phantom[j] = true;
                }
            }
            segStart = i + 1;
        }
        bool sim;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (phantom[i] || l.topics.length == 0) continue;
            if (l.emitter == address(manager) && l.topics[0] == PM_SWAP && l.topics.length > 2) {
                address sender = address(uint160(uint256(l.topics[2])));
                if (_isRoot(sender)) {
                    phantom[i] = true;
                    continue;
                }
                sim = sender == address(quoter);
                if (sim) phantom[i] = true;
                continue;
            }
            if (!sim) continue;
            if (_isRules(l.emitter)) phantom[i] = true;
            if (_isRoot(l.emitter)) {
                phantom[i] = true;
                if (l.topics[0] == IHookrRootState.HookFee.selector) sim = false;
            }
        }
    }

    /// @dev Reads every committed log of this call: builds the event ledgers (credited, claimed, protocol, collected,
    ///      vault skims), checks the HookFee/FeesAllocated split per swap, every bind's protocol share, the realised LP
    ///      fee per PoolManager Swap, the guard counter, execution id uniqueness and every Paymaster settlement.
    function _ingest() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool[] memory phantom = _phantoms(logs);
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.topics.length == 0 || phantom[i]) continue;
            bytes32 t0 = l.topics[0];
            address e = l.emitter;
            if (_isRules(e)) {
                _ingestRules(e, l);
            } else if (_isRoot(e) && t0 == IHookrRootState.HookFee.selector) {
                _ingestHookFee(e, l);
            } else if (e == address(manager) && t0 == PM_SWAP) {
                _ingestSwap(l);
            } else if (e == address(treasury) && t0 == IHookrTreasury.ProtocolCollected.selector) {
                ghostCollected[
                    address(uint160(uint256(l.topics[1])))
                ][address(uint160(uint256(l.topics[2])))] += abi.decode(l.data, (uint256));
            } else if (e == address(vault) && t0 == IHookrLiquidityVault.FeesRealized.selector) {
                (,, uint256 skim0, uint256 skim1) = abi.decode(l.data, (uint256, uint256, uint256, uint256));
                Currency[2] memory cs = _rangeCurrencies[uint256(l.topics[1])];
                ghostVaultSkim[Currency.unwrap(cs[0])] += skim0;
                ghostVaultSkim[Currency.unwrap(cs[1])] += skim1;
            } else if (e == address(vault) && t0 == IHookrLiquidityVault.ProtocolFeesPaid.selector) {
                ghostVaultPaid[address(uint160(uint256(l.topics[1])))] += abi.decode(l.data, (uint256));
            } else if (e == address(programs) && t0 == IHookrPrograms.ExecutionAccepted.selector) {
                if (_seenExecution[l.topics[1]]) _flag("P7 duplicate executionId accepted");
                _seenExecution[l.topics[1]] = true;
                ++executions;
            } else if (e == address(launcher) && t0 == IHookrLauncher.DevBuyExecuted.selector) {
                ++_callDevBuyLogs;
            } else if (e == address(paymaster) && t0 == IHookrPaymaster.UserOperationSettled.selector) {
                _checkSettled(l);
            } else if (e == EP && t0 == POSTOP_REVERT) {
                ++postOpReverts;
            } else if (e == EP && t0 == UOE) {
                (, bool ok,,) = abi.decode(l.data, (uint256, bool, uint256, uint256));
                _hit(ok ? "4337.op.ok" : "4337.op.reverted");
            } else if (e == EP && t0 == OP_REVERT_REASON) {
                (, bytes memory reason) = abi.decode(l.data, (uint256, bytes));
                _hitErr("4337.op.reason", reason);
            }
        }
    }

    function _ingestRules(address e, Vm.Log memory l) internal {
        bytes32 t0 = l.topics[0];
        if (t0 == IHookrRulesEvents.FeesAllocated.selector) {
            (uint256 protocol, uint256 royalty, uint256 refund,, uint256 advisoryFee) =
                abi.decode(l.data, (uint256, uint256, uint256, address, uint256));
            address q = address(uint160(uint256(l.topics[2])));
            ghostProtocolCredited[e][q] += protocol;
            _callRules.push(e);
            _callProtocol[e][q] += protocol;
            // I1: the integrator's part is its frozen rate of Hookr's whole share, rounded down; the protocol keeps
            // the rest. A pool without an integrator pays none.
            uint256 cut = _pendingIntegratorPart;
            _pendingIntegratorPart = 0;
            (, uint16 rate) = HookrRules(e).integration(PoolId.wrap(l.topics[1]));
            if (cut != (protocol + cut) * rate / 10_000) {
                _flag("I1 integrator part is not its frozen rate of Hookr's share, rounded down");
            }
            if (cut != 0) _hit("rules.integratorPaid");
            (_lastId, _lastProtocol, _lastRoyalty, _lastRefund, _lastAdvisoryFee) =
            (l.topics[1], protocol + cut, royalty, refund, advisoryFee);
        } else if (t0 == IHookrRulesState.IntegratorPaid.selector) {
            uint256 amount = abi.decode(l.data, (uint256));
            address integrator = address(uint160(uint256(l.topics[3])));
            ghostIntegratorCredited[e][address(uint160(uint256(l.topics[2])))][integrator] += amount;
            (address named,) = HookrRules(e).integration(PoolId.wrap(l.topics[1]));
            if (integrator != named || amount == 0) _flag("I1 IntegratorPaid names another integrator or nothing");
            _pendingIntegratorPart += amount;
        } else if (t0 == IHookrRulesState.Claimed.selector) {
            uint256 amount = abi.decode(l.data, (uint256));
            address q = address(uint160(uint256(l.topics[1])));
            ghostClaimed[e][q] += amount;
            address beneficiary = address(uint160(uint256(l.topics[2])));
            if (beneficiary == INTEGRATOR_A || beneficiary == INTEGRATOR_B || beneficiary == INTEGRATOR_C) {
                ghostIntegratorClaimed[e][q][beneficiary] += amount;
            }
        } else if (t0 == IHookrRulesState.RulesBound.selector) {
            (, bytes memory config) = abi.decode(l.data, (bytes32, bytes));
            HookrTypes.RulesConfig memory c;
            // The first sixteen words are the RulesConfig for both the plain and the dynamic fee encoding.
            assembly ("memory-safe") {
                c := mload(0x40)
                mcopy(c, add(config, 32), 512)
                mstore(0x40, add(c, 512))
            }
            if (c.protocolShareBps < HookrRules(e).minProtocolShareBps()) {
                _flag("PS1 a pool bound below minProtocolShareBps");
            }
            // I0: a pool freezes exactly the integrator it names, at the treasury's rate at bind.
            (address named, uint16 rate) = HookrRules(e).integration(PoolId.wrap(l.topics[1]));
            PoolId boundId = PoolId.wrap(l.topics[1]);
            // A recapture pool's Rules data: RulesConfig, RulesKnobs and RecaptureConfig, 16 + 6 + 8 words.
            bool lane = config.length == (16 + 6 + 8) * 32;
            (, uint16 listed,) = treasury.feeTerms(c.integrator, lane, boundId);
            if (named != c.integrator || rate != listed) _flag("I0 a pool froze another integrator or rate");
            // M0: a Hookr token's pool with no arb recapture, no rule that earns Hookr a share (LP Rewards or Auto
            // Burn at a nonzero protocolShareBps, or dynamic fees or the Anti-Snipe tax whose span or snipeTaxPips
            // times the share reaches 10,000, a pip of Hookr's) and no Tax + Conversion advisory (one declaring the
            // DIRECTIONAL_QUOTE_TAX group, read with 10,000 gas, and admitted with a quote take, at a nonzero share)
            // freezes the treasury's plain minimum (its integrator's override when that integrator approved this
            // pool's id), any other pool none. Recomputed from the treasury's parts rather than feeTerms, so an
            // override reaching an unapproved pool is caught.
            uint16 minimum = treasury.minFeePips(false);
            (uint16 overridePips,,) = treasury.integratorMinFee(c.integrator);
            bool approved = treasury.minFeePoolApproved(c.integrator, boundId);
            if (c.integrator != address(0) && overridePips != treasury.NO_MIN_FEE_OVERRIDE() && approved) {
                minimum = overridePips;
            }
            if (c.integrator == INTEGRATOR_C) _hit(approved ? "minFee.overrideApproved" : "minFee.overrideUnapproved");
            HookrTypes.PoolConfig memory opened =
                HookrRoot(address(uint160(uint256(l.topics[2])))).poolConfig(PoolId.wrap(l.topics[1]));
            address subject = Currency.unwrap(opened.subject);
            uint256 share = c.protocolShareBps;
            uint256 span = c.maxFeePips > opened.baseLpFeePips ? c.maxFeePips - opened.baseLpFeePips : 0;
            bool earns = share != 0
                && (c.lpBps != 0
                    || c.burnBps != 0
                    || span * share >= 10_000
                    || uint256(c.snipeTaxPips) * share >= 10_000);
            if (!earns && share != 0 && opened.advisory != address(0)) {
                (bool ok, bytes memory group) =
                    opened.advisory.staticcall{gas: 10_000}(abi.encodeWithSignature("EXCLUSIVE_GROUP()"));
                IHookrRegistry.Admission memory admitted =
                    registry.admission(address(uint160(uint256(l.topics[2]))), opened.advisory);
                earns = ok && group.length == 32 && bytes32(group) == keccak256("DIRECTIONAL_QUOTE_TAX")
                    && admitted.caps.maxQuoteTakePips != 0;
            }
            if (subject.codehash != address(Q).codehash) minimum = 0;
            else if (lane || earns) _hit(lane ? "minFee.noneOnLane" : "minFee.noneOnEarningRules");
            if (lane || earns) minimum = 0;
            if (IHookrRecaptureRules(e).minimumFee(PoolId.wrap(l.topics[1])) != minimum) {
                _flag("M0 a pool froze another Hookr minimum");
            }
            if (minimum != 0) _hit("minFee.bound");
            _hit("rules.bound");
        }
    }

    function _ingestHookFee(address e, Vm.Log memory l) internal {
        (uint256 earned, uint256 refund, uint256 burned) = abi.decode(l.data, (uint256, uint256, uint256));
        burned;
        address q = address(uint160(uint256(l.topics[2])));
        address r = address(_rulesOfRoot(e));
        ghostCredited[r][q] += earned + refund;
        _lastHookr = _lastId == l.topics[1] ? _lastProtocol : type(uint256).max;
        if (earned + refund != 0) {
            if (
                _lastId != l.topics[1] || earned != _lastProtocol + _lastRoyalty + _lastAdvisoryFee
                    || refund != _lastRefund
            ) {
                _flag("E1 HookFee does not equal the preceding FeesAllocated split");
            }
        }
        _lastId = bytes32(0);
        if (_lastSwapPool != 0) {
            uint256 p = _lastSwapPool - 1;
            if (PoolId.unwrap(keys[p].toId()) == l.topics[1]) _afterSwapFees(p, earned);
        }
        _lastSwapPool = 0;
    }

    /// @dev At the root's HookFee: the quote take bound and the guard counter, from the preceding PoolManager Swap.
    function _afterSwapFees(uint256 p, uint256 earned) internal {
        bool quoteIs0 = Currency.unwrap(_quoteOf(p)) == Currency.unwrap(keys[p].currency0);
        // A swap that filled nothing has no direction in its amounts and moves no guard counter: not a buy.
        bool buy = _lastSwapZeroForOne == quoteIs0 && (_lastSwap0 != 0 || _lastSwap1 != 0);
        int128 quoteDelta = quoteIs0 ? _lastSwap0 : _lastSwap1;
        uint256 actualQuote = uint256(quoteDelta < 0 ? -int256(quoteDelta) : int256(quoteDelta));
        uint256 basis = buy ? actualQuote + earned : actualQuote;
        (, uint256 maxQuote) = _maxima(p);
        // Buys: earned is at most the take rate of the gross spend. Sells: of the quote that left the pool; an
        // exact-output sell reserves ceil(Q * t / (PIPS - t)), at most one unit above t of the gross.
        if (earned > basis * maxQuote / PIPS + 1) _flag("E3 quote take above the pool's frozen maximum");
        // M1: a pool with a Hookr minimum runs its Rules on every swap and pays Hookr (protocol recipient and
        // integrator together) at least floor(gross spend or quote out x minimum / 10^6).
        uint256 minimum = IHookrRecaptureRules(address(_rules(p))).minimumFee(keys[p].toId());
        if (minimum != 0) {
            if (_lastHookr == type(uint256).max) _flag("M1 a swap on a pool with a minimum skipped its Rules");
            else if (_lastHookr < basis * minimum / PIPS) _flag("M1 Hookr's part of a swap below the pool's minimum");
            else _hit("rules.minimumHeld");
        }
        HookrTypes.RulesConfig memory c = _rules(p).config(keys[p].toId());
        if (vm.getBlockNumber() >= c.guardEndBlock || c.maxBuyQuoteAmount == 0) return;
        uint256 word = _guardWord[p];
        uint256 spent = word >> 192 == vm.getBlockNumber() ? uint256(uint192(word)) : 0;
        if (buy) {
            ++guardBuys;
            if (_closedBlock[p] == vm.getBlockNumber() + 1 && !_inDevBuy) {
                _flag("G2 a buy cleared in the parent block a dev buy closed");
            }
            spent += basis;
            if (spent > _capNow(p, c)) _flag("G1 guarded buys in one parent block above the decayed cap");
            if (_inDevBuy) _closedBlock[p] = vm.getBlockNumber() + 1;
        } else if (spent != 0) {
            spent = spent > basis ? spent - basis : 0;
        }
        _guardWord[p] = (vm.getBlockNumber() << 192) | spent;
    }

    function _ingestSwap(Vm.Log memory l) internal {
        address sender = address(uint160(uint256(l.topics[2])));
        if (sender == address(launcher)) ++_callLauncherSwaps;
        (int128 a0, int128 a1,,,, uint24 fee) = abi.decode(l.data, (int128, int128, uint160, uint128, int24, uint24));
        // A swap that moved nothing (no liquidity on its side) shows no direction; its fee is checked against both.
        bool known = a0 != 0 || a1 != 0;
        bool zeroForOne = a0 < 0 || (a0 == 0 && a1 > 0);
        uint256 p = _poolIndex(l.topics[1]);
        if (p != type(uint256).max) {
            _lastSwapPool = p + 1;
            _lastSwapZeroForOne = zeroForOne;
            (_lastSwap0, _lastSwap1) = (a0, a1);
            (_execPool, _execFee) = (p + 1, fee);
            _checkSwapFee(keys[p], zeroForOne, known, fee, p, false);
            return;
        }
        uint256 q = _pairIndex(l.topics[1]);
        if (q != type(uint256).max) _checkSwapFee(pairKeys[q], zeroForOne, known, fee, q, true);
    }

    /// @dev The fee a PoolManager Swap event reports for LP fee `lp` under the directional protocol fee `dir`.
    function _swapFee(uint16 dir, uint256 lp) internal pure returns (uint256) {
        return dir == 0 ? lp : ProtocolFeeLibrary.calculateSwapFee(dir, uint24(lp));
    }

    /// @dev The Uniswap protocol fee a swap in this direction pays on `k` now.
    function _dir(PoolKey memory k, bool zeroForOne) internal view returns (uint16) {
        (,, uint24 pf,) = manager.getSlot0(k.toId());
        return zeroForOne ? ProtocolFeeLibrary.getZeroForOneFee(pf) : ProtocolFeeLibrary.getOneForZeroFee(pf);
    }

    /// @dev P10: the realised swap fee never exceeds the pool's frozen LP-fee maximum composed with the Uniswap
    ///      protocol fee. S1: a root pool's LP fee equals its frozen native fee (base, LP Rewards, the decayed Snipe
    ///      while the guard lasts, less the protocol share) plus the advisory surcharge, with a dynamic fee only adding
    ///      to it. PR2: a pair pool's LP fee is its base plus the clamped advisory surcharge. S1 and PR2 compare the
    ///      Swap event's fee with that LP fee composed with the protocol fee in force
    ///      (ProtocolFeeLibrary.calculateSwapFee), so they hold with or without one. They skip only a swap that moved
    ///      nothing (its direction is unknown) and a multicall that triggered a protocol fee update, which may land
    ///      between its quote and its swap.
    function _checkSwapFee(PoolKey memory k, bool zeroForOne, bool known, uint24 fee, uint256 index, bool pair)
        internal
    {
        uint16 dir = _dir(k, zeroForOne);
        if (!known) {
            uint16 other = _dir(k, !zeroForOne);
            if (other > dir) dir = other;
        }
        if (_feeTouched) dir = 1000;
        uint256 maxLp;
        if (pair) {
            maxLp = IHookrPairRoot(address(k.hooks)).params().maxLpFeePips;
        } else {
            (maxLp,) = _maxima(index);
        }
        uint256 bound = _swapFee(dir, maxLp);
        if (fee > bound) {
            _flag(
                string.concat(
                    "P10 realised swap fee above the pool's frozen maximum plus the protocol fee: ",
                    pair ? "pair " : "pool ",
                    vm.toString(index),
                    zeroForOne ? " zeroForOne" : " oneForZero",
                    " protocol ",
                    vm.toString(uint256(dir)),
                    " fee ",
                    vm.toString(fee),
                    " bound ",
                    vm.toString(bound)
                )
            );
        }
        if (!known || _feeTouched) {
            _hit(known ? "swap.feeTriggeredInCall" : "swap.zeroAmounts");
            return;
        }
        if (dir != 0) {
            ++protocolFeeChecks;
            _hit("swap.exactWithProtocolFee");
        }
        if (pair) {
            IHookrPairRoot.Params memory pp = IHookrPairRoot(address(k.hooks)).params();
            uint256 expected = pp.baseLpFeePips;
            if (pp.advisory != address(0)) {
                uint256 s = feeAdvisory.surcharge(k.toId(), zeroForOne);
                expected += s < pp.advisoryCapPips ? s : pp.advisoryCapPips;
            }
            if (fee != _swapFee(dir, expected)) {
                _flag(
                    string.concat(
                        "PR2 pair pool LP fee differs from its base plus the clamped surcharge: pair ",
                        vm.toString(index),
                        " fee ",
                        vm.toString(fee),
                        " expected LP fee ",
                        vm.toString(expected),
                        " protocol ",
                        vm.toString(uint256(dir))
                    )
                );
            }
            return;
        }
        bool quoteIs0 = Currency.unwrap(_quoteOf(index)) == Currency.unwrap(k.currency0);
        bool buy = zeroForOne == quoteIs0;
        uint256 floor = _nativeFloor(index, buy) + _advice(index, zeroForOne);
        ++lpFeeChecks;
        if (buy) _hitDecay(index);
        // One pip of rounding either way on the LP fee; a dynamic fee only adds to the floor.
        uint256 lo = floor == 0 ? 0 : _swapFee(dir, floor - 1);
        bool off = metas[index].dynamic ? fee < lo : (fee < lo || fee > _swapFee(dir, floor + 1));
        if (off) {
            _flag(
                string.concat(
                    metas[index].dynamic
                        ? "S1 dynamic fee pool charged below its native floor: pool "
                        : "S1 LP fee differs from the frozen native fee plus the advisory surcharge: pool ",
                    vm.toString(index),
                    buy ? " buy fee " : " sell fee ",
                    vm.toString(fee),
                    " expected LP fee ",
                    vm.toString(floor),
                    " protocol ",
                    vm.toString(uint256(dir))
                )
            );
        }
    }

    /// @dev Coverage: a guarded buy priced part way down its Snipe decay.
    function _hitDecay(uint256 p) internal {
        HookrTypes.RulesConfig memory c = _rules(p).config(keys[p].toId());
        if (c.snipeDecaySeconds == 0 || vm.getBlockNumber() >= c.guardEndBlock) return;
        uint256 elapsed = block.timestamp - metas[p].launchedAt;
        if (elapsed != 0 && elapsed < c.snipeDecaySeconds) _hit("swap.buyMidDecay");
    }

    function _checkSettled(Vm.Log memory l) internal {
        (, bool succeeded, uint256 costWei, uint256 feeWei, uint256 rebateWei,,) =
            abi.decode(l.data, (uint8, bool, uint256, uint256, uint256, uint256, uint256));
        succeeded;
        if (rebateWei > costWei) _flag("P5b rebate above costWei");
        if (rebateWei > feeWei * 5_000 / 10_000) _flag("P5b rebate above rebateBps x attributed fee");
        if (rebateWei != 0) {
            rebatesPaid += rebateWei;
            ++rebateOps;
            _rebateOf[address(uint160(uint256(l.topics[1])))] += rebateWei;
        }
    }

    /// @dev P5: for single-payer calls, the change in PROTOCOL_PAID(payer, quote) this call equals the protocol claims
    ///      this call credited, per Rules and quote.
    function _checkPaid(address payer, uint256[4] memory before) internal {
        uint256[4] memory afterPaid = _paid(payer);
        address[2] memory rs = [address(rules1), address(rules2)];
        address[2] memory qs = [address(0), address(Q)];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                uint256 delta = afterPaid[i * 2 + j] - before[i * 2 + j];
                if (delta != _callProtocol[rs[i]][qs[j]]) {
                    _flag("P5 PROTOCOL_PAID delta differs from protocol claims credited to that payer");
                }
            }
        }
    }

    function _paid(address payer) internal view returns (uint256[4] memory v) {
        v[0] = rules1.protocolFeePaid(payer, Currency.wrap(address(0)));
        v[1] = rules1.protocolFeePaid(payer, Currency.wrap(address(Q)));
        v[2] = rules2.protocolFeePaid(payer, Currency.wrap(address(0)));
        v[3] = rules2.protocolFeePaid(payer, Currency.wrap(address(Q)));
    }

    function _quote(IHookrRouter.Swap memory s, address payer)
        internal
        returns (bool ok, HookrTypes.ExecutionReceipt memory r)
    {
        try quoter.quote(s, payer) returns (HookrTypes.ExecutionReceipt memory q) {
            return (true, q);
        } catch {
            return (false, r);
        }
    }

    // ═════════════════════════════ dynamic fee (DF-02 and the anchor) ═════════════════════════════

    struct DfPre {
        bool started;
        int24 anchor;
        uint160 sqrtBefore;
        int24 tickBefore;
    }

    function _dfPre(uint256 p) internal view returns (DfPre memory d) {
        PoolId id = keys[p].toId();
        (, int24 ref, int24 anchor, uint40 movedAt,,) = _rules(p).referenceState(id);
        ref;
        d.started = movedAt != 0;
        d.anchor = anchor;
        (d.sqrtBefore, d.tickBefore,,) = manager.getSlot0(id);
    }

    /// @dev DF-02 over any pool state: the fee the executed swap was charged (its PoolManager Swap event's fee, the
    ///      protocol fee composed in) covers the dynamic fee its executed end price implies from the reference the swap
    ///      was priced against and the nearer of its start and the anchor. And the anchor moves toward the executed
    ///      price and never beyond it, the old anchor or the reference.
    function _dfCheck(uint256 p, bool zeroForOne, uint256 swapFee, DfPre memory d) internal {
        PoolId id = keys[p].toId();
        HookrRules r = _rules(p);
        (, int24 ref, int24 anchor1, uint40 movedAt,,) = r.referenceState(id);
        // A swap that ran out of liquidity is priced to the last price with liquidity, not to where it stopped.
        if (movedAt == 0 || manager.getLiquidity(id) == 0) return;
        int24 anchor0 = d.started ? d.anchor : d.tickBefore;
        (uint160 sqrtEnd, int24 tickEnd,,) = manager.getSlot0(id);
        HookrTypes.RulesConfig memory c = r.config(id);
        bool quoteIs0 = Currency.unwrap(_quoteOf(p)) == Currency.unwrap(keys[p].currency0);
        bool buy = zeroForOne == quoteIs0;
        uint256 base = _base(p);
        uint256 ideal;
        {
            uint160 sqrtRef = TickMath.getSqrtPriceAtTick(ref);
            int256 from = HookrDynamicFee.distance(sqrtRef, d.sqrtBefore, zeroForOne);
            int256 end = HookrDynamicFee.distance(sqrtRef, sqrtEnd, zeroForOne);
            int256 away = from > 0 ? from : int256(0);
            if (end > away) {
                int256 a = HookrDynamicFee.distance(sqrtRef, TickMath.getSqrtPriceAtTick(anchor0), zeroForOne);
                int256 start = a < from ? a : from;
                if (start < 0) start = 0;
                uint256 s = uint256(start);
                ideal = (uint256(c.maxFeePips) - base)
                    * HookrDynamicFee.averageRate(s, s + uint256(end - away), c.dynamicFeeSens) / HookrDynamicFee.WAD;
            }
        }
        uint256 lpReward = buy ? _lpReward(c) : 0;
        uint256 room = 600_000 - base - lpReward;
        if (ideal > room) ideal = room;
        uint256 floor = base + lpReward + ideal - ideal * c.protocolShareBps / BPS;
        ++dynamicChecks;
        if (floor != 0 && swapFee < _swapFee(_dir(keys[p], zeroForOne), floor - 1)) {
            _flag("DF-02 dynamic fee below the executed move");
        }
        // The anchor never passes the executed price, the previous anchor or the reference (one tick of rounding).
        int24 lo = anchor0;
        int24 hi = anchor0;
        if (tickEnd < lo) lo = tickEnd;
        if (tickEnd > hi) hi = tickEnd;
        if (ref < lo) lo = ref;
        if (ref > hi) hi = ref;
        ++anchorChecks;
        if (anchor1 < lo - 1 || anchor1 > hi + 1) _flag("DF-A anchor moved beyond the executed price");
    }

    // ═════════════════════════════ handlers ═════════════════════════════

    /// @notice Router.swap by an EOA: exact-in/out, buy/sell, full or price-limited, optional Programs campaigns.
    ///         The Quoter runs first in the same transaction and must equal the swap (P9); on a dynamic fee pool the
    ///         executed swap's fee must cover the executed move (DF-02) and the anchor must follow the executed price.
    function swapRouter(uint256 seed) external {
        seed = _mix(seed, "swapRouter");
        _begin("swapRouter");
        uint256 p = seed % keys.length;
        address actor = actors[(seed >> 8) % 4];
        bool buy = (seed >> 16) & 1 == 0;
        bool exactIn = (seed >> 17) % 4 != 0;
        bool isPartial = (seed >> 20) % 5 == 0;
        uint128 amount = _swapAmount(seed >> 40, 3e19);
        IHookrRouter.Swap memory s = _params(p, buy, exactIn, amount, isPartial, actor);
        (address engagement, uint256[] memory ids) = _campaigns((seed >> 24) & 1 == 1, p);
        (bool qOk, HookrTypes.ExecutionReceipt memory q) = _quote(s, actor);
        uint256[4] memory before = _paid(actor);
        DfPre memory d = _dfPre(p);
        uint256 value = _nativeIn(s) ? _maxIn(s) : 0;
        bool dfDue;
        vm.prank(actor);
        try router.swap{value: value}(s, engagement, ids) returns (uint256 aIn, uint256 aOut) {
            _hit(exactIn ? (buy ? "router.buy.in" : "router.sell.in") : (buy ? "router.buy.out" : "router.sell.out"));
            if (isPartial) _hit("router.isPartial");
            if (!qOk) {
                _flag("P9 quote reverted but the same swap succeeded");
            } else {
                if (q.inputAmount != aIn || q.outputAmount != aOut) {
                    _flag("P9 quote differs from the swap in the same transaction");
                }
                dfDue = metas[p].dynamic;
            }
        } catch (bytes memory err) {
            _discard();
            _hitErr("router.revert", err);
            _rulesFailure(p, err);
        }
        _ingest();
        if (dfDue) {
            // The router's swap is this call's last committed PoolManager Swap on the pool.
            if (_execPool != p + 1) _flag("DF-02 the router swap left no Swap event on its pool");
            else _dfCheck(p, s.zeroForOne, _execFee, d);
        }
        _checkPaid(actor, before);
    }

    function _sign(IHookrForwarder.HookrSwapIntent memory it, uint256 pk) internal view returns (bytes memory) {
        (address token, uint256 amount,) = fwd.pullOf(it);
        bytes32 typeHash = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                fwd.WITNESS_TYPE_STRING()
            )
        );
        bytes32 tp = keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), token, amount));
        bytes32 structHash = keccak256(
            abi.encode(typeHash, tp, address(fwd), fwd.permit2Nonce(it.nonce), it.deadline, fwd.hashIntent(it))
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", ISysPermit2Domain(PERMIT2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _intent(uint256 seed, uint256 ownerIdx, address relayer)
        internal
        returns (IHookrForwarder.HookrSwapIntent memory it)
    {
        uint256 p = seed % keys.length;
        bool buy = (seed >> 16) & 1 == 0;
        // Native input is unsupported on the relayed path.
        if (Currency.unwrap(_quoteOf(p)) == address(0)) buy = false;
        bool exactIn = (seed >> 17) % 4 != 0;
        uint128 amount = _swapAmount(seed >> 40, 3e19);
        IHookrRouter.Swap memory s = _params(p, buy, exactIn, amount, (seed >> 20) % 5 == 0, actors[ownerIdx]);
        it.key = s.key;
        it.zeroForOne = s.zeroForOne;
        it.amountSpecified = s.amountSpecified;
        it.amountBound = s.amountBound;
        it.sqrtPriceLimitX96 = s.sqrtPriceLimitX96;
        it.recipient = actors[ownerIdx];
        it.relayer = (seed >> 28) & 1 == 1 ? relayer : address(0);
        // A zero relayer takes no fee, and an output-side fee (a sell's) is refused on an advised pool.
        it.relayerFee = it.relayer == address(0) || (!buy && metas[p].advised) ? 0 : bound(seed >> 100, 0, 1e16);
        (it.engagement, it.campaigns) = _campaigns((seed >> 24) & 1 == 1, p);
        it.nonce = ++_fwdNonce[actors[ownerIdx]];
        it.deadline = vm.getBlockTimestamp() + 100;
    }

    /// @notice Forwarder.execute (Permit2 witness) relayed by another EOA; fee from input on buys, output on sells.
    function swapForwarder(uint256 seed) external {
        seed = _mix(seed, "swapForwarder");
        _begin("swapForwarder");
        uint256 oi = (seed >> 8) % 4;
        address relayer = actors[(oi + 1 + (seed >> 12) % 3) % 4];
        IHookrForwarder.HookrSwapIntent memory it = _intent(seed, oi, relayer);
        bytes memory sig = _sign(it, actorPk[oi]);
        uint256[4] memory before = _paid(actors[oi]);
        vm.prank(relayer);
        try fwd.execute(it, actors[oi], sig) {
            _hit(it.amountSpecified < 0 ? "forwarder.exactIn" : "forwarder.exactOut");
        } catch (bytes memory err) {
            _discard();
            _hitErr("forwarder.revert", err);
            _rulesFailure(seed % keys.length, err);
        }
        _ingest();
        _checkPaid(actors[oi], before);
    }

    function _swapAct(PoolKey memory k, uint256 p, bool pair, uint256 seed) internal returns (SysLocker.Act memory a) {
        bool zeroForOne = (seed >> 1) & 1 == 0;
        if (!pair) zeroForOne = _zeroForOne(p, zeroForOne);
        bool exactIn = (seed >> 2) % 4 != 0;
        uint256 amount = _swapAmount(seed >> 8, 3e19);
        a.kind = 0;
        a.key = k;
        a.zeroForOne = zeroForOne;
        a.amount = exactIn ? -int256(amount) : int256(amount);
        a.limit = _limit(k, zeroForOne, (seed >> 5) % 4 == 0);
    }

    /// @notice 1..8 operations in ONE unlock through the curated locker (authenticated as the caller) or the generic
    ///         locker (unauthenticated): swaps on root and pair pools, and same-unlock JIT bands (add, swap, remove).
    function lockerBundle(uint256 seed) external {
        seed = _mix(seed, "lockerBundle");
        _begin("lockerBundle");
        bool isCurated = seed & 1 == 0;
        SysLocker L = isCurated ? curated : generic;
        address actor = actors[(seed >> 1) % 4];
        uint256 n = 1 + (seed >> 4) % 6;
        SysLocker.Act[] memory acts = new SysLocker.Act[](n + 2);
        uint256 k;
        uint256 s = uint256(keccak256(abi.encode(seed)));
        bool jitDone;
        for (uint256 i; i < n; ++i) {
            s = uint256(keccak256(abi.encode(s)));
            if (!jitDone && s % 4 == 0) {
                (bool pair, uint256 p) = _openPool(s >> 3);
                PoolKey memory pk = _anyKey(pair, p);
                (int24 lo, int24 hi) = _band(pk, (s >> 12) % 3);
                int256 liq = int256(bound(s >> 20, 1e18, 1e22));
                bytes32 salt = keccak256(abi.encode("jit", s));
                acts[k++] = SysLocker.Act(1, pk, false, liq, 0, lo, hi, salt);
                acts[k++] = _swapAct(pk, p, pair, s >> 40);
                acts[k++] = SysLocker.Act(1, pk, false, -liq, 0, lo, hi, salt);
                jitDone = true;
                i += 2;
            } else if ((s >> 200) % 5 == 0) {
                uint256 q = (s >> 3) % pairKeys.length;
                acts[k++] = _swapAct(pairKeys[q], q, true, s >> 40);
            } else {
                uint256 p = s % keys.length;
                acts[k++] = _swapAct(keys[p], p, false, s >> 40);
            }
        }
        assembly ("memory-safe") {
            mstore(acts, k)
        }
        address payer = isCurated ? actor : address(generic);
        uint256[4] memory before = _paid(payer);
        vm.prank(actor);
        try L.run{value: 1e22}(acts) {
            _hit(isCurated ? "curated.bundle" : "generic.bundle");
            if (jitDone) _hit("bundle.jit");
            if (k > 1) _hit("bundle.multiAct");
        } catch (bytes memory err) {
            _discard();
            _hitErr(isCurated ? "curated.revert" : "generic.revert", err);
        }
        _ingest();
        _checkPaid(payer, before);
    }

    function _addDust(bool pair, uint256 p, int24 lo, int24 hi, uint128 liq) internal returns (bool ok) {
        bytes32 salt = bytes32(++_dustSalt);
        SysLocker.Act[] memory acts = new SysLocker.Act[](1);
        acts[0] = SysLocker.Act(1, _anyKey(pair, p), false, int256(uint256(liq)), 0, lo, hi, salt);
        try generic.run{value: 1e22}(acts) {
            _dust.push(Dust(pair, uint8(p), lo, hi, liq, salt));
            return true;
        } catch (bytes memory err) {
            _discard();
            _hitErr("dust.add.revert", err);
        }
    }

    /// @notice Third-party liquidity that persists across transactions (the generic locker owns the position).
    function dustAdd(uint256 seed) external {
        seed = _mix(seed, "dustAdd");
        _begin("dustAdd");
        (bool pair, uint256 p) = _openPool(seed);
        (int24 lo, int24 hi) = _band(_anyKey(pair, p), (seed >> 8) % 20);
        if ((seed >> 16) & 1 == 1) {
            lo = lo - 6000 < TickMath.minUsableTick(60) ? lo : lo - 6000;
            hi = hi + 6000 > TickMath.maxUsableTick(60) ? hi : hi + 6000;
        }
        if (_addDust(pair, p, lo, hi, uint128(bound(seed >> 32, 1e9, 1e19)))) {
            _hit(pair ? "dust.add.pair" : "dust.add");
        }
        _ingest();
    }

    function dustRemove(uint256 seed) external {
        seed = _mix(seed, "dustRemove");
        _begin("dustRemove");
        if (_dust.length == 0) return;
        uint256 i = seed % _dust.length;
        Dust memory d = _dust[i];
        SysLocker.Act[] memory acts = new SysLocker.Act[](1);
        acts[0] = SysLocker.Act(
            1, _anyKey(d.pair, d.pool), false, -int256(uint256(d.liquidity)), 0, d.lower, d.upper, d.salt
        );
        try generic.run(acts) {
            _dust[i] = _dust[_dust.length - 1];
            _dust.pop();
            _hit("dust.remove");
        } catch (bytes memory err) {
            _discard();
            _hitErr("dust.remove.revert", err);
            _flag("P11 third-party position cannot be removed");
        }
        _ingest();
    }

    // ───────────── launcher ─────────────
    function _family(uint256 seed) internal view returns (bytes32 fam, uint8 member) {
        fam = _families[seed % _families.length];
        member = uint8((seed >> 4) % launcher.memberCount(fam));
    }

    function _familyGuardEnd(bytes32 fam) internal view returns (uint256 end) {
        uint8 n = launcher.memberCount(fam);
        for (uint8 i; i < n; ++i) {
            PoolKey memory k = launcher.position(fam, i).key;
            if (k.tickSpacing == 0) continue;
            HookrRules r = address(k.hooks) == address(root1) ? rules1 : rules2;
            uint256 g = r.config(k.toId()).guardEndBlock;
            if (g > end) end = g;
        }
    }

    function launcherAdd(uint256 seed) external {
        seed = _mix(seed, "launcherAdd");
        _begin("launcherAdd");
        (bytes32 fam, uint8 m) = _family(seed);
        address owner = launcher.familyOwner(fam);
        IHookrLauncher.Position memory pos = launcher.position(fam, m);
        uint128 liq = uint128(bound(seed >> 16, 1e15, 3e20));
        uint128 max0 = uint128(bound(seed >> 80, 1e18, 1e21));
        uint128 max1 = max0;
        uint256 value = Currency.unwrap(pos.key.currency0) == address(0) ? max0 : 0;
        _fundOwner(owner, pos.key);
        vm.prank(owner);
        try launcher.addLiquidity{value: value}(fam, m, liq, max0, max1, vm.getBlockTimestamp() + 10) {
            _hit("launcher.add");
        } catch (bytes memory err) {
            _discard();
            _hitErr("launcher.add.revert", err);
        }
        _ingest();
    }

    /// @dev An owner may hold none of a dev-bought subject; the campaign's owners are funded like any LP.
    function _fundOwner(address owner, PoolKey memory k) internal {
        address[2] memory cs = [Currency.unwrap(k.currency0), Currency.unwrap(k.currency1)];
        for (uint256 i; i < 2; ++i) {
            if (cs[i] == address(0)) continue;
            if (IERC20(cs[i]).balanceOf(owner) < 1e21 && IERC20(cs[i]).balanceOf(address(this)) >= 1e21) {
                IERC20(cs[i]).transfer(owner, 1e21);
            }
            if (IERC20(cs[i]).allowance(owner, address(launcher)) < 1e30) {
                vm.prank(owner);
                IERC20(cs[i]).approve(address(launcher), type(uint256).max);
            }
        }
    }

    /// @notice withdraw / withdrawWithClaims / collect. P8: principal never leaves before the family's lock (its
    ///         largest guard, or the dev buy's lock), and the lock reads what the launch set.
    function launcherWithdraw(uint256 seed) external {
        seed = _mix(seed, "launcherWithdraw");
        _begin("launcherWithdraw");
        (bytes32 fam, uint8 m) = _family(seed);
        address owner = launcher.familyOwner(fam);
        IHookrLauncher.Position memory pos = launcher.position(fam, m);
        uint256 mode = (seed >> 8) % 20;
        uint128 liq = mode < 7 ? 0 : (mode < 14 ? pos.liquidity / 8 : (mode < 18 ? pos.liquidity / 2 : pos.liquidity));
        address recipient = actors[(seed >> 12) % 4];
        uint8 claims = uint8((seed >> 16) % 4);
        uint256 lock = launcher.principalLockedUntil(fam);
        if (lock != familyLock[fam]) {
            _flag("P8 principalLockedUntil differs from the family's guards and dev-buy lock");
        }
        if (lock < _familyGuardEnd(fam)) _flag("P8 principal lock ends before a member's guard");
        vm.prank(owner);
        try launcher.withdrawWithClaims(fam, m, liq, 0, 0, recipient, claims, vm.getBlockTimestamp() + 10) {
            _hit(liq == 0 ? "launcher.collect" : "launcher.withdraw");
            if (liq != 0 && vm.getBlockNumber() < lock) _flag("P8 principal withdrawn before the family's lock");
            if (claims != 0) _addClaimHolder(recipient);
        } catch (bytes memory err) {
            _discard();
            _hit("launcher.withdraw.revert");
            if (
                pos.liquidity != 0 && vm.getBlockNumber() >= lock && err.length >= 4
                    && bytes4(err) == IHookrLauncher.PrincipalLocked.selector
            ) {
                _flag("P11 principal locked after the family lock ended");
            }
        }
        _ingest();
    }

    function launcherTransfer(uint256 seed) external {
        seed = _mix(seed, "launcherTransfer");
        _begin("launcherTransfer");
        (bytes32 fam,) = _family(seed);
        address owner = launcher.familyOwner(fam);
        address next = actors[(seed >> 8) % 4];
        if (next == owner) next = actors[((seed >> 8) + 1) % 4];
        uint16 claims = uint16((seed >> 16) % (uint256(1) << (2 * launcher.memberCount(fam))));
        vm.prank(owner);
        launcher.transferFamily(fam, next, claims);
        vm.prank(next);
        try launcher.acceptFamily(fam) {
            _hit("launcher.transfer");
            if (claims != 0) _addClaimHolder(owner);
        } catch (bytes memory err) {
            _discard();
            _hitErr("launcher.accept.revert", err);
            _flag("P11 acceptFamily reverted");
        }
        _ingest();
    }

    /// @notice ERC-6909 exit: a holder of PoolManager claims (from withdrawWithClaims, acceptFamily or Rules'
    ///         claimAsClaims) redeems some of them through the Launcher.
    function launcherRedeem(uint256 seed) external {
        seed = _mix(seed, "launcherRedeem");
        _begin("launcherRedeem");
        if (_claimHolders.length == 0) return;
        address holder = _claimHolders[seed % _claimHolders.length];
        Currency[4] memory cs = [
            Currency.wrap(address(0)), Currency.wrap(address(Q)), Currency.wrap(address(SA)), Currency.wrap(address(SB))
        ];
        Currency c = cs[(seed >> 8) % 4];
        uint256 bal = manager.balanceOf(holder, c.toId());
        if (bal == 0) return;
        uint256 amount = bound(seed >> 16, 1, bal);
        uint256 before = c.balanceOf(holder);
        vm.startPrank(holder);
        manager.setOperator(address(launcher), true);
        try launcher.redeem(c, amount, holder) {
            _hit("launcher.redeem");
            if (c.balanceOf(holder) != before + amount) _flag("X1 ERC-6909 redemption not exact");
        } catch (bytes memory err) {
            _discard();
            _hitErr("launcher.redeem.revert", err);
            _flag("P11 ERC-6909 claim redeem reverted");
        }
        vm.stopPrank();
        _ingest();
    }

    // ───────────── claims and treasury ─────────────
    function _claimAs(address b, HookrRules r, Currency c, address to, bool asClaims) internal returns (bool ok) {
        if (b == address(treasury)) {
            try treasury.collect(address(r), c) {
                return true;
            } catch {
                _discard();
                return false;
            }
        }
        bytes memory call =
            asClaims ? abi.encodeCall(HookrRules.claimAsClaims, (c, to)) : abi.encodeCall(HookrRules.claimTo, (c, to));
        if (b == address(multicall)) {
            address[] memory t = new address[](1);
            uint256[] memory v = new uint256[](1);
            bytes[] memory d = new bytes[](1);
            t[0] = address(r);
            d[0] = call;
            try multicall.exec(t, v, d) {
                return true;
            } catch {
                _discard();
                return false;
            }
        }
        if (b == address(curated) || b == address(generic)) {
            try SysLocker(payable(b)).exec(address(r), call) {
                return true;
            } catch {
                _discard();
                return false;
            }
        }
        if (b != address(this)) vm.prank(b);
        (bool success,) = address(r).call(call);
        if (!success) _discard();
        return success;
    }

    /// @notice A beneficiary claims its Rules claim as tokens, or (one in four) as PoolManager ERC-6909 claims.
    function claim(uint256 seed) external {
        seed = _mix(seed, "claim");
        _begin("claim");
        HookrRules r = seed & 1 == 0 ? rules1 : rules2;
        Currency c = (seed >> 1) & 1 == 0 ? Currency.wrap(address(0)) : Currency.wrap(address(Q));
        address b = beneficiaries[(seed >> 8) % beneficiaries.length];
        if (r.claimable(c, b) == 0) return;
        address to = (seed >> 16) % 3 == 0 ? actors[(seed >> 20) % 4] : b;
        if (
            b == address(acct0) || b == address(acct1) || b == address(multicall) || b == address(curated)
                || b == address(generic) || b == address(this)
        ) {
            to = actors[(seed >> 20) % 4];
        }
        bool asClaims = (seed >> 24) % 4 == 0 && b != address(treasury);
        uint256 claimBefore = manager.balanceOf(to, c.toId());
        uint256 amount = r.claimable(c, b);
        if (_claimAs(b, r, c, to, asClaims)) {
            _hit(asClaims ? "rules.claimAsClaims" : "rules.claim");
            if (asClaims) {
                _addClaimHolder(to);
                if (manager.balanceOf(to, c.toId()) != claimBefore + amount) _flag("X2 claimAsClaims not exact");
            }
        } else {
            _flag("P11 beneficiary claim reverted");
        }
        _ingest();
    }

    function treasuryOps(uint256 seed) external {
        seed = _mix(seed, "treasuryOps");
        _begin("treasuryOps");
        uint256 which = seed % 3;
        address source = which == 0 ? address(rules1) : (which == 1 ? address(rules2) : address(vault));
        Currency[4] memory cs = [
            Currency.wrap(address(0)), Currency.wrap(address(Q)), Currency.wrap(address(SA)), Currency.wrap(address(SB))
        ];
        Currency c = cs[(seed >> 2) % (source == address(vault) ? 4 : 2)];
        uint256 mode = (seed >> 4) % 4;
        if (mode == 0) {
            try treasury.collect(source, c) {
                _hit("treasury.collect");
            } catch {
                _discard();
                _flag("P11 treasury.collect reverted");
            }
        } else if (mode == 1) {
            try treasury.collectTo(source, c) {
                _hit("treasury.collectTo");
            } catch {
                _discard();
                _flag("P11 treasury.collectTo reverted");
            }
        } else if (mode == 2) {
            try treasury.forwardBalance(c) {
                _hit("treasury.forward");
            } catch {
                _discard();
                _flag("P11 treasury.forwardBalance reverted");
            }
        } else if (source != address(vault)) {
            try treasury.collectAsClaims(source, c) {
                _hit("treasury.collectAsClaims");
            } catch {
                _discard();
                _flag("P11 treasury.collectAsClaims reverted");
            }
        } else {
            try vault.collectProtocolFees(c) {
                _hit("vault.collectProtocolFees");
            } catch {
                _discard();
                _flag("P11 vault.collectProtocolFees reverted");
            }
        }
        _ingest();
    }

    // ───────────── programs daily lifecycle ─────────────
    function programDay(uint256 seed) external {
        seed = _mix(seed, "programDay");
        _begin("programDay");
        IHookrPrograms.Program memory pr = programs.program(dailyId);
        if (block.timestamp < pr.terms.start + 1 days) return;
        uint256 elapsed = (block.timestamp - pr.terms.start) / 1 days;
        uint256 total = (pr.terms.end - pr.terms.start) / 1 days;
        if (elapsed > total) elapsed = total;
        uint256 day = seed % elapsed;
        IHookrPrograms.Epoch memory e = programs.epoch(dailyId, day);
        address who = actors[(seed >> 8) % 4];
        uint128 weight = uint128(bound(seed >> 16, 1, 1e18));
        if (e.version == 0 && block.timestamp < programs.dayEnd(dailyId, day) + programs.PROPOSAL_WINDOW()) {
            // dayLeaf reads the stored coverage hash, so a first proposal stores it and a second commits the leaf.
            vm.prank(ATTESTOR);
            programs.proposeDay(dailyId, day, bytes32(uint256(1)), 1, keccak256("cov"), keccak256("ev"));
            bytes32 leaf = programs.dayLeaf(dailyId, day, who, weight);
            vm.prank(ATTESTOR);
            programs.proposeDay(dailyId, day, leaf, weight, keccak256("cov"), keccak256("ev"));
            e = programs.epoch(dailyId, day);
            vm.prank(REVIEWER);
            programs.approveDay(dailyId, day, e.version);
            try programs.claimDay(dailyId, day, who, weight, new bytes32[](0)) {
                _hit("programs.claimDay");
            } catch {
                _discard();
                _flag("P7 claimDay of a single-leaf day reverted");
            }
        } else if (e.closed && !e.remainderReleased) {
            try programs.releaseUnusedCash(dailyId, day) {
                _hit("programs.release");
            } catch {
                _discard();
                _flag("P7 releaseUnusedCash reverted");
            }
        }
        for (uint256 i; i < 4; ++i) {
            if (programs.claimableCash(dailyId, actors[i]) != 0) {
                vm.prank(actors[i]);
                try programs.claimCash(dailyId, actors[i], actors[i], 0) {
                    _hit("programs.claimCash");
                } catch {
                    _discard();
                    _flag("P7 claimCash reverted");
                }
            }
        }
        _ingest();
    }

    /// @notice A stranger leaves PoolManager.sync(X) set (no unlock, no funds), then an exit or liquidity action runs in
    ///         the SAME transaction. Exits (claims, collects, withdrawals, dust removal, vault exits) and Launcher adds
    ///         must still work. The sync is cleared at the end, as the transaction's end would clear it. Swaps after a
    ///         stale sync are SYS-01's regression tests: HookrRouter and HookrQuoter clear the sync before they swap.
    function staleSyncThen(uint256 seed) external {
        seed = _mix(seed, "staleSyncThen");
        Currency[3] memory cs = [Currency.wrap(address(SA)), Currency.wrap(address(SB)), Currency.wrap(address(Q))];
        vm.prank(address(0xBAD5));
        manager.sync(cs[seed % 3]);
        uint256 op = (seed >> 4) % 6;
        if (op == 0) this.claim(seed >> 8);
        else if (op == 1) this.treasuryOps(seed >> 8);
        else if (op == 2) this.launcherWithdraw(seed >> 8);
        else if (op == 3) this.dustRemove(seed >> 8);
        else if (op == 4) this.vaultOps(((seed >> 8) / 5) * 5 + 1 + ((seed >> 12) & 1));
        else this.launcherAdd(seed >> 8);
        manager.sync(Currency.wrap(address(0)));
        _hit("staleSync.then");
    }

    // ───────────── protocol fee and clock ─────────────
    /// @notice The fee setter stores a Uniswap protocol fee for one pool, and anyone triggers it (V4FeeAdapter model).
    function protocolFee(uint256 seed) external {
        seed = _mix(seed, "protocolFee");
        _begin("protocolFee");
        bool pair = (seed >> 70) % 4 == 0;
        PoolKey memory k = pair ? pairKeys[seed % pairKeys.length] : keys[seed % keys.length];
        uint24 f0 = uint24(bound(seed >> 8, 0, 1000));
        uint24 f1 = uint24(bound(seed >> 24, 0, 1000));
        if ((seed >> 40) % 4 == 0) (f0, f1) = (0, 0);
        vm.prank(FEE_SETTER);
        feeAdapter.setPoolOverride(k.toId(), (f1 << 12) | f0);
        if ((seed >> 60) & 1 == 0) {
            vm.prank(actors[(seed >> 50) % 4]);
            feeAdapter.triggerFeeUpdate(k);
            _hit("protocolFee.set");
        } else {
            _hit("protocolFee.pending");
        }
        _ingest();
    }

    /// @notice Moves the clock in one of four steps: one parent block and 1 to 120 s (inside a Snipe decay or a
    ///         session ramp, 3 in 10), 1 to 30 blocks and up to an hour (4 in 10), 1 to 30 blocks and up to a day, so
    ///         any time of day (2 in 10), or exactly one day (1 in 10).
    function clock(uint256 seed) external {
        seed = _mix(seed, "clock");
        uint256 mode = seed % 10;
        uint256 blocks = mode < 3 ? 1 : bound(seed >> 8, 1, 30);
        uint256 secs;
        if (mode < 3) secs = bound(seed >> 16, 1, 120);
        else if (mode < 7) secs = bound(seed >> 16, 1, 3600);
        else if (mode < 9) secs = bound(seed >> 16, 1, 1 days);
        else secs = 1 days;
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + secs);
        if (paymaster.revenue(address(0)) != 0) paymaster.refillDeposit(paymaster.revenue(address(0)));
        _hit(mode < 3 ? "clock.small" : (mode < 7 ? "clock.hour" : (mode < 9 ? "clock.anyTime" : "clock.day")));
        _hitSession();
    }

    /// @dev Coverage: the tier the session-advised pool (index 3) is priced at now, or a ramp between two tiers.
    function _hitSession() internal {
        uint256 v = sessionAdvisory.surchargeAt(address(root1), keys[3].toId(), block.timestamp);
        IHookrSessionAdvisory.Bound memory b = frozenSession;
        string memory t = "ramp";
        if (v == b.regularPips) t = "regular";
        else if (v == b.preMarketPips) t = "preMarket";
        else if (v == b.afterHoursPips) t = "afterHours";
        else if (v == b.overnightPips) t = "overnight";
        else if (v == b.closedPips) t = "closed";
        _hit(string.concat("session.", t));
    }

    // ───────────── multicall bundle ─────────────
    struct Step {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice 2..8 steps in ONE transaction from one contract: Router swaps (with probes around each), Quoter then
    ///         swap pairs, quote -> triggerFeeUpdate -> swap triples, Forwarder executes relayed by the multicall
    ///         (probed for the signer), Rules claims and Treasury collects.
    function multicallBundle(uint256 seed) external {
        seed = _mix(seed, "multicallBundle");
        _begin("multicallBundle");
        probe.clear();
        uint256 n = 2 + seed % 7;
        Step[] memory steps = new Step[](n * 5);
        uint256[] memory kind = new uint256[](n * 5); // 2 quote-before-swap, 3 swap-after-quote, 4/5 with trigger
        uint256 k;
        uint256 s = seed;
        address mc = address(multicall);
        for (uint256 i; i < n; ++i) {
            s = uint256(keccak256(abi.encode(s, i)));
            uint256 op = s % 6;
            uint256 p = (s >> 8) % keys.length;
            HookrRules r = _rules(p);
            address q = Currency.unwrap(_quoteOf(p));
            if (op <= 1 || op == 5) {
                IHookrRouter.Swap memory sw = _params(
                    p, (s >> 16) & 1 == 0, (s >> 17) % 4 != 0, _swapAmount(s >> 40, 3e19), (s >> 20) % 5 == 0, mc
                );
                (address engagement, uint256[] memory ids) = _campaigns((s >> 24) & 1 == 1, p);
                uint256 value = _nativeIn(sw) ? _maxIn(sw) : 0;
                if (op == 1) {
                    steps[k] = Step(address(quoter), 0, abi.encodeCall(quoter.quote, (sw, mc)));
                    kind[k++] = 2;
                } else if (op == 5) {
                    steps[k] = Step(address(quoter), 0, abi.encodeCall(quoter.quote, (sw, mc)));
                    kind[k++] = 4;
                    PoolKey memory kp = keys[p];
                    steps[k++] = Step(address(feeAdapter), 0, abi.encodeCall(feeAdapter.triggerFeeUpdate, (kp)));
                    _feeTouched = true;
                }
                steps[k++] = Step(address(probe), 0, abi.encodeCall(probe.snap, (address(r), mc, q, address(treasury))));
                steps[k] = Step(address(router), value, abi.encodeCall(router.swap, (sw, engagement, ids)));
                kind[k++] = op == 1 ? 3 : (op == 5 ? 5 : 1);
                steps[k++] = Step(address(probe), 0, abi.encodeCall(probe.snap, (address(r), mc, q, address(treasury))));
            } else if (op == 2) {
                uint256 oi = (s >> 30) % 4;
                IHookrForwarder.HookrSwapIntent memory it = _intent(s, oi, mc);
                bytes memory sig = _sign(it, actorPk[oi]);
                HookrRules fr = address(it.key.hooks) == address(root1) ? rules1 : rules2;
                address fq = Currency.unwrap(HookrRoot(address(it.key.hooks)).poolConfig(it.key.toId()).quote);
                steps[k++] = Step(
                    address(probe), 0, abi.encodeCall(probe.snap, (address(fr), actors[oi], fq, address(treasury)))
                );
                steps[k++] = Step(address(fwd), 0, abi.encodeCall(fwd.execute, (it, actors[oi], sig)));
                steps[k++] = Step(
                    address(probe), 0, abi.encodeCall(probe.snap, (address(fr), actors[oi], fq, address(treasury)))
                );
            } else if (op == 3) {
                Currency c = (s >> 9) & 1 == 0 ? Currency.wrap(address(0)) : Currency.wrap(address(Q));
                if (r.claimable(c, mc) != 0) {
                    steps[k++] = Step(address(r), 0, abi.encodeCall(r.claimTo, (c, actors[0])));
                }
            } else {
                steps[k++] =
                    Step(address(treasury), 0, abi.encodeCall(treasury.collect, (address(r), Currency.wrap(q))));
            }
        }
        address[] memory t = new address[](k);
        uint256[] memory v = new uint256[](k);
        bytes[] memory d = new bytes[](k);
        for (uint256 i; i < k; ++i) {
            (t[i], v[i], d[i]) = (steps[i].target, steps[i].value, steps[i].data);
        }
        try multicall.exec(t, v, d) returns (bytes[] memory out) {
            _hit("multicall.bundle");
            _checkMulticall(out, kind, k);
            _checkProbe();
        } catch (bytes memory err) {
            _discard();
            _hitErr("multicall.revert", err);
        }
        _ingest();
    }

    function _checkMulticall(bytes[] memory out, uint256[] memory kind, uint256 k) internal {
        for (uint256 i; i + 2 < k; ++i) {
            if (kind[i] != 2 && kind[i] != 4) continue;
            // quote at i, [trigger], probe, swap
            uint256 j = kind[i] == 2 ? i + 2 : i + 3;
            if (j >= k || (kind[j] != 3 && kind[j] != 5)) continue;
            HookrTypes.ExecutionReceipt memory rc = abi.decode(out[i], (HookrTypes.ExecutionReceipt));
            (uint256 aIn, uint256 aOut) = abi.decode(out[j], (uint256, uint256));
            if (rc.inputAmount != aIn || rc.outputAmount != aOut) {
                if (kind[i] == 2) _flag("P9 multicall quote differs from the adjacent swap");
                else ++quoteMismatchAfterTrigger;
            }
            _hit(kind[i] == 2 ? "multicall.quoteThenSwap" : "multicall.quoteTriggerSwap");
        }
    }

    function _checkProbe() internal {
        uint256 c = probe.count();
        for (uint256 i; i + 1 < c; i += 2) {
            SysProbe.Snap memory a = probe.snapAt(i);
            SysProbe.Snap memory b = probe.snapAt(i + 1);
            if (b.paid - a.paid != b.protocolClaim - a.protocolClaim) {
                _flag("P5 in-transaction PROTOCOL_PAID step differs from the protocol claim step");
            }
        }
        if (c != 0) _hit("probe.pairs");
    }

    // ───────────── ERC-4337 bundle ─────────────
    function _opCalls(uint256 s, SysAccount a) internal returns (bytes memory callData) {
        uint256 n = 1 + s % 3;
        address[] memory dest = new address[](n);
        uint256[] memory values = new uint256[](n);
        bytes[] memory funcs = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            s = uint256(keccak256(abi.encode(s, i)));
            uint256 op = s % 5;
            uint256 p = (s >> 8) % keys.length;
            if (op <= 2) {
                IHookrRouter.Swap memory sw = _params(
                    p,
                    (s >> 16) & 1 == 0,
                    (s >> 17) % 4 != 0,
                    _swapAmount(s >> 40, 1e19),
                    (s >> 20) % 5 == 0,
                    address(a)
                );
                (address engagement, uint256[] memory ids) = _campaigns((s >> 24) & 1 == 1, p);
                dest[i] = address(router);
                values[i] = _nativeIn(sw) ? _maxIn(sw) : 0;
                funcs[i] = abi.encodeCall(router.swap, (sw, engagement, ids));
            } else if (op == 3) {
                uint256 oi = (s >> 30) % 4;
                IHookrForwarder.HookrSwapIntent memory it = _intent(s, oi, address(a));
                dest[i] = address(fwd);
                funcs[i] = abi.encodeCall(fwd.execute, (it, actors[oi], _sign(it, actorPk[oi])));
            } else {
                HookrRules r = (s >> 9) & 1 == 0 ? rules1 : rules2;
                Currency c = (s >> 10) & 1 == 0 ? Currency.wrap(address(0)) : Currency.wrap(address(Q));
                if (r.claimable(c, address(a)) == 0) {
                    IHookrRouter.Swap memory sw2 =
                        _params(p, false, true, uint128(bound(s >> 40, 1e14, 1e19)), false, address(a));
                    dest[i] = address(router);
                    funcs[i] = abi.encodeCall(router.swap, (sw2, address(0), new uint256[](0)));
                } else {
                    dest[i] = address(r);
                    funcs[i] = abi.encodeCall(HookrRules.claim, (c));
                }
            }
        }
        callData = abi.encodeWithSelector(SysAccount.executeBatch.selector, dest, values, funcs);
    }

    function _userOp(SysAccount a, uint256 nonce, bytes memory callData, bool tokenMode)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = address(a);
        op.nonce = nonce;
        op.callData = callData;
        op.accountGasLimits = bytes32((uint256(200_000) << 128) | uint256(6_000_000));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(1 gwei));
        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(400_000),
            uint128(300_000),
            uint8(tokenMode ? 1 : 0),
            tokenMode ? address(Q) : address(0),
            type(uint128).max,
            uint48(vm.getBlockTimestamp() + 1 days)
        );
    }

    /// @notice One EntryPoint.handleOps carrying 2..4 ops from 2 accounts (CREDIT and TOKEN modes, rebates on).
    function bundle4337(uint256 seed) external {
        seed = _mix(seed, "bundle4337");
        _begin("bundle4337");
        uint256 n = 2 + seed % 3;
        PackedUserOperation[] memory ops = new PackedUserOperation[](n);
        uint256[2] memory used;
        SysAccount[2] memory accts = [acct0, acct1];
        uint256 s = seed;
        for (uint256 i; i < n; ++i) {
            s = uint256(keccak256(abi.encode(s, i, "op")));
            uint256 ai = i < 2 ? (i + (seed >> 3)) % 2 : s % 2;
            SysAccount a = accts[ai];
            uint256 nonce = ISysEntryPoint(EP).getNonce(address(a), 0) + used[ai]++;
            ops[i] = _userOp(a, nonce, _opCalls(s >> 1, a), (s >> 200) & 1 == 1);
        }
        uint256[4] memory b0 = _paid(address(acct0));
        uint256[4] memory b1 = _paid(address(acct1));
        _rebateOf[address(acct0)] = 0;
        _rebateOf[address(acct1)] = 0;
        vm.prank(BUNDLER, BUNDLER);
        try ISysEntryPoint(EP).handleOps(ops, payable(BUNDLER)) {
            _hit("4337.handleOps");
        } catch {
            _discard();
            _hit("4337.revert");
        }
        _ingest();
        _rebateBound(address(acct0), b0);
        _rebateBound(address(acct1), b1);
    }

    /// @dev P5b: rebates to one account in this transaction stay within rebateBps x the protocol fees it paid in it.
    function _rebateBound(address a, uint256[4] memory before) internal {
        uint256[4] memory afterPaid = _paid(a);
        uint256 native = (afterPaid[0] - before[0]) + (afterPaid[2] - before[2]);
        uint256 quote = (afterPaid[1] - before[1]) + (afterPaid[3] - before[3]);
        uint256 feeWei = native + quote * 1e18 / Q_PER_ETH;
        if (_rebateOf[a] > feeWei * 5_000 / 10_000 + 1) {
            _flag("P5b rebates exceed rebateBps x fees the account paid this tx");
        }
    }

    // ═════════════════════════════ features the audit never saw ═════════════════════════════

    /// @dev A new-token member opening at price 1 whose band sits on the subject's side of that price and holds
    ///      `amount` subject and no quote (as DevBuyFixture).
    function _devMember(address subject, Currency quote, uint256 amount, address rules_)
        internal
        view
        returns (IHookrLauncher.Member memory m)
    {
        m = _member(quote, rules_);
        bool subjectIs0 = uint160(subject) < uint160(Currency.unwrap(quote));
        m.tickLower = subjectIs0 ? int24(0) : int24(-60_000);
        m.tickUpper = subjectIs0 ? int24(60_000) : int24(0);
        uint160 lower = TickMath.getSqrtPriceAtTick(m.tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(m.tickUpper);
        uint128 liquidity = subjectIs0
            ? LiquidityAmounts.getLiquidityForAmount0(lower, upper, amount)
            : LiquidityAmounts.getLiquidityForAmount1(lower, upper, amount);
        m.liquidity = liquidity / 1000 * 999;
        m.amount0Max = subjectIs0 ? uint128(amount) : 0;
        m.amount1Max = subjectIs0 ? 0 : uint128(amount);
    }

    /// @notice launchWithBuy: a new token with 1 or 2 members on root1, the dev buy on member 0 with a random base LP
    ///         fee (3,000 one time in four, else 0 to 10%), guard (10 to 200 blocks, one in eight 10,000 to the 100,000
    ///         maximum), Snipe (flat or decaying), buy cap, dynamic fee, protocol share, buy size (one in eight at the
    ///         cap) and lock (one in eight at the 2,628,000 maximum, one in eight above 500). Checks, on every launch
    ///         that succeeds: DB1 the creator holds at most 5% of supply; DB3 the principal lock is the later of every
    ///         guard and the dev buy's lock; DB4 exactly one DevBuyExecuted and one Launcher swap; DB2 a public buy in
    ///         the same parent block does not clear.
    function launchDevBuy(uint256 seed) external {
        if (_families.length >= MAX_FAMILIES) return;
        seed = _mix(seed, "launchDevBuy");
        uint256 e = _mix(seed, "launchDevBuy.edges");
        _begin("launchDevBuy");
        address creator = actors[seed % 4];
        bool native = (seed >> 2) & 1 == 0;
        uint256 n = 1 + ((seed >> 3) & 1);
        // Placing under 95% of supply leaves the creator above the 5% cap before any buy: one launch in four probes
        // that refusal, the rest place 96% or more.
        uint256 placeBps = (e >> 160) % 4 == 0 ? bound(seed >> 8, 9_000, 9_990) : bound(seed >> 8, 9_600, 9_990);
        IHookrLauncher.Token memory t =
            IHookrLauncher.Token(address(0), "Dev", "DEV", DEV_SUPPLY, bytes32(++_tokenSalt));
        address subject = launcher.predictToken(creator, t);
        IHookrLauncher.Member[] memory ms = new IHookrLauncher.Member[](n);
        Currency q0 = native ? Currency.wrap(address(0)) : Currency.wrap(address(Q));
        Currency q1 = native ? Currency.wrap(address(Q)) : Currency.wrap(address(0));
        uint256 placed = DEV_SUPPLY * placeBps / BPS;
        ms[0] = _devMember(subject, q0, n == 1 ? placed : placed * 6 / 10, address(rules1));
        if (n == 2) ms[1] = _devMember(subject, q1, placed - placed * 6 / 10, address(rules1));
        uint256 base = 3000;
        if ((e >> 8) % 4 == 1) base = bound(e >> 16, 0, 500);
        else if ((e >> 8) % 4 == 2) base = bound(e >> 16, 501, 30_000);
        else if ((e >> 8) % 4 == 3) base = bound(e >> 16, 30_001, 100_000);
        ms[0].config.baseLpFeePips = uint24(base);
        HookrTypes.RulesConfig memory c = ms[0].rules;
        c.maxFeePips = uint24(base);
        bool longGuard = (e >> 40) % 8 == 0;
        c.guardEndBlock =
            uint40(vm.getBlockNumber() + (longGuard ? bound(e >> 48, 10_000, 100_000) : bound(seed >> 24, 10, 200)));
        c.snipeTaxPips = uint24(bound(seed >> 40, 10_000, 500_000));
        if ((seed >> 60) & 1 == 1) {
            c.snipeDecaySeconds = uint16(bound(seed >> 64, 1, 3600));
            c.snipeFloorPips = uint24(bound(seed >> 80, 0, c.snipeTaxPips - 1));
        }
        c.maxBuyQuoteAmount = uint128(bound(seed >> 96, 1e18, 1e22));
        if ((seed >> 112) & 1 == 1) {
            c.dynamicFeeSens = uint16(bound(seed >> 116, 1, 10));
            c.maxFeePips = uint24(base + bound(seed >> 124, 1_000, 200_000));
        }
        if ((seed >> 144) & 1 == 1) {
            c.burnBps = 100;
            c.lpBps = 200;
            c.royaltyBps = 500;
            c.royaltyTo = ROYALTY_A;
        }
        c.protocolShareBps = uint16(bound(seed >> 150, MIN_SHARE, 5_000));
        if (c.dynamicFeeSens != 0) {
            // At most the widest span the reach bound admits at the sensitivity and share (HookrDynamicFee.withinReach).
            uint256 sens2 = uint256(c.dynamicFeeSens) * c.dynamicFeeSens;
            uint256 widest = HookrDynamicFee.MAX_REACH / sens2;
            uint256 reserve = HookrDynamicFee.MAX_RESERVE * HookrDynamicFee.RESERVE_SCALE
                / (uint256(c.protocolShareBps) * (HookrDynamicFee.RESERVE_SCALE - sens2));
            if (reserve < widest) widest = reserve;
            if (c.maxFeePips > base + widest) c.maxFeePips = uint24(base + widest);
        }
        // One launch in four names the integrator with a zero Hookr minimum override without its approval: the pool
        // must bind the plain rate (M0).
        if ((e >> 200) % 4 == 0) c.integrator = INTEGRATOR_C;
        ms[0].rules = c;
        uint256 quoteIn = (e >> 80) % 8 == 0 ? c.maxBuyQuoteAmount : bound(seed >> 170, 1e15, c.maxBuyQuoteAmount);
        uint256 lockMode = (e >> 120) % 8;
        uint256 lockBlocks =
            lockMode == 0 ? MAX_LOCK : (lockMode == 1 ? bound(e >> 128, 501, MAX_LOCK) : bound(seed >> 200, 0, 500));
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, uint128(quoteIn), 1, uint32(lockBlocks));
        uint256 value = native ? buy.quoteIn : 0;
        uint256 expectedLock = vm.getBlockNumber() + buy.lockBlocks;
        if (c.guardEndBlock > expectedLock) expectedLock = c.guardEndBlock;
        _inDevBuy = true;
        vm.prank(creator);
        try launcher.launchWithBuy{value: value}(
            t, address(root1), ms, new bytes[](n), buy, vm.getBlockTimestamp()
        ) returns (
            bytes32 fam, address sub, uint256
        ) {
            _inDevBuy = false;
            ++devLaunches;
            _hit("devbuy.launch");
            _hit(c.snipeDecaySeconds != 0 ? "devbuy.decayingSnipe" : "devbuy.flatSnipe");
            _hit(c.dynamicFeeSens != 0 ? "devbuy.dynamicFee" : "devbuy.staticFee");
            _hit(c.royaltyBps != 0 ? "devbuy.royalty" : "devbuy.noRoyalty");
            _hit(c.protocolShareBps == MIN_SHARE ? "devbuy.shareAtFloor" : "devbuy.shareAboveFloor");
            _hit(base == 3000 ? "devbuy.base3000" : "devbuy.baseOther");
            if (longGuard) _hit("devbuy.longGuard");
            if (quoteIn == c.maxBuyQuoteAmount) _hit("devbuy.buyAtCap");
            if (lockBlocks == MAX_LOCK) _hit("devbuy.lockMax");
            else _hit(lockBlocks > 500 ? "devbuy.lockLong" : "devbuy.lockShort");
            _families.push(fam);
            familyLock[fam] = expectedLock;
            _devSubjects.push(sub);
            if (IERC20(sub).balanceOf(creator) > DEV_SUPPLY / 20) {
                _flag("DB1 creator holds more than 5% after launchWithBuy");
            }
            if (launcher.principalLockedUntil(fam) != expectedLock) {
                _flag("DB3 principal lock is not the later of the guards and the dev buy lock");
            }
            uint256 first = keys.length;
            if (keys.length + n <= MAX_POOLS) {
                for (uint8 i; i < n; ++i) {
                    _push(launcher.position(fam, i).key, fam, i, true, ms[i].rules.dynamicFeeSens != 0, false, creator);
                }
            }
            for (uint256 i; i < 4; ++i) {
                _approveAll(actors[i], sub);
            }
            // The dev buy's own logs: its guard counter closes the parent block.
            _inDevBuy = true;
            _ingest();
            _inDevBuy = false;
            if (_callDevBuyLogs != 1 || _callLauncherSwaps != 1) {
                _flag("DB4 not exactly one dev buy and one Launcher swap");
            }
            if (first < keys.length) _publicBuyInLaunchBlock(first, creator);
        } catch (bytes memory err) {
            _inDevBuy = false;
            _discard();
            if (err.length >= 4 && bytes4(err) == IHookrLauncher.DevBuyAboveCap.selector) _hit("devbuy.aboveCap");
            else _hitErr("devbuy.revert", err);
            if (longGuard) _hitErr("devbuy.longGuard.revert", err);
            _ingest();
        }
    }

    /// @dev DB2: another buyer's buy on the dev-buy member in the launch's parent block never clears.
    function _publicBuyInLaunchBlock(uint256 p, address creator) internal {
        _begin("launchDevBuy.publicBuy");
        address buyer = actors[0] == creator ? actors[1] : actors[0];
        IHookrRouter.Swap memory s = _params(p, true, true, 1e15, false, buyer);
        uint256 value = _nativeIn(s) ? _maxIn(s) : 0;
        vm.prank(buyer);
        try router.swap{value: value}(s, address(0), new uint256[](0)) {
            _flag("DB2 a public buy cleared in the dev buy's parent block");
        } catch {
            _discard();
            _hit("devbuy.blockClosed");
        }
        _ingest();
    }

    /// @notice The per-parent-block buy cap at its edge: an exact-input router buy on a guarded, capped root pool,
    ///         sized to the parent block's room under the decayed cap less one, exactly, plus one, plus two, or plus up
    ///         to the whole cap again (one in three). G1 (at the swap's HookFee) flags such a buy that clears past the
    ///         cap; G3 flags a buy within the room that the cap refused, outside a parent block a dev buy closed.
    function nearCapBuy(uint256 seed) external {
        seed = _mix(seed, "nearCapBuy");
        _begin("nearCapBuy");
        uint256 p = type(uint256).max;
        HookrTypes.RulesConfig memory c;
        for (uint256 i; i < keys.length; ++i) {
            uint256 j = (seed % keys.length + i) % keys.length;
            c = _rules(j).config(keys[j].toId());
            if (vm.getBlockNumber() < c.guardEndBlock && c.maxBuyQuoteAmount != 0) {
                p = j;
                break;
            }
        }
        if (p == type(uint256).max) {
            _hit("nearCap.noGuardedPool");
            return;
        }
        uint256 limit = _capNow(p, c);
        if (limit >= type(uint128).max) {
            _hit("nearCap.capLifted");
            return;
        }
        uint256 word = _guardWord[p];
        uint256 spent = word >> 192 == vm.getBlockNumber() ? uint256(uint192(word)) : 0;
        uint256 room = spent < limit ? limit - spent : 0;
        uint256 mode = (seed >> 16) % 6;
        uint256 amount = mode < 4 ? room + mode : room + 1 + bound(seed >> 24, 1, limit);
        amount = amount > 1 ? amount - 1 : 1;
        address actor = actors[(seed >> 8) % 4];
        IHookrRouter.Swap memory s = _params(p, true, true, uint128(amount), false, actor);
        uint256 value = _nativeIn(s) ? amount : 0;
        if (value > actor.balance || (value == 0 && _quoteOf(p).balanceOf(actor) < amount)) {
            _hit("nearCap.unaffordable");
            return;
        }
        bool closed = _closedBlock[p] == vm.getBlockNumber() + 1;
        uint256[4] memory before = _paid(actor);
        vm.prank(actor);
        try router.swap{value: value}(s, address(0), new uint256[](0)) {
            _hit(amount > room ? "nearCap.clearedPastRoom" : "nearCap.clearedWithinRoom");
        } catch (bytes memory err) {
            _discard();
            if (!_capRefusal(p, err)) {
                _hitErr("nearCap.revert", err);
            } else if (amount > room || closed) {
                _hit("nearCap.refusedPastRoom");
            } else {
                _flag(
                    string.concat(
                        "G3 the cap refused an exact-input buy within the parent block's room: pool ",
                        vm.toString(p),
                        " amount ",
                        vm.toString(amount),
                        " room ",
                        vm.toString(room)
                    )
                );
            }
        }
        _ingest();
        _checkPaid(actor, before);
    }

    /// @dev Whether a router swap reverted because the pool's Rules refused its settlement with the guard's buy cap:
    ///      GuardBuyLimit in settleSwap, the one refusal settleSwap makes on an exact-input buy, which the root carries in
    ///      ModuleCallReverted.
    function _capRefusal(uint256 p, bytes memory err) internal view returns (bool) {
        bytes memory inner = _inner(err);
        if (inner.length >= 4 && bytes4(inner) == 0x90bfb865) inner = _inner(inner);
        if (inner.length < 164 || bytes4(inner) != IHookrRootEvents.ModuleCallReverted.selector) return false;
        bytes memory body = new bytes(inner.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = inner[i + 4];
        }
        (address module, bytes4 selector, bytes memory reason) = abi.decode(body, (address, bytes4, bytes));
        return module == address(_rules(p)) && selector == HookrRules.settleSwap.selector && reason.length == 68
            && bytes4(reason) == IHookrRulesState.GuardBuyLimit.selector;
    }

    /// @notice PS1: a pool never binds with a protocol share below Rules' floor. Tries a launch one or more basis
    ///         points under it; the launch must revert.
    function floorProbe(uint256 seed) external {
        seed = _mix(seed, "floorProbe");
        _begin("floorProbe");
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Low", "LOW", 1e24, bytes32(++_tokenSalt));
        IHookrLauncher.Member[] memory ms = new IHookrLauncher.Member[](1);
        HookrRules r = seed & 1 == 0 ? rules1 : rules2;
        ms[0] = _member(Currency.wrap(address(Q)), address(r));
        ms[0].rules.protocolShareBps = uint16(bound(seed >> 8, 0, r.minProtocolShareBps() - 1));
        vm.prank(actors[(seed >> 1) % 4]);
        try launcher.launch(t, address(r.trustedRoot()), ms, vm.getBlockTimestamp()) {
            _flag("PS1 a launch bound a pool below minProtocolShareBps");
        } catch {
            _discard();
            _hit("floor.refused");
        }
        _ingest();
    }

    /// @notice The fee advisory's keeper reprices a root pool or the advised pair pool within (or outside) its frozen
    ///         bounds. FA1: an accepted target never exceeds the cap; FA2: an accepted step never exceeds maxStep.
    function keeperReprice(uint256 seed) external {
        seed = _mix(seed, "keeperReprice");
        _begin("keeperReprice");
        bool pair = seed & 1 == 1;
        PoolId id = pair ? pairKeys[1].toId() : keys[2].toId();
        uint24 target = uint24(bound(seed >> 8, 0, 25_000));
        uint24 p0 = uint24(bound(seed >> 32, 0, 5_000));
        uint24 p1 = uint24(bound(seed >> 56, 0, 5_000));
        uint32 ttl = uint32(bound(seed >> 80, 1, 2 hours));
        IHookrFeeAdvisory.Bounds memory b = feeAdvisory.poolBounds(id);
        IHookrFeeAdvisory.State memory s0 = feeAdvisory.poolState(id);
        bool live = s0.expiry > block.timestamp;
        uint256 cur0 = live ? s0.target0 : s0.default0;
        uint256 cur1 = live ? s0.target1 : s0.default1;
        vm.prank(KEEPER);
        try feeAdvisory.reprice(id, target, p0, p1, ttl) {
            _hit(pair ? "keeper.reprice.pair" : "keeper.reprice");
            uint256 next0 = uint256(target) + p0;
            uint256 next1 = uint256(target) + p1;
            if (next0 > b.cap || next1 > b.cap) _flag("FA1 a keeper target above the frozen cap was accepted");
            uint256 step0 = next0 > cur0 ? next0 - cur0 : cur0 - next0;
            uint256 step1 = next1 > cur1 ? next1 - cur1 : cur1 - next1;
            if (step0 > b.maxStep || step1 > b.maxStep) _flag("FA2 a keeper step above maxStep was accepted");
        } catch (bytes memory err) {
            _discard();
            _hitErr("keeper.revert", err);
        }
        _ingest();
    }

    /// @notice A swap on a pair pool through a locker. PR1: the caller's delta equals the pool's own swap delta (the
    ///         pair root returns no delta); PR2 (in _checkSwapFee): the fee is base plus the clamped surcharge. One in
    ///         four calls instead tries to initialize a second pool on the pair root (PR4).
    function pairSwap(uint256 seed) external {
        seed = _mix(seed, "pairSwap");
        _begin("pairSwap");
        uint256 q = (seed >> 100) % pairKeys.length;
        if (seed % 4 == 0) {
            // PR4: a pair root serves exactly one pool; any other key naming it is refused at initialization.
            PoolKey memory squat = pairKeys[q];
            squat.tickSpacing = squat.tickSpacing == 60 ? int24(10) : int24(60);
            vm.prank(actors[(seed >> 3) % 4]);
            try manager.initialize(squat, uint160(1 << 96)) {
                _flag("PR4 a pair root admitted a second pool");
            } catch {
                _hit("pair.squatRefused");
            }
            return;
        }
        SysLocker L = (seed >> 2) & 1 == 0 ? generic : curated;
        address actor = actors[(seed >> 3) % 4];
        SysLocker.Act[] memory acts = new SysLocker.Act[](1);
        acts[0] = _swapAct(pairKeys[q], q, true, seed >> 8);
        vm.prank(actor);
        try L.run{value: 1e22}(acts) returns (int256[] memory out) {
            _hit("pair.swap");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bytes32 id = PoolId.unwrap(pairKeys[q].toId());
            for (uint256 i; i < logs.length; ++i) {
                Vm.Log memory l = logs[i];
                if (l.emitter != address(manager) || l.topics.length < 3 || l.topics[0] != PM_SWAP || l.topics[1] != id)
                {
                    continue;
                }
                (int128 a0, int128 a1) = abi.decode(l.data, (int128, int128));
                ++pairDeltaChecks;
                if (int256(a0) != out[0] || int256(a1) != out[1]) _flag("PR1 a pair root returned a swap delta");
                _checkSwapFee(pairKeys[q], acts[0].zeroForOne, true, _swapFeeOf(l), q, true);
            }
        } catch (bytes memory err) {
            _discard();
            _hitErr("pair.revert", err);
        }
    }

    function _swapFeeOf(Vm.Log memory l) internal pure returns (uint24 fee) {
        (,,,,, fee) = abi.decode(l.data, (int128, int128, uint160, uint128, int24, uint24));
    }

    // ───────────── liquidity vault ─────────────
    function _openRange(bool pair, uint256 p, int24 lo, int24 hi) internal {
        PoolKey memory k = _anyKey(pair, p);
        uint256 id = vault.rangeId(k.toId(), lo, hi);
        _ranges.push(Range(pair, uint8(p), lo, hi, id));
        _rangeCurrencies[id] = [k.currency0, k.currency1];
    }

    function _vaultDeposit(uint256 a, uint256 r, uint256 amount0, uint256 amount1) internal returns (bool ok) {
        Range memory g = _ranges[r];
        PoolKey memory k = _anyKey(g.pair, g.pool);
        address actor = actors[a];
        uint256 value = Currency.unwrap(k.currency0) == address(0) ? amount0 : 0;
        IHookrLiquidityVault.DepositParams memory d = IHookrLiquidityVault.DepositParams(
            k, g.lower, g.upper, amount0, amount1, 0, 0, actor, vm.getBlockTimestamp() + 10
        );
        uint256 b0 = k.currency0.balanceOf(actor);
        uint256 b1 = k.currency1.balanceOf(actor);
        uint256 sharesBefore = vault.balanceOf(actor, g.id);
        vm.prank(actor);
        try vault.deposit{value: value}(d) returns (uint256, uint128 liquidity, uint256 paid0, uint256 paid1) {
            ok = true;
            if (liquidity == 0) _flag("V1 a deposit minted no shares");
            if (vault.balanceOf(actor, g.id) != sharesBefore + liquidity) {
                _flag("V1 shares minted differ from liquidity");
            }
            // The depositor pays exactly what the pool took, never more than desired; native change is refunded.
            if (
                b0 - k.currency0.balanceOf(actor) != paid0 || b1 - k.currency1.balanceOf(actor) != paid1
                    || paid0 > amount0 || paid1 > amount1
            ) _flag("V1 a deposit charged other than the amounts the pool took");
        } catch (bytes memory err) {
            _discard();
            _hitErr("vault.deposit.revert", err);
        }
    }

    /// @notice Vault deposit, withdraw, claim, poke, share transfer. V1: a deposit mints its liquidity as shares and
    ///         charges exactly what the pool took; V2: a withdrawal returns exactly the principal of the burned
    ///         liquidity at the current price (one unit of rounding) plus the fees it reports; V5: a claim pays exactly
    ///         the fees it reports.
    function vaultOps(uint256 seed) external {
        // The mode is the raw seed's low digit, so staleSyncThen can ask for an exit; everything else is read from the
        // seed's hash.
        uint256 mode = seed % 5;
        seed = _mix(seed, "vaultOps");
        _begin("vaultOps");
        uint256 r = (seed >> 3) % _ranges.length;
        Range memory g = _ranges[r];
        PoolKey memory k = _anyKey(g.pair, g.pool);
        uint256 ai = (seed >> 8) % 4;
        // Withdrawals, claims and transfers go to a holder of the range when there is one.
        if (mode != 0 && mode != 3 && vault.balanceOf(actors[ai], g.id) == 0) {
            for (uint256 i = 1; i < 4; ++i) {
                if (vault.balanceOf(actors[(ai + i) % 4], g.id) != 0) {
                    ai = (ai + i) % 4;
                    break;
                }
            }
        }
        address actor = actors[ai];
        uint256 shares = vault.balanceOf(actor, g.id);
        if (mode == 0 || (shares == 0 && mode != 3)) {
            if (_vaultDeposit(ai, r, bound(seed >> 16, 1e15, 1e20), bound(seed >> 80, 1e15, 1e20))) {
                _hit("vault.deposit");
            }
        } else if (mode == 1) {
            uint128 liq = uint128(bound(seed >> 16, 1, shares));
            (uint160 sqrtP,,,) = manager.getSlot0(k.toId());
            (uint256 e0, uint256 e1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtP, TickMath.getSqrtPriceAtTick(g.lower), TickMath.getSqrtPriceAtTick(g.upper), liq
            );
            uint256 b0 = k.currency0.balanceOf(actor);
            uint256 b1 = k.currency1.balanceOf(actor);
            vm.prank(actor);
            try vault.withdraw(
                IHookrLiquidityVault.WithdrawParams(k, g.lower, g.upper, liq, 0, 0, actor, vm.getBlockTimestamp() + 10)
            ) returns (
                uint256 a0, uint256 a1, uint256 f0, uint256 f1
            ) {
                _hit("vault.withdraw");
                ++vaultPrincipalChecks;
                if (a0 + 1 < e0 || a0 > e0 + 1 || a1 + 1 < e1 || a1 > e1 + 1) {
                    _flag("V2 vault withdrawal principal differs from the burned liquidity's amounts");
                }
                if (k.currency0.balanceOf(actor) - b0 != a0 + f0 || k.currency1.balanceOf(actor) - b1 != a1 + f1) {
                    _flag("V2 vault withdrawal paid other than principal plus fees");
                }
            } catch (bytes memory err) {
                _discard();
                _hitErr("vault.withdraw.revert", err);
                _flag("P11 vault withdrawal reverted");
            }
        } else if (mode == 2) {
            uint256 b0 = k.currency0.balanceOf(actor);
            uint256 b1 = k.currency1.balanceOf(actor);
            vm.prank(actor);
            try vault.claim(k, g.lower, g.upper, actor) returns (uint256 f0, uint256 f1) {
                _hit("vault.claim");
                if (k.currency0.balanceOf(actor) - b0 != f0 || k.currency1.balanceOf(actor) - b1 != f1) {
                    _flag("V5 vault fee claim paid other than the fees it reports");
                }
            } catch (bytes memory err) {
                _discard();
                _hitErr("vault.claim.revert", err);
                _flag("P11 vault fee claim reverted");
            }
        } else if (mode == 3) {
            if (vault.totalSupply(g.id) == 0) return;
            try vault.poke(k, g.lower, g.upper) {
                _hit("vault.poke");
            } catch (bytes memory err) {
                _discard();
                _hitErr("vault.poke.revert", err);
                _flag("P11 vault poke reverted");
            }
        } else {
            address to = actors[(ai + 1 + (seed >> 12) % 3) % 4];
            uint256 amount = bound(seed >> 16, 1, shares);
            vm.prank(actor);
            try vault.transfer(to, g.id, amount) {
                _hit("vault.transfer");
            } catch (bytes memory err) {
                _discard();
                _hitErr("vault.transfer.revert", err);
                _flag("P11 vault share transfer reverted");
            }
        }
        _ingest();
    }

    // ═════════════════════════════ liveness (not a fuzz target) ═════════════════════════════

    /// @notice P11/L: every party exits: dust LPs, family owners (after the last lock), ERC-6909 claim holders, every
    ///         Rules claim, Treasury collection, vault holders and the vault's protocol fees, Programs cash and
    ///         Paymaster credit.
    function liveness() external {
        _begin("liveness");
        uint256 end;
        for (uint256 f; f < _families.length; ++f) {
            uint256 l = launcher.principalLockedUntil(_families[f]);
            if (l > end) end = l;
        }
        if (vm.getBlockNumber() <= end) vm.roll(end + 1);
        while (_dust.length != 0) {
            Dust memory d = _dust[_dust.length - 1];
            SysLocker.Act[] memory acts = new SysLocker.Act[](1);
            acts[0] = SysLocker.Act(
                1, _anyKey(d.pair, d.pool), false, -int256(uint256(d.liquidity)), 0, d.lower, d.upper, d.salt
            );
            try generic.run(acts) {}
            catch {
                _discard();
                _flag("L dust removal failed");
            }
            _dust.pop();
        }
        for (uint256 f; f < _families.length; ++f) {
            bytes32 fam = _families[f];
            address owner = launcher.familyOwner(fam);
            uint8 n = launcher.memberCount(fam);
            for (uint8 m; m < n; ++m) {
                uint128 liq = launcher.position(fam, m).liquidity;
                if (liq == 0) continue;
                vm.prank(owner);
                try launcher.withdraw(fam, m, liq, 0, 0, owner, vm.getBlockTimestamp() + 10) {}
                catch {
                    _discard();
                    _flag("L family principal withdrawal failed after the lock");
                }
            }
        }
        for (uint256 r; r < _ranges.length; ++r) {
            Range memory g = _ranges[r];
            PoolKey memory k = _anyKey(g.pair, g.pool);
            for (uint256 a; a < 4; ++a) {
                uint256 shares = vault.balanceOf(actors[a], g.id);
                if (shares == 0) continue;
                vm.prank(actors[a]);
                try vault.withdraw(
                    IHookrLiquidityVault.WithdrawParams(
                        k, g.lower, g.upper, uint128(shares), 0, 0, actors[a], vm.getBlockTimestamp() + 10
                    )
                ) {}
                catch {
                    _discard();
                    _flag("L vault withdrawal failed");
                }
            }
        }
        Currency[4] memory cs = [
            Currency.wrap(address(0)), Currency.wrap(address(Q)), Currency.wrap(address(SA)), Currency.wrap(address(SB))
        ];
        for (uint256 j; j < 4; ++j) {
            if (vault.protocolFees(cs[j]) == 0) continue;
            try treasury.collect(address(vault), cs[j]) {}
            catch {
                _discard();
                _flag("L vault protocol fee collection failed");
            }
        }
        HookrRules[2] memory rs = [rules1, rules2];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                for (uint256 b; b < beneficiaries.length; ++b) {
                    address who = beneficiaries[b];
                    if (rs[i].claimable(cs[j], who) == 0) continue;
                    address to = who;
                    if (
                        who == address(acct0) || who == address(acct1) || who == address(multicall)
                            || who == address(curated) || who == address(generic) || who == address(this)
                    ) to = actors[0];
                    if (!_claimAs(who, rs[i], cs[j], to, false)) _flag("L beneficiary claim failed at the end");
                }
            }
        }
        for (uint256 h; h < _claimHolders.length; ++h) {
            address holder = _claimHolders[h];
            for (uint256 j; j < 4; ++j) {
                uint256 bal = manager.balanceOf(holder, cs[j].toId());
                if (bal == 0) continue;
                vm.startPrank(holder);
                manager.setOperator(address(launcher), true);
                try launcher.redeem(cs[j], bal, holder) {}
                catch {
                    _discard();
                    _flag("L ERC-6909 redeem failed");
                }
                vm.stopPrank();
            }
        }
        for (uint256 i; i < 4; ++i) {
            if (programs.claimableCash(dailyId, actors[i]) != 0) {
                vm.prank(actors[i]);
                try programs.claimCash(dailyId, actors[i], actors[i], 0) {}
                catch {
                    _discard();
                    _flag("L programs cash claim failed");
                }
            }
        }
        SysAccount[2] memory accts = [acct0, acct1];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                address t = j == 0 ? address(0) : address(Q);
                uint256 c = paymaster.credit(address(accts[i]), t);
                if (c == 0) continue;
                vm.prank(address(accts[i]));
                try paymaster.withdrawCredit(t, address(accts[i]), c) {}
                catch {
                    _discard();
                    _flag("L paymaster credit withdrawal failed");
                }
            }
        }
        _ingest();
    }
}
