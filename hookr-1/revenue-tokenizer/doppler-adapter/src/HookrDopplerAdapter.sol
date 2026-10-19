// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IHookrRevenueSource} from "hookr-revenue/interfaces/IHookrRevenueSource.sol";
import {IHookrRevenueToken} from "hookr-revenue/interfaces/IHookrRevenueToken.sol";
import {IHookrDropBox} from "hookr-revenue/interfaces/IHookrDropBox.sol";
import {IHookrDropHost} from "hookr-revenue/interfaces/IHookrDropHost.sol";
import {IHookrDopplerAdapter} from "./interfaces/IHookrDopplerAdapter.sol";
import {IDopplerHookInitializer, IDopplerAirlock} from "./interfaces/external/IDoppler.sol";

/// @title Hookr Doppler adapter, a revenue source of the HookRevenue Tokenizer
/// @notice A beneficiary share of one Doppler launch, standing in for a revenue token. See IHookrDopplerAdapter for
///         the rules; `docs/doppler.md` has the chain facts the design rests on.
/// @dev Every pin is read at construction: from the initializer the launch's pool key (its two currencies, fee,
///      spacing and hook, which must be the initializer itself), the pool id the initializer stored the
///      beneficiaries under and the Airlock; from the Airlock the launch's integrator; and the share the origin
///      holds then. The launch must be `Locked` (only a locked pool has shares) and the revenue token must not exist
///      yet (an adapter can only become a source of a token minted after it).
///
///      pull(), in order, each step its own attempt with a gas cap: (1) when the adapter holds a share,
///      `collectFees(poolId)` with COLLECT_GAS (it pays this adapter, the caller, its share of everything
///      collected so far, both currencies); (2) forward: native ETH to the token with FORWARD_GAS, then the
///      numeraire and the launch token, each read with READ_GAS, checked with `isAsset` (READ_GAS) and sent by
///      `transfer` (FORWARD_GAS) when the token lists it, or into the token's drop box (`approve` then `drop`) when
///      it does not. A failed step leaves what it could not move where it is and never undoes another step. Nothing
///      runs while the token has no code (`NotLive`) or has not sealed this adapter as a door (`NotADoor`), so the
///      share never feeds a token that took no Hookr leg for it. For a token the tokenizer minted with this source,
///      which lists both currencies, the caps sum to 2,600,000, under the 3,000,000 stipend `pullGas` answers.
///
///      One bit of state: whether the adapter has found itself among the token's doors (`_sealedIn`), set once and
///      never cleared, since doors are fixed at the seal. Nothing here is owned, nothing is paused and, once a token
///      has sealed the adapter as a door, no function moves the share. The adapter is never a payee of the token, so
///      the sync's transient lock, Doppler's own reentrancy guard and forwards by balance are the whole safety
///      case.
contract HookrDopplerAdapter is IHookrDopplerAdapter {
    using PoolIdLibrary for PoolKey;

    /// @inheritdoc IHookrDopplerAdapter
    bytes32 public constant SOURCE_KIND = keccak256("doppler.v4");
    /// @inheritdoc IHookrDopplerAdapter
    uint256 public constant COLLECT_GAS = 1_500_000;
    /// @inheritdoc IHookrDopplerAdapter
    uint256 public constant FORWARD_GAS = 300_000;
    /// @inheritdoc IHookrDopplerAdapter
    uint256 public constant READ_GAS = 50_000;
    /// @dev Gas an `approve` of the drop box gets before `drop`.
    uint256 internal constant APPROVE_GAS = 100_000;
    /// @dev What `pullGas` answers: the collection at its cap and the forwards.
    uint32 internal constant PULL_GAS = 3_000_000;
    /// @dev Doppler's `PoolStatus.Locked`: the only status in which fees are collected and shares exist.
    uint8 internal constant LOCKED = 2;
    /// @dev Doppler's `ON_GRADUATION_FLAG`: a Doppler hook with it lets anyone `graduate` the pool.
    uint256 internal constant GRADUATION_FLAG = 1 << 2;
    /// @dev One share in Doppler's units (WAD).
    uint256 internal constant WAD = 1e18;
    /// @dev The timelock Doppler launches without governance record; it can never call anything.
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @dev The most doors a revenue token has (IHookrRevenueToken.MAX_DOORS); `isDoor` reads no further.
    uint256 internal constant MAX_DOORS = 8;

    /// @inheritdoc IHookrRevenueSource
    address public immutable revenueToken;
    /// @inheritdoc IHookrDopplerAdapter
    address public immutable initializer;
    /// @inheritdoc IHookrDopplerAdapter
    address public immutable airlock;
    /// @inheritdoc IHookrDopplerAdapter
    address public immutable launchToken;
    /// @inheritdoc IHookrDopplerAdapter
    Currency public immutable numeraire;
    /// @inheritdoc IHookrDopplerAdapter
    PoolId public immutable poolId;
    /// @inheritdoc IHookrDopplerAdapter
    address public immutable origin;
    /// @inheritdoc IHookrDopplerAdapter
    uint256 public immutable originShares;
    /// @inheritdoc IHookrDopplerAdapter
    address public immutable integrator;
    /// @dev Whether the launch token is the pool's currency0 (then the numeraire is currency1).
    bool internal immutable launchIsCurrency0;
    /// @dev Set the first time a pull finds this adapter among the revenue token's doors; doors never change.
    bool private _sealedIn;

    /// @param revenueToken_ The revenue token every pull pays, at its predicted address; it must not exist yet.
    /// @param initializer_ The Doppler hook initializer; must have code and hold `launchToken_`'s locked pool.
    /// @param launchToken_ The launched token.
    /// @param origin_ The account that holds the share now (or has moved it to this adapter's address already).
    constructor(address revenueToken_, address initializer_, address launchToken_, address origin_) {
        if (
            revenueToken_ == address(0) || revenueToken_.code.length != 0 || origin_ == address(0)
                || initializer_.code.length == 0
        ) {
            revert InvalidConfig();
        }
        IDopplerHookInitializer i = IDopplerHookInitializer(initializer_);
        (,,,, uint8 status, PoolKey memory key,) = i.getState(launchToken_);
        if (status != LOCKED || address(key.hooks) != initializer_) revert InvalidConfig();
        bool isCurrency0 = Currency.unwrap(key.currency0) == launchToken_;
        if (!isCurrency0 && Currency.unwrap(key.currency1) != launchToken_) revert InvalidConfig();
        PoolId id = key.toId();
        (,,,, IHooks stored) = i.getPoolKey(id);
        if (address(stored) != initializer_) revert InvalidConfig();
        address airlock_ = i.airlock();
        if (airlock_.code.length == 0) revert InvalidConfig();
        (,,,,,,,,, address integrator_) = IDopplerAirlock(airlock_).getAssetData(launchToken_);
        revenueToken = revenueToken_;
        initializer = initializer_;
        airlock = airlock_;
        launchToken = launchToken_;
        numeraire = isCurrency0 ? key.currency1 : key.currency0;
        poolId = id;
        origin = origin_;
        originShares = i.getShares(id, origin_) + i.getShares(id, address(this));
        integrator = integrator_;
        launchIsCurrency0 = isCurrency0;
    }

    /// @notice Takes the initializer's native payout when a currency is native ETH; forwarded by the next pull.
    receive() external payable {}

    // ------------------------------------------------------------------ IHookrRevenueSource

    /// @inheritdoc IHookrRevenueSource
    /// @dev Both currencies of the pool: the numeraire, then the launch token. The tokenizer then requires the
    ///      token to list both, so both stream through the token's index, however often and whenever anyone pulls.
    function assets() external view returns (Currency[] memory list) {
        list = new Currency[](2);
        list[0] = numeraire;
        list[1] = Currency.wrap(launchToken);
    }

    /// @inheritdoc IHookrRevenueSource
    function sourceKind() external pure returns (bytes32) {
        return SOURCE_KIND;
    }

    /// @inheritdoc IHookrRevenueSource
    function label() external pure returns (string memory) {
        return "Doppler fee share";
    }

    /// @inheritdoc IHookrRevenueSource
    function pullGas() external pure returns (uint32) {
        return PULL_GAS;
    }

    /// @inheritdoc IHookrRevenueSource
    /// @dev The adapter holds a nonzero share and the pool is still `Locked`, so the share still earns.
    function bound() public view returns (bool) {
        if (shares() == 0) return false;
        (,,,, uint8 status,,) = IDopplerHookInitializer(initializer).getState(launchToken);
        return status == LOCKED;
    }

    /// @inheritdoc IHookrRevenueSource
    /// @dev `ENDED` when not `bound()`. `REVOCABLE` with zero when a graduation path exists, or when the numeraire is
    ///      an ERC-20 (its issuer may be able to block, pause, burn from or replace it, and Doppler pays both sides
    ///      in one call, so that stops the launch-token side too). `FOREVER` only for a native ETH numeraire with no
    ///      graduation path. Never `AT_BLOCK` or `AT_TIME`: a share has no term.
    function ends() external view returns (EndKind, uint64) {
        if (!bound()) return (EndKind.ENDED, 0);
        (,, address hook,,,,) = IDopplerHookInitializer(initializer).getState(launchToken);
        if (_graduationPath(hook) || !numeraire.isAddressZero()) return (EndKind.REVOCABLE, 0);
        return (EndKind.FOREVER, 0);
    }

    /// @inheritdoc IHookrRevenueSource
    /// @dev Forwards even when the adapter holds no share any more: whatever reached it is still the holders'.
    /// @dev Pays only a token that sealed this adapter as a door; the first call that finds it there remembers it.
    function pull() external {
        _requireDoor();
        _collect(poolId);
        _forwardEth();
        if (!numeraire.isAddressZero()) _forward(Currency.unwrap(numeraire));
        _forward(launchToken);
    }

    // ------------------------------------------------------------------ IHookrDopplerAdapter

    /// @inheritdoc IHookrDopplerAdapter
    /// @dev At most `MAX_DOORS` reads of `doorAt`; a token that does not answer `doorCount` (no code, or not a
    ///      revenue token) is no door of anything.
    function isDoor() public view returns (bool) {
        if (_sealedIn) return true;
        if (revenueToken.code.length == 0) return false;
        IHookrRevenueToken t = IHookrRevenueToken(revenueToken);
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

    /// @inheritdoc IHookrDopplerAdapter
    function shares() public view returns (uint256) {
        return IDopplerHookInitializer(initializer).getShares(poolId, address(this));
    }

    /// @inheritdoc IHookrDopplerAdapter
    function revocable() external pure returns (bool) {
        return false;
    }

    /// @inheritdoc IHookrDopplerAdapter
    function graduable() external view returns (bool) {
        (,, address hook,, uint8 status,,) = IDopplerHookInitializer(initializer).getState(launchToken);
        return status == LOCKED && _graduationPath(hook);
    }

    /// @inheritdoc IHookrDopplerAdapter
    function hookSetter() public view returns (address) {
        (, address timelock,,,,,,,,) = IDopplerAirlock(airlock).getAssetData(launchToken);
        return timelock == DEAD ? address(0) : timelock;
    }

    /// @inheritdoc IHookrDopplerAdapter
    function pending() external view returns (uint256 numeraireAmount, uint256 launchTokenAmount) {
        IDopplerHookInitializer i = IDopplerHookInitializer(initializer);
        uint256 s = i.getShares(poolId, address(this));
        if (s == 0) return (0, 0);
        uint256 owed0 = (i.getCumulatedFees0(poolId) - i.getLastCumulatedFees0(poolId, address(this))) * s / WAD;
        uint256 owed1 = (i.getCumulatedFees1(poolId) - i.getLastCumulatedFees1(poolId, address(this))) * s / WAD;
        (numeraireAmount, launchTokenAmount) = launchIsCurrency0 ? (owed1, owed0) : (owed0, owed1);
    }

    /// @inheritdoc IHookrDopplerAdapter
    function sweep(address asset) external {
        _requireDoor();
        if (asset == address(0)) _forwardEth();
        else _forward(asset);
    }

    /// @inheritdoc IHookrDopplerAdapter
    function collect(PoolId other) external {
        _requireDoor();
        _collect(other);
        (Currency c0, Currency c1,,,) = IDopplerHookInitializer(initializer).getPoolKey(other);
        _forwardEth();
        if (!c0.isAddressZero()) _forward(Currency.unwrap(c0));
        if (!c1.isAddressZero()) _forward(Currency.unwrap(c1));
    }

    /// @inheritdoc IHookrDopplerAdapter
    /// @dev Only `origin`, only while no token has sealed this adapter as a door (`isDoor`, false while the token
    ///      has no code or left the adapter out). Doppler moves every share of the caller at once and only by the caller, and shares never split, so a
    ///      share that was more than half of the launch can never be matched by any mix of the other holders' shares
    ///      (they add up to less). When the adapter holds exactly that much, it holds the origin's share and nothing
    ///      else. `updateBeneficiary(poolId, origin)` first pays this adapter what its share is owed; then every unit
    ///      of the launch token, the numeraire and native ETH the adapter holds goes to `origin`. Reverts whole when a
    ///      pay-back is refused.
    function abort() external {
        if (msg.sender != origin) revert NotOrigin(msg.sender);
        if (isDoor()) revert AlreadyLive();
        uint256 held = shares();
        if (originShares * 2 <= WAD || held != originShares) revert AbortRefused(held, originShares);
        IDopplerHookInitializer(initializer).updateBeneficiary(poolId, origin);
        _payBack(launchToken);
        if (!numeraire.isAddressZero()) _payBack(Currency.unwrap(numeraire));
        uint256 eth = address(this).balance;
        if (eth != 0) {
            (bool ok,) = origin.call{value: eth}("");
            if (!ok) revert TransferFailed(address(0));
        }
        emit Aborted(origin, held);
    }

    // ------------------------------------------------------------------ the steps of a pull

    /// @dev The token exists and has sealed this adapter as a door; remembered the first time it is found.
    function _requireDoor() private {
        if (revenueToken.code.length == 0) revert NotLive();
        if (!_sealedIn) {
            if (!isDoor()) revert NotADoor();
            _sealedIn = true;
        }
    }

    /// @dev The adapter's own collection of `pool`, only while it holds a share there (Doppler pays the caller
    ///      alone).
    function _collect(PoolId pool) private {
        IDopplerHookInitializer i = IDopplerHookInitializer(initializer);
        if (i.getShares(pool, address(this)) == 0) return;
        try i.collectFees{gas: COLLECT_GAS}(pool) {
            emit Collected(pool);
        } catch {
            emit CollectFailed(pool);
        }
    }

    /// @dev Native ETH the adapter holds goes into the token's empty `receive` with `FORWARD_GAS`. Never reverts.
    function _forwardEth() private {
        uint256 eth = address(this).balance;
        if (eth == 0) return;
        (bool ok,) = revenueToken.call{value: eth, gas: FORWARD_GAS}("");
        if (ok) emit Forwarded(Currency.wrap(address(0)), eth);
        else emit ForwardFailed(Currency.wrap(address(0)), eth);
    }

    /// @dev The adapter's whole balance of the ERC-20 `asset` goes to the token: by `transfer` with `FORWARD_GAS`
    ///      when the token lists it, into the token's drop box otherwise. A balance read or listing check that fails
    ///      skips this asset alone (`ForwardFailed`, with zero when the balance could not be read). Never reverts.
    function _forward(address asset) private {
        (bool read, uint256 amount) = _readWord(asset, abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!read) {
            emit ForwardFailed(Currency.wrap(asset), 0);
            return;
        }
        if (amount == 0) return;
        (bool checked, uint256 listed) =
            _readWord(revenueToken, abi.encodeCall(IHookrRevenueToken.isAsset, (Currency.wrap(asset))));
        if (!checked) {
            emit ForwardFailed(Currency.wrap(asset), amount);
            return;
        }
        if (listed == 0) {
            _drop(asset, amount);
        } else if (_call(asset, FORWARD_GAS, abi.encodeCall(IERC20.transfer, (revenueToken, amount)))) {
            emit Forwarded(Currency.wrap(asset), amount);
        } else {
            emit ForwardFailed(Currency.wrap(asset), amount);
        }
    }

    /// @dev `approve` the token's drop box for `amount` of `asset` with `APPROVE_GAS`, then `drop` with
    ///      `FORWARD_GAS`. A refusal (no earning supply yet, the box's own rules) leaves the asset here for the next
    ///      pull. Never reverts.
    function _drop(address asset, uint256 amount) private {
        (bool found, uint256 word) = _readWord(revenueToken, abi.encodeCall(IHookrDropHost.dropBox, ()));
        address box = address(uint160(word));
        if (found && box != address(0) && _call(asset, APPROVE_GAS, abi.encodeCall(IERC20.approve, (box, amount)))) {
            try IHookrDropBox(box).drop{gas: FORWARD_GAS}(asset, amount) returns (uint256 dropId) {
                emit StrayDropped(asset, amount, dropId);
                return;
            } catch {}
        }
        emit StrayDropFailed(asset, amount);
    }

    /// @dev `abort`'s pay-back of the adapter's whole balance of `asset` to `origin`; reverts on a refusal.
    function _payBack(address asset) private {
        uint256 amount = IERC20(asset).balanceOf(address(this));
        if (amount == 0) return;
        if (!_call(asset, gasleft(), abi.encodeCall(IERC20.transfer, (origin, amount)))) revert TransferFailed(asset);
    }

    /// @dev A raw call that counts as success when it did not revert and returned nothing or a nonzero word.
    function _call(address target, uint256 gas, bytes memory data) private returns (bool) {
        (bool ok, bytes memory ret) = target.call{gas: gas}(data);
        return ok && (ret.length == 0 || (ret.length >= 32 && bytes32(ret) != bytes32(0)));
    }

    /// @dev A read with `READ_GAS` that must answer one word or more; the first word is the answer.
    function _readWord(address target, bytes memory data) private view returns (bool, uint256) {
        (bool ok, bytes memory ret) = target.staticcall{gas: READ_GAS}(data);
        if (!ok || ret.length < 32) return (false, 0);
        return (true, uint256(bytes32(ret)));
    }

    /// @dev A graduation path exists when the pool's Doppler hook carries the graduation flag, or when a live
    ///      timelock could set a hook that does.
    function _graduationPath(address hook) private view returns (bool) {
        if (
            hook != address(0) && IDopplerHookInitializer(initializer).isDopplerHookEnabled(hook) & GRADUATION_FLAG != 0
        ) {
            return true;
        }
        return hookSetter() != address(0);
    }
}
