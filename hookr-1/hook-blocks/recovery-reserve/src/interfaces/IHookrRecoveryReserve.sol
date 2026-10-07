// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Recovery Reserve interface
/// @notice A small per-pool reserve, funded by a bounded slice of a pool's claims, that can top up LPs or
///         traders after a verified incident. Payouts only happen inside a timelocked claim window and only
///         against a reviewer's signed attestation; unclaimed funds roll back to the pool's recipient after a
///         bounded window.
interface IHookrRecoveryReserve {
    /// @notice Per-pool reserve configuration. `token == address(0)` means native ETH. `root` is the Hookr 1
    ///         `HookrRoot` this pool is bound to; ownership is re-derived from it (never cached) on every
    ///         owner-gated call, so a family-owner transfer upstream moves access control here at once. `recipient`
    ///         and `reviewer` stay as configured until the new owner reconfigures.
    struct ReserveConfig {
        address token;
        address reviewer;
        address recipient;
        address root;
        uint16 fundingBps;
        uint16 perIncidentCapBps;
        uint256 perPoolCap;
        uint32 claimWindow;
        uint32 rollbackWindow;
        bool active;
    }

    /// @notice One declared incident against a pool's reserve.
    struct Incident {
        uint64 openAt;
        uint64 claimsOpenAt;
        uint64 claimsCloseAt;
        uint64 closedAt;
        uint256 cap;
        uint256 paid;
        bool closed;
    }

    event ReserveConfigured(
        bytes32 indexed poolId,
        address token,
        address reviewer,
        address recipient,
        address root,
        uint16 fundingBps,
        uint16 perIncidentCapBps,
        uint256 perPoolCap,
        uint32 claimWindow,
        uint32 rollbackWindow
    );
    event ReserveActivated(bytes32 indexed poolId, bool active);
    event ReserveFunded(bytes32 indexed poolId, address indexed funder, uint256 amount, uint256 balance);
    event IncidentDeclared(
        bytes32 indexed poolId, bytes32 indexed incidentId, uint64 claimsOpenAt, uint64 claimsCloseAt, uint256 cap
    );
    event IncidentClaimed(
        bytes32 indexed poolId, bytes32 indexed incidentId, address indexed claimant, uint256 amount, uint256 nonce
    );
    event IncidentClosed(bytes32 indexed poolId, bytes32 indexed incidentId, uint256 paid, uint256 releasedToReserve);
    event ReserveSwept(bytes32 indexed poolId, address indexed recipient, uint256 amount);

    error NotFamilyOwner();
    error ReserveNotActive();
    error ReserveNotConfigured();
    error InvalidConfig(uint8 reason);
    error InvalidReviewer();
    error InvalidRoot();
    error InvalidFamilyLock();
    error UnknownPool();
    error InsufficientReserve();
    error IncidentAlreadyOpen();
    error IncidentNotOpen();
    error IncidentClosedAlready();
    error ClaimWindowNotOpen();
    error ClaimWindowStillOpen();
    error ClaimExceedsCap();
    error ClaimAlreadyPaid();
    error InvalidClaimant();
    error BadAttestation();
    error AttestationExpired();
    error ZeroAmount();
    error NativeTransferFailed();
    error ReserveHoldsFunds();
    error IncidentOpen();
    error RollbackWindowOpen();
    error TokenMismatch();
}
