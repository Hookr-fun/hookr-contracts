// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Module marketplace types
/// @notice Shared enums and structs of the bonded module marketplace.
/// @dev The design source is the app's
///      `src/lib/module-market.ts` (hookr-org/main 565bed7b); every constant mirrors it and is an opening
///      number for owner review, not a final requirement.
library ModuleMarketTypes {
    /// @notice What a module can reach, and so how much $HOOKR must stand behind it.
    /// @dev READ: reads and emits only. PARAMS: sets numbers the pool already applies (fees, takes, a reject).
    ///      ASSETS: moves value that already exists. CREDIT: creates obligations (borrowing, liquidation).
    ///      A phase-one advisory is PARAMS in substance: it can always refuse a swap, so the market publishes none
    ///      below PARAMS (`ModuleMarketMath.MIN_TIER`) and READ waits for a slot that cannot refuse. ASSETS and
    ///      CREDIT are declared by the developer for modules that will run in later Hookr 1 slots (lane, custody
    ///      class).
    enum RiskTier {
        READ,
        PARAMS,
        ASSETS,
        CREDIT
    }

    /// @notice Coarse, published reputation bands. Reputation reduces the bond; it never removes it.
    enum Band {
        NEW,
        ESTABLISHED,
        TRUSTED
    }

    /// @notice Version lifecycle.
    /// @dev LISTED: accepts bonds and (when bonded) installs, both only while no slash is pending. EXITING: notice
    ///      given, no new installs, bonds locked until exposure ends plus the cooldown. RELEASED: bonds withdrawable.
    ///      TERMINATED: the whole bond was slashed; nothing is installable and stakers can only collect earned fees.
    enum Status {
        NONE,
        LISTED,
        EXITING,
        RELEASED,
        TERMINATED
    }

    /// @notice The only grounds a bond can be slashed on. There is deliberately no member for a price fall,
    ///         a liquidation, unpopularity, a dried-up fee stream or a market going to zero.
    enum SlashReason {
        MALICIOUS_CODE,
        DENIED_ASSET_MOVE,
        PERMISSION_BOUNDARY,
        ORACLE_MANIPULATION,
        UNDISCLOSED_UPGRADE,
        CRITICAL_INVARIANT
    }

    /// @notice Slash proposal state.
    enum SlashStatus {
        NONE,
        PENDING,
        EXECUTED,
        VETOED,
        EXPIRED
    }

    /// @notice How an install stopped counting as live exposure.
    enum CloseReason {
        OWNER,
        DRAINED
    }

    /// @notice The on-chain half of a module's permission manifest. The full can/cannot document is committed
    ///         by `manifestHash` on the version.
    /// @dev Enforced at install: the registry admission the root will apply must be no wider than these
    ///      numbers (caps and phases), so the root's own bounds are the manifest's bounds. `mayReject` is a
    ///      declaration only: any phase-one advisory can return `reject` (a strict one refuses the swap, a fail-open
    ///      one reverts it), so a module that declares `mayReject = false` and rejects anyway has reached past its
    ///      manifest, which is slashable. It does not lower the tier: every version is at least PARAMS, so a bond of
    ///      at least that tier's floor stands behind the declaration.
    struct Manifest {
        uint24 maxLpFeeSurchargePips;
        uint24 maxQuoteTakePips;
        uint8 phaseMask;
        bool mayReject;
    }

    /// @notice Where a module's usage fee goes, in basis points of every collected amount. Frozen per version.
    /// @dev developer 20-60% and backers 10-40% (static bounds), protocol and reserve exactly the market's frozen
    ///      `protocolBps` and `reserveBps`, total 100%. With the defaults (protocol 20%, reserve 10%) the reachable
    ///      developer share is 30-60%; the market's `developerShareBounds` returns the reachable range.
    struct Split {
        uint16 developerBps;
        uint16 backersBps;
        uint16 protocolBps;
        uint16 reserveBps;
    }

    /// @notice One published version of a module. Only the lifecycle fields change after publish.
    struct Version {
        address module;
        bytes32 moduleId;
        uint32 number;
        RiskTier tier;
        Status status;
        bytes32 codeHash;
        bytes32 manifestHash;
        Manifest manifest;
        Split split;
        address feeAccount;
        uint64 publishedAt;
        uint64 exitRequestedAt;
        uint64 drainedAt;
        uint32 liveInstalls;
        uint32 totalInstalls;
        uint16 pendingSlashes;
    }

    /// @notice One pool that froze a marketplace module at creation.
    /// @param versionId The installed version.
    /// @param root The Hookr root that initialized the pool.
    /// @param launcher The registered launcher that owned the pool's launch liquidity, or zero.
    /// @param installedAt When the pool was initialized.
    /// @param live True until the market's owner closes it or its liquidity is proven drained.
    struct Install {
        uint64 versionId;
        address root;
        address launcher;
        uint64 installedAt;
        bool live;
    }

    /// @notice A published, timelocked, vetoable slash.
    struct SlashProposal {
        uint64 versionId;
        uint16 bps;
        SlashReason reason;
        SlashStatus status;
        uint48 readyAt;
        address recipient;
        bytes32 evidenceHash;
    }
}
