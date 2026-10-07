// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IHookrProtocolClaims} from "../interfaces/IHookrProtocolClaims.sol";
import {IHookrProtocolClaimsTransfer} from "../interfaces/IHookrProtocolClaimsTransfer.sol";
import {IHookrTreasury} from "../interfaces/IHookrTreasury.sol";
import {HookrDelegation} from "../libraries/HookrDelegation.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrRules} from "../interfaces/IHookrRules.sol";
import {IHookrOwnedRoots} from "../interfaces/IHookrOwnedRoots.sol";
import {IHookrRootRegistrar} from "../interfaces/IHookrRootRegistrar.sol";

/// @title HookrTreasury
/// @notice Permissionless collector of this contract's protocol-owned claims from admitted Rules sources and from the
///         companion Rules of owned roots.
/// @dev User, LP, royalty and reward liabilities stay in their respective contracts. This collector
///      has no authority to spend those ledgers. Its owner controls protocol-fund destinations, but a new
///      destination only takes effect `TARGET_DELAY` after it is proposed and lapses `TARGET_GRACE` after
///      that; until then anyone can still collect and forward protocol cash to the current target. Ownership
///      moves in two steps and clears any pending destination. Owner and nominee are never EIP-7702
///      delegated accounts. This is not a holder dividend or an automatic buyback contract.
///
///      Collection events. Every call that pays a source claim emits exactly one `ProtocolCollected(source,
///      currency, to, amount)`, where `to` and `amount` equal the `to` and amount the source reports for the
///      same claim (a Rules `Claimed(currency, beneficiary = this treasury, to, amount)` in the same call).
///      `collect` pays this treasury (`to == address(this)`) and then emits `ProtocolForwarded` or
///      `ProtocolForwardDeferred` for the delivery attempt; `collectTo` pays the current target directly
///      (`to == target()`) and emits nothing else; `collectAsClaims`, called by the owner or the target,
///      credits the current target with the claim as PoolManager ERC-6909 claims of `currency`
///      (`to == target()`) and emits nothing else, the PoolManager's `Transfer` in the same call marking the
///      payment as ERC-6909 rather than token.
///      `ProtocolForwarded` and `ProtocolForwardDeferred` only ever describe balances this treasury held.
///
///      Owned-root sources. Every owned root (IHookrOwnedRoots) has a companion Rules module its factory deployed, and
///      it pays this treasury. Once the owner names the registry (`setOwnedRootRegistry`), `collect`, `collectTo` and
///      `collectAsClaims` take such a companion without `admitSource`: on its first collection the treasury asks the
///      companion for its `trustedRoot()`, the registry whether that root is owned and which factory registered it,
///      and that factory for the root's `rulesOf`. Only when the factory names the companion, the companion pays this
///      treasury on its PoolManager and it passes `admitSource`'s other checks (code that is not an EIP-7702
///      delegation; neither this treasury, the target, the pending target, a listed integrator nor one with a pending
///      proposal) does the treasury admit it at its current runtime codehash and emit `SourceAdmitted`. From then on it
///      is an admitted source like any other: a later change of its code refuses collection (`SourceCodeChanged`). Any
///      failed or unexpected answer reads as `InvalidSource`. Naming the registry admits no more than `admitSource`
///      could, so it takes effect at once, and zero turns the check off for companions not yet admitted.
///
///      Fee terms. The owner also governs two terms every Rules paying this treasury reads once when it binds a pool,
///      never on a swap (`feeTerms`): the governed rule-share floor (0 to 5,000 basis points; a Rules binds a pool's
///      protocolShareBps at no less than the larger of it and its own immutable floor) and the integrator list (each
///      entry a rate of 1 to 5,000 basis points of Hookr's rule-fee share, paid to the integrator on every pool that
///      names it at bind). Raising, lowering, listing and re-rating wait TERMS_DELAY (30 minutes) after the proposal
///      and lapse TERMS_GRACE after that; taking an integrator off the list is immediate and voids its pending
///      proposal. A change of owner voids every pending fee-terms proposal. Pools already bound keep the floor they
///      met and the integrator and rate they froze. An integrator must be an account that can claim what the Rules
///      credit it (an EOA, a Safe, or a contract that calls `claim`, `claimTo` or `claimAsClaims`): the list refuses
///      this treasury, the PoolManager and every admitted source, at the proposal and again at its acceptance, and
///      `admitSource` refuses an account that is listed or has a pending proposal, so no order of the two makes an
///      admitted source an integrator (the Rules refuse the rest at bind).
///
///      Pending proposals. A proposal is pending from `propose` until it is accepted, cancelled, replaced by a new
///      proposal for the same entry, voided (a change of owner voids all; `removeIntegrator` voids the account's) or
///      lapsed (TERMS_GRACE after `readyAt`); the pending views report none once it lapsed. Each void emits the entry's
///      cancellation event: `RuleShareFloorProposalCancelled`, `MinFeeProposalCancelled`,
///      `IntegratorProposalCancelled`, `IntegratorMinFeeProposalCancelled` and `OwnedRootFeeProposalCancelled`. A
///      change of owner cannot list the per-account proposals it voids, so it also emits
///      `FeeTermsProposalsVoided(epoch)`: an indexer drops every integrator and override proposal made before it.
///
///      The Hookr minimum. Also read once at bind: the least Hookr takes of every trader swap on a Hookr token's pool
///      that nothing else earns Hookr a share on, in pips of the swap. HookrRules binds it only on a pool with no arb
///      recapture and nothing that pays Hookr a protocol share (LP Rewards, Auto Burn, dynamic fees or the Anti-Snipe
///      tax that can pay Hookr a pip of a swap, or Tax + Conversion; see HookrRules.bind), so what pays Hookr a share
///      replaces it rather than adds to it. Two rates, one for pools without arb recapture and one for
///      pools with it on (which HookrRules never binds), each 0 to MAX_MIN_FEE_PIPS (10,000, 1%) and
///      DEFAULT_MIN_FEE_PIPS (1,000) at construction, and a per-integrator override, 0 to 10,000.
///      Naming an integrator is a creator's free choice at launch, so the override is not a rate for every pool that
///      names it: a pool binds it only when the integrator itself approved that pool's id beforehand
///      (`approveMinFeePool`); any other pool naming the integrator binds the rate for its kind. Each rate or override
///      change waits TERMS_DELAY and lapses TERMS_GRACE after that, like the other fee terms; taking an integrator off
///      the list also removes its override. Pools already bound keep the minimum they froze.
///
///      The owned-root fee. The owned-root factory (IHookrOwnedRootFactory) reads `ownedRootFee()` on every deployment,
///      takes exactly that much native currency from the deployer and forwards it to this treasury's target in the
///      same transaction. It is a deterrent against filling the factory's deployment cap, not a share of any pool. It
///      starts at DEFAULT_OWNED_ROOT_FEE (0.01) at construction, is at most MAX_OWNED_ROOT_FEE (1) of the native
///      currency, moves in steps of OWNED_ROOT_FEE_UNIT (0.0001), and changes like the other fee terms: proposed, then
///      accepted after TERMS_DELAY and before TERMS_GRACE runs out, voided by a change of owner.
contract HookrTreasury is HookrReleased, IHookrTreasury {
    using CurrencyLibrary for Currency;

    /// @inheritdoc IHookrTreasury
    uint256 public constant override DELIVERY_GAS = 100_000;
    /// @inheritdoc IHookrTreasury
    uint256 public constant override TARGET_DELAY = 30 minutes;
    /// @inheritdoc IHookrTreasury
    uint256 public constant override TARGET_GRACE = 14 days;
    /// @inheritdoc IHookrTreasury
    uint256 public constant override TERMS_DELAY = 30 minutes;
    /// @inheritdoc IHookrTreasury
    uint256 public constant override TERMS_GRACE = 14 days;
    /// @inheritdoc IHookrTreasury
    uint16 public constant override MAX_RULE_SHARE_FLOOR_BPS = 5_000;
    /// @inheritdoc IHookrTreasury
    uint16 public constant override MAX_INTEGRATOR_BPS = 5_000;
    /// @inheritdoc IHookrTreasury
    uint16 public constant override DEFAULT_INTEGRATOR_BPS = 5_000;
    /// @inheritdoc IHookrTreasury
    uint16 public constant override MAX_MIN_FEE_PIPS = 10_000;
    /// @inheritdoc IHookrTreasury
    uint16 public constant override DEFAULT_MIN_FEE_PIPS = 1_000;
    /// @inheritdoc IHookrTreasury
    uint16 public constant override NO_MIN_FEE_OVERRIDE = type(uint16).max;
    /// @inheritdoc IHookrTreasury
    uint256 public constant override OWNED_ROOT_FEE_UNIT = 1e14;
    /// @inheritdoc IHookrTreasury
    uint256 public constant override MAX_OWNED_ROOT_FEE = 1e18;
    /// @inheritdoc IHookrTreasury
    uint256 public constant override DEFAULT_OWNED_ROOT_FEE = 1e16;
    /// @dev keccak256(abi.encode(uint256(keccak256("hookr.treasury")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SLOT = 0xfbe7548a70873d48ea7fddfba1199106377ceedcd42dbef7dc33de62b5287a00;
    /// @dev Transient reentrancy lock.
    bytes32 private constant ENTERED = keccak256("hookr.treasury.transient.entered");
    /// @dev The gas each answer of the owned-root check may use.
    uint256 private constant PROVENANCE_GAS = 50_000;
    /// @inheritdoc IHookrTreasury
    IPoolManager public immutable override poolManager;

    /// @dev One fee-terms entry: the current value, a pending value, when the pending value can be accepted (zero
    ///      when none is pending) and the owner epoch it was proposed in.
    struct Terms {
        uint16 current;
        uint16 pending;
        uint64 readyAt;
        uint64 epoch;
    }

    /// @custom:storage-location erc7201:hookr.treasury
    struct State {
        address owner;
        address pendingOwner;
        address target;
        address pendingTarget;
        uint256 targetReadyAt;
        mapping(address source => bytes32 codeHash) sourceCodeHash;
        /// @dev Bumped by every change of owner, which voids every fee-terms proposal made before it.
        uint64 ownerEpoch;
        Terms floor;
        mapping(address account => Terms) integrators;
        /// @dev The Hookr minimum of pools without arb recapture, in pips.
        Terms minFee;
        /// @dev The Hookr minimum of pools with arb recapture on, in pips.
        Terms recaptureMinFee;
        /// @dev Per-integrator override of the Hookr minimum, stored as pips + 1 so that zero is no override.
        mapping(address account => Terms) minFeeOverrides;
        /// @dev The pool ids each account approved to bind its override.
        mapping(address account => mapping(PoolId id => bool)) minFeePools;
        /// @dev The owned-root fee, in OWNED_ROOT_FEE_UNIT steps of the native currency.
        Terms ownedRootFee;
        /// @dev The registry whose owned roots' companions are admitted on their first collection; zero for none.
        address ownedRootRegistry;
    }

    constructor(address _owner, address _target, IPoolManager _poolManager) {
        if (_owner == address(0) || address(_poolManager) == address(0) || address(_poolManager).code.length == 0) {
            revert InvalidAddress();
        }
        _refuseDelegated(_owner);
        poolManager = _poolManager;
        State storage s = _state();
        s.owner = _owner;
        _requireTarget(_target);
        s.target = _target;
        s.minFee.current = DEFAULT_MIN_FEE_PIPS;
        s.recaptureMinFee.current = DEFAULT_MIN_FEE_PIPS;
        s.ownedRootFee.current = uint16(DEFAULT_OWNED_ROOT_FEE / OWNED_ROOT_FEE_UNIT);
        emit OwnershipTransferred(address(0), _owner);
        emit TargetSet(address(0), _target);
        emit MinFeeSet(false, 0, DEFAULT_MIN_FEE_PIPS);
        emit MinFeeSet(true, 0, DEFAULT_MIN_FEE_PIPS);
        emit OwnedRootFeeSet(0, DEFAULT_OWNED_ROOT_FEE);
    }

    modifier onlyOwner() {
        if (msg.sender != _state().owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        bytes32 slot = ENTERED;
        uint256 entered;
        assembly ("memory-safe") {
            entered := tload(slot)
        }
        if (entered != 0) revert Reentrancy();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    receive() external payable {}

    /// @inheritdoc IHookrTreasury
    function owner() external view override returns (address) {
        return _state().owner;
    }

    /// @inheritdoc IHookrTreasury
    function pendingOwner() external view override returns (address) {
        return _state().pendingOwner;
    }

    /// @inheritdoc IHookrTreasury
    function target() external view override returns (address) {
        return _state().target;
    }

    /// @inheritdoc IHookrTreasury
    function pendingTarget() external view override returns (address) {
        return _state().pendingTarget;
    }

    /// @inheritdoc IHookrTreasury
    function targetReadyAt() external view override returns (uint256) {
        return _state().targetReadyAt;
    }

    /// @inheritdoc IHookrTreasury
    function sourceCodeHash(address source) external view override returns (bytes32) {
        return _state().sourceCodeHash[source];
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Propose the next owner; the zero address cancels a pending proposal.
    function proposeOwner(address nextOwner) external override onlyOwner nonReentrant {
        State storage s = _state();
        // Zero cancels a pending proposal; ownership itself cannot be renounced accidentally.
        if (nextOwner == s.owner) revert InvalidAddress();
        _refuseDelegated(nextOwner);
        s.pendingOwner = nextOwner;
        emit OwnershipProposed(nextOwner);
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Accept a pending ownership transfer as the nominated owner.
    /// @dev Clears any pending destination: a new owner proposes its own and waits the full delay.
    function acceptOwnership() external override nonReentrant {
        State storage s = _state();
        if (msg.sender != s.pendingOwner) revert NotPendingOwner();
        _refuseDelegated(msg.sender);
        address previous = s.owner;
        s.owner = msg.sender;
        s.pendingOwner = address(0);
        address proposed = s.pendingTarget;
        if (proposed != address(0)) {
            delete s.pendingTarget;
            delete s.targetReadyAt;
            emit TargetProposalCancelled(proposed);
        }
        // Every fee-terms proposal of the previous owner lapses with it (`_accept` checks the epoch). The three
        // single entries say so each; the per-account ones, which cannot be listed, through the epoch.
        if (_live(s.floor)) emit RuleShareFloorProposalCancelled(s.floor.pending);
        if (_live(s.minFee)) emit MinFeeProposalCancelled(false, s.minFee.pending);
        if (_live(s.recaptureMinFee)) emit MinFeeProposalCancelled(true, s.recaptureMinFee.pending);
        if (_live(s.ownedRootFee)) {
            emit OwnedRootFeeProposalCancelled(uint256(s.ownedRootFee.pending) * OWNED_ROOT_FEE_UNIT);
        }
        emit FeeTermsProposalsVoided(++s.ownerEpoch);
        emit OwnershipTransferred(previous, msg.sender);
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Propose a new destination for protocol-owned funds. It can be accepted after `TARGET_DELAY`.
    /// @dev A new proposal replaces the pending one and restarts the delay. Until acceptance, permissionless
    ///      `collect`, `collectTo` and `forwardBalance` keep paying the current target.
    function proposeTarget(address nextTarget) external override onlyOwner nonReentrant {
        State storage s = _state();
        _requireTarget(nextTarget);
        if (nextTarget == s.target) revert InvalidTarget();
        uint256 readyAt = block.timestamp + TARGET_DELAY;
        s.pendingTarget = nextTarget;
        s.targetReadyAt = readyAt;
        emit TargetProposed(s.target, nextTarget, readyAt);
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Withdraw the pending destination proposal.
    function cancelTarget() external override onlyOwner nonReentrant {
        State storage s = _state();
        address proposed = s.pendingTarget;
        if (proposed == address(0)) revert NoPendingTarget();
        delete s.pendingTarget;
        delete s.targetReadyAt;
        emit TargetProposalCancelled(proposed);
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Make the matured proposal the destination for protocol-owned funds, within `TARGET_GRACE` of maturity.
    function acceptTarget() external override onlyOwner nonReentrant {
        State storage s = _state();
        address nextTarget = s.pendingTarget;
        if (nextTarget == address(0)) revert NoPendingTarget();
        uint256 readyAt = s.targetReadyAt;
        if (block.timestamp < readyAt) revert TargetNotReady(nextTarget, readyAt);
        if (block.timestamp > readyAt + TARGET_GRACE) revert TargetExpired(nextTarget, readyAt + TARGET_GRACE);
        // Re-check: a source admitted after the proposal must not become the destination.
        _requireTarget(nextTarget);
        address previous = s.target;
        s.target = nextTarget;
        delete s.pendingTarget;
        delete s.targetReadyAt;
        emit TargetSet(previous, nextTarget);
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Append a reviewed non-proxy Rules source which already assigns its protocol claims here.
    /// @dev Admission is off the swap path. A getter and code hash are necessary wiring checks,
    ///      not proof that an arbitrary candidate has the promised semantics. An EIP-7702 delegated
    ///      account is refused: its codehash does not pin its behaviour or its balances. An account on the integrator
    ///      list, or with a pending proposal to list it, is refused: no source ever claims an integrator's credit.
    function admitSource(address source) external override onlyOwner nonReentrant {
        State storage s = _state();
        Terms storage listed = s.integrators[source];
        if (
            source == address(0) || source == address(this) || source == s.target || source == s.pendingTarget
                || source.code.length == 0 || HookrDelegation.isDelegated(source) || listed.current != 0
                || _pending(listed)
        ) revert InvalidSource();
        if (s.sourceCodeHash[source] != bytes32(0)) revert SourceAlreadyAdmitted();
        IHookrProtocolClaims claims = IHookrProtocolClaims(source);
        if (claims.protocolRecipient() != address(this) || address(claims.poolManager()) != address(poolManager)) {
            revert InvalidSource();
        }
        bytes32 codeHash = source.codehash;
        s.sourceCodeHash[source] = codeHash;
        emit SourceAdmitted(source, codeHash);
    }

    /// @inheritdoc IHookrTreasury
    function ownedRootRegistry() external view override returns (address) {
        return _state().ownedRootRegistry;
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Name the registry whose owned roots' companion Rules are admitted on their first collection, or zero to
    ///         admit no further companion that way. Sources already admitted stay admitted.
    /// @dev Effective at once, like `admitSource`, since it admits no source `admitSource` could not.
    function setOwnedRootRegistry(address registry) external override onlyOwner nonReentrant {
        if (registry != address(0) && registry.code.length == 0) revert InvalidAddress();
        State storage s = _state();
        address previous = s.ownedRootRegistry;
        s.ownedRootRegistry = registry;
        emit OwnedRootRegistrySet(previous, registry);
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Pull this treasury's claims, measure the receipt, then attempt delivery.
    /// @dev Failed delivery rolls back the delivery subcall only; protocol cash remains here.
    ///      Existing treasury balances are excluded from the receipt and are never counted twice.
    function collect(address source, Currency currency) external override nonReentrant returns (uint256 received) {
        IHookrProtocolClaims claims = _admitted(source);
        if (claims.claimable(currency, address(this)) == 0) return 0;
        uint256 beforeBalance = currency.balanceOfSelf();
        uint256 reported = claims.claimTo(currency, address(this));
        uint256 afterBalance = currency.balanceOfSelf();
        if (afterBalance < beforeBalance) revert ReceiptMismatch(reported, 0);
        received = afterBalance - beforeBalance;
        if (received != reported) revert ReceiptMismatch(reported, received);
        emit ProtocolCollected(source, currency, address(this), received);
        if (received != 0) _forward(currency, received);
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Pay this treasury's claim from an admitted source, or an owned root's companion, straight to the current
    ///         target.
    /// @dev Fallback for an asset whose issuer restricts this treasury's own address: the claim then never
    ///      passes through the treasury. The target's measured receipt must equal the reported claim, so a
    ///      transfer-fee, rebasing or forwarding target reverts instead of recording a false amount. Anyone may
    ///      call it; it emits only `ProtocolCollected(source, currency, target, amount)`.
    function collectTo(address source, Currency currency) external override nonReentrant returns (uint256 received) {
        IHookrProtocolClaims claims = _admitted(source);
        if (claims.claimable(currency, address(this)) == 0) return 0;
        address to = _state().target;
        uint256 beforeBalance = currency.balanceOf(to);
        uint256 reported = claims.claimTo(currency, to);
        uint256 afterBalance = currency.balanceOf(to);
        if (afterBalance < beforeBalance) revert ReceiptMismatch(reported, 0);
        received = afterBalance - beforeBalance;
        if (received != reported) revert ReceiptMismatch(reported, received);
        emit ProtocolCollected(source, currency, to, received);
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Credit this treasury's claim from an admitted Rules source, or an owned root's companion, to the current
    ///         target as PoolManager ERC-6909 claims of `currency`. Moves no token.
    /// @dev The exit for a quote that stops delivering exact amounts (a transfer fee switched on, a pause, a
    ///      rebase), which makes `collect` and `collectTo` revert. The target redeems the ERC-6909 balance through
    ///      any PoolManager unlock once the token delivers again. The target's measured ERC-6909 receipt must equal
    ///      the reported claim. Only the owner or the current target may call it, since a target that can only
    ///      move tokens cannot redeem ERC-6909 claims; it emits only `ProtocolCollected(source, currency, target,
    ///      amount)`. A source without `claimAsClaims` reverts.
    function collectAsClaims(address source, Currency currency)
        external
        override
        nonReentrant
        returns (uint256 received)
    {
        State storage s = _state();
        address to = s.target;
        if (msg.sender != s.owner && msg.sender != to) revert NotOwner();
        IHookrProtocolClaims claims = _admitted(source);
        if (claims.claimable(currency, address(this)) == 0) return 0;
        uint256 id = currency.toId();
        uint256 beforeBalance = poolManager.balanceOf(to, id);
        uint256 reported = IHookrProtocolClaimsTransfer(source).claimAsClaims(currency, to);
        uint256 afterBalance = poolManager.balanceOf(to, id);
        if (afterBalance < beforeBalance) revert ReceiptMismatch(reported, 0);
        received = afterBalance - beforeBalance;
        if (received != reported) revert ReceiptMismatch(reported, received);
        emit ProtocolCollected(source, currency, to, received);
    }

    /// @inheritdoc IHookrTreasury
    /// @dev The minimum is the account's override when it has one and approved `id`, else the arb recapture rate or
    ///      the plain rate.
    function feeTerms(address account, bool recapture, PoolId id)
        external
        view
        override
        returns (uint16 floorBps, uint16 integratorBps, uint16 minFee)
    {
        State storage s = _state();
        floorBps = s.floor.current;
        minFee = recapture ? s.recaptureMinFee.current : s.minFee.current;
        if (account != address(0)) {
            integratorBps = s.integrators[account].current;
            uint16 stored = s.minFeeOverrides[account].current;
            if (stored != 0 && s.minFeePools[account][id]) minFee = stored - 1;
        }
    }

    /// @inheritdoc IHookrTreasury
    function minFeePoolApproved(address account, PoolId id) external view override returns (bool) {
        return _state().minFeePools[account][id];
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Approve, or withdraw the approval of, pool `id` binding the caller's Hookr minimum override when it
    ///         names the caller as its integrator. Only the caller's own approvals change, and an approval does
    ///         nothing while the caller has no override or is off the list. It is read once, at bind: a pool already
    ///         bound keeps the minimum it froze whatever happens to the approval later.
    function approveMinFeePool(PoolId id, bool approved) external override nonReentrant {
        _state().minFeePools[msg.sender][id] = approved;
        emit MinFeePoolApproved(msg.sender, id, approved);
    }

    /// @inheritdoc IHookrTreasury
    function minFeePips(bool recapture) external view override returns (uint16) {
        return _minFee(recapture).current;
    }

    /// @inheritdoc IHookrTreasury
    function pendingMinFee(bool recapture) external view override returns (uint16 pips, uint256 readyAt) {
        Terms storage t = _minFee(recapture);
        if (_pending(t)) (pips, readyAt) = (t.pending, t.readyAt);
    }

    /// @inheritdoc IHookrTreasury
    function integratorMinFee(address account)
        external
        view
        override
        returns (uint16 pips, uint16 pendingPips, uint256 readyAt)
    {
        Terms storage t = _state().minFeeOverrides[account];
        pips = _decodeOverride(t.current);
        pendingPips = NO_MIN_FEE_OVERRIDE;
        if (_pending(t)) (pendingPips, readyAt) = (_decodeOverride(t.pending), t.readyAt);
    }

    /// @inheritdoc IHookrTreasury
    function ruleShareFloorBps() external view override returns (uint16) {
        return _state().floor.current;
    }

    /// @inheritdoc IHookrTreasury
    function pendingRuleShareFloor() external view override returns (uint16 floorBps, uint256 readyAt) {
        Terms storage t = _state().floor;
        if (_pending(t)) (floorBps, readyAt) = (t.pending, t.readyAt);
    }

    /// @inheritdoc IHookrTreasury
    function integrator(address account)
        external
        view
        override
        returns (uint16 rateBps, uint16 pendingRateBps, uint256 readyAt)
    {
        Terms storage t = _state().integrators[account];
        rateBps = t.current;
        if (_pending(t)) (pendingRateBps, readyAt) = (t.pending, t.readyAt);
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Propose the governed rule-share floor for pools bound from now on (0 to 5,000). It can be accepted
    ///         after TERMS_DELAY. A Rules never binds below its own immutable floor, whatever this one says.
    function proposeRuleShareFloor(uint16 floorBps) external override onlyOwner nonReentrant {
        Terms storage t = _state().floor;
        if (floorBps > MAX_RULE_SHARE_FLOOR_BPS || floorBps == t.current) revert InvalidTerms();
        emit RuleShareFloorProposed(t.current, floorBps, _propose(t, floorBps));
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Withdraw the pending rule-share floor.
    function cancelRuleShareFloor() external override onlyOwner nonReentrant {
        Terms storage t = _state().floor;
        if (!_live(t)) revert NoPendingTerms();
        emit RuleShareFloorProposalCancelled(t.pending);
        t.readyAt = 0;
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Make the matured rule-share floor proposal the governed floor, within TERMS_GRACE of maturity.
    function acceptRuleShareFloor() external override onlyOwner nonReentrant {
        Terms storage t = _state().floor;
        uint16 previous = t.current;
        emit RuleShareFloorSet(previous, _accept(t));
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Propose listing `account` as an integrator, or re-rating it, at `rateBps` (1 to 5,000) of Hookr's
    ///         rule-fee share. It can be accepted after TERMS_DELAY. Neither the zero address, this treasury, the
    ///         PoolManager nor an admitted source can be listed.
    function proposeIntegrator(address account, uint16 rateBps) external override onlyOwner nonReentrant {
        Terms storage t = _state().integrators[account];
        if (!_listable(account) || rateBps == 0 || rateBps > MAX_INTEGRATOR_BPS || rateBps == t.current) {
            revert InvalidTerms();
        }
        emit IntegratorProposed(account, t.current, rateBps, _propose(t, rateBps));
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Withdraw the pending proposal for `account`.
    function cancelIntegrator(address account) external override onlyOwner nonReentrant {
        Terms storage t = _state().integrators[account];
        if (!_live(t)) revert NoPendingTerms();
        emit IntegratorProposalCancelled(account, t.pending);
        t.readyAt = 0;
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Make the matured proposal for `account` its rate on the list, within TERMS_GRACE of maturity. The
    ///         addresses proposeIntegrator refuses are refused again, as acceptTarget re-checks its target.
    function acceptIntegrator(address account) external override onlyOwner nonReentrant {
        if (!_listable(account)) revert InvalidTerms();
        Terms storage t = _state().integrators[account];
        uint16 previous = t.current;
        emit IntegratorSet(account, previous, _accept(t));
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Take `account` off the integrator list at once and void any pending proposal for it, and remove its
    ///         Hookr minimum override with any pending one. Pools bound with it keep paying it at their frozen rate and
    ///         keep their frozen minimum; new pools can no longer name it. An account neither listed nor with a pending
    ///         proposal (a lapsed one is not) reverts NotListed. Each proposal it voids emits its cancellation.
    function removeIntegrator(address account) external override onlyOwner nonReentrant {
        State storage s = _state();
        Terms storage t = s.integrators[account];
        uint16 previous = t.current;
        if (previous == 0 && !_pending(t)) revert NotListed(account);
        if (_live(t)) emit IntegratorProposalCancelled(account, t.pending);
        (t.current, t.readyAt) = (0, 0);
        emit IntegratorRemoved(account, previous);
        Terms storage o = s.minFeeOverrides[account];
        uint16 stored = o.current;
        if (_live(o)) emit IntegratorMinFeeProposalCancelled(account, _decodeOverride(o.pending));
        (o.current, o.readyAt) = (0, 0);
        if (stored != 0) emit IntegratorMinFeeSet(account, stored - 1, NO_MIN_FEE_OVERRIDE);
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Propose the Hookr minimum, in pips (0 to 10,000), for Hookr token pools bound from now on: with arb
    ///         recapture on when `recapture`, else without it. It can be accepted after TERMS_DELAY; a new proposal
    ///         replaces the pending one.
    function proposeMinFee(bool recapture, uint16 pips) external override onlyOwner nonReentrant {
        Terms storage t = _minFee(recapture);
        if (pips > MAX_MIN_FEE_PIPS || pips == t.current) revert InvalidTerms();
        emit MinFeeProposed(recapture, t.current, pips, _propose(t, pips));
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Withdraw the pending Hookr minimum of the pools `recapture` names.
    function cancelMinFee(bool recapture) external override onlyOwner nonReentrant {
        Terms storage t = _minFee(recapture);
        if (!_live(t)) revert NoPendingTerms();
        emit MinFeeProposalCancelled(recapture, t.pending);
        t.readyAt = 0;
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Make the matured Hookr minimum proposal current, within TERMS_GRACE of maturity.
    function acceptMinFee(bool recapture) external override onlyOwner nonReentrant {
        Terms storage t = _minFee(recapture);
        uint16 previous = t.current;
        emit MinFeeSet(recapture, previous, _accept(t));
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Propose `account`'s Hookr minimum override, in pips (0 to 10,000), or NO_MIN_FEE_OVERRIDE to remove
    ///         it. A pool bound from its acceptance on that names `account` as its integrator, and whose id `account`
    ///         approved (`approveMinFeePool`), binds the override instead of either rate. The addresses
    ///         proposeIntegrator refuses are refused.
    function proposeIntegratorMinFee(address account, uint16 pips) external override onlyOwner nonReentrant {
        Terms storage t = _state().minFeeOverrides[account];
        uint16 stored = pips == NO_MIN_FEE_OVERRIDE ? 0 : pips + 1;
        if (!_listable(account) || (pips > MAX_MIN_FEE_PIPS && stored != 0) || stored == t.current) {
            revert InvalidTerms();
        }
        emit IntegratorMinFeeProposed(account, _decodeOverride(t.current), pips, _propose(t, stored));
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Withdraw the pending Hookr minimum override of `account`.
    function cancelIntegratorMinFee(address account) external override onlyOwner nonReentrant {
        Terms storage t = _state().minFeeOverrides[account];
        if (!_live(t)) revert NoPendingTerms();
        emit IntegratorMinFeeProposalCancelled(account, _decodeOverride(t.pending));
        t.readyAt = 0;
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Make the matured override proposal for `account` current, within TERMS_GRACE of maturity.
    function acceptIntegratorMinFee(address account) external override onlyOwner nonReentrant {
        Terms storage t = _state().minFeeOverrides[account];
        uint16 previous = _decodeOverride(t.current);
        emit IntegratorMinFeeSet(account, previous, _decodeOverride(_accept(t)));
    }

    /// @inheritdoc IHookrTreasury
    function ownedRootFee() external view override returns (uint256) {
        return uint256(_state().ownedRootFee.current) * OWNED_ROOT_FEE_UNIT;
    }

    /// @inheritdoc IHookrTreasury
    function pendingOwnedRootFee() external view override returns (uint256 fee, uint256 readyAt) {
        Terms storage t = _state().ownedRootFee;
        if (_pending(t)) (fee, readyAt) = (uint256(t.pending) * OWNED_ROOT_FEE_UNIT, t.readyAt);
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Propose the owned-root fee, 0 to MAX_OWNED_ROOT_FEE in steps of OWNED_ROOT_FEE_UNIT, for every owned
    ///         root deployed from its acceptance on. It can be accepted after TERMS_DELAY; a new proposal replaces the
    ///         pending one.
    function proposeOwnedRootFee(uint256 fee) external override onlyOwner nonReentrant {
        Terms storage t = _state().ownedRootFee;
        if (fee > MAX_OWNED_ROOT_FEE || fee % OWNED_ROOT_FEE_UNIT != 0 || fee / OWNED_ROOT_FEE_UNIT == t.current) {
            revert InvalidTerms();
        }
        uint256 readyAt = _propose(t, uint16(fee / OWNED_ROOT_FEE_UNIT));
        emit OwnedRootFeeProposed(uint256(t.current) * OWNED_ROOT_FEE_UNIT, fee, readyAt);
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Withdraw the pending owned-root fee.
    function cancelOwnedRootFee() external override onlyOwner nonReentrant {
        Terms storage t = _state().ownedRootFee;
        if (!_live(t)) revert NoPendingTerms();
        emit OwnedRootFeeProposalCancelled(uint256(t.pending) * OWNED_ROOT_FEE_UNIT);
        t.readyAt = 0;
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Make the matured owned-root fee proposal current, within TERMS_GRACE of maturity.
    function acceptOwnedRootFee() external override onlyOwner nonReentrant {
        Terms storage t = _state().ownedRootFee;
        uint256 previous = uint256(t.current) * OWNED_ROOT_FEE_UNIT;
        emit OwnedRootFeeSet(previous, uint256(_accept(t)) * OWNED_ROOT_FEE_UNIT);
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Retry deferred protocol funds or forward an unassigned donation to the configured target.
    /// @dev Every balance here is protocol-owned; this function must never be reused as a sweep
    ///      for contracts that custody user principal or reward liabilities.
    function forwardBalance(Currency currency) external override nonReentrant returns (uint256 amount, bool delivered) {
        amount = currency.balanceOfSelf();
        if (amount == 0) return (0, true);
        delivered = _forward(currency, amount);
    }

    /// @inheritdoc IHookrTreasury
    /// @notice Transfer protocol funds inside a failure-isolated self-call.
    /// @dev A self-call isolates transfer failures, including a token that mutates then returns false.
    ///      No caller other than this contract may select the destination or amount.
    function deliver(Currency currency, address to, uint256 amount) external override {
        if (msg.sender != address(this)) revert NotSelf();
        currency.transfer(to, amount);
    }

    function _forward(Currency currency, uint256 amount) private returns (bool delivered) {
        address to = _state().target;
        try this.deliver{gas: DELIVERY_GAS}(currency, to, amount) {
            emit ProtocolForwarded(currency, to, amount);
            return true;
        } catch {
            emit ProtocolForwardDeferred(currency, to, amount);
            return false;
        }
    }

    /// @dev An admitted source, or an owned root's companion the registry vouches for, admitted here on this first
    ///      collection. Either way the source must still run its admitted runtime codehash.
    function _admitted(address source) private returns (IHookrProtocolClaims) {
        State storage s = _state();
        bytes32 admitted = s.sourceCodeHash[source];
        if (admitted == bytes32(0)) admitted = _admitCompanion(s, source);
        if (source.codehash != admitted) revert SourceCodeChanged();
        return IHookrProtocolClaims(source);
    }

    /// @dev Admits `source` when the owned-root registry vouches for it: the root it trusts is an owned root, the
    ///      factory that registered that root names `source` as its companion, and `source` pays this treasury on its
    ///      PoolManager. It must pass what `admitSource` requires: code that is not an EIP-7702 delegation, and neither
    ///      this treasury, the target, the pending target, a listed integrator nor one with a pending proposal. Reverts
    ///      InvalidSource otherwise.
    function _admitCompanion(State storage s, address source) private returns (bytes32 codeHash) {
        address registry = s.ownedRootRegistry;
        Terms storage listed = s.integrators[source];
        if (
            registry == address(0) || source == address(this) || source == s.target || source == s.pendingTarget
                || source.code.length == 0 || HookrDelegation.isDelegated(source) || listed.current != 0
                || _pending(listed)
        ) revert InvalidSource();
        (bool ok, uint256 word) = _answer(source, abi.encodeCall(IHookrRules.trustedRoot, ()));
        address root = address(uint160(word));
        if (!ok || word >> 160 != 0) revert InvalidSource();
        (ok, word) = _answer(registry, abi.encodeCall(IHookrOwnedRoots.isOwnedRoot, (root)));
        if (!ok || word != 1) revert InvalidSource();
        (ok, word) = _answer(registry, abi.encodeCall(IHookrOwnedRoots.ownedRegistrarForRoot, (root)));
        address registrar = address(uint160(word));
        if (!ok || word >> 160 != 0) revert InvalidSource();
        (ok, word) = _answer(registrar, abi.encodeCall(IHookrRootRegistrar.rulesOf, (root)));
        if (!ok || word != uint256(uint160(source))) revert InvalidSource();
        IHookrProtocolClaims claims = IHookrProtocolClaims(source);
        if (claims.protocolRecipient() != address(this) || address(claims.poolManager()) != address(poolManager)) {
            revert InvalidSource();
        }
        codeHash = source.codehash;
        s.sourceCodeHash[source] = codeHash;
        emit SourceAdmitted(source, codeHash);
    }

    /// @dev The answer of a static call to `account` with `data` and at most PROVENANCE_GAS, and whether it succeeded
    ///      with exactly one word. An account without code answers nothing.
    function _answer(address account, bytes memory data) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            // The call first: Yul evaluates arguments right to left, so returndatasize() must come after it.
            let called := staticcall(PROVENANCE_GAS, account, add(data, 32), mload(data), 0, 32)
            ok := and(called, eq(returndatasize(), 32))
            word := mload(0)
        }
    }

    /// @dev Queues `value` on `t` for TERMS_DELAY under the current owner epoch, replacing any pending value.
    function _propose(Terms storage t, uint16 value) private returns (uint256 readyAt) {
        readyAt = block.timestamp + TERMS_DELAY;
        (t.pending, t.readyAt, t.epoch) = (value, uint64(readyAt), _state().ownerEpoch);
    }

    /// @dev Moves `t`'s matured pending value to current within TERMS_GRACE of maturity. A proposal made under an
    ///      earlier owner is void.
    function _accept(Terms storage t) private returns (uint16 value) {
        uint256 readyAt = t.readyAt;
        if (!_live(t)) revert NoPendingTerms();
        if (block.timestamp < readyAt) revert TermsNotReady(readyAt);
        if (block.timestamp > readyAt + TERMS_GRACE) revert TermsExpired(readyAt + TERMS_GRACE);
        value = t.pending;
        (t.current, t.readyAt) = (value, 0);
    }

    function _minFee(bool recapture) private view returns (Terms storage) {
        State storage s = _state();
        return recapture ? s.recaptureMinFee : s.minFee;
    }

    /// @dev A stored override (pips + 1, zero for none) as pips, or NO_MIN_FEE_OVERRIDE for none.
    function _decodeOverride(uint16 stored) private pure returns (uint16) {
        return stored == 0 ? NO_MIN_FEE_OVERRIDE : stored - 1;
    }

    /// @dev Whether `t` holds a proposal of the current owner, lapsed or not: what cancel voids and `_accept` names.
    function _live(Terms storage t) private view returns (bool) {
        return t.readyAt != 0 && t.epoch == _state().ownerEpoch;
    }

    /// @dev Whether `t` holds a proposal of the current owner that has not lapsed: what the pending views report.
    function _pending(Terms storage t) private view returns (bool) {
        return _live(t) && block.timestamp <= t.readyAt + TERMS_GRACE;
    }

    /// @dev Whether `account` may be listed or given an override: not the zero address, this treasury, the
    ///      PoolManager or an admitted source.
    function _listable(address account) private view returns (bool) {
        return account != address(0) && account != address(this) && account != address(poolManager)
            && _state().sourceCodeHash[account] == bytes32(0);
    }

    /// @dev Reverts if `account`'s code starts with 0xEF (HookrDelegation.isDelegated): an EIP-7702 delegation
    ///      designator, which its key holder can re-point so that its codehash pins nothing, or a Stylus program.
    function _refuseDelegated(address account) private view {
        if (HookrDelegation.isDelegated(account)) revert DelegatedAccount(account);
    }

    function _requireTarget(address candidate) private view {
        if (
            candidate == address(0) || candidate == address(this) || candidate == address(poolManager)
                || _state().sourceCodeHash[candidate] != bytes32(0)
        ) revert InvalidTarget();
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") {
            s.slot := SLOT
        }
    }
}
