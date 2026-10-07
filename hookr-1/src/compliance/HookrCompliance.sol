// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IHookrCompliance} from "../interfaces/IHookrCompliance.sol";
import {ISanctionsList} from "../interfaces/external/ISanctionsList.sol";
import {HookrRelease} from "../libraries/HookrRelease.sol";
import {HookrGoverned} from "../base/HookrGoverned.sol";

/// @title HookrCompliance
/// @notice KYC credentials per list and wallet sanctions, read by the compliance guard on entries only.
/// @dev No global pause and no function touches funds. If the operator disappears, credentials expire within
/// MAX_CREDENTIAL_TTL: buys stop, sells continue. Restrictive actions are immediate and invalidate the restoring
/// operations on the same subject queued before them; loosening actions and every sanctions source change are
/// timelocked. RESUME_LIST, GRANT_ATTESTER, GRANT_OFFICER and GRANT_GUARDIAN epochs are keyed by subject, so a
/// guardian is rotated by queueing the successor's grant and revoking the predecessor in either order. The EIP-712
/// domain has no version and is recomputed on every call, so the runtime hash is identical on every chain.
contract HookrCompliance is IHookrCompliance, HookrGoverned {
    /// @dev One slot: grant time (zero while revoked) and the earliest issuedAt that counts.
    struct Attester {
        uint32 since;
        uint32 validFrom;
    }

    /// @custom:storage-location erc7201:hookr.compliance
    struct State {
        address sanctionsSource;
        mapping(bytes32 listId => List) lists;
        mapping(bytes32 listId => mapping(address attester => Attester)) attesters;
        mapping(bytes32 listId => mapping(address wallet => Credential)) credentials;
        mapping(address wallet => bool) sanctioned;
        mapping(address officer => bool) officers;
        mapping(address guardian => bool) guardians;
    }

    /// @dev cast index-erc7201 hookr.compliance
    bytes32 private constant STATE_SLOT = 0x4b50a81602cb2b80d70033d9972a53f216b421d893368928ec520a175d508b00;
    /// @dev keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)")
    bytes32 private constant DOMAIN_TYPEHASH = 0x8cad95687ba82c2ce50e74f7b754645e5117c3a5bec8151c0726d5857980a866;
    /// @dev keccak256("HookrCompliance")
    bytes32 private constant NAME_HASH = keccak256("HookrCompliance");

    /// @notice keccak256("Attestation(bytes32 listId,address wallet,uint32 tiers,uint32 expiresAt,uint32 issuedAt,uint32 deadline)").
    bytes32 public constant ATTESTATION_TYPEHASH = 0xa2df5db8f0526a2001d08cf5e9adc39b15d26163ce67f0f26076b10107574c4b;
    /// @notice Largest batch any role may write in one call.
    uint256 public constant MAX_BATCH = 200;
    /// @notice Longest credential lifetime from the time it is written.
    uint256 public constant MAX_CREDENTIAL_TTL = 400 days;
    /// @notice Gas forwarded to the external sanctions source.
    uint256 public constant SOURCE_GAS = 30_000;

    bytes32 public constant CREATE_LIST = keccak256("CREATE_LIST");
    bytes32 public constant GRANT_ATTESTER = keccak256("GRANT_ATTESTER");
    bytes32 public constant GRANT_OFFICER = keccak256("GRANT_OFFICER");
    bytes32 public constant GRANT_GUARDIAN = keccak256("GRANT_GUARDIAN");
    bytes32 public constant SET_SANCTIONS_SOURCE = keccak256("SET_SANCTIONS_SOURCE");
    bytes32 public constant RESUME_LIST = keccak256("RESUME_LIST");
    bytes32 public constant VOID_CREDENTIALS = keccak256("VOID_CREDENTIALS");

    modifier onlyOfficer() {
        if (!_state().officers[msg.sender]) revert NotOfficer(msg.sender);
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != _owner() && !_state().guardians[msg.sender]) revert NotGuardianOrOwner(msg.sender);
        _;
    }

    modifier onlyAttester(bytes32 listId) {
        if (_state().attesters[listId][msg.sender].since == 0) revert NotAttester(listId, msg.sender);
        _;
    }

    /// @param owner_ Governance owner (multisig).
    /// @param delay_ Timelock delay in [30 minutes, 30 days].
    constructor(address owner_, uint48 delay_) HookrGoverned(owner_, delay_) {}

    /// @inheritdoc IHookrCompliance
    function setSanctioned(address[] calldata wallets, bool listed) external onlyOfficer {
        _batch(wallets.length);
        State storage s = _state();
        for (uint256 i; i < wallets.length; ++i) {
            s.sanctioned[wallets[i]] = listed;
            emit SanctionSet(wallets[i], listed, msg.sender);
        }
    }

    /// @inheritdoc IHookrCompliance
    function attest(bytes32 listId, address wallet, uint32 tiers, uint32 expiresAt) external onlyAttester(listId) {
        _attest(listId, wallet, tiers, expiresAt);
    }

    /// @inheritdoc IHookrCompliance
    function attestBatch(bytes32 listId, address[] calldata wallets, uint32[] calldata tiers, uint32 expiresAt)
        external
        onlyAttester(listId)
    {
        if (wallets.length != tiers.length) revert InvalidCredential(4);
        _batch(wallets.length);
        for (uint256 i; i < wallets.length; ++i) {
            _attest(listId, wallets[i], tiers[i], expiresAt);
        }
    }

    /// @inheritdoc IHookrCompliance
    function revokeCredential(bytes32 listId, address[] calldata wallets) external onlyAttester(listId) {
        _batch(wallets.length);
        State storage s = _state();
        uint32 nowTs = uint32(block.timestamp);
        for (uint256 i; i < wallets.length; ++i) {
            address wallet = wallets[i];
            if (wallet == address(0)) revert InvalidCredential(1);
            address issuer = s.credentials[listId][wallet].issuer;
            if (issuer != address(0) && issuer != msg.sender) revert NotIssuer(listId, wallet, issuer);
            s.credentials[listId][wallet] = Credential(msg.sender, 0, nowTs, 0);
            emit CredentialSet(listId, wallet, msg.sender, 0, 0, nowTs);
        }
    }

    /// @inheritdoc IHookrCompliance
    function attestBySig(Attestation calldata a, address attester, bytes calldata signature) external {
        State storage s = _state();
        Attester memory granted = s.attesters[a.listId][attester];
        uint32 since = granted.since;
        if (since == 0) revert NotAttester(a.listId, attester);
        if (block.timestamp > a.deadline) revert AttestationExpired(a.deadline, block.timestamp);
        if (a.issuedAt > block.timestamp) revert FutureIssuedAt(a.issuedAt, block.timestamp);
        Credential storage stored = s.credentials[a.listId][a.wallet];
        uint32 storedIssuedAt = stored.issuedAt;
        if (a.issuedAt <= storedIssuedAt) revert StaleAttestation(a.issuedAt, storedIssuedAt);
        if (a.issuedAt < granted.validFrom) revert StaleAttestation(a.issuedAt, granted.validFrom);
        _expiry(a.wallet, a.expiresAt);
        _refuseHeld(s, a.listId, a.wallet, stored, attester);
        if (!SignatureChecker.isValidSignatureNow(attester, attestationDigest(a), signature)) {
            revert InvalidSignature(attester);
        }
        s.credentials[a.listId][a.wallet] = Credential(attester, a.expiresAt, a.issuedAt, a.tiers);
        emit CredentialSet(a.listId, a.wallet, attester, a.tiers, a.expiresAt, a.issuedAt);
    }

    /// @inheritdoc IHookrCompliance
    function renounceAttester(bytes32 listId) external onlyAttester(listId) {
        _state().attesters[listId][msg.sender].since = 0;
        emit AttesterSet(listId, msg.sender, false, 0);
    }

    /// @inheritdoc IHookrCompliance
    function renounceOfficer() external onlyOfficer {
        _state().officers[msg.sender] = false;
        emit OfficerSet(msg.sender, false);
    }

    /// @inheritdoc IHookrCompliance
    function revokeAttester(bytes32 listId, address attester) external onlyGuardianOrOwner {
        State storage s = _state();
        Attester storage record = s.attesters[listId][attester];
        if (record.since == 0) revert NotAttester(listId, attester);
        record.since = 0;
        _invalidateQueued(_subjectKey(GRANT_ATTESTER, abi.encode(listId, attester)));
        emit AttesterSet(listId, attester, false, 0);
    }

    /// @inheritdoc IHookrCompliance
    function revokeOfficer(address officer) external onlyGuardianOrOwner {
        State storage s = _state();
        if (!s.officers[officer]) revert NotOfficer(officer);
        s.officers[officer] = false;
        _invalidateQueued(_subjectKey(GRANT_OFFICER, abi.encode(officer)));
        emit OfficerSet(officer, false);
    }

    /// @inheritdoc IHookrCompliance
    /// @dev Callable on a suspended list to void a RESUME_LIST queued during the suspension; the owner removes a
    ///      guardian that abuses this at once.
    function suspendList(bytes32 listId) external onlyGuardianOrOwner {
        List storage l = _state().lists[listId];
        if (!l.exists) revert UnknownList(listId);
        l.suspended = true;
        _invalidateQueued(_subjectKey(RESUME_LIST, abi.encode(listId)));
        emit ListSuspended(listId, msg.sender);
    }

    /// @inheritdoc IHookrCompliance
    function clearSanctionsSource() external onlyGuardianOrOwner {
        State storage s = _state();
        address current = s.sanctionsSource;
        if (current == address(0)) revert InvalidSource(current);
        (, bool failed) = _source(current, address(0));
        if (!failed) revert SourceHealthy(current);
        s.sanctionsSource = address(0);
        emit SanctionsSourceSet(address(0));
    }

    /// @inheritdoc IHookrCompliance
    function revokeGuardian(address guardian) external onlyOwner {
        State storage s = _state();
        if (!s.guardians[guardian]) revert NotGuardianOrOwner(guardian);
        s.guardians[guardian] = false;
        _invalidateQueued(_subjectKey(GRANT_GUARDIAN, abi.encode(guardian)));
        emit GuardianSet(guardian, false);
    }

    /// @inheritdoc IHookrCompliance
    /// @dev listId zero is reserved for sanctions-only mode and can never be created.
    function createList(bytes32 listId) external onlyOwner {
        List storage l = _state().lists[listId];
        if (listId == bytes32(0) || l.exists) revert ListExists(listId);
        _consume(CREATE_LIST, abi.encode(listId));
        l.exists = true;
        emit ListCreated(listId);
    }

    /// @inheritdoc IHookrCompliance
    function grantAttester(bytes32 listId, address attester) external onlyOwner {
        if (attester == address(0)) revert InvalidAddress(attester);
        State storage s = _state();
        if (!s.lists[listId].exists) revert UnknownList(listId);
        Attester storage record = s.attesters[listId][attester];
        if (record.since != 0) revert AlreadyAttester(listId, attester);
        _consume(GRANT_ATTESTER, abi.encode(listId, attester));
        uint32 since = uint32(block.timestamp);
        record.since = since;
        if (record.validFrom == 0) record.validFrom = since;
        emit AttesterSet(listId, attester, true, since);
    }

    /// @inheritdoc IHookrCompliance
    function voidCredentials(bytes32 listId, address attester) external onlyOwner {
        State storage s = _state();
        if (!s.lists[listId].exists) revert UnknownList(listId);
        _consume(VOID_CREDENTIALS, abi.encode(listId, attester));
        uint32 from = uint32(block.timestamp);
        s.attesters[listId][attester].validFrom = from;
        emit CredentialsVoided(listId, attester, from);
    }

    /// @inheritdoc IHookrCompliance
    function grantOfficer(address officer) external onlyOwner {
        if (officer == address(0)) revert InvalidAddress(officer);
        _consume(GRANT_OFFICER, abi.encode(officer));
        _state().officers[officer] = true;
        emit OfficerSet(officer, true);
    }

    /// @inheritdoc IHookrCompliance
    function grantGuardian(address guardian) external onlyOwner {
        if (guardian == address(0)) revert InvalidAddress(guardian);
        _refuseDelegated(guardian);
        _consume(GRANT_GUARDIAN, abi.encode(guardian));
        _state().guardians[guardian] = true;
        emit GuardianSet(guardian, true);
    }

    /// @inheritdoc IHookrCompliance
    /// @dev Every change, switching a source on included, consumes SET_SANCTIONS_SOURCE(source): a source gates
    ///      every exit, so users get the full delay's notice. Immediate listing is the officers' power. A new source
    ///      must answer a probe.
    function setSanctionsSource(address source) external onlyOwner {
        State storage s = _state();
        if (source != address(0)) {
            _requireDeployedCode(source);
            (, bool failed) = _source(source, address(0));
            if (failed) revert InvalidSource(source);
        }
        _consume(SET_SANCTIONS_SOURCE, abi.encode(source));
        s.sanctionsSource = source;
        emit SanctionsSourceSet(source);
    }

    /// @inheritdoc IHookrCompliance
    function resumeList(bytes32 listId) external onlyOwner {
        List storage l = _state().lists[listId];
        if (!l.exists) revert UnknownList(listId);
        if (!l.suspended) revert ListNotSuspended(listId);
        _consume(RESUME_LIST, abi.encode(listId));
        l.suspended = false;
        emit ListResumed(listId);
    }

    /// @inheritdoc IHookrCompliance
    function check(bytes32 listId, address wallet, uint32 requireAll, uint32 blockAny)
        external
        view
        returns (Decision)
    {
        State storage s = _state();
        if (s.sanctioned[wallet]) return Decision.SANCTIONED;
        if (s.sanctionsSource != address(0)) {
            (bool listed, bool failed) = _source(s.sanctionsSource, wallet);
            if (failed) return Decision.SOURCE_FAILED;
            if (listed) return Decision.SANCTIONED;
        }
        if (listId == bytes32(0)) return Decision.ALLOW;
        return _credentialDecision(s, listId, wallet, requireAll, blockAny);
    }

    /// @inheritdoc IHookrCompliance
    function checkCredential(bytes32 listId, address wallet, uint32 requireAll, uint32 blockAny)
        external
        view
        returns (Decision)
    {
        if (listId == bytes32(0)) return Decision.ALLOW;
        return _credentialDecision(_state(), listId, wallet, requireAll, blockAny);
    }

    /// @inheritdoc IHookrCompliance
    function sanctionStatus(address wallet) public view returns (bool listed, bool sourceFailed) {
        State storage s = _state();
        if (s.sanctioned[wallet]) return (true, false);
        if (s.sanctionsSource != address(0)) (listed, sourceFailed) = _source(s.sanctionsSource, wallet);
    }

    /// @inheritdoc IHookrCompliance
    function isSanctioned(address wallet) external view returns (bool) {
        (bool listed, bool failed) = sanctionStatus(wallet);
        return listed || failed;
    }

    /// @inheritdoc IHookrCompliance
    function isSanctionedLocal(address wallet) external view returns (bool) {
        return _state().sanctioned[wallet];
    }

    /// @inheritdoc IHookrCompliance
    function credential(bytes32 listId, address wallet) external view returns (Credential memory) {
        return _state().credentials[listId][wallet];
    }

    /// @inheritdoc IHookrCompliance
    function list(bytes32 listId) external view returns (List memory) {
        return _state().lists[listId];
    }

    /// @inheritdoc IHookrCompliance
    function attesterSince(bytes32 listId, address attester) external view returns (uint32) {
        return _state().attesters[listId][attester].since;
    }

    /// @inheritdoc IHookrCompliance
    function validFrom(bytes32 listId, address attester) external view returns (uint32) {
        return _state().attesters[listId][attester].validFrom;
    }

    /// @inheritdoc IHookrCompliance
    function isOfficer(address account) external view returns (bool) {
        return _state().officers[account];
    }

    /// @inheritdoc IHookrCompliance
    function isGuardian(address account) external view returns (bool) {
        return _state().guardians[account];
    }

    /// @inheritdoc IHookrCompliance
    function sanctionsSource() external view returns (address) {
        return _state().sanctionsSource;
    }

    /// @inheritdoc IHookrCompliance
    function attestationDigest(Attestation calldata a) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(ATTESTATION_TYPEHASH, a.listId, a.wallet, a.tiers, a.expiresAt, a.issuedAt, a.deadline)
        );
        return keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR(), structHash));
    }

    /// @inheritdoc IHookrCompliance
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, block.chainid, address(this)));
    }

    /// @inheritdoc IHookrCompliance
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
        )
    {
        return (hex"0d", "HookrCompliance", "", block.chainid, address(this), bytes32(0), new uint256[](0));
    }

    /// @inheritdoc IHookrCompliance
    function releaseId() external pure returns (uint256) {
        return HookrRelease.ID;
    }

    function _attest(bytes32 listId, address wallet, uint32 tiers, uint32 expiresAt) private {
        _expiry(wallet, expiresAt);
        State storage s = _state();
        Credential storage stored = s.credentials[listId][wallet];
        uint32 nowTs = uint32(block.timestamp);
        if (nowTs < stored.issuedAt) revert StaleAttestation(nowTs, stored.issuedAt);
        _refuseHeld(s, listId, wallet, stored, msg.sender);
        s.credentials[listId][wallet] = Credential(msg.sender, expiresAt, nowTs, tiers);
        emit CredentialSet(listId, wallet, msg.sender, tiers, expiresAt, nowTs);
    }

    function _expiry(address wallet, uint32 expiresAt) private view {
        if (wallet == address(0)) revert InvalidCredential(1);
        if (expiresAt <= block.timestamp) revert InvalidCredential(2);
        if (expiresAt > block.timestamp + MAX_CREDENTIAL_TTL) revert InvalidCredential(3);
    }

    function _batch(uint256 length) private pure {
        if (length > MAX_BATCH) revert BatchTooLarge(length, MAX_BATCH);
    }

    /// @dev The list part of `check`, and all of `checkCredential`, in order: list, suspension, credential, issuer,
    ///      expiry, tiers; no sanctions.
    function _credentialDecision(State storage s, bytes32 listId, address wallet, uint32 requireAll, uint32 blockAny)
        private
        view
        returns (Decision)
    {
        List memory l = s.lists[listId];
        if (!l.exists) return Decision.UNKNOWN_LIST;
        if (l.suspended) return Decision.LIST_SUSPENDED;
        Credential memory c = s.credentials[listId][wallet];
        if (c.issuer == address(0) || c.expiresAt == 0) return Decision.NO_CREDENTIAL;
        if (!_issuerValid(s, listId, c)) return Decision.ISSUER_REVOKED;
        if (c.expiresAt <= block.timestamp) return Decision.EXPIRED;
        if (c.tiers & requireAll != requireAll) return Decision.MISSING_TIERS;
        if (c.tiers & blockAny != 0) return Decision.BLOCKED_TIERS;
        return Decision.ALLOW;
    }

    /// @dev The issuer is active and the credential was issued after its last void.
    function _issuerValid(State storage s, bytes32 listId, Credential memory c) private view returns (bool) {
        Attester memory issuer = s.attesters[listId][c.issuer];
        return issuer.since != 0 && c.issuedAt >= issuer.validFrom;
    }

    /// @dev An attester may not overwrite another issuer's credential while it still counts.
    function _refuseHeld(State storage s, bytes32 listId, address wallet, Credential storage stored, address writer)
        private
        view
    {
        Credential memory c = stored;
        if (c.issuer == address(0) || c.issuer == writer || c.expiresAt <= block.timestamp) return;
        if (_issuerValid(s, listId, c)) revert CredentialHeld(listId, wallet, c.issuer);
    }

    /// @dev Exactly 32 bytes holding 0 or 1, from a SOURCE_GAS-bounded static call. Anything else is a failure.
    ///      The account access is paid before the gas floor is checked, so the source always receives SOURCE_GAS.
    function _source(address source, address wallet) private view returns (bool listed, bool failed) {
        uint256 size;
        assembly ("memory-safe") {
            size := extcodesize(source)
        }
        if (size == 0) return (false, true);
        uint256 required = SOURCE_GAS + SOURCE_GAS / 63 + 2_000;
        uint256 available = gasleft();
        if (available < required) revert SourceGasTooLow(available, required);
        bytes memory input = abi.encodeCall(ISanctionsList.isSanctioned, (wallet));
        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            ok := staticcall(SOURCE_GAS, source, add(input, 32), mload(input), 0, 32)
            ok := and(ok, eq(returndatasize(), 32))
            word := mload(0)
        }
        if (!ok) {
            available = gasleft();
            if (available < SOURCE_GAS / 63) revert SourceGasTooLow(available, required);
            return (false, true);
        }
        if (word > 1) return (false, true);
        return (word == 1, false);
    }

    /// @dev Grants and resumptions are keyed by subject: a brake voids only the operation on its own subject.
    function _epochKey(bytes32 kind, bytes memory arguments) internal pure override returns (bytes32) {
        if (kind == RESUME_LIST || kind == GRANT_ATTESTER || kind == GRANT_OFFICER || kind == GRANT_GUARDIAN) {
            return _subjectKey(kind, arguments);
        }
        return kind;
    }

    function _subjectKey(bytes32 kind, bytes memory arguments) private pure returns (bytes32) {
        return keccak256(abi.encode(kind, arguments));
    }

    /// @dev Queue-time admission: known kinds with canonical arguments only.
    function _checkQueue(bytes32 kind, bytes calldata arguments) internal view override {
        bytes memory canonical;
        if (kind == CREATE_LIST || kind == RESUME_LIST) {
            bytes32 listId = abi.decode(arguments, (bytes32));
            if (kind == RESUME_LIST && !_state().lists[listId].suspended) revert ListNotSuspended(listId);
            canonical = abi.encode(listId);
        } else if (kind == GRANT_ATTESTER || kind == VOID_CREDENTIALS) {
            (bytes32 listId, address attester) = abi.decode(arguments, (bytes32, address));
            canonical = abi.encode(listId, attester);
        } else if (kind == GRANT_OFFICER || kind == GRANT_GUARDIAN || kind == SET_SANCTIONS_SOURCE) {
            address account = abi.decode(arguments, (address));
            if (kind == GRANT_GUARDIAN) _refuseDelegated(account);
            canonical = abi.encode(account);
        } else if (kind == TRANSFER_OWNER) {
            super._checkQueue(kind, arguments);
            return;
        } else {
            revert UnknownOperation(kind);
        }
        _requireCanonical(kind, arguments, canonical);
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") {
            s.slot := STATE_SLOT
        }
    }
}
