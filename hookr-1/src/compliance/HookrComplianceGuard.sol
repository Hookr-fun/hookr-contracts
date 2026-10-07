// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrCompliance} from "../interfaces/IHookrCompliance.sol";
import {IHookrComplianceGuard, IHookrAdvisory} from "../interfaces/IHookrComplianceGuard.sol";
import {IHookrLauncherView} from "../interfaces/IHookrLauncherView.sol";
import {HookrRelease} from "../libraries/HookrRelease.sol";
import {HookrDelegation} from "../libraries/HookrDelegation.sol";

/// @title HookrComplianceGuard
/// @notice Fail-closed BEFORE_SWAP and liquidity advisory. It admits only permitted identities into a pool and never
/// sees exits, fee collection or claims. Launcher adds and a launch's dev buy resolve to the family owner.
/// @dev Stateless on the swap path: every read is a static call and nothing is written after bind. Storage is keyed
/// by the binder (the root today, a future advisory stack later), so a third-party bind writes only its own namespace.
contract HookrComplianceGuard is IHookrComplianceGuard {
    using PoolIdLibrary for PoolKey;

    /// @custom:storage-location erc7201:hookr.compliance.guard
    struct State {
        mapping(address binder => mapping(PoolId => Bound)) bound;
    }

    /// @dev cast index-erc7201 hookr.compliance.guard
    bytes32 private constant STATE_SLOT = 0x7d372b090789211481529fb92dec95726ef62623b0c4cc394640b9c1bf677200;
    bytes32 private constant SCHEMA_HASH =
        keccak256("ComplianceTerms(bytes32 listId,uint32 requireAll,uint32 blockAny,uint16 flags)");

    /// @notice Also check the recipient.
    uint16 public constant CHECK_BENEFICIARY = 1;
    /// @notice Sellers need a credential too. A suspended list, a revoked issuer or an expired credential leaves a
    ///         seller under the sanctions rule, so no role can freeze exits.
    uint16 public constant KYC_ON_SELL = 2;
    /// @notice When the external source fails, sells stop too. Without it, sells pass if not locally sanctioned.
    uint16 public constant HALT_SELLS_WHEN_SOURCE_DOWN = 4;
    /// @notice The subject enforces transfer restrictions; requires caps.maxSubjectTakeBps == 0.
    uint16 public constant RESTRICTED_SUBJECT = 8;
    /// @notice Accept curated-router swaps; requires RESTRICTED_SUBJECT or listId == 0.
    uint16 public constant ACCEPT_CURATED = 16;
    /// @notice Allow adds from a non-launcher sender that is itself permitted.
    uint16 public constant DIRECT_LP_IF_PERMITTED = 32;
    /// @notice Every defined flag bit.
    uint16 public constant ALL_FLAGS = 63;
    /// @notice Smallest advisory gas limit a pool may bind with.
    uint32 public constant MIN_ADVISORY_GAS = 150_000;
    /// @dev Gas forwarded to each launcher or root view probe.
    uint256 private constant VIEW_GAS = 30_000;

    IHookrCompliance private immutable _compliance;

    /// @param compliance_ The compliance registry. Contract code is required; code that starts with 0xEF
    ///        (HookrDelegation.isDelegated: a delegation designator or a Stylus program) is refused.
    constructor(address compliance_) {
        if (compliance_.code.length == 0 || HookrDelegation.isDelegated(compliance_)) {
            revert InvalidCompliance(compliance_);
        }
        _compliance = IHookrCompliance(compliance_);
    }

    /// @inheritdoc IHookrAdvisory
    function configSchemaHash() external pure returns (bytes32) {
        return SCHEMA_HASH;
    }

    /// @inheritdoc IHookrComplianceGuard
    function compliance() external view returns (address) {
        return address(_compliance);
    }

    /// @inheritdoc IHookrComplianceGuard
    function releaseId() external pure returns (uint256) {
        return HookrRelease.ID;
    }

    /// @inheritdoc IHookrComplianceGuard
    function terms(address binder, PoolId id) external view returns (Bound memory) {
        return _state().bound[binder][id];
    }

    /// @inheritdoc IHookrAdvisory
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32 configHash)
    {
        Terms memory t = _decode(data);
        PoolId id = key.toId();
        Bound storage entry = _state().bound[msg.sender][id];
        if (entry.bound) revert AlreadyBound(msg.sender, id);

        if (t.flags & ~ALL_FLAGS != 0) revert InvalidTerms(1);
        if (t.requireAll & t.blockAny != 0) revert InvalidTerms(2);
        if (t.listId != bytes32(0) && !_compliance.list(t.listId).exists) revert InvalidTerms(3);
        if (t.flags & ACCEPT_CURATED != 0 && t.flags & RESTRICTED_SUBJECT == 0 && t.listId != bytes32(0)) {
            revert InvalidTerms(4);
        }

        if (pc.advisoryFailOpen) revert InvalidPoolConfig(1);
        if (pc.advisoryPhases & HookrTypes.BEFORE_SWAP == 0) revert InvalidPoolConfig(2);
        if (pc.advisoryGasLimit < MIN_ADVISORY_GAS) revert InvalidPoolConfig(3);
        if (t.flags & RESTRICTED_SUBJECT != 0 && pc.caps.maxSubjectTakeBps != 0) revert InvalidPoolConfig(4);
        address launcher = pc.liquidityOwner;
        if (launcher == address(0)) revert InvalidPoolConfig(5);
        (bool okFamily, uint256 family) = _probe(launcher, abi.encodeCall(IHookrLauncherView.poolFamily, (id)));
        if (!okFamily || family == 0) revert InvalidPoolConfig(6);
        (bool okOwner, uint256 familyOwner) =
            _probe(launcher, abi.encodeCall(IHookrLauncherView.familyOwner, (bytes32(family))));
        if (!okOwner || familyOwner == 0 || familyOwner > type(uint160).max) revert InvalidPoolConfig(6);
        (bool okCurated, uint256 curated) = _probe(address(key.hooks), abi.encodeWithSignature("curatedRouter()"));
        if (!okCurated || curated > type(uint160).max) revert InvalidPoolConfig(7);

        entry.listId = t.listId;
        entry.launcher = launcher;
        entry.requireAll = t.requireAll;
        entry.blockAny = t.blockAny;
        entry.flags = t.flags;
        entry.bound = true;
        entry.curatedRouter = address(uint160(curated));
        emit ComplianceBound(
            msg.sender, id, t.listId, t.requireAll, t.blockAny, t.flags, launcher, address(uint160(curated))
        );
        return keccak256(data);
    }

    /// @inheritdoc IHookrAdvisory
    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory advice) {
        (bool allowed,,) = _swap(_state().bound[msg.sender][x.id], x);
        advice.reject = !allowed;
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
        (allowed,,,) = _liquidity(_state().bound[msg.sender][id], id, sender);
    }

    /// @inheritdoc IHookrComplianceGuard
    function explainSwap(address binder, HookrTypes.SwapContext calldata x)
        external
        view
        returns (bool allowed, Reason reason, IHookrCompliance.Decision decision)
    {
        return _swap(_state().bound[binder][x.id], x);
    }

    /// @inheritdoc IHookrComplianceGuard
    function explainLiquidity(address binder, PoolId id, address sender)
        external
        view
        returns (bool allowed, Reason reason, IHookrCompliance.Decision decision, address actor)
    {
        return _liquidity(_state().bound[binder][id], id, sender);
    }

    /// @dev `decision` is ALLOW whenever the registry was not consulted, except a launch buy whose family owner cannot
    ///      be read (NO_CREDENTIAL, from the launch-buy branch of `_swap`). The one
    ///      unauthenticated swap admitted is the launch buy: an exact-input buy the pool's launcher sends while its
    ///      launchBuyPool() names this pool. The launcher delivers it to the family owner, so the owner is screened
    ///      as its payer and recipient.
    function _swap(Bound storage stored, HookrTypes.SwapContext calldata x)
        private
        view
        returns (bool, Reason, IHookrCompliance.Decision)
    {
        Bound memory b = stored;
        if (!b.bound) return (false, Reason.NOT_BOUND, IHookrCompliance.Decision.ALLOW);
        if (!x.authenticated) {
            if (x.isBuy && x.exactInput && x.sender == b.launcher) {
                (bool ok, uint256 pool) = _probe(b.launcher, abi.encodeCall(IHookrLauncherView.launchBuyPool, ()));
                if (ok && bytes32(pool) == PoolId.unwrap(x.id)) {
                    address owner = _familyOwner(b.launcher, x.id);
                    IHookrCompliance.Decision o =
                        owner == address(0) ? IHookrCompliance.Decision.NO_CREDENTIAL : _entry(b, owner);
                    if (o != IHookrCompliance.Decision.ALLOW) return (false, Reason.LAUNCH_BUY, o);
                    return (true, Reason.NONE, o);
                }
            }
            return (false, Reason.UNAUTHENTICATED, IHookrCompliance.Decision.ALLOW);
        }
        bool curated = b.curatedRouter != address(0) && x.sender == b.curatedRouter;
        if (curated && b.flags & ACCEPT_CURATED == 0) {
            return (false, Reason.CURATED_NOT_ACCEPTED, IHookrCompliance.Decision.ALLOW);
        }
        IHookrCompliance.Decision d = x.isBuy ? _entry(b, x.payer) : _exit(b, x.payer, b.flags & KYC_ON_SELL != 0);
        if (d != IHookrCompliance.Decision.ALLOW) return (false, Reason.PAYER, d);
        if (b.flags & CHECK_BENEFICIARY != 0 && !curated && x.beneficiary != x.payer) {
            // A buyer's recipient receives the subject; a seller's recipient receives the quote.
            d = x.isBuy ? _entry(b, x.beneficiary) : _exit(b, x.beneficiary, false);
            if (d != IHookrCompliance.Decision.ALLOW) return (false, Reason.BENEFICIARY, d);
        }
        return (true, Reason.NONE, IHookrCompliance.Decision.ALLOW);
    }

    /// @dev Full check for an entry into the subject: a source failure stops it.
    function _entry(Bound memory b, address who) private view returns (IHookrCompliance.Decision) {
        return _compliance.check(b.listId, who, b.requireAll, b.blockAny);
    }

    /// @dev Sanction rule for an exit into the quote, then the credential when `kyc`. A source failure stops the exit
    ///      only under HALT_SELLS_WHEN_SOURCE_DOWN. A suspended list, a revoked issuer or an expired credential does not
    ///      stop it; a missing credential or a tier mismatch does.
    function _exit(Bound memory b, address who, bool kyc) private view returns (IHookrCompliance.Decision) {
        (bool listed, bool failed) = _compliance.sanctionStatus(who);
        if (listed) return IHookrCompliance.Decision.SANCTIONED;
        if (failed && b.flags & HALT_SELLS_WHEN_SOURCE_DOWN != 0) return IHookrCompliance.Decision.SOURCE_FAILED;
        if (!kyc) return IHookrCompliance.Decision.ALLOW;
        IHookrCompliance.Decision d = _compliance.checkCredential(b.listId, who, b.requireAll, b.blockAny);
        if (
            d == IHookrCompliance.Decision.LIST_SUSPENDED || d == IHookrCompliance.Decision.ISSUER_REVOKED
                || d == IHookrCompliance.Decision.EXPIRED
        ) return IHookrCompliance.Decision.ALLOW;
        return d;
    }

    /// @dev Launcher adds resolve to the family owner; other senders only with DIRECT_LP_IF_PERMITTED.
    function _liquidity(Bound storage stored, PoolId id, address sender)
        private
        view
        returns (bool, Reason, IHookrCompliance.Decision, address)
    {
        Bound memory b = stored;
        if (!b.bound) return (false, Reason.NOT_BOUND, IHookrCompliance.Decision.ALLOW, address(0));
        IHookrCompliance.Decision d;
        if (sender == b.launcher) {
            address owner = _familyOwner(sender, id);
            if (owner == address(0)) return (false, Reason.LP_OWNER, IHookrCompliance.Decision.NO_CREDENTIAL, owner);
            d = _compliance.check(b.listId, owner, b.requireAll, b.blockAny);
            if (d != IHookrCompliance.Decision.ALLOW) return (false, Reason.LP_OWNER, d, owner);
            return (true, Reason.NONE, d, owner);
        }
        if (b.flags & DIRECT_LP_IF_PERMITTED == 0) {
            return (false, Reason.LP_SENDER, IHookrCompliance.Decision.ALLOW, sender);
        }
        d = _compliance.check(b.listId, sender, b.requireAll, b.blockAny);
        if (d != IHookrCompliance.Decision.ALLOW) return (false, Reason.LP_SENDER, d, sender);
        return (true, Reason.NONE, d, sender);
    }

    /// @dev Current family owner of a pool, or zero when either launcher view fails.
    function _familyOwner(address launcher, PoolId id) private view returns (address) {
        (bool ok, uint256 family) = _probe(launcher, abi.encodeCall(IHookrLauncherView.poolFamily, (id)));
        if (!ok || family == 0) return address(0);
        uint256 owner;
        (ok, owner) = _probe(launcher, abi.encodeCall(IHookrLauncherView.familyOwner, (bytes32(family))));
        if (!ok || owner > type(uint160).max) return address(0);
        return address(uint160(owner));
    }

    /// @dev Bounded static call that must return exactly one word.
    function _probe(address target, bytes memory input) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            ok := staticcall(VIEW_GAS, target, add(input, 32), mload(input), 0, 32)
            ok := and(ok, eq(returndatasize(), 32))
            word := mload(0)
        }
    }

    /// @dev Strict decode: exactly four canonical words, re-encoding to the same bytes (InvalidTerms(5) otherwise).
    function _decode(bytes calldata data) private pure returns (Terms memory t) {
        if (data.length != 128) revert InvalidTerms(5);
        if (
            uint256(bytes32(data[32:64])) > type(uint32).max || uint256(bytes32(data[64:96])) > type(uint32).max
                || uint256(bytes32(data[96:128])) > type(uint16).max
        ) revert InvalidTerms(5);
        t = abi.decode(data, (Terms));
        if (keccak256(data) != keccak256(abi.encode(t))) revert InvalidTerms(5);
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") {
            s.slot := STATE_SLOT
        }
    }
}
