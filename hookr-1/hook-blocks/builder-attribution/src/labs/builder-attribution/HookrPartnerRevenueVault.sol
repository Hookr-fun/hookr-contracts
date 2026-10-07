// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRules} from "../../interfaces/IHookrRules.sol";
import {HookrAttributionTypes as T} from "./types/HookrAttributionTypes.sol";
import {IHookrPartnerRevenueVault} from "./interfaces/IHookrPartnerRevenueVault.sol";

/// @title Hookr partner revenue vault
/// @notice Per-pool, non-proxy vault that realizes the pool's directional-tax claim from HookrRules and splits the
///         actual output: creator 60%, partner 20-25% (zero for a direct market), HOOKR buy/burn 10%, treasury the
///         remainder including all rounding dust. Each role pulls its own balance.
/// @dev Deployed by `HookrAttributionLauncher` with CREATE2 (salt =
///      PoolId) and initialized entirely in its constructor. Nothing about the split, the pool, the quote or the
///      role identities can change after deployment; only each role's payee rotates, by proposal and acceptance.
///
///      Revenue source. The tax advisory names this vault as its take recipient, so the root credits the tax to
///      it as a HookrRules claim backed by PoolManager ERC-6909 balances. Only this vault can realize that claim
///      (`IHookrRules.claim` pays the caller's own claim). `harvest` realizes it and splits the balance increase
///      it actually observed, so the split is on delivered output, never on a reported number.
///
///      Accounting separation. The vault never touches LP fees or any pool. A direct transfer nobody credited (a
///      donation or forced ETH) is surplus: `recoverSurplus` assigns it to the treasury role only, reported as
///      surplus and never as revenue, so a direct transfer cannot inflate partner or creator revenue. The
///      buy/burn role is an allocation to its payee, not proof that any HOOKR was bought or burned.
///
///      Limit (open). HookrRules keeps claims per (currency, account) across every pool it serves,
///      and this vault cannot tell the sources of its claim apart. Any Rules credit that names this vault's
///      address, such as another pool's Rules `royaltyTo` or another advisory's recipient, is realized by
///      `harvest` and split and reported exactly like this pool's tax. `grossHarvested`, `roleAccrued` and
///      `Harvested` therefore mean "quote claims realized from Rules by this vault", not "this pool's tax".
///      The pool's tax is read from the root's `HookFee` and Rules' `FeesAllocated` events (advisory fee =
///      earned - protocol - royalty). Separating the two on chain needs per-pool take buckets in H1.
contract HookrPartnerRevenueVault is IHookrPartnerRevenueVault {
    using SafeERC20 for IERC20;

    uint8 public constant ROLE_CREATOR = 0;
    uint8 public constant ROLE_PARTNER = 1;
    uint8 public constant ROLE_TREASURY = 2;
    uint8 public constant ROLE_BUY_BURN = 3;
    uint8 public constant ROLE_COUNT = 4;

    /// @notice The launcher that deployed this vault.
    address public immutable launcher;
    /// @notice The attributed pool.
    bytes32 public immutable poolId;
    /// @notice The attributed pool's root.
    address public immutable root;
    /// @notice The Rules module that holds the pool's tax claims.
    IHookrRules public immutable rules;
    /// @notice The pool's quote currency; address zero is native ETH.
    Currency public immutable quote;
    /// @notice The attributed partner, or zero for a direct market.
    bytes32 public immutable partnerId;
    /// @notice The partner share in basis points; zero for a direct market.
    uint16 public immutable partnerShareBps;

    /// @notice Constructor terms. `partnerBeneficiary` is zero exactly when `partnerId` is zero.
    struct Terms {
        bytes32 poolId;
        address root;
        IHookrRules rules;
        Currency quote;
        bytes32 partnerId;
        uint16 partnerShareBps;
        address creatorBeneficiary;
        address partnerBeneficiary;
        address treasuryBeneficiary;
        address buyBurnBeneficiary;
    }

    address[4] private _beneficiary;
    address[4] private _pendingBeneficiary;
    /// @dev asset => role => unclaimed balance.
    mapping(address => uint256[4]) private _claimable;
    /// @dev asset => sum of unclaimed balances; always covered by this vault's balance of the asset.
    mapping(address => uint256) private _outstanding;
    /// @dev Quote-denominated cumulative figures.
    uint256 private _grossHarvested;
    uint256 private _harvests;
    uint256[4] private _roleAccrued;
    uint256 private _surplusRecovered;
    uint256 private _lock = 1;

    error InvalidTerms();
    error InvalidRole();
    error NotBeneficiary();
    error NotPendingBeneficiary();
    error InvalidRecipient(address recipient);
    error NothingToHarvest();
    error NothingToClaim();
    error NoSurplus();
    error BalanceMismatch();
    error NativeTransferFailed();
    error ReentrantCall();

    /// @notice A harvest realized `gross` from Rules and split it.
    event Harvested(
        bytes32 indexed poolId,
        bytes32 indexed partnerId,
        uint256 gross,
        uint256 creator,
        uint256 partner,
        uint256 treasury,
        uint256 buyBurn
    );
    /// @notice A role paid out its balance.
    event RevenueClaimed(
        bytes32 indexed poolId,
        uint8 indexed role,
        address indexed asset,
        address beneficiary,
        address to,
        uint256 amount
    );
    /// @notice An uncredited balance was assigned to the treasury role. Surplus is not revenue.
    event SurplusRecovered(bytes32 indexed poolId, address indexed asset, uint256 amount);
    event BeneficiaryProposed(bytes32 indexed poolId, uint8 indexed role, address indexed current, address pending);
    event BeneficiaryAccepted(bytes32 indexed poolId, uint8 indexed role, address indexed previous, address current);

    /// @param t Immutable terms; the deployer is recorded as `launcher`.
    constructor(Terms memory t) {
        bool direct = t.partnerId == bytes32(0);
        if (
            t.poolId == bytes32(0) || t.root.code.length == 0 || address(t.rules).code.length == 0
                || (Currency.unwrap(t.quote) != address(0) && Currency.unwrap(t.quote).code.length == 0)
                || direct != (t.partnerShareBps == 0) || direct != (t.partnerBeneficiary == address(0))
                || (!direct
                    && (t.partnerShareBps < T.MIN_PARTNER_SHARE_BPS || t.partnerShareBps > T.MAX_PARTNER_SHARE_BPS))
                || t.creatorBeneficiary == address(0) || t.treasuryBeneficiary == address(0)
                || t.buyBurnBeneficiary == address(0) || t.creatorBeneficiary == address(this)
                || t.partnerBeneficiary == address(this) || t.treasuryBeneficiary == address(this)
                || t.buyBurnBeneficiary == address(this)
        ) revert InvalidTerms();
        launcher = msg.sender;
        poolId = t.poolId;
        root = t.root;
        rules = t.rules;
        quote = t.quote;
        partnerId = t.partnerId;
        partnerShareBps = t.partnerShareBps;
        _beneficiary[ROLE_CREATOR] = t.creatorBeneficiary;
        _beneficiary[ROLE_PARTNER] = t.partnerBeneficiary;
        _beneficiary[ROLE_TREASURY] = t.treasuryBeneficiary;
        _beneficiary[ROLE_BUY_BURN] = t.buyBurnBeneficiary;
    }

    /// @notice Accepts native quote from the PoolManager during a harvest. Anything else is surplus.
    receive() external payable {}

    modifier nonReentrant() {
        if (_lock != 1) revert ReentrantCall();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @notice The treasury share in basis points: 30% minus the partner share, before rounding dust.
    function treasuryShareBps() external view returns (uint16) {
        return T.PARTNER_AND_TREASURY_BPS - partnerShareBps;
    }

    /// @notice The current payee of a role.
    function beneficiary(uint8 role) external view returns (address) {
        _checkRole(role);
        return _beneficiary[role];
    }

    /// @notice The nominated payee of a role, or zero.
    function pendingBeneficiary(uint8 role) external view returns (address) {
        _checkRole(role);
        return _pendingBeneficiary[role];
    }

    /// @notice A role's unclaimed balance of `asset`. Only the quote accrues revenue; other assets hold surplus only.
    function claimable(address asset, uint8 role) external view returns (uint256) {
        _checkRole(role);
        return _claimable[asset][role];
    }

    /// @notice Sum of every role's unclaimed balance of `asset`.
    function outstanding(address asset) external view returns (uint256) {
        return _outstanding[asset];
    }

    /// @notice Quote realized from Rules and split, cumulative. Includes any Rules credit naming this vault, not only
    ///         this pool's tax.
    function grossHarvested() external view returns (uint256) {
        return _grossHarvested;
    }

    /// @notice Number of harvests that split a nonzero amount.
    function harvests() external view returns (uint256) {
        return _harvests;
    }

    /// @notice Quote a role has been allocated from harvests, cumulative. Excludes surplus.
    function roleAccrued(uint8 role) external view returns (uint256) {
        _checkRole(role);
        return _roleAccrued[role];
    }

    /// @notice Quote assigned to the treasury as surplus, cumulative. Not revenue.
    function surplusRecovered() external view returns (uint256) {
        return _surplusRecovered;
    }

    /// @notice The tax claim waiting in Rules for the next harvest.
    function pendingRevenue() external view returns (uint256) {
        return rules.claimable(quote, address(this));
    }

    /// @notice The split of `gross`: creator, partner and buy/burn round down independently; treasury takes the
    ///         remainder, so the four parts always sum to `gross`.
    function splitOf(uint256 gross)
        public
        view
        returns (uint256 creator, uint256 partner, uint256 treasury, uint256 buyBurn)
    {
        creator = gross * T.CREATOR_SHARE_BPS / T.BPS;
        partner = gross * partnerShareBps / T.BPS;
        buyBurn = gross * T.BUY_BURN_SHARE_BPS / T.BPS;
        treasury = gross - creator - partner - buyBurn;
    }

    /// @notice Realizes this vault's whole Rules claim in the quote (the pool's tax plus any other Rules credit to
    ///         this address) and splits the balance it actually received. Callable by anyone.
    /// @dev Rules pays at most int128.max per claim; the rest stays claimable for the next harvest. Rules refuses a
    ///      quote that does not deliver exactly (a transfer fee), so such a claim stays in Rules unrealized.
    /// @return gross The quote this harvest received and split
    function harvest() external nonReentrant returns (uint256 gross) {
        Currency q = quote;
        if (rules.claimable(q, address(this)) == 0) revert NothingToHarvest();
        uint256 beforeBalance = _balance(Currency.unwrap(q));
        rules.claim(q);
        uint256 afterBalance = _balance(Currency.unwrap(q));
        if (afterBalance <= beforeBalance) revert BalanceMismatch();
        gross = afterBalance - beforeBalance;
        (uint256 c, uint256 p, uint256 t, uint256 b) = splitOf(gross);
        address asset = Currency.unwrap(q);
        uint256[4] storage slot = _claimable[asset];
        slot[ROLE_CREATOR] += c;
        slot[ROLE_PARTNER] += p;
        slot[ROLE_TREASURY] += t;
        slot[ROLE_BUY_BURN] += b;
        _roleAccrued[ROLE_CREATOR] += c;
        _roleAccrued[ROLE_PARTNER] += p;
        _roleAccrued[ROLE_TREASURY] += t;
        _roleAccrued[ROLE_BUY_BURN] += b;
        _outstanding[asset] += gross;
        _grossHarvested += gross;
        ++_harvests;
        emit Harvested(poolId, partnerId, gross, c, p, t, b);
    }

    /// @notice Pays the caller's whole balance of the quote for `role` to `to`. Only the role's current payee.
    function claim(uint8 role, address to) external returns (uint256) {
        return claimAsset(Currency.unwrap(quote), role, to);
    }

    /// @notice Pays the caller's whole balance of `asset` for `role` to `to`. Only the role's current payee.
    /// @dev ERC20 delivery must be exact. A native recipient that reverts only fails its own claim.
    function claimAsset(address asset, uint8 role, address to) public nonReentrant returns (uint256 amount) {
        _checkRole(role);
        if (msg.sender != _beneficiary[role]) revert NotBeneficiary();
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        amount = _claimable[asset][role];
        if (amount == 0) revert NothingToClaim();
        _claimable[asset][role] = 0;
        _outstanding[asset] -= amount;
        _send(asset, to, amount);
        emit RevenueClaimed(poolId, role, asset, msg.sender, to, amount);
    }

    /// @notice Assigns any balance of `asset` above what the roles are owed to the treasury role. Callable by anyone.
    /// @dev Surplus comes only from transfers nobody credited: donations and forced ETH. Harvest never counts it.
    function recoverSurplus(address asset) external nonReentrant returns (uint256 surplus) {
        uint256 held = _balance(asset);
        uint256 owed = _outstanding[asset];
        if (held <= owed) revert NoSurplus();
        surplus = held - owed;
        _claimable[asset][ROLE_TREASURY] += surplus;
        _outstanding[asset] = held;
        if (asset == Currency.unwrap(quote)) _surplusRecovered += surplus;
        emit SurplusRecovered(poolId, asset, surplus);
    }

    /// @notice Nominates the next payee of `role`, or clears a nomination with zero. Only the current payee.
    /// @dev The role, its share and its unclaimed balance stay with the role; the new payee claims all of it.
    function proposeBeneficiary(uint8 role, address next) external {
        _checkRole(role);
        address current = _beneficiary[role];
        if (msg.sender != current) revert NotBeneficiary();
        if (next == current || next == address(this)) revert InvalidRecipient(next);
        _pendingBeneficiary[role] = next;
        emit BeneficiaryProposed(poolId, role, current, next);
    }

    /// @notice Completes a payee rotation. Only the nominee.
    function acceptBeneficiary(uint8 role) external {
        _checkRole(role);
        if (msg.sender == address(0) || msg.sender != _pendingBeneficiary[role]) revert NotPendingBeneficiary();
        address previous = _beneficiary[role];
        _beneficiary[role] = msg.sender;
        delete _pendingBeneficiary[role];
        emit BeneficiaryAccepted(poolId, role, previous, msg.sender);
    }

    function _checkRole(uint8 role) private pure {
        if (role >= ROLE_COUNT) revert InvalidRole();
    }

    function _balance(address asset) private view returns (uint256) {
        return asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    function _send(address asset, address to, uint256 amount) private {
        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
            return;
        }
        uint256 ours = _balance(asset);
        uint256 theirs = IERC20(asset).balanceOf(to);
        IERC20(asset).safeTransfer(to, amount);
        if (_balance(asset) != ours - amount || IERC20(asset).balanceOf(to) != theirs + amount) {
            revert BalanceMismatch();
        }
    }
}
