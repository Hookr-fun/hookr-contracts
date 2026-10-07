// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrGoverned} from "./IHookrGoverned.sol";

/// @title IHookrCompliance
/// @notice Wallet-level sanctions (officers, optional external source) and per-list credentials (attesters).
/// @dev Adding power is timelocked through HookrGoverned; removing power is immediate and voids the restoring
/// operations queued before it. Reads are O(1) and never revert on data conditions. Only a mask, an expiry and an issuer
/// go on chain; no personal data.
interface IHookrCompliance is IHookrGoverned {
    /// @notice What `check` decided for a wallet; the first failing step names it.
    enum Decision {
        ALLOW,
        SANCTIONED,
        SOURCE_FAILED,
        UNKNOWN_LIST,
        LIST_SUSPENDED,
        NO_CREDENTIAL,
        ISSUER_REVOKED,
        EXPIRED,
        MISSING_TIERS,
        BLOCKED_TIERS
    }

    /// @notice A stored credential: who issued it, for which tiers, when, and until when.
    struct Credential {
        /// @notice The attester that wrote the credential.
        address issuer; // 1 slot
        /// @notice The timestamp from which the credential no longer counts; zero for a revocation.
        uint32 expiresAt;
        /// @notice The timestamp of the write, which a later write must not precede.
        uint32 issuedAt;
        /// @notice A bitmask of the tiers the credential grants.
        uint32 tiers;
    }

    /// @notice A credential an attester signed, for anyone to submit.
    struct Attestation {
        /// @notice The list.
        bytes32 listId;
        /// @notice The wallet credentialed.
        address wallet;
        /// @notice A bitmask of the tiers the credential grants.
        uint32 tiers;
        /// @notice The timestamp from which the credential no longer counts.
        uint32 expiresAt;
        /// @notice The credential's issue time, which must be after any stored credential's.
        uint32 issuedAt;
        /// @notice The timestamp after which the signature cannot be submitted.
        uint32 deadline;
    }

    /// @notice A list's status.
    struct List {
        /// @notice Whether the list was created.
        bool exists;
        /// @notice Whether entries into the list's pools are stopped.
        bool suspended;
    }

    // Officers: immediate
    /// @notice The caller left too little gas to give the external source its full SOURCE_GAS.
    /// @dev Reverting (instead of reporting SOURCE_FAILED) stops a caller from starving the source to turn a sanctioned
    /// sell into a SELL_WHEN_SOURCE_DOWN pass (EIP-150 63/64 griefing).
    error SourceGasTooLow(uint256 available, uint256 required);

