// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {IHookrLauncherView} from "hookr/interfaces/IHookrLauncherView.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {IHookrAgentGate} from "./interfaces/IHookrAgentGate.sol";
import {IERC8004Identity, IERC8004Reputation} from "./interfaces/external/IERC8004.sol";
import {IERC1271} from "./interfaces/external/IERC1271.sol";
import {IPositionManagerView} from "./interfaces/external/IPositionManagerView.sol";

/// @title Hookr agent gate (second gate)
/// @notice Fail-closed BEFORE_SWAP and liquidity advisory that makes a pool agents-only: a buy, a sell or a liquidity
///         add is admitted only for a wallet that holds an ERC-8004 agent identity, or is the registered agent wallet
///         or owner of an identity it linked here. Removals are never gated. The pool's frozen arb recapture executor's
///         legs pass on the root's word alone while its lane is on. Optional, frozen per pool: an admission threshold
///         on the agent's reputation score from a chosen reviewer, a fee tier that charges agents below a threshold an
///         LP-fee surcharge, and a floor on the age of the wallet's link.
///
///         What this gate changes against the first (0x3b1aC66a6Fd9e9d8F063d145003cf29eac4Fb0C9 on 4663):
///         - An add through Uniswap's PositionManager is screened on the wallet the PositionManager names through
///           `msgSender()`, never on the PositionManager itself, so an identity sent to the PositionManager opens
///           nothing. The PositionManager is pinned by address and code at construction.
///         - A wallet with ordinary runtime code is an agent only through a link it made itself and proved
///           with its own ERC-1271 signature over the gate's Link digest. An identity sent to a shared contract gives
///           it no entry, and one parked in a call-forwarder anyone can drive (Multicall3, an ERC-2771 forwarder)
///           cannot be linked through it. A wallet without code, or an EIP-7702 delegated one, still passes by balance
///           and links without a proof. Constructor trades/adds therefore retain balance-only access, which a
///           public CREATE2 constructor relay can share. A codeless Nitro origin alias can also link; this gate
///           does not distinguish that alias from an ordinary origin wallet.
///         - The creator (the launch's family owner) is screened at bind: a launch a non-agent would own, a revenue
///           token's stream launch included (the tokenizer owns that family), reverts with InvalidPoolConfig(11).
///           A creator with no code must also be tx.origin, so a constructor cannot bind a gated pool.
///         - A link-age floor per pool (`Terms.minAge`): the clock starts at the wallet's first link to the id.
///         - The registry pins live in storage. The owner can suspend and resume the gate, and re-pin the registries
///           after a reviewed upgrade, so an upgrade degrades the pools (entries refused, sells open) rather than
///           ending them. There is no one-way retire.
/// @dev Stateless on the swap path: every read is a static call. After bind nothing about a pool changes; the only
///      writes are a wallet's own link, a reviewer set (content-addressed, immutable) and the owner's suspend, resume,
///      and re-pin. Storage is keyed by the binder, so a third-party bind writes only its own namespace.
contract HookrAgentGate is HookrReleased, IHookrAgentGate, IHookrAdvisory {
    using PoolIdLibrary for PoolKey;

    /// @custom:storage-location erc7201:hookr.agent.gate.v2.state
    struct State {
        mapping(address binder => mapping(PoolId => Bound)) bound;
        /// @dev The agent id a wallet linked, plus one: zero is no link, so identity 0 can link too.
        mapping(address wallet => uint256 linkedPlusOne) links;
        /// @dev When a wallet first linked an id: written once, kept through unlink.
        mapping(address wallet => mapping(uint256 agentId => uint64 since)) linkedAt;
        mapping(bytes32 id => ReviewerSet) reviewers;
        Pins pins;
        bool suspended;
        uint48 repinAt;
        /// @dev How many links a contract wallet proved: the nonce its next Link digest carries.
        mapping(address wallet => uint256 nonce) linkNonces;
        /// @dev Hash of the four registry pins the owner reviewed when queuing the re-pin.
        bytes32 repinCommitment;
    }

    struct ReviewerSet {
        address[] clients;
        string tag;
        bytes32 tagHash;
    }

    /// @dev cast index-erc7201 hookr.agent.gate.v2.state. Read through the immutable `_stateSlot`: as a constant the
    ///      compiler stores it as data after the code and leaves the metadata tail after data rather than after
    ///      INVALID, which the conformance kit's opcode scan then reads (HookrCredentialGate found this).
    bytes32 private constant STATE_SLOT = 0x3846dc6bfc7c1b6c2daf13146ca59ee9272451fb535d0ccec61a42b9419fd200;
    /// @dev keccak256("Terms(uint16 flags,uint32 minScore,uint32 tierScore,uint24 tierPips,bytes32 reviewers,uint32 minAge)").
    bytes32 private constant SCHEMA_HASH = 0xc6848895ec12bfc54b1d011fdda88ab892250ccd0910f40dcf2025e17ac3225d;
    /// @dev ABI size of Terms: six words.
    uint256 private constant TERMS_SIZE = 6 * 32;
    /// @dev The most bytes of a getVersion answer hashed whole: a version string of up to 192 bytes. A longer answer is
    ///      hashed by its first VERSION_MAX bytes and its length, so every answer has a pin and a re-pin can follow it.
    uint256 private constant VERSION_MAX = 8 * 32;
    /// @dev EIP-712: the domain type, the gate's name and version, and the Link a contract approves to link.
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("HookrAgentGate");
    bytes32 private constant DOMAIN_VERSION_HASH = keccak256("2");
    bytes32 private constant LINK_TYPEHASH = keccak256("Link(address wallet,uint256 agentId,uint256 nonce)");
    /// @dev ABI size of laneOf's seven return words.
    uint256 private constant LANE_SIZE = 7 * 32;
    /// @dev The most bytes of a readFeedback answer the gate takes: five head words and its two tags. A longer
    ///      answer (a reviewer's long tags) is a failed read.
    uint256 private constant FEEDBACK_MAX = 512;
    /// @dev keccak256 of the empty string: a reviewer set with an empty tag takes entries under any tag.
    bytes32 private constant EMPTY_HASH = keccak256("");
    /// @dev Gas forwarded to each registry, launcher, PositionManager or root view probe.
    uint256 private constant VIEW_GAS = 30_000;
    /// @dev Gas forwarded to the root's laneOf, which also reads the registry.
    uint256 private constant LANE_GAS = 60_000;
    /// @dev Gas forwarded to each readFeedback: one entry, its tags included.
    uint256 private constant FEEDBACK_GAS = 30_000;
    /// @dev Gas the gate keeps to finish after the score: a reviewer read starts only with this and its stipends left,
    ///      so the score turns to "no score" before the gate itself could run out.
    uint256 private constant SCORE_RESERVE = 20_000;

    /// @notice A buyer's recipient must be an agent too.
    uint16 public constant CHECK_BENEFICIARY = 1;
    /// @notice Let the curated router's (Universal Router) swaps in: the root reads their payer through msgSender()
    ///         and cannot see their recipient.
    uint16 public constant ACCEPT_CURATED = 2;
    /// @notice Every defined flag bit.
    uint16 public constant ALL_FLAGS = 3;
    /// @notice Default flags: CHECK_BENEFICIARY.
    uint16 public constant DEFAULT_FLAGS = 1;
    /// @notice Smallest advisory gas limit a pool may bind with; the root forwards it to bind too.
    uint32 public constant MIN_ADVISORY_GAS = 400_000;
    /// @notice Largest advisory gas limit a pool may bind with: the registry's admission ceiling.
    uint32 public constant MAX_ADVISORY_GAS = 2_000_000;
    /// @notice Most clients in a reviewer set: one in this release. A plain average of several reviewers' values
    ///         lets any one of them decide the score alone (the registry takes values up to 1e38 on each reviewer's own
    ///         scale), so a set is one reviewer and its tag until a later gate counts a quorum instead.
    uint256 public constant MAX_REVIEWERS = 1;
    /// @notice Longest reviewer tag, in bytes.
    uint256 public constant MAX_TAG_LENGTH = 32;
    /// @notice The registry bounds valueDecimals to 18.
    uint256 public constant MAX_DECIMALS = 18;
    /// @notice The longest link-age floor a pool may set: 30 days. The clock starts at a wallet's first link on this
    ///         gate, so a longer floor would shut a new pool to every agent for longer than a launch can wait.
    uint32 public constant MAX_MIN_AGE = 30 days;
    /// @notice The wait between `queueRepin` and `repin`: the release registry's own timelock.
    uint48 public constant REPIN_DELAY = 30 minutes;
    /// @notice A ready re-pin expires after fourteen days, as the release registry's queue does.
    uint48 public constant REPIN_GRACE = 14 days;

    IERC8004Identity private immutable _identity;
    IERC8004Reputation private immutable _reputation;
    IPoolManager private immutable _manager;
    IPositionManagerView private immutable _positionManager;
    bytes32 private immutable _positionManagerCode;
    /// @inheritdoc IHookrAgentGate
    address public immutable owner;
    /// @dev STATE_SLOT, as a PUSH32 in the runtime rather than data after the code.
    bytes32 private immutable _stateSlot = STATE_SLOT;

    /// @param identity_ The ERC-8004 Identity Registry: contract code, not an EIP-7702 delegation.
    /// @param reputation_ The ERC-8004 Reputation Registry, which must read `identity_`.
    /// @param manager_ The PoolManager of every HookrRoot this gate serves.
    /// @param positionManager_ Uniswap's PositionManager on `manager_`.
    /// @param owner_ The owner that can suspend, resume and re-pin the gate.
    constructor(address identity_, address reputation_, address manager_, address positionManager_, address owner_) {
        if (!_isCode(identity_)) revert InvalidConstructor(1);
        if (!_isCode(reputation_)) revert InvalidConstructor(2);
        if (!_isCode(manager_)) revert InvalidConstructor(3);
        if (owner_ == address(0)) revert InvalidConstructor(4);
        if (!_isCode(positionManager_)) revert InvalidConstructor(5);
        (bool okIdentity, bytes32 identityVersion) = _versionHash(identity_);
        if (!okIdentity) revert InvalidConstructor(1);
        (bool okReputation, bytes32 reputationVersion) = _versionHash(reputation_);
        (bool okReads, uint256 reads) =
            _probe(reputation_, abi.encodeCall(IERC8004Reputation.getIdentityRegistry, ()), 32, VIEW_GAS);
        if (!okReputation || !okReads || reads != uint256(uint160(identity_))) revert InvalidConstructor(2);
        (bool okManager, uint256 managerOf) =
            _probe(positionManager_, abi.encodeCall(IPositionManagerView.poolManager, ()), 32, VIEW_GAS);
        if (!okManager || managerOf != uint256(uint160(manager_))) revert InvalidConstructor(5);
        _identity = IERC8004Identity(identity_);
        _reputation = IERC8004Reputation(reputation_);
        _manager = IPoolManager(manager_);
        _positionManager = IPositionManagerView(positionManager_);
        _positionManagerCode = positionManager_.codehash;
        owner = owner_;
        State storage s = _state();
        s.pins = Pins({
            identityCode: identity_.codehash,
            identityVersion: identityVersion,
            reputationCode: reputation_.codehash,
            reputationVersion: reputationVersion
        });
    }

    /// @inheritdoc IHookrAdvisory
    function configSchemaHash() external pure override(IHookrAdvisory, IHookrAgentGate) returns (bytes32) {
        return SCHEMA_HASH;
    }

    /// @inheritdoc IHookrAgentGate
    function identity() external view returns (address) {
        return address(_identity);
    }

    /// @inheritdoc IHookrAgentGate
    function reputation() external view returns (address) {
        return address(_reputation);
    }

    /// @inheritdoc IHookrAgentGate
    function poolManager() external view returns (address) {
        return address(_manager);
    }

    /// @inheritdoc IHookrAgentGate
    function positionManager() external view returns (address) {
        return address(_positionManager);
    }

    /// @inheritdoc IHookrAgentGate
    function suspended() external view returns (bool) {
        return _state().suspended;
    }

    /// @inheritdoc IHookrAgentGate
    function pins() external view returns (Pins memory) {
        return _state().pins;
    }

    /// @inheritdoc IHookrAgentGate
    function repinAt() external view returns (uint48) {
        return _state().repinAt;
    }

    /// @inheritdoc IHookrAgentGate
    function repinCommitment() external view returns (bytes32) {
        return _state().repinCommitment;
    }

    /// @inheritdoc IHookrAgentGate
    function terms(address binder, PoolId id) external view returns (Bound memory) {
        return _state().bound[binder][id];
    }

    /// @inheritdoc IHookrAgentGate
    function linkOf(address wallet) external view returns (bool linked, uint256 agentId) {
        uint256 plusOne = _state().links[wallet];
        return plusOne == 0 ? (false, 0) : (true, plusOne - 1);
    }

    /// @inheritdoc IHookrAgentGate
    function linkedAt(address wallet, uint256 agentId) external view returns (uint64) {
        return _state().linkedAt[wallet][agentId];
    }

    /// @inheritdoc IHookrAgentGate
    function linkNonce(address wallet) external view returns (uint256) {
        return _state().linkNonces[wallet];
    }

    /// @inheritdoc IHookrAgentGate
    function linkDigest(address wallet, uint256 agentId) external view returns (bytes32) {
        return _linkDigest(wallet, agentId, _state().linkNonces[wallet]);
    }

    /// @inheritdoc IHookrAgentGate
    function reviewerSet(bytes32 id) external view returns (address[] memory clients, string memory tag) {
        ReviewerSet storage r = _state().reviewers[id];
        return (r.clients, r.tag);
    }

    /// @inheritdoc IHookrAgentGate
    function isAgent(address wallet) external view returns (bool agent) {
        (agent,,) = _resolve(_state(), wallet, false);
    }

    /// @inheritdoc IHookrAgentGate
    function scoreOf(address wallet, bytes32 reviewers) external view returns (bool has, int256 wad) {
        State storage s = _state();
        if (s.reviewers[reviewers].clients.length == 0) return (false, 0);
        (bool agent, bool hasId, uint256 id) = _resolve(s, wallet, true);
        if (agent && hasId) return _score(s, reviewers, id);
    }

    /// @inheritdoc IHookrAgentGate
    function ageOf(address wallet) external view returns (uint256) {
        State storage s = _state();
        (bool agent, bool hasId, uint256 id) = _resolve(s, wallet, true);
        if (!agent || !hasId) return 0;
        return _age(s, wallet, id);
    }

    /// @inheritdoc IHookrAgentGate
    function link(uint256 agentId) external {
        _link(agentId, "");
    }

    /// @inheritdoc IHookrAgentGate
    function linkWithProof(uint256 agentId, bytes calldata proof) external {
        _link(agentId, proof);
    }

    /// @dev The caller must be the id's agent wallet or owner now. A caller with code must also approve the Link
    ///      digest for its next nonce through its own ERC-1271 `isValidSignature`: holding the id is not consent, since
    ///      a call-forwarder anyone can drive (Multicall3, an ERC-2771 forwarder) runs `link` as itself, and the proof
    ///      comes from the caller only, never from the id's other wallet, which a forwarder's driver can set. A contract
    ///      still in its constructor (no code yet and not the transaction's sender) is refused: once deployed it links
    ///      with a proof. Nothing is written, the age clock included, unless the link is admitted.
    function _link(uint256 agentId, bytes memory proof) private {
        (bool ok, uint256 wallet) =
            _probe(address(_identity), abi.encodeCall(IERC8004Identity.getAgentWallet, (agentId)), 32, VIEW_GAS);
        if (!ok || wallet != uint256(uint160(msg.sender))) {
            (ok, wallet) = _probe(address(_identity), abi.encodeCall(IERC8004Identity.ownerOf, (agentId)), 32, VIEW_GAS);
            if (!ok || wallet != uint256(uint160(msg.sender))) revert NotAgentWallet(agentId, msg.sender);
        }
        State storage s = _state();
        if (_isContract(msg.sender)) {
            uint256 nonce = s.linkNonces[msg.sender];
            if (!_approves(msg.sender, _linkDigest(msg.sender, agentId, nonce), proof)) {
                revert LinkNotProven(agentId, msg.sender);
            }
            s.linkNonces[msg.sender] = nonce + 1;
        } else if (msg.sender != tx.origin && msg.sender.code.length == 0) {
            revert LinkNotProven(agentId, msg.sender);
        }
        s.links[msg.sender] = agentId + 1;
        uint64 since = s.linkedAt[msg.sender][agentId];
        if (since == 0) {
            since = uint64(block.timestamp);
            s.linkedAt[msg.sender][agentId] = since;
        }
        emit AgentLinked(msg.sender, agentId, since);
    }

    /// @inheritdoc IHookrAgentGate
    function unlink() external {
        delete _state().links[msg.sender];
        emit AgentUnlinked(msg.sender);
    }

    /// @inheritdoc IHookrAgentGate
    function registerReviewers(address[] calldata clients, string calldata tag) external returns (bytes32 id) {
        if (clients.length == 0 || clients.length > MAX_REVIEWERS) revert InvalidReviewers(1);
        if (bytes(tag).length > MAX_TAG_LENGTH) revert InvalidReviewers(2);
        for (uint256 i; i < clients.length; ++i) {
            if (clients[i] == address(0)) revert InvalidReviewers(3);
        }
        id = keccak256(abi.encode(clients, tag));
        ReviewerSet storage r = _state().reviewers[id];
        if (r.clients.length != 0) return id;
        r.clients = clients;
        r.tag = tag;
        r.tagHash = keccak256(bytes(tag));
        emit ReviewersRegistered(id, clients, tag);
    }

    /// @inheritdoc IHookrAgentGate
    function suspend() external {
        if (msg.sender != owner) revert Unauthorized();
        State storage s = _state();
        if (s.suspended) revert AlreadySuspended();
        s.suspended = true;
        emit Suspended();
    }

    /// @inheritdoc IHookrAgentGate
    function resume() external {
        if (msg.sender != owner) revert Unauthorized();
        State storage s = _state();
        if (!s.suspended) revert NotSuspended();
        s.suspended = false;
        emit Resumed();
    }

    /// @inheritdoc IHookrAgentGate
    function queueRepin(Pins calldata expected) external {
        if (msg.sender != owner) revert Unauthorized();
        uint48 at = uint48(block.timestamp) + REPIN_DELAY;
        State storage s = _state();
        s.repinAt = at;
        s.repinCommitment = keccak256(abi.encode(expected));
        emit RepinQueued(at, s.repinCommitment);
    }

    /// @inheritdoc IHookrAgentGate
    /// @dev Re-reads what the constructor read. Both registries must still be code and answer a version; the
    ///      reputation registry must still read the identity registry. All four pins must match the commitment;
    ///      the queue is consumed only after a match inside its execution window.
    function repin() external {
        if (msg.sender != owner) revert Unauthorized();
        State storage s = _state();
        uint48 at = s.repinAt;
        if (at == 0 || block.timestamp < at) revert RepinNotReady();
        if (block.timestamp > uint256(at) + REPIN_GRACE) revert RepinExpired();
        address identity_ = address(_identity);
        address reputation_ = address(_reputation);
        if (!_isCode(identity_)) revert InvalidConstructor(1);
        if (!_isCode(reputation_)) revert InvalidConstructor(2);
        (bool okIdentity, bytes32 identityVersion) = _versionHash(identity_);
        if (!okIdentity) revert InvalidConstructor(1);
        (bool okReputation, bytes32 reputationVersion) = _versionHash(reputation_);
        (bool okReads, uint256 reads) =
            _probe(reputation_, abi.encodeCall(IERC8004Reputation.getIdentityRegistry, ()), 32, VIEW_GAS);
        if (!okReputation || !okReads || reads != uint256(uint160(identity_))) revert InvalidConstructor(2);
        Pins memory next = Pins({
            identityCode: identity_.codehash,
            identityVersion: identityVersion,
            reputationCode: reputation_.codehash,
            reputationVersion: reputationVersion
        });
        if (keccak256(abi.encode(next)) != s.repinCommitment) revert RepinMismatch();
        s.pins = next;
        s.repinAt = 0;
        s.repinCommitment = bytes32(0);
        emit Repinned(s.pins);
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev The binder must be a root on whose registry this contract is admitted as an ADVISORY, on this gate's
    ///      PoolManager, binding its own pool fail-closed before the swap with the admitted gas. The tier's surcharge
    ///      must fit the admission's LP cap, and a score threshold needs a registered reviewer set. The family owner
    ///      the launcher reports must be an agent: it is who the launch's liquidity and dev buy are screened as.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32 configHash)
    {
        Terms memory t = _decode(data);
        PoolId id = key.toId();
        State storage s = _state();
        Bound storage entry = s.bound[msg.sender][id];
        if (entry.bound) revert AlreadyBound(msg.sender, id);
        if (address(key.hooks) != msg.sender || pc.advisory != address(this)) revert InvalidPoolConfig(1);
        if (pc.advisoryPhases != HookrTypes.BEFORE_SWAP) revert InvalidPoolConfig(2);
        if (pc.advisoryGasLimit < MIN_ADVISORY_GAS || pc.advisoryGasLimit > MAX_ADVISORY_GAS) {
            revert InvalidPoolConfig(3);
        }
        if (pc.advisoryFailOpen) revert InvalidPoolConfig(4);
        if (address(IHookrRoot(msg.sender).poolManager()) != address(_manager)) revert InvalidPoolConfig(5);
        IHookrRegistry.Admission memory own = IHookrRoot(msg.sender).registry().admission(msg.sender, address(this));
        if (own.kind != IHookrRegistry.Kind.ADVISORY || own.implementation != address(this)) {
            revert InvalidPoolConfig(6);
        }
        _checkTerms(s, t, own.caps.maxLpFeePips);
        address launcher = pc.liquidityOwner;
        if (launcher == address(0)) revert InvalidPoolConfig(7);
        (bool okFamily, uint256 family) =
            _probe(launcher, abi.encodeCall(IHookrLauncherView.poolFamily, (id)), 32, VIEW_GAS);
        if (!okFamily || family == 0) revert InvalidPoolConfig(8);
        (bool okOwner, uint256 familyOwner) =
            _probe(launcher, abi.encodeCall(IHookrLauncherView.familyOwner, (bytes32(family))), 32, VIEW_GAS);
        if (!okOwner || familyOwner == 0 || familyOwner > type(uint160).max) revert InvalidPoolConfig(8);
        (bool okCurated, uint256 curated) =
            _probe(msg.sender, abi.encodeCall(IHookrRoot.curatedRouter, ()), 32, VIEW_GAS);
        if (!okCurated || curated > type(uint160).max) revert InvalidPoolConfig(9);
        if (_degraded(s, t.reviewers != bytes32(0))) revert InvalidPoolConfig(10);
        address creator = address(uint160(familyOwner));
        // A constructing contract has no code and cannot prove its link. Codeless creators must be the origin;
        // smart-account creators have code and use their ERC-1271-approved link.
        if (creator.code.length == 0 && creator != tx.origin) revert InvalidPoolConfig(11);
        (bool creatorIsAgent,,) = _resolve(s, creator, false);
        if (!creatorIsAgent) revert InvalidPoolConfig(11);
        entry.bound = true;
        entry.flags = t.flags;
        entry.minScore = t.minScore;
        entry.tierScore = t.tierScore;
        entry.tierPips = t.tierPips;
        entry.minAge = t.minAge;
        entry.launcher = launcher;
        entry.curatedRouter = address(uint160(curated));
        entry.reviewers = t.reviewers;
        emit GateBound(msg.sender, id, t, launcher);
        return keccak256(data);
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev A refused swap gets reject and no charge; an admitted one the fee tier's surcharge, if any.
    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory advice) {
        (bool allowed,, uint24 surcharge) = _swap(_state(), msg.sender, x);
        if (!allowed) advice.reject = true;
        else advice.lpFeeSurchargePips = surcharge;
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
        (allowed,) = _liquidity(_state(), msg.sender, id, sender);
    }

    /// @inheritdoc IHookrAgentGate
    function explainSwap(address binder, HookrTypes.SwapContext calldata x)
        external
        view
        returns (bool, Reason, uint24)
    {
        return _swap(_state(), binder, x);
    }

    /// @inheritdoc IHookrAgentGate
    function explainLiquidity(address binder, PoolId id, address sender) external view returns (bool, Reason) {
        return _liquidity(_state(), binder, id, sender);
    }

    /// @dev The swap decision. Unauthenticated swaps: the launch dev buy is screened as the family owner (as
    ///      HookrCredentialGate screens it); the pool's frozen lane executor's legs pass on the root's word alone while
    ///      its lane is on, with no surcharge (the executor holds no identity, and its legs keep the agent pool on the
    ///      open pool's price) and whatever the registries or the suspension say, since they read neither; anything
    ///      else is refused. In the degraded state (a registry moved, or suspended) entries are refused and sells pass
    ///      without a registry read, at the tier's surcharge since no score can be read.
    function _swap(State storage s, address binder, HookrTypes.SwapContext calldata x)
        private
        view
        returns (bool, Reason, uint24)
    {
        Bound storage b = s.bound[binder][x.id];
        if (!b.bound) return (false, Reason.NOT_BOUND, 0);
        address payer = x.payer;
        if (!x.authenticated) {
            address launcher = b.launcher;
            if (x.sender == launcher && x.isBuy && x.exactInput) {
                (bool ok, uint256 pool) =
                    _probe(launcher, abi.encodeCall(IHookrLauncherView.launchBuyPool, ()), 32, VIEW_GAS);
                if (!ok || bytes32(pool) != PoolId.unwrap(x.id)) return (false, Reason.UNAUTHENTICATED, 0);
                payer = _familyOwner(launcher, x.id);
                if (payer == address(0)) return (false, Reason.LAUNCH_BUY, 0);
            } else if (_isExecutor(binder, x.id, x.sender)) {
                return (true, Reason.NONE, 0);
            } else {
                return (false, Reason.UNAUTHENTICATED, 0);
            }
        } else if (x.sender == b.curatedRouter && b.flags & ACCEPT_CURATED == 0) {
            return (false, Reason.CURATED_NOT_ACCEPTED, 0);
        }
        bool scored = b.reviewers != bytes32(0);
        if (_degraded(s, scored)) {
            if (x.isBuy) return (false, Reason.DEGRADED, 0);
            return (true, Reason.NONE, b.tierPips);
        }
        // The score matters to a buy on a pool with a threshold, and to any swap on a pool with a tier; the age to a
        // buy on a pool with a floor; nowhere else.
        bool aged = x.isBuy && b.minAge != 0;
        bool needScore = (x.isBuy && b.minScore != 0) || b.tierPips != 0;
        (bool agent, bool hasId, uint256 agentId) = _resolve(s, payer, needScore || aged);
        if (!agent) return (false, Reason.PAYER, 0);
        if (x.isBuy && x.authenticated && b.flags & CHECK_BENEFICIARY != 0 && x.beneficiary != payer) {
            (bool recipient,,) = _resolve(s, x.beneficiary, false);
            if (!recipient) return (false, Reason.BENEFICIARY, 0);
        }
        if (aged && !(hasId && _age(s, payer, agentId) >= b.minAge)) return (false, Reason.AGE, 0);
        if (!needScore) return (true, Reason.NONE, 0);
        (bool has, int256 wad) = hasId ? _score(s, b.reviewers, agentId) : (false, int256(0));
        if (x.isBuy && b.minScore != 0 && !(has && _atLeast(wad, b.minScore))) return (false, Reason.SCORE, 0);
        uint24 surcharge = b.tierPips != 0 && !(has && _atLeast(wad, b.tierScore)) ? b.tierPips : 0;
        return (true, Reason.NONE, surcharge);
    }

    /// @dev Adds: an agent, and above the pool's score threshold and age floor where set. The pool's launcher (its
    ///      liquidity owner, which holds the creator's launch position) adds for its family owner, who is screened in
    ///      its place for the identity only: a creator's own liquidity, the launch's included, needs an agent creator,
    ///      and the threshold and floor it chose bind every other LP and every buyer, its own dev buy included.
    ///      Uniswap's PositionManager adds for the wallet it names through msgSender(), screened in its place like any
    ///      LP; an add it does not name a wallet for is refused. Removals are never asked.
    function _liquidity(State storage s, address binder, PoolId id, address sender)
        private
        view
        returns (bool, Reason)
    {
        Bound storage b = s.bound[binder][id];
        if (!b.bound) return (false, Reason.NOT_BOUND);
        address actor = sender;
        Reason refusal = Reason.LP_SENDER;
        bool launch = sender == b.launcher;
        if (launch) {
            actor = _familyOwner(sender, id);
            refusal = Reason.LP_OWNER;
            if (actor == address(0)) return (false, Reason.LP_OWNER);
        } else if (sender == address(_positionManager)) {
            if (sender.codehash != _positionManagerCode) return (false, Reason.LP_MANAGER);
            (bool ok, uint256 word) =
                _probe(sender, abi.encodeCall(IPositionManagerView.msgSender, ()), 32, VIEW_GAS);
            if (!ok || word == 0 || word > type(uint160).max) return (false, Reason.LP_MANAGER);
            actor = address(uint160(word));
            if (actor == b.curatedRouter || actor == sender) return (false, Reason.LP_MANAGER);
        }
        if (_degraded(s, b.reviewers != bytes32(0))) return (false, Reason.DEGRADED);
        bool scored = b.minScore != 0 && !launch;
        bool aged = b.minAge != 0 && !launch;
        (bool agent, bool hasId, uint256 agentId) = _resolve(s, actor, scored || aged);
        if (!agent) return (false, refusal);
        if (aged && !(hasId && _age(s, actor, agentId) >= b.minAge)) return (false, Reason.AGE);
        if (scored) {
            (bool has, int256 wad) = hasId ? _score(s, b.reviewers, agentId) : (false, int256(0));
            if (!(has && _atLeast(wad, b.minScore))) return (false, Reason.SCORE);
        }
        return (true, Reason.NONE);
    }

    /// @dev Whether `wallet` passes the identity check, and the agent id whose score and age it trades with: the id it
    ///      linked while the registry names `wallet` that id's agent wallet or, with `needId`, its owner; none
    ///      otherwise, so a link to an id the wallet sold or was rotated off reads as no score and no age. A wallet
    ///      without code (or an EIP-7702 delegated one) holding any identity still passes the identity check by its
    ///      balance, including during construction. Ordinary runtime code needs a link; codeless constructor relays
    ///      and Nitro origin aliases remain identity-sharing boundaries of the balance-only path.
    function _resolve(State storage s, address wallet, bool needId)
        private
        view
        returns (bool agent, bool hasId, uint256 agentId)
    {
        uint256 plusOne = s.links[wallet];
        uint256 word;
        bool ok;
        if (plusOne != 0) {
            agentId = plusOne - 1;
            (ok, word) =
                _probe(address(_identity), abi.encodeCall(IERC8004Identity.getAgentWallet, (agentId)), 32, VIEW_GAS);
            if (ok && word == uint256(uint160(wallet))) return (true, true, agentId);
        }
        bool contractWallet = _isContract(wallet);
        if (!contractWallet) {
            (ok, word) = _probe(address(_identity), abi.encodeCall(IERC8004Identity.balanceOf, (wallet)), 32, VIEW_GAS);
            if (!ok || word == 0) return (false, false, 0);
            if (plusOne == 0 || !needId) return (true, false, 0);
        } else if (plusOne == 0) {
            return (false, false, 0);
        }
        // A linked wallet that is not the id's agent wallet: it passes with the id when it owns the id. For a wallet
        // without code that is a question only where the id matters; for a contract it is the only way in.
        (ok, word) = _probe(address(_identity), abi.encodeCall(IERC8004Identity.ownerOf, (agentId)), 32, VIEW_GAS);
        if (ok && word == uint256(uint160(wallet))) return (true, true, agentId);
        return contractWallet ? (false, false, 0) : (true, false, 0);
    }

    /// @dev Seconds since `wallet` first linked `agentId` here; zero when it never did.
    function _age(State storage s, address wallet, uint256 agentId) private view returns (uint256) {
        uint64 since = s.linkedAt[wallet][agentId];
        if (since == 0 || since > block.timestamp) return 0;
        return block.timestamp - since;
    }

    /// @dev The agent's score from the reviewer set: the mean, in 18 decimals, of the listed reviewers' latest entries
    ///      for the agent that are live and carry the set's tag (an empty tag takes any). A set holds one reviewer in
    ///      this release (MAX_REVIEWERS), so the score is that reviewer's latest live entry. An entry that is revoked
    ///      or carries another tag gives none: the latest entry is the reviewer's current word, which a reviewer
    ///      re-scoring by revoke-then-post keeps, and the read costs the same however long its history grows. "No
    ///      score" when no entry counts, and when any read fails (a revert, an answer out of shape, or too little gas
    ///      left to read it).
    function _score(State storage s, bytes32 setId, uint256 agentId) private view returns (bool, int256) {
        ReviewerSet storage r = s.reviewers[setId];
        uint256 n = r.clients.length;
        bytes32 tagHash = r.tagHash;
        int256 sum;
        uint256 count;
        for (uint256 i; i < n; ++i) {
            if (gasleft() < SCORE_RESERVE + VIEW_GAS + FEEDBACK_GAS) return (false, 0);
            address client = r.clients[i];
            (bool ok, uint256 last) = _probe(
                address(_reputation), abi.encodeCall(IERC8004Reputation.getLastIndex, (agentId, client)), 32, VIEW_GAS
            );
            if (!ok || last > type(uint64).max) return (false, 0);
            if (last == 0) continue;
            (bool read, bool counts, int256 wad) = _latest(agentId, client, uint64(last), tagHash);
            if (!read) return (false, 0);
            if (!counts) continue;
            sum += wad;
            ++count;
        }
        if (count == 0) return (false, 0);
        return (true, sum / int256(count));
    }

    /// @dev One reviewer's entry `index` for the agent, read with FEEDBACK_GAS and at most FEEDBACK_MAX bytes back:
    ///      `read` false for a failed call or an answer out of shape (a value outside int128, decimals above 18, a
    ///      revoked flag that is not a bool, a tag that does not fit); `counts` whether it is live and carries the tag
    ///      `tagHash` (any, for the empty tag's); `wad` its value in 18 decimals.
    function _latest(uint256 agentId, address client, uint64 index, bytes32 tagHash)
        private
        view
        returns (bool read, bool counts, int256 wad)
    {
        bytes memory input = abi.encodeCall(IERC8004Reputation.readFeedback, (agentId, client, index));
        bytes memory out = new bytes(FEEDBACK_MAX);
        address target = address(_reputation);
        uint256 size;
        uint256 value;
        uint256 decimals;
        uint256 offset;
        uint256 revoked;
        assembly ("memory-safe") {
            read := staticcall(FEEDBACK_GAS, target, add(input, 32), mload(input), add(out, 32), FEEDBACK_MAX)
            size := returndatasize()
            let p := add(out, 32)
            value := mload(p)
            decimals := mload(add(p, 32))
            offset := mload(add(p, 64))
            revoked := mload(add(p, 128))
        }
        // Five head words and two string lengths at least, all inside what the buffer took.
        if (!read || size < 7 * 32 || size > FEEDBACK_MAX) return (false, false, 0);
        int256 signed = int256(value);
        if (signed != int256(int128(signed)) || decimals > MAX_DECIMALS || revoked > 1) return (false, false, 0);
        // The first tag: a length word inside the answer, then its bytes.
        if (offset < 5 * 32 || offset > size - 32) return (false, false, 0);
        uint256 length;
        bytes32 tag;
        assembly ("memory-safe") {
            length := mload(add(add(out, 32), offset))
        }
        if (length > size - offset - 32) return (false, false, 0);
        assembly ("memory-safe") {
            tag := keccak256(add(add(out, 64), offset), length)
        }
        if (revoked == 1 || (tagHash != EMPTY_HASH && tag != tagHash)) return (true, false, 0);
        return (true, true, signed * int256(10 ** (MAX_DECIMALS - decimals)));
    }

    /// @dev Whether a score `wad` (18 decimals) is at least `threshold` whole units.
    function _atLeast(int256 wad, uint32 threshold) private pure returns (bool) {
        return wad >= int256(uint256(threshold)) * 1e18;
    }

    /// @dev The degraded state: suspended, or the identity proxy's code or version moved off the pins, or (where a
    ///      score is read) the reputation proxy's.
    function _degraded(State storage s, bool score) private view returns (bool) {
        if (s.suspended) return true;
        Pins storage p = s.pins;
        if (!_pinned(address(_identity), p.identityCode, p.identityVersion)) return true;
        return score && !_pinned(address(_reputation), p.reputationCode, p.reputationVersion);
    }

    /// @dev Whether `target` still runs the pinned code and answers the pinned version bytes.
    function _pinned(address target, bytes32 code, bytes32 version) private view returns (bool) {
        if (target.codehash != code) return false;
        (bool ok, bytes32 h) = _versionHash(target);
        return ok && h == version;
    }

    /// @dev The Link digest: EIP-712 typed data `Link(address wallet,uint256 agentId,uint256 nonce)` in this gate's
    ///      domain on this chain.
    function _linkDigest(address wallet, uint256 agentId, uint256 nonce) private view returns (bytes32) {
        bytes32 domain =
            keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, DOMAIN_VERSION_HASH, block.chainid, address(this)));
        bytes32 link_ = keccak256(abi.encode(LINK_TYPEHASH, wallet, agentId, nonce));
        return keccak256(abi.encodePacked("\x19\x01", domain, link_));
    }

    /// @dev Whether `wallet` approves `digest` with `proof` through ERC-1271: a static call that must answer exactly
    ///      the magic word. A revert, a wallet with no code or any other answer is no.
    function _approves(address wallet, bytes32 digest, bytes memory proof) private view returns (bool) {
        bytes memory input = abi.encodeCall(IERC1271.isValidSignature, (digest, proof));
        (bool ok, uint256 word) = _probe(wallet, input, 32, gasleft());
        return ok && bytes32(word) == bytes32(IERC1271.isValidSignature.selector);
    }

    /// @dev Everything about the terms that needs no pool.
    function _checkTerms(State storage s, Terms memory t, uint24 capPips) private view {
        if (t.flags & ~ALL_FLAGS != 0) revert InvalidTerms(1);
        if ((t.tierScore == 0) != (t.tierPips == 0)) revert InvalidTerms(2);
        if (t.tierPips > capPips) revert InvalidTerms(3);
        bool scored = t.minScore != 0 || t.tierScore != 0;
        if (scored != (t.reviewers != bytes32(0))) revert InvalidTerms(4);
        if (scored && s.reviewers[t.reviewers].clients.length == 0) revert InvalidTerms(5);
        if (t.minAge > MAX_MIN_AGE) revert InvalidTerms(7);
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
        // laneOf's words: executor, codeHash, partnerBps, family, on, gasCap, gasFloor. `on` is the registry's switch
        // for this executor on the root: the lane's brake (stopExecutorLane) turns it off.
        (uint256 executor, bytes32 codeHash,,, uint256 on) = abi.decode(output, (uint256, bytes32, uint256, uint256, uint256));
        return executor != 0 && on == 1 && executor == uint256(uint160(sender)) && sender.codehash == codeHash;
    }

    /// @dev Current family owner of a pool, or zero when either launcher view fails.
    function _familyOwner(address launcher, PoolId id) private view returns (address) {
        (bool ok, uint256 family) = _probe(launcher, abi.encodeCall(IHookrLauncherView.poolFamily, (id)), 32, VIEW_GAS);
        if (!ok || family == 0) return address(0);
        uint256 familyOwner;
        (ok, familyOwner) =
            _probe(launcher, abi.encodeCall(IHookrLauncherView.familyOwner, (bytes32(family))), 32, VIEW_GAS);
        if (!ok || familyOwner > type(uint160).max) return address(0);
        return address(uint160(familyOwner));
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

    /// @dev `getVersion()` on `target`, bounded: `ok` whether the call returned, `h` the keccak256 of the answer's
    ///      bytes, or past VERSION_MAX bytes of its first VERSION_MAX bytes and its length. Every answer that returns
    ///      has a hash, so a longer version after an upgrade is a version change the owner can re-pin, not a dead end.
    function _versionHash(address target) private view returns (bool ok, bytes32 h) {
        bytes memory input = abi.encodeCall(IERC8004Identity.getVersion, ());
        bytes memory output = new bytes(VERSION_MAX + 32);
        assembly ("memory-safe") {
            let out := add(output, 32)
            ok := staticcall(VIEW_GAS, target, add(input, 32), mload(input), out, VERSION_MAX)
            let size := returndatasize()
            switch gt(size, VERSION_MAX)
            case 0 { h := keccak256(out, size) }
            default {
                mstore(add(out, VERSION_MAX), size)
                h := keccak256(out, add(VERSION_MAX, 32))
            }
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
                extcodecopy(a, free, 0, 3)
                delegated := and(eq(size, 23), eq(shr(232, mload(free)), 0xef0100))
            }
        }
        return size != 0 && !delegated;
    }

    /// @dev Code that is not an exact EIP-7702 delegation designator. A constructor has no code and still follows
    ///      the balance-only trade/add path; a public CREATE2 constructor relay can share that identity-only access.
    ///      Bind rejects a codeless non-origin creator. Nitro-origin aliases can be codeless origins and are not
    ///      distinguished from wallets here; their holder can deliberately share identity, score and age access.
    function _isContract(address a) private view returns (bool) {
        return _isCode(a);
    }

    /// @dev Strict decode: exactly the Terms words, each in range, re-encoding to the same bytes (InvalidTerms(6)).
    function _decode(bytes calldata data) private pure returns (Terms memory t) {
        if (data.length != TERMS_SIZE) revert InvalidTerms(6);
        t = abi.decode(data, (Terms));
        if (keccak256(data) != keccak256(abi.encode(t))) revert InvalidTerms(6);
    }

    function _state() private view returns (State storage s) {
        bytes32 slot = _stateSlot;
        assembly ("memory-safe") {
            s.slot := slot
        }
    }
}
