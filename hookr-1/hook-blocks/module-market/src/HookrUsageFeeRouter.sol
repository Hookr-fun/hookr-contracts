// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHookrRules} from "hookr/interfaces/IHookrRules.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {IHookrProtocolClaims} from "hookr/interfaces/IHookrProtocolClaims.sol";
import {ModuleMarketTypes} from "./interfaces/ModuleMarketTypes.sol";
import {IHookrModuleMarket} from "./interfaces/IHookrModuleMarket.sol";
import {IHookrBondVault} from "./interfaces/IHookrBondVault.sol";
import {IHookrUsageFeeRouter} from "./interfaces/IHookrUsageFeeRouter.sol";
import {ModuleMarketMath} from "./libraries/ModuleMarketMath.sol";
import {TransientReentrancyGuard} from "./libraries/TransientReentrancyGuard.sol";
import {HookrModuleFeeAccount} from "./HookrModuleFeeAccount.sol";
import {IRegistryPoolManager} from "./interfaces/IRegistryPoolManager.sol";

/// @title HookrUsageFeeRouter
/// @notice Routes each module version's usage fees out: collects the version's HookrRules claim through its
///         fee account and splits exactly what arrived by the version's frozen split. Developer and protocol
///         shares accrue as pull balances here; the backers' share is streamed through HookrBondVault; the
///         reserve share stays here, isolated per version.
///
///      Only what actually arrives is split (balance before and after the pull), and only from a Rules the market
///      recorded when a root bound a pool installing the version (`usesRules`). Everything that credits this router is
///      guarded by the same lock as `collect`, so nothing the pull triggers can be booked twice; a
///      donation can at most give money away. Rounding always favours the reserve. Every payout is a pull by its owner;
///      a recipient that cannot receive only blocks itself. The only way value leaves a reserve is a timelocked,
///      published DRAW_RESERVE on the market naming that one version. A version terminated by a full slash forfeits its
///      developer share to its own reserve from then on, and (the bond being empty) its backers' share too.
///
///      The protocol share is booked to the protocol, not to an address: whoever is the market's protocol
///      recipient when it is paid receives all of it, so a re-pointed recipient takes over the unpaid balance.
///      The router is also an IHookrProtocolClaims source, so the release HookrTreasury can admit it and pull
///      the protocol share with `collect`, `collectTo` or `forwardBalance`.
contract HookrUsageFeeRouter is HookrReleased, TransientReentrancyGuard, IHookrUsageFeeRouter, IHookrProtocolClaims {
    using CurrencyLibrary for Currency;

    /// @inheritdoc IHookrUsageFeeRouter
    address public immutable market;
    /// @notice keccak256 of HookrModuleFeeAccount's creation code, for CREATE2 prediction.
    bytes32 public immutable feeAccountInitCodeHash;
    /// @inheritdoc IHookrProtocolClaims
    /// @dev The registry's PoolManager, which backs every HookrRules claim this router collects.
    IPoolManager public immutable poolManager;

    /// @notice Pull balances of developer payees.
    mapping(address account => mapping(Currency => uint256)) private _owed;
    /// @notice The unpaid protocol share, paid to whoever is the market's protocol recipient at payment time.
    mapping(Currency => uint256) public protocolOwed;
    /// @notice Each version's safety reserve, never pooled across versions.
    mapping(uint256 versionId => mapping(Currency => uint256)) public reserveOf;
    /// @notice Everything this router owes, per currency: owed balances plus reserves.
    mapping(Currency => uint256) public liability;
    /// @notice Lifetime usage fees collected per version and currency.
    mapping(uint256 versionId => mapping(Currency => uint256)) public collected;

    error Unauthorized(address caller);
    error UnknownVersion(uint256 versionId);
    error UnknownRules(address rules);
    error NothingToCollect();
    error NothingToWithdraw();
    error InvalidRecipient(address to);
    error InvalidFunding(uint256 expected, uint256 actual);
    error ReserveShort(uint256 versionId, uint256 available, uint256 requested);
    error AccountMismatch(address deployed, address predicted);

    event FeeAccountDeployed(address indexed module, address indexed account);
    event FeesRouted(
        uint256 indexed versionId,
        Currency indexed currency,
        address indexed rules,
        uint256 received,
        uint256 developer,
        uint256 backers,
        uint256 protocol,
        uint256 reserve,
        bool backersStreamed
    );
    event Withdrawn(address indexed account, Currency indexed currency, address to, uint256 amount);
    event ReserveCredited(uint256 indexed versionId, Currency indexed currency, uint256 amount);
    event ReserveDrawn(uint256 indexed versionId, Currency indexed currency, address to, uint256 amount);

    /// @param market_ The marketplace; the PoolManager is read from its registry.
    constructor(address market_) {
        if (market_.code.length == 0) revert Unauthorized(market_);
        market = market_;
        feeAccountInitCodeHash = keccak256(type(HookrModuleFeeAccount).creationCode);
        poolManager = IRegistryPoolManager(address(IHookrModuleMarket(market_).registry())).poolManager();
    }

    /// @notice Accepts native ETH from HookrRules claims (paid by the PoolManager) and from the vault.
    receive() external payable {}

    /// @inheritdoc IHookrUsageFeeRouter
    function feeAccountOf(address module) public view returns (address) {
        bytes32 salt = bytes32(uint256(uint160(module)));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, feeAccountInitCodeHash))))
        );
    }

    /// @inheritdoc IHookrUsageFeeRouter
    function deployFeeAccount(address module) external returns (address account) {
        if (msg.sender != market) revert Unauthorized(msg.sender);
        account = address(new HookrModuleFeeAccount{salt: bytes32(uint256(uint160(module)))}());
        address predicted = feeAccountOf(module);
        if (account != predicted) revert AccountMismatch(account, predicted);
        emit FeeAccountDeployed(module, account);
    }

    /// @notice Collects one version's usage fees from one HookrRules contract and splits them. Anyone may call.
    /// @param versionId The version whose fee account holds the claim.
    /// @param rules The Rules of a pool that installed the version, as the market recorded it (`usesRules`).
    /// @param currency The quote currency to collect.
    function collect(uint256 versionId, IHookrRules rules, Currency currency)
        external
        nonReentrant
        returns (uint256 received)
    {
        IHookrModuleMarket m = IHookrModuleMarket(market);
        ModuleMarketTypes.Version memory v = m.getVersion(versionId);
        // Naming a registered root is not enough; only a genuine Rules is collected from. Genuine means a Rules a
        // root bound for a pool installing the version, which the market recorded during that binding, not a live
        // admission read. A revoked, or unbonded, Rules admission blocks new pools only, and the pools that froze
        // the Rules keep crediting the version there.
        if (!m.usesRules(versionId, address(rules))) revert UnknownRules(address(rules));
        if (rules.claimable(currency, v.feeAccount) == 0) revert NothingToCollect();
        uint256 before = currency.balanceOfSelf();
        HookrModuleFeeAccount(v.feeAccount).pull(rules, currency);
        received = currency.balanceOfSelf() - before;
        if (received == 0) revert NothingToCollect();
        _route(versionId, v.split, v.status == ModuleMarketTypes.Status.TERMINATED, currency, received, address(rules));
    }

    /// @notice Pays the caller's accrued developer share in one currency, plus the whole unpaid protocol share
    ///         when the caller is the market's current protocol recipient.
    function withdraw(Currency currency, address to) external nonReentrant returns (uint256 amount) {
        return _pay(msg.sender, currency, to);
    }

    /// @inheritdoc IHookrProtocolClaims
    /// @dev Same payment as `withdraw`; the entry the release HookrTreasury pulls through.
    function claimTo(Currency currency, address to) external nonReentrant returns (uint256 amount) {
        return _pay(msg.sender, currency, to);
    }

    /// @inheritdoc IHookrProtocolClaims
    function protocolRecipient() public view returns (address) {
        return IHookrModuleMarket(market).protocolRecipient();
    }

    /// @inheritdoc IHookrProtocolClaims
    function claimable(Currency currency, address account) public view returns (uint256 amount) {
        amount = _owed[account][currency];
        if (account == protocolRecipient()) amount += protocolOwed[currency];
    }

    /// @notice What `account` can withdraw in `currency` now (its developer share, plus the protocol share when
    ///         it is the current protocol recipient).
    function owed(address account, Currency currency) external view returns (uint256) {
        return claimable(currency, account);
    }

    /// @inheritdoc IHookrUsageFeeRouter
    /// @dev nonReentrant: `collect` counts whatever arrives during
    ///      `feeAccount.pull(rules)` as fees, and `rules` is external code. Without the router's own lock here,
    ///      a malicious rules contract could call the permissionless `vault.sweepStranded` mid-pull, so the same
    ///      ETH was booked twice (this version's reserve, and the collecting version's usage fees) and the
    ///      router owed more than it held.
    function receiveStranded(uint256 versionId, Currency currency, uint256 amount) external payable nonReentrant {
        if (msg.sender != address(IHookrModuleMarket(market).vault())) revert Unauthorized(msg.sender);
        if (currency.isAddressZero()) {
            if (msg.value != amount) revert InvalidFunding(amount, msg.value);
        } else {
            if (msg.value != 0) revert InvalidFunding(0, msg.value);
            uint256 balance = currency.balanceOfSelf();
            if (balance < liability[currency] + amount) revert InvalidFunding(liability[currency] + amount, balance);
        }
        reserveOf[versionId][currency] += amount;
        liability[currency] += amount;
        emit ReserveCredited(versionId, currency, amount);
    }

    /// @inheritdoc IHookrUsageFeeRouter
    function drawReserve(uint256 versionId, Currency currency, address to, uint256 amount) external nonReentrant {
        if (msg.sender != market) revert Unauthorized(msg.sender);
        if (to == address(0)) revert InvalidRecipient(to);
        uint256 available = reserveOf[versionId][currency];
        if (amount > available) revert ReserveShort(versionId, available, amount);
        reserveOf[versionId][currency] = available - amount;
        liability[currency] -= amount;
        currency.transfer(to, amount);
        emit ReserveDrawn(versionId, currency, to, amount);
    }

    function _pay(address account, Currency currency, address to) private returns (uint256 amount) {
        if (to == address(0)) revert InvalidRecipient(to);
        amount = _owed[account][currency];
        _owed[account][currency] = 0;
        if (account == protocolRecipient()) {
            amount += protocolOwed[currency];
            protocolOwed[currency] = 0;
        }
        if (amount == 0) revert NothingToWithdraw();
        liability[currency] -= amount;
        currency.transfer(to, amount);
        emit Withdrawn(account, currency, to, amount);
    }

    function _route(
        uint256 versionId,
        ModuleMarketTypes.Split memory split,
        bool terminated,
        Currency currency,
        uint256 received,
        address rules
    ) private {
        (uint256 developer, uint256 backers, uint256 protocol, uint256 reserve) =
            ModuleMarketMath.splitAmounts(received, split);
        if (terminated) {
            // A version slashed in full for misconduct forfeits its developer's future share: pools that froze
            // it keep paying the usage fee, and that share now builds the version's reserve instead.
            reserve += developer;
            developer = 0;
        }
        IHookrModuleMarket m = IHookrModuleMarket(market);
        _owed[m.payee(versionId)][currency] += developer;
        protocolOwed[currency] += protocol;
        IHookrBondVault vault = m.vault();
        bool streamed = backers != 0 && vault.canNotify(versionId, currency);
        if (streamed) {
            if (currency.isAddressZero()) {
                vault.notifyReward{value: backers}(versionId, currency, backers);
            } else {
                currency.transfer(address(vault), backers);
                vault.notifyReward(versionId, currency, backers);
            }
        } else {
            // Nobody is posted behind the version, or the vault does not stream the currency (neither native ETH
            // nor a catalog quote when first collected): the backers' share is kept for the version's own reserve
            // rather than handed to anyone else.
            reserve += backers;
        }
        reserveOf[versionId][currency] += reserve;
        liability[currency] += developer + protocol + reserve;
        collected[versionId][currency] += received;
        emit FeesRouted(versionId, currency, rules, received, developer, backers, protocol, reserve, streamed);
    }
}
