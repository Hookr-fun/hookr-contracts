// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookrForwarding} from "../base/HookrForwarding.sol";
import {HookrForward} from "../libraries/HookrForward.sol";
import {EndKind} from "../types/EndKind.sol";
import {IHookrRevenueSource} from "../interfaces/IHookrRevenueSource.sol";
import {IHookrPonsAdapter} from "../interfaces/IHookrPonsAdapter.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";
import {
    IPonsV2LaunchFactory,
    IPonsV2FeeEscrow,
    IPonsV2MemeHook,
    IPonsV2BuybackVault
} from "../interfaces/external/IPonsV2.sol";

/// @title Hookr Pons adapter, part of the HookRevenue Tokenizer
/// @notice The creator fee recipient of one Pons V2 launch, standing in for a revenue token. See IHookrPonsAdapter
///         for the rules.
/// @dev Every pin is read from the Pons factory at construction (its escrow, hook and buyback vault, the launch's
///      quote, fee and spacing), so the adapter follows the factory's own wiring and the pool id is the one the
///      factory derives: memecoin / quote sorted, the launch's fee and tick spacing, the meme hook.
///
///      pull(), in order, each step its own attempt with a gas cap: (1) when the pool is registered on the hook,
///      its `creator` is this adapter and no internal swap is needed (nothing pending in the memecoin, no buyback
///      pending in the quote) but something is pending in the quote, `sweepPoolFees(poolId, 0, 0)` with SWEEP_GAS,
///      so the quote-denominated fees reach the escrow without the Pons operator; (2) when the buyback vault's
///      creator recipient for the memecoin is this adapter and `releasable` is nonzero, `release(memecoin)` with
///      RELEASE_GAS; (3) the escrow's native balance (`claim()`), the quote's ERC-20 balance (`claimToken(quote)`)
///      and the memecoin's (`claimToken(memecoin)`), each only when nonzero, with NATIVE_CLAIM_GAS for native ETH
///      and CLAIM_GAS for an ERC-20; (4) forward
///      (HookrForwarding): native ETH and the quote to the token, the memecoin to the token when it lists it and,
///      less Hookr's leg, into the token's drop box otherwise (an immediate drop at a release period under an hour, the
///      stray stream at an hour or more). A failed step leaves what it could not
///      move where it is. `pull` takes calls from the revenue token alone (`OnlyRevenueToken`) and runs only once the
///      token has the adapter as a door (`NotADoor`), so a Pons right can only ever feed a token that took Hookr's leg
///      for it.
///
///      Gas: the tokenizer gives this source `pullGas()` (10,500,000). The caps (the sweep, the release, three
///      claims, the native send at `SEND_GAS` and two forwards at `FORWARD_ITEM_GAS`) sum to about 9,700,000 with
///      the 64/63 the EVM keeps back and the reads, so one step that burns its whole cap never starves the ones after
///      it. Measured cold: a full pull (sweep, release, three claims, the native forward and the memecoin into the
///      stray stream) takes about 355,000 against the mocks.
///
///      Admission is remembered (`_doorSeen`), since doors are never removed. A completed `abort` is recorded too,
///      so its origin can retry a refund while the token has not admitted the adapter; once a Pons override has
///      moved the right away from an adapter the token never admitted, the origin recovers without an abort
///      (`recoverAbort`). Nothing here is owned or
///      paused and no function moves the right but `abort`. The adapter is
///      never a payee of the token, so the sync's transient lock, the escrow's debit-before-pay and the capped
///      forwards are the whole safety case.
contract HookrPonsAdapter is IHookrPonsAdapter, HookrForwarding {
    using PoolIdLibrary for PoolKey;

    /// @inheritdoc IHookrPonsAdapter
    bytes32 public constant SOURCE_KIND = keccak256("pons.v2");
    /// @inheritdoc IHookrPonsAdapter
    uint256 public constant SWEEP_GAS = 1_000_000;
    /// @inheritdoc IHookrPonsAdapter
    uint256 public constant RELEASE_GAS = 400_000;
    /// @dev Gas one ERC-20 escrow claim gets: the debit and a cold transfer of a revenue token listing eight assets,
    ///      including its first release in every asset and the escrow's settlement as a holder.
    uint256 internal constant CLAIM_GAS = 1_600_000;
    /// @dev Native ETH needs only the escrow's debit and the adapter's empty receive.
    uint256 internal constant NATIVE_CLAIM_GAS = 200_000;
    /// @dev What `pullGas` answers: every step at its cap, the escrow claims and the forwards.
    uint32 internal constant PULL_GAS = 10_500_000;

    /// @inheritdoc IHookrPonsAdapter
    address public immutable factory;
    /// @inheritdoc IHookrPonsAdapter
    address public immutable hook;
    /// @inheritdoc IHookrPonsAdapter
    address public immutable escrow;
    /// @inheritdoc IHookrPonsAdapter
    address public immutable buybackVault;
    /// @inheritdoc IHookrPonsAdapter
    address public immutable memecoin;
    /// @inheritdoc IHookrPonsAdapter
    Currency public immutable quote;
    /// @inheritdoc IHookrPonsAdapter
    PoolId public immutable poolId;
    /// @inheritdoc IHookrPonsAdapter
    address public immutable origin;
    /// @dev Set the first time a pull finds this adapter among the revenue token's doors; doors are never removed.
    bool private _doorSeen;
    /// @inheritdoc IHookrPonsAdapter
    bool public aborted;

    /// @param revenueToken_ The revenue token every pull pays; it need not exist yet, and is not the launch's quote
    ///        (`PairIsRevenueToken`).
    /// @param factory_ The Pons V2 launch factory; must have code and know `memecoin_`.
    /// @param memecoin_ The Pons launch.
    /// @param origin_ The account that holds the creator right now and may `abort`.
    constructor(address revenueToken_, address factory_, address memecoin_, address origin_)
        HookrForwarding(revenueToken_)
    {
        if (factory_.code.length == 0 || origin_ == address(0)) revert InvalidConfig();
        IPonsV2LaunchFactory f = IPonsV2LaunchFactory(factory_);
        IPonsV2LaunchFactory.LaunchedToken memory launch = f.getLaunchedToken(memecoin_);
        if (!launch.exists) revert InvalidConfig();
        if (launch.pairToken == revenueToken_) revert PairIsRevenueToken();
        address hook_ = f.memeHook();
        address escrow_ = f.feeEscrow();
        address vault = f.buybackVault();
        if (hook_.code.length == 0 || escrow_.code.length == 0 || vault.code.length == 0) revert InvalidConfig();
        factory = factory_;
        hook = hook_;
        escrow = escrow_;
        buybackVault = vault;
        memecoin = memecoin_;
        quote = Currency.wrap(launch.pairToken);
        origin = origin_;
        (Currency c0, Currency c1) = memecoin_ < launch.pairToken
            ? (Currency.wrap(memecoin_), Currency.wrap(launch.pairToken))
            : (Currency.wrap(launch.pairToken), Currency.wrap(memecoin_));
        poolId = PoolKey(c0, c1, launch.poolFee, launch.tickSpacing, IHooks(hook_)).toId();
    }

    /// @notice Takes the escrow's native payout; forwarded by the same pull.
    receive() external payable {}

    // ------------------------------------------------------------------ IHookrRevenueSource

    /// @inheritdoc IHookrRevenueSource
    /// @dev The quote alone: the memecoin reaches the holders as drops unless the creator lists it as an asset.
    function assets() external view returns (Currency[] memory list) {
        list = new Currency[](1);
        list[0] = quote;
    }

    /// @inheritdoc IHookrRevenueSource
    function sourceKind() external pure returns (bytes32) {
        return SOURCE_KIND;
    }

    /// @inheritdoc IHookrRevenueSource
    function label() external pure returns (string memory) {
        return "Pons creator fee";
    }

    /// @inheritdoc IHookrRevenueSource
    function pullGas() external pure returns (uint32) {
        return PULL_GAS;
    }

    /// @inheritdoc IHookrRevenueSource
    /// @dev From `pending()` and what the adapter holds: native ETH; the quote when it is an ERC-20 the token lists;
    ///      the memecoin, with the creator's part of the buyback the adapter could release (the vault credits the
    ///      protocol's share to its own recipient), only when the token lists it (otherwise a pull streams it through
    ///      the drop box). Fees still in the hook, which a sweep would move first, are not counted.
    function pendingIncome() external view returns (Currency[] memory, uint256[] memory) {
        (uint256 eth, uint256 quoteAmount, uint256 memecoinAmount, uint256 buybackReleasable) = pending();
        if (buybackReleasable != 0) {
            (,, uint16 protocolBps) = IPonsV2BuybackVault(buybackVault).vestingTerms(memecoin);
            buybackReleasable = protocolBps >= 10_000 ? 0 : buybackReleasable - buybackReleasable * protocolBps / 10_000;
        }
        address[3] memory list;
        uint256[3] memory owed;
        owed[0] = eth;
        uint256 n = 1;
        if (!quote.isAddressZero()) (list[n], owed[n++]) = (Currency.unwrap(quote), quoteAmount);
        (list[n], owed[n++]) = (memecoin, memecoinAmount + buybackReleasable);
        return _income(list, owed, n);
    }

    /// @inheritdoc IHookrRevenueSource
    /// @dev `factory.getLaunchedToken(memecoin).creatorFeeRecipient == address(this)`.
    function bound() public view returns (bool) {
        return IPonsV2LaunchFactory(factory).getLaunchedToken(memecoin).creatorFeeRecipient == address(this);
    }

    /// @notice When the stream ends: Pons can move the right, so never a date of its own.
    /// @dev `ENDED` when not bound; else `REVOCABLE` with the pending override's `effectiveAt` when one names
    ///      another recipient and has not expired, zero otherwise.
    function ends() external view returns (EndKind, uint64) {
        if (!bound()) return (EndKind.ENDED, 0);
        (address newRecipient, uint256 effectiveAt, uint256 expiresAt) =
            IPonsV2LaunchFactory(factory).pendingCreatorFeeRecipient(memecoin);
        if (newRecipient == address(0) || newRecipient == address(this) || block.timestamp > expiresAt) {
            return (EndKind.REVOCABLE, 0);
        }
        return (EndKind.REVOCABLE, uint64(effectiveAt));
    }

    /// @notice Sweeps, releases and claims what the right earned and forwards it to the revenue token. Only the
    ///         revenue token, and only once it has this adapter as a door.
    /// @dev Claims even when the right no longer points here: what the escrow credited before a revocation is still
    ///      the holders'. The first pull that finds the adapter among the token's doors remembers it.
    function pull() external onlyRevenueToken nonReentrant {
        if (!_doorSeen) {
            if (!isDoor()) revert NotADoor();
            _doorSeen = true;
        }
        _sweep();
        _release();
        _claim();
        _forwardHeld(address(0));
        if (!quote.isAddressZero()) _forwardHeld(Currency.unwrap(quote));
        _forwardHeld(memecoin);
    }

    // ------------------------------------------------------------------ IHookrPonsAdapter

    /// @inheritdoc IHookrPonsAdapter
    function revocable() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IHookrPonsAdapter
    function pendingOverride() external view returns (address, uint256, uint256) {
        return IPonsV2LaunchFactory(factory).pendingCreatorFeeRecipient(memecoin);
    }

    /// @inheritdoc IHookrPonsAdapter
    function buybackEnabled() external view returns (bool) {
        return IPonsV2LaunchFactory(factory).getLaunchedToken(memecoin).buybackEnabled;
    }

    /// @inheritdoc IHookrPonsAdapter
    /// @dev One capped read of the token's `isDoor`; a token that does not answer it (no code, or not a revenue
    ///      token) is no door of anything.
    function isDoor() public view returns (bool) {
        if (_doorSeen) return true;
        (bool read, uint256 yes) =
            HookrForward.read(revenueToken, abi.encodeCall(IHookrRevenueToken.isDoor, (address(this))), BALANCE_GAS);
        return read && yes != 0;
    }

    /// @inheritdoc IHookrPonsAdapter
    function pending()
        public
        view
        returns (uint256 eth, uint256 quoteAmount, uint256 memecoinAmount, uint256 buybackReleasable)
    {
        IPonsV2FeeEscrow e = IPonsV2FeeEscrow(escrow);
        eth = e.balanceOf(address(this));
        if (!quote.isAddressZero()) quoteAmount = e.balanceOfToken(address(this), Currency.unwrap(quote));
        memecoinAmount = e.balanceOfToken(address(this), memecoin);
        (address creatorRecipient,,) = IPonsV2BuybackVault(buybackVault).vestingTerms(memecoin);
        if (creatorRecipient == address(this)) {
            buybackReleasable = IPonsV2BuybackVault(buybackVault).releasable(memecoin);
        }
    }

    /// @inheritdoc IHookrPonsAdapter
    /// @dev Returns the future right first, then attempts each escrow claim and refund independently. A failed
    ///      claim stays in the escrow, a refused refund stays here, and `recoverAbort` retries them. The admission
    ///      check runs again after the claims and refunds finish, so an admission during a refund reverts the
    ///      whole cancellation rather than paying the origin income that belongs to holders.
    function abort() external nonReentrant {
        if (msg.sender != origin) revert NotOrigin(msg.sender);
        _requireUnadmitted();
        IPonsV2LaunchFactory(factory).transferCreatorFeeRecipient(memecoin, origin);
        aborted = true;
        emit Aborted(origin);
        _recoverAbort(origin);
    }

    /// @inheritdoc IHookrPonsAdapter
    /// @dev Needs a completed `abort`, or a right that is no longer here: once Pons moves the right away (its owner's
    ///      override), `abort` cannot run, and an unbound adapter can never be admitted (the tokenizer refuses an
    ///      unbound source, `SourceNotBound`), so what the escrow credited before is the origin's. The admission check
    ///      runs first, so an adapter the token admitted before the override keeps its credit for holders.
    function recoverAbort(address to) external nonReentrant {
        if (msg.sender != origin) revert NotOrigin(msg.sender);
        _requireUnadmitted();
        if (!aborted && bound()) revert NotAborted();
        if (to == address(0) || to == address(this)) revert InvalidRecoveryRecipient(to);
        _recoverAbort(to);
    }

    // ------------------------------------------------------------------ the steps of a pull

    /// @dev Step 1: the adapter's own sweep, only when the hook would accept it from the pool's creator and it would
    ///      move something. The hook refuses a creator sweep that needs an internal swap, and a zero minimum would
    ///      refuse a conversion, so both are checked first.
    function _sweep() private {
        IPonsV2MemeHook h = IPonsV2MemeHook(hook);
        (bool registered,,,, address creator,,,,,,,,) = h.launches(poolId);
        if (!registered || creator != address(this)) return;
        address q = Currency.unwrap(quote);
        if (h.pendingFees(poolId, memecoin) != 0 || h.pendingCreatorTax(poolId, memecoin) != 0) return;
        if (h.pendingBuyback(poolId, q) != 0) return;
        if (h.pendingFees(poolId, q) == 0 && h.pendingCreatorTax(poolId, q) == 0) return;
        try h.sweepPoolFees{gas: SWEEP_GAS}(poolId, 0, 0) {
            emit Swept(poolId);
        } catch {}
    }

    /// @dev Step 2: the buyback release, only when the vault names this adapter and something vested; the vault
    ///      credits the escrow with the memecoin.
    function _release() private {
        IPonsV2BuybackVault v = IPonsV2BuybackVault(buybackVault);
        (address creatorRecipient,,) = v.vestingTerms(memecoin);
        if (creatorRecipient != address(this) || v.releasable(memecoin) == 0) return;
        try v.release{gas: RELEASE_GAS}(memecoin) returns (uint256 released) {
            emit BuybackReleased(released);
        } catch {}
    }

    /// @dev Step 3: the escrow claims, each only when the escrow owes something and each on its own attempt.
    function _claim() private {
        IPonsV2FeeEscrow e = IPonsV2FeeEscrow(escrow);
        uint256 eth;
        uint256 quoteAmount;
        uint256 memecoinAmount;
        if (e.balanceOf(address(this)) != 0) {
            try e.claim{gas: NATIVE_CLAIM_GAS}() returns (uint256 amount) {
                eth = amount;
            } catch {}
        }
        address q = Currency.unwrap(quote);
        if (q != address(0) && e.balanceOfToken(address(this), q) != 0) {
            try e.claimToken{gas: CLAIM_GAS}(q) returns (uint256 amount) {
                quoteAmount = amount;
            } catch {}
        }
        if (e.balanceOfToken(address(this), memecoin) != 0) {
            try e.claimToken{gas: CLAIM_GAS}(memecoin) returns (uint256 amount) {
                memecoinAmount = amount;
            } catch {}
        }
        if (eth != 0 || quoteAmount != 0 || memecoinAmount != 0) emit Claimed(eth, quoteAmount, memecoinAmount);
    }

    /// @dev Before admission only: a failed read of an existing token is not evidence that a refund is allowed.
    function _requireUnadmitted() private view {
        if (_doorSeen) revert AlreadyLive();
        if (revenueToken.code.length == 0) return;
        (bool read, uint256 yes) =
            HookrForward.read(revenueToken, abi.encodeCall(IHookrRevenueToken.isDoor, (address(this))), BALANCE_GAS);
        if (!read) revert AdmissionUnread();
        if (yes != 0) revert AlreadyLive();
    }

    /// @dev Only this adapter's own pre-admission currencies are refunded; nothing can sweep an admitted stream.
    function _recoverAbort(address to) private {
        _claim();
        _refundHeld(address(0), to);
        address q = Currency.unwrap(quote);
        if (q != address(0)) _refundHeld(q, to);
        _refundHeld(memecoin, to);
        _requireUnadmitted();
    }

    /// @dev Each failed read or payment is reported and leaves the currency available for another recovery attempt.
    function _refundHeld(address asset, address to) private {
        uint256 amount;
        bool ok;
        if (asset == address(0)) {
            amount = address(this).balance;
            if (amount == 0) return;
            ok = HookrForward.send(to, amount, SEND_GAS);
        } else {
            (ok, amount) = HookrForward.balanceOf(asset, address(this), BALANCE_GAS);
            if (!ok) {
                emit AbortRecoveryFailed(asset, to, 0);
                return;
            }
            if (amount == 0) return;
            ok = HookrForward.transfer(asset, to, amount, FORWARD_GAS);
        }
        if (ok) emit AbortRecovered(asset, to, amount);
        else emit AbortRecoveryFailed(asset, to, amount);
    }

    /// @dev The quote and the memecoin are the adapter's own; anything else leaves through `dropStray`.
    function _isOwnAsset(address asset) internal view override returns (bool) {
        return asset == Currency.unwrap(quote) || asset == memecoin;
    }
}
