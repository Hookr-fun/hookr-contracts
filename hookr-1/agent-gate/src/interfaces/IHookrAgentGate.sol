// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";

/// @title Hookr agent gate (second gate)
/// @notice Fail-closed advisory for agents-only pools: a buy, a sell or a liquidity add is admitted only for a wallet
///         that holds an ERC-8004 agent identity or is the registered agent wallet (or owner) of an identity it linked
///         here. Removals are never gated. Optional per pool, frozen at bind: a reputation threshold for entries, a
///         fee tier that charges agents below a threshold an LP-fee surcharge, and a link-age floor for entries.
///         Adds through Uniswap's PositionManager are screened on the wallet that called it (its `msgSender()`), never
///         on the PositionManager itself; ordinary runtime code passes only through a link it made itself and proved with its
///         own ERC-1271 signature, never by holding an identity someone sent it. The creator is screened at bind, so a
///         launch a non-agent would own is refused with a reason before any liquidity moves. A codeless non-origin
///         creator is refused too. Constructor trades/adds still pass by balance; a public constructor relay can share
///         that identity-only access. Codeless Nitro origin aliases can also link and share score/age access.
interface IHookrAgentGate {
    /// @notice Pool terms, frozen at bind. Bind data = abi.encode(Terms): six words.
    /// @param flags Behaviour bits: CHECK_BENEFICIARY (a buyer's recipient must be an agent too), ACCEPT_CURATED (let
    ///        Universal Router swaps in; the root reads their payer and cannot see their recipient).
    /// @param minScore Entries need the payer's agent's score (see `scoreOf`) at or above it, in whole units. Zero:
    ///        identity only.
    /// @param tierScore Agents at or above it pay the base fee; below it, or with no score, base plus `tierPips`. Zero
    ///        with `tierPips` zero: no tier.
    /// @param tierPips The fee tier's LP-fee surcharge in pips, at most the admission's maxLpFeePips.
    /// @param reviewers The reviewer set (`registerReviewers`, one reviewer in this release) the score is read from. Zero
    ///        when no score is read.
    /// @param minAge Entries (buys and adds, the launch's own liquidity excepted) need the wallet's live link to its
    ///        agent id to be at least this many seconds old (see `linkedAt`); a wallet passing by balance alone has no
    ///        age. Zero: no age rule. At most MAX_MIN_AGE.
    struct Terms {
        uint16 flags;
        uint32 minScore;
        uint32 tierScore;
        uint24 tierPips;
        bytes32 reviewers;
        uint32 minAge;
    }

    /// @notice Frozen state per (binder, pool).
    struct Bound {
        bool bound;
        uint16 flags;
        uint32 minScore;
        uint32 tierScore;
        uint24 tierPips;
        uint32 minAge;
        address launcher;
        address curatedRouter;
        bytes32 reviewers;
    }

    /// @notice The registry pins the degraded check reads: the two proxies' runtime code hashes and the hashes of
    ///         their `getVersion()` answers (the answer's bytes; past 256 bytes, its first 256 bytes and its length).
    struct Pins {
        bytes32 identityCode;
        bytes32 identityVersion;
        bytes32 reputationCode;
        bytes32 reputationVersion;
    }

    /// @notice Who or what refused the operation. New reasons are appended, so the first gate's numbering holds.
    enum Reason {
        NONE,
        NOT_BOUND,
        UNAUTHENTICATED,
        LAUNCH_BUY,
        CURATED_NOT_ACCEPTED,
        DEGRADED,
        PAYER,
        BENEFICIARY,
        SCORE,
        LP_SENDER,
        LP_OWNER,
        /// @dev The wallet's link is younger than the pool's age floor, or it has no link.
        AGE,
        /// @dev The PositionManager did not name the wallet adding through it (or named the curated router).
        LP_MANAGER
    }

    event GateBound(address indexed binder, PoolId indexed id, Terms terms, address launcher);
    event AgentLinked(address indexed wallet, uint256 indexed agentId, uint64 since);
    event AgentUnlinked(address indexed wallet);
    event ReviewersRegistered(bytes32 indexed id, address[] clients, string tag);
    event Suspended();
    event Resumed();
    event RepinQueued(uint48 at, bytes32 commitment);
    event Repinned(Pins pins);

