// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrCompliance} from "hookr/interfaces/IHookrCompliance.sol";
import {HookrSessionTiers} from "hookr/libraries/HookrSessionTiers.sol";
import {HookrCredentialChecks} from "../libraries/HookrCredentialChecks.sol";

/// @title Hookr credential gate
/// @notice Fail-closed advisory for gated pools (tokenized stock, RWA and other restricted subjects). One advisory slot
///         carries the credential gate of HookrComplianceGuard, off-market session tiers (HookrSessionTiers), a
///         minimum-balance gate, a frozen allowlist and an optional price band. Every setting is frozen at bind.
interface IHookrCredentialGate {
    /// @notice Pool terms, frozen at bind. Bind data = abi.encode(Terms).
    /// @param listId Credential list on the compliance registry. Zero: sanctions only.
    /// @param requireAll Tier bits a credential must hold.
    /// @param blockAny Tier bits a credential must not hold.
    /// @param flags Behaviour bits (see the flag constants of HookrCredentialGate).
    /// @param sides Gated sides: GATE_BUY, GATE_SELL, GATE_ADD. An ungated buy, sell or add is screened for sanctions
    ///        only. A gated buy or sell needs the add side gated; a gated sell also needs the buy side gated and
    ///        CHECK_BENEFICIARY, and refuses ACCEPT_CURATED. Removals are never gated.
    /// @param balanceToken Token whose balance an entry must hold. Zero: off.
    /// @param minBalance Raw balance an entry must hold, 1 to MAX_MIN_BALANCE_BPS of the token's supply at bind.
    /// @param allowRoot Merkle root of the pool's allowlist. Zero: off. Wallets join with a proof (`join`).
    /// @param tickLower Band floor when TICK_RANGE is set, else zero.
    /// @param tickUpper Band ceiling when TICK_RANGE is set, else zero.
    /// @param protocolShareBps Share of the session surcharge taken for the protocol as a quote take. Zero on a pool
    ///        that cannot carry a take (fail-open, or an admission without a quote cap), else at least the floor.
    /// @param tiers Off-market session surcharge tiers. All zero: none.
    struct Terms {
        bytes32 listId;
        uint32 requireAll;
        uint32 blockAny;
        uint16 flags;
        uint8 sides;
        address balanceToken;
        uint128 minBalance;
        bytes32 allowRoot;
        int24 tickLower;
        int24 tickUpper;
        uint16 protocolShareBps;
        HookrSessionTiers.Tiers tiers;
    }

    /// @notice Frozen state per (binder, pool). Eight slots.
    struct Bound {
        bytes32 listId;
        address launcher;
        uint32 requireAll;
        uint32 blockAny;
        uint16 flags;
        uint8 sides;
        bool bound;
        address curatedRouter;
        int24 tickLower;
        int24 tickUpper;
        uint16 protocolShareBps;
        address balanceToken;
        uint128 minBalance;
        bytes32 allowRoot;
        HookrSessionTiers.Tiers tiers;
        address protocolRecipient;
    }

    /// @notice Who or what refused the operation.
    enum Reason {
        NONE,
        NOT_BOUND,
        UNAUTHENTICATED,
        CURATED_NOT_ACCEPTED,
        PAYER,
        BENEFICIARY,
        LP_SENDER,
        LP_OWNER,
        LAUNCH_BUY,
        OUT_OF_RANGE
    }

    event GateBound(address indexed binder, PoolId indexed id, bytes32 indexed listId, Terms terms, address launcher);
    event PairBound(address indexed binder, PoolId indexed id, HookrSessionTiers.Tiers tiers, uint24 capPips);
    event Joined(bytes32 indexed allowRoot, address indexed wallet);

    error InvalidConstructor(uint8 field);
    error AlreadyBound(address binder, PoolId id);
    error UnknownPool(address binder, PoolId id);
    /// @dev 1 unknown flag, 2 requireAll & blockAny overlap, 3 unknown list, 4 ACCEPT_CURATED without
    ///      RESTRICTED_SUBJECT on a credential list, allowlist or balance gate, 5 non-canonical data, 6 unknown side,
    ///      7 OPEN with gate settings, 8 balance token, 9 min balance, 10 band, 11 band flags without TICK_RANGE,
    ///      12 protocol share, 13 tiers, 14 no calendar, 15 lane executor flag on an OPEN pool, 16 pair terms, 17 a
    ///      gated buy or sell with the add side ungated, 18 a gated sell without the buy side gated, without
    ///      CHECK_BENEFICIARY or with ACCEPT_CURATED.
    error InvalidTerms(uint8 field);
    /// @dev 1 fail-open pool that can refuse, 2 phases, 3 gas limit, 4 RESTRICTED_SUBJECT with a subject take,
    ///      5 liquidity owner zero, 6 launcher views, 7 curated router view, 8 advisory or admission mismatch,
    ///      9 PoolManager mismatch, 10 protocol recipient view, 11 tick spacing.
    error InvalidPoolConfig(uint8 field);
    error NotAllowlisted(address wallet);
    error ProofTooLong(uint256 length);

    /// @notice keccak256 of the Terms type string.
    function configSchemaHash() external pure returns (bytes32);
    /// @notice The compliance registry.
    function compliance() external view returns (address);
    /// @notice The shared market calendar (HookrSessionAdvisory), or zero.
    function calendar() external view returns (address);
    /// @notice The PoolManager every HookrRoot binder must use.
    function poolManager() external view returns (address);
    /// @notice The frozen terms `binder` bound for a pool.
    function terms(address binder, PoolId id) external view returns (Bound memory);
    /// @notice Whether `wallet` joined the allowlist of the pool `binder` bound.
    function isMember(address binder, PoolId id, address wallet) external view returns (bool);
    /// @notice Whether `wallet` proved membership of the allowlist with root `allowRoot`.
    function isMemberOf(bytes32 allowRoot, address wallet) external view returns (bool);
    /// @notice Records `wallet` as a member of the allowlist with root `allowRoot`, with a Merkle proof. Anyone may
    ///         submit; membership never ends.
    function join(bytes32 allowRoot, address wallet, bytes32[] calldata proof) external;
    /// @notice The session surcharge the pool bound by `binder` would charge at `timestamp`, before the split.
    function surchargeAt(address binder, PoolId id, uint256 timestamp) external view returns (uint24);
    /// @notice Explains the swap decision `binder` would receive from beforeSwap.
    function explainSwap(address binder, HookrTypes.SwapContext calldata x)
        external
        view
        returns (bool allowed, Reason reason, HookrCredentialChecks.Check check, IHookrCompliance.Decision decision);
    /// @notice Explains the liquidity decision `binder` would receive from beforeAddLiquidity.
    function explainLiquidity(address binder, PoolId id, address sender)
        external
        view
        returns (
            bool allowed,
            Reason reason,
            HookrCredentialChecks.Check check,
            IHookrCompliance.Decision decision,
            address actor
        );
    /// @notice Default terms for a credential list under an LP-fee cap: buys and adds gated, beneficiary checked, tier
    ///         bit 0 required when there is a list (DEFAULT_REQUIRE_ALL), no balance, allowlist or band, the default
    ///         tiers for `capPips`, and the default protocol share when the pool can carry a quote take (`withTake`),
    ///         else zero.
    function defaultTerms(bytes32 listId, uint24 capPips, bool withTake) external pure returns (Terms memory);
}
