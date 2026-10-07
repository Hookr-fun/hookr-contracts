// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {IHookrCompliance} from "hookr/interfaces/IHookrCompliance.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {IHookrLauncherView} from "hookr/interfaces/IHookrLauncherView.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {HookrSessionTiers} from "hookr/libraries/HookrSessionTiers.sol";
import {IHookrPairAdvisory} from "hookr/interfaces/IHookrPairAdvisory.sol";
import {IHookrCredentialGate} from "./interfaces/IHookrCredentialGate.sol";
import {HookrCredentialChecks} from "./libraries/HookrCredentialChecks.sol";

/// @title Hookr credential gate
/// @notice Fail-closed BEFORE_SWAP and liquidity advisory for gated pools. It keeps HookrComplianceGuard's credential
///         gate (credential list, sanctions, the launch buy screened as the family owner, curated-router policy,
///         restricted subjects) and adds, in the same advisory slot:
///         - off-market session tiers (HookrSessionTiers on the shared calendar), with a protocol share of the
///           surcharge taken as a quote take wherever the pool can carry one;
///         - per-side gating: buys, sells and adds each on or off (removals are never gated);
///         - a minimum balance of a named token for entries;
///         - a frozen allowlist (a Merkle root; wallets join with a proof, once, for every pool on that root);
///         - an optional price band: outside it only swaps back toward it start and no add starts, so the pool
///           opens inside it, and in strict mode a swap's price limit must stay inside it.
///         An OPEN pool gates no identity and may be fail-open; that is also the only mode a pair root can bind.
/// @dev Stateless on the swap path: every read is a static call, and nothing is written after bind except allowlist
///      membership, which only grows and only with a valid proof. Storage is keyed by the binder, so a third-party
///      bind writes only its own namespace. No owner and no setting that changes after bind.
contract HookrCredentialGate is HookrReleased, IHookrCredentialGate, IHookrAdvisory, IHookrPairAdvisory {
    using PoolIdLibrary for PoolKey;

    /// @custom:storage-location erc7201:hookr.credential.gate.state
    struct State {
        mapping(address binder => mapping(PoolId => Bound)) bound;
        mapping(bytes32 allowRoot => mapping(address wallet => bool)) members;
    }

    /// @dev cast index-erc7201 hookr.credential.gate.state. Read through the immutable `_stateSlot`: as a constant the
    ///      compiler stored it as data after the code, which left the metadata tail after data rather than after
    ///      INVALID, so the conformance kit's opcode scan read the metadata digest too. This namespace also holds no
    ///      0xf2, 0xf4 or 0xff byte.
    bytes32 private constant STATE_SLOT = 0x424dea7a9f6a43f8e242b66cc87800c078ee595737d66e66530e5c2434beea00;
    /// @dev keccak256 of the Terms type string (see configSchemaHash).
    bytes32 private constant SCHEMA_HASH = 0x81fe695aaf9358e29034946596184ba42d0d6e0d5b31ffe53e27cfe7d1218786;
    uint256 private constant BPS = 10_000;
    /// @dev ABI size of Terms: eleven words and the eight words of the tiers.
    uint256 private constant TERMS_SIZE = 19 * 32;
    /// @dev Gas forwarded to each launcher, root or Rules view probe.
    uint256 private constant VIEW_GAS = 30_000;
    /// @dev Gas forwarded to the root's laneOf, which also reads the registry.
    uint256 private constant LANE_GAS = 60_000;
    /// @dev ABI size of laneOf's seven return words.
    uint256 private constant LANE_SIZE = 7 * 32;

    /// @notice Also check the recipient (a buyer's for entry, a seller's for sanctions).
    uint16 public constant CHECK_BENEFICIARY = 1;
    /// @notice When the external sanctions source fails, sells stop too.
    uint16 public constant HALT_SELLS_WHEN_SOURCE_DOWN = 4;
    /// @notice The subject enforces transfer restrictions; requires the pool's maxSubjectTakeBps == 0.
    uint16 public constant RESTRICTED_SUBJECT = 8;
    /// @notice Accept curated-router swaps; with a credential list, requires RESTRICTED_SUBJECT. Never on a pool whose
    ///         sell side is gated.
    uint16 public constant ACCEPT_CURATED = 16;
    /// @notice With the add side gated, allow adds from a non-launcher sender that itself passes the entry checks.
    uint16 public constant DIRECT_LP_IF_PERMITTED = 32;
    /// @notice No identity gate at all: only the session tiers and the optional band. May be fail-open without a band.
    uint16 public constant OPEN = 64;
    /// @notice Treat the pool's frozen lane executor (running its frozen code) as the trader of its unauthenticated
    ///         swaps and screen it like any wallet, so arb recapture runs on the pool once the executor passes the
    ///         gate.
    uint16 public constant ADMIT_LANE_EXECUTOR = 128;
    /// @notice Price band on [tickLower, tickUpper]. No add starts while the price is outside it, so the pool opens
    ///         inside it.
    uint16 public constant TICK_RANGE = 256;
    /// @notice With TICK_RANGE, a swap's price limit must sit inside the band.
    uint16 public constant STRICT_RANGE = 512;
    /// @notice Every defined flag bit. Bit 2 (HookrComplianceGuard's KYC_ON_SELL) is the GATE_SELL side here.
    uint16 public constant ALL_FLAGS = 1021;

    /// @notice Side bits.
    uint8 public constant GATE_BUY = 1;
    uint8 public constant GATE_SELL = 2;
    uint8 public constant GATE_ADD = 4;
    uint8 public constant ALL_SIDES = 7;

    /// @notice Default sides: buys and adds gated, sells screened for sanctions (HookrComplianceGuard's default).
    uint8 public constant DEFAULT_SIDES = 5;
    /// @notice Default flags: CHECK_BENEFICIARY.
    uint16 public constant DEFAULT_FLAGS = 1;
    /// @notice Default tier bits a credential must hold on a pool with a credential list: bit 0, so a credential issued
    ///         with no tier bits (a placeholder or a downgrade) does not pass a default pool.
    uint32 public constant DEFAULT_REQUIRE_ALL = 1;
    /// @notice Protocol share of the session surcharge on a pool that can carry a quote take: at least the release
    ///         floor (and at least the pool Rules' own minProtocolShareBps), at most all of it.
    uint16 public constant MIN_PROTOCOL_SHARE_BPS = 2_000;
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 10_000;
    uint16 public constant DEFAULT_PROTOCOL_SHARE_BPS = 2_000;
    /// @notice Minimum balance: off (zero, with no token), or 1 raw unit up to this share of the token's supply at
    ///         bind.
    uint16 public constant MAX_MIN_BALANCE_BPS = 100;
    uint128 public constant MIN_MIN_BALANCE = 1;
    uint128 public constant DEFAULT_MIN_BALANCE = 0;
    /// @notice Band bounds: TickMath's range; the band is at least one tick spacing wide. Default off.
    int24 public constant MIN_TICK = TickMath.MIN_TICK;
    int24 public constant MAX_TICK = TickMath.MAX_TICK;
    /// @notice Longest allowlist proof: 2^32 wallets.
    uint256 public constant MAX_PROOF_DEPTH = 32;
    /// @notice Smallest advisory gas limit a HookrRoot pool may bind with; the root forwards it to bind too.
    uint32 public constant MIN_ADVISORY_GAS = 400_000;
    /// @notice Largest advisory gas limit a HookrRoot pool may bind with: the registry's own admission ceiling
    ///         (`HookrRegistryChecks.sol`: any admission's `gasLimit` above 2,000,000 is refused at ADMIT, regardless
    ///         of kind). Checked here too so a misconfigured `PoolConfig` fails at this gate's own bind, not only later
    ///         at admission.
    uint32 public constant MAX_ADVISORY_GAS = 2_000_000;
    /// @notice Smallest advisory gas limit a pair root may bind with.
    uint32 public constant MIN_PAIR_GAS = 70_000;
    /// @notice Largest gas limit a pair root may bind with. The factory bounds a pair root's `advisoryGasLimit` by
    ///         this gate's own ADVISORY admission (`HookrRootFactory._checkAdvisory`: `params.advisoryGasLimit >
    ///         a.gasLimit` reverts), and that admission is itself capped at 2,000,000 by the registry, so this
    ///         matches the same ceiling rather than inventing a separate one.
    uint32 public constant MAX_PAIR_GAS = 2_000_000;

    IHookrCompliance private immutable _compliance;
    address private immutable _calendar;
    IPoolManager private immutable _manager;
    /// @dev STATE_SLOT, as a PUSH32 in the runtime rather than data after the code.
    bytes32 private immutable _stateSlot = STATE_SLOT;

    /// @param compliance_ The compliance registry: contract code, not an EIP-7702 delegation.
    /// @param calendar_ The shared market calendar (a HookrSessionAdvisory), or zero for a gate without tiers.
    /// @param manager_ The PoolManager of every HookrRoot this gate serves.
    constructor(address compliance_, address calendar_, address manager_) {
        if (!_isCode(compliance_)) revert InvalidConstructor(1);
        if (calendar_ != address(0) && !_isCode(calendar_)) revert InvalidConstructor(2);
        if (!_isCode(manager_)) revert InvalidConstructor(3);
        _compliance = IHookrCompliance(compliance_);
        _calendar = calendar_;
        _manager = IPoolManager(manager_);
    }

    /// @inheritdoc IHookrAdvisory
    function configSchemaHash() external pure override(IHookrAdvisory, IHookrCredentialGate) returns (bytes32) {
        return SCHEMA_HASH;
    }

    /// @inheritdoc IHookrCredentialGate
    function compliance() external view returns (address) {
        return address(_compliance);
    }

    /// @inheritdoc IHookrCredentialGate
    function calendar() external view returns (address) {
        return _calendar;
    }

    /// @inheritdoc IHookrCredentialGate
    function poolManager() external view returns (address) {
        return address(_manager);
    }

    /// @inheritdoc IHookrCredentialGate
    function terms(address binder, PoolId id) external view returns (Bound memory) {
        return _state().bound[binder][id];
    }

    /// @inheritdoc IHookrCredentialGate
    function isMember(address binder, PoolId id, address wallet) external view returns (bool) {
        bytes32 allowRoot = _state().bound[binder][id].allowRoot;
        return allowRoot != bytes32(0) && _state().members[allowRoot][wallet];
    }

    /// @notice Whether `wallet` proved membership of the allowlist with root `allowRoot`.
    function isMemberOf(bytes32 allowRoot, address wallet) external view returns (bool) {
        return _state().members[allowRoot][wallet];
    }

    /// @inheritdoc IHookrCredentialGate
    function surchargeAt(address binder, PoolId id, uint256 timestamp) external view returns (uint24) {
        Bound storage b = _state().bound[binder][id];
        return b.bound ? uint24(_session(b, timestamp)) : 0;
    }

    /// @inheritdoc IHookrCredentialGate
    function defaultTerms(bytes32 listId, uint24 capPips, bool withTake) external pure returns (Terms memory t) {
        t.listId = listId;
        if (listId != bytes32(0)) t.requireAll = DEFAULT_REQUIRE_ALL;
        t.flags = DEFAULT_FLAGS;
        t.sides = DEFAULT_SIDES;
        t.protocolShareBps = withTake ? DEFAULT_PROTOCOL_SHARE_BPS : 0;
        t.tiers = HookrSessionTiers.Tiers(capPips / 25, capPips / 6, capPips / 4, capPips / 2, capPips, 1_800, 1_800, 1);
    }

    /// @inheritdoc IHookrCredentialGate
    /// @dev Membership is per allowlist root, so a wallet joins before a launch and once for every pool on that root.
    ///      The leaf is keccak256(bytes.concat(keccak256(abi.encode(wallet)))).
    function join(bytes32 allowRoot, address wallet, bytes32[] calldata proof) external {
        if (proof.length > MAX_PROOF_DEPTH) revert ProofTooLong(proof.length);
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(wallet))));
        if (allowRoot == bytes32(0) || !MerkleProof.verifyCalldata(proof, allowRoot, leaf)) {
            revert NotAllowlisted(wallet);
        }
        mapping(address => bool) storage m = _state().members[allowRoot];
        if (m[wallet]) return;
        m[wallet] = true;
        emit Joined(allowRoot, wallet);
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev The binder must be a root on whose registry this contract is admitted as an ADVISORY, on this gate's
    ///      PoolManager. Every tier must be within the admission's LP cap, and the protocol part of the highest tier
    ///      within its quote cap.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32 configHash)
    {
        Terms memory t = _decode(data);
        PoolId id = key.toId();
        Bound storage entry = _state().bound[msg.sender][id];
        if (entry.bound) revert AlreadyBound(msg.sender, id);
        _checkTerms(t, key.tickSpacing);
        bool open = t.flags & OPEN != 0;

        if (pc.advisory != address(this)) revert InvalidPoolConfig(8);
        if (pc.advisoryPhases != HookrTypes.BEFORE_SWAP) revert InvalidPoolConfig(2);
        if (pc.advisoryGasLimit < MIN_ADVISORY_GAS || pc.advisoryGasLimit > MAX_ADVISORY_GAS) {
            revert InvalidPoolConfig(3);
        }
        if (pc.advisoryFailOpen && (!open || t.flags & TICK_RANGE != 0)) revert InvalidPoolConfig(1);
        if (address(IHookrRoot(msg.sender).poolManager()) != address(_manager)) revert InvalidPoolConfig(9);
        IHookrRegistry.Admission memory own = IHookrRoot(msg.sender).registry().admission(msg.sender, address(this));
        if (own.kind != IHookrRegistry.Kind.ADVISORY || own.implementation != address(this)) {
            revert InvalidPoolConfig(8);
        }

        if (!open) {
            if (t.listId != bytes32(0) && !_compliance.list(t.listId).exists) revert InvalidTerms(3);
            if (t.flags & RESTRICTED_SUBJECT != 0 && pc.caps.maxSubjectTakeBps != 0) revert InvalidPoolConfig(4);
            address launcher = pc.liquidityOwner;
            if (launcher == address(0)) revert InvalidPoolConfig(5);
            (bool okFamily, uint256 family) =
                _probe(launcher, abi.encodeCall(IHookrLauncherView.poolFamily, (id)), 32, VIEW_GAS);
            if (!okFamily || family == 0) revert InvalidPoolConfig(6);
            (bool okOwner, uint256 familyOwner) =
                _probe(launcher, abi.encodeCall(IHookrLauncherView.familyOwner, (bytes32(family))), 32, VIEW_GAS);
            if (!okOwner || familyOwner == 0 || familyOwner > type(uint160).max) revert InvalidPoolConfig(6);
            (bool okCurated, uint256 curated) =
                _probe(address(key.hooks), abi.encodeWithSignature("curatedRouter()"), 32, VIEW_GAS);
            if (!okCurated || curated > type(uint160).max) revert InvalidPoolConfig(7);
            if (t.balanceToken != address(0)) _checkBalanceToken(t.balanceToken, t.minBalance);
            entry.listId = t.listId;
            entry.launcher = launcher;
            entry.requireAll = t.requireAll;
            entry.blockAny = t.blockAny;
            entry.curatedRouter = address(uint160(curated));
            entry.balanceToken = t.balanceToken;
            entry.minBalance = t.minBalance;
            entry.allowRoot = t.allowRoot;
        }

        bool tiered = !HookrSessionTiers.isEmpty(t.tiers);
        if (tiered) {
            uint256 code = HookrSessionTiers.validate(t.tiers, own.caps.maxLpFeePips);
            if (code != 0) revert InvalidTerms(13);
        }
        if (!tiered || pc.advisoryFailOpen || own.caps.maxQuoteTakePips == 0) {
            if (t.protocolShareBps != 0) revert InvalidTerms(12);
        } else {
            uint256 floor = MIN_PROTOCOL_SHARE_BPS;
            (bool okMin, uint256 rulesMin) =
                _probe(pc.rules, abi.encodeWithSignature("minProtocolShareBps()"), 32, VIEW_GAS);
            if (okMin && rulesMin > floor) floor = rulesMin;
            if (
                t.protocolShareBps < floor || t.protocolShareBps > MAX_PROTOCOL_SHARE_BPS
                    || HookrSessionTiers.highest(t.tiers) * t.protocolShareBps / BPS > own.caps.maxQuoteTakePips
            ) revert InvalidTerms(12);
            (bool okRecipient, uint256 recipient) =
                _probe(pc.rules, abi.encodeWithSignature("protocolRecipient()"), 32, VIEW_GAS);
            if (!okRecipient || recipient == 0 || recipient > type(uint160).max) revert InvalidPoolConfig(10);
            entry.protocolRecipient = address(uint160(recipient));
        }

        entry.flags = t.flags;
        entry.sides = t.sides;
        entry.tickLower = t.tickLower;
        entry.tickUpper = t.tickUpper;
        entry.protocolShareBps = t.protocolShareBps;
        entry.tiers = t.tiers;
        entry.bound = true;
        emit GateBound(msg.sender, id, t.listId, t, entry.launcher);
        return keccak256(data);
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev A refused swap gets reject and no charge; an admitted one the session surcharge, split into its LP part
    ///      and the protocol's quote take.
    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory advice) {
        Bound storage b = _state().bound[msg.sender][x.id];
        (bool allowed,,,) = _swap(b, msg.sender, x);
        if (!allowed) {
            advice.reject = true;
            return advice;
        }
        uint256 s = _session(b, block.timestamp);
        if (s == 0) return advice;
        uint256 take = s * b.protocolShareBps / BPS;
        advice.lpFeeSurchargePips = uint24(s - take);
        if (take != 0) {
            advice.quoteTakePips = uint24(take);
            advice.recipient = b.protocolRecipient;
        }
    }

    /// @inheritdoc IHookrAdvisory
    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory advice)
    {
        return advice;
    }

    /// @inheritdoc IHookrAdvisory
    function beforeAddLiquidity(PoolId id, address sender) external view returns (bool allowed) {
        (allowed,,,,) = _liquidity(_state().bound[msg.sender][id], id, sender);
    }

    /// @inheritdoc IHookrCredentialGate
    function explainSwap(address binder, HookrTypes.SwapContext calldata x)
        external
        view
        returns (bool, Reason, HookrCredentialChecks.Check, IHookrCompliance.Decision)
    {
        return _swap(_state().bound[binder][x.id], binder, x);
    }

    /// @inheritdoc IHookrCredentialGate
    function explainLiquidity(address binder, PoolId id, address sender)
        external
        view
        returns (bool, Reason, HookrCredentialChecks.Check, IHookrCompliance.Decision, address)
    {
        return _liquidity(_state().bound[binder][id], id, sender);
    }

    /// @inheritdoc IHookrPairAdvisory
    /// @dev A pair root authenticates no trader, so it binds OPEN terms only: session tiers within `capPips`, nothing
    ///      else. Keyed by the calling root.
    function bindPair(PoolId id, uint24 capPips, uint32 gasLimit, bytes calldata data) external returns (bytes4) {
        Terms memory t = _decode(data);
        Bound storage entry = _state().bound[msg.sender][id];
        if (entry.bound) revert AlreadyBound(msg.sender, id);
        if (
            t.flags != OPEN || t.listId != bytes32(0) || t.requireAll != 0 || t.blockAny != 0 || t.sides != 0
                || t.balanceToken != address(0) || t.minBalance != 0 || t.allowRoot != bytes32(0) || t.tickLower != 0
                || t.tickUpper != 0 || t.protocolShareBps != 0
        ) revert InvalidTerms(16);
        if (gasLimit < MIN_PAIR_GAS || gasLimit > MAX_PAIR_GAS) revert InvalidPoolConfig(3);
        if (!HookrSessionTiers.isEmpty(t.tiers)) {
            if (_calendar == address(0)) revert InvalidTerms(14);
            if (HookrSessionTiers.validate(t.tiers, capPips) != 0) revert InvalidTerms(13);
        }
        entry.flags = OPEN;
        entry.tiers = t.tiers;
        entry.bound = true;
        emit PairBound(msg.sender, id, t.tiers, capPips);
        return IHookrPairAdvisory.bindPair.selector;
    }

    /// @inheritdoc IHookrPairAdvisory
    function surchargeForSwap(PoolId id, bool, int256, uint160, bytes calldata, address)
        external
        view
        returns (uint24)
    {
        Bound storage b = _state().bound[msg.sender][id];
        if (!b.bound) revert UnknownPool(msg.sender, id);
        return uint24(_session(b, block.timestamp));
    }

    /// @dev The swap decision. `decision` is ALLOW whenever the compliance registry did not decide the reason. The
    ///      one unauthenticated trader swap admitted is the launch buy (as HookrComplianceGuard), screened as the
    ///      family owner; with ADMIT_LANE_EXECUTOR, the pool's frozen lane executor's swaps are screened with the
    ///      executor as payer.
    function _swap(Bound storage b, address binder, HookrTypes.SwapContext calldata x)
        private
        view
        returns (bool, Reason, HookrCredentialChecks.Check, IHookrCompliance.Decision)
    {
        IHookrCompliance.Decision allow = IHookrCompliance.Decision.ALLOW;
        HookrCredentialChecks.Check none = HookrCredentialChecks.Check.NONE;
        if (!b.bound) return (false, Reason.NOT_BOUND, none, allow);
        uint16 flags = b.flags;
        if (flags & OPEN == 0) {
            (Reason r, HookrCredentialChecks.Check c, IHookrCompliance.Decision d) = _identity(b, binder, x, flags);
            if (r != Reason.NONE) return (false, r, c, d);
        }
        if (flags & TICK_RANGE != 0) {
            (, int24 tick,,) = StateLibrary.getSlot0(_manager, x.id);
            if (!HookrCredentialChecks.inBand(
                    tick, x.zeroForOne, x.sqrtPriceLimitX96, b.tickLower, b.tickUpper, flags & STRICT_RANGE != 0
                )) {
                return (false, Reason.OUT_OF_RANGE, HookrCredentialChecks.Check.RANGE, allow);
            }
        }
        return (true, Reason.NONE, none, allow);
    }

    function _identity(Bound storage b, address binder, HookrTypes.SwapContext calldata x, uint16 flags)
        private
        view
        returns (Reason, HookrCredentialChecks.Check, IHookrCompliance.Decision d)
    {
        HookrCredentialChecks.Check c;
        HookrCredentialChecks.Gate memory g = _gate(b, flags);
        mapping(address => bool) storage m = _state().members[b.allowRoot];
        uint8 sides = b.sides;
        if (!x.authenticated) {
            address launcher = b.launcher;
            if (x.isBuy && x.exactInput && x.sender == launcher) {
                (bool ok, uint256 pool) =
                    _probe(launcher, abi.encodeCall(IHookrLauncherView.launchBuyPool, ()), 32, VIEW_GAS);
                if (ok && bytes32(pool) == PoolId.unwrap(x.id)) {
                    address owner = _familyOwner(launcher, x.id);
                    if (owner == address(0)) {
                        return (
                            Reason.LAUNCH_BUY,
                            HookrCredentialChecks.Check.COMPLIANCE,
                            IHookrCompliance.Decision.NO_CREDENTIAL
                        );
                    }
                    (d, c) = HookrCredentialChecks.entry(g, m, owner, sides & GATE_BUY != 0);
                    return (d == IHookrCompliance.Decision.ALLOW ? Reason.NONE : Reason.LAUNCH_BUY, c, d);
                }
            }
            if (flags & ADMIT_LANE_EXECUTOR != 0 && x.sender != address(0) && _isExecutor(binder, x.id, x.sender)) {
                // The executor's own swap outside a frame looks exactly like a leg, so the executor is screened as
                // the trader of every leg: it passes the pool's checks like any wallet, or its legs are refused.
                (d, c) = x.isBuy
                    ? HookrCredentialChecks.entry(g, m, x.sender, sides & GATE_BUY != 0)
                    : HookrCredentialChecks.exit(g, x.sender, sides & GATE_SELL != 0);
                return (d == IHookrCompliance.Decision.ALLOW ? Reason.NONE : Reason.PAYER, c, d);
            }
            return (Reason.UNAUTHENTICATED, c, d);
        }
        bool curated = b.curatedRouter != address(0) && x.sender == b.curatedRouter;
        if (curated && flags & ACCEPT_CURATED == 0) return (Reason.CURATED_NOT_ACCEPTED, c, d);
        (d, c) = x.isBuy
            ? HookrCredentialChecks.entry(g, m, x.payer, sides & GATE_BUY != 0)
            : HookrCredentialChecks.exit(g, x.payer, sides & GATE_SELL != 0);
        if (d != IHookrCompliance.Decision.ALLOW) return (Reason.PAYER, c, d);
        if (flags & CHECK_BENEFICIARY != 0 && !curated && x.beneficiary != x.payer) {
            // A buyer's recipient receives the subject; a seller's recipient receives the quote.
            (d, c) = x.isBuy
                ? HookrCredentialChecks.entry(g, m, x.beneficiary, sides & GATE_BUY != 0)
                : HookrCredentialChecks.exit(g, x.beneficiary, false);
            if (d != IHookrCompliance.Decision.ALLOW) return (Reason.BENEFICIARY, c, d);
        }
        return (Reason.NONE, c, d);
    }

    /// @dev Adds: none while the price is outside the band. The root binds before the PoolManager initializes the
    ///      pool, so the launch add is the first call that sees the launch price, and a pool cannot open outside its
    ///      band, where only swaps toward the band would start. Otherwise never restricted on an OPEN pool. The
    ///      launcher's adds resolve to the family owner. With the add side off, the actor is screened for sanctions
    ///      only (an add is a standing order to trade, so a sanctioned wallet must not trade through a range it
    ///      provides). Gated: other senders only with DIRECT_LP_IF_PERMITTED; the actor passes the entry checks.
    function _liquidity(Bound storage b, PoolId id, address sender)
        private
        view
        returns (bool, Reason, HookrCredentialChecks.Check, IHookrCompliance.Decision, address)
    {
        IHookrCompliance.Decision d;
        HookrCredentialChecks.Check c;
        if (!b.bound) return (false, Reason.NOT_BOUND, c, d, address(0));
        uint16 flags = b.flags;
        if (flags & TICK_RANGE != 0) {
            (, int24 tick,,) = StateLibrary.getSlot0(_manager, id);
            if (tick < b.tickLower || tick > b.tickUpper) {
                return (false, Reason.OUT_OF_RANGE, HookrCredentialChecks.Check.RANGE, d, sender);
            }
        }
        if (flags & OPEN != 0) return (true, Reason.NONE, c, d, sender);
        bool gated = b.sides & GATE_ADD != 0;
        HookrCredentialChecks.Gate memory g = _gate(b, flags);
        mapping(address => bool) storage m = _state().members[b.allowRoot];
        if (sender == b.launcher) {
            address owner = _familyOwner(sender, id);
            if (owner == address(0)) {
                return (
                    false,
                    Reason.LP_OWNER,
                    HookrCredentialChecks.Check.COMPLIANCE,
                    IHookrCompliance.Decision.NO_CREDENTIAL,
                    owner
                );
            }
            (d, c) = HookrCredentialChecks.entry(g, m, owner, gated);
            return (
                d == IHookrCompliance.Decision.ALLOW,
                d == IHookrCompliance.Decision.ALLOW ? Reason.NONE : Reason.LP_OWNER,
                c,
                d,
                owner
            );
        }
        if (gated && flags & DIRECT_LP_IF_PERMITTED == 0) return (false, Reason.LP_SENDER, c, d, sender);
        (d, c) = HookrCredentialChecks.entry(g, m, sender, gated);
        return (
            d == IHookrCompliance.Decision.ALLOW,
            d == IHookrCompliance.Decision.ALLOW ? Reason.NONE : Reason.LP_SENDER,
            c,
            d,
            sender
        );
    }

    function _gate(Bound storage b, uint16 flags) private view returns (HookrCredentialChecks.Gate memory g) {
        g.compliance = _compliance;
        g.listId = b.listId;
        g.requireAll = b.requireAll;
        g.blockAny = b.blockAny;
        g.haltSellsWhenSourceDown = flags & HALT_SELLS_WHEN_SOURCE_DOWN != 0;
        g.balanceToken = b.balanceToken;
        g.minBalance = b.minBalance;
        g.allowlist = b.allowRoot != bytes32(0);
    }

    /// @dev Session surcharge before the split: zero without tiers; the highest tier when the calendar read fails.
    function _session(Bound storage b, uint256 timestamp) private view returns (uint256) {
        HookrSessionTiers.Tiers memory t = b.tiers;
        if (HookrSessionTiers.isEmpty(t)) return 0;
        return HookrSessionTiers.valueAt(t, _calendar, timestamp);
    }

    /// @dev Everything about the terms that needs no pool: flags, sides, OPEN, band, balance bounds and tiers. A gated
    ///      buy or sell needs the add side gated too, since a one-sided range is a limit order the price fills
    ///      (InvalidTerms(17)). A gated sell needs the buy side gated and CHECK_BENEFICIARY and refuses
    ///      ACCEPT_CURATED, so every wallet that receives the subject from the pool passed the list and can always sell
    ///      it back (InvalidTerms(18)); with buys open, recipients unchecked or curated swaps (which skip the recipient
    ///      check) accepted, a wallet the list never recorded buys in and can never sell.
    ///      ACCEPT_CURATED on any identity gate (list, allowlist or balance) needs RESTRICTED_SUBJECT, since curated
    ///      swaps skip the beneficiary check (InvalidTerms(4)).
    function _checkTerms(Terms memory t, int24 tickSpacing) private view {
        uint16 f = t.flags;
        if (f & ~ALL_FLAGS != 0) revert InvalidTerms(1);
        if (t.requireAll & t.blockAny != 0) revert InvalidTerms(2);
        if (t.sides & ~ALL_SIDES != 0) revert InvalidTerms(6);
        if (t.sides & (GATE_BUY | GATE_SELL) != 0 && t.sides & GATE_ADD == 0) revert InvalidTerms(17);
        if (
            t.sides & GATE_SELL != 0
                && (t.sides & GATE_BUY == 0 || f & CHECK_BENEFICIARY == 0 || f & ACCEPT_CURATED != 0)
        ) revert InvalidTerms(18);
        if (f & OPEN != 0) {
            if (
                t.listId != bytes32(0) || t.requireAll != 0 || t.blockAny != 0 || t.sides != 0
                    || t.balanceToken != address(0) || t.minBalance != 0 || t.allowRoot != bytes32(0)
                    || f
                            & (CHECK_BENEFICIARY
                                | HALT_SELLS_WHEN_SOURCE_DOWN
                                | RESTRICTED_SUBJECT
                                | ACCEPT_CURATED
                                | DIRECT_LP_IF_PERMITTED) != 0
            ) revert InvalidTerms(7);
            if (f & ADMIT_LANE_EXECUTOR != 0) revert InvalidTerms(15);
        } else if (
            f & ACCEPT_CURATED != 0 && f & RESTRICTED_SUBJECT == 0
                && (t.listId != bytes32(0) || t.allowRoot != bytes32(0) || t.balanceToken != address(0))
        ) {
            revert InvalidTerms(4);
        }
        if (t.balanceToken == address(0) ? t.minBalance != 0 : t.minBalance < MIN_MIN_BALANCE) revert InvalidTerms(9);
        if (f & TICK_RANGE != 0) {
            if (
                t.tickLower < MIN_TICK || t.tickUpper > MAX_TICK || t.tickLower >= t.tickUpper
                    || int256(t.tickUpper) - t.tickLower < tickSpacing
            ) revert InvalidTerms(10);
        } else if (f & STRICT_RANGE != 0 || t.tickLower != 0 || t.tickUpper != 0) {
            revert InvalidTerms(11);
        }
        if (!HookrSessionTiers.isEmpty(t.tiers) && _calendar == address(0)) revert InvalidTerms(14);
    }

    /// @dev The balance token holds its own code, answers balanceOf and totalSupply, and the minimum is at most
    ///      MAX_MIN_BALANCE_BPS of its supply.
    function _checkBalanceToken(address token, uint128 minBalance) private view {
        if (!_isCode(token)) revert InvalidTerms(8);
        (bool okBalance,) = HookrCredentialChecks.balanceOf(token, address(this));
        (bool okSupply, uint256 supply) = _probe(token, abi.encodeWithSignature("totalSupply()"), 32, VIEW_GAS);
        if (!okBalance || !okSupply) revert InvalidTerms(8);
        if (minBalance > supply * MAX_MIN_BALANCE_BPS / BPS) revert InvalidTerms(9);
    }

    /// @dev Whether `sender` is the pool's frozen lane executor on `binder` and still runs its frozen code.
    function _isExecutor(address binder, PoolId id, address sender) private view returns (bool) {
        bytes memory input = abi.encodeWithSignature("laneOf(bytes32)", id);
        bytes memory output = new bytes(LANE_SIZE);
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(LANE_GAS, binder, add(input, 32), mload(input), add(output, 32), LANE_SIZE)
            ok := and(ok, eq(returndatasize(), LANE_SIZE))
        }
        if (!ok) return false;
        (uint256 executor, bytes32 codeHash) = abi.decode(output, (uint256, bytes32));
        return executor == uint256(uint160(sender)) && sender.codehash == codeHash;
    }

    /// @dev Current family owner of a pool, or zero when either launcher view fails.
    function _familyOwner(address launcher, PoolId id) private view returns (address) {
        (bool ok, uint256 family) = _probe(launcher, abi.encodeCall(IHookrLauncherView.poolFamily, (id)), 32, VIEW_GAS);
        if (!ok || family == 0) return address(0);
        uint256 owner;
        (ok, owner) = _probe(launcher, abi.encodeCall(IHookrLauncherView.familyOwner, (bytes32(family))), 32, VIEW_GAS);
        if (!ok || owner > type(uint160).max) return address(0);
        return address(uint160(owner));
    }

    /// @dev Bounded static call that must return exactly `size` bytes; returns the first word.
    function _probe(address target, bytes memory input, uint256 size, uint256 gasLimit)
        private
        view
        returns (bool ok, uint256 word)
    {
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(input, 32), mload(input), 0, 32)
            ok := and(ok, eq(returndatasize(), size))
            word := mload(0)
        }
    }

    /// @dev Contract code that is not an EIP-7702 delegation designator.
    function _isCode(address a) private view returns (bool) {
        uint256 size;
        bool delegated;
        assembly ("memory-safe") {
            size := extcodesize(a)
            if size {
                let free := mload(0x40)
                extcodecopy(a, free, 0, 1)
                delegated := eq(byte(0, mload(free)), 0xef)
            }
        }
        return size != 0 && !delegated;
    }

    /// @dev Strict decode: exactly the Terms words, each in range, re-encoding to the same bytes (InvalidTerms(5)).
    function _decode(bytes calldata data) private pure returns (Terms memory t) {
        if (data.length != TERMS_SIZE) revert InvalidTerms(5);
        t = abi.decode(data, (Terms));
        if (keccak256(data) != keccak256(abi.encode(t))) revert InvalidTerms(5);
    }

    function _state() private view returns (State storage s) {
        bytes32 slot = _stateSlot;
        assembly ("memory-safe") {
            s.slot := slot
        }
    }
}