    /// @dev 1 identity registry, 2 reputation registry, 3 PoolManager, 4 owner, 5 PositionManager.
    error InvalidConstructor(uint8 field);
    error AlreadyBound(address binder, PoolId id);
    /// @dev 1 unknown flag, 2 a tier threshold without a surcharge or a surcharge without a threshold, 3 surcharge
    ///      above the admission's LP cap, 4 a score threshold without a reviewer set or a set without one, 5 unknown
    ///      reviewer set, 6 non-canonical data, 7 age floor above MAX_MIN_AGE.
    error InvalidTerms(uint8 field);
    /// @dev 1 not the calling root's pool or not this advisory, 2 phases, 3 gas limit, 4 fail-open, 5 PoolManager
    ///      mismatch, 6 not admitted as this root's ADVISORY, 7 liquidity owner zero, 8 launcher views, 9 curated
    ///      router view, 10 the registries moved or the gate is suspended, 11 the family owner (the creator, or the
    ///      tokenizer when a revenue token's stream launches the pool) is not an agent, or is codeless and not tx.origin.
    error InvalidPoolConfig(uint8 field);
    /// @dev 1 no clients or too many, 2 tag too long, 3 a zero client.
    error InvalidReviewers(uint8 field);
    error NotAgentWallet(uint256 agentId, address wallet);
    /// @dev A caller with code did not approve the Link digest through ERC-1271, or a contract still in its
    ///      constructor tried to link.
    error LinkNotProven(uint256 agentId, address wallet);
    error Unauthorized();
    error AlreadySuspended();
    error NotSuspended();
    /// @dev No repin is queued, or its delay has not passed.
    error RepinNotReady();
    /// @dev More than REPIN_GRACE has elapsed since the queued re-pin became ready.
    error RepinExpired();
    /// @dev The registries no longer match the four pins committed by the queued call.
    error RepinMismatch();