    /// @notice Sets or clears the local sanction flag of at most MAX_BATCH wallets.
    /// @param wallets The wallets, at most MAX_BATCH.
    /// @param listed True to flag them, false to clear the flag.
    function setSanctioned(address[] calldata wallets, bool listed) external;
    // Attesters of listId: immediate
    /// @notice Issues a credential with issuedAt = block.timestamp.
    /// @param listId The list.
    /// @param wallet The wallet credentialed.
    /// @param tiers A bitmask of the tiers the credential grants.
    /// @param expiresAt The timestamp from which the credential no longer counts, at most MAX_CREDENTIAL_TTL from now.
    function attest(bytes32 listId, address wallet, uint32 tiers, uint32 expiresAt) external;
    /// @notice Issues credentials to up to MAX_BATCH wallets with one expiry.
    /// @param listId The list.
    /// @param wallets The wallets credentialed, at most MAX_BATCH.
    /// @param tiers The tiers of each wallet, in the order of `wallets`.
    /// @param expiresAt The one expiry of every credential.
    function attestBatch(bytes32 listId, address[] calldata wallets, uint32[] calldata tiers, uint32 expiresAt) external;
    /// @notice Revokes the caller's own credentials on a list (or an empty slot): writes {msg.sender, 0, now, 0}.
    /// @param listId The list.
    /// @param wallets The wallets whose credentials the caller wrote, or that hold none.
    function revokeCredential(bytes32 listId, address[] calldata wallets) external;
    /// @notice Stores an attester-signed credential. Anyone may submit.
    /// @param a The attestation the attester signed.
    /// @param attester The attester whose signature `signature` is.
    /// @param signature The signature over the attestation's EIP-712 digest.
    function attestBySig(Attestation calldata a, address attester, bytes calldata signature) external;
    // Self-renounce
    /// @notice Gives up the caller's attester role on a list.
    /// @param listId The list.
    function renounceAttester(bytes32 listId) external;
    /// @notice Gives up the caller's officer role.
    function renounceOfficer() external;
    // Guardian or owner: immediate, reduces power
    /// @notice Revokes an attester. Its credentials stop counting while it is revoked and count again if it is
    ///         re-granted; voidCredentials voids them for good. Voids GRANT_ATTESTER(listId, attester) queued before
    ///         it.
    /// @param listId The list.
    /// @param attester The attester.
    function revokeAttester(bytes32 listId, address attester) external;
    /// @notice Revokes an officer. Voids GRANT_OFFICER(officer) queued before it.
    /// @param officer The officer.
    function revokeOfficer(address officer) external;
    /// @notice Suspends a list: entries into its pools stop. Resuming is timelocked; RESUME_LIST(listId) queued
    ///         before the suspension is void.
    /// @param listId The list.
    function suspendList(bytes32 listId) external;
    /// @notice Removes the external sanctions source while a probe of it fails; the local list remains. A healthy
    ///         source is removed only through SET_SANCTIONS_SOURCE(0).
    function clearSanctionsSource() external;
    /// @notice Revokes a guardian. Owner only. Voids GRANT_GUARDIAN(guardian) queued before it.
    /// @param guardian The guardian.
    function revokeGuardian(address guardian) external;
    // Owner: timelocked (HookrGoverned kinds in brackets)
    /// @notice Creates a list. Consumes CREATE_LIST(listId).
    /// @param listId The new list.
    function createList(bytes32 listId) external;
    /// @notice Grants an attester on a list. Consumes GRANT_ATTESTER(listId, attester). Sets attesterSince to now;
    ///         reverts for an attester already granted.
    /// @param listId The list.
    /// @param attester The attester.
    function grantAttester(bytes32 listId, address attester) external;
    /// @notice Grants an officer. Consumes GRANT_OFFICER(officer).
    /// @param officer The officer.
    function grantOfficer(address officer) external;
    /// @notice Grants a guardian (never an EIP-7702 delegated account). Consumes GRANT_GUARDIAN(guardian).
    /// @param guardian The guardian.
    function grantGuardian(address guardian) external;
    /// @notice Sets, replaces or removes (zero) the external sanctions source. Consumes SET_SANCTIONS_SOURCE(source).
    ///         A new source must be a contract that answers a probe.
    /// @param source The source, or zero to remove it.
    function setSanctionsSource(address source) external;
    /// @notice Resumes a suspended list. Consumes RESUME_LIST(listId), queued while the list was suspended.
    /// @param listId The list.
    function resumeList(bytes32 listId) external;
    /// @notice Voids every credential `attester` issued on a list before now. Consumes VOID_CREDENTIALS(listId, attester).
    /// @param listId The list.
    /// @param attester The attester.
    function voidCredentials(bytes32 listId, address attester) external;

