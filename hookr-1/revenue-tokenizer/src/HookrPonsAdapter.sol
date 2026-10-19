// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IHookrRevenueSource} from "./interfaces/IHookrRevenueSource.sol";
import {IHookrPonsAdapter} from "./interfaces/IHookrPonsAdapter.sol";
import {IHookrRevenueToken} from "./interfaces/IHookrRevenueToken.sol";
import {IHookrDropBox} from "./interfaces/IHookrDropBox.sol";
import {HookrForward} from "./libraries/HookrForward.sol";
import {
    IPonsV2LaunchFactory,
    IPonsV2FeeEscrow,
    IPonsV2MemeHook,
    IPonsV2BuybackVault
} from "./interfaces/external/IPonsV2.sol";

/// @title Hookr Pons adapter, part of the HookRevenue Tokenizer
/// @notice The creator fee recipient of one Pons V2 launch, standing in for a revenue token. See IHookrPonsAdapter
///         for the rules; `docs/multi-stream.md` has the chain facts the design rests on.
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
///      and the memecoin's (`claimToken(memecoin)`), each only when nonzero, with CLAIM_GAS; (4) forward: native
///      ETH to the token with an exact send, the quote by `transfer` with FORWARD_GAS, the memecoin by `transfer`
///      when the token lists it (`isAsset`) and otherwise into the token's drop box (`approve` then `drop`) with
///      FORWARD_GAS. A failed step leaves what it could not move where it is. Nothing runs while the token has no
///      code (`NotLive`) or while the adapter is not one of the token's doors (`NotADoor`): the token seals its doors
///      once, so an adapter the mint did not list never pays that token, and a Pons right can only ever feed a token
///      that took the Hookr leg for it. The caps sum below the 3,000,000 stipend `pullGas` answers, so one step that
///      burns its whole cap never starves the ones after it.
///
///      One bit of state: whether the adapter has found itself among the token's doors (`_sealedIn`), set once and
///      never cleared, since doors are fixed at the seal. Nothing here is owned, nothing is paused and no function
///      moves the right but `abort`, which works only while no live token has the adapter as a door. The adapter is
///      never a payee of the token, so the sync's transient lock, the escrow's debit-before-pay and the capped
///      forwards are the whole safety case.
contract HookrPonsAdapter is IHookrPonsAdapter {
    using PoolIdLibrary for PoolKey;

    /// @inheritdoc IHookrPonsAdapter
    bytes32 public constant SOURCE_KIND = keccak256("pons.v2");
    /// @inheritdoc IHookrPonsAdapter
    uint256 public constant SWEEP_GAS = 1_000_000;
    /// @inheritdoc IHookrPonsAdapter
    uint256 public constant RELEASE_GAS = 400_000;
    /// @inheritdoc IHookrPonsAdapter
    uint256 public constant FORWARD_GAS = 300_000;
    /// @dev Gas one escrow claim gets: a debit and one transfer to this adapter.
    uint256 internal constant CLAIM_GAS = 200_000;
    /// @dev Gas the memecoin's `approve` of the drop box gets before `drop`.
    uint256 internal constant APPROVE_GAS = 100_000;
    /// @dev Gas a `balanceOf` read of the quote or the memecoin gets.
    uint256 internal constant BALANCE_GAS = 50_000;
    /// @dev What `pullGas` answers: every step at its cap, the escrow claims and the forwards.
    uint32 internal constant PULL_GAS = 3_000_000;
    /// @dev The most doors a revenue token has (IHookrRevenueToken.MAX_DOORS); `isDoor` reads no further.
    uint256 internal constant MAX_DOORS = 8;

    /// @inheritdoc IHookrRevenueSource
    address public immutable revenueToken;
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
    /// @dev Set the first time a pull finds this adapter among the revenue token's doors; doors never change.
    bool private _sealedIn;

    /// @param revenueToken_ The revenue token every pull pays, at its predicted address; it need not exist yet.
    /// @param factory_ The Pons V2 launch factory; must have code and know `memecoin_`.
    /// @param memecoin_ The Pons launch.
    /// @param origin_ The account that holds the creator right now and may `abort`.
    constructor(address revenueToken_, address factory_, address memecoin_, address origin_) {
        if (revenueToken_ == address(0) || factory_.code.length == 0 || origin_ == address(0)) revert InvalidConfig();
        IPonsV2LaunchFactory f = IPonsV2LaunchFactory(factory_);
        IPonsV2LaunchFactory.LaunchedToken memory launch = f.getLaunchedToken(memecoin_);
        if (!launch.exists) revert InvalidConfig();
        address hook_ = f.memeHook();
        address escrow_ = f.feeEscrow();
        address vault = f.buybackVault();
        if (hook_.code.length == 0 || escrow_.code.length == 0 || vault.code.length == 0) revert InvalidConfig();
        revenueToken = revenueToken_;
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
    /// @dev `factory.getLaunchedToken(memecoin).creatorFeeRecipient == address(this)`.
    function bound() public view returns (bool) {
        return IPonsV2LaunchFactory(factory).getLaunchedToken(memecoin).creatorFeeRecipient == address(this);
    }

    /// @inheritdoc IHookrRevenueSource
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

    /// @inheritdoc IHookrRevenueSource
    /// @dev Claims even when the right no longer points here: what the escrow credited before a revocation is still
    ///      the holders'. Pays only a token that sealed this adapter as a door; the first pull that finds it there
    ///      remembers it.
    function pull() external {
        if (revenueToken.code.length == 0) revert NotLive();
        if (!_sealedIn) {
            if (!isDoor()) revert NotADoor();
            _sealedIn = true;
        }
        _sweep();
        _release();
        _claim();
        _forwardAll();
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
    /// @dev At most `MAX_DOORS` reads of `doorAt`; a token that does not answer `doorCount` (no code, or not a
    ///      revenue token) is no door of anything.
    function isDoor() public view returns (bool) {
        if (_sealedIn) return true;
        IHookrRevenueToken t = IHookrRevenueToken(revenueToken);
        if (revenueToken.code.length == 0) return false;
        uint256 n;
        try t.doorCount() returns (uint256 count) {
            n = count > MAX_DOORS ? MAX_DOORS : count;
        } catch {
            return false;
        }
        for (uint256 i; i < n; ++i) {
            if (t.doorAt(i).target == address(this)) return true;
        }
        return false;
    }

    /// @inheritdoc IHookrPonsAdapter
    function pending()
        external
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
    /// @dev Only `origin`, only while the adapter is not a door of the revenue token (`isDoor`, which is false while
    ///      the token has no code or is not sealed): `factory.transferCreatorFeeRecipient(memecoin, origin)`, which
    ///      the factory accepts only from the current recipient, so it fails on its own when the right is not here.
    function abort() external {
        if (msg.sender != origin) revert NotOrigin(msg.sender);
        if (isDoor()) revert AlreadyLive();
        IPonsV2LaunchFactory(factory).transferCreatorFeeRecipient(memecoin, origin);
        emit Aborted(origin);
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
            try e.claim{gas: CLAIM_GAS}() returns (uint256 amount) {
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

    /// @dev Step 4: everything the adapter holds goes to the token: native ETH and the quote as assets, the
    ///      memecoin as an asset when listed and as a drop otherwise. Every balance read and every transfer is
    ///      capped and copies at most one word (HookrForward), so neither the quote nor the memecoin can revert a
    ///      pull or make it pay for an answer.
    function _forwardAll() private {
        uint256 eth = address(this).balance;
        if (eth != 0) {
            if (HookrForward.send(revenueToken, eth, FORWARD_GAS)) emit Forwarded(Currency.wrap(address(0)), eth);
            else emit ForwardFailed(Currency.wrap(address(0)), eth);
        }
        address q = Currency.unwrap(quote);
        if (q != address(0)) _forwardAsset(q);
        (bool read, uint256 held) = HookrForward.balanceOf(memecoin, address(this), BALANCE_GAS);
        if (!read || held == 0) return;
        if (IHookrRevenueToken(revenueToken).isAsset(Currency.wrap(memecoin))) _forwardAsset(memecoin);
        else _drop(memecoin, held);
    }

    /// @dev One ERC-20 `transfer` of the adapter's whole balance to the revenue token with `FORWARD_GAS`. Never
    ///      reverts; a balance that cannot be read is left alone.
    function _forwardAsset(address asset) private {
        (bool read, uint256 amount) = HookrForward.balanceOf(asset, address(this), BALANCE_GAS);
        if (!read || amount == 0) return;
        if (HookrForward.transfer(asset, revenueToken, amount, FORWARD_GAS)) {
            emit Forwarded(Currency.wrap(asset), amount);
        } else {
            emit ForwardFailed(Currency.wrap(asset), amount);
        }
    }

    /// @dev `approve` the token's drop box for `amount` of `asset` with `APPROVE_GAS`, then `drop` with
    ///      `FORWARD_GAS`. A refusal (no earning supply yet, the box's own rules) leaves the asset here for the next
    ///      pull. Never reverts.
    function _drop(address asset, uint256 amount) private {
        address box = IHookrRevenueToken(revenueToken).dropBox();
        if (HookrForward.approve(asset, box, amount, APPROVE_GAS)) {
            try IHookrDropBox(box).drop{gas: FORWARD_GAS}(asset, amount) returns (uint256 dropId) {
                emit StrayDropped(asset, amount, dropId);
                return;
            } catch {}
        }
        emit StrayDropFailed(asset, amount);
    }
}
