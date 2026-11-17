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

/// @title Hookr agent gate
/// @notice Fail-closed BEFORE_SWAP and liquidity advisory that makes a pool agents-only: a buy, a sell or a liquidity
///         add is admitted only for a wallet that holds an ERC-8004 agent identity, or is the registered agent wallet
///         of an identity it linked here. Removals are never gated. The pool's frozen arb recapture executor's legs
///         pass on the root's word alone while its lane is on. Optional, frozen per pool: an admission threshold on the
///         agent's reputation score from a chosen reviewer, and a fee tier that charges agents below a threshold
///         an LP-fee surcharge. The ERC-8004 registries are upgradeable proxies: the gate pins their runtime code and version
///         at construction and refuses entries when either moves, and its owner can retire it for good.
/// @dev Stateless on the swap path: every read is a static call. After bind nothing about a pool changes; the only
///      writes are a wallet's own link, a reviewer set (content-addressed, immutable) and the owner's retire.
///      Storage is keyed by the binder, so a third-party bind writes only its own namespace.
contract HookrAgentGate is HookrReleased, IHookrAgentGate, IHookrAdvisory {
    using PoolIdLibrary for PoolKey;

    /// @custom:storage-location erc7201:hookr.agent.gate.state
    struct State {
        mapping(address binder => mapping(PoolId => Bound)) bound;
        /// @dev The agent id a wallet linked, plus one: zero is no link, so identity 0 can link too.
        mapping(address wallet => uint256 linkedPlusOne) links;
        mapping(bytes32 id => ReviewerSet) reviewers;
        bool retired;
    }

    struct ReviewerSet {
        address[] clients;
        string tag;
        bytes32 tagHash;
    }

    /// @dev cast index-erc7201 hookr.agent.gate.state. Read through the immutable `_stateSlot`: as a constant the
    ///      compiler stores it as data after the code and leaves the metadata tail after data rather than after
    ///      INVALID, which the conformance kit's opcode scan then reads (HookrCredentialGate found this).
    bytes32 private constant STATE_SLOT = 0x92ea18a9efcfaf477141ec6ac196ef9ba388e50402bc2f4b84d76cad9961f600;
    /// @dev keccak256 of the Terms type string (see configSchemaHash).
    bytes32 private constant SCHEMA_HASH = 0x167ba3b15d65044b17c87154087d35fc5efde07538be66b804a54e63d6089136;
    /// @dev ABI size of Terms: five words.
    uint256 private constant TERMS_SIZE = 5 * 32;
    /// @dev ABI size of a version string of at most 32 bytes: its offset, its length and one data word.
    uint256 private constant VERSION_SIZE = 3 * 32;
    /// @dev ABI size of laneOf's seven return words.
    uint256 private constant LANE_SIZE = 7 * 32;
    /// @dev The most bytes of a readFeedback answer the gate takes: five head words and its two tags. A longer
    ///      answer (a reviewer's long tags) is a failed read.
    uint256 private constant FEEDBACK_MAX = 512;
    /// @dev keccak256 of the empty string: a reviewer set with an empty tag takes entries under any tag.
    bytes32 private constant EMPTY_HASH = keccak256("");
    /// @dev Gas forwarded to each registry, launcher or root view probe.
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

    IERC8004Identity private immutable _identity;
    IERC8004Reputation private immutable _reputation;
    IPoolManager private immutable _manager;
    /// @inheritdoc IHookrAgentGate
    address public immutable owner;
    bytes32 private immutable _identityCode;
    bytes32 private immutable _identityVersion;
    bytes32 private immutable _reputationCode;
    bytes32 private immutable _reputationVersion;
    /// @dev STATE_SLOT, as a PUSH32 in the runtime rather than data after the code.
    bytes32 private immutable _stateSlot = STATE_SLOT;

    /// @param identity_ The ERC-8004 Identity Registry: contract code, not an EIP-7702 delegation.
    /// @param reputation_ The ERC-8004 Reputation Registry, which must read `identity_`.
    /// @param manager_ The PoolManager of every HookrRoot this gate serves.
    /// @param owner_ The owner that can retire the gate.
    constructor(address identity_, address reputation_, address manager_, address owner_) {
        if (!_isCode(identity_)) revert InvalidConstructor(1);
        if (!_isCode(reputation_)) revert InvalidConstructor(2);
        if (!_isCode(manager_)) revert InvalidConstructor(3);
        if (owner_ == address(0)) revert InvalidConstructor(4);
        bytes memory version = abi.encodeCall(IERC8004Identity.getVersion, ());
        (bool okIdentity, bytes32 identityVersion) = _probeHash(identity_, version, VERSION_SIZE, VIEW_GAS);
        if (!okIdentity) revert InvalidConstructor(1);
        (bool okReputation, bytes32 reputationVersion) = _probeHash(reputation_, version, VERSION_SIZE, VIEW_GAS);
        (bool okReads, uint256 reads) =
            _probe(reputation_, abi.encodeCall(IERC8004Reputation.getIdentityRegistry, ()), 32, VIEW_GAS);
        if (!okReputation || !okReads || reads != uint256(uint160(identity_))) revert InvalidConstructor(2);
        _identity = IERC8004Identity(identity_);
        _reputation = IERC8004Reputation(reputation_);
        _manager = IPoolManager(manager_);
        owner = owner_;
        _identityCode = identity_.codehash;
        _identityVersion = identityVersion;
        _reputationCode = reputation_.codehash;
        _reputationVersion = reputationVersion;
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
    function retired() external view returns (bool) {
        return _state().retired;
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
    function link(uint256 agentId) external {
        (bool ok, uint256 wallet) =
            _probe(address(_identity), abi.encodeCall(IERC8004Identity.getAgentWallet, (agentId)), 32, VIEW_GAS);
        if (!ok || wallet != uint256(uint160(msg.sender))) {
            (ok, wallet) = _probe(address(_identity), abi.encodeCall(IERC8004Identity.ownerOf, (agentId)), 32, VIEW_GAS);
            if (!ok || wallet != uint256(uint160(msg.sender))) revert NotAgentWallet(agentId, msg.sender);
        }
        _state().links[msg.sender] = agentId + 1;
        emit AgentLinked(msg.sender, agentId);
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
    function retire() external {
        if (msg.sender != owner) revert Unauthorized();
        State storage s = _state();
        if (s.retired) revert AlreadyRetired();
        s.retired = true;
        emit Retired();
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev The binder must be a root on whose registry this contract is admitted as an ADVISORY, on this gate's
    ///      PoolManager, binding its own pool fail-closed before the swap with the admitted gas. The tier's surcharge
    ///      must fit the admission's LP cap, and a score threshold needs a registered reviewer set.
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
        entry.bound = true;
        entry.flags = t.flags;
        entry.minScore = t.minScore;
        entry.tierScore = t.tierScore;
        entry.tierPips = t.tierPips;
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
    ///      open pool's price) and whatever the registries or the retire say, since they read neither; anything else is
    ///      refused. In the degraded state (a registry moved, or retired) entries are refused and sells pass without a
    ///      registry read, at the tier's surcharge since no score can be read.
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
        // The score matters to a buy on a pool with a threshold, and to any swap on a pool with a tier; nowhere else.
        bool needScore = (x.isBuy && b.minScore != 0) || b.tierPips != 0;
        (bool agent, bool hasId, uint256 agentId) = _resolve(s, payer, needScore);
        if (!agent) return (false, Reason.PAYER, 0);
        if (x.isBuy && x.authenticated && b.flags & CHECK_BENEFICIARY != 0 && x.beneficiary != payer) {
            (bool recipient,,) = _resolve(s, x.beneficiary, false);
            if (!recipient) return (false, Reason.BENEFICIARY, 0);
        }
        if (!needScore) return (true, Reason.NONE, 0);
        (bool has, int256 wad) = hasId ? _score(s, b.reviewers, agentId) : (false, int256(0));
        if (x.isBuy && b.minScore != 0 && !(has && _atLeast(wad, b.minScore))) return (false, Reason.SCORE, 0);
        uint24 surcharge = b.tierPips != 0 && !(has && _atLeast(wad, b.tierScore)) ? b.tierPips : 0;
        return (true, Reason.NONE, surcharge);
    }

    /// @dev Adds: an agent, and above the pool's score threshold where one is set. The pool's launcher (its liquidity
    ///      owner, which holds the creator's launch position) adds for its family owner, who is screened in its place
    ///      for the identity only: a creator's own liquidity, the launch's included, needs an agent creator, and the
    ///      threshold it chose binds every other LP and every buyer, its own dev buy included. Removals are never asked.
    function _liquidity(State storage s, address binder, PoolId id, address sender)
        private
        view
        returns (bool, Reason)
    {
        Bound storage b = s.bound[binder][id];
        if (!b.bound) return (false, Reason.NOT_BOUND);
        address actor = sender;
        Reason refusal = Reason.LP_SENDER;
        if (sender == b.launcher) {
            actor = _familyOwner(sender, id);
            refusal = Reason.LP_OWNER;
            if (actor == address(0)) return (false, Reason.LP_OWNER);
        }
        if (_degraded(s, b.reviewers != bytes32(0))) return (false, Reason.DEGRADED);
        bool scored = b.minScore != 0 && sender != b.launcher;
        (bool agent, bool hasId, uint256 agentId) = _resolve(s, actor, scored);
        if (!agent) return (false, refusal);
        if (scored) {
            (bool has, int256 wad) = hasId ? _score(s, b.reviewers, agentId) : (false, int256(0));
            if (!(has && _atLeast(wad, b.minScore))) return (false, Reason.SCORE);
        }
        return (true, Reason.NONE);
    }

    /// @dev Whether `wallet` passes the identity check, and the agent id whose score it trades with: the id it linked
    ///      while the registry names `wallet` that id's agent wallet or, with `needId`, its owner; none otherwise, so a
    ///      link to an id the wallet sold or was rotated off reads as no score (a wallet holding any identity still
    ///      passes the identity check by its balance).
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
        (ok, word) = _probe(address(_identity), abi.encodeCall(IERC8004Identity.balanceOf, (wallet)), 32, VIEW_GAS);
        if (!ok || word == 0) return (false, false, 0);
        if (plusOne != 0 && needId) {
            (ok, word) =
                _probe(address(_identity), abi.encodeCall(IERC8004Identity.ownerOf, (agentId)), 32, VIEW_GAS);
            if (ok && word == uint256(uint160(wallet))) return (true, true, agentId);
        }
        return (true, false, 0);
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

    /// @dev The degraded state: retired, or the identity proxy's code or version moved, or (where a score is read)
    ///      the reputation proxy's.
    function _degraded(State storage s, bool score) private view returns (bool) {
        if (s.retired) return true;
        if (!_pinned(address(_identity), _identityCode, _identityVersion)) return true;
        return score && !_pinned(address(_reputation), _reputationCode, _reputationVersion);
    }

    /// @dev Whether `target` still runs the pinned code and answers the pinned version bytes.
    function _pinned(address target, bytes32 code, bytes32 version) private view returns (bool) {
        if (target.codehash != code) return false;
        (bool ok, bytes32 h) =
            _probeHash(target, abi.encodeCall(IERC8004Identity.getVersion, ()), VERSION_SIZE, VIEW_GAS);
        return ok && h == version;
    }

    /// @dev Everything about the terms that needs no pool.
    function _checkTerms(State storage s, Terms memory t, uint24 capPips) private view {
        if (t.flags & ~ALL_FLAGS != 0) revert InvalidTerms(1);
        if ((t.tierScore == 0) != (t.tierPips == 0)) revert InvalidTerms(2);
        if (t.tierPips > capPips) revert InvalidTerms(3);
        bool scored = t.minScore != 0 || t.tierScore != 0;
        if (scored != (t.reviewers != bytes32(0))) revert InvalidTerms(4);
        if (scored && s.reviewers[t.reviewers].clients.length == 0) revert InvalidTerms(5);
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

    /// @dev Bounded static call that must return exactly `size` bytes; returns their keccak256.
    function _probeHash(address target, bytes memory input, uint256 size, uint256 gasLimit)
        private
        view
        returns (bool ok, bytes32 h)
    {
        bytes memory output = new bytes(size);
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(input, 32), mload(input), add(output, 32), size)
            ok := and(ok, eq(returndatasize(), size))
            h := keccak256(add(output, 32), size)
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