    // Reads: O(1); never revert on data conditions
    /// @notice Evaluates a wallet for a list; the first failing step decides: local sanctions, the sanctions source (a
    ///         failed or malformed read is SOURCE_FAILED), list zero (ALLOW), unknown or suspended list, credential,
    ///         issuer, expiry, required tiers, blocked tiers; otherwise ALLOW.
    /// @dev Selector 0xff711c73.
    /// @param listId The list; zero skips the list part.
    /// @param wallet The wallet.
    /// @param requireAll The tiers the credential must all hold.
    /// @param blockAny The tiers of which the credential must hold none.
    /// @return The decision.
    function check(bytes32 listId, address wallet, uint32 requireAll, uint32 blockAny) external view returns (Decision);
    /// @notice Evaluates only the list part of `check` (list, credential, issuer, expiry, tiers); ALLOW for list zero.
    /// @param listId The list; zero allows.
    /// @param wallet The wallet.
    /// @param requireAll The tiers the credential must all hold.
    /// @param blockAny The tiers of which the credential must hold none.
    /// @return The decision.
    function checkCredential(bytes32 listId, address wallet, uint32 requireAll, uint32 blockAny)
        external
        view
        returns (Decision);
    /// @notice Returns the sanction flag and whether the external source failed.
    /// @param wallet The wallet.
    /// @return listed Whether the wallet is flagged locally or by the source.
    /// @return sourceFailed Whether the external source failed to answer.
    function sanctionStatus(address wallet) external view returns (bool listed, bool sourceFailed);
    /// @notice ISanctionsList-compatible read. A source failure reads as sanctioned.
    /// @dev Selector 0xdf592f7d.
    /// @param wallet The account to check.
    /// @return Whether `wallet` is sanctioned locally or by the source, or the source failed.
    function isSanctioned(address wallet) external view returns (bool);
    /// @notice Local storage read only; safe inside ERC-4337 validation (ERC-7562).
    /// @dev Selector 0xad97c652.
    /// @param wallet The account to check.
    /// @return Whether `wallet` is on the local sanctions list.
    function isSanctionedLocal(address wallet) external view returns (bool);
    /// @notice Returns the stored credential.
    /// @param listId The list.
    /// @param wallet The wallet.
    /// @return The stored credential.
    function credential(bytes32 listId, address wallet) external view returns (Credential memory);
    /// @notice Returns a list's status.
    /// @param listId The list.
    /// @return The list's status.
    function list(bytes32 listId) external view returns (List memory);
    /// @notice Returns an attester's grant time on a list, or zero.
    /// @param listId The list.
    /// @param attester The attester.
    /// @return The grant time, or zero.
    function attesterSince(bytes32 listId, address attester) external view returns (uint32);
    /// @notice Returns the earliest issuedAt at which an attester's credentials on a list count, or zero.
    /// @param listId The list.
    /// @param attester The attester.
    /// @return The earliest counting issue time, or zero.
    function validFrom(bytes32 listId, address attester) external view returns (uint32);
    /// @notice Returns whether the account is an officer.
    /// @param account The account.
    /// @return True when the account is an officer.
    function isOfficer(address account) external view returns (bool);
    /// @notice Returns whether the account is a guardian.
    /// @param account The account.
    /// @return True when the account is a guardian.
    function isGuardian(address account) external view returns (bool);
    /// @notice Returns the external sanctions source, or zero.
    /// @return The external source, or zero.
    function sanctionsSource() external view returns (address);
    /// @notice Returns the EIP-712 digest an attester signs.
    /// @param a The attestation.
    /// @return The EIP-712 digest.
    function attestationDigest(Attestation calldata a) external view returns (bytes32);
    /// @notice Returns the EIP-712 domain separator, computed on every call.
    /// @return The domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    /// @notice ERC-5267 domain description: fields 0x0d, an empty version and a zero salt.
    /// @return fields The bitmap of the fields below that are set.
    /// @return name The domain's name.
    /// @return version The domain's version, empty.
    /// @return chainId The chain id.
    /// @return verifyingContract This contract.
    /// @return salt The salt, zero.
    /// @return extensions The extensions, none.
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
    /// @notice Returns the shared release identity.
    /// @return The release id.
    function releaseId() external view returns (uint256);

