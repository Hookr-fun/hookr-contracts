// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";

/// @title Hookr agent gate
/// @notice Fail-closed advisory for agents-only pools: a buy, a sell or a liquidity add is admitted only for a wallet
///         that holds an ERC-8004 agent identity or is the registered agent wallet of an identity it linked here.
///         Removals are never gated. Optional per pool, frozen at bind: a reputation threshold for entries and a fee
///         tier that charges agents below a threshold an LP-fee surcharge.
interface IHookrAgentGate {
    /// @notice Pool terms, frozen at bind. Bind data = abi.encode(Terms).
    /// @param flags Behaviour bits: CHECK_BENEFICIARY (a buyer's recipient must be an agent too), ACCEPT_CURATED (let
    ///        Universal Router swaps in; the root reads their payer and cannot see their recipient).
    /// @param minScore Entries need the payer's agent's score (see `scoreOf`) at or above it, in whole units. Zero:
    ///        identity only.
    /// @param tierScore Agents at or above it pay the base fee; below it, or with no score, base plus `tierPips`. Zero
    ///        with `tierPips` zero: no tier.
    /// @param tierPips The fee tier's LP-fee surcharge in pips, at most the admission's maxLpFeePips.
    /// @param reviewers The reviewer set (`registerReviewers`, one reviewer in this release) the score is read from. Zero
    ///        when no score is read.
    struct Terms {
        uint16 flags;
        uint32 minScore;
        uint32 tierScore;
        uint24 tierPips;
        bytes32 reviewers;
    }

    /// @notice Frozen state per (binder, pool).
    struct Bound {
        bool bound;
        uint16 flags;
        uint32 minScore;
        uint32 tierScore;
        uint24 tierPips;
        address launcher;
        address curatedRouter;
        bytes32 reviewers;
    }

    /// @notice Who or what refused the operation.
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
        LP_OWNER
    }

    event GateBound(address indexed binder, PoolId indexed id, Terms terms, address launcher);
    event AgentLinked(address indexed wallet, uint256 indexed agentId);
    event AgentUnlinked(address indexed wallet);
    event ReviewersRegistered(bytes32 indexed id, address[] clients, string tag);
    event Retired();

    /// @dev 1 identity registry, 2 reputation registry, 3 PoolManager, 4 owner.
    error InvalidConstructor(uint8 field);
    error AlreadyBound(address binder, PoolId id);
    /// @dev 1 unknown flag, 2 a tier threshold without a surcharge or a surcharge without a threshold, 3 surcharge
    ///      above the admission's LP cap, 4 a score threshold without a reviewer set or a set without one, 5 unknown
    ///      reviewer set, 6 non-canonical data.
    error InvalidTerms(uint8 field);
    /// @dev 1 not the calling root's pool or not this advisory, 2 phases, 3 gas limit, 4 fail-open, 5 PoolManager
    ///      mismatch, 6 not admitted as this root's ADVISORY, 7 liquidity owner zero, 8 launcher views, 9 curated
    ///      router view, 10 the registries moved or the gate is retired.
    error InvalidPoolConfig(uint8 field);
    /// @dev 1 no clients or too many, 2 tag too long, 3 a zero client.
    error InvalidReviewers(uint8 field);
    error NotAgentWallet(uint256 agentId, address wallet);
    error Unauthorized();
    error AlreadyRetired();

    /// @notice keccak256 of the Terms type string.
    function configSchemaHash() external pure returns (bytes32);
    /// @notice The ERC-8004 Identity Registry.
    function identity() external view returns (address);
    /// @notice The ERC-8004 Reputation Registry.
    function reputation() external view returns (address);
    /// @notice The PoolManager every HookrRoot binder must use.
    function poolManager() external view returns (address);
    /// @notice The owner that can retire the gate.
    function owner() external view returns (address);
    /// @notice Whether the owner retired the gate: every pool refuses entries for good; holders can still sell.
    function retired() external view returns (bool);
    /// @notice The frozen terms `binder` bound for a pool.
    function terms(address binder, PoolId id) external view returns (Bound memory);
    /// @notice The agent id `wallet` linked, if any. A link is only the wallet's claim: every read checks that the
    ///         registry still names the wallet as the id's agent wallet or owner.
    function linkOf(address wallet) external view returns (bool linked, uint256 agentId);
    /// @notice A registered reviewer set.
    function reviewerSet(bytes32 id) external view returns (address[] memory clients, string memory tag);
    /// @notice Whether `wallet` passes the identity check now: it holds an identity, or it is the live agent wallet
    ///         of the identity it linked.
    function isAgent(address wallet) external view returns (bool);
    /// @notice The score `wallet` trades with on pools reading the reviewer set `reviewers`: in 18 decimals, the set's
    ///         one reviewer's latest live entry under the set's tag for the agent id `wallet` linked, while the registry
    ///         still names `wallet` as that id's agent wallet or owner. `has` is false for no live link, no such entry,
    ///         or any read that failed.
    function scoreOf(address wallet, bytes32 reviewers) external view returns (bool has, int256 wad);
    /// @notice Links the caller to `agentId` (any id, 0 included): the caller must be its agent wallet or its owner
    ///         now. The link gives the score its id and lets an agent wallet that holds no identity NFT trade; every
    ///         read checks it again, so a wallet the registry no longer names loses both at once.
    function link(uint256 agentId) external;
    /// @notice Clears the caller's link.
    function unlink() external;
    /// @notice Registers the reviewer set (`clients`, `tag`) under keccak256(abi.encode(clients, tag)): 1 to
    ///         MAX_REVIEWERS clients, a tag of at most MAX_TAG_LENGTH bytes. Content-addressed, so it never changes.
    function registerReviewers(address[] calldata clients, string calldata tag) external returns (bytes32 id);
    /// @notice Retires the gate for good. Owner only. Every pool then refuses entries and adds from wallets; holders
    ///         can still sell, and each pool's lane executor, which reads no registry, keeps trading while its lane is
    ///         on (the lane's own brake stops it).
    function retire() external;
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
