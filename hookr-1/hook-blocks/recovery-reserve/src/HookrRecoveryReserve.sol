// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrLauncherView} from "hookr/interfaces/IHookrLauncherView.sol";
import {IHookrFamilyLock} from "hookr/interfaces/IHookrFamilyLock.sol";
import {IHookrFamilyRelease} from "hookr/interfaces/IHookrFamilyRelease.sol";
import {IHookrRecoveryReserve} from "./interfaces/IHookrRecoveryReserve.sol";

/// @title Hookr Recovery Reserve
/// @notice A small per-pool reserve, funded by a bounded slice of a pool's claims, that tops up LPs or traders
///         after a verified incident. Payouts are gated by a fixed 30-minute timelock after an incident is
///         declared, a reviewer attestation per claim, and per-incident / per-pool caps. Unclaimed funds roll
///         back into the pool's own availability after a bounded window once an incident is closed, and only the
///         pool owner sweeps them out, to the pool's recipient.
/// @dev Standalone periphery, but ownership is never self-declared: `configureReserve` takes the `HookrRoot`
///      the pool is bound to, and every owner-gated call re-derives the real owner from that root rather than
///      trusting `msg.sender` at configure time. Resolution (see `_resolveOwner`): the caller-supplied `root`
///      must be a registered root (`HookrRegistry.isRoot`); `IHookrRoot.poolConfig(id).liquidityOwner`
///      is read from it, which Hookr 1 always sets at bind time and is the same address every recapture claim
///      path (`HookrRecapture.claimPool`) already authenticates against. When that address is itself a
///      registered launcher (`HookrRegistry.isLauncher`), the pool is a launched family member, so the real
///      owner one hop further is `IHookrLauncherView(launcher).familyOwner(launcher.poolFamily(id))`, the
///      family owner, never the launcher contract itself. A family held by the release's `HookrFamilyLock`, or by
///      a `HookrFamilyRelease` that lock created to hand it over, is run here by the lock's beneficiary, who collects
///      the family's fees and releases it: neither contract ever calls this reserve, so without that hop a locked
///      family's reserve would have no one to run it (see `_beneficialOwner`). The launcher a reserve was configured
///      through is remembered (`familyLauncherOf`) so the registry's launcher brake, which stops new pools only, does
///      not hand an existing family's reserve to the launcher contract. The registry never deregisters a root: one it
///      closes or retires stays registered, so existing reserves keep resolving on it. The family owner is never
///      cached and there is no first-caller self-declaration left to front-run: a family-owner transfer moves every
///      owner-gated call at once. Only access control follows a transfer: the stored recipient and reviewer stay as
///      configured until the new owner reconfigures, so a seller sweeps before `transferFamily` and a buyer
///      reconfigures after `acceptFamily`; likewise a locker sweeps before `HookrFamilyLock.lock`, and the
///      beneficiary reconfigures after it.
///
///      The reviewer must attest with an EIP-1271 contract signature (`isValidSignature`) only; a raw
///      ECDSA-recoverable signature from an externally-owned key is never accepted, so a bare EOA reviewer
///      cannot attest. This is the closest on-chain approximation of "reviewer is a Safe, never a 7702
///      account": Solidity has no general way to tell a Safe apart from an EIP-7702-delegated EOA that also
///      exposes `isValidSignature`, so that residual gap is a disclosed limit, not solved
///      here. Both attestations are EIP-712 typed data, `RecoveryIncident` and `RecoveryClaim`, under a domain
///      with a name, the chain id and this reserve's address and no version, recomputed on every call as in
///      `HookrCompliance`, so the reviewer Safe's signers see the pool, incident, cap or claimant, amount and
///      expiry they approve rather than an opaque hash.
contract HookrRecoveryReserve is IHookrRecoveryReserve, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Fixed claim-window timelock, matching the Hookr 1 owner-timelock convention.
    uint32 public constant CLAIM_TIMELOCK = 30 minutes;

    /// @notice Bounded slice of a pool's routed claims that may be swept into its reserve, in bps.
    uint16 public constant MIN_FUNDING_BPS = 0;
    uint16 public constant MAX_FUNDING_BPS = 2_000; // 20%
    uint16 public constant DEFAULT_FUNDING_BPS = 500; // 5%

    /// @notice Share of the current reserve balance a single incident may lock, in bps.
    uint16 public constant MIN_INCIDENT_CAP_BPS = 500; // 5%
    uint16 public constant MAX_INCIDENT_CAP_BPS = 10_000; // 100%
    uint16 public constant DEFAULT_INCIDENT_CAP_BPS = 5_000; // 50%

    /// @notice Absolute per-pool reserve ceiling bounds, written for an 18-decimal asset. They are whole-token
    ///         amounts, not raw base units: `poolCapBounds(token)` scales them to the token's own `decimals()`
    ///         (native ETH is 18), so the same bounds hold for ETH and WETH (18) and USDG (6 on chain 4663). A
    ///         token reporting more than 18 decimals, or no readable `decimals()`, is refused (`InvalidConfig(8)`).
    uint256 public constant MIN_POOL_CAP = 1e15; // 0.001 token
    uint256 public constant MAX_POOL_CAP = 1_000_000e18;
    uint256 public constant DEFAULT_POOL_CAP = 50e18;

    /// @notice How long the claim window stays open once the fixed timelock elapses.
    uint32 public constant MIN_CLAIM_WINDOW = 1 hours;
    uint32 public constant MAX_CLAIM_WINDOW = 30 days;
    uint32 public constant DEFAULT_CLAIM_WINDOW = 7 days;

    /// @notice How long after the claim window closes before unclaimed funds are sweepable.
    uint32 public constant MIN_ROLLBACK_WINDOW = 1 hours;
    uint32 public constant MAX_ROLLBACK_WINDOW = 30 days;
    uint32 public constant DEFAULT_ROLLBACK_WINDOW = 3 days;

    /// @notice Hookr's protocol cut of every reserve payout, in bps. Zero by default: the reserve is meant to
    ///         make victims whole, not to earn revenue, so Hookr takes nothing unless the owner turns this on.
    ///         If it is ever turned on it must clear the 2,000 bps protocol floor like every other fee-charging
    ///         rule.
    uint16 public constant PROTOCOL_SHARE_BPS = 0;

    /// @notice EIP-712 type of the reviewer's incident attestation, signed by `declareIncident`'s reviewer.
    bytes32 public constant INCIDENT_TYPEHASH =
        keccak256("RecoveryIncident(bytes32 poolId,bytes32 incidentId,uint256 cap,uint64 expiry)");
    /// @notice EIP-712 type of the reviewer's claim attestation, signed for each `claim`.
    bytes32 public constant CLAIM_TYPEHASH = keccak256(
        "RecoveryClaim(bytes32 poolId,bytes32 incidentId,address claimant,uint256 amount,uint256 nonce,uint64 expiry)"
    );
    /// @dev The EIP-712 domain has a name, the chain id and the verifying contract, and no version or salt.
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("HookrRecoveryReserve");

    /// @notice The Hookr 1 registry used to check that a caller-supplied root is a real, registered root (and to
    ///         tell a launcher address apart from a plain liquidity owner). Immutable: set once at deploy to the
    ///         canonical Hookr 1 registry.
    IHookrRegistry public immutable registry;

    /// @notice The release's `HookrFamilyLock`. A family it holds, or a family one of its `HookrFamilyRelease`s holds
    ///         until the new owner accepts it, is run here by the lock's beneficiary. Immutable: set once at deploy to
    ///         the canonical Hookr 1 lock.
    address public immutable familyLock;

    mapping(bytes32 poolId => ReserveConfig) public reserves;
    mapping(bytes32 poolId => uint256) public balanceOf;
    mapping(bytes32 poolId => uint256) public lockedOf;
    mapping(bytes32 poolId => mapping(bytes32 incidentId => Incident)) public incidents;
    mapping(
        bytes32 poolId => mapping(bytes32 incidentId => mapping(address claimant => mapping(uint256 nonce => bool)))
    ) public claimed;
    /// @notice Incidents declared against a pool and not yet closed. While this is non-zero the pool's
    ///         configuration is frozen, so a declared incident stays bound to the reviewer, window and rollback
    ///         it was declared under.
    mapping(bytes32 poolId => uint256) public openIncidentsOf;
    /// @notice The registered launcher a launched pool's ownership was resolved through when its reserve was
    ///         last configured, or zero for a pool with a plain liquidity owner. Lets the reserve keep resolving
    ///         the family owner after the registry's launcher brake (`deactivateLauncher`), which stops new pools
    ///         only and leaves existing families as they were.
    mapping(bytes32 poolId => address) public familyLauncherOf;

    constructor(address registry_, address familyLock_) {
        if (registry_ == address(0)) revert InvalidRoot();
        if (familyLock_ == address(0)) revert InvalidFamilyLock();
        registry = IHookrRegistry(registry_);
        familyLock = familyLock_;
    }

    modifier onlyPoolOwner(bytes32 poolId) {
        address root = reserves[poolId].root;
        if (root == address(0)) revert ReserveNotConfigured();
        (address owner,) = _resolveOwner(root, poolId);
        if (msg.sender != owner) revert NotFamilyOwner();
        _;
    }

    /// @notice Resolves the real, current owner of `poolId` as bound on `root`: a registered root's
    ///         `liquidityOwner` for that pool, or, when that address is a registered launcher (or the launcher this
    ///         pool's reserve was configured through, see `familyLauncherOf`), the launched family's current
    ///         owner one hop further, or that family's lock beneficiary while the release's lock or one of its
    ///         releases holds it (`_beneficialOwner`). Also returns the launcher used, or zero. Reverts rather than
    ///         ever returning a value the caller declares; the family owner itself is always read live.
    function _resolveOwner(address root, bytes32 poolId) internal view returns (address, address) {
        if (!registry.isRoot(root)) revert InvalidRoot();
        PoolId id = PoolId.wrap(poolId);
        address owner = IHookrRoot(root).poolConfig(id).liquidityOwner;
        if (owner == address(0)) revert UnknownPool();
        if (owner == familyLauncherOf[poolId] || registry.isLauncher(owner)) {
            bytes32 family = IHookrLauncherView(owner).poolFamily(id);
            if (family != bytes32(0)) {
                address familyOwner = IHookrLauncherView(owner).familyOwner(family);
                if (familyOwner != address(0)) return (_beneficialOwner(owner, family, familyOwner), owner);
            }
        }
        return (owner, address(0));
    }

    /// @dev Who runs the reserve of `family`, launched through `launcher` and owned by `familyOwner`: the family owner,
    ///      unless it is the release's `HookrFamilyLock` holding the family for `launcher`, or a `HookrFamilyRelease`
    ///      that lock created and that holds the family until its new owner accepts it; then the lock's beneficiary.
    ///      A release is told apart by its own `lock()` and `familyId()`. Only a family's owner can hand the family to
    ///      a contract, so a contract that answered them falsely could just as well hand the family to the account
    ///      it names. Any other contract that owns a family runs its reserve itself.
    function _beneficialOwner(address launcher, bytes32 family, address familyOwner) internal view returns (address) {
        address beneficiary;
        if (familyOwner == familyLock) {
            (beneficiary,) = IHookrFamilyLock(familyLock).lockOf(family);
        } else if (
            familyOwner.code.length != 0
                && _firstWord(familyOwner, IHookrFamilyRelease.lock.selector) == uint256(uint160(familyLock))
                && _firstWord(familyOwner, IHookrFamilyRelease.familyId.selector) == uint256(family)
        ) {
            beneficiary = IHookrFamilyRelease(familyOwner).beneficiary();
        }
        if (beneficiary == address(0) || IHookrFamilyLock(familyLock).launcher() != launcher) return familyOwner;
        return beneficiary;
    }

    /// @dev The first word `target` returns for a call of `selector` with no arguments, or zero when the call
    ///      reverts or returns less than a word.
    function _firstWord(address target, bytes4 selector) internal view returns (uint256) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    /// @dev Shared gate for both configure calls. The caller must be the resolved owner; a pool with an open
    ///      incident cannot be reconfigured at all; a pool holding funds cannot change its token or its root,
    ///      because every pool of one asset shares a single custody balance and `balanceOf` is denominated in
    ///      the pool's token. Both configure calls are `nonReentrant`, so a token's `transferFrom` running inside
    ///      `fundReserve` cannot switch the pool's token while its first funding is still unbooked. Funding is
    ///      permissionless, so anyone can book dust between an owner's sweep to zero and the switch; an owner
    ///      switches token or root after `setActive(false)` (which stops funding) and a sweep, or sweeps and
    ///      configures in one transaction. Either configure call sets the pool active again.
    function _checkConfigure(bytes32 poolId, address root, address token) internal {
        (address owner, address launcher) = _resolveOwner(root, poolId);
        if (msg.sender != owner) revert NotFamilyOwner();
        if (openIncidentsOf[poolId] != 0) revert IncidentOpen();
        ReserveConfig storage current = reserves[poolId];
        if (balanceOf[poolId] != 0 && (token != current.token || root != current.root)) revert ReserveHoldsFunds();
        familyLauncherOf[poolId] = launcher;
    }

    /// @notice The `perPoolCap` bounds and default for `token`, in that token's smallest unit: the 18-decimal
    ///         `MIN_POOL_CAP`, `MAX_POOL_CAP` and `DEFAULT_POOL_CAP` divided by `10 ** (18 - decimals)`, with the
    ///         minimum never below one base unit. Native ETH (`token == address(0)`) uses the constants as they
    ///         are. Reverts `InvalidConfig(8)` when `decimals()` cannot be read or exceeds 18.
    function poolCapBounds(address token) public view returns (uint256 minCap, uint256 maxCap, uint256 defaultCap) {
        uint256 scale = 1;
        if (token != address(0)) {
            (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20Metadata.decimals.selector));
            if (!ok || data.length < 32) revert InvalidConfig(8);
            uint256 decimals_ = abi.decode(data, (uint256));
            if (decimals_ > 18) revert InvalidConfig(8);
            scale = 10 ** (18 - decimals_);
        }
        minCap = MIN_POOL_CAP / scale;
        if (minCap == 0) minCap = 1;
        maxCap = MAX_POOL_CAP / scale;
        defaultCap = DEFAULT_POOL_CAP / scale;
    }

    /// @notice Resolves `poolId`'s current real owner the same way every owner-gated call does: for a family the
    ///         release's lock holds, the lock's beneficiary. Returns `address(0)` when the pool has no reserve
    ///         configured yet.
    function poolOwner(bytes32 poolId) external view returns (address) {
        address root = reserves[poolId].root;
        if (root == address(0)) return address(0);
        (address owner,) = _resolveOwner(root, poolId);
        return owner;
    }

    /// @notice Configures (or reconfigures) a pool's reserve. `root` is the `HookrRoot` this pool is bound to;
    ///         only the pool's real owner as resolved from that root (see `_resolveOwner`) may call this, both
    ///         the first time and on every later reconfiguration; there is no first-caller self-declaration.
    ///         `recipient` may be neither zero nor this reserve (`InvalidConfig(0)`): a sweep to the reserve itself
    ///         would leave the tokens in custody with no pool booking them.
    function configureReserve(
        bytes32 poolId,
        address root,
        address token,
        address reviewer,
        address recipient,
        uint16 fundingBps,
        uint16 perIncidentCapBps,
        uint256 perPoolCap,
        uint32 claimWindow,
        uint32 rollbackWindow
    ) external nonReentrant {
        _checkConfigure(poolId, root, token);
        if (reviewer == address(0) || reviewer.code.length == 0) revert InvalidReviewer();
        if (recipient == address(0) || recipient == address(this)) revert InvalidConfig(0);
        if (fundingBps > MAX_FUNDING_BPS) revert InvalidConfig(1);
        if (perIncidentCapBps < MIN_INCIDENT_CAP_BPS || perIncidentCapBps > MAX_INCIDENT_CAP_BPS) {
            revert InvalidConfig(2);
        }
        (uint256 minCap, uint256 maxCap,) = poolCapBounds(token);
        if (perPoolCap < minCap || perPoolCap > maxCap) revert InvalidConfig(3);
        if (claimWindow < MIN_CLAIM_WINDOW || claimWindow > MAX_CLAIM_WINDOW) revert InvalidConfig(4);
        if (rollbackWindow < MIN_ROLLBACK_WINDOW || rollbackWindow > MAX_ROLLBACK_WINDOW) revert InvalidConfig(5);

        reserves[poolId] = ReserveConfig({
            token: token,
            reviewer: reviewer,
            recipient: recipient,
            root: root,
            fundingBps: fundingBps,
            perIncidentCapBps: perIncidentCapBps,
            perPoolCap: perPoolCap,
            claimWindow: claimWindow,
            rollbackWindow: rollbackWindow,
            active: true
        });

        emit ReserveConfigured(
            poolId,
            token,
            reviewer,
            recipient,
            root,
            fundingBps,
            perIncidentCapBps,
            perPoolCap,
            claimWindow,
            rollbackWindow
        );
    }

    /// @notice Convenience configure call using every DEFAULT_* knob. Same ownership check as `configureReserve`.
    function configureReserveWithDefaults(
        bytes32 poolId,
        address root,
        address token,
        address reviewer,
        address recipient
    ) external nonReentrant {
        _checkConfigure(poolId, root, token);
        if (reviewer == address(0) || reviewer.code.length == 0) revert InvalidReviewer();
        if (recipient == address(0) || recipient == address(this)) revert InvalidConfig(0);
        (,, uint256 defaultCap) = poolCapBounds(token);

        reserves[poolId] = ReserveConfig({
            token: token,
            reviewer: reviewer,
            recipient: recipient,
            root: root,
            fundingBps: DEFAULT_FUNDING_BPS,
            perIncidentCapBps: DEFAULT_INCIDENT_CAP_BPS,
            perPoolCap: defaultCap,
            claimWindow: DEFAULT_CLAIM_WINDOW,
            rollbackWindow: DEFAULT_ROLLBACK_WINDOW,
            active: true
        });

        emit ReserveConfigured(
            poolId,
            token,
            reviewer,
            recipient,
            root,
            DEFAULT_FUNDING_BPS,
            DEFAULT_INCIDENT_CAP_BPS,
            defaultCap,
            DEFAULT_CLAIM_WINDOW,
            DEFAULT_ROLLBACK_WINDOW
        );
    }

    /// @notice Stops or resumes a pool's funding and new incidents. Claims, closes and sweeps run either way, so
    ///         deactivating never traps funds or claimants; either configure call sets the pool active again.
    function setActive(bytes32 poolId, bool active) external onlyPoolOwner(poolId) {
        reserves[poolId].active = active;
        emit ReserveActivated(poolId, active);
    }

    /// @notice Adds funds to a pool's reserve, up to its `perPoolCap`. Anyone may call this; the bound on how
    ///         much of the pool's claims this represents (`fundingBps`) is enforced by whoever routes the
    ///         claims slice in, since this contract has no visibility into the claims source. `msg.value` is
    ///         used when the reserve token is native ETH (`token == address(0)`), otherwise `amount` is pulled
    ///         via `transferFrom`. The funder names the token it means to pay in, and the call reverts
    ///         (`TokenMismatch`) if the pool is configured with any other token when it executes, so an owner
    ///         who switches an emptied reserve's token can never make a pending top-up pull a different asset.
    ///         A top-up that would pass `perPoolCap` is filled up to the cap: an ERC-20 top-up pulls only the room
    ///         left, and a native top-up refunds the excess to the caller. It reverts `InvalidConfig(7)` only
    ///         when the pool is already at its cap.
    function fundReserve(bytes32 poolId, address token, uint256 amount) external payable nonReentrant {
        ReserveConfig memory cfg = reserves[poolId];
        if (cfg.root == address(0)) revert ReserveNotConfigured();
        if (!cfg.active) revert ReserveNotActive();
        if (token != cfg.token) revert TokenMismatch();

        uint256 balance = balanceOf[poolId];
        if (balance >= cfg.perPoolCap) revert InvalidConfig(7);
        uint256 room = cfg.perPoolCap - balance;

        uint256 received;
        uint256 refund;
        if (cfg.token == address(0)) {
            received = msg.value;
            if (received > room) {
                refund = received - room;
                received = room;
            }
        } else {
            if (msg.value != 0) revert InvalidConfig(6);
            if (amount == 0) revert ZeroAmount();
            uint256 pull = amount < room ? amount : room;
            uint256 before = IERC20(cfg.token).balanceOf(address(this));
            IERC20(cfg.token).safeTransferFrom(msg.sender, address(this), pull);
            received = IERC20(cfg.token).balanceOf(address(this)) - before;
        }
        if (received == 0) revert ZeroAmount();

        uint256 newBalance = balance + received;
        if (newBalance > cfg.perPoolCap) revert InvalidConfig(7);
        balanceOf[poolId] = newBalance;

        emit ReserveFunded(poolId, msg.sender, received, newBalance);

        if (refund != 0) _payout(address(0), msg.sender, refund);
    }

    /// @notice Declares an incident against `poolId`'s reserve. The reviewer attests to the incident id and the
    ///         cap it may pay out (EIP-712 `RecoveryIncident`, see `incidentDigest`); the claim window opens
    ///         `CLAIM_TIMELOCK` after this call, bounding how fast a reserve can be drained after a single
    ///         attestation. The declared cap locks that much of the reserve balance (bounded by
    ///         `perIncidentCapBps` of what is currently unlocked) so concurrent incidents cannot double-spend the
    ///         same funds.
    function declareIncident(
        bytes32 poolId,
        bytes32 incidentId,
        uint256 requestedCap,
        uint64 expiry,
        bytes calldata attestation
    ) external onlyPoolOwner(poolId) {
        ReserveConfig memory cfg = reserves[poolId];
        if (!cfg.active) revert ReserveNotActive();
        Incident storage inc = incidents[poolId][incidentId];
        if (inc.openAt != 0) revert IncidentAlreadyOpen();
        if (block.timestamp > expiry) revert AttestationExpired();

        bytes32 digest = incidentDigest(poolId, incidentId, requestedCap, expiry);
        _requireReviewerAttestation(cfg.reviewer, digest, attestation);

        uint256 available = balanceOf[poolId] - lockedOf[poolId];
        uint256 ceiling = (available * cfg.perIncidentCapBps) / 10_000;
        uint256 cap = requestedCap < ceiling ? requestedCap : ceiling;
        if (cap == 0) revert InsufficientReserve();

        lockedOf[poolId] += cap;
        openIncidentsOf[poolId] += 1;

        uint64 opensAt = uint64(block.timestamp) + CLAIM_TIMELOCK;
        uint64 closesAt = opensAt + cfg.claimWindow;
        inc.openAt = uint64(block.timestamp);
        inc.claimsOpenAt = opensAt;
        inc.claimsCloseAt = closesAt;
        inc.cap = cap;

        emit IncidentDeclared(poolId, incidentId, opensAt, closesAt, cap);
    }

    /// @notice Pays out one claim against an open incident. Every claim needs its own reviewer attestation over
    ///         `(poolId, incidentId, claimant, amount, nonce, expiry)` (EIP-712 `RecoveryClaim`, see
    ///         `claimDigest`); `nonce` lets the reviewer split one claimant's entitlement across several payouts
    ///         while replay of the same digest is still blocked. `claimant` may be neither zero nor this reserve
    ///         (`InvalidClaimant`), so an attested payout can never be burned or left unbooked in custody.
    function claim(
        bytes32 poolId,
        bytes32 incidentId,
        address claimant,
        uint256 amount,
        uint256 nonce,
        uint64 expiry,
        bytes calldata attestation
    ) external nonReentrant {
        ReserveConfig memory cfg = reserves[poolId];
        Incident storage inc = incidents[poolId][incidentId];
        if (inc.openAt == 0) revert IncidentNotOpen();
        if (inc.closed) revert IncidentClosedAlready();
        if (block.timestamp < inc.claimsOpenAt || block.timestamp > inc.claimsCloseAt) revert ClaimWindowNotOpen();
        if (amount == 0) revert ZeroAmount();
        if (claimant == address(0) || claimant == address(this)) revert InvalidClaimant();
        if (block.timestamp > expiry) revert AttestationExpired();
        if (claimed[poolId][incidentId][claimant][nonce]) revert ClaimAlreadyPaid();

        bytes32 digest = claimDigest(poolId, incidentId, claimant, amount, nonce, expiry);
        _requireReviewerAttestation(cfg.reviewer, digest, attestation);

        if (inc.paid + amount > inc.cap) revert ClaimExceedsCap();
        claimed[poolId][incidentId][claimant][nonce] = true;
        inc.paid += amount;
        balanceOf[poolId] -= amount;
        lockedOf[poolId] -= amount;

        _payout(cfg.token, claimant, amount);

        emit IncidentClaimed(poolId, incidentId, claimant, amount, nonce);
    }

    /// @notice Closes an incident once its claim window and then the pool's `rollbackWindow` have passed,
    ///         releasing whatever of its cap went unpaid back to the pool's general (unlocked) reserve balance.
    ///         Callable by anyone so a slow or absent family owner can never trap funds. `rollbackWindow` cannot
    ///         change while the incident is open (see `openIncidentsOf`).
    function closeIncident(bytes32 poolId, bytes32 incidentId) external {
        Incident storage inc = incidents[poolId][incidentId];
        if (inc.openAt == 0) revert IncidentNotOpen();
        if (inc.closed) revert IncidentClosedAlready();
        if (block.timestamp <= inc.claimsCloseAt) revert ClaimWindowStillOpen();
        if (block.timestamp <= uint256(inc.claimsCloseAt) + reserves[poolId].rollbackWindow) {
            revert RollbackWindowOpen();
        }

        uint256 unpaid = inc.cap - inc.paid;
        lockedOf[poolId] -= unpaid;
        openIncidentsOf[poolId] -= 1;
        inc.closed = true;
        inc.closedAt = uint64(block.timestamp);

        emit IncidentClosed(poolId, incidentId, inc.paid, unpaid);
    }

    /// @notice Sweeps unlocked reserve funds to the pool's configured recipient. Only callable by the pool
    ///         owner. Funds locked by an open incident (`lockedOf`) can never be swept, and an incident only
    ///         releases its unpaid cap once `rollbackWindow` has passed after its claim window (`closeIncident`),
    ///         so unclaimed incident funds reach the recipient no earlier than that.
    function sweepReserve(bytes32 poolId, uint256 amount) external onlyPoolOwner(poolId) nonReentrant {
        ReserveConfig memory cfg = reserves[poolId];
        uint256 available = balanceOf[poolId] - lockedOf[poolId];
        if (amount == 0 || amount > available) revert InsufficientReserve();

        balanceOf[poolId] -= amount;
        _payout(cfg.token, cfg.recipient, amount);

        emit ReserveSwept(poolId, cfg.recipient, amount);
    }

    /// @notice The EIP-712 digest the reviewer signs to attest an incident: a `RecoveryIncident` under
    ///         `DOMAIN_SEPARATOR()`.
    function incidentDigest(bytes32 poolId, bytes32 incidentId, uint256 cap, uint64 expiry)
        public
        view
        returns (bytes32)
    {
        return _hashTypedData(keccak256(abi.encode(INCIDENT_TYPEHASH, poolId, incidentId, cap, expiry)));
    }

    /// @notice The EIP-712 digest the reviewer signs to attest one claim: a `RecoveryClaim` under
    ///         `DOMAIN_SEPARATOR()`.
    function claimDigest(
        bytes32 poolId,
        bytes32 incidentId,
        address claimant,
        uint256 amount,
        uint256 nonce,
        uint64 expiry
    ) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(abi.encode(CLAIM_TYPEHASH, poolId, incidentId, claimant, amount, nonce, expiry))
        );
    }

    /// @notice The EIP-712 domain separator of every reviewer attestation: name `HookrRecoveryReserve`, this
    ///         chain's id and this reserve's address. Recomputed on every call.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, block.chainid, address(this)));
    }

    /// @notice ERC-5267 description of the EIP-712 domain, for wallets and the reviewer Safe's interface.
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
        return (hex"0d", "HookrRecoveryReserve", "", block.chainid, address(this), bytes32(0), new uint256[](0));
    }

    /// @notice `poolId`'s balance that no open incident locks: what `sweepReserve` may move, and what a new
    ///         incident's cap is a share of.
    function availableOf(bytes32 poolId) external view returns (uint256) {
        return balanceOf[poolId] - lockedOf[poolId];
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR(), structHash));
    }

    /// @dev Accepts only an EIP-1271 contract signature from `reviewer`; a plain ECDSA-recoverable signature is
    ///      never checked, so an externally-owned reviewer key cannot attest by itself. `reviewer` is also
    ///      required to already carry code at configure time (see `configureReserve`).
    function _requireReviewerAttestation(address reviewer, bytes32 digest, bytes calldata signature) internal view {
        if (reviewer.code.length == 0) revert InvalidReviewer();
        (bool ok, bytes memory ret) =
            reviewer.staticcall(abi.encodeCall(IERC1271.isValidSignature, (digest, signature)));
        if (!ok || ret.length < 32) revert BadAttestation();
        if (abi.decode(ret, (bytes4)) != IERC1271.isValidSignature.selector) revert BadAttestation();
    }

    function _payout(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // Deliberately no `receive()`: native funding must go through `fundReserve` so every wei is accounted for
    // in `balanceOf`. A plain ETH send with empty calldata reverts instead of becoming untracked balance.
}