    /// @notice A list was created.
    /// @param listId The list.
    event ListCreated(bytes32 indexed listId);
    /// @notice A list was suspended.
    /// @param listId The list.
    /// @param by The guardian or owner that suspended it.
    event ListSuspended(bytes32 indexed listId, address indexed by);
    /// @notice A suspended list resumed.
    /// @param listId The list.
    event ListResumed(bytes32 indexed listId);
    /// @notice An attester was granted or revoked on a list.
    /// @param listId The list.
    /// @param attester The attester.
    /// @param active Whether the attester is now granted.
    /// @param since The grant time, or zero when revoked.
    event AttesterSet(bytes32 indexed listId, address indexed attester, bool active, uint32 since);
    /// @notice An officer was granted or revoked.
    /// @param officer The officer.
    /// @param active Whether it is now an officer.
    event OfficerSet(address indexed officer, bool active);
    /// @notice A guardian was granted or revoked.
    /// @param guardian The guardian.
    /// @param active Whether it is now a guardian.
    event GuardianSet(address indexed guardian, bool active);
    /// @notice A wallet's local sanction flag changed.
    /// @param wallet The wallet.
    /// @param listed Whether it is now flagged.
    /// @param officer The officer that changed it.
    event SanctionSet(address indexed wallet, bool listed, address indexed officer);
    /// @notice A credential was written.
    /// @param listId The list.
    /// @param wallet The wallet.
    /// @param issuer The attester that wrote it.
    /// @param tiers The tiers it grants, zero for a revocation.
    /// @param expiresAt The timestamp from which it no longer counts.
    /// @param issuedAt The timestamp of the write.
    event CredentialSet(
        bytes32 indexed listId,
        address indexed wallet,
        address indexed issuer,
        uint32 tiers,
        uint32 expiresAt,
        uint32 issuedAt
    );
    /// @notice The external sanctions source changed.
    /// @param source The new source, or zero.
    event SanctionsSourceSet(address indexed source);
    /// @notice An attester's earlier credentials on a list were voided.
    /// @param listId The list.
    /// @param attester The attester.
    /// @param validFrom The earliest issue time that counts from now.
    event CredentialsVoided(bytes32 indexed listId, address indexed attester, uint32 validFrom);

    /// @notice `listId` was never created.
    error UnknownList(bytes32 listId);
    /// @notice `listId` already exists.
    error ListExists(bytes32 listId);
    /// @notice `attester` is already granted on `listId`.
    error AlreadyAttester(bytes32 listId, address attester);
    /// @notice `caller` is not an attester of `listId`.
    error NotAttester(bytes32 listId, address caller);
    /// @notice `caller` is not an officer.
    error NotOfficer(address caller);
    /// @notice `caller` is neither a guardian nor the owner.
    error NotGuardianOrOwner(address caller);
    /// @notice A credential write was refused.
    error InvalidCredential(uint8 field);
    /// @notice The credential's `issuedAt` is not after the `stored` time that already counts.
    error StaleAttestation(uint32 issuedAt, uint32 stored);
    /// @notice The credential's `issuedAt` is after `timestamp`.
    error FutureIssuedAt(uint32 issuedAt, uint256 timestamp);
    /// @notice The signature's `deadline` passed before `timestamp`.
    error AttestationExpired(uint32 deadline, uint256 timestamp);
    /// @notice The signature is not `attester`'s.
    error InvalidSignature(address attester);
    /// @notice `length` entries are more than the `maximum`.
    error BatchTooLarge(uint256 length, uint256 maximum);
    /// @notice `source` is not a contract that answers the probe, or none is set.
    error InvalidSource(address source);
    /// @notice `source` answers its probe, so only a timelocked change removes it.
    error SourceHealthy(address source);
    /// @notice `listId` is not suspended.
    error ListNotSuspended(bytes32 listId);
    /// @notice `issuer`, not the caller, wrote the credential of `wallet` on `listId`.
    error NotIssuer(bytes32 listId, address wallet, address issuer);
    /// @notice `issuer` holds a live credential for `wallet` on `listId` that the writer may not replace.
    error CredentialHeld(bytes32 listId, address wallet, address issuer);
}