    /// @notice keccak256 of the Terms type string.
    function configSchemaHash() external pure returns (bytes32);
    /// @notice The ERC-8004 Identity Registry.
    function identity() external view returns (address);
    /// @notice The ERC-8004 Reputation Registry.
    function reputation() external view returns (address);
    /// @notice The PoolManager every HookrRoot binder must use.
    function poolManager() external view returns (address);
    /// @notice Uniswap's PositionManager on this chain: adds it sends are screened on its `msgSender()`.
    function positionManager() external view returns (address);
    /// @notice The owner that can suspend, resume and re-pin the gate.
    function owner() external view returns (address);
    /// @notice Whether the owner suspended the gate: every pool refuses entries until `resume`; holders can still sell.
    function suspended() external view returns (bool);
    /// @notice The registry pins in force.
    function pins() external view returns (Pins memory);
    /// @notice When a queued re-pin may run, or zero.
    function repinAt() external view returns (uint48);
    /// @notice keccak256(abi.encode(expected)) for the queued four pins, or zero when no re-pin is queued.
    function repinCommitment() external view returns (bytes32);
    /// @notice The frozen terms `binder` bound for a pool.
    function terms(address binder, PoolId id) external view returns (Bound memory);
    /// @notice The agent id `wallet` linked, if any. A link is only the wallet's claim: every read checks that the
    ///         registry still names the wallet as the id's agent wallet or owner.
    function linkOf(address wallet) external view returns (bool linked, uint256 agentId);
    /// @notice When `wallet` first linked `agentId` here (seconds), or zero. Written once; `unlink` keeps it.
    function linkedAt(address wallet, uint256 agentId) external view returns (uint64);
    /// @notice The nonce of `wallet`'s next proven link: how many links it proved with ERC-1271 here.
    function linkNonce(address wallet) external view returns (uint256);
    /// @notice The EIP-712 digest a contract `wallet` must approve through its ERC-1271 `isValidSignature` for its
    ///         next link to `agentId`: typed data `Link(address wallet,uint256 agentId,uint256 nonce)` with `nonce` =
    ///         `linkNonce(wallet)`, in the domain (name "HookrAgentGate", version "2", this chain, this gate).
    function linkDigest(address wallet, uint256 agentId) external view returns (bytes32);
    /// @notice A registered reviewer set.
    function reviewerSet(bytes32 id) external view returns (address[] memory clients, string memory tag);
    /// @notice Whether `wallet` passes the identity check now: it holds an identity (a wallet without code, or an
    ///         EIP-7702 delegated one), or it is the live agent wallet or owner of the identity it linked (a contract
    ///         only links with its own ERC-1271 proof).
    function isAgent(address wallet) external view returns (bool);
    /// @notice The score `wallet` trades with on pools reading the reviewer set `reviewers`: in 18 decimals, the set's
    ///         one reviewer's latest live entry under the set's tag for the agent id `wallet` linked, while the registry
    ///         still names `wallet` as that id's agent wallet or owner. `has` is false for no live link, no such entry,
    ///         or any read that failed.
    function scoreOf(address wallet, bytes32 reviewers) external view returns (bool has, int256 wad);
    /// @notice The age, in seconds, of `wallet`'s live link: zero when it has none.
    function ageOf(address wallet) external view returns (uint256);
    /// @notice Links the caller to `agentId` (any id, 0 included): the caller must be its agent wallet or its owner
    ///         now. The link gives the score its id, starts the age clock the first time, and lets an agent wallet
    ///         that holds no identity NFT trade; every read checks it again, so a wallet the registry no longer names
    ///         loses all three at once. A contract trades only through a link, and a contract's link is the same as
    ///         `linkWithProof(agentId, "")`: it passes when the contract approves `linkDigest` with an empty signature
    ///         (a Safe that signed the message on chain), and reverts LinkNotProven otherwise.
    function link(uint256 agentId) external;
    /// @notice `link` for a caller with code: the caller's ERC-1271 `isValidSignature(linkDigest(caller, agentId),
    ///         proof)` must approve, and the proof is spent (the nonce moves). A contract anyone can drive (Multicall3,
    ///         an ERC-2771 forwarder) cannot approve, so an identity parked in it never opens a pool. A wallet without
    ///         code, or an EIP-7702 delegated one, needs no proof and `proof` is ignored.
    function linkWithProof(uint256 agentId, bytes calldata proof) external;
    /// @notice Clears the caller's link. The first link's time stays.
    function unlink() external;
    /// @notice Registers the reviewer set (`clients`, `tag`) under keccak256(abi.encode(clients, tag)): 1 to
    ///         MAX_REVIEWERS clients, a tag of at most MAX_TAG_LENGTH bytes. Content-addressed, so it never changes.
    function registerReviewers(address[] calldata clients, string calldata tag) external returns (bytes32 id);
    /// @notice Suspends the gate. Owner only. Every pool then refuses entries and adds from wallets; holders can
    ///         still sell, and each pool's lane executor, which reads no registry, keeps trading while its lane is on.
    function suspend() external;
    /// @notice Lifts a suspension. Owner only.
    function resume() external;
    /// @notice Commits to the reviewed four pins and starts the REPIN_DELAY clock. Re-queueing replaces the commitment
    ///         and restarts the delay. Owner only.
    function queueRepin(Pins calldata expected) external;
    /// @notice Re-reads both registries and accepts exactly the queued four pins, from REPIN_DELAY after the queue
    ///         until REPIN_GRACE after it becomes ready. A mismatch leaves the queue intact; a successful re-pin consumes
    ///         it. Version answers are bounded and hashed as `pins` describes. Owner only.
    function repin() external;
    /// @notice Explains the swap decision `binder` would receive from beforeSwap.
    function explainSwap(address binder, HookrTypes.SwapContext calldata x)
        external
        view
        returns (bool allowed, Reason reason, uint24 surchargePips);
    /// @notice Explains the liquidity decision `binder` would receive from beforeAddLiquidity.
    function explainLiquidity(address binder, PoolId id, address sender)
        external
        view
        returns (bool allowed, Reason reason);
}
