// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRevenueTypes} from "./interfaces/HookrRevenueTypes.sol";
import {IHookrRevenueSplit} from "./interfaces/IHookrRevenueSplit.sol";
import {IHookrRevenueSource} from "./interfaces/IHookrRevenueSource.sol";
import {HookrRevenueAllocation} from "./libraries/HookrRevenueAllocation.sol";
import {HookrRevenueConfig} from "./libraries/HookrRevenueConfig.sol";

/// @title Hookr revenue split
/// @notice One immutable fee recipient with up to eight fixed payees whose weights sum to 10,000 bps. Name it as a
///         pool's `RulesConfig.royaltyTo` (creator claims), as the `HookrTreasury` target (protocol claims), as the
///         `recipient` of a family owner's LP-fee collection, or pay it directly. Every wei that arrives is credited
///         by one cumulative highest-averages allocation, so many small deposits credit exactly what one large
///         deposit would; each payee pulls its own balance, so one failing payee blocks nobody else. Every currency has
///         its own ledger, so a pool's quote royalty and its claims in each settlement currency (native ETH, WETH, USDG
///         at genesis, recapture shares pushed in any of them) are credited and paid separately; `collectMany`,
///         `claimMany` and `claimForMany` move all of them in one call. PoolManager ERC-6909 claims paid to it (a
///         Rules `claimAsClaims`, a treasury `collectAsClaims` or a launcher `withdrawWithClaims` to it, a Directional
///         Tax queue's exit for a quote that will not deliver) become the currency itself through `redeem`, which
///         anyone may call, and are credited the same way.
/// @dev Hookr 1 extension point: off-pool sidecar / contract fee recipient. Nothing on the swap path ever calls it.
///      There is no owner, no admin, no upgrade path and no sweep: the payee list lives in immutables (the runtime
///      code commits to it) and the ledger is append-only. The split never grants an allowance or an operator
///      approval anywhere, so an arbitrary `collect` source or `redeem` manager it calls cannot move its funds;
///      `collect` and `redeem` also refuse any call that lowers the currency's balance here. `redeem` burns only the
///      split's own ERC-6909 claims, inside an unlock the split opens itself, and takes the same amount here;
///      `unlockCallback` answers only that unlock, once. Unsupported assets: tokens whose balance can fall
///      without a transfer (negative rebasing) make `sync` fail closed (`AccountingInvariant`) until the balance
///      again covers the outstanding claims; fee-on-transfer tokens credit only what actually arrived. An ERC-20
///      payout charges the payee only what left this contract: a token that debits at most `MAX_PAYOUT_SHORTFALL`
///      less than the transfer value (share rounding) leaves the remainder on the payee's claim; one that debits
///      more (a fee charged to the sender on top) or much less (reflection, or an inflow during the payout) is
///      refused with `TransferMismatch`, so that asset's payouts stay closed.
contract HookrRevenueSplit is IHookrRevenueSplit, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    /// @dev keccak256(abi.encode(uint256(keccak256("hookr.revenue.split")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SLOT = 0x71b2a54b978d0fb684a9636590dc585e16ee9e3039c9686abfb9de7a4b28c100;
    /// @dev keccak256("hookr.revenue.split.transient.lock"); transient (EIP-1153) reentrancy lock.
    bytes32 private constant LOCK = 0x868be265b9ee603037c72653c39f273db7e7cf4ce4c478101be9ef105c89d043;
    /// @dev keccak256("hookr.revenue.split.transient.redeeming"); transient (EIP-1153): the manager `redeem` is
    ///      unlocking until its callback runs, the only caller `unlockCallback` answers.
    bytes32 private constant REDEEMING = 0x1d63a2b215103b68d6e6c93d567dfde1f30d47821052bc30791875317f580ee7;
    /// @notice Largest amount by which an ERC-20 payout's balance debit may fall short of the requested transfer
    ///         (share-based tokens round a transfer by 1-2 wei in the sender's favour).
    uint256 public constant MAX_PAYOUT_SHORTFALL = 2;
    /// @notice Most currencies one batch call takes: the pool's two plus the registry's settlement set (at most 8),
    ///         with room for members that left the set while a pool's accrual still held them.
    uint256 public constant MAX_BATCH_CURRENCIES = 16;

    /// @dev Per-currency ledger. `credited[i]` is payee i's lifetime credit, which always equals the allocation
    ///      of `deposited`; `reserved` is the sum of every `claimable`.
    struct Ledger {
        uint256 deposited;
        uint256 reserved;
        uint256[8] credited;
        mapping(address account => uint256) claimable;
        mapping(address account => uint256) claimed;
    }

    /// @custom:storage-location erc7201:hookr.revenue.split
    struct State {
        mapping(Currency currency => Ledger) ledgers;
    }

    /// @inheritdoc IHookrRevenueSplit
    address public immutable factory;
    /// @inheritdoc IHookrRevenueSplit
    bytes32 public immutable tag;
    /// @inheritdoc IHookrRevenueSplit
    bytes32 public immutable splitId;
    uint256 private immutable _count;
    // Payee i packed as account | bps << 160 | role << 176. Unused slots are zero.
    uint256 private immutable _r0;
    uint256 private immutable _r1;
    uint256 private immutable _r2;
    uint256 private immutable _r3;
    uint256 private immutable _r4;
    uint256 private immutable _r5;
    uint256 private immutable _r6;
    uint256 private immutable _r7;

    modifier nonReentrant() {
        bytes32 slot = LOCK;
        uint256 locked;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
        if (locked != 0) revert Reentrancy();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    /// @param tag_ Free creator-chosen tag (for example a family or market label) mixed into the commitment.
    /// @param recipients_ The frozen payees; validated by `HookrRevenueConfig.validate`.
    constructor(bytes32 tag_, HookrRevenueTypes.Recipient[] memory recipients_) {
        HookrRevenueConfig.validate(recipients_, address(this), address(0));
        uint256 count = recipients_.length;
        uint256[8] memory packed;
        for (uint256 i; i < count; ++i) {
            HookrRevenueTypes.Recipient memory r = recipients_[i];
            packed[i] = uint256(uint160(r.account)) | (uint256(r.bps) << 160) | (uint256(uint8(r.role)) << 176);
        }
        factory = msg.sender;
        tag = tag_;
        bytes32 id = HookrRevenueConfig.id(tag_, recipients_);
        splitId = id;
        _count = count;
        _r0 = packed[0];
        _r1 = packed[1];
        _r2 = packed[2];
        _r3 = packed[3];
        _r4 = packed[4];
        _r5 = packed[5];
        _r6 = packed[6];
        _r7 = packed[7];
        emit SplitConfigured(id, tag_, recipients_);
    }

    /// @notice Accepts native currency from anyone (a Rules claim through the PoolManager, a treasury forward, an
    ///         LP-fee collection). It is credited on the next `sync`, `collect` or `deposit`.
    receive() external payable {}

    /// @inheritdoc IHookrRevenueSplit
    function collect(address source, Currency currency)
        external
        nonReentrant
        returns (uint256 received, uint256 credited)
    {
        (received, credited) = _collect(source, currency);
    }

    /// @inheritdoc IHookrRevenueSplit
    function collectMany(address source, Currency[] calldata currencies)
        external
        nonReentrant
        returns (uint256[] memory received, uint256[] memory credited)
    {
        _checkBatch(currencies);
        uint256 n = currencies.length;
        received = new uint256[](n);
        credited = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (received[i], credited[i]) = _collect(source, currencies[i]);
        }
    }

    /// @inheritdoc IHookrRevenueSplit
    function sync(Currency currency) external nonReentrant returns (uint256 credited) {
        credited = _sync(currency);
    }

    /// @inheritdoc IHookrRevenueSplit
    function deposit(Currency currency, uint256 amount) external payable nonReentrant returns (uint256 credited) {
        if (amount == 0) revert InvalidAmount();
        if (currency.isAddressZero()) {
            if (msg.value != amount) revert InvalidAmount();
        } else {
            if (msg.value != 0) revert InvalidAmount();
            IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
        }
        credited = _sync(currency);
    }

    /// @inheritdoc IHookrRevenueSplit
    function redeem(IPoolManager manager, Currency currency)
        external
        nonReentrant
        returns (uint256 received, uint256 credited)
    {
        uint256 claims = manager.balanceOf(address(this), currency.toId());
        if (claims != 0) {
            // PoolManager amounts are signed int128. A larger balance is redeemed in chunks.
            if (claims > uint256(uint128(type(int128).max))) claims = uint256(uint128(type(int128).max));
            uint256 beforeBalance = currency.balanceOfSelf();
            _setRedeeming(address(manager));
            manager.unlock(abi.encode(currency, claims));
            if (_redeeming() != address(0)) revert NotPoolManager();
            uint256 afterBalance = currency.balanceOfSelf();
            if (afterBalance < beforeBalance) revert SourceMismatch();
            received = afterBalance - beforeBalance;
            emit ClaimsRedeemed(address(manager), currency, claims, received);
        }
        credited = _sync(currency);
    }

    /// @notice The PoolManager's callback inside `redeem`: burns this split's claims and takes the same amount of the
    ///         currency here.
    /// @dev Answers only the manager `redeem` is unlocking, and only once, so it runs only inside `redeem`, under its
    ///      lock, on the amount `redeem` read. The manager's balance must fall by the claims burned, or by at most
    ///      `MAX_PAYOUT_SHORTFALL` less (share rounding): a larger debit would be paid out of other holders' backing
    ///      (a fee charged to the sender on top), and a debit of nothing would burn the claims for nothing. What
    ///      arrives here is measured by `redeem`, so a fee-on-transfer currency credits only what arrived.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != _redeeming()) revert NotPoolManager();
        _setRedeeming(address(0));
        (Currency currency, uint256 claims) = abi.decode(data, (Currency, uint256));
        IPoolManager manager = IPoolManager(msg.sender);
        manager.burn(address(this), currency.toId(), claims);
        uint256 managerBefore = currency.balanceOf(msg.sender);
        manager.take(currency, address(this), claims);
        uint256 managerAfter = currency.balanceOf(msg.sender);
        uint256 debited = managerBefore > managerAfter ? managerBefore - managerAfter : 0;
        if (debited == 0 || debited > claims || claims - debited > MAX_PAYOUT_SHORTFALL) {
            revert RedeemMismatch(claims, debited);
        }
        return "";
    }

    /// @inheritdoc IHookrRevenueSplit
    function claim(Currency currency) external nonReentrant returns (uint256 amount) {
        amount = _pay(currency, msg.sender, msg.sender);
    }

    /// @inheritdoc IHookrRevenueSplit
    function claimTo(Currency currency, address to) external nonReentrant returns (uint256 amount) {
        amount = _pay(currency, msg.sender, to);
    }

    /// @inheritdoc IHookrRevenueSplit
    function claimFor(address account, Currency currency) external nonReentrant returns (uint256 amount) {
        if (pullOnly(account)) revert PullOnly(account);
        amount = _pay(currency, account, account);
    }

    /// @inheritdoc IHookrRevenueSplit
    function claimMany(Currency[] calldata currencies, address to)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        amounts = _payMany(currencies, msg.sender, to);
    }

    /// @inheritdoc IHookrRevenueSplit
    function claimForMany(address account, Currency[] calldata currencies)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (pullOnly(account)) revert PullOnly(account);
        amounts = _payMany(currencies, account, account);
    }

    /// @inheritdoc IHookrRevenueSplit
    function recipients() external view returns (HookrRevenueTypes.Recipient[] memory list) {
        uint256 count = _count;
        list = new HookrRevenueTypes.Recipient[](count);
        for (uint256 i; i < count; ++i) {
            (address account, uint256 bps, HookrRevenueTypes.Role role) = _recipient(i);
            // bps came from a uint16 weight.
            // forge-lint: disable-next-line(unsafe-typecast)
            list[i] = HookrRevenueTypes.Recipient(account, uint16(bps), role);
        }
    }

    /// @inheritdoc IHookrRevenueSplit
    function recipientCount() external view returns (uint256) {
        return _count;
    }

    /// @inheritdoc IHookrRevenueSplit
    function pullOnly(address account) public view returns (bool) {
        uint256 count = _count;
        for (uint256 i; i < count; ++i) {
            (address a,, HookrRevenueTypes.Role role) = _recipient(i);
            if (a == account && role == HookrRevenueTypes.Role.STRATEGY) return true;
        }
        return false;
    }

    /// @inheritdoc IHookrRevenueSplit
    function claimable(Currency currency, address account) external view returns (uint256) {
        return _ledger(currency).claimable[account];
    }

    /// @inheritdoc IHookrRevenueSplit
    function reserved(Currency currency) external view returns (uint256) {
        return _ledger(currency).reserved;
    }

    /// @inheritdoc IHookrRevenueSplit
    function lifetimeDeposited(Currency currency) external view returns (uint256) {
        return _ledger(currency).deposited;
    }

    /// @inheritdoc IHookrRevenueSplit
    function lifetimeCredited(Currency currency, address account, HookrRevenueTypes.Role role)
        external
        view
        returns (uint256)
    {
        Ledger storage l = _ledger(currency);
        uint256 count = _count;
        for (uint256 i; i < count; ++i) {
            (address a,, HookrRevenueTypes.Role r) = _recipient(i);
            if (a == account && r == role) return l.credited[i];
        }
        return 0;
    }

    /// @inheritdoc IHookrRevenueSplit
    function lifetimeCreditedByAccount(Currency currency, address account) external view returns (uint256 total) {
        Ledger storage l = _ledger(currency);
        uint256 count = _count;
        for (uint256 i; i < count; ++i) {
            (address a,,) = _recipient(i);
            if (a == account) total += l.credited[i];
        }
    }

    /// @inheritdoc IHookrRevenueSplit
    function lifetimeCreditedByRole(Currency currency, HookrRevenueTypes.Role role)
        external
        view
        returns (uint256 total)
    {
        Ledger storage l = _ledger(currency);
        uint256 count = _count;
        for (uint256 i; i < count; ++i) {
            (,, HookrRevenueTypes.Role r) = _recipient(i);
            if (r == role) total += l.credited[i];
        }
    }

    /// @inheritdoc IHookrRevenueSplit
    function lifetimeClaimed(Currency currency, address account) external view returns (uint256) {
        return _ledger(currency).claimed[account];
    }

    /// @inheritdoc IHookrRevenueSplit
    function unaccounted(Currency currency) external view returns (uint256) {
        uint256 balance = currency.balanceOfSelf();
        uint256 liability = _ledger(currency).reserved;
        return balance > liability ? balance - liability : 0;
    }

    /// @inheritdoc IHookrRevenueSplit
    function solvency(Currency currency)
        external
        view
        returns (uint256 balance, uint256 liability, uint256 surplus, bool solvent)
    {
        balance = currency.balanceOfSelf();
        liability = _ledger(currency).reserved;
        solvent = balance >= liability;
        if (solvent) surplus = balance - liability;
    }

    /// @inheritdoc IHookrRevenueSplit
    function allocation(uint256 total) external view returns (uint256[] memory) {
        return HookrRevenueAllocation.targets(_weights(), total);
    }

    /// @inheritdoc IHookrRevenueSplit
    function preview(Currency currency, uint256 amount) external view returns (uint256[] memory shares) {
        Ledger storage l = _ledger(currency);
        shares = HookrRevenueAllocation.targets(_weights(), l.deposited + amount);
        for (uint256 i; i < shares.length; ++i) {
            shares[i] -= l.credited[i];
        }
    }

    /// @dev Pulls this split's claim at `source` in `currency`, when it has one, then credits everything unaccounted.
    function _collect(address source, Currency currency) private returns (uint256 received, uint256 credited) {
        IHookrRevenueSource claims = IHookrRevenueSource(source);
        if (claims.claimable(currency, address(this)) != 0) {
            uint256 beforeBalance = currency.balanceOfSelf();
            claims.claim(currency);
            uint256 afterBalance = currency.balanceOfSelf();
            if (afterBalance < beforeBalance) revert SourceMismatch();
            received = afterBalance - beforeBalance;
            emit RevenueCollected(source, currency, received);
        }
        credited = _sync(currency);
    }

    /// @dev Pays `account`'s balance in each listed currency to `to`, skipping empty ones; at least one must pay.
    function _payMany(Currency[] calldata currencies, address account, address to)
        private
        returns (uint256[] memory amounts)
    {
        _checkBatch(currencies);
        uint256 n = currencies.length;
        amounts = new uint256[](n);
        bool paid;
        for (uint256 i; i < n; ++i) {
            if (_ledger(currencies[i]).claimable[account] == 0) continue;
            amounts[i] = _pay(currencies[i], account, to);
            paid = true;
        }
        if (!paid) revert NothingToClaim();
    }

    /// @dev One to MAX_BATCH_CURRENCIES currencies, none twice (a repeat would only collect or pay nothing).
    function _checkBatch(Currency[] calldata currencies) private pure {
        uint256 n = currencies.length;
        if (n == 0 || n > MAX_BATCH_CURRENCIES) revert InvalidCurrencies();
        for (uint256 i = 1; i < n; ++i) {
            for (uint256 j; j < i; ++j) {
                if (currencies[i] == currencies[j]) revert InvalidCurrencies();
            }
        }
    }

    /// @dev Credits balance minus outstanding claims as one deposit. Fails closed if the balance no longer covers
    ///      the claims (an asset whose balance fell without a transfer).
    function _sync(Currency currency) private returns (uint256 amount) {
        Ledger storage l = _ledger(currency);
        uint256 balance = currency.balanceOfSelf();
        uint256 liability = l.reserved;
        if (balance < liability) revert AccountingInvariant();
        amount = balance - liability;
        if (amount != 0) _credit(currency, l, amount);
    }

    /// @dev Credits payee i with allocation(lifetime)[i] - credited[i]. House monotonicity makes every difference
    ///      non-negative; conservation makes them sum to `amount`. Both are re-checked and fail closed.
    function _credit(Currency currency, Ledger storage l, uint256 amount) private {
        uint256 lifetime = l.deposited + amount;
        uint256[] memory target = HookrRevenueAllocation.targets(_weights(), lifetime);
        uint256 distributed;
        for (uint256 i; i < target.length; ++i) {
            uint256 previous = l.credited[i];
            if (target[i] < previous) revert AccountingInvariant();
            uint256 share = target[i] - previous;
            if (share == 0) continue;
            l.credited[i] = target[i];
            (address account,, HookrRevenueTypes.Role role) = _recipient(i);
            l.claimable[account] += share;
            distributed += share;
            emit RevenueCredited(currency, account, role, share);
        }
        if (distributed != amount) revert AccountingInvariant();
        l.deposited = lifetime;
        l.reserved += amount;
        emit RevenueDeposited(currency, msg.sender, amount, lifetime);
    }

    /// @dev Pays `account`'s claim to `to` and returns what left this contract. Effects before the transfer; the
    ///      transient lock covers every state-changing entry point. An ERC-20 payout requests the claim, capped at
    ///      this contract's current balance so a negative rebase settles the remaining balance to this claimant and
    ///      leaves only the shortfall on its claim. The balance delta may fall short of the request by at most
    ///      `MAX_PAYOUT_SHORTFALL` (share rounding); only the delta is charged and the remainder stays on the claim.
    ///      A delta of zero, above the request, or short by more (fee on top, reflection, or an inflow that reaches
    ///      this contract during the transfer and would otherwise be netted against the claim instead of credited by
    ///      weight) reverts `TransferMismatch(requested, debited)`.
    function _pay(Currency currency, address account, address to) private returns (uint256 amount) {
        if (to == address(0) || to == address(this)) revert InvalidDestination(to);
        Ledger storage l = _ledger(currency);
        uint256 owed = l.claimable[account];
        if (owed == 0) revert NothingToClaim();
        l.claimable[account] = 0;
        l.reserved -= owed;
        l.claimed[account] += owed;
        amount = owed;
        if (currency.isAddressZero()) {
            (bool ok,) = to.call{value: owed}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            uint256 beforeBalance = currency.balanceOfSelf();
            uint256 payout = beforeBalance < owed ? beforeBalance : owed;
            IERC20(Currency.unwrap(currency)).safeTransfer(to, payout);
            uint256 afterBalance = currency.balanceOfSelf();
            uint256 sent = beforeBalance > afterBalance ? beforeBalance - afterBalance : 0;
            if (sent == 0 || sent > payout || payout - sent > MAX_PAYOUT_SHORTFALL) {
                revert TransferMismatch(payout, sent);
            }
            if (sent < owed) {
                // Only `sent` left: the undelivered remainder goes back on the payee's claim.
                uint256 kept = owed - sent;
                l.claimable[account] = kept;
                l.reserved += kept;
                l.claimed[account] -= kept;
                amount = sent;
            }
        }
        emit RevenueClaimed(currency, account, to, amount);
    }

    function _weights() private view returns (uint256[] memory w) {
        uint256 count = _count;
        w = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            (, uint256 bps,) = _recipient(i);
            w[i] = bps;
        }
    }

    function _recipient(uint256 i) private view returns (address account, uint256 bps, HookrRevenueTypes.Role role) {
        uint256 p = _packed(i);
        account = address(uint160(p));
        // Packed by the constructor from a uint16 weight and a Role, so both casts are exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        bps = uint16(p >> 160);
        // forge-lint: disable-next-line(unsafe-typecast)
        role = HookrRevenueTypes.Role(uint8(p >> 176));
    }

    function _packed(uint256 i) private view returns (uint256) {
        if (i < 4) {
            if (i == 0) return _r0;
            if (i == 1) return _r1;
            if (i == 2) return _r2;
            return _r3;
        }
        if (i == 4) return _r4;
        if (i == 5) return _r5;
        if (i == 6) return _r6;
        return _r7;
    }

    function _ledger(Currency currency) private view returns (Ledger storage) {
        return _state().ledgers[currency];
    }

    function _redeeming() private view returns (address manager) {
        bytes32 slot = REDEEMING;
        assembly ("memory-safe") {
            manager := tload(slot)
        }
    }

    function _setRedeeming(address manager) private {
        bytes32 slot = REDEEMING;
        assembly ("memory-safe") {
            tstore(slot, manager)
        }
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") {
            s.slot := SLOT
        }
    }
}
