// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {HookrAttributionTypes as T} from "./types/HookrAttributionTypes.sol";
import {IHookrPartnerRegistry} from "./interfaces/IHookrPartnerRegistry.sol";
import {IHookrPartnerRevenueVault} from "./interfaces/IHookrPartnerRevenueVault.sol";

/// @title Hookr partner registry
/// @notice Registered integration partners, one-time EIP-712 market vouchers, and the permanent attribution
///         record of every pool opened through the attribution launcher.
/// @dev This is the non-root "sidecar registry" of the Hookr 1 design: the voucher's semantics belong to the launcher and this registry, never to the
///      root. Nothing here is read on the swap path.
///
///      Authority. The owner timelock is a fixed `DELAY` of 30 minutes, the same wait as the Hookr 1 registry and
///      every governed contract. Adding power waits it: a partner is admitted only by a proposal the owner can
///      activate `DELAY` later, and an ownership nomination can be accepted only `DELAY` after it was made.
///      Removing power is immediate: retirement is immediate and permanent, and a nomination is withdrawn at once.
///      Retirement blocks new vouchers and never rewrites an existing attribution. The launcher is bound once. The
///      owner, a nominee and the accepting account are never an EIP-7702 delegated account. The owner cannot touch
///      any vault, any split or any pool.
///
///      Economics. The partner share is carved from the Hookr treasury share (30% minus the partner share),
///      never from the creator's fixed 60% or the buy/burn 10%. The share must equal the partner's registered
///      share, inside the inclusive 20%-25% range. A direct market (partnerId zero) pays no partner.
contract HookrPartnerRegistry is EIP712, IHookrPartnerRegistry {
    /// @notice EIP-712 type of `HookrAttributionTypes.Voucher`.
    bytes32 public constant VOUCHER_TYPEHASH = keccak256(
        "AttributionVoucher(bytes32 partnerId,address launcher,address root,address caller,bytes32 poolId,bytes32 stackHash,address creatorBeneficiary,uint24 buyTaxPips,uint24 sellTaxPips,uint16 partnerShareBps,uint256 nonce,uint256 deadline)"
    );
    /// @notice Domain of `termsHash`.
    bytes32 public constant TERMS_DOMAIN = keccak256("HOOKR_LAB_BUILDER_ATTRIBUTION_TERMS_V1");
    /// @notice The owner timelock: the wait between a partner proposal and its activation, and between an ownership
    ///         nomination and its acceptance. Fixed at 30 minutes.
    uint48 public constant DELAY = 30 minutes;
    /// @notice Inclusive bounds of a registered partner's share of every harvested amount, in basis points. The
    ///         share is set per partner by the owner, not per pool.
    uint16 public constant MIN_PARTNER_SHARE_BPS = T.MIN_PARTNER_SHARE_BPS;
    uint16 public constant MAX_PARTNER_SHARE_BPS = T.MAX_PARTNER_SHARE_BPS;
    /// @notice The share the onboarding flow pre-fills. The partner share is carved from the treasury's 3,000, so the
    ///         treasury keeps 500 to 1,000 and the creator's 6,000 and the buy/burn 1,000 never change.
    uint16 public constant DEFAULT_PARTNER_SHARE_BPS = T.DEFAULT_PARTNER_SHARE_BPS;
    /// @inheritdoc IHookrPartnerRegistry
    address public immutable treasuryBeneficiary;
    /// @inheritdoc IHookrPartnerRegistry
    address public immutable buyBurnBeneficiary;

    /// @notice Registry administrator: proposes, activates and retires partners and binds the launcher once.
    address public owner;
    /// @notice Nominated successor, or zero.
    address public pendingOwner;
    /// @notice Earliest block.timestamp at which `pendingOwner` can accept; zero without a nomination.
    uint48 public pendingOwnerReadyAt;
    /// @notice The only launcher that can consume vouchers. Zero until bound.
    address public launcher;

    mapping(bytes32 => T.Partner) private _partners;
    /// @notice Whether a signer's nonce has been consumed.
    mapping(address => mapping(uint256 => bool)) public nonceUsed;
    mapping(bytes32 => T.Attribution) private _attributions;
    mapping(bytes32 => bytes32[]) private _partnerPools;

    error NotOwner();
    error NotPendingOwner();
    error NotLauncher();
    error InvalidAddress();
    error OwnerNotReady(uint48 readyAt);
    error DelegatedAccount(address account);
    error LauncherAlreadyBound();
    error InvalidPartner();
    error PartnerExists(bytes32 partnerId);
    error UnknownPartner(bytes32 partnerId);
    error PartnerNotReady(bytes32 partnerId, uint48 readyAt);
    error PartnerNotActive(bytes32 partnerId);
    error PartnerIsRetired(bytes32 partnerId);
    error InvalidVoucher();
    error InvalidTax();
    error ShareMismatch(uint16 voucherShare, uint16 registeredShare);
    error VoucherExpired(uint256 deadline);
    error VoucherUsed(address signer, uint256 nonce);
    error InvalidSignature();
    error PoolAlreadyAttributed(bytes32 poolId);
    error VaultMismatch(address vault);

    event OwnerProposed(address indexed owner, address indexed nominee, uint48 readyAt);
    event OwnerSet(address indexed previous, address indexed owner);
    event LauncherBound(address indexed launcher);
    event PartnerProposed(
        bytes32 indexed partnerId, address indexed signer, address indexed beneficiary, uint16 shareBps, uint48 readyAt
    );
    event PartnerActivated(bytes32 indexed partnerId);
    event PartnerRetired(bytes32 indexed partnerId);
    event VoucherConsumed(
        bytes32 indexed poolId, bytes32 indexed partnerId, address indexed signer, uint256 nonce, bytes32 digest
    );
    event PoolAttributed(
        bytes32 indexed poolId,
        bytes32 indexed partnerId,
        address indexed vault,
        address root,
        address caller,
        address creatorBeneficiary,
        address partnerBeneficiary,
        uint24 buyTaxPips,
        uint24 sellTaxPips,
        uint16 partnerShareBps,
        bytes32 stackHash,
        bytes32 termsHash
    );

    /// @param owner_ Initial administrator (not an EIP-7702 delegated account)
    /// @param treasury Initial treasury payee of every vault
    /// @param buyBurn Initial HOOKR buy/burn payee of every vault
    constructor(address owner_, address treasury, address buyBurn) EIP712("Hookr Attribution", "1") {
        if (owner_ == address(0) || treasury == address(0) || buyBurn == address(0)) revert InvalidAddress();
        _refuseDelegated(owner_);
        owner = owner_;
        treasuryBeneficiary = treasury;
        buyBurnBeneficiary = buyBurn;
        emit OwnerSet(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Nominates a new owner, who can accept `DELAY` later; zero withdraws a nomination at once.
    function proposeOwner(address nominee) external onlyOwner {
        uint48 readyAt;
        if (nominee != address(0)) {
            _refuseDelegated(nominee);
            readyAt = uint48(block.timestamp) + DELAY;
        }
        pendingOwner = nominee;
        pendingOwnerReadyAt = readyAt;
        emit OwnerProposed(msg.sender, nominee, readyAt);
    }

    /// @notice Accepts a pending ownership nomination, `DELAY` after it was made.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner || msg.sender == address(0)) revert NotPendingOwner();
        if (block.timestamp < pendingOwnerReadyAt) revert OwnerNotReady(pendingOwnerReadyAt);
        _refuseDelegated(msg.sender);
        emit OwnerSet(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
        pendingOwnerReadyAt = 0;
    }

    /// @notice Binds the only launcher that may consume vouchers. Once.
    /// @dev The launcher must already point at this registry; a mismatched launcher would record nothing usable.
    function bindLauncher(address launcher_) external onlyOwner {
        if (launcher != address(0)) revert LauncherAlreadyBound();
        if (launcher_.code.length == 0) revert InvalidAddress();
        (bool ok, bytes memory out) = launcher_.staticcall(abi.encodeWithSignature("partnerRegistry()"));
        if (!ok || out.length != 32 || abi.decode(out, (address)) != address(this)) revert InvalidAddress();
        launcher = launcher_;
        emit LauncherBound(launcher_);
    }

    /// @notice Proposes a new partner. It can authorize vouchers only after `activatePartner`, `DELAY` later.
    /// @param partnerId Nonzero id, never reused
    /// @param signer Voucher signer (EOA, EIP-7702 account or ERC-1271 contract)
    /// @param beneficiary Initial partner payee of every vault this partner is attributed to
    /// @param shareBps The partner's share, 2,000 to 2,500 basis points inclusive
    function proposePartner(bytes32 partnerId, address signer, address beneficiary, uint16 shareBps)
        external
        onlyOwner
    {
        if (
            partnerId == bytes32(0) || signer == address(0) || beneficiary == address(0)
                || shareBps < T.MIN_PARTNER_SHARE_BPS || shareBps > T.MAX_PARTNER_SHARE_BPS
        ) revert InvalidPartner();
        if (_partners[partnerId].signer != address(0)) revert PartnerExists(partnerId);
        uint48 readyAt = uint48(block.timestamp) + DELAY;
        _partners[partnerId] = T.Partner(signer, beneficiary, shareBps, readyAt, false, false);
        emit PartnerProposed(partnerId, signer, beneficiary, shareBps, readyAt);
    }

    /// @notice Activates a proposed partner `DELAY` after its proposal.
    function activatePartner(bytes32 partnerId) external onlyOwner {
        T.Partner storage p = _partners[partnerId];
        if (p.signer == address(0)) revert UnknownPartner(partnerId);
        if (p.retired) revert PartnerIsRetired(partnerId);
        if (p.active) revert PartnerExists(partnerId);
        if (block.timestamp < p.readyAt) revert PartnerNotReady(partnerId, p.readyAt);
        p.active = true;
        emit PartnerActivated(partnerId);
    }

    /// @notice Retires a partner at once and forever: no new vouchers. Existing attributions and vaults are untouched.
    function retirePartner(bytes32 partnerId) external onlyOwner {
        T.Partner storage p = _partners[partnerId];
        if (p.signer == address(0)) revert UnknownPartner(partnerId);
        if (p.retired) revert PartnerIsRetired(partnerId);
        p.active = false;
        p.retired = true;
        emit PartnerRetired(partnerId);
    }

    /// @inheritdoc IHookrPartnerRegistry
    function partner(bytes32 partnerId) external view returns (T.Partner memory) {
        return _partners[partnerId];
    }

    /// @inheritdoc IHookrPartnerRegistry
    function attribution(bytes32 poolId) external view returns (T.Attribution memory) {
        return _attributions[poolId];
    }

    /// @notice Number of pools attributed to a partner (zero id: direct markets).
    function partnerPoolCount(bytes32 partnerId) external view returns (uint256) {
        return _partnerPools[partnerId].length;
    }

    /// @notice The `index`-th pool attributed to a partner.
    function partnerPoolAt(bytes32 partnerId, uint256 index) external view returns (bytes32) {
        return _partnerPools[partnerId][index];
    }

    /// @notice The EIP-712 domain separator vouchers are signed under.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice The EIP-712 digest a partner signs for `v`.
    function voucherDigest(T.Voucher calldata v) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    VOUCHER_TYPEHASH,
                    v.partnerId,
                    v.launcher,
                    v.root,
                    v.caller,
                    v.poolId,
                    v.stackHash,
                    v.creatorBeneficiary,
                    v.buyTaxPips,
                    v.sellTaxPips,
                    v.partnerShareBps,
                    v.nonce,
                    v.deadline
                )
            )
        );
    }

    /// @inheritdoc IHookrPartnerRegistry
    /// @dev Checks, in order: the bound launcher is calling, the voucher names it, `caller`, a root and a fresh
    ///      pool; the deadline; the taxes (at most 10% each, not both zero); the partner (active, share equal to
    ///      its registered share, unused nonce, valid EIP-712 or ERC-1271 signature from its signer); and the
    ///      vault (deployed by this launcher for this pool with exactly these payees and share). A direct market
    ///      (partnerId zero) must carry a zero share and no signature.
    function consume(T.Voucher calldata v, bytes calldata signature, address caller, address vault)
        external
        returns (T.Attribution memory a)
    {
        if (msg.sender != launcher || launcher == address(0)) revert NotLauncher();
        if (
            v.launcher != msg.sender || v.caller != caller || caller == address(0) || v.root == address(0)
                || v.poolId == bytes32(0) || v.creatorBeneficiary == address(0)
        ) revert InvalidVoucher();
        if (block.timestamp > v.deadline) revert VoucherExpired(v.deadline);
        if (_attributions[v.poolId].recorded) revert PoolAlreadyAttributed(v.poolId);
        if (
            v.buyTaxPips > T.MAX_TAX_PIPS || v.sellTaxPips > T.MAX_TAX_PIPS || (v.buyTaxPips == 0 && v.sellTaxPips == 0)
        ) revert InvalidTax();
        address signer;
        address partnerBeneficiary;
        bytes32 digest;
        if (v.partnerId == bytes32(0)) {
            if (v.partnerShareBps != 0 || signature.length != 0) revert InvalidVoucher();
        } else {
            T.Partner storage p = _partners[v.partnerId];
            if (!p.active) revert PartnerNotActive(v.partnerId);
            if (v.partnerShareBps != p.shareBps) revert ShareMismatch(v.partnerShareBps, p.shareBps);
            signer = p.signer;
            if (nonceUsed[signer][v.nonce]) revert VoucherUsed(signer, v.nonce);
            digest = voucherDigest(v);
            if (!SignatureChecker.isValidSignatureNow(signer, digest, signature)) revert InvalidSignature();
            nonceUsed[signer][v.nonce] = true;
            partnerBeneficiary = p.beneficiary;
        }
        _checkVault(vault, v, partnerBeneficiary);
        a = T.Attribution({
            recorded: true,
            partnerId: v.partnerId,
            root: v.root,
            caller: caller,
            signer: signer,
            vault: vault,
            creatorBeneficiary: v.creatorBeneficiary,
            partnerBeneficiary: partnerBeneficiary,
            buyTaxPips: v.buyTaxPips,
            sellTaxPips: v.sellTaxPips,
            partnerShareBps: v.partnerShareBps,
            createdAtBlock: uint64(block.number),
            stackHash: v.stackHash,
            termsHash: termsHash(v, partnerBeneficiary)
        });
        _attributions[v.poolId] = a;
        _partnerPools[v.partnerId].push(v.poolId);
        if (signer != address(0)) emit VoucherConsumed(v.poolId, v.partnerId, signer, v.nonce, digest);
        emit PoolAttributed(
            v.poolId,
            v.partnerId,
            vault,
            v.root,
            caller,
            v.creatorBeneficiary,
            partnerBeneficiary,
            v.buyTaxPips,
            v.sellTaxPips,
            v.partnerShareBps,
            v.stackHash,
            a.termsHash
        );
    }

    /// @notice Commitment to a pool's split, taxes and initial payees.
    function termsHash(T.Voucher calldata v, address partnerBeneficiary) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                TERMS_DOMAIN,
                block.chainid,
                v.root,
                v.poolId,
                v.partnerId,
                v.buyTaxPips,
                v.sellTaxPips,
                T.CREATOR_SHARE_BPS,
                v.partnerShareBps,
                T.PARTNER_AND_TREASURY_BPS - v.partnerShareBps,
                T.BUY_BURN_SHARE_BPS,
                v.creatorBeneficiary,
                partnerBeneficiary,
                treasuryBeneficiary,
                buyBurnBeneficiary
            )
        );
    }

    /// @dev Refuses an account whose code is an EIP-7702 delegation designator (0xef0100 || target), as the Hookr 1
    ///      registry does. Accounts without code and ordinary contracts (a Safe) pass.
    function _refuseDelegated(address account) private view {
        bool delegated;
        assembly ("memory-safe") {
            if eq(extcodesize(account), 23) {
                extcodecopy(account, 0, 0, 3)
                delegated := eq(shr(232, mload(0)), 0xef0100)
            }
        }
        if (delegated) revert DelegatedAccount(account);
    }

    function _checkVault(address vault, T.Voucher calldata v, address partnerBeneficiary) private view {
        IHookrPartnerRevenueVault x = IHookrPartnerRevenueVault(vault);
        if (
            vault.code.length == 0 || x.launcher() != msg.sender || x.poolId() != v.poolId || x.root() != v.root
                || x.partnerId() != v.partnerId || x.partnerShareBps() != v.partnerShareBps
                || x.beneficiary(0) != v.creatorBeneficiary || x.beneficiary(1) != partnerBeneficiary
                || x.beneficiary(2) != treasuryBeneficiary || x.beneficiary(3) != buyBurnBeneficiary
        ) revert VaultMismatch(vault);
    }
}
