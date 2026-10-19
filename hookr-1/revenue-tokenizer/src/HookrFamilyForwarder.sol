// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {IHookrFamilyLock} from "hookr/interfaces/IHookrFamilyLock.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {HookrAssetList} from "./base/HookrAssetList.sol";
import {HookrForward} from "./libraries/HookrForward.sol";
import {IHookrFamilyForwarder} from "./interfaces/IHookrFamilyForwarder.sol";
import {IHookrRevenueToken} from "./interfaces/IHookrRevenueToken.sol";
import {IHookrRulesDoor} from "./interfaces/IHookrRulesDoor.sol";

/// @title Hookr family forwarder, part of the HookRevenue Tokenizer
/// @notice The beneficiary of the HookrLauncher families locked for one revenue token in the live HookrFamilyLock: it pulls
///         LP fees and arb recapture accruals (never principal) and forwards them to the revenue token, and from a
///         family's unlock block releases it to the account the tokenizer recorded.
/// @dev Reaches the families only through the lock's beneficiary entry points (`collect`, `claimRecapture`,
///      `release`) and the launcher's `redeem` for ERC-6909 claims a release leaves here. Holds nothing between calls
///      but those claims. The revenue token itself, earned as the market pool's subject-side LP fee, goes to 0xdead.
///
///      Every call into the lock and the Rules during a pull is wrapped on its own, so one member whose quote is paused
///      or whose Rules refuse a claim this block does not stop the others: what it could not pull waits where it is
///      (fees in the position, accruals in the Rules ledger) for the next pull. The forwarding step at the end is
///      wrapped the same way, asset by asset, with `FORWARD_GAS` per transfer: an asset whose issuer refuses the revenue
///      token's address (a blocklist), or whose transfer burns gas, stays here for a later pull (`ForwardFailed`) and
///      never stops the native ETH, the other assets or a release. Exactness buys nothing here: the revenue token
///      recognizes what reached it by balance delta in its own sync. The release's redeem of ERC-6909 claims is
///      wrapped too, so a refused claim stays here as a claim.
///
///      Known limit: an accrual in a currency that is neither one of the token's assets nor the revenue token stays
///      claimable in the Rules ledger for good (`claimable(c, forwarder)`), and an ERC-6909 claim in such a currency
///      stays here. The tokenizer prevents both by making every family currency an asset.
contract HookrFamilyForwarder is IHookrFamilyForwarder, HookrAssetList {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @inheritdoc IHookrFamilyForwarder
    address public constant DEAD = address(0xdead);
    /// @inheritdoc IHookrFamilyForwarder
    uint256 public constant FORWARD_GAS = 300_000;
    /// @inheritdoc IHookrFamilyForwarder
    uint256 public constant BALANCE_GAS = 50_000;

    /// @inheritdoc IHookrFamilyForwarder
    address public immutable token;
    /// @inheritdoc IHookrFamilyForwarder
    address public immutable lock;
    /// @inheritdoc IHookrFamilyForwarder
    address public immutable launcher;
    /// @inheritdoc IHookrFamilyForwarder
    address public immutable tokenizer;
    IPoolManager internal immutable _manager;

    Family[] internal _families;
    bool private transient _busy;

    modifier nonReentrant() {
        if (_busy) revert Reentered();
        _busy = true;
        _;
        _busy = false;
    }

    /// @param token_ The revenue token every pull pays; its asset list is read once here (HookrAssetList).
    /// @param lock_ The HookrFamilyLock; its launcher and that launcher's PoolManager are read from it.
    /// @param tokenizer_ The tokenizer that may register families.
    constructor(address token_, address lock_, address tokenizer_) HookrAssetList(token_) {
        if (lock_.code.length == 0 || tokenizer_ == address(0)) revert InvalidConfig();
        token = token_;
        lock = lock_;
        tokenizer = tokenizer_;
        address launcher_ = IHookrFamilyLock(lock_).launcher();
        if (launcher_.code.length == 0) revert InvalidConfig();
        launcher = launcher_;
        _manager = IHookrLauncher(launcher_).poolManager();
    }

    /// @notice Takes the native ETH the lock's `collect` pays this beneficiary; forwarded by the same pull.
    receive() external payable {}

    // ------------------------------------------------------------------ views

    /// @inheritdoc IHookrFamilyForwarder
    function familyCount() external view returns (uint256) {
        return _families.length;
    }

    /// @inheritdoc IHookrFamilyForwarder
    function familyAt(uint256 i) external view returns (Family memory) {
        return _families[i];
    }

    /// @inheritdoc IHookrFamilyForwarder
    /// @dev The launcher holds every family position under the salt `keccak256(abi.encode(familyId, member))`; the
    ///      unclaimed fees are the fee growth inside the range since the position last settled, times its liquidity,
    ///      as HookrLiquidityVault.pendingFees reads them. Needs a real PoolManager (`extsload`).
    function pendingFees(uint256 i, uint8 member) external view returns (uint256 amount0, uint256 amount1) {
        if (i >= _families.length) revert UnknownFamily(i);
        bytes32 familyId = _families[i].id;
        IHookrLauncher.Position memory p = IHookrLauncher(launcher).position(familyId, member);
        PoolId poolId = p.key.toId();
        (uint128 liquidity, uint256 last0, uint256 last1) = _manager.getPositionInfo(
            poolId, launcher, p.tickLower, p.tickUpper, keccak256(abi.encode(familyId, member))
        );
        if (liquidity == 0) return (0, 0);
        (uint256 inside0, uint256 inside1) = _manager.getFeeGrowthInside(poolId, p.tickLower, p.tickUpper);
        unchecked {
            amount0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            amount1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    // ------------------------------------------------------------------ tokenizer

    /// @inheritdoc IHookrFamilyForwarder
    function register(bytes32 familyId, address returnTo) external {
        if (msg.sender != tokenizer) revert Unauthorized(msg.sender);
        (address beneficiary, uint64 unlockBlock) = IHookrFamilyLock(lock).lockOf(familyId);
        if (beneficiary != address(this)) revert NotLockedHere(familyId);
        if (returnTo == address(0) || returnTo == address(this) || returnTo == lock || returnTo == launcher) {
            revert InvalidReturnTo(returnTo);
        }
        for (uint256 i; i < _families.length; ++i) {
            if (_families[i].id == familyId) revert InvalidConfig();
        }
        _families.push(Family(familyId, unlockBlock, returnTo, false));
        emit FamilyRegistered(familyId, unlockBlock, returnTo);
    }

    // ------------------------------------------------------------------ anyone

    /// @inheritdoc IHookrFamilyForwarder
    /// @dev The ETH counted is what reached the token through this pull: the LP fees and accruals collected here and
    ///      forwarded, plus the Rules claims `claimTo` paid to the token directly.
    function pull() external nonReentrant returns (uint256 ethForwarded) {
        uint256 n = _families.length;
        for (uint256 i; i < n; ++i) {
            Family storage f = _families[i];
            if (!f.released) ethForwarded += _pullFamily(f.id);
        }
        ethForwarded += _forwardAll();
    }

    /// @inheritdoc IHookrFamilyForwarder
    /// @dev The final pull runs before the lock's `release`, which takes the fees earned since as ERC-6909 claims and
    ///      moves them here; those are redeemed to the token in the same call. Fees the family earns while `returnTo`
    ///      has not yet accepted reach the handover, whose `sweep` sends them here as claims too: `flushClaims` then.
    ///      A family locked for good (unlock block type(uint64).max) is never released.
    function release(uint256 i) external nonReentrant returns (address handover) {
        if (i >= _families.length) revert UnknownFamily(i);
        Family storage f = _families[i];
        bytes32 familyId = f.id;
        if (f.released) revert AlreadyReleased(familyId);
        if (f.unlockBlock == type(uint64).max || block.number < f.unlockBlock) {
            revert StillLocked(familyId, f.unlockBlock);
        }
        f.released = true;
        _pullFamily(familyId);
        uint8 n = IHookrLauncher(launcher).memberCount(familyId);
        PoolKey[] memory keys = new PoolKey[](n);
        for (uint8 m; m < n; ++m) {
            keys[m] = IHookrLauncher(launcher).position(familyId, m).key;
        }
        address returnTo = f.returnTo;
        handover = IHookrFamilyLock(lock).release(familyId, returnTo);
        for (uint8 m; m < n; ++m) {
            _flush(keys[m].currency0);
            _flush(keys[m].currency1);
        }
        _forwardAll();
        emit FamilyReturned(familyId, returnTo, handover);
    }

    /// @inheritdoc IHookrFamilyForwarder
    function flushClaims(Currency currency) external nonReentrant returns (uint256 amount) {
        return _flush(currency);
    }

    // ------------------------------------------------------------------ internals

    /// @dev One family's pull: every member's LP fees and accrual, then the Rules claims of every asset and of the
    ///      revenue token in every member's Rules. The collected balances stay here until `_forwardAll`; returns the native ETH
    ///      the Rules paid the token directly.
    function _pullFamily(bytes32 familyId) private returns (uint256 nativeClaimed) {
        uint8 n = IHookrLauncher(launcher).memberCount(familyId);
        for (uint8 m; m < n; ++m) {
            nativeClaimed += _pullMember(familyId, m);
        }
    }

    /// @dev `collect` pays this forwarder the member's LP fees in its pool's two currencies (and, on a recapture
    ///      member, the launcher moves the accrual into this forwarder's Rules claims in the same call);
    ///      `claimRecapture` moves whatever accrued in between. Then every claim this forwarder holds in the member's
    ///      Rules is paid: an asset to the token, the revenue token to 0xdead. Each call is wrapped on its own.
    function _pullMember(bytes32 familyId, uint8 member) private returns (uint256 nativeClaimed) {
        try IHookrFamilyLock(lock).collect(familyId, member, 0) returns (uint256 amount0, uint256 amount1) {
            emit Collected(familyId, member, amount0, amount1);
        } catch {}
        try IHookrFamilyLock(lock).claimRecapture(familyId, member) returns (uint256) {} catch {}
        address rules = _rulesOf(familyId, member);
        if (rules == address(0)) return 0;
        uint256 assets = _assetCount;
        for (uint256 a; a < assets; ++a) {
            Currency currency = _assetAt(a);
            uint256 paid = _claimRules(rules, currency, token);
            if (currency.isAddressZero()) nativeClaimed = paid;
        }
        _claimRules(rules, Currency.wrap(token), DEAD);
    }

    /// @dev The Rules of the member's pool, read from its root's `poolConfig`; zero when the read fails.
    function _rulesOf(bytes32 familyId, uint8 member) private view returns (address) {
        PoolKey memory key = IHookrLauncher(launcher).position(familyId, member).key;
        if (address(key.hooks).code.length == 0) return address(0);
        try IHookrRoot(address(key.hooks)).poolConfig(key.toId()) returns (HookrTypes.PoolConfig memory pc) {
            return pc.rules;
        } catch {
            return address(0);
        }
    }

    /// @dev Pays this forwarder's claim in `currency` on `rules` to `to`, when there is one, and returns what was paid.
    ///      A Rules that refuses the payout this block (a paused quote) keeps the claim for the next pull.
    function _claimRules(address rules, Currency currency, address to) private returns (uint256 paid) {
        if (rules.code.length == 0) return 0;
        try IHookrRulesDoor(rules).claimable(currency, address(this)) returns (uint256 owed) {
            if (owed == 0) return 0;
        } catch {
            return 0;
        }
        try IHookrRulesDoor(rules).claimTo(currency, to) returns (uint256 amount) {
            paid = amount;
        } catch {}
    }

    /// @dev Forwards this forwarder's whole balance of every token asset to the token, each on its own attempt, and
    ///      of the revenue token to 0xdead. Returns the native ETH forwarded. An asset the token could not take stays
    ///      here (`ForwardFailed`) for the next pull.
    function _forwardAll() private returns (uint256 ethForwarded) {
        uint256 assets = _assetCount;
        for (uint256 a; a < assets; ++a) {
            Currency currency = _assetAt(a);
            (bool read, uint256 amount) = _held(currency);
            if (!read) {
                emit ForwardFailed(currency, 0);
                continue;
            }
            if (amount == 0) continue;
            if (_forward(currency, amount)) {
                if (currency.isAddressZero()) ethForwarded = amount;
                emit Forwarded(currency, amount);
            } else {
                emit ForwardFailed(currency, amount);
            }
        }
        uint256 own = IERC20(token).balanceOf(address(this));
        if (own != 0) {
            IERC20(token).safeTransfer(DEAD, own);
            emit Retired(own);
        }
    }

    /// @dev This forwarder's balance of `currency`: the native balance, or a `balanceOf` read with `BALANCE_GAS`
    ///      that may fail (`read` false) without reverting the pull.
    function _held(Currency currency) private view returns (bool read, uint256 amount) {
        if (currency.isAddressZero()) return (true, address(this).balance);
        return HookrForward.balanceOf(Currency.unwrap(currency), address(this), BALANCE_GAS);
    }

    /// @dev One forward to the revenue token with `FORWARD_GAS`: a plain call for native ETH (the token's `receive` is
    ///      empty), `transfer` for an ERC-20 that copies at most one word of its answer (HookrForward). Never reverts.
    function _forward(Currency currency, uint256 amount) private returns (bool ok) {
        address asset = Currency.unwrap(currency);
        if (asset == address(0)) return HookrForward.send(token, amount, FORWARD_GAS);
        return HookrForward.transfer(asset, token, amount, FORWARD_GAS);
    }

    /// @inheritdoc IHookrFamilyForwarder
    /// @dev The token's own `dropStray` then splits it. Native ETH, the token's assets and the revenue token itself
    ///      (retired to 0xdead by every pull) are `pull`'s.
    function forwardUnlisted(address asset) external nonReentrant returns (uint256 amount) {
        if (asset == address(0) || asset == token) revert ListedAsset(asset);
        uint256 assets = _assetCount;
        for (uint256 a = 1; a < assets; ++a) {
            if (Currency.unwrap(_assetAt(a)) == asset) revert ListedAsset(asset);
        }
        bool read;
        (read, amount) = HookrForward.balanceOf(asset, address(this), BALANCE_GAS);
        if (!read || amount == 0) revert NothingToForward(asset);
        if (!HookrForward.transfer(asset, token, amount, FORWARD_GAS)) revert ForwardRefused(asset);
        emit UnlistedForwarded(asset, amount);
    }

    /// @dev Redeems this forwarder's ERC-6909 claim in `currency` through the launcher, straight to the token (an
    ///      asset) or to 0xdead (the revenue token). A claim in any other currency stays here: paying it into the token
    ///      would strand it where no asset ledger reaches it. A redeem the asset refuses (the token's address
    ///      blocked by its issuer) leaves the claim here too (`ForwardFailed`), for a later `flushClaims`.
    function _flush(Currency currency) private returns (uint256 amount) {
        uint256 id = currency.toId();
        amount = _manager.balanceOf(address(this), id);
        if (amount == 0) return 0;
        address to;
        if (Currency.unwrap(currency) == token) to = DEAD;
        else if (IHookrRevenueToken(token).isAsset(currency)) to = token;
        else return 0;
        _manager.approve(launcher, id, amount);
        try IHookrLauncher(launcher).redeem(currency, amount, to) {
            if (to == DEAD) emit Retired(amount);
            else emit Forwarded(currency, amount);
        } catch {
            emit ForwardFailed(currency, amount);
            return 0;
        }
    }
}
