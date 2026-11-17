// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookrForwarding} from "../base/HookrForwarding.sol";
import {HookrForward} from "../libraries/HookrForward.sol";
import {EndKind} from "../types/EndKind.sol";
import {IHookrRevenueSource} from "../interfaces/IHookrRevenueSource.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";
import {IHookrDopplerAdapter} from "../interfaces/IHookrDopplerAdapter.sol";
import {IDopplerHookInitializer, IDopplerAirlock} from "../interfaces/external/IDoppler.sol";

/// @title Hookr Doppler adapter, a revenue source of the HookRevenue Tokenizer
/// @notice A beneficiary share of one Doppler launch (the Long adapter), standing in for a revenue token. See
///         IHookrDopplerAdapter for the rules.
/// @dev Every pin is read at construction: from the initializer the launch's pool key (its two currencies, fee,
///      spacing and hook, which must be the initializer itself), the pool id the initializer stored the
///      beneficiaries under and the Airlock; from the Airlock the launch's integrator; and the share the origin
///      holds then. The launch must be `Locked` (only a locked pool has shares).
///
///      pull(), in order, each step its own attempt with a gas cap: (1) when the adapter holds a share,
///      `collectFees(poolId)` with COLLECT_GAS (it pays this adapter, the caller, its share of everything collected so
///      far, both currencies); (2) forward (HookrForwarding): native ETH, the numeraire and the launch token, each to
///      the token when it lists them and, less Hookr's leg, into the token's drop box otherwise (an immediate drop at
///      a release period under an hour, the stray stream at an hour or more). A failed
///      step leaves what it could not move where it is and never undoes another step. `pull` takes calls from the
///      revenue token alone and runs only once the token has the adapter as a door (`NotADoor`), so the share never
///      feeds a token that took no Hookr leg for it.
///
///      Gas: the tokenizer gives this source `pullGas()` (6,800,000): the collection at its cap, the native send at
///      `SEND_GAS` and two forwards at `FORWARD_ITEM_GAS`, with the 64/63 the EVM keeps back, sum to about
///      6,300,000. Measured cold: a pull that collects, forwards ETH and the numeraire and streams the launch token
///      takes about 355,000 against the mocks.
///
///      One bit of state: whether the adapter has found itself among the token's doors (`_doorSeen`), set once and
///      never cleared, since doors are never removed. Nothing here is owned, nothing is paused and, once the token
///      has the adapter as a door, no function moves the share. The adapter is never a payee of the token, so the
///      sync's transient lock, Doppler's own reentrancy guard and forwards by balance are the whole safety case.
contract HookrDopplerAdapter is IHookrDopplerAdapter, HookrForwarding {
    using PoolIdLibrary for PoolKey;

    /// @inheritdoc IHookrDopplerAdapter
    bytes32 public constant SOURCE_KIND = keccak256("doppler.v4");
    /// @inheritdoc IHookrDopplerAdapter
    uint256 public constant COLLECT_GAS = 1_500_000;
    /// @dev What `pullGas` answers: the collection at its cap and the forwards.
    uint32 internal constant PULL_GAS = 6_800_000;
    /// @dev Doppler's `PoolStatus.Locked`: the only status in which fees are collected and shares exist.
    uint8 internal constant LOCKED = 2;
    /// @dev Doppler's `ON_GRADUATION_FLAG`: a Doppler hook with it lets anyone `graduate` the pool.
    uint256 internal constant GRADUATION_FLAG = 1 << 2;
    /// @dev One share in Doppler's units (WAD).
    uint256 internal constant WAD = 1e18;
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
    /// @dev Set the first time a pull finds this adapter among the revenue token's doors; doors are never removed.
    bool private _doorSeen;

    /// @param revenueToken_ The revenue token every pull pays; it may exist already or not yet, and is neither of the
    ///        pool's currencies (`PairIsRevenueToken`).
    /// @param initializer_ The Doppler hook initializer; must have code and hold `launchToken_`'s locked pool.
    /// @param launchToken_ The launched token.
    /// @param origin_ The account that holds the share now. The factory makes an adapter only while its address holds
    ///        no share (`ShareMovedBeforeCreate`); `originShares` also counts one there for an adapter made otherwise.
    constructor(address revenueToken_, address initializer_, address launchToken_, address origin_)
        HookrForwarding(revenueToken_)
    {
        if (origin_ == address(0) || initializer_.code.length == 0) revert InvalidConfig();
        IDopplerHookInitializer i = IDopplerHookInitializer(initializer_);
        (,,,, uint8 status, PoolKey memory key,) = i.getState(launchToken_);
        if (status != LOCKED || address(key.hooks) != initializer_) revert InvalidConfig();
        bool isCurrency0 = Currency.unwrap(key.currency0) == launchToken_;
        if (!isCurrency0 && Currency.unwrap(key.currency1) != launchToken_) revert InvalidConfig();
        if (Currency.unwrap(key.currency0) == revenueToken_ || Currency.unwrap(key.currency1) == revenueToken_) {
            revert PairIsRevenueToken();
        }
        PoolId id = key.toId();
        (,,,, IHooks stored) = i.getPoolKey(id);
        if (address(stored) != initializer_) revert InvalidConfig();
        address airlock_ = i.airlock();
        if (airlock_.code.length == 0) revert InvalidConfig();
        (,,,,,,,,, address integrator_) = IDopplerAirlock(airlock_).getAssetData(launchToken_);
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
    /// @dev Both currencies of the pool: the numeraire, then the launch token. The tokenizer lists them when the
    ///      call that adds the adapter sets `StreamParams.listAssets`, while there is room: then both stream through
    ///      the token's index, however often and whenever anyone pulls. Unlisted, they reach the holders through the
    ///      drop box's stray path.
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
    /// @dev From `pending()` and what the adapter holds: native ETH (the numeraire when it is native), the numeraire
    ///      when it is an ERC-20 the token lists, and the launch token when the token lists it (otherwise a pull
    ///      streams it through the drop box). Fees the pool earned since Doppler's last collection are not counted.
    function pendingIncome() external view returns (Currency[] memory, uint256[] memory) {
        (uint256 numeraireAmount, uint256 launchTokenAmount) = pending();
        address[3] memory list;
        uint256[3] memory owed;
        uint256 n = 1;
        if (numeraire.isAddressZero()) owed[0] = numeraireAmount;
        else (list[n], owed[n++]) = (Currency.unwrap(numeraire), numeraireAmount);
        (list[n], owed[n++]) = (launchToken, launchTokenAmount);
        return _income(list, owed, n);
    }

    /// @inheritdoc IHookrRevenueSource
    /// @dev The adapter holds a nonzero share and the pool is still `Locked`, so the share still earns.
    function bound() public view returns (bool) {
        if (shares() == 0) return false;
        (,,,, uint8 status,,) = IDopplerHookInitializer(initializer).getState(launchToken);
        return status == LOCKED;
    }

    /// @notice When the stream ends: a share has no term of its own.
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

    /// @notice Collects the share's fees and forwards them to the revenue token. Only the revenue token, and only
    ///         once it has this adapter as a door.
    /// @dev Forwards even when the adapter holds no share any more: whatever reached it is still the holders'. The
    ///      first pull that finds the adapter among the token's doors remembers it.
    function pull() external onlyRevenueToken nonReentrant {
        _requireDoor();
        _collect(poolId);
        _forwardHeld(address(0));
        if (!numeraire.isAddressZero()) _forwardHeld(Currency.unwrap(numeraire));
        _forwardHeld(launchToken);
    }

    // ------------------------------------------------------------------ IHookrDopplerAdapter

    /// @inheritdoc IHookrDopplerAdapter
    /// @dev One capped read of the token's `isDoor`; a token that does not answer it (no code, or not a revenue
    ///      token) is no door of anything.
    function isDoor() public view returns (bool) {
        if (_doorSeen) return true;
        (bool read, uint256 yes) =
            HookrForward.read(revenueToken, abi.encodeCall(IHookrRevenueToken.isDoor, (address(this))), BALANCE_GAS);
        return read && yes != 0;
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
    function pending() public view returns (uint256 numeraireAmount, uint256 launchTokenAmount) {
        IDopplerHookInitializer i = IDopplerHookInitializer(initializer);
        uint256 s = i.getShares(poolId, address(this));
        if (s == 0) return (0, 0);
        uint256 owed0 = (i.getCumulatedFees0(poolId) - i.getLastCumulatedFees0(poolId, address(this))) * s / WAD;
        uint256 owed1 = (i.getCumulatedFees1(poolId) - i.getLastCumulatedFees1(poolId, address(this))) * s / WAD;
        (numeraireAmount, launchTokenAmount) = launchIsCurrency0 ? (owed1, owed0) : (owed0, owed1);
    }

    /// @inheritdoc IHookrDopplerAdapter
    function collect(PoolId other) external nonReentrant {
        _collect(other);
    }

    /// @inheritdoc IHookrDopplerAdapter
    /// @dev Only `origin`, only while the token does not have this adapter as a door (`isDoor`, false while the token
    ///      has no code or has not added it). Doppler moves every share of the caller at once and only by the caller,
    ///      and shares never split, so a share that was more than half of the launch can never be matched by any mix of
    ///      the other holders' shares (they add up to less). When the adapter holds exactly that much, it holds the
    ///      origin's share and nothing else. `updateBeneficiary(poolId, origin)` first pays this adapter what its share
    ///      is owed; then every unit of the launch token, the numeraire and native ETH the adapter holds goes to
    ///      `origin`. Reverts whole when a pay-back is refused.
    function abort() external nonReentrant {
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

    /// @dev The token has this adapter as a door; remembered the first time it is found.
    function _requireDoor() private {
        if (!_doorSeen) {
            if (!isDoor()) revert NotADoor();
            _doorSeen = true;
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

    /// @dev The numeraire and the launch token are the adapter's own; anything else leaves through `dropStray`.
    function _isOwnAsset(address asset) internal view override returns (bool) {
        return asset == Currency.unwrap(numeraire) || asset == launchToken;
    }
}
